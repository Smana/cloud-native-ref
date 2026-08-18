# Crossplane Configuration Extraction — Stage 1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build `github.com/Smana/crossplane-configuration` into a repository that publishes two working Crossplane Configuration packages — `crossplane-configuration-core` and `crossplane-configuration-aws` at `0.1.0` — proven to render byte-identically to today's OCI-module Compositions.

**Architecture:** Five APIs live under `apis/<api>/` as an XRD, a *generated* Composition, and a KCL module. `make generate` inlines each `kcl/main.k` into its `composition.yaml` as a literal block scalar; CI proves the committed output is in sync and that rendering it reproduces committed golden fixtures captured from today's OCI path. Two `crossplane.yaml` files under `packages/` are assembled into clean build roots and packaged with `crossplane xpkg build`.

**Tech Stack:** KCL 0.11.3, Crossplane CLI v2.1.3 (targets Crossplane 2.3.4), Python 3 + PyYAML, GNU Make, kind v0.32.0, GitHub Actions, ghcr.io.

## Global Constraints

- **`cloud-native-ref`'s FUNCTIONAL files are READ-ONLY for this entire stage.** No manifest, script, composition, workflow or cluster file may change. Stage 2 is a separate plan. Documentation under `docs/superpowers/` on the `feat/crossplane-configuration-extraction` branch MAY be updated to record evidence (Task 11 Step 8 does exactly this). Verify with both:
  - `git -C $CNR status --porcelain` → empty
  - `git -C $CNR diff --stat main...HEAD` → paths under `docs/` only
- **The API group is `cloud.ogenki.io` and does not change.** No XRD schema edit, no `metadata.name` edit, no `kind` or `plural` edit. This is a relocation.
- **`kcl test` requires `-Y settings-example.yaml`.** Without it every test fails with `EvaluationError` (verified: kvstore 15/15 FAIL bare, 15/15 PASS with the flag).
- **Baseline test counts that must not regress:** app 32, cloudnativepg 12, eks-pod-identity 7, inference-service 44, kvstore 15 — **110 total**.
- **`crossplane xpkg build --ignore` cannot exclude directories.** Each package therefore needs its own clean build root containing only its YAML.
- **`Function` objects cannot live inside a Configuration package.** They are cluster-scoped install manifests, expressed in packages as `dependsOn`.
- **Pinned function versions**, used verbatim in both `functions.yaml` and every `dependsOn`:
  - `xpkg.upbound.io/crossplane-contrib/function-kcl` → `v0.12.1`
  - `xpkg.crossplane.io/crossplane-contrib/function-auto-ready` → `v0.7.0`
  - `xpkg.crossplane.io/crossplane-contrib/function-environment-configs` → `v0.7.2`
- **Never mutate a KCL dict after creation** (function-kcl issue #285 — duplicate resources). Not expected in this plan, which does not author KCL, but applies to any fix.
- Source of truth for every decision: [`docs/superpowers/specs/2026-08-18-crossplane-configuration-extraction-design.md`](../specs/2026-08-18-crossplane-configuration-extraction-design.md).

## Pre-flight context (verified while writing this plan — no action needed)

| Fact | Value |
|---|---|
| XRD file → CRD name → kind | `app-definition.yaml` → `apps.cloud.ogenki.io` → `App`; `epi-definition.yaml` → `epis.cloud.ogenki.io` → `EPI`; `inference-service-definition.yaml` → `inferenceservices.cloud.ogenki.io` → `InferenceService`; `kvstore-definition.yaml` → `kvstores.cloud.ogenki.io` → `KVStore`; `sql-instance-definition.yaml` → `sqlinstances.cloud.ogenki.io` → `SQLInstance` |
| Composition → module | `app-composition.yaml` → `kcl/app`; `sql-instance-composition.yaml` → `kcl/cloudnativepg`; `epi-composition.yaml` → `kcl/eks-pod-identity`; `inference-service-composition.yaml` → `kcl/inference-service`; `kvstore-composition.yaml` → `kcl/kvstore` |
| Function usage | `kvstore` uses `function-kcl` + `function-auto-ready` only. The other four also use `function-environment-configs` |
| Modules are inline-safe | 1 non-test `.k` file each, imports only `json`/`yaml`, empty `[dependencies]` |
| Render equivalence | Already proven during design: 12/12 examples byte-identical |
| Existing render command | `cd <config-dir> && crossplane render examples/<ex> <composition> functions.yaml --extra-resources examples/environmentconfig.yaml` |
| Examples on disk | 13 files: 12 claim examples + `environmentconfig.yaml` (an `--extra-resources` input, not a claim) |
| Validator coverage gap | `inferenceservice-endpointpicker.yaml` is absent from `COMPOSITIONS` in `scripts/validate-kcl-compositions.sh:55-60` |

**`CNR` below means the absolute path to the `cloud-native-ref` checkout**; `CFG` means `$CNR/infrastructure/base/crossplane/configuration`. Export both once per session:

```bash
export CNR=/home/smana/Sources/cloud-native-ref
export CFG=$CNR/infrastructure/base/crossplane/configuration
```

## File Structure

| File | Action | Responsibility |
|---|---|---|
| `README.md` | Create | What the packages are, how to install, API table |
| `LICENSE` | Create | Apache-2.0 |
| `.gitignore` | Create | `build/`, `*.xpkg`, `.venv/` |
| `mise.toml` | Create | Pin kcl, crossplane, python |
| `Makefile` | Create | `generate` `test` `render` `build` `push` `check` |
| `functions.yaml` | Create | Function manifests for local render; mirrors `dependsOn` |
| `apis/<api>/definition.yaml` | Create ×5 | XRD, copied verbatim |
| `apis/<api>/composition.yaml` | Create ×5 | **Generated** — KCL inlined |
| `apis/<api>/kcl/{main.k,main_test.k,kcl.mod,settings-example.yaml}` | Create ×5 | KCL source of truth |
| `examples/*.yaml` | Create ×13 | Claim examples + environmentconfig |
| `packages/{core,aws}/crossplane.yaml` | Create ×2 | Package metadata + `dependsOn` |
| `scripts/generate.py` | Create | Inline `main.k` into `composition.yaml` |
| `scripts/render_check.py` | Create | Render every example, diff against golden |
| `scripts/xrd_to_crd.py` | Create | Copied from `cloud-native-ref`, for the release asset |
| `scripts/assemble.sh` | Create | Stage `build/<pkg>/` roots |
| `tests/golden/*.yaml` | Create ×12 | Frozen render output — the equivalence contract |
| `.github/workflows/ci.yaml` | Create | fmt, test, generate-sync, render-diff, xpkg build |
| `.github/workflows/release.yaml` | Create | tag → push both packages + `xrd-crds.yaml` asset |

`apis/<api>` names: `app`, `sqlinstance`, `kvstore`, `inferenceservice`, `epi`.

---

## Task 1: Repository skeleton

**Files:**
- Create: `README.md`, `LICENSE`, `.gitignore`, `mise.toml`, `Makefile`

**Interfaces:**
- Produces: a pushed `main` branch, and the complete `make` target surface
  (`generate` `test` `render` `build` `push` `check` `clean`) that Tasks 3-7 supply scripts for.

- [ ] **Step 1: Clone the empty repo and enter it**

```bash
cd ~/Sources
git clone https://github.com/Smana/crossplane-configuration
cd crossplane-configuration
```

Expected: `warning: You appear to have cloned an empty repository.`

- [ ] **Step 2: Write `.gitignore`**

```gitignore
build/
*.xpkg
.venv/
__pycache__/
```

- [ ] **Step 3: Write `mise.toml`**

```toml
[tools]
kcl = "0.11.3"
crossplane = "2.1.3"
python = "3.13"
```

- [ ] **Step 4: Write `LICENSE`**

Fetch the Apache-2.0 text so it is byte-correct rather than paraphrased:

```bash
curl -fsSL https://www.apache.org/licenses/LICENSE-2.0.txt -o LICENSE
```

- [ ] **Step 5: Write `Makefile`**

```makefile
.PHONY: generate test render build push check clean

APIS := app sqlinstance kvstore inferenceservice epi
PKGS := core aws
VERSION ?= 0.1.0
REGISTRY ?= ghcr.io/smana

generate:
	python3 scripts/generate.py

test:
	@for a in $(APIS); do \
	  echo "==> $$a"; \
	  (cd apis/$$a/kcl && kcl fmt --check . && kcl test . -Y settings-example.yaml) || exit 1; \
	done

render:
	python3 scripts/render_check.py

build: generate
	./scripts/assemble.sh
	@for p in $(PKGS); do \
	  crossplane xpkg build \
	    --package-root=build/$$p \
	    --examples-root=build/$$p/examples \
	    --package-file=build/crossplane-configuration-$$p.xpkg || exit 1; \
	done

push:
	@for p in $(PKGS); do \
	  crossplane xpkg push \
	    -f build/crossplane-configuration-$$p.xpkg \
	    $(REGISTRY)/crossplane-configuration-$$p:$(VERSION) || exit 1; \
	done

check: generate
	@git diff --exit-code -- apis/ \
	  || { echo "ERROR: composition.yaml is stale. Run 'make generate' and commit."; exit 1; }
	$(MAKE) test
	$(MAKE) render

clean:
	rm -rf build/
```

- [ ] **Step 6: Write `README.md`**

```markdown
# crossplane-configuration

Crossplane Configuration packages for the [ogenki](https://blog.ogenki.io) platform — the API
surface used by [Smana/cloud-native-ref](https://github.com/Smana/cloud-native-ref).

Composed with [KCL](https://kcl-lang.io) via
[function-kcl](https://github.com/crossplane-contrib/function-kcl). The KCL is **inlined into the
Compositions**, so installing a package pulls no further artifacts at render time.

## Packages

| Package | Contents |
|---|---|
| `ghcr.io/smana/crossplane-configuration-core` | Cloud-neutral contracts: `App`, `SQLInstance`, `KVStore`, `InferenceService` + the `KVStore` Composition |
| `ghcr.io/smana/crossplane-configuration-aws` | `EPI` (EKS Pod Identity) + the AWS Compositions for `App`, `SQLInstance`, `InferenceService`, `EPI`. Depends on `-core` |

A GCP package is added when it has content; see the
[dual-cloud design](https://github.com/Smana/cloud-native-ref/blob/main/docs/superpowers/specs/2026-08-18-gcp-support-design.md).

## APIs

All in group `cloud.ogenki.io`.

| Kind | Purpose |
|---|---|
| `App` | Application abstraction: Deployment, Service, HTTPRoute, HPA, PDB, CiliumNetworkPolicy, optional database / cache / object storage |
| `SQLInstance` | PostgreSQL via CloudNativePG, optional S3 barman backup and Atlas schema migrations |
| `KVStore` | Valkey cache via the official chart |
| `InferenceService` | Self-hosted LLM inference: vLLM, KEDA autoscaling, Envoy AI Gateway routes |
| `EPI` | EKS Pod Identity — an IAM role bound to a (namespace, ServiceAccount) pair |

## Install

```yaml
apiVersion: pkg.crossplane.io/v1
kind: Configuration
metadata:
  name: crossplane-configuration-aws
spec:
  package: ghcr.io/smana/crossplane-configuration-aws:0.1.0
```

`-aws` pulls `-core` through its `dependsOn`.

## Development

```bash
mise install
make check   # generate-sync + kcl fmt/test + render against golden fixtures
make build   # produce both .xpkg files
```

`apis/<api>/kcl/main.k` is the source of truth. `apis/<api>/composition.yaml` is **generated** by
`make generate` — edit the KCL, never the inlined copy.
```

- [ ] **Step 7: Commit and push**

```bash
git add -A
git commit -m "chore: repository skeleton"
git branch -M main
git push -u origin main
```

Expected: push succeeds, `main` exists on GitHub.

---

## Task 2: Move the APIs

**Files:**
- Create: `apis/{app,sqlinstance,kvstore,inferenceservice,epi}/definition.yaml`
- Create: `apis/*/composition.yaml` (still OCI-sourced at this point)
- Create: `apis/*/kcl/{main.k,main_test.k,kcl.mod,kcl.mod.lock,settings-example.yaml}`
- Create: `examples/` (13 files), `functions.yaml`

**Interfaces:**
- Produces: the `apis/<api>/` layout every later task globs.

- [ ] **Step 1: Copy the files into the new layout**

```bash
set -euo pipefail
export CFG=/home/smana/Sources/cloud-native-ref/infrastructure/base/crossplane/configuration

# api-dir : definition file : composition file : kcl module
while IFS=: read -r api def comp mod; do
  mkdir -p "apis/$api/kcl"
  cp "$CFG/$def"  "apis/$api/definition.yaml"
  cp "$CFG/$comp" "apis/$api/composition.yaml"
  cp "$CFG/kcl/$mod"/* "apis/$api/kcl/"
done <<'EOF'
app:app-definition.yaml:app-composition.yaml:app
sqlinstance:sql-instance-definition.yaml:sql-instance-composition.yaml:cloudnativepg
kvstore:kvstore-definition.yaml:kvstore-composition.yaml:kvstore
inferenceservice:inference-service-definition.yaml:inference-service-composition.yaml:inference-service
epi:epi-definition.yaml:epi-composition.yaml:eks-pod-identity
EOF

mkdir -p examples
cp "$CFG"/examples/*.yaml examples/
cp "$CFG/functions.yaml" .
```

- [ ] **Step 2: Verify the copy is complete and faithful**

```bash
ls apis/*/definition.yaml apis/*/composition.yaml | wc -l   # expect 10
ls apis/*/kcl/main.k | wc -l                                 # expect 5
ls examples/*.yaml | wc -l                                   # expect 13
diff <(cat "$CFG/app-definition.yaml") apis/app/definition.yaml && echo "verbatim"
```

Expected: `10`, `5`, `13`, `verbatim`.

- [ ] **Step 3: Move the per-module READMEs up and repoint their paths**

The platform constitution requires a `README.md` per composition, so these are kept rather than
folded into the root README. They currently reference
`infrastructure/base/crossplane/configuration/kcl/...` paths that no longer exist.

```bash
for api in app sqlinstance kvstore inferenceservice epi; do
  [ -f "apis/$api/kcl/README.md" ] && git mv 2>/dev/null || true
  mv "apis/$api/kcl/README.md" "apis/$api/README.md" 2>/dev/null || true
done
ls apis/*/README.md
```

Expected: five files, one per API.

Then rewrite every stale path inside them. The old layout had a flat directory; the new one is
per-API:

```bash
for api in app sqlinstance kvstore inferenceservice epi; do
  sed -i \
    -e "s#infrastructure/base/crossplane/configuration/kcl/[a-z-]*#apis/$api/kcl#g" \
    -e "s#infrastructure/base/crossplane/configuration/examples#examples#g" \
    -e "s#infrastructure/base/crossplane/configuration#apis/$api#g" \
    "apis/$api/README.md"
done
grep -rn 'infrastructure/base' apis/*/README.md || echo "no stale paths remain"
```

Expected: `no stale paths remain`.

Finally, verify each README still describes the right API — the `sqlinstance` README belongs to the
`cloudnativepg` module and the `epi` README to `eks-pod-identity`, so their titles and any module
names inside must match the new API directory names. Fix any mismatch by hand.

Add the links to the root `README.md` under the APIs table:

```markdown
Per-API documentation: [`App`](apis/app/README.md) · [`SQLInstance`](apis/sqlinstance/README.md) ·
[`KVStore`](apis/kvstore/README.md) · [`InferenceService`](apis/inferenceservice/README.md) ·
[`EPI`](apis/epi/README.md)
```

- [ ] **Step 4: Run the tests in their new location**

```bash
make test
```

Expected — exactly the pre-flight baseline, no regression:

```
==> app
PASS: 32/32
==> sqlinstance
PASS: 12/12
==> kvstore
PASS: 15/15
==> inferenceservice
PASS: 44/44
==> epi
PASS: 7/7
```

If any module reports fewer tests than the baseline, a file was missed in Step 1 — do not proceed.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat: import the platform APIs from cloud-native-ref

Five XRDs, five Compositions and five KCL modules, copied verbatim. The
Compositions still reference their OCI modules; Task 3 inlines them.

kcl test: 110/110 across the five modules, matching the baseline measured in
cloud-native-ref before the move."
```

---

## Task 3: The generator

**Files:**
- Create: `scripts/generate.py`
- Create: `tests/test_generate.py`
- Modify: `apis/*/composition.yaml` (regenerated)

**Interfaces:**
- Consumes: `apis/<api>/kcl/main.k`, `apis/<api>/composition.yaml`
- Produces: `scripts/generate.py` exposing `inline_composition(comp_path: pathlib.Path) -> str`
  returning the module directory name it inlined; used by `render_check.py` indirectly (via the
  regenerated files) and by CI's `make check`.

- [ ] **Step 1: Write the failing test**

`tests/test_generate.py`:

```python
import pathlib
import subprocess
import sys

import yaml

ROOT = pathlib.Path(__file__).resolve().parents[1]
APIS = ["app", "sqlinstance", "kvstore", "inferenceservice", "epi"]


def _source_of(api: str) -> str:
    doc = yaml.safe_load((ROOT / "apis" / api / "composition.yaml").read_text())
    for step in doc["spec"]["pipeline"]:
        spec = (step.get("input") or {}).get("spec") or {}
        if "source" in spec:
            return spec["source"]
    raise AssertionError(f"no KCL step found in {api}")


def test_generate_inlines_every_module():
    """After generate, no Composition may reference an OCI module."""
    subprocess.run([sys.executable, "scripts/generate.py"], cwd=ROOT, check=True)
    for api in APIS:
        assert not _source_of(api).startswith("oci://"), f"{api} still OCI-sourced"


def test_inlined_source_is_byte_identical_to_main_k():
    """The embedded copy must equal main.k exactly - no reformatting, no trimming."""
    subprocess.run([sys.executable, "scripts/generate.py"], cwd=ROOT, check=True)
    for api in APIS:
        main_k = (ROOT / "apis" / api / "kcl" / "main.k").read_text()
        assert _source_of(api) == main_k, f"{api} source drifted from main.k"


def test_generate_is_idempotent():
    """Running generate twice must not change the file - CI relies on this."""
    subprocess.run([sys.executable, "scripts/generate.py"], cwd=ROOT, check=True)
    first = {a: (ROOT / "apis" / a / "composition.yaml").read_bytes() for a in APIS}
    subprocess.run([sys.executable, "scripts/generate.py"], cwd=ROOT, check=True)
    for api in APIS:
        assert (ROOT / "apis" / api / "composition.yaml").read_bytes() == first[api], api
```

- [ ] **Step 2: Run it to make sure it fails**

```bash
python3 -m pytest tests/test_generate.py -v
```

Expected: FAIL — `No such file or directory: 'scripts/generate.py'`.

- [ ] **Step 3: Write `scripts/generate.py`**

```python
#!/usr/bin/env python3
"""Inline each KCL module into its Composition.

`apis/<api>/kcl/main.k` is the source of truth. This rewrites the KCL pipeline
step's `input.spec.source` with the module's contents as a literal block scalar,
so the published Composition is self-contained and function-kcl pulls nothing at
render time.

Idempotent: the previous value of `source` is always discarded, so running this
against an already-generated file is a no-op.
"""
import pathlib
import re
import sys

import yaml

ROOT = pathlib.Path(__file__).resolve().parents[1]

# api directory -> KCL module directory name (they differ for three APIs, because
# the modules were named after their implementation and the APIs after their kind).
MODULE = {
    "app": "app",
    "sqlinstance": "cloudnativepg",
    "kvstore": "kvstore",
    "inferenceservice": "inference-service",
    "epi": "eks-pod-identity",
}


class Literal(str):
    """A str that PyYAML emits as a `|` block scalar."""


def _repr_literal(dumper, data):
    return dumper.represent_scalar("tag:yaml.org,2002:str", str(data), style="|")


yaml.add_representer(Literal, _repr_literal)


def inline_composition(comp_path: pathlib.Path) -> str:
    """Rewrite comp_path with its KCL inlined. Returns the module directory name."""
    api = comp_path.parent.name
    module = MODULE[api]
    main_k = (comp_path.parent / "kcl" / "main.k").read_text()

    doc = yaml.safe_load(comp_path.read_text())
    hits = 0
    for step in doc["spec"]["pipeline"]:
        spec = (step.get("input") or {}).get("spec") or {}
        if "source" not in spec:
            continue
        spec["source"] = Literal(main_k)
        hits += 1
    if hits != 1:
        raise SystemExit(f"{comp_path}: expected exactly 1 KCL step, found {hits}")

    out = yaml.dump(doc, default_flow_style=False, width=10**9,
                    allow_unicode=True, sort_keys=False)

    # A block scalar cannot represent trailing whitespace; PyYAML silently falls
    # back to a quoted style, which would still parse but would stop being
    # reviewable. Prove the round-trip instead of trusting it.
    back = yaml.safe_load(out)
    for step in back["spec"]["pipeline"]:
        spec = (step.get("input") or {}).get("spec") or {}
        if "source" in spec and spec["source"] != main_k:
            raise SystemExit(
                f"{comp_path}: source did not survive the YAML round-trip. "
                "Check main.k for trailing whitespace."
            )

    comp_path.write_text(out)
    return module


def main() -> int:
    for comp in sorted(ROOT.glob("apis/*/composition.yaml")):
        module = inline_composition(comp)
        size = comp.stat().st_size
        print(f"{comp.relative_to(ROOT)}  <- apis/{comp.parent.name}/kcl/main.k "
              f"(module {module}, {size} B)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
python3 -m pytest tests/test_generate.py -v
```

Expected: 3 passed. And `make generate` prints five lines, e.g.
`apis/app/composition.yaml  <- apis/app/kcl/main.k (module app, ~56010 B)`.

- [ ] **Step 5: Confirm no OCI reference survives**

```bash
grep -rn 'oci://' apis/ || echo "no OCI references"
```

Expected: `no OCI references`.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat: inline the KCL modules into the Compositions

main.k stays the editable source; composition.yaml is generated. The generator
asserts the block scalar round-trips, because PyYAML silently falls back to a
quoted style if any line has trailing whitespace.

Deletes the OCI module pin flow: no -prN tags, no version audit job, no
'kcl mod push ignores the URL tag' trap."
```

---

## Task 4: Golden render fixtures

**Files:**
- Create: `tests/golden/*.yaml` (12 files)
- Create: `scripts/capture_golden.py`

**Interfaces:**
- Consumes: `cloud-native-ref`'s OCI-sourced Compositions (read-only), Docker.
- Produces: `tests/golden/<example-stem>.yaml` — the frozen contract that `render_check.py` diffs against.

This task captures the *old* behaviour as the contract, while the OCI Compositions still exist to
capture it from. It is the one task that cannot be done later.

- [ ] **Step 1: Confirm Docker is up**

```bash
docker info --format '{{.ServerVersion}}'
```

Expected: a version string. If this fails, `crossplane render` cannot run functions and the task
cannot proceed.

- [ ] **Step 2: Write `scripts/capture_golden.py`**

```python
#!/usr/bin/env python3
"""Capture golden render output from cloud-native-ref's OCI-sourced Compositions.

Run ONCE, before the old Compositions go away. The output becomes the contract
that scripts/render_check.py enforces forever after: the extraction is correct
if and only if the inlined Compositions reproduce these bytes.

Usage: CNR=/path/to/cloud-native-ref python3 scripts/capture_golden.py
"""
import os
import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
GOLDEN = ROOT / "tests" / "golden"

# example file -> the OLD composition filename in cloud-native-ref
EXAMPLES = {
    "app-basic.yaml": "app-composition.yaml",
    "app-complete.yaml": "app-composition.yaml",
    "app-worker.yaml": "app-composition.yaml",
    "app-cron.yaml": "app-composition.yaml",
    "sqlinstance-basic.yaml": "sql-instance-composition.yaml",
    "sqlinstance-complete.yaml": "sql-instance-composition.yaml",
    "epi.yaml": "epi-composition.yaml",
    "inferenceservice-basic.yaml": "inference-service-composition.yaml",
    "inferenceservice-complete.yaml": "inference-service-composition.yaml",
    "inferenceservice-endpointpicker.yaml": "inference-service-composition.yaml",
    "kvstore-basic.yaml": "kvstore-composition.yaml",
    "kvstore-complete.yaml": "kvstore-composition.yaml",
}


def main() -> int:
    cnr = os.environ.get("CNR")
    if not cnr:
        print("error: set CNR to the cloud-native-ref checkout path", file=sys.stderr)
        return 2
    cfg = pathlib.Path(cnr) / "infrastructure/base/crossplane/configuration"
    if not cfg.is_dir():
        print(f"error: {cfg} is not a directory", file=sys.stderr)
        return 2

    GOLDEN.mkdir(parents=True, exist_ok=True)
    failures = 0
    for example, composition in EXAMPLES.items():
        proc = subprocess.run(
            ["crossplane", "render", f"examples/{example}", composition, "functions.yaml",
             "--extra-resources", "examples/environmentconfig.yaml"],
            cwd=cfg, capture_output=True, text=True,
        )
        if proc.returncode != 0:
            print(f"FAIL  {example}\n{proc.stderr}", file=sys.stderr)
            failures += 1
            continue
        out = GOLDEN / example
        out.write_text(proc.stdout)
        print(f"captured {example:<40} {len(proc.stdout):>6} B")

    print(f"\n{len(EXAMPLES) - failures}/{len(EXAMPLES)} captured")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
```

- [ ] **Step 3: Capture**

```bash
CNR=/home/smana/Sources/cloud-native-ref python3 scripts/capture_golden.py
```

Expected: 12 lines, then `12/12 captured`. Approximate sizes, for a sanity check:
`app-basic` 3813 B, `app-complete` 17826 B, `app-worker` 3896 B, `app-cron` 3075 B,
`sqlinstance-basic` 2956 B, `sqlinstance-complete` 19403 B, `epi` 4437 B,
`inferenceservice-basic` 18219 B, `inferenceservice-complete` 22752 B,
`inferenceservice-endpointpicker` 25433 B, `kvstore-basic` 2480 B, `kvstore-complete` 3234 B.

- [ ] **Step 4: Verify cloud-native-ref was not modified**

```bash
git -C /home/smana/Sources/cloud-native-ref status --porcelain
```

Expected: empty output. `crossplane render` only reads.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "test: freeze render output from the OCI Compositions as golden fixtures

Captured from cloud-native-ref's pre-extraction Compositions while they still
exist. These 12 files are the extraction's contract: the inlined Compositions
are correct if and only if they reproduce these bytes exactly.

Includes inferenceservice-endpointpicker.yaml, which the old
validate-kcl-compositions.sh never tested."
```

---

## Task 5: Render check against golden

**Files:**
- Create: `scripts/render_check.py`

**Interfaces:**
- Consumes: `tests/golden/*.yaml`, `apis/*/composition.yaml`, `examples/`, `functions.yaml`
- Produces: `make render` — exit 0 iff every example reproduces its golden file.

- [ ] **Step 1: Run the check before it exists, to establish the failure**

`render_check.py` *is* the test here — there is no separate unit test wrapping it. Confirm the
target is wired but unsatisfied:

```bash
make render; echo "exit=$?"
```

Expected: `python3: can't open file '.../scripts/render_check.py'` and `exit=2`.

- [ ] **Step 2: Write `scripts/render_check.py`**

```python
#!/usr/bin/env python3
"""Render every claim example through the inlined Compositions and diff against golden.

Examples are enumerated from disk rather than hardcoded, so a new example cannot
be silently untested - which is how inferenceservice-endpointpicker.yaml went
unrendered in cloud-native-ref's validator.
"""
import difflib
import pathlib
import subprocess
import sys

import yaml

ROOT = pathlib.Path(__file__).resolve().parents[1]
GOLDEN = ROOT / "tests" / "golden"
EXAMPLES = ROOT / "examples"

# environmentconfig.yaml is an --extra-resources input, not a claim.
NOT_A_CLAIM = {"environmentconfig.yaml"}


def composition_for(kind: str) -> pathlib.Path:
    """Find the Composition whose compositeTypeRef matches this claim's kind."""
    for comp in sorted(ROOT.glob("apis/*/composition.yaml")):
        doc = yaml.safe_load(comp.read_text())
        if doc["spec"]["compositeTypeRef"]["kind"] == kind:
            return comp
    raise SystemExit(f"no Composition found for kind {kind}")


def main() -> int:
    examples = sorted(p for p in EXAMPLES.glob("*.yaml") if p.name not in NOT_A_CLAIM)
    if not examples:
        raise SystemExit("no examples found")

    missing = [p.name for p in examples if not (GOLDEN / p.name).exists()]
    if missing:
        raise SystemExit(
            f"no golden fixture for: {', '.join(missing)}\n"
            "Every example must have one. Capture it or delete the example."
        )
    orphans = [p.name for p in GOLDEN.glob("*.yaml") if not (EXAMPLES / p.name).exists()]
    if orphans:
        raise SystemExit(f"golden fixture with no example: {', '.join(orphans)}")

    failures = 0
    for example in examples:
        kind = yaml.safe_load(example.read_text())["kind"]
        comp = composition_for(kind)
        proc = subprocess.run(
            ["crossplane", "render", f"examples/{example.name}",
             str(comp.relative_to(ROOT)), "functions.yaml",
             "--extra-resources", "examples/environmentconfig.yaml"],
            cwd=ROOT, capture_output=True, text=True,
        )
        if proc.returncode != 0:
            print(f"ERROR  {example.name}\n{proc.stderr}", file=sys.stderr)
            failures += 1
            continue
        want = (GOLDEN / example.name).read_text()
        if proc.stdout == want:
            print(f"MATCH  {example.name:<40} {len(want):>6} B")
        else:
            print(f"DIFFER {example.name}", file=sys.stderr)
            sys.stderr.writelines(difflib.unified_diff(
                want.splitlines(keepends=True), proc.stdout.splitlines(keepends=True),
                fromfile="golden", tofile="rendered"))
            failures += 1

    print(f"\n{len(examples) - failures}/{len(examples)} match")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
```

- [ ] **Step 3: Run it**

```bash
make render
```

Expected: 12 `MATCH` lines and `12/12 match`, exit 0. **A single `DIFFER` means the extraction
changed behaviour — stop and investigate, do not adjust the golden file.**

- [ ] **Step 4: Prove the check actually catches a regression**

A check that cannot fail is not a check. Perturb the golden fixture — **not** `main.k`. Appending a
KCL *comment* leaves the rendered output byte-identical (verified), so it would prove nothing.

```bash
printf '\n' >> tests/golden/kvstore-basic.yaml
make render; echo "exit=$?"
git checkout tests/golden/kvstore-basic.yaml
```

Expected: `DIFFER kvstore-basic.yaml`, a unified diff on stderr, `11/12 match`, and `exit=1`.
The `git checkout` then restores the fixture.

- [ ] **Step 5: Confirm the tree is clean again**

```bash
git status --porcelain
```

Expected: only `scripts/render_check.py` as untracked/new — no modified `apis/` files.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "test: enforce render equivalence against the golden fixtures

Examples are enumerated from disk and cross-checked against the golden set in
both directions, so neither an untested example nor an orphaned fixture can
survive CI. Verified the check fails on a deliberate one-line regression."
```

---

## Task 6: Package metadata and build

**Files:**
- Create: `packages/core/crossplane.yaml`, `packages/aws/crossplane.yaml`
- Create: `scripts/assemble.sh`

**Interfaces:**
- Consumes: `apis/*/`, `examples/`
- Produces: `build/crossplane-configuration-{core,aws}.xpkg`

- [ ] **Step 1: Write `packages/core/crossplane.yaml`**

```yaml
apiVersion: meta.pkg.crossplane.io/v1
kind: Configuration
metadata:
  name: crossplane-configuration-core
  annotations:
    meta.crossplane.io/maintainer: Smana <smaine.kahlouch@ogenki.io>
    meta.crossplane.io/source: github.com/Smana/crossplane-configuration
    meta.crossplane.io/license: Apache-2.0
    meta.crossplane.io/description: |
      Cloud-neutral platform API contracts for the ogenki platform: App,
      SQLInstance, KVStore and InferenceService, plus the KVStore Composition.
      Cloud-specific Compositions ship in a sibling package.
spec:
  crossplane:
    version: ">=v2.0.0-0"
  dependsOn:
    - function: xpkg.upbound.io/crossplane-contrib/function-kcl
      version: ">=v0.12.1"
    - function: xpkg.crossplane.io/crossplane-contrib/function-auto-ready
      version: ">=v0.7.0"
```

- [ ] **Step 2: Write `packages/aws/crossplane.yaml`**

```yaml
apiVersion: meta.pkg.crossplane.io/v1
kind: Configuration
metadata:
  name: crossplane-configuration-aws
  annotations:
    meta.crossplane.io/maintainer: Smana <smaine.kahlouch@ogenki.io>
    meta.crossplane.io/source: github.com/Smana/crossplane-configuration
    meta.crossplane.io/license: Apache-2.0
    meta.crossplane.io/description: |
      AWS implementations of the ogenki platform APIs: the EPI (EKS Pod Identity)
      contract and Compositions, and the AWS Compositions for App, SQLInstance
      and InferenceService.
spec:
  crossplane:
    version: ">=v2.0.0-0"
  dependsOn:
    - configuration: ghcr.io/smana/crossplane-configuration-core
      version: ">=v0.1.0"
    - function: xpkg.crossplane.io/crossplane-contrib/function-environment-configs
      version: ">=v0.7.2"
```

- [ ] **Step 3: Write `scripts/assemble.sh`**

`crossplane xpkg build --ignore` cannot exclude directories, so each package needs a build root
holding only its own YAML.

```bash
#!/usr/bin/env bash
# Stage a clean build root per package. crossplane xpkg build recurses through
# --package-root and --ignore cannot exclude directories, so the KCL sources and
# the other package's files must simply not be there.
set -euo pipefail
cd "$(dirname "$0")/.."

rm -rf build
mkdir -p build/core/apis build/core/examples build/aws/apis build/aws/examples

# --- core: the cloud-neutral contracts, plus the one neutral Composition ------
for api in app sqlinstance kvstore inferenceservice; do
  cp "apis/$api/definition.yaml" "build/core/apis/$api-definition.yaml"
done
cp apis/kvstore/composition.yaml build/core/apis/kvstore-composition.yaml
cp packages/core/crossplane.yaml build/core/crossplane.yaml
cp examples/kvstore-basic.yaml examples/kvstore-complete.yaml build/core/examples/

# --- aws: the AWS contract, plus every AWS Composition ------------------------
cp apis/epi/definition.yaml build/aws/apis/epi-definition.yaml
for api in app sqlinstance inferenceservice epi; do
  cp "apis/$api/composition.yaml" "build/aws/apis/$api-composition.yaml"
done
cp packages/aws/crossplane.yaml build/aws/crossplane.yaml
cp examples/app-*.yaml examples/sqlinstance-*.yaml examples/inferenceservice-*.yaml \
   examples/epi.yaml examples/environmentconfig.yaml build/aws/examples/

echo "staged:"
find build -name '*.yaml' | sort | sed 's/^/  /'
```

```bash
chmod +x scripts/assemble.sh
```

- [ ] **Step 4: Build both packages**

```bash
make build
```

Expected: `staged:` listing 5 core YAMLs + 2 core examples and 5 aws YAMLs + 9 aws examples, then
two files:

```bash
ls -la build/*.xpkg
```

Expected: `build/crossplane-configuration-core.xpkg` and `build/crossplane-configuration-aws.xpkg`.

- [ ] **Step 5: Assert the contents landed in the right package**

```bash
python3 - <<'EOF'
import pathlib, yaml, sys
want = {
  "core": {"apps.cloud.ogenki.io", "sqlinstances.cloud.ogenki.io",
           "kvstores.cloud.ogenki.io", "inferenceservices.cloud.ogenki.io",
           "xkvstores.cloud.ogenki.io"},
  "aws":  {"epis.cloud.ogenki.io", "xapps.cloud.ogenki.io",
           "xsqlinstances.cloud.ogenki.io", "xinferenceservices.cloud.ogenki.io",
           "xepis.cloud.ogenki.io"},
}
bad = 0
for pkg, expected in want.items():
    got = set()
    for f in sorted(pathlib.Path(f"build/{pkg}/apis").glob("*.yaml")):
        got.add(yaml.safe_load(f.read_text())["metadata"]["name"])
    print(f"{pkg}: {len(got)} objects")
    if got != expected:
        print(f"  MISSING {expected - got}\n  EXTRA   {got - expected}"); bad = 1
    # EPI must never appear in core
    if pkg == "core" and any("epi" in n for n in got):
        print("  ERROR: EPI leaked into core"); bad = 1
sys.exit(bad)
EOF
```

Expected: `core: 5 objects`, `aws: 5 objects`, exit 0.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat: package the APIs as crossplane-configuration-core and -aws

EPI's XRD ships in -aws, not -core: both halves of it are wholly AWS, so
leaving the contract in core would advertise epis.cloud.ogenki.io on a GKE
cluster that can never satisfy it.

assemble.sh stages a clean root per package because crossplane xpkg build
recurses and --ignore cannot exclude directories."
```

---

## Task 7: The XRD-to-CRD release asset

**Files:**
- Create: `scripts/xrd_to_crd.py`

**Interfaces:**
- Consumes: `apis/*/definition.yaml`
- Produces: `build/xrd-crds.yaml`, attached to each GitHub release; consumed in Stage 2 by
  `cloud-native-ref`'s `scripts/flux-schema/gen-catalog.sh`.

- [ ] **Step 1: Copy the converter from cloud-native-ref**

```bash
cp /home/smana/Sources/cloud-native-ref/scripts/flux-schema/xrd-to-crd.py scripts/xrd_to_crd.py
```

- [ ] **Step 2: Read it and confirm it needs no change**

The script takes XRD file paths as `argv` and writes CRDs to stdout, so only the *caller's* glob
changes — from the old flat `configuration/*-definition.yaml` to `apis/*/definition.yaml`. Read the
file to confirm it has no hardcoded input path. If it does, that is the only edit to make; Step 4
proves the output is unchanged either way.

- [ ] **Step 3: Add the Makefile target**

Insert into `Makefile` after the `build` target:

```makefile
crds:
	@mkdir -p build
	python3 scripts/xrd_to_crd.py apis/*/definition.yaml > build/xrd-crds.yaml
	@echo "wrote build/xrd-crds.yaml ($$(grep -c '^kind: CustomResourceDefinition' build/xrd-crds.yaml) CRDs)"
```

Add `crds` to the `.PHONY` line.

- [ ] **Step 4: Generate and verify against cloud-native-ref's output**

The converted CRDs must be identical to what `cloud-native-ref` produces today, or the schema gate
changes meaning in Stage 2.

```bash
make crds
CNR=/home/smana/Sources/cloud-native-ref
python3 "$CNR/scripts/flux-schema/xrd-to-crd.py" \
  "$CNR"/infrastructure/base/crossplane/configuration/*-definition.yaml > /tmp/cnr-crds.yaml
diff /tmp/cnr-crds.yaml build/xrd-crds.yaml && echo "IDENTICAL"
```

Expected: `IDENTICAL`. If they differ, the XRDs were not copied verbatim in Task 2 — fix that,
do not adjust the converter.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat: emit xrd-crds.yaml for the schema catalog

Stage 2 repoints cloud-native-ref's gen-catalog.sh at this release asset, so
the same version string drives both the installed Configuration and the schemas
its claims are validated against. Verified byte-identical to the output
cloud-native-ref produces today."
```

---

## Task 8: CI workflow

**Files:**
- Create: `.github/workflows/ci.yaml`

**Interfaces:**
- Produces: a required check on every PR.

- [ ] **Step 1: Write `.github/workflows/ci.yaml`**

```yaml
name: CI

on:
  push:
    branches: [main]
  pull_request:

permissions:
  contents: read

jobs:
  check:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v5

      - name: Install mise-managed tools
        uses: jdx/mise-action@v3

      - name: Install Python dependencies
        run: pip install pyyaml pytest

      - name: KCL format and unit tests
        run: make test

      - name: Generator unit tests
        run: python3 -m pytest tests/test_generate.py -v

      - name: Compositions are in sync with the KCL
        run: |
          make generate
          git diff --exit-code -- apis/ \
            || { echo "::error::composition.yaml is stale. Run 'make generate' and commit."; exit 1; }

      # Docker is present on ubuntu-latest, so crossplane render can run the functions.
      - name: Render equivalence against golden fixtures
        run: make render

      - name: Build both packages
        run: make build

      - name: XRD-to-CRD conversion
        run: make crds

      - name: Function versions match the package dependsOn
        run: python3 scripts/check_function_pins.py
```

- [ ] **Step 2: Write `scripts/check_function_pins.py`**

`functions.yaml` exists for local render and for the App Wizard, while `dependsOn` is what adopters
get. They must not drift.

```python
#!/usr/bin/env python3
"""Assert functions.yaml and the packages' dependsOn pin the same versions."""
import pathlib
import re
import sys

import yaml

ROOT = pathlib.Path(__file__).resolve().parents[1]


def from_functions_yaml() -> dict[str, str]:
    pins = {}
    for doc in yaml.safe_load_all((ROOT / "functions.yaml").read_text()):
        if not doc or doc.get("kind") != "Function":
            continue
        pkg = doc["spec"]["package"]
        repo, _, version = pkg.rpartition(":")
        pins[repo] = version
    return pins


def from_packages() -> dict[str, str]:
    pins = {}
    for meta in sorted(ROOT.glob("packages/*/crossplane.yaml")):
        doc = yaml.safe_load(meta.read_text())
        for dep in doc["spec"].get("dependsOn", []):
            if "function" not in dep:
                continue
            pins[dep["function"]] = re.sub(r"^[><=~^]+", "", dep["version"])
    return pins


def main() -> int:
    fns, pkgs = from_functions_yaml(), from_packages()
    bad = 0
    for repo, version in sorted(pkgs.items()):
        actual = fns.get(repo)
        if actual is None:
            print(f"ERROR {repo} is a package dependency but absent from functions.yaml")
            bad = 1
        elif actual != version:
            print(f"ERROR {repo}: functions.yaml={actual} dependsOn={version}")
            bad = 1
        else:
            print(f"ok    {repo} {version}")
    return bad


if __name__ == "__main__":
    sys.exit(main())
```

- [ ] **Step 3: Run it locally**

```bash
python3 scripts/check_function_pins.py; echo "exit=$?"
```

Expected: three `ok` lines and `exit=0`.

- [ ] **Step 4: Commit and push, then confirm CI is green**

```bash
git add -A
git commit -m "ci: enforce generate-sync, render equivalence and pin agreement"
git push
gh run watch
```

Expected: all steps pass. `make render` is the one that needs Docker; GitHub's `ubuntu-latest`
provides it.

---

## Task 9: Release workflow

**Files:**
- Create: `.github/workflows/release.yaml`

**Interfaces:**
- Produces: on tag `v*`, two packages on ghcr.io and an `xrd-crds.yaml` release asset.

- [ ] **Step 1: Write `.github/workflows/release.yaml`**

```yaml
name: Release

on:
  push:
    tags: ['v*']

permissions:
  contents: write   # create the release and upload assets
  packages: write   # push to ghcr.io

jobs:
  release:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v5

      - uses: jdx/mise-action@v3

      - run: pip install pyyaml

      - name: Derive the version from the tag
        id: v
        run: echo "version=${GITHUB_REF_NAME#v}" >> "$GITHUB_OUTPUT"

      - name: Build packages and CRDs
        run: |
          make build VERSION=${{ steps.v.outputs.version }}
          make crds

      # crossplane xpkg push reuses the Docker credential store; the CLI has no
      # `login` subcommand of its own (verified against v2.1.3).
      - name: Push both packages
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        run: |
          echo "${GITHUB_TOKEN}" | docker login ghcr.io -u "${{ github.actor }}" --password-stdin
          make push VERSION=${{ steps.v.outputs.version }}

      - name: Create the release with the schema asset
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        run: |
          gh release create "${GITHUB_REF_NAME}" \
            --title "${GITHUB_REF_NAME}" \
            --generate-notes \
            build/xrd-crds.yaml
```

- [ ] **Step 2: Commit and push**

```bash
git add -A
git commit -m "ci: publish both packages and the schema asset on tag"
git push
```

---

## Task 10: Publish 0.1.0

**Files:** none — this is a release task.

- [ ] **Step 1: Confirm the working tree is clean and CI is green**

```bash
git status --porcelain          # expect empty
gh run list --limit 1
```

- [ ] **Step 2: Tag and push**

```bash
git tag v0.1.0
git push origin v0.1.0
gh run watch
```

Expected: the Release workflow succeeds.

- [ ] **Step 3: Verify both packages are pullable anonymously**

Anonymous pull matters: Crossplane pulls without credentials unless `imagePullSecrets` are
configured, and `cloud-native-ref` configures none.

`crossplane xpkg install` has no `--dry-run` flag (verified against v2.1.3), so check the registry
directly:

Use a throwaway Docker config directory rather than `docker logout`, which would drop the
operator's real ghcr.io credentials from their machine:

```bash
ANON=$(mktemp -d)
for p in core aws; do
  if DOCKER_CONFIG="$ANON" docker manifest inspect \
       "ghcr.io/smana/crossplane-configuration-$p:0.1.0" >/dev/null 2>&1; then
    echo "$p: pullable anonymously"
  else
    echo "$p: NOT pullable anonymously"
  fi
done
rm -rf "$ANON"
```

Expected: `core: pullable` and `aws: pullable`. If either fails with `denied` or `unauthorized`,
set the package visibility to public at
`https://github.com/users/Smana/packages/container/crossplane-configuration-<pkg>/settings`.

- [ ] **Step 4: Verify the release asset**

```bash
gh release view v0.1.0 --json assets --jq '.assets[].name'
curl -fsSL https://github.com/Smana/crossplane-configuration/releases/download/v0.1.0/xrd-crds.yaml \
  | grep -c '^kind: CustomResourceDefinition'
```

Expected: `xrd-crds.yaml`, and a count of `5`.

- [ ] **Step 5: Confirm `cloud-native-ref` is still untouched**

```bash
git -C /home/smana/Sources/cloud-native-ref status --porcelain
```

Expected: empty. Publishing changes no cluster and no consumer — `cloud-native-ref` still runs
entirely from its own OCI modules. Task 11 proves the packages are safe to install before anything
is cut over.

---

## Task 11: Prove XRD adoption on a throwaway cluster

**Files:** none — this is a verification task.

This settles the design's highest-severity risk: installing the Configuration packages must
**adopt** the existing XRDs, not delete and recreate them. Recreating would orphan 37 live claims on
`mycluster-0`. Prove it on kind, never first on the real cluster.

- [ ] **Step 1: Create a throwaway cluster and install Crossplane**

```bash
kind create cluster --name xp-adopt
helm repo add crossplane-stable https://charts.crossplane.io/stable
helm repo update
helm install crossplane crossplane-stable/crossplane \
  --namespace crossplane-system --create-namespace --version 2.3.4 --wait
kubectl -n crossplane-system get pods
```

Expected: crossplane and crossplane-rbac-manager pods `Running`.

- [ ] **Step 2: Apply the XRDs the *old* way, exactly as `cloud-native-ref` does today**

```bash
export CFG=/home/smana/Sources/cloud-native-ref/infrastructure/base/crossplane/configuration
kubectl apply -f "$CFG/app-definition.yaml" -f "$CFG/kvstore-definition.yaml"
kubectl get xrd
```

Expected: `apps.cloud.ogenki.io` and `kvstores.cloud.ogenki.io`, eventually `ESTABLISHED=True`.

- [ ] **Step 3: Record the identities that must survive**

```bash
kubectl get xrd apps.cloud.ogenki.io -o jsonpath='{.metadata.uid}{"\n"}' | tee /tmp/xrd-uid-before
kubectl get crd apps.cloud.ogenki.io -o jsonpath='{.metadata.uid}{"\n"}' | tee /tmp/crd-uid-before
```

- [ ] **Step 4: Create a claim, so there is something to orphan**

```bash
kubectl create namespace demo
kubectl -n demo apply -f "$CFG/examples/kvstore-basic.yaml"
kubectl -n demo get kvstore -o wide
kubectl -n demo get kvstore -o jsonpath='{.items[0].metadata.uid}{"\n"}' | tee /tmp/claim-uid-before
```

- [ ] **Step 5: Install the package published in Task 10**

```bash
kubectl apply -f - <<'EOF'
apiVersion: pkg.crossplane.io/v1
kind: Configuration
metadata:
  name: crossplane-configuration-core
spec:
  package: ghcr.io/smana/crossplane-configuration-core:0.1.0
EOF
kubectl wait --for=condition=Healthy configuration/crossplane-configuration-core --timeout=5m
```

Expected: `configuration.pkg.crossplane.io/crossplane-configuration-core condition met`.

Installing the real published artifact — rather than a hand-pushed release candidate — means this
task tests exactly the bytes Stage 2 will install, and needs no registry credentials.

- [ ] **Step 6: Assert adoption, not recreation**

```bash
kubectl get xrd apps.cloud.ogenki.io -o jsonpath='{.metadata.uid}{"\n"}' > /tmp/xrd-uid-after
kubectl get crd apps.cloud.ogenki.io -o jsonpath='{.metadata.uid}{"\n"}' > /tmp/crd-uid-after
kubectl -n demo get kvstore -o jsonpath='{.items[0].metadata.uid}{"\n"}' > /tmp/claim-uid-after

diff /tmp/xrd-uid-before   /tmp/xrd-uid-after   && echo "XRD adopted"
diff /tmp/crd-uid-before   /tmp/crd-uid-after   && echo "CRD adopted"
diff /tmp/claim-uid-before /tmp/claim-uid-after && echo "claim survived"
```

Expected: all three print their `adopted` / `survived` line.

**If any UID changed, STOP.** Stage 2 is unsafe as designed and the plan needs a migration step
(likely `kubectl label`/`annotate` to hand ownership to the package before install). Record the
finding in the design's Risks table and raise it rather than proceeding.

- [ ] **Step 7: Tear down**

```bash
kind delete cluster --name xp-adopt
```

- [ ] **Step 8: Record the result in the design document**

This is evidence for a `cloud-native-ref` design doc, so it is committed there — on the existing
`feat/crossplane-configuration-extraction` branch, which is documentation-only and does not violate
the read-only constraint on the platform's functional files.

Append the measured outcome to the Risks table row for XRD recreation, then:

```bash
cd /home/smana/Sources/cloud-native-ref
git add docs/superpowers/specs/2026-08-18-crossplane-configuration-extraction-design.md
git commit -m "docs(crossplane): record the XRD adoption result from the kind cluster"
```

---

## Stage 1 exit criteria

| # | Criterion | Evidence |
|---|---|---|
| 1 | Both packages published at `0.1.0`, pullable anonymously | Task 10 Step 3 |
| 2 | 12/12 examples render byte-identical to the pre-extraction output | `make render` → `12/12 match` |
| 3 | 110/110 KCL tests pass | `make test` |
| 4 | `xrd-crds.yaml` is byte-identical to `cloud-native-ref`'s current output | Task 7 Step 4 |
| 5 | Installing the packages adopts existing XRDs without changing any UID | Task 11 Step 6 |
| 6 | `cloud-native-ref` is unmodified | `git status --porcelain` empty |

Stage 2 (the `cloud-native-ref` cutover) is a separate plan and must not be started here.
