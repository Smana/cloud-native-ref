# CI/CD Workflows

How continuous integration and delivery work in this repository.

## Overview

- **Shift left** — pre-commit hooks catch issues before a commit; GitHub Actions gate every pull request.
- **Validate what Flux applies** — manifests are rendered (Kustomize overlays + `helm template`) and validated as the rendered desired state, not as raw source files.
- **GitOps delivery** — nothing is deployed from CI. On merge, Flux reconciles `main` onto the cluster.
- **Publish artifacts** — container images and Crossplane KCL modules are built and pushed to GHCR.

CI never applies changes to a cluster. It validates, scans, and publishes; Flux owns delivery.

## Workflows at a glance

| Workflow | Trigger | Purpose |
|----------|---------|---------|
| `ci.yaml` | PR → main | The main gate: OpenTofu validation, security scanning, manifest validation, rendered diff, shellcheck |
| `app-wizard.yml` | push / PR | Go lint & test + UI build & test for the App Wizard (`container-images/app-wizard/`) |
| `build-container-images.yml` | push / PR / dispatch | Detect changed images under `container-images/`, build each, push on non-PR events |
| `crossplane-modules.yml` | push / PR | Validate, test and publish the KCL Crossplane modules to GHCR |
| `vector-config-validation.yml` | push / PR | Validate the Vector log-parsing configuration |
| `spec-archive.yaml` | PR (merge) | SDD automation: archive a spec directory when its PR merges |
| `terramate-preview.yaml` / `terramate-drift-detection.yaml` | — | **Currently disabled** (fully commented out). See [Terramate workflows](#terramate-workflows-disabled). |

## CI pipeline (`ci.yaml`)

Runs on every pull request to `main`. Five independent jobs:

### Pre-commit checks 🛃

Validates the OpenTofu/Terraform code with the standard Terraform pre-commit hooks, across every stack:

- `terraform_fmt` — formatting
- `terraform_validate` — syntax / provider validation
- `terraform_tflint` — linting

These are the same hooks declared in `.pre-commit-config.yaml`, so `pre-commit run --all-files` reproduces the check locally.

### Security scanning 🔒

Three scanners, results uploaded to the GitHub **Security** tab as SARIF:

- **Trivy** — filesystem vulnerability scan (`CRITICAL,HIGH`, `ignore-unfixed`). Config exceptions live in `.trivyignore.yaml`.
- **Checkov** — IaC static analysis (`terraform,secrets` frameworks, soft-fail — reports without gating).
- **TruffleHog** — verified-secret detection across the PR diff (`--only-verified`).

### Kubernetes validation ☸

The hard manifest gate — `./scripts/validate-manifests.sh` (SPEC-007). It renders the repo the way Flux does — every Kustomize overlay (with `postBuild` vars) plus every HelmRelease through `helm template` — then runs two gates on the **rendered bundle**:

1. **`flux schema validate`** — structure **and** CEL rules, against the repo's own XRDs plus the Flux/CNCF catalogs. `skipMissingSchemas: false`, so an unknown Kind **fails the build** — it is not skipped. `Skipped: 0` is part of the pass criteria.
2. **Polaris** — workload best practices (privilege escalation, resource limits, probes, image tags) on the rendered controllers.

This replaced kubeconform, which ran with `-ignore-missing-schemas` and silently skipped every custom (`cloud.ogenki.io`, Flux, VictoriaMetrics, Cilium) resource. See [How manifest validation works](#how-manifest-validation-works) for the full pipeline.

### Rendered manifest diff 📝

**Informational only — never gates.** Renders the PR head and the merge base, then posts a per-PR comment showing exactly which rendered resources the PR **adds / changes / removes**. This is a diff of the rendered *desired state* (git vs git); cluster drift is Flux's concern, handled separately, so the job needs no cluster access and stays secretless and fork-safe.

> Note: on the PR that first introduces the renderer, the merge base predates it, so the base renders to nothing and the whole bundle shows as "added". That is a one-time bootstrap effect and resolves for every subsequent PR.

### Check the shell scripts 💻

`shellcheck -x -S warning` over every `scripts/**/*.sh`.

## How manifest validation works

`./scripts/validate-manifests.sh` is one entry point run **identically in CI and locally** (SPEC-007), so "the manifests are valid" is a claim backed by a command anyone — human or agent — can reproduce. It has three steps: build a schema catalog, render the repo into a bundle, then gate the bundle.

```
validate-manifests.sh
  ├─ [1/3] gen-catalog.sh        → .schemas/   (JSON Schemas for the repo's own CRDs)
  ├─ [2/3] render-bundle.py      → .bundle/    (what Flux actually applies)
  └─ [3/3] gate 1: flux schema validate .bundle --config .fluxschema.yml
           gate 2: polaris audit .bundle --config .polaris.yaml
```

`.schemas/` and `.bundle/` are **gitignored and regenerated on every run** — a committed catalog would drift from the XRDs it is derived from, and a committed bundle would be a silently-wrong green.

### Step 1 — schema catalog (`gen-catalog.sh` → `.schemas/`)

The repo's own custom resources have no schema in any public catalog, so one is built from source:

- Crossplane **XRDs → CRDs** (`xrd-to-crd.py` over `*-definition.yaml`), because `flux schema extract` reads CRDs, not XRDs.
- The **Envoy AI Gateway CRDs** are rendered from the exact chart version pinned in `flux/sources/` (so the catalog tracks the version actually deployed).
- `flux schema extract crd` pulls JSON Schemas out of both into `.schemas/`.
- A completeness check fails the build if any expected schema (`app`, `sqlinstance`, `inferenceservice`, `epi`, and the `aigateway.envoyproxy.io` group) came out missing or empty — so a broken catalog can't produce a false pass.

### Step 2 — render the bundle (`render-bundle.py` → `.bundle/`)

Renders the repo the way Flux applies it — because raw source files aren't what runs, and a raw patch fragment can never satisfy a full schema (CL-1):

- every top-most **Kustomize overlay** → `kustomize build` + Flux `postBuild` envsubst (fixture vars substituted);
- every **HelmRelease** → `helm template` with its own `spec.values` and `postRenderers` (both inline `spec.chart` and `spec.chartRef` sources);
- **standalone manifests** → copied verbatim.

The result is ~70 rendered controllers from a tree with only 2 raw Deployments — which is the point: pointing a validator at the source tree checks almost nothing.

### Step 3 — two gates on the rendered bundle

**Gate 1 — `flux schema validate` (`.fluxschema.yml`):** structure **and** CEL (`x-kubernetes-validations`) rules. Schema lookup order is the repo catalog → Flux built-in → the hosted CNCF ecosystem catalog:

```yaml
schemaLocation: [ ./.schemas, default, ecosystem ]
skipMissingSchemas: false          # unknown kind FAILS — the whole point of SPEC-007
skipFile: [ '.*', kustomization.yaml, settings-example.yaml ]  # non-manifest inputs
```

**Gate 2 — Polaris (`.polaris.yaml`):** workload best practices (privilege escalation, capabilities, resource limits, probes, image tags) with `--set-exit-code-on-danger`, on the rendered controllers.

### The two load-bearing properties

1. **`skipMissingSchemas: false`** — an unknown Kind *fails the build*, it is not skipped. `Skipped: 0` is part of the pass criteria, not decoration. The old kubeconform ran with `-ignore-missing-schemas`, so every `cloud.ogenki.io` claim went unvalidated for the life of the repo.
2. **Polaris audits the rendered bundle, not raw files** — the 2 raw Deployments in the tree become ~70 rendered controllers. A best-practices gate pointed at the source tree checks almost nothing.

### Requirements

`flux` ≥ 2.9 with the schema plugin (`mise install && flux plugin install schema`), Polaris 8.5.0, and `helm` / `kustomize` / `tofu` (pinned via `mise.toml`). `preflight.sh` hard-fails on a too-old flux client or a missing plugin rather than picking up a stale binary from `PATH`.

## Application & image builds

### App Wizard (`app-wizard.yml`)

On changes under `container-images/app-wizard/`:

- **Go lint & test** — `golangci-lint run ./...` + `go test ./...` for the backend.
- **UI build & test** — the embedded React SPA build + tests.

### Container images (`build-container-images.yml`)

Builds the images under `container-images/` (`app-wizard`, `pev2`, …):

- **Detect Changed Images** — determines which image directories changed (dynamic build matrix).
- **Build `<image>`** — builds each changed image. **On pull requests it builds but does not push** (validation only); on push to `main` and `workflow_dispatch` it pushes to `ghcr.io/smana/<image>`.
- Tags are `<branch>-<short-sha>` (e.g. `main-8886ba3`) plus `latest` on the default branch. Deployments pin an immutable `<branch>-<sha>` tag — never `latest` (which `IfNotPresent` would never re-pull).

## Crossplane modules (`crossplane-modules.yml`)

Validates and publishes the KCL Crossplane modules in `infrastructure/base/crossplane/configuration/kcl/`:

- **detect-changes** — which KCL modules changed.
- **quality-checks** — `kcl fmt` (CI-enforced), `kcl lint`, `kcl test`, and `kcl run -Y settings-example.yaml` (render with example inputs).
- **publish** — pushes the module to GHCR. Pull requests publish a `-pr<number>`-suffixed tag (overwritable, for testing); `main` publishes the release version. The publish rewrites `kcl.mod`'s `version` before push, since `kcl mod push` uses that field as the actual tag (see `.claude/rules/kcl-crossplane.md`).
- **validate-composition-versions** — ensures compositions reference published (non-PR-suffixed) module versions.
- **summary** — job summary with the published version, GHCR URL, and usage snippet.

## Other validation

### Vector configuration (`vector-config-validation.yml`)

Validates the Vector log-parsing configuration so a malformed pipeline is caught before it reaches the observability stack.

### Spec archive (`spec-archive.yaml`)

SDD automation. When a PR that touches a spec directory merges, the workflow moves it to `docs/specs/done/YYYY-Qn/NNN-slug/` and generates a `SUMMARY.md` (see `docs/specs/README.md`).

## Terramate workflows (disabled)

`terramate-preview.yaml` (OpenTofu plan preview on PRs) and `terramate-drift-detection.yaml` (scheduled drift detection) are present but **fully commented out** — they do not run today. When re-enabled they run `terramate script run preview` / `terramate script run drift detect` respectively. Treat them as templates, not active pipeline stages.

## Pre-commit hooks

Local validation before a commit (`.pre-commit-config.yaml`). Install once, then it runs on every commit:

```bash
pip install pre-commit   # or: uv pip install pre-commit
pre-commit install
pre-commit run --all-files   # run against the whole tree
```

| Group | Hooks |
|-------|-------|
| General | `trailing-whitespace`, `end-of-file-fixer`, `check-yaml`, `check-json`, `check-added-large-files`, `check-merge-conflict` |
| OpenTofu / Terraform | `terraform_fmt`, `terraform_validate`, `terraform_tflint` (`--tf-path=tofu`) |
| Secrets | `detect-secrets` (baseline: `.secrets.baseline`) |

KCL files (`.k`) are excluded from `trailing-whitespace` — KCL uses indented blank lines in some patterns.

## Local validation scripts

These are the same checks CI runs — cite them as evidence, and run them before pushing.

### Manifests — `./scripts/validate-manifests.sh`

The single entry point the `Kubernetes validation` job runs. Renders the repo and gates it with `flux schema validate` + Polaris (see above). A clean run reports `Valid: N, Invalid: 0, Skipped: 0`. Requires `flux` ≥ 2.9 with the schema plugin (`mise install && flux plugin install schema`).

### Crossplane compositions — `./scripts/validate-kcl-compositions.sh`

Four stages per composition: `kcl fmt` → syntax (`kcl run`) → `crossplane render` (basic + complete examples) → security. Run from the repo root to validate every composition.

```
📝 [1/3] Checking KCL formatting...        ✅
🧪 [2/3] Validating KCL syntax and logic... ✅
🎨 [3/3] Testing crossplane render...       ✅
✅ All checks passed for app
```

## Self-hosted GitHub runners

Self-hosted runner scale sets run in-cluster (`tooling/base/gha-runners/`), enabled via the `tooling` Kustomization. They give:

- **Private-endpoint access** — validate/reach resources not publicly exposed.
- **Lower latency and no egress charges** for heavy builds.
- **Secure execution** inside the VPC — ephemeral runners, network policies, secrets via External Secrets Operator, no long-lived credentials in the workflow.

## Troubleshooting

### KCL formatting failure
```bash
cd infrastructure/base/crossplane/configuration/kcl/<module>
kcl fmt .
```
CI fails if code is not formatted. Run `kcl fmt` before committing.

### Manifest validation failure (`Invalid` > 0 or `Skipped` > 0)
- A new custom Kind needs its XRD/CRD present so the generated schema catalog covers it — a missing schema is a **hard failure** by design (`Skipped: 0` is part of the pass criteria), unlike the old `-ignore-missing-schemas` behaviour.
- Check the failing resource's `apiVersion` matches the CRD version the catalog was built from.
- Reproduce locally with `./scripts/validate-manifests.sh`.

### Security scan findings
- **Trivy** — review the Security tab; bump base images/deps, or add a justified entry to `.trivyignore.yaml`.
- **TruffleHog** — never commit real secrets; use placeholders and store real values in AWS Secrets Manager. Update `.secrets.baseline` for a genuine false positive.

### Crossplane render failure
- **Module not found** — confirm the module is published to GHCR and the composition references the correct (non-PR-suffixed) version.
- **KCL logic error** — read the line number; test with `kcl run -Y settings-example.yaml`; watch for post-creation dict mutation (function-kcl #285).

## Related documentation

- [Technology Choices](./technology-choices.md)
- [Crossplane](./crossplane.md) — composition validation requirements
- [Spec-driven development](./specs/README.md) — SDD workflow, including SPEC-007 (manifest validation)
- `CLAUDE.md` → *Validation Commands* — the canonical local validation entry points
- [GitHub self-hosted runners](https://docs.github.com/en/actions/hosting-your-own-runners)
