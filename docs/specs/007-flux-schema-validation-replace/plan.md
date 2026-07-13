# Plan: Flux schema validation — replace kubeconform/Datree, render Kustomize+Helm into one validated bundle

**Spec**: [SPEC-007](spec.md)
**Status**: draft
**Last updated**: 2026-07-13

> The **plan** covers *HOW* to deliver the spec. It may evolve during implementation (unlike `spec.md`, which freezes after approval). Append-only `clarifications.md` is where decisions are durable.

> **For agentic workers:** REQUIRED SUB-SKILL: use `superpowers:subagent-driven-development` (recommended) or `superpowers:executing-plans` to implement task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** One renderer, two enforcing gates — `flux schema validate` with zero silent skips, and `polaris audit` over the workloads the platform actually runs.

**Architecture:** A render step turns the repository into a single bundle (every Kustomize overlay with Flux `postBuild` vars substituted, plus every HelmRelease rendered with its own values). That bundle feeds both gates. A generated schema catalog — built at run time from the repo's own XRDs and the Envoy AI Gateway CRDs — is layered under the hosted ecosystem catalog so no resource resolves to "no schema".

**Tech Stack:** `flux` 2.9.2 + `flux-schema` v0.10.2 plugin, `helm`, `kustomize`, `polaris` 8.5.0, Python 3 (stdlib + PyYAML), Bash.

## Global Constraints

- `flux` **2.9.2** (2.8.x has no `flux plugin` subcommand), `flux-schema` **v0.10.2**.
- `flux schema validate` runs with **`skipMissingSchemas: false`** — this is the point of the spec (FR-005).
- Schema catalog is **generated, never committed** (FR-002) — a committed catalog drifts from the XRDs.
- Validation targets **rendered output, never raw files** (CL-1) — patch fragments cannot satisfy a full schema.
- The bundle is **rendered fresh each CI run**; only the Helm download cache is cached (CL-2).
- Scripts are `shellcheck -S warning` clean — CI enforces it on `scripts/**.sh`.

---

## Design

### Data flow

```
                    ┌─ infrastructure/ security/ observability/
                    │  tooling/ apps/ clusters/ flux/ namespaces/
                    ▼
        scripts/flux-schema/render-bundle.py
          ├─ kustomize build (top-most overlays)  ──► envsubst (CI fixture vars)
          ├─ helm template   (41 HelmReleases, each with its own spec.values)
          └─ standalone manifests (outside any kustomize dir)
                    │
                    ▼
              .bundle/ (gitignored)
                    │
        ┌───────────┴────────────┐
        ▼                        ▼
  flux schema validate      polaris audit
   (structure + CEL)      (workload best practice)
   -s ./.schemas           --config .polaris.yaml
   -s default              --set-exit-code-on-danger
   -s ecosystem
   skipMissingSchemas:false
        ▲
        │
  .schemas/ (gitignored) ◄── scripts/flux-schema/gen-catalog.sh
                                ├─ 4 XRDs ─► xrd-to-crd.py ─► flux schema extract crd
                                └─ Envoy AI Gateway CRDs ──► flux schema extract crd
```

### File structure

```
.fluxschema.yml                          # NEW — shared by CI, humans, agents (FR-005, FR-006)
.gitignore                               # MODIFY — ignore .schemas/ and .bundle/
mise.toml                                # MODIFY — pin flux 2.9.2, helm, kustomize (FR-001)
.mcp.json                                # MODIFY — schemas.fluxoperator.dev MCP (FR-012)
scripts/
├── validate-manifests.sh                # NEW — single entry point: catalog → render → 2 gates (FR-010)
├── test-flux-schema.sh                  # NEW — test suite (mirrors scripts/test-vector-vrl.sh)
└── flux-schema/
    ├── xrd-to-crd.py                    # NEW — XRD → CRD + Crossplane-injected fields (FR-003)
    ├── gen-catalog.sh                   # NEW — build .schemas/ from XRDs + AI-GW CRDs (FR-002)
    └── render-bundle.py                 # NEW — kustomize+envsubst+helm → .bundle/ (FR-004)
.github/workflows/ci.yaml                # MODIFY — drop kubeconform+Checkov-k8s, add gates (FR-007, FR-008)
CLAUDE.md                                # MODIFY — Validation Commands (FR-011)
.claude/rules/process.md                 # MODIFY — evidence table (FR-011)
infrastructure/base/crossplane/configuration/examples/
├── inferenceservice-complete.yaml       # MODIFY — undeclared route fields (FR-009)
├── sqlinstance-basic.yaml               # MODIFY — missing required fields (FR-009)
└── epi.yaml                             # MODIFY — stale claimRef (FR-009)
```

### Key entities

- **`.schemas/`** — generated JSON-Schema catalog, layout `{group}/{kind}_{version}.json`. Gitignored.
- **`.bundle/`** — rendered YAML, one file per overlay/chart. Gitignored. Input to both gates.
- **Fixture vars** — the same substitution values CI passes to kubeconform today: `domain_name=cluster.local`, `private_domain_name=priv.cluster.local`, `public_domain_name=cluster.local`, `cluster_name=foobar`, `region=eu-west-3`, `environment=dev`, `cert_manager_approle_id=random`, `route53_public_zone_id=Z0123456789`.

### Dependencies

- [x] `flux` 2.9.2 and `flux-schema` v0.10.2 exist (verified 2026-07-13).
- [x] Ecosystem catalog resolves all repo kinds except the 4 `cloud.ogenki.io` + 4 `aigateway.envoyproxy.io` (spike-verified).
- [x] `.polaris.yaml` already tuned with `danger`/`warning` levels — reused as-is.

### Alternatives considered

The upstream `fluxcd/flux-schema` composite action was rejected: it has no `envsubst` hook (FR-004 needs one) and its `helm-charts` input renders only local `Chart.yaml` charts, of which this repo has zero. Committing the schema catalog was rejected because it drifts from the XRDs. Full deliberation in CL-1 and CL-2.

---

## Implementation Notes

- **Crossplane injects `spec.crossplane`** into the CRDs it generates from XRDs (v2 moved composition refs there). The converter must add it or `tooling/base/harbor/sqlinstance.yaml` and `security/base/zitadel/sqlinstance.yaml` report false `additional properties 'crossplane' not allowed` (spike-observed). See FR-003.
- **`sourceRef.namespace` defaults to the HelmRelease's own namespace** in Flux, not `flux-system`. The spike hardcoded `flux-system` and resolved only 19 of 33 charts. Resolve with fallback: `(name, sourceRef.namespace or hr.namespace)`, then `(name, "flux-system")`.
- **Some charts gate on `kubeVersion`** — Zitadel requires `>= 1.30.0-0`. Pass `--kube-version` to `helm template`.
- **Only top-most Kustomize dirs are built** (a dir with no ancestor `kustomization.yaml`), otherwise nested bases render twice and Polaris double-counts.
- **`kustomize build` needs `--load-restrictor=LoadRestrictionsNone`**, matching upstream's `validate.sh`.

### Validation path

- `./scripts/test-flux-schema.sh` passes (unit tests for the converter and renderer)
- `./scripts/validate-manifests.sh` exits 0, report shows 0 `schema-not-found`
- `shellcheck -S warning scripts/**/*.sh` clean
- CI green on the branch

---

## Tasks

> Each task has a stable ID (`T001`, `T002`, …) — committable unit, referenced by PRs and `/verify-spec`. Before marking `[x]`, cite fresh evidence (see [`.claude/rules/process.md`](../../../.claude/rules/process.md)).

**Task index** — tick here as each task's detailed steps below are completed and evidenced.

- [ ] **T001**: Pin the toolchain — flux 2.9.2, helm, kustomize; gitignore `.schemas/` and `.bundle/` (FR-001)
- [ ] **T002**: XRD → CRD converter, injecting Crossplane's `spec.crossplane` fields (FR-002, FR-003)
- [ ] **T003**: Generate the schema catalog from the 4 XRDs + Envoy AI Gateway CRDs (FR-002)
- [ ] **T004**: Render the bundle — kustomize overlays + envsubst + `helm template` (FR-004)
- [ ] **T005**: `.fluxschema.yml` with `skipMissingSchemas: false`, plus the `validate-manifests.sh` entry point (FR-005, FR-006, FR-007, FR-010)
- [ ] **T006**: Rewire CI — drop both kubeconform steps, make Polaris enforcing, drop Checkov's `kubernetes` framework (FR-007, FR-008)
- [ ] **T007**: Fix the three real defects the spike found in the Crossplane examples (FR-009)
- [ ] **T008**: Prove both gates fail on injected defects before trusting their green (SC-002, SC-003)
- [ ] **T009**: Documentation — `CLAUDE.md` and `.claude/rules/process.md` still name kubeconform (FR-011)
- [ ] **T010**: Agent layer — schema MCP server, gitops-skills 0.0.2 → v0.1.0 (FR-012)

### Phase 1: Toolchain

#### T001 — Pin the toolchain (FR-001)

**Files:** Modify `mise.toml`; Modify `.gitignore`

- [ ] **Step 1: Add the tools to `mise.toml`**

```toml
[tools]
nodejs = "22.22.1"
opentofu = "1.12.3"
pre-commit = "4.6.0"
trivy = "0.72.0"
"ubi:terramate-io/terramate" = "0.17.1"
flux2 = "2.9.2"
helm = "3.16.4"
kustomize = "5.4.3"
```

- [ ] **Step 2: Ignore generated artifacts** — append to `.gitignore`

```gitignore
# SPEC-007: generated at validation time, never committed
.schemas/
.bundle/
```

- [ ] **Step 3: Install and verify the plugin**

Run:
```bash
mise install && flux version --client && flux plugin install schema && flux plugin list
```
Expected: `flux: v2.9.2`, and `flux plugin list` prints a row `schema  0.10.2`.

- [ ] **Step 4: Commit**

```bash
git add mise.toml .gitignore
git commit -m "build: pin flux 2.9.2, helm, kustomize; ignore generated schema/bundle dirs"
```

---

### Phase 2: Schema catalog

#### T002 — XRD → CRD converter (FR-002, FR-003)

**Files:** Create `scripts/flux-schema/xrd-to-crd.py`; Create `scripts/test-flux-schema.sh`

**Interfaces:**
- Produces: CLI `python3 scripts/flux-schema/xrd-to-crd.py <xrd.yaml>...` → multi-doc CRD YAML on stdout. Consumed by `gen-catalog.sh` (T003).

- [ ] **Step 1: Write the failing test** — create `scripts/test-flux-schema.sh`

```bash
#!/usr/bin/env bash
# Test suite for the SPEC-007 flux-schema tooling.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

fail=0
check() {
  local name="$1" expected="$2" actual="$3"
  if [[ "$actual" == *"$expected"* ]]; then
    echo "  PASS  $name"
  else
    echo "  FAIL  $name"
    echo "        expected to contain: $expected"
    echo "        got: $actual"
    fail=1
  fi
}

echo "== xrd-to-crd =="
out="$(python3 scripts/flux-schema/xrd-to-crd.py \
  infrastructure/base/crossplane/configuration/app-definition.yaml)"

check "emits a CustomResourceDefinition" "kind: CustomResourceDefinition" "$out"
check "preserves the group"              "group: cloud.ogenki.io"          "$out"
check "preserves the kind"               "kind: App"                       "$out"
check "injects spec.crossplane"          "crossplane:"                     "$out"
check "injects compositionRef"           "compositionRef:"                 "$out"

exit "$fail"
```

- [ ] **Step 2: Run it and watch it fail**

Run: `chmod +x scripts/test-flux-schema.sh && ./scripts/test-flux-schema.sh`
Expected: FAIL — `python3: can't open file 'scripts/flux-schema/xrd-to-crd.py': No such file or directory`

- [ ] **Step 3: Implement the converter** — create `scripts/flux-schema/xrd-to-crd.py`

```python
#!/usr/bin/env python3
"""Convert Crossplane CompositeResourceDefinitions into CustomResourceDefinitions.

`flux schema extract crd` reads CRDs, not XRDs. The shapes are nearly identical,
but Crossplane injects fields into the CRDs it generates that the XRD never
declares — notably `spec.crossplane`. Omitting them makes in-use manifests
(harbor/zitadel SQLInstance) fail validation with
`additional properties 'crossplane' not allowed`. See SPEC-007 FR-003.
"""
import sys
import pathlib
import yaml

# Fields Crossplane v2 injects into every generated composite/XR CRD.
CROSSPLANE_INJECTED = {
    "crossplane": {
        "type": "object",
        "properties": {
            "compositionRef": {
                "type": "object",
                "properties": {"name": {"type": "string"}},
            },
            "compositionRevisionRef": {
                "type": "object",
                "properties": {"name": {"type": "string"}},
            },
            "compositionSelector": {
                "type": "object",
                "properties": {
                    "matchLabels": {
                        "type": "object",
                        "additionalProperties": {"type": "string"},
                    }
                },
            },
            "compositionRevisionSelector": {
                "type": "object",
                "properties": {
                    "matchLabels": {
                        "type": "object",
                        "additionalProperties": {"type": "string"},
                    }
                },
            },
            "compositionUpdatePolicy": {"type": "string"},
            "resourceRefs": {"type": "array", "items": {"type": "object"}},
        },
    }
}


def convert(xrd):
    spec = xrd["spec"]
    versions = []
    for version in spec["versions"]:
        schema = version["schema"]["openAPIV3Schema"]
        props = schema.setdefault("properties", {})
        spec_props = props.setdefault("spec", {"type": "object"}).setdefault(
            "properties", {}
        )
        for name, definition in CROSSPLANE_INJECTED.items():
            spec_props.setdefault(name, definition)
        versions.append(
            {
                "name": version["name"],
                "served": version.get("served", True),
                "storage": True,
                "schema": {"openAPIV3Schema": schema},
            }
        )
    return {
        "apiVersion": "apiextensions.k8s.io/v1",
        "kind": "CustomResourceDefinition",
        "metadata": {"name": xrd["metadata"]["name"]},
        "spec": {
            "group": spec["group"],
            "scope": spec.get("scope", "Namespaced"),
            "names": spec["names"],
            "versions": versions,
        },
    }


def main():
    crds = []
    for path in sys.argv[1:]:
        for doc in yaml.safe_load_all(pathlib.Path(path).read_text()):
            if doc and doc.get("kind") == "CompositeResourceDefinition":
                crds.append(convert(doc))
    if not crds:
        print("error: no CompositeResourceDefinition found", file=sys.stderr)
        return 1
    yaml.safe_dump_all(crds, sys.stdout, sort_keys=False)
    return 0


if __name__ == "__main__":
    sys.exit(main())
```

- [ ] **Step 4: Run the test and watch it pass**

Run: `./scripts/test-flux-schema.sh`
Expected: 5 × `PASS`, exit 0.

- [ ] **Step 5: Commit**

```bash
git add scripts/flux-schema/xrd-to-crd.py scripts/test-flux-schema.sh
git commit -m "feat(validation): convert Crossplane XRDs to CRDs for schema extraction"
```

---

#### T003 — Generate the schema catalog (FR-002)

**Files:** Create `scripts/flux-schema/gen-catalog.sh`; Modify `scripts/test-flux-schema.sh`

**Interfaces:**
- Consumes: `xrd-to-crd.py` (T002).
- Produces: `./.schemas/` populated with `cloud.ogenki.io/*.json` and `aigateway.envoyproxy.io/*.json`. Consumed by `validate-manifests.sh` (T005).

- [ ] **Step 1: Add the failing test** — append to `scripts/test-flux-schema.sh` before `exit "$fail"`

```bash
echo "== gen-catalog =="
rm -rf .schemas
./scripts/flux-schema/gen-catalog.sh >/dev/null

for kind in app sqlinstance inferenceservice epi; do
  if [[ -f ".schemas/cloud.ogenki.io/${kind}_v1alpha1.json" ]]; then
    echo "  PASS  catalog has cloud.ogenki.io/${kind}"
  else
    echo "  FAIL  catalog missing cloud.ogenki.io/${kind}_v1alpha1.json"
    fail=1
  fi
done

if compgen -G ".schemas/aigateway.envoyproxy.io/*.json" >/dev/null; then
  echo "  PASS  catalog has aigateway.envoyproxy.io schemas"
else
  echo "  FAIL  catalog missing aigateway.envoyproxy.io schemas"
  fail=1
fi
```

- [ ] **Step 2: Run and watch it fail**

Run: `./scripts/test-flux-schema.sh`
Expected: FAIL — `./scripts/flux-schema/gen-catalog.sh: No such file or directory`

- [ ] **Step 3: Implement** — create `scripts/flux-schema/gen-catalog.sh`

```bash
#!/usr/bin/env bash
# Build the local JSON-Schema catalog consumed by `flux schema validate`.
#
# Two sources (SPEC-007 FR-002):
#   1. The repo's own Crossplane XRDs  -> cloud.ogenki.io/*
#   2. Envoy AI Gateway CRDs           -> aigateway.envoyproxy.io/*
#      (absent from the hosted ecosystem catalog)
#
# The catalog is generated, never committed, so it cannot drift from the XRDs.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

SCHEMA_DIR="${SCHEMA_DIR:-.schemas}"

# Single source of truth: the same OCIRepository pin Flux uses to install the
# CRDs on the cluster. Renovate bumps that file; this script follows it.
AI_GATEWAY_SOURCE="flux/sources/ocirepo-envoy-ai-gateway-crds.yaml"
AI_GATEWAY_CHART="oci://docker.io/envoyproxy/ai-gateway-crds-helm"
AI_GATEWAY_VERSION="$(grep -oP 'tag:\s*"?\K[0-9][^"]*' "${AI_GATEWAY_SOURCE}" | tr -d '"')"

if [[ -z "${AI_GATEWAY_VERSION}" ]]; then
  echo "error: could not read the AI Gateway CRD chart version from ${AI_GATEWAY_SOURCE}" >&2
  exit 1
fi

rm -rf "${SCHEMA_DIR}"
mkdir -p "${SCHEMA_DIR}"

tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

echo "==> Converting Crossplane XRDs to CRDs"
python3 scripts/flux-schema/xrd-to-crd.py \
  infrastructure/base/crossplane/configuration/*-definition.yaml \
  > "${tmp}/xrd-crds.yaml"

echo "==> Rendering Envoy AI Gateway CRDs (chart ${AI_GATEWAY_VERSION})"
helm template aigw-crds "${AI_GATEWAY_CHART}" --version "${AI_GATEWAY_VERSION}" \
  > "${tmp}/aigateway-crds.yaml"

echo "==> Extracting JSON Schemas into ${SCHEMA_DIR}/"
flux schema extract crd "${tmp}/xrd-crds.yaml" -d "${SCHEMA_DIR}"
flux schema extract crd "${tmp}/aigateway-crds.yaml" -d "${SCHEMA_DIR}"

find "${SCHEMA_DIR}" -name '*.json' | sort
```

> Verified 2026-07-13: `helm template oci://docker.io/envoyproxy/ai-gateway-crds-helm --version 1.0.0` renders 6 CRDs, and `flux/sources/ocirepo-envoy-ai-gateway-crds.yaml` pins `tag: "1.0.0"`.

- [ ] **Step 4: Run and watch it pass**

Run: `chmod +x scripts/flux-schema/gen-catalog.sh && ./scripts/test-flux-schema.sh`
Expected: the 4 `cloud.ogenki.io` PASS lines plus the `aigateway.envoyproxy.io` PASS line.

> If the chart render fails, fix the version resolution — do not fall back to `--skip-missing-schemas`, which reintroduces the exact bug this spec removes.

- [ ] **Step 5: Commit**

```bash
git add scripts/flux-schema/gen-catalog.sh scripts/test-flux-schema.sh
git commit -m "feat(validation): generate schema catalog from XRDs and Envoy AI Gateway CRDs"
```

---

### Phase 3: Renderer

#### T004 — Render the bundle (FR-004, CL-1, CL-2)

**Files:** Create `scripts/flux-schema/render-bundle.py`; Modify `scripts/test-flux-schema.sh`

**Interfaces:**
- Produces: CLI `python3 scripts/flux-schema/render-bundle.py <outdir>` → one YAML file per overlay/chart/standalone; prints `RENDER: overlays=N charts=N standalone=N failed=N`; exits non-zero if any render fails. Consumed by `validate-manifests.sh` (T005).

- [ ] **Step 1: Add the failing test** — append to `scripts/test-flux-schema.sh` before `exit "$fail"`

```bash
echo "== render-bundle =="
rm -rf .bundle
render_out="$(python3 scripts/flux-schema/render-bundle.py .bundle)"
echo "${render_out}"

check "renders with no failures" "failed=0" "${render_out}"

workloads="$(grep -rhc '^kind: \(Deployment\|StatefulSet\|DaemonSet\|Job\)$' .bundle/*.yaml 2>/dev/null | paste -sd+ | bc)"
if [[ "${workloads:-0}" -ge 30 ]]; then
  echo "  PASS  bundle exposes ${workloads} workloads to Polaris (SC-005: >= 30)"
else
  echo "  FAIL  bundle exposes only ${workloads:-0} workloads (SC-005 requires >= 30)"
  fail=1
fi
```

- [ ] **Step 2: Run and watch it fail**

Run: `./scripts/test-flux-schema.sh`
Expected: FAIL — `render-bundle.py: No such file or directory`

- [ ] **Step 3: Implement** — create `scripts/flux-schema/render-bundle.py`

```python
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
                if doc.get("kind") not in ("HelmRepository", "OCIRepository"):
                    continue
                meta, spec = doc.get("metadata", {}), doc.get("spec", {})
                key = (meta.get("name"), meta.get("namespace", "flux-system"))
                sources[key] = spec
    return sources


def resolve_source(sources, source_ref, hr_namespace):
    """sourceRef.namespace defaults to the HelmRelease's namespace, not flux-system."""
    name = source_ref.get("name")
    for namespace in (source_ref.get("namespace"), hr_namespace, "flux-system"):
        if namespace and (name, namespace) in sources:
            return sources[(name, namespace)]
    return None


def render_overlay(overlay, outdir):
    result = subprocess.run(
        ["kustomize", "build", str(overlay), "--load-restrictor=LoadRestrictionsNone"],
        capture_output=True,
        text=True,
        timeout=300,
    )
    if result.returncode != 0:
        return result.stderr.strip().splitlines()[-1][:200]
    name = "overlay-" + str(overlay).replace("/", "-") + ".yaml"
    (outdir / name).write_text(substitute(result.stdout))
    return None


def render_helmrelease(doc, sources, outdir):
    meta, spec = doc["metadata"], doc["spec"]
    namespace = meta.get("namespace", "default")
    chart_spec = spec.get("chart", {}).get("spec", {})
    source = resolve_source(sources, chart_spec.get("sourceRef", {}), namespace)
    if not source or not source.get("url"):
        return f"unresolved chart source for HelmRelease/{namespace}/{meta['name']}"

    url, chart, version = source["url"], chart_spec.get("chart"), chart_spec.get("version")
    is_oci = source.get("type") == "oci" or url.startswith("oci://")

    with tempfile.NamedTemporaryFile("w", suffix=".yaml", delete=False) as handle:
        yaml.safe_dump(spec.get("values") or {}, handle)
        values_file = handle.name

    cmd = [
        "helm", "template", meta["name"],
        f"{url.rstrip('/')}/{chart}" if is_oci else chart,
        "--namespace", namespace,
        "--values", values_file,
        "--include-crds",
        "--skip-tests",
        "--kube-version", KUBE_VERSION,
    ]
    if not is_oci:
        cmd += ["--repo", url]
    if version:
        cmd += ["--version", version]

    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=300)
    finally:
        os.unlink(values_file)

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
                    error = render_helmrelease(doc, sources, outdir)
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
```

- [ ] **Step 4: Run and watch it pass**

Run: `./scripts/test-flux-schema.sh`
Expected: `RENDER: overlays=… charts=… standalone=… failed=0`, and `PASS bundle exposes ≥30 workloads`.

> Every chart must resolve. If any report `unresolved chart source`, fix `resolve_source` — do not skip the chart. A skipped chart is a workload Polaris cannot see, which is the bug this spec exists to fix.

- [ ] **Step 5: Commit**

```bash
git add scripts/flux-schema/render-bundle.py scripts/test-flux-schema.sh
git commit -m "feat(validation): render kustomize overlays and HelmReleases into one bundle"
```

---

### Phase 4: Gates

#### T005 — `.fluxschema.yml` + the single entry point (FR-005, FR-006, FR-007, FR-010)

**Files:** Create `.fluxschema.yml`; Create `scripts/validate-manifests.sh`

**Interfaces:**
- Consumes: `gen-catalog.sh` (T003), `render-bundle.py` (T004).
- Produces: `./scripts/validate-manifests.sh` — exit 0 iff both gates pass. Consumed by CI (T006).

- [ ] **Step 1: Create `.fluxschema.yml`**

```yaml
# Shared by CI, humans, and AI agents. See docs/specs/007-flux-schema-validation-replace/
apiVersion: schema.plugin.fluxcd.io/v1beta1
kind: Config
validate:
  # Order matters: our generated catalog wins, then Flux's built-in, then the
  # hosted CNCF ecosystem catalog (rebuilt daily from upstream releases).
  schemaLocation:
    - ./.schemas
    - default
    - ecosystem
  # The entire point of SPEC-007: an unknown kind fails the build instead of
  # passing silently, as it did under kubeconform's -ignore-missing-schemas.
  skipMissingSchemas: false
  skipFile:
    - '.*'                     # dotfiles and dot-dirs
    - kustomization.yaml       # kustomize build inputs, not Kubernetes objects
    - settings-example.yaml    # KCL module settings, not Kubernetes objects
  verbose: false
  output: text
```

- [ ] **Step 2: Create `scripts/validate-manifests.sh`**

```bash
#!/usr/bin/env bash
# Single entry point for Kubernetes manifest validation (SPEC-007 FR-010).
#
# Runs the same three steps locally and in CI, so "it validates" is a claim
# backed by a command anyone — human or agent — can reproduce:
#   1. generate the schema catalog (XRDs + Envoy AI Gateway CRDs)
#   2. render the repo into a bundle (kustomize + envsubst + helm template)
#   3. gate the bundle: flux schema validate, then polaris audit
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

BUNDLE_DIR="${BUNDLE_DIR:-.bundle}"

echo "==> [1/3] Generating schema catalog"
./scripts/flux-schema/gen-catalog.sh > /dev/null

echo "==> [2/3] Rendering manifests into ${BUNDLE_DIR}/"
rm -rf "${BUNDLE_DIR}"
python3 scripts/flux-schema/render-bundle.py "${BUNDLE_DIR}"

echo "==> [3/3] Gate 1 — flux schema validate (structure + CEL)"
flux schema validate "${BUNDLE_DIR}" --config .fluxschema.yml

echo "==> [3/3] Gate 2 — polaris audit (workload best practices)"
polaris audit \
  --audit-path "${BUNDLE_DIR}" \
  --config .polaris.yaml \
  --set-exit-code-on-danger \
  --only-show-failed-tests

echo "==> All gates passed"
```

- [ ] **Step 3: Run it — expect failures from the real defects**

Run: `chmod +x scripts/validate-manifests.sh && ./scripts/validate-manifests.sh`
Expected: **non-zero**. Gate 1 reports the FR-009 defects (`parentGateway` not allowed, `instances` missing, `claimRef` not allowed). This is the tool proving it works — fix them in T007, not here.

- [ ] **Step 4: Confirm zero unknown kinds**

Run:
```bash
flux schema validate .bundle --config .fluxschema.yml -o json \
  | jq '[.report.results[] | select(.reason=="schema-not-found")] | length'
```
Expected: `0` — satisfies SC-001.

- [ ] **Step 5: Commit**

```bash
git add .fluxschema.yml scripts/validate-manifests.sh
git commit -m "feat(validation): add .fluxschema.yml and the validate-manifests entry point"
```

---

#### T006 — Rewire CI (FR-007, FR-008)

**Files:** Modify `.github/workflows/ci.yaml`

- [ ] **Step 1: Replace the whole `kubernetes-validation` job**

Delete both `kubeconform` Dagger steps, the `setup-polaris` step, and the `head -20 … || true` step. Replace the job with:

```yaml
  kubernetes-validation:
    name: Kubernetes validation ☸
    runs-on: ubuntu-latest
    steps:
      - name: Checkout
        uses: actions/checkout@v7

      - name: Install tools
        uses: jdx/mise-action@v2

      - name: Install the flux-schema plugin
        run: flux plugin install schema

      - name: Install Polaris
        uses: fairwindsops/polaris/.github/actions/setup-polaris@master
        with:
          version: '8.5.0'

      # Charts are version-pinned, so only the download layer is cached (CL-2).
      # The bundle itself is always rendered fresh — a stale bundle is a
      # silently-wrong green, the exact failure class SPEC-007 removes.
      - name: Cache Helm chart downloads
        uses: actions/cache@v4
        with:
          path: ~/.cache/helm
          key: helm-${{ hashFiles('**/helmrelease.yaml', 'flux/sources/**') }}
          restore-keys: helm-

      - name: Validate manifests (flux schema + polaris)
        run: ./scripts/validate-manifests.sh
```

- [ ] **Step 2: Drop Checkov's redundant `kubernetes` framework**

In the `security-scan` job, change the Checkov step's framework line:

```yaml
          framework: terraform,secrets
```

- [ ] **Step 3: Verify no kubeconform reference survives**

Run: `grep -rn "kubeconform\|head -20\|polaris validate" .github/workflows/ci.yaml || echo "CLEAN"`
Expected: `CLEAN` — satisfies SC-006.

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/ci.yaml
git commit -m "ci: replace kubeconform with flux schema; make polaris an enforcing gate"
```

---

### Phase 5: Defects, docs, agents

#### T007 — Fix the three real defects (FR-009)

**Files:** Modify `infrastructure/base/crossplane/configuration/examples/{inferenceservice-complete,sqlinstance-basic,epi}.yaml`

- [ ] **Step 1: Reproduce — the tool names each defect**

Run: `flux schema validate .bundle --config .fluxschema.yml 2>&1 | grep -A2 "is invalid"`
Expected: three failures — undeclared `spec.route.parentGateway*`; missing `spec.instances` / `spec.roles[0].superuser`; disallowed `spec.claimRef`.

- [ ] **Step 2: Fix each against the XRD, not against the error text**

For each, read the XRD (`*-definition.yaml`) and make the example conform:
- `inferenceservice-complete.yaml` — `spec.route.parentGateway` / `parentGatewayNamespace` are not in the XRD. Since SPEC-002 made routing composition-owned, remove them (do **not** add them to the XRD without a spec).
- `sqlinstance-basic.yaml` — add the `required` fields `spec.instances` and `spec.roles[0].superuser`.
- `epi.yaml` — remove `spec.claimRef` (Crossplane v2 XRDs are `scope: Namespaced`; claims no longer exist).

- [ ] **Step 3: Re-validate**

Run: `./scripts/validate-manifests.sh`
Expected: exit 0 — satisfies SC-001.

- [ ] **Step 4: Commit**

```bash
git add infrastructure/base/crossplane/configuration/examples
git commit -m "fix(crossplane): correct three example claims rejected by XRD schema validation"
```

---

#### T008 — Prove the gates actually fail (SC-002, SC-003)

**Files:** none committed — this task produces evidence, then reverts.

- [ ] **Step 1: Break a claim on purpose**

```bash
yq -i '.spec.notAFieldInTheXrd = "boom"' apps/base/ai/llm/*.yaml
./scripts/validate-manifests.sh; echo "exit=$?"
```
Expected: non-zero, naming `/spec: additional properties 'notAFieldInTheXrd' not allowed` — SC-002.

- [ ] **Step 2: Break a workload on purpose**

```bash
git checkout -- apps/base/ai/llm
printf 'apiVersion: apps/v1\nkind: Deployment\nmetadata:\n  name: bad\nspec:\n  selector:\n    matchLabels: {app: bad}\n  template:\n    metadata:\n      labels: {app: bad}\n    spec:\n      containers:\n      - name: c\n        image: nginx:1.27\n        securityContext:\n          allowPrivilegeEscalation: true\n' > .bundle/zz-bad.yaml
polaris audit --audit-path .bundle --config .polaris.yaml --set-exit-code-on-danger; echo "exit=$?"
```
Expected: non-zero — SC-003.

- [ ] **Step 3: Revert and confirm clean**

```bash
git checkout -- . && ./scripts/validate-manifests.sh && echo "GREEN"
```
Expected: `GREEN`.

- [ ] **Step 4: Record the evidence** in the PR description (both exit codes and the failing paths).

---

#### T009 — Documentation (FR-011)

**Files:** Modify `CLAUDE.md`; Modify `.claude/rules/process.md`

- [ ] **Step 1: `CLAUDE.md` — replace kubeconform in *Validation Commands***

```bash
tofu validate
trivy config --exit-code=1 --ignorefile=./.trivyignore.yaml .
./scripts/validate-manifests.sh          # flux schema (structure + CEL) + polaris (workloads)
kubectl get nodes && kubectl get pods --all-namespaces
flux get all
```

- [ ] **Step 2: `.claude/rules/process.md` — add the row to the evidence table**

```markdown
| Manifests valid | `./scripts/validate-manifests.sh` → exit 0, 0 `schema-not-found` |
```

- [ ] **Step 3: Commit**

```bash
git add CLAUDE.md .claude/rules/process.md
git commit -m "docs: point validation guidance at validate-manifests.sh"
```

---

#### T010 — Agent layer (FR-012)

**Files:** Modify `.mcp.json`

- [ ] **Step 1: Add the schema MCP server** — new entry in `.mcp.json` `mcpServers`

```json
    "flux-schema": {
      "type": "http",
      "url": "https://schemas.fluxoperator.dev/mcp"
    }
```

- [ ] **Step 2: Update the gitops-skills plugin (0.0.2 → v0.1.0)**

The installed marketplace is at 0.0.2; upstream released v0.1.0 on 2026-07-02 and it now depends on the `flux schema` plugin (installed in T001). Run in the Claude Code CLI:

```
/plugin marketplace update fluxcd
```

- [ ] **Step 3: Verify** — in a new session, confirm the `flux-schema` MCP tools resolve and `/gitops-repo-audit` is available.

- [ ] **Step 4: Commit**

```bash
git add .mcp.json
git commit -m "chore(agents): add flux-schema MCP server for authoring-time validation"
```

### Deviations from plan

<!-- Append as implementation surprises show up. Format:
- <2026-07-13> T00N was [dropped|replaced|split]: <why>
Keep short — detailed rationale goes in clarifications.md if it is a decision. -->

- 2026-07-13 T003 corrected pre-flight: the Envoy AI Gateway CRDs are rendered from the pinned OCI chart (version read from `flux/sources/ocirepo-envoy-ai-gateway-crds.yaml`), not fetched from a raw GitHub URL. Same artifact the cluster installs; stays Renovate-managed.
- 2026-07-13 T004 gained three fidelity fixes after the first full gate run (see CL-3, CL-4): apply `spec.postRenderers`, unwrap `kind: List`, normalise numeric resource quantities.
- 2026-07-14 **T011 and T012 added.** The plan's Non-Goals assumed Polaris `danger` was clean and only the `warning` backlog needed deferring. False: once Polaris could see the rendered charts (70 controllers, up from 4), it reported **46 `danger` failures across 24 controllers**. Two groups: 6 privileged-by-design (CSI ×2, node-exporter, dagger-engine, 2 GHA runner scale sets) → documented exemptions (T011); 18 upstream charts that never set `allowPrivilegeEscalation: false`, which the constitution mandates, plus an untagged Headlamp image → fixed by plumbing values (T012). Decided in conversation 2026-07-14: fix rather than defer, since these are real constitution violations that were invisible only because the gate was blind. Scope kept minimal — clear `danger` only; `readOnlyRootFilesystem` (a `warning`, and the riskiest change) stays deferred.

---

## Review Checklist

Complete this before implementation begins. Each persona enforces non-negotiable rules — do not skip.

### Project Manager

- [x] Problem statement in spec.md is clear and specific — quantified: 8 kinds skipped, 41 claim files unvalidated, 4 workloads visible to Polaris vs 80+
- [x] User stories capture real user needs — US-1..US-4 map to the two blind spots and the agent-parity requirement
- [x] Acceptance scenarios are testable — each is an exit code or a report field, exercised in T008
- [x] Scope is well-defined (goals AND non-goals) — Helm schema-validation explicitly dropped after measuring 0 findings
- [x] Success criteria are measurable — SC-001..SC-006 are all commands with numeric or boolean outcomes

### Platform Engineer

- [x] Design follows existing patterns — `scripts/validate-*.sh` + `scripts/test-*.sh` mirror `validate-kcl-compositions.sh` / `test-vector-vrl.sh`; `scripts/flux-schema/` mirrors `scripts/sdd/`
- [x] Single source of config — `.fluxschema.yml` is shared by CI, humans, and agents; no CI-only flags
- [x] Generated artifacts are gitignored, never committed (`.schemas/`, `.bundle/`) so they cannot drift from the XRDs
- [x] Existing behaviour preserved — the same fixture substitution vars CI already passes to kubeconform
- [x] Shell scripts pass `shellcheck -S warning` (CI enforces this on `scripts/**`)

### Security & Compliance

- [x] No new credentials or secrets — the ecosystem catalog and CRD fetches are anonymous HTTPS reads
- [x] Supply chain: schema sources pinned/explicit — `AI_GATEWAY_VERSION` is pinned; the ecosystem catalog is the Flux project's own
- [x] The change strengthens, not weakens, enforcement — `skipMissingSchemas: false` and `--set-exit-code-on-danger` both make CI stricter
- [x] Polaris `danger` checks cover the PSS bug class this repo keeps hitting (privilege escalation, root, dangerous capabilities)
- [ ] Polaris `warning` backlog (probes, limits, `readOnlyRootFilesystem`) triaged — **deliberately deferred**, see Non-Goals

### SRE

- [x] Failure modes documented — unresolved chart source, AI-Gateway CRD URL drift; both call out "do not fall back to `--skip-missing-schemas`"
- [x] The gates fail loudly rather than silently — the defining fix of this spec
- [x] Rollback path clear — revert the CI job; the old kubeconform Dagger module is unchanged upstream and still callable
- [x] CI wall-clock bounded — Helm download cache (CL-2); bundle always fresh
- [x] Evidence path defined — T008 proves both gates fail on injected defects before we trust their green

---

## References

- Spec: [spec.md](spec.md)
- Clarifications log: [clarifications.md](clarifications.md)
- Constitution: [docs/specs/constitution.md](../constitution.md)
- Upstream: [fluxcd/flux-schema](https://github.com/fluxcd/flux-schema) v0.10.2 · [ecosystem catalog](https://schemas.fluxoperator.dev)
- Related: SPEC-002 (composition-owned gateway routing) — why `parentGateway` must not be re-added to the InferenceService XRD in T007
