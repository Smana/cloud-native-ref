#!/usr/bin/env python3
"""Render the repository into a single validated bundle (SPEC-007 FR-004).

Three inputs, one output directory:
  * every top-most kustomize overlay -> `kustomize build` + Flux postBuild envsubst
  * every HelmRelease                -> `helm template` with its own spec.values
  * standalone manifests             -> copied verbatim

Rendered output is what Flux actually applies, so it is the only artifact worth
asserting on (CL-1): raw patch fragments can never satisfy a full schema.
"""
import concurrent.futures
import contextlib
import os
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile
import threading

import yaml

from yamlcompat import YAML_DUMPER, YAML_LOADER

# Renders are independent subprocesses (helm/kustomize), so they parallelize
# near-linearly; the loops in main() were sequential and dominated the runtime
# (~130s of a ~140s validate run for 67 overlays + 40 charts).
MAX_WORKERS = int(os.environ.get("RENDER_WORKERS", "8"))

# helm shares one repository cache dir for index files AND chart tarballs
# (`<chart>-<version>.tgz` - not namespaced by repo, and OCI pulls land there
# too). Two concurrent helm invocations against the same source can race on
# the same cache file (e.g. the two gha-runner-scale-set HelmReleases share a
# chart), so helm calls are serialized per source URL; distinct sources still
# run fully parallel.
_repo_locks = {}
_repo_locks_guard = threading.Lock()


def _repo_lock(url):
    with _repo_locks_guard:
        return _repo_locks.setdefault(url, threading.Lock())

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

# YAML that lives under a manifest dir but is NOT a Kubernetes manifest: plain
# config a workload reads at runtime. It has no apiVersion/kind, so sweeping it
# into the bundle fails gate 1 ("missing required property: /apiVersion").
#
# This list is deliberately explicit rather than a blanket "skip docs with no
# kind" rule: SPEC-007's contract is that nothing is silently skipped, so a NEW
# non-manifest YAML must fail the build loudly and be added here on purpose.
NON_MANIFEST_FILES = {
    # Stack registry the App Wizard reads via STACKS_PATH (SPEC-008 FR-006).
    "apps/stacks.yaml",
}

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
        return [d for d in yaml.load_all(path.read_text(), Loader=YAML_LOADER) if isinstance(d, dict)]
    except yaml.YAMLError:
        return []


def unwrap_lists(docs):
    """`kind: List` is a client-side envelope, not an applyable resource -
    `kubectl apply`/kustomize expand it and apply each item individually.
    (aws-load-balancer-controller's ingressclass.yaml template wraps an
    IngressClassParams + an IngressClass this way.) Replace each List with
    its items so the CONTENTS get validated, instead of failing on
    "no schema for kind List" or silently hiding the items from both gates.
    """
    expanded = []
    for doc in docs:
        if doc.get("kind") == "List":
            expanded.extend(item for item in (doc.get("items") or []) if isinstance(item, dict))
        else:
            expanded.append(doc)
    return expanded


def normalize_quantities(node):
    """Stringify bare-number values under any `resources.limits`/`resources.requests` map.

    The Kubernetes API server's resource.Quantity.UnmarshalJSON accepts a bare
    JSON number (`cpu: 1`) exactly like a string (`cpu: "1"`) - upstream chart
    defaults (KEDA, Harbor's bundled Trivy subchart) and this repo's own
    dagger-engine overlay rely on that leniency, and these workloads run in
    the live cluster today with these exact values. flux-schema's generated
    JSON-Schema catalog types Quantity as `string` only, stricter than the
    API server actually is, so a numeric value here is a validator false
    positive, not a real defect. Narrowly scoped to resources.limits/requests
    (containers, initContainers, ephemeralContainers, and the same shape
    wherever it recurs in CRs) - does not touch numbers anywhere else.
    """
    if isinstance(node, dict):
        resources = node.get("resources")
        if isinstance(resources, dict):
            for section in ("limits", "requests"):
                quantities = resources.get(section)
                if isinstance(quantities, dict):
                    for key, value in quantities.items():
                        if isinstance(value, (int, float)) and not isinstance(value, bool):
                            quantities[key] = str(value)
        for value in node.values():
            normalize_quantities(value)
    elif isinstance(node, list):
        for item in node:
            normalize_quantities(item)


def postprocess(text):
    """Make rendered output a faithful stand-in for what Flux/kubectl actually
    applies: expand `List` envelopes and fix up bare-number Quantity values
    that only a stricter-than-the-API-server schema catalog would reject.
    Comments and exact formatting are not preserved - irrelevant to schema/
    Polaris validation, and dropped anyway once helm/kustomize post-renderers
    round-trip through YAML.
    """
    docs = unwrap_lists([d for d in yaml.load_all(text, Loader=YAML_LOADER) if isinstance(d, dict)])
    # Drop non-resource docs before they reach the bundle. `helm template`
    # (notably Helm v4) can emit a stray YAML document that is a non-empty dict
    # yet carries no apiVersion/kind - not an applyable Kubernetes resource, but
    # a dict, so the isinstance() filter above lets it through and gate 1 then
    # rejects it ("missing required property: /apiVersion"). A real resource
    # always has both fields, so requiring them here is the faithful stand-in
    # for what Flux/kubectl would actually apply. Applied after unwrap_lists so
    # `kind: List` envelopes (apiVersion/kind present) are expanded first and
    # only their inner resources are checked.
    docs = [doc for doc in docs if doc.get("apiVersion") and doc.get("kind")]
    for doc in docs:
        normalize_quantities(doc)
    return "\n---\n".join(
        yaml.dump(doc, Dumper=YAML_DUMPER, sort_keys=False, default_flow_style=False, width=1000000).strip()
        for doc in docs
    ) + "\n"


def _last_line(result, default, limit=200):
    """Last line of a subprocess' stderr (or `default`), truncated for a
    one-line error message."""
    return (result.stderr.strip().splitlines() or [default])[-1][:limit]


def apply_post_renderers(rendered_text, post_renderers):
    """Apply `spec.postRenderers` the same way helm-controller does before
    installing the release, so the bundle matches what Flux actually applies
    (skipping this makes the bundle diverge from reality - e.g. loggen's
    postRenderer strips container-level securityContext fields the chart
    wrongly hardcodes at pod level; without it the bundle still has them and
    the schema gate reports a false positive on an already-fixed problem).

    Only the `kustomize` post-renderer is implemented - the sole kind used in
    this repo (loggen, harbor). Other post-renderer kinds (e.g. Flagger's
    dep-container) don't apply to static bundle rendering and are skipped.
    """
    workdir = pathlib.Path(tempfile.mkdtemp(prefix="flux-schema-postrender-"))
    try:
        (workdir / "rendered.yaml").write_text(rendered_text)
        kustomization = {
            "apiVersion": "kustomize.config.k8s.io/v1beta1",
            "kind": "Kustomization",
            "resources": ["rendered.yaml"],
        }
        has_kustomize_pr = False
        for post_renderer in post_renderers:
            kustomize_pr = (post_renderer or {}).get("kustomize")
            if not kustomize_pr:
                continue
            has_kustomize_pr = True
            if kustomize_pr.get("patches"):
                kustomization.setdefault("patches", []).extend(kustomize_pr["patches"])
            if kustomize_pr.get("images"):
                kustomization.setdefault("images", []).extend(kustomize_pr["images"])
            for idx, merge in enumerate(kustomize_pr.get("patchesStrategicMerge") or []):
                patch_file = f"strategic-merge-{idx}.yaml"
                content = merge if isinstance(merge, str) else yaml.safe_dump(merge)
                (workdir / patch_file).write_text(content)
                kustomization.setdefault("patchesStrategicMerge", []).append(patch_file)

        if not has_kustomize_pr:
            return rendered_text, None

        (workdir / "kustomization.yaml").write_text(yaml.safe_dump(kustomization, sort_keys=False))
        result = subprocess.run(
            [KUSTOMIZE_BIN, "build", str(workdir), "--load-restrictor=LoadRestrictionsNone"],
            capture_output=True,
            text=True,
            timeout=300,
        )
        if result.returncode != 0:
            return None, _last_line(result, "kustomize postRenderer failed")
        return result.stdout, None
    finally:
        shutil.rmtree(workdir, ignore_errors=True)


def _kustomization_dirs():
    return {
        p.parent
        for root in MANIFEST_DIRS
        if pathlib.Path(root).exists()
        for p in pathlib.Path(root).rglob("kustomization.yaml")
    }


def _referenced_dirs(kdirs):
    """Directories pulled in by another kustomization's resources/components/
    bases. Such a dir is rendered transitively by its parent, so it must not
    also be rendered as its own root."""
    referenced = set()
    for d in kdirs:
        for doc in load_docs(d / "kustomization.yaml"):
            for field in ("resources", "components", "bases"):
                for entry in doc.get(field) or []:
                    if not isinstance(entry, str):
                        continue
                    target = pathlib.Path(os.path.normpath(d / entry))
                    if (target / "kustomization.yaml").is_file():
                        referenced.add(target)
    return referenced


def top_most_overlays():
    """Kustomize dirs to `kustomize build` as roots.

    A dir is a root when it is filesystem-top-most (no ancestor kustomization)
    OR it is nested but no other kustomization references it — the latter being
    a dir a Flux Kustomization targets directly by `spec.path`
    (infrastructure/mycluster-0/crossplane/*, security/mycluster-0/zitadel,
    observability/mycluster-0/victoria-metrics-k8s-stack). The old
    `no ancestor kustomization` rule silently dropped that second class from
    both render paths, contradicting SPEC-007's no-silent-skips guarantee.

    This is a filesystem heuristic that approximates the true source of truth —
    the `spec.path` of every Flux Kustomization under clusters/. Deriving roots
    from those directly would be more exact but couples the renderer to the
    cluster's Kustomization graph (base-vs-overlay, suspended siblings, multiple
    clusters); test-flux-schema.sh pins the known nested cases as a safety net."""
    dirs = _kustomization_dirs()
    referenced = _referenced_dirs(dirs)
    roots = []
    for d in dirs:
        if not any(a in dirs for a in d.parents):
            roots.append(d)          # filesystem-top-most (unchanged)
        elif d not in referenced:
            roots.append(d)          # nested, but nobody includes it
    return sorted(roots)


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
    """Map each locally-listed kustomize resource file to its effective
    namespace, and collect the set of ALL files any kustomization references.

    Namespaces: this repo's convention is `base/<component>/kustomization.yaml`
    carrying both `namespace: X` and a `resources:` list of local files
    (helmrelease.yaml among them) - the namespace transformer stamps X onto
    them at apply time, even though the raw HelmRelease YAML on disk has no
    metadata.namespace. Without this, HelmReleases relying on that convention
    default to the wrong namespace and both their own render and their
    sourceRef lookup fail.

    Referenced set: used to pick between ALTERNATIVE HelmRelease variants of
    the same release (see main()) - the variant a kustomization actually lists
    is the one Flux applies; the commented-out sibling is not.
    """
    index, referenced = {}, set()
    for root in MANIFEST_DIRS:
        base = pathlib.Path(root)
        if not base.exists():
            continue
        for kfile in base.rglob("kustomization.yaml"):
            docs = load_docs(kfile)
            if not docs:
                continue
            namespace = docs[0].get("namespace")
            for resource in docs[0].get("resources") or []:
                candidate = (kfile.parent / resource).resolve()
                if candidate.is_file():
                    referenced.add(candidate)
                    if namespace:
                        index[candidate] = namespace
    return index, referenced


def clone_git_source(url, ref, dest):
    """Shallow-clone a GitRepository source at its pinned tag/branch/commit."""
    ref = ref or {}
    tag_or_branch = ref.get("tag") or ref.get("branch")
    commit = ref.get("commit")
    # A ref pinned only by `semver`/`name` needs the remote tag list to
    # resolve; we cannot do that faithfully offline, so fail loudly rather than
    # silently clone the default branch (a different revision than Flux applies).
    if not (tag_or_branch or commit) and (ref.get("semver") or ref.get("name")):
        return f"unsupported GitRepository ref (semver/name resolves against remote tags): {ref}"
    cmd = ["git", "clone", "--quiet", "--depth", "1"]
    if tag_or_branch:
        cmd += ["--branch", tag_or_branch]
    cmd += [url, str(dest)]
    result = subprocess.run(cmd, capture_output=True, text=True, timeout=300)
    if result.returncode != 0:
        return _last_line(result, "git clone failed")

    # Honor an explicit commit even when a tag/branch was also given: Flux
    # resolves to that exact commit, and a moved tag would otherwise render a
    # different revision than the cluster applies.
    if commit:
        result = subprocess.run(
            ["git", "fetch", "--quiet", "--depth", "1", "origin", commit],
            cwd=dest, capture_output=True, text=True, timeout=300,
        )
        if result.returncode != 0:
            return _last_line(result, "git fetch failed")
        result = subprocess.run(
            ["git", "checkout", "--quiet", commit],
            cwd=dest, capture_output=True, text=True, timeout=300,
        )
        if result.returncode != 0:
            return _last_line(result, "git checkout failed")
    return None


def render_overlay(overlay, outdir):
    result = subprocess.run(
        [KUSTOMIZE_BIN, "build", str(overlay), "--load-restrictor=LoadRestrictionsNone"],
        capture_output=True,
        text=True,
        timeout=300,
    )
    if result.returncode != 0:
        return _last_line(result, "kustomize build failed")
    try:
        rendered = postprocess(result.stdout)
    except yaml.YAMLError as exc:
        return f"postprocess: {exc}"
    name = "overlay-" + str(overlay).replace("/", "-") + ".yaml"
    (outdir / name).write_text(substitute(rendered))
    return None


def _resolve_chart(spec, sources, namespace):
    """Resolve a HelmRelease's chart source, whether inline or by reference.

    `spec.chartRef` points straight at a source object (OCIRepository /
    HelmChart): the source URL is already the fully-qualified chart path and the
    version lives on the source's own `ref`, so `chart` is None. `spec.chart` is
    the inline form (chart name + sourceRef). Returns (source, chart, version);
    `source` is None when it cannot be resolved."""
    chart_ref = spec.get("chartRef")
    if chart_ref:
        source = resolve_source(sources, chart_ref, namespace)
        pin = (source.get("ref") or {}) if source else {}
        return source, None, pin.get("tag") or pin.get("semver")
    chart_spec = spec.get("chart", {}).get("spec", {})
    source = resolve_source(sources, chart_spec.get("sourceRef", {}), namespace)
    return source, chart_spec.get("chart"), chart_spec.get("version")


def render_helmrelease(doc, sources, outdir, namespace):
    meta, spec = doc["metadata"], doc["spec"]
    namespace = meta.get("namespace") or namespace or "default"

    source, chart, version = _resolve_chart(spec, sources, namespace)
    if not source or not source.get("url"):
        kind = "chartRef" if spec.get("chartRef") else "chart"
        return f"unresolved {kind} source for HelmRelease/{namespace}/{meta['name']}"

    url = source["url"]
    is_oci = source.get("type") == "oci" or url.startswith("oci://")
    is_git = source.get("_kind") == "GitRepository"
    # `chart` is None only for a chartRef (the source URL is the chart itself).
    via_ref = chart is None

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
            # GitRepository source: `chart` is a path to the chart *within*
            # the repo, not a repo-relative chart name - clone, then point
            # helm template at the local checkout subdirectory.
            if via_ref:
                return f"HelmRelease/{namespace}/{meta['name']}: chartRef to a GitRepository is not supported"
            git_clone_dir = tempfile.mkdtemp(prefix="flux-schema-git-")
            error = clone_git_source(url, source.get("ref"), git_clone_dir)
            if error:
                return f"HelmRelease/{namespace}/{meta['name']}: git clone {url}: {error}"
            chart_path = str(pathlib.Path(git_clone_dir) / chart)
        elif via_ref:
            # chartRef -> OCIRepository: the source URL already points at the
            # chart itself, so there is no chart name to append.
            chart_path = url
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
            # `version` may be a semver RANGE from an OCIRepository ref (e.g.
            # flux-operator's ">=0.43.0 <1.0.0"). helm resolves it against the
            # registry's tags at template time, which can differ from the
            # concrete version Flux's source-controller picked — a rendered
            # version that is helm's independent resolution, not necessarily
            # the cluster's. Exact pins (tag / exact semver) are unaffected.
            cmd += ["--version", version]

        # Local git checkouts touch no shared helm cache - no lock needed.
        lock = contextlib.nullcontext() if is_git else _repo_lock(url)
        with lock:
            result = subprocess.run(cmd, capture_output=True, text=True, timeout=300)
    finally:
        os.unlink(values_file)
        if git_clone_dir:
            shutil.rmtree(git_clone_dir, ignore_errors=True)

    if result.returncode != 0:
        detail = _last_line(result, "helm template failed")
        return f"HelmRelease/{namespace}/{meta['name']}: {detail}"

    rendered = result.stdout
    post_renderers = spec.get("postRenderers")
    if post_renderers:
        rendered, pr_error = apply_post_renderers(rendered, post_renderers)
        if pr_error:
            return f"HelmRelease/{namespace}/{meta['name']}: postRenderer: {pr_error}"

    try:
        rendered = postprocess(rendered)
    except yaml.YAMLError as exc:
        return f"HelmRelease/{namespace}/{meta['name']}: postprocess: {exc}"

    (outdir / f"chart-{namespace}-{meta['name']}.yaml").write_text(substitute(rendered))
    return None


def main():
    outdir = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else ".bundle")
    outdir.mkdir(parents=True, exist_ok=True)

    errors = []
    overlays = top_most_overlays()
    sources = index_sources()
    namespaces, referenced = index_namespaces()
    covered = {str(o) for o in overlays}
    charts = standalone = 0

    # Keyed by the OUTPUT identity (effective namespace, name): the repo keeps
    # alternative HelmRelease variants for the same release side by side (e.g.
    # victoria-metrics-k8s-stack's helmrelease-vmsingle.yaml vs
    # helmrelease-vmcluster.yaml, one commented out in the kustomization), and
    # this wiring-agnostic scan picks up both - yet they write the same
    # chart-<ns>-<name>.yaml, so only one can be rendered. The winner is the
    # variant some kustomization actually references (that is what Flux
    # applies; scan-order last-write-wins previously picked victoria-logs'
    # UNREFERENCED vlcluster variant, and under parallel rendering the winner
    # was whichever FINISHED last). Among equally-referenced (or equally
    # unreferenced) duplicates, last in scan order wins. Dropped duplicates
    # are logged, never silent.
    helmreleases = {}
    for root in MANIFEST_DIRS:
        base = pathlib.Path(root)
        if not base.exists():
            continue
        for path in base.rglob("*.yaml"):
            if path.as_posix() in NON_MANIFEST_FILES:
                continue
            docs = load_docs(path)
            in_overlay = any(str(path).startswith(c + "/") for c in covered)
            for doc in docs:
                # A HelmRelease is renderable whether it names its chart inline
                # (`spec.chart`) or by reference (`spec.chartRef` -> an
                # OCIRepository/HelmChart). Both produce pods Polaris must
                # audit; rendering only `spec.chart` left every chartRef
                # controller (Karpenter, Envoy Gateway, ...) as a bare
                # HelmRelease CR with no workloads behind it. Patch fragments
                # (no chart at all) are still validated via the overlay.
                hr_spec = doc.get("spec", {})
                if doc.get("kind") == "HelmRelease" and (hr_spec.get("chart") or hr_spec.get("chartRef")):
                    kustomize_ns = namespaces.get(path.resolve())
                    effective_ns = doc["metadata"].get("namespace") or kustomize_ns or "default"
                    key = (effective_ns, doc["metadata"]["name"])
                    is_referenced = path.resolve() in referenced
                    if key in helmreleases and helmreleases[key][2] and not is_referenced:
                        print(
                            f"note: duplicate HelmRelease/{key[0]}/{key[1]}: skipping "
                            f"unreferenced variant {path} (a kustomization references the other)",
                            file=sys.stderr,
                        )
                        continue
                    if key in helmreleases:
                        print(
                            f"note: duplicate HelmRelease/{key[0]}/{key[1]}: rendering {path} "
                            "(kustomization-referenced, or last in scan order)",
                            file=sys.stderr,
                        )
                    helmreleases[key] = (doc, kustomize_ns, is_referenced)
            if not in_overlay and docs:
                (outdir / ("standalone-" + str(path).replace("/", "-"))).write_text(
                    substitute(path.read_text())
                )
                standalone += 1

    # Every render writes its own uniquely-named output file, so the only
    # shared mutable state is the helm cache (serialized per source URL above).
    # Futures are drained in submission order to keep error output
    # deterministic regardless of completion order.
    with concurrent.futures.ThreadPoolExecutor(max_workers=MAX_WORKERS) as pool:
        overlay_futures = [(o, pool.submit(render_overlay, o, outdir)) for o in overlays]
        chart_futures = [
            pool.submit(render_helmrelease, doc, sources, outdir, namespace)
            for doc, namespace, _ in helmreleases.values()
        ]
        for overlay, future in overlay_futures:
            error = future.result()
            if error:
                errors.append(f"kustomize {overlay}: {error}")
        for future in chart_futures:
            error = future.result()
            if error:
                errors.append(error)
            else:
                charts += 1

    print(
        f"RENDER: overlays={len(overlays)} charts={charts} "
        f"standalone={standalone} failed={len(errors)}"
    )
    for error in errors:
        print(f"  FAIL {error}", file=sys.stderr)
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
