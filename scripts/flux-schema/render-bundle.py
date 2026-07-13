#!/usr/bin/env python3
"""Render the repository into a single validated bundle (SPEC-007 FR-004).

Three inputs, one output directory:
  * every top-most kustomize overlay -> `kustomize build` + Flux postBuild envsubst
  * every HelmRelease                -> `helm template` with its own spec.values
  * standalone manifests             -> copied verbatim

Rendered output is what Flux actually applies, so it is the only artifact worth
asserting on (CL-1): raw patch fragments can never satisfy a full schema.
"""
import os
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile

import yaml

MANIFEST_DIRS = [
    "infrastructure",
    "security",
    "observability",
    "tooling",
    "apps",
    "clusters",
    "flux",
    "namespaces",
    "crds",
]

# Same fixture values CI passed to kubeconform. Substituted so that
# ${private_domain_name} in a DNS-1123 field validates as a hostname.
FIXTURE_VARS = {
    "domain_name": "cluster.local",
    "private_domain_name": "priv.cluster.local",
    "public_domain_name": "cluster.local",
    "cluster_name": "foobar",
    "region": "eu-west-3",
    "environment": "dev",
    "cert_manager_approle_id": "random",
    "route53_public_zone_id": "Z0123456789",
    "aws_account_id": "123456789012",
    "vpc_id": "vpc-0123456789abcdef0",
    "vpc_cidr_block": "10.0.0.0/16",
    "oidc_provider_arn": "arn:aws:iam::123456789012:oidc-provider/oidc.eks",
    "oidc_issuer_host": "oidc.eks.eu-west-3.amazonaws.com",
    "oidc_issuer_url": "https://oidc.eks.eu-west-3.amazonaws.com",
    "cluster_endpoint_full": "https://example.eks.amazonaws.com",
    "karpenter_queue_name": "karpenter-foobar",
}

KUBE_VERSION = "1.31.0"
VAR_RE = re.compile(r"\$\{([a-zA-Z_][a-zA-Z0-9_]*)\}")

REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]

# Render-only value overrides for charts whose templates call Helm's `lookup`
# function to discover live cluster state (an existing Secret, a sibling
# release's ServiceAccount). `helm template` has no cluster to read, so
# `lookup` always returns an empty result and these charts then dereference
# into it and crash - a template-rendering limitation, not a source
# resolution problem. Each override is the value the chart's own error
# message names as the explicit escape hatch, and matches what `lookup`
# would have found on a real cluster (see the HelmRelease's sibling
# resources: the actual Secret/controller release), so it does not change
# validation intent.
CHART_RENDER_OVERRIDES = {
    # harbor.redis.pwdfromsecret does `(lookup "v1" "Secret" ... existingSecret).data.REDIS_PASSWORD`;
    # emptying existingSecret routes to the external username/password branch instead.
    ("tooling", "harbor"): {"redis": {"external": {"existingSecret": ""}}},
    # gha-runner-scale-set's manager_role_binding.yaml discovers the controller's
    # ServiceAccount by label-selecting Deployments; explicit name/namespace (the
    # gha-runner-scale-set-controller HelmRelease's own release name + chart
    # "fullname" helper) is the chart's documented workaround (see values.yaml).
    ("tooling", "default-gha-runner-scale-set"): {
        "controllerServiceAccount": {
            "name": "gha-runner-scale-set-controller-gha-rs-controller",
            "namespace": "tooling",
        }
    },
    ("tooling", "dagger-gha-runner-scale-set"): {
        "controllerServiceAccount": {
            "name": "gha-runner-scale-set-controller-gha-rs-controller",
            "namespace": "tooling",
        }
    },
}


def deep_merge(base, overrides):
    merged = dict(base)
    for key, value in overrides.items():
        if isinstance(value, dict) and isinstance(merged.get(key), dict):
            merged[key] = deep_merge(merged[key], value)
        else:
            merged[key] = value
    return merged


def resolve_bin(env_var, tool):
    """Resolve a tool binary the same way preflight.sh does.

    Precedence: env var exported by the shell entry point (preflight.sh
    sourced by the caller) > `mise which` scoped to this repo > bare PATH
    lookup. A bare `helm`/`kustomize` earlier on $PATH can be a stale
    version that silently mis-renders charts (see preflight.sh); never
    fall back to that first.
    """
    override = os.environ.get(env_var)
    if override:
        return override

    if shutil.which("mise") and (REPO_ROOT / "mise.toml").exists():
        try:
            result = subprocess.run(
                ["mise", "which", "-C", str(REPO_ROOT), tool],
                capture_output=True,
                text=True,
                timeout=30,
                check=False,
            )
            resolved = result.stdout.strip()
            if result.returncode == 0 and resolved:
                return resolved
        except (OSError, subprocess.SubprocessError):
            pass

    resolved = shutil.which(tool)
    if resolved:
        return resolved

    print(f"error: {tool} not found (checked ${env_var}, mise, PATH).", file=sys.stderr)
    sys.exit(1)


HELM_BIN = resolve_bin("HELM_BIN", "helm")
KUSTOMIZE_BIN = resolve_bin("KUSTOMIZE_BIN", "kustomize")


def substitute(text):
    """Replace ${var} with fixture values. `$${var}` is Flux's escape - leave it."""
    text = text.replace("$${", "\x00{")
    text = VAR_RE.sub(lambda m: FIXTURE_VARS.get(m.group(1), m.group(0)), text)
    return text.replace("\x00{", "$${")


def load_docs(path):
    try:
        return [d for d in yaml.safe_load_all(path.read_text()) if isinstance(d, dict)]
    except yaml.YAMLError:
        return []


def top_most_overlays():
    """Kustomize dirs with no ancestor kustomization.yaml (avoids double-render)."""
    dirs = {
        p.parent
        for root in MANIFEST_DIRS
        for p in pathlib.Path(root).rglob("kustomization.yaml")
        if pathlib.Path(root).exists()
    }
    return sorted(d for d in dirs if not any(a in dirs for a in d.parents))


def index_sources():
    sources = {}
    for root in MANIFEST_DIRS:
        base = pathlib.Path(root)
        if not base.exists():
            continue
        for path in base.rglob("*.yaml"):
            for doc in load_docs(path):
                # GitRepository is included alongside HelmRepository/OCIRepository:
                # one HelmRelease (runlore) points `chart.spec.sourceRef` at a
                # GitRepository and a chart subpath, not a Helm repo.
                if doc.get("kind") not in ("HelmRepository", "OCIRepository", "GitRepository"):
                    continue
                meta, spec = doc.get("metadata", {}), doc.get("spec", {})
                # Keyed by (kind, name, namespace), not just (name, namespace):
                # this repo has a GitRepository and a HelmRepository sharing the
                # same name+namespace (e.g. security/kyverno, security/external-secrets
                # - one feeds CRDs via kustomize, the other feeds the Helm chart).
                # sourceRef always states `kind` explicitly, so this is a safe key.
                key = (doc["kind"], meta.get("name"), meta.get("namespace", "flux-system"))
                sources[key] = dict(spec, _kind=doc["kind"])
    return sources


def resolve_source(sources, source_ref, hr_namespace):
    """sourceRef.namespace defaults to the HelmRelease's namespace, not flux-system."""
    kind, name = source_ref.get("kind"), source_ref.get("name")
    for namespace in (source_ref.get("namespace"), hr_namespace, "flux-system"):
        if namespace and (kind, name, namespace) in sources:
            return sources[(kind, name, namespace)]
    return None


def index_namespaces():
    """Map each locally-listed kustomize resource file to its effective namespace.

    This repo's convention is `base/<component>/kustomization.yaml` carrying
    both `namespace: X` and a `resources:` list of local files (helmrelease.yaml
    among them) - the namespace transformer stamps X onto them at apply time,
    even though the raw HelmRelease YAML on disk has no metadata.namespace.
    Without this, HelmReleases relying on that convention default to the wrong
    namespace and both their own render and their sourceRef lookup fail.
    """
    index = {}
    for root in MANIFEST_DIRS:
        base = pathlib.Path(root)
        if not base.exists():
            continue
        for kfile in base.rglob("kustomization.yaml"):
            docs = load_docs(kfile)
            if not docs:
                continue
            namespace = docs[0].get("namespace")
            if not namespace:
                continue
            for resource in docs[0].get("resources") or []:
                candidate = (kfile.parent / resource).resolve()
                if candidate.is_file():
                    index[candidate] = namespace
    return index


def clone_git_source(url, ref, dest):
    """Shallow-clone a GitRepository source at its pinned tag/branch/commit."""
    ref = ref or {}
    tag_or_branch = ref.get("tag") or ref.get("branch")
    cmd = ["git", "clone", "--quiet", "--depth", "1"]
    if tag_or_branch:
        cmd += ["--branch", tag_or_branch]
    cmd += [url, str(dest)]
    result = subprocess.run(cmd, capture_output=True, text=True, timeout=300)
    if result.returncode != 0:
        return (result.stderr.strip().splitlines() or ["git clone failed"])[-1][:200]

    commit = ref.get("commit")
    if commit and not tag_or_branch:
        result = subprocess.run(
            ["git", "fetch", "--quiet", "--depth", "1", "origin", commit],
            cwd=dest, capture_output=True, text=True, timeout=300,
        )
        if result.returncode != 0:
            return (result.stderr.strip().splitlines() or ["git fetch failed"])[-1][:200]
        result = subprocess.run(
            ["git", "checkout", "--quiet", commit],
            cwd=dest, capture_output=True, text=True, timeout=300,
        )
        if result.returncode != 0:
            return (result.stderr.strip().splitlines() or ["git checkout failed"])[-1][:200]
    return None


def render_overlay(overlay, outdir):
    result = subprocess.run(
        [KUSTOMIZE_BIN, "build", str(overlay), "--load-restrictor=LoadRestrictionsNone"],
        capture_output=True,
        text=True,
        timeout=300,
    )
    if result.returncode != 0:
        return result.stderr.strip().splitlines()[-1][:200]
    name = "overlay-" + str(overlay).replace("/", "-") + ".yaml"
    (outdir / name).write_text(substitute(result.stdout))
    return None


def render_helmrelease(doc, sources, outdir, namespace):
    meta, spec = doc["metadata"], doc["spec"]
    namespace = meta.get("namespace") or namespace or "default"
    chart_spec = spec.get("chart", {}).get("spec", {})
    source = resolve_source(sources, chart_spec.get("sourceRef", {}), namespace)
    if not source or not source.get("url"):
        return f"unresolved chart source for HelmRelease/{namespace}/{meta['name']}"

    url, chart, version = source["url"], chart_spec.get("chart"), chart_spec.get("version")
    is_oci = source.get("type") == "oci" or url.startswith("oci://")
    is_git = source.get("_kind") == "GitRepository"

    values = spec.get("values") or {}
    overrides = CHART_RENDER_OVERRIDES.get((namespace, meta["name"]))
    if overrides:
        values = deep_merge(values, overrides)

    with tempfile.NamedTemporaryFile("w", suffix=".yaml", delete=False) as handle:
        yaml.safe_dump(values, handle)
        values_file = handle.name

    git_clone_dir = None
    try:
        if is_git:
            # GitRepository sourceRef: `chart` is a path to the chart *within*
            # the repo, not a repo-relative chart name - clone, then point
            # helm template at the local checkout subdirectory.
            git_clone_dir = tempfile.mkdtemp(prefix="flux-schema-git-")
            error = clone_git_source(url, source.get("ref"), git_clone_dir)
            if error:
                return f"HelmRelease/{namespace}/{meta['name']}: git clone {url}: {error}"
            chart_path = str(pathlib.Path(git_clone_dir) / chart)
        else:
            chart_path = f"{url.rstrip('/')}/{chart}" if is_oci else chart

        cmd = [
            HELM_BIN, "template", meta["name"], chart_path,
            "--namespace", namespace,
            "--values", values_file,
            "--include-crds",
            "--skip-tests",
            "--kube-version", KUBE_VERSION,
        ]
        if not is_oci and not is_git:
            cmd += ["--repo", url]
        if version and not is_git:
            cmd += ["--version", version]

        result = subprocess.run(cmd, capture_output=True, text=True, timeout=300)
    finally:
        os.unlink(values_file)
        if git_clone_dir:
            shutil.rmtree(git_clone_dir, ignore_errors=True)

    if result.returncode != 0:
        return f"HelmRelease/{namespace}/{meta['name']}: {result.stderr.strip().splitlines()[-1][:160]}"
    (outdir / f"chart-{namespace}-{meta['name']}.yaml").write_text(substitute(result.stdout))
    return None


def main():
    outdir = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else ".bundle")
    outdir.mkdir(parents=True, exist_ok=True)

    errors = []
    overlays = top_most_overlays()
    for overlay in overlays:
        error = render_overlay(overlay, outdir)
        if error:
            errors.append(f"kustomize {overlay}: {error}")

    sources = index_sources()
    namespaces = index_namespaces()
    covered = {str(o) for o in overlays}
    charts = standalone = 0

    for root in MANIFEST_DIRS:
        base = pathlib.Path(root)
        if not base.exists():
            continue
        for path in base.rglob("*.yaml"):
            docs = load_docs(path)
            in_overlay = any(str(path).startswith(c + "/") for c in covered)
            for doc in docs:
                # HelmReleases carrying `chart` are renderable; `chartRef` (OCIRepository)
                # and patch fragments (no chart at all) are validated via the overlay.
                if doc.get("kind") == "HelmRelease" and doc.get("spec", {}).get("chart"):
                    namespace = namespaces.get(path.resolve())
                    error = render_helmrelease(doc, sources, outdir, namespace)
                    if error:
                        errors.append(error)
                    else:
                        charts += 1
            if not in_overlay and docs:
                (outdir / ("standalone-" + str(path).replace("/", "-"))).write_text(
                    substitute(path.read_text())
                )
                standalone += 1

    print(
        f"RENDER: overlays={len(overlays)} charts={charts} "
        f"standalone={standalone} failed={len(errors)}"
    )
    for error in errors:
        print(f"  FAIL {error}", file=sys.stderr)
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
