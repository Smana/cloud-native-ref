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
    # No "domain_name": it was removed from the aws-0 ConfigMap, where it was a
    # second key holding the same value as public_domain_name. A fixture for a
    # key no cluster defines would let a manifest reference it and still render
    # here -- which is precisely how the AWS-only usages went unnoticed.
    "private_domain_name": "priv.cluster.local",
    "public_domain_name": "cluster.local",
    "cluster_name": "foobar",
    "region": "eu-west-3",
    "environment": "dev",
    # Both clusters define this; the value differs (gp3 / standard-rwo) but the
    # SHAPE does not -- it is an opaque string either way, which is why one
    # fixture is honest here. Contrast "region" above, where a single
    # AWS-shaped fixture masks a GCP-shaped runtime value.
    "storage_class": "gp3",
    # One fixture, and honestly so: ZITADEL is a singleton, so BOTH clusters
    # carry the same value here -- aws-0 derives it from its own domain because
    # it hosts the IdP, gcp-0 sets the same literal because it consumes it
    # (ADR-0022). A per-cluster override would misrepresent the design.
    "identity_provider_url": "https://auth.cluster.local",
    "route53_public_zone_id": "Z0123456789",
    "aws_account_id": "123456789012",
    "vpc_id": "vpc-0123456789abcdef0",
    "vpc_cidr_block": "10.0.0.0/16",
    # Must match vpc_cidr_block above: both clusters' ConfigMaps set
    # openbao_cidr from the same CIDR range in this fixture (AWS: whole VPC;
    # GCP: node subnet), so aws-0 renders byte-identical.
    "openbao_cidr": "10.0.0.0/16",
    # The lineage's snapshot bucket, consumed as BUCKET_NAME by the snapshot
    # CronJob. AWS value; gcp-0's ConfigMap carries a project-prefixed name.
    "openbao_snapshot_bucket": "eu-west-3-ogenki-openbao-snapshot",
    # security/base/openbao-endpoint/remote: the active OpenBao's fixed NLB
    # address a remote cluster proxies to. Only gcp-0 applies that directory.
    "openbao_target_ip": "10.0.15.250",
    # apps/base/ai/llm/hf-token-externalsecret.yaml. AWS value, same reasoning
    # as openbao_snapshot_secret above: without this entry VAR_RE.sub passes
    # the name through verbatim and the ExternalSecret extracts nothing --
    # schema-valid, useless.
    "llm_hf_token_secret": "/platform/llm/hf_token",  # pragma: allowlist secret
    "oidc_provider_arn": "arn:aws:iam::123456789012:oidc-provider/oidc.eks",
    "oidc_issuer_host": "oidc.eks.eu-west-3.amazonaws.com",
    "oidc_issuer_url": "https://oidc.eks.eu-west-3.amazonaws.com",
    "cluster_endpoint_full": "https://example.eks.amazonaws.com",
    "karpenter_queue_name": "karpenter-foobar",
    # GCP. Without these, VAR_RE.sub passes the name through verbatim and CI
    # renders GCP manifests still containing a literal ${project_id}. They pass
    # gate 1 anyway — every target field is a free-form string — so the GCP
    # substitution path would be validated without ever being exercised, which is
    # the silent skip SPEC-007 exists to prevent.
    "project_id": "ogenki-435905",
    # Unquoted on purpose: this is what Flux actually substitutes, and a bare
    # 12-digit number parses as an int downstream. Keeping the fixture faithful
    # is what lets CI catch a consumer that assumes a string.
    "project_number": "323586397743",
    "workload_pool": "ogenki-435905.svc.id.goog",
    "zone": "europe-west4-a",
    "network_name": "vpc-foobar",
    # Federated Route53 path (workstream 12). GCP-only: aws-0 authenticates to
    # Route53 with ambient EKS Pod Identity credentials and has no equivalent
    # variable. public_domain_name and route53_public_zone_id above already
    # cover the two AWS-named keys this fixture shares with the AWS ones.
    "route53_role_arn": "arn:aws:iam::123456789012:role/gcp-0-route53-dns",
    # A dedicated AWS-region hint for the route53 solver, deliberately distinct
    # from "region" above -- reusing that key would need the fixture to be an
    # AWS region for aws-0 and a GCP region for gcp-0, and this single map
    # cannot tell which cluster is rendering. So it stays AWS-shaped for both,
    # which means the gcp-0 bundle would render a region that cluster never
    # substitutes -- the blind spot that let `region: ${region}` reach review.
    # See opentofu/gcp/gke/configure's var.route53_region for why the two keys
    # must never collapse into one.
    "route53_region": "eu-west-3",
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


# Values that genuinely differ per cluster. FIXTURE_VARS above stays the merged
# map and remains AWS-shaped, because most of the repo is aws-0 and because
# base/ roots are rendered from it -- they belong to no cluster, appearing as
# roots only because top_most_overlays() treats a nested-but-unreferenced dir as
# one, and nothing deploys them.
#
# This makes the gcp-0 bundle honest; it does NOT make it a gate. A wrong GCP
# value is still a string to the schema validator, exactly as a wrong AWS one
# is. What catches an undefined variable is check-substitution.py, which reads
# each cluster's real ConfigMap and walks the cluster graph rather than guessing
# a cluster from a path.
CLUSTER_FIXTURE_VARS = {
    # aws-0 needs no overrides: the merged map is already AWS-shaped.
    "aws-0": {},
    "gcp-0": {
        "region": "europe-west4",
        "private_domain_name": "priv.gcp.cluster.local",
        # NOT route53_region. That one is AWS-shaped on gcp-0 ON PURPOSE -- it
        # is the AWS region hint the Route53 solver needs, and gcp-0 really does
        # substitute an AWS region there. See opentofu/gcp/gke/configure's
        # var.route53_region, and the comment on route53_region above.
    },
}


def cluster_of(path):
    """Cluster a bundle path belongs to, or None for base/ and anything else.

    Paths are `<area>/<cluster>/...` (security/gcp-0/openbao-snapshot) or
    `<area>/base/...`. Anything unrecognised -- including a new area directory
    -- returns None and gets the merged map, so an unfamiliar layout degrades to
    today's behaviour instead of breaking the render.
    """
    parts = str(path).replace("\\", "/").split("/")
    if len(parts) >= 2 and parts[1] in CLUSTER_FIXTURE_VARS:
        return parts[1]
    return None


def substitute(text, cluster=None):
    """Replace ${var} with fixture values. `$${var}` is Flux's escape - leave it.

    `cluster` selects the per-cluster overrides; None means the merged map.
    """
    fixtures = FIXTURE_VARS
    overrides = CLUSTER_FIXTURE_VARS.get(cluster) if cluster else None
    if overrides:
        fixtures = {**FIXTURE_VARS, **overrides}
    text = text.replace("$${", "\x00{")
    text = VAR_RE.sub(lambda m: fixtures.get(m.group(1), m.group(0)), text)
    return text.replace("\x00{", "$${")


def load_docs_text(text):
    """Parse a rendered multi-doc YAML string. Mirrors load_docs, which reads
    from a path — chart extraction now works on kustomize output held in
    memory rather than on a file."""
    return [d for d in yaml.safe_load_all(text) if isinstance(d, dict)]


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
    (infrastructure/aws-0/crossplane/*, security/aws-0/zitadel,
    observability/aws-0/victoria-metrics-k8s-stack). The old
    `no ancestor kustomization` rule silently dropped that second class from
    both render paths, contradicting SPEC-007's no-silent-skips guarantee.

    This is a filesystem heuristic that approximates the true source of truth —
    the `spec.path` of every Flux Kustomization under clusters/. Deriving roots
    from those directly would be more exact but couples the renderer to the
    cluster's Kustomization graph (base-vs-overlay, suspended siblings, multiple
    clusters).

    NOTHING PINS THE KNOWN NESTED CASES. An earlier version of this docstring
    said "test-flux-schema.sh pins the known nested cases as a safety net";
    that file has never existed in this repo. A docstring asserting a safety
    net that is absent is worse than silence, because it reads as covered and
    nobody re-checks -- the same shape as a Renovate annotation that matches
    nothing. test-check-substitution.py covers the undefined-variable gate,
    not this heuristic. If a nested overlay is ever dropped from the bundle,
    only the resource count moving will show it."""
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
        for path in sorted(base.rglob("*.yaml")):
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
        for kfile in sorted(base.rglob("kustomization.yaml")):
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


def overlay_slug(overlay):
    """Stable filename fragment for an overlay path. Shared by the overlay file
    and its charts so the two are greppable together in the bundle."""
    return str(overlay).replace("/", "-")


def render_overlay(overlay, outdir):
    """Build one overlay. Returns (error, rendered_text).

    The returned text is postprocessed but NOT substituted, because it feeds
    two consumers with different needs: the bundle file (substituted, so gate 1
    sees realistic values) and chart extraction in main(), which wants the
    HelmRelease exactly as `render_helmrelease` has always received it. Feeding
    substituted values to `helm template` would change what every chart renders
    — a behaviour change well beyond fixing the dedupe key."""
    result = subprocess.run(
        [KUSTOMIZE_BIN, "build", str(overlay), "--load-restrictor=LoadRestrictionsNone"],
        capture_output=True,
        text=True,
        timeout=300,
    )
    if result.returncode != 0:
        return _last_line(result, "kustomize build failed"), None
    try:
        rendered = postprocess(result.stdout)
    except yaml.YAMLError as exc:
        return f"postprocess: {exc}", None
    (outdir / ("overlay-" + overlay_slug(overlay) + ".yaml")).write_text(
        substitute(rendered, cluster_of(overlay))
    )
    return None, rendered


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


def effective_namespace(doc, kustomize_namespace):
    """metadata.namespace > enclosing kustomization's namespace transformer >
    "default". Shared by render_helmrelease and the duplicate-variant dedupe
    key in main() - they MUST agree, since the key decides which variant is
    rendered under the chart-<ns>-<name>.yaml filename this resolves."""
    return doc["metadata"].get("namespace") or kustomize_namespace or "default"


def render_helmrelease(doc, sources, outdir, namespace, stem):
    """`stem` is the bundle filename fragment identifying WHICH rendering this
    is — `<overlay-slug>` for a chart reached through an overlay, or `direct`
    for a HelmRelease no overlay covers. It exists because one release name can
    legitimately render twice with different values: aws-0 and gcp-0 both
    resolve external-dns to kube-system/external-dns, and keying the output on
    (namespace, name) alone meant only one of them ever reached
    `helm template`."""
    meta, spec = doc["metadata"], doc["spec"]
    namespace = effective_namespace(doc, namespace)

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

    # stem is overlay_slug(overlay), i.e. the path with "/" replaced by "-".
    # Restoring the first separator is enough for cluster_of, which only reads
    # the second segment.
    (outdir / f"chart-{stem}-{namespace}-{meta['name']}.yaml").write_text(
        substitute(rendered, cluster_of(stem.replace("-", "/", 1)))
    )
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
        for path in sorted(base.rglob("*.yaml")):
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
                    resolved = path.resolve()
                    kustomize_ns = namespaces.get(resolved)
                    key = (effective_namespace(doc, kustomize_ns), doc["metadata"]["name"])
                    is_referenced = resolved in referenced
                    prev = helmreleases.get(key)
                    if prev and prev[2] and not is_referenced:
                        print(
                            f"note: duplicate HelmRelease/{key[0]}/{key[1]}: skipping "
                            f"unreferenced variant {path} (a kustomization references the other)",
                            file=sys.stderr,
                        )
                        continue
                    if prev:
                        print(
                            f"note: duplicate HelmRelease/{key[0]}/{key[1]}: rendering {path} "
                            "(kustomization-referenced, or last in scan order)",
                            file=sys.stderr,
                        )
                    helmreleases[key] = (doc, kustomize_ns, is_referenced)
            if not in_overlay and docs:
                (outdir / ("standalone-" + str(path).replace("/", "-"))).write_text(
                    substitute(path.read_text(), cluster_of(path))
                )
                standalone += 1

    # Overlays FIRST, charts second — a deliberate serialization.
    #
    # Charts used to be discovered by scanning raw files and deduped by
    # (effective namespace, name). That key is not unique across clusters: both
    # aws-0 and gcp-0 resolve external-dns to kube-system/external-dns, so only
    # ONE set of values ever reached `helm template`. Worse, the GCP variant is
    # a patch fragment with no `chart:`, so it was never even a candidate and
    # produced no "duplicate" note — it was skipped in silence. A values-shape
    # error on that release could not fail the build.
    #
    # Rendering from each overlay's OWN output fixes that by construction: the
    # overlay has already merged base + patches, so what we template is what
    # that cluster actually gets. The cost is wall-clock — charts consumed by
    # both clouds now render twice — and a bundle keyed by overlay.
    with concurrent.futures.ThreadPoolExecutor(max_workers=MAX_WORKERS) as pool:
        overlay_futures = [(o, pool.submit(render_overlay, o, outdir)) for o in overlays]
        overlay_docs = []
        for overlay, future in overlay_futures:
            error, rendered = future.result()
            if error:
                errors.append(f"kustomize {overlay}: {error}")
                continue
            overlay_docs.append((overlay, rendered))

    # Chart tasks, one per (overlay, namespace, name).
    chart_tasks = []
    seen = set()
    for overlay, rendered in overlay_docs:
        stem = overlay_slug(overlay)
        for doc in load_docs_text(rendered):
            spec = doc.get("spec") or {}
            if doc.get("kind") != "HelmRelease" or not (spec.get("chart") or spec.get("chartRef")):
                continue
            # An overlay's output already carries the kustomization's namespace
            # transformer, so metadata.namespace is authoritative here.
            ns = doc["metadata"].get("namespace") or "default"
            chart_tasks.append((doc, ns, stem))
            seen.add((ns, doc["metadata"]["name"]))

    # Fallback: a HelmRelease no overlay covers still has to be rendered, or
    # this change would quietly shrink coverage while looking like a fix. Every
    # one is logged rather than assumed absent.
    for (ns, name), (doc, kustomize_ns, _referenced) in helmreleases.items():
        if (ns, name) in seen:
            continue
        print(
            f"note: HelmRelease/{ns}/{name} is not reached by any overlay; "
            f"rendering it directly from its source file",
            file=sys.stderr,
        )
        chart_tasks.append((doc, kustomize_ns, "direct"))

    with concurrent.futures.ThreadPoolExecutor(max_workers=MAX_WORKERS) as pool:
        chart_futures = [
            pool.submit(render_helmrelease, doc, sources, outdir, ns, stem)
            for doc, ns, stem in chart_tasks
        ]
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
