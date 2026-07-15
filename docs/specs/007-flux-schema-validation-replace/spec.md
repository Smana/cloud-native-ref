# Spec: Flux schema validation — replace kubeconform/Datree, render Kustomize+Helm into one validated bundle

**ID**: SPEC-007
**Issue**: [#1578](https://github.com/Smana/cloud-native-ref/issues/1578)
**Status**: draft
**Type**: platform
**Created**: 2026-07-13
**Last updated**: 2026-07-13

> The **spec** is the contract: *WHAT* we are delivering and *why*. Freeze it once approved. How we build it lives in [`plan.md`](plan.md) (which also tracks tasks and the review checklist); decisions made during filling live append-only in [`clarifications.md`](clarifications.md).

---

## Summary

Replace the kubeconform + Datree-catalog validation stack with the Flux schema plugin (`flux` 2.9.2, `flux-schema` v0.10.2), and introduce a single manifest renderer whose output feeds two enforcing gates: `flux schema validate` (structure + CEL) and `polaris audit` (workload best practices). The result is zero silently-skipped resources and a best-practices gate that sees the platform's real workloads instead of 5% of them.

---

## Problem

Two independent blind spots, both currently invisible because CI is green.

**1. CI silently skips what it does not understand.** The kubeconform Dagger module runs with `-ignore-missing-schemas` (`Smana/daggerverse:kubeconform/dagger/main.go:327`). Any resource whose schema is absent from the [Datree CRDs-catalog](https://github.com/datreeio/CRDs-catalog) is skipped and CI passes. Enumerating all 79 `apiVersion`/`kind` pairs across the Flux-managed directories against that catalog: **57 validated, 8 silently skipped**. The 8 include all four `cloud.ogenki.io` XRD kinds — `App`, `SQLInstance`, `InferenceService`, `EPI` — carried by **41 files** (9 EPIs, the 4 LLM apps, Harbor, Zitadel, PEV2, and every `examples/` claim). The platform's entire user-facing API is the one thing nothing validates.

This is not theoretical. A validation pass with schemas generated from the XRDs found three real defects that are merged and live in the repository today:

| Defect | Impact |
|---|---|
| `examples/inferenceservice-complete.yaml` sets `spec.route.parentGateway` and `parentGatewayNamespace` | Fields are **not declared in the XRD**. The example cannot be applied. |
| `examples/sqlinstance-basic.yaml` omits `spec.instances` and `spec.roles[0].superuser` | Both are `required` in the XRD. Copy-pasting the "basic" example yields an API rejection. |
| `examples/epi.yaml` sets `spec.claimRef` | Stale Crossplane v1 claim semantics; the XRD is `scope: Namespaced` (v2). |

**2. The best-practices gate inspects almost nothing, and cannot fail.** Three gates exist and none can fail a PR:

- **Polaris** — `find … | head -20` piped to `polaris validate … || true`: at most 20 arbitrary files, exit code discarded.
- **Checkov** — `soft_fail: true`.
- **Trivy** — runs `scan-type: fs`, whose default scanners are `[vuln,secret]`; `misconfig` is never enabled and `trivy config` is never invoked in CI, despite `.trivyignore.yaml` existing and `CLAUDE.md` documenting it.

Fixing Polaris's exit code alone would not help, because Polaris reads raw repository files and this platform's workloads live inside Helm charts. The repository contains **2 Deployments and 2 CronJobs** as raw manifests. Rendering just **16 of the 41 HelmReleases** produces **20 Deployments, 7 StatefulSets, 3 DaemonSets and 3 Jobs**. The gate is blind to roughly 95% of the pods that actually run.

That blindness is exactly where the platform's recurring bug class lives. `.claude/rules/spec-constitution.md` devotes a section to `seccompProfile: RuntimeDefault` and "per-component `securityContext` REPLACES the top-level default" — these are **PSS admission failures, not schema violations**. `flux schema` will never catch them; Polaris will, but only against rendered charts.

**Why now**: `flux` 2.9.2 and `flux-schema` v0.10.2 both shipped 2026-07-13, `fluxcd/agent-skills` v0.1.0 now depends on the schema plugin, and the hosted [ecosystem catalog](https://schemas.fluxoperator.dev) (~9,000 schemas, rebuilt daily) removes the reason we depended on a community catalog in the first place.

---

## User Stories

### US-1: Claims are validated before merge (Priority: P1)

As a **platform engineer**, I want my `App` / `SQLInstance` / `InferenceService` / `EPI` claims validated against the XRD schema in CI, so that a claim the API server would reject never reaches `main`.

**Acceptance Scenarios**:
1. **Given** a PR adding an `App` claim with a field not declared in the XRD, **When** CI runs, **Then** the validation job fails and names the offending JSON path.
2. **Given** a PR adding a `SQLInstance` claim missing a `required` field, **When** CI runs, **Then** the job fails citing the missing property.
3. **Given** an XRD gains a new field, **When** CI runs on the next PR, **Then** claims using that field validate without any catalog being manually refreshed.

### US-2: No resource is validated by accident (Priority: P1)

As a **platform engineer**, I want CI to fail on any resource kind it has no schema for, so that adding a new CRD can never silently reintroduce a validation blind spot.

**Acceptance Scenarios**:
1. **Given** a PR introducing a resource whose kind resolves to no schema, **When** CI runs, **Then** the job fails with `schema-not-found` rather than passing.
2. **Given** the manifest set as it exists at merge time, **When** the validation job runs, **Then** zero documents report status `skipped` for reason `schema-not-found`.

### US-3: Workload best practices are actually enforced (Priority: P1)

As a **platform engineer**, I want Polaris to audit the workloads my Helm charts really produce and to fail the build on `danger`, so that the securityContext/PSS bug class is caught in CI instead of at cluster admission.

**Acceptance Scenarios**:
1. **Given** the rendered bundle, **When** `polaris audit` runs, **Then** it inspects workloads from rendered HelmReleases, not only the 4 raw ones.
2. **Given** a workload that allows privilege escalation, **When** CI runs, **Then** the job exits non-zero.

### US-4: One command, everywhere (Priority: P2)

As a **platform engineer or AI agent**, I want a single command that reproduces CI's validation locally, so that "it validates" is a claim backed by a fresh command run, as `.claude/rules/process.md` requires.

**Acceptance Scenarios**:
1. **Given** a working copy, **When** I run `./scripts/validate-manifests.sh`, **Then** it performs the same rendering and the same two gates as CI, and exits with CI's exit code.

---

## Requirements

### Functional

- **FR-001**: The toolchain MUST be pinned in `mise.toml` — `flux` 2.9.2 (today an unpinned 2.8.8, which has no `flux plugin` subcommand), plus `helm` and `kustomize`. The `flux-schema` plugin MUST be installed reproducibly in CI and locally.
- **FR-002**: A generated schema catalog MUST be produced at validation time (never committed, so it cannot drift) from two sources: the repository's 4 XRDs, and the Envoy AI Gateway CRDs (`aigateway.envoyproxy.io`, absent from the ecosystem catalog — the last 4 unresolvable documents).
- **FR-003**: The XRD→CRD conversion MUST inject the fields Crossplane itself injects into generated CRDs — notably `spec.crossplane` (`compositionRef`, `compositionSelector`, `compositionUpdatePolicy`, `compositionRevisionRef`, `resourceRefs`). Without this, in-use manifests (`tooling/base/harbor/sqlinstance.yaml`, `security/base/zitadel/sqlinstance.yaml`) produce false positives.
- **FR-004**: A renderer MUST emit a single bundle containing every `kustomize build` overlay with Flux `postBuild` variables substituted using the CI fixture values, plus every HelmRelease rendered via `helm template` with its own `spec.values`. Rendering MUST resolve `sourceRef` namespace defaults (a naive prototype resolved only 19 of 33) and MUST pass `--kube-version` for charts that gate on it (Zitadel requires `>= 1.30.0-0`).
- **FR-005**: `flux schema validate` MUST run with `skipMissingSchemas: false`, against `schemaLocation: [./.schemas, default, ecosystem]`, configured in a repo-root `.fluxschema.yml` shared by CI, humans, and agents.
- **FR-006**: Non-Kubernetes YAML MUST be excluded by configuration, not by ignoring failures: `kustomization.yaml` (70 build inputs) and `settings-example.yaml` (4 KCL settings files).
- **FR-007**: `polaris audit` MUST run against the rendered bundle using the existing `.polaris.yaml`, failing the build on `danger`.
- **FR-008**: Both kubeconform Dagger steps MUST be removed from `.github/workflows/ci.yaml`; Checkov MUST drop its now-redundant `kubernetes` framework, retaining `terraform,secrets`.
- **FR-009**: The three defects listed in *Problem* MUST be fixed.
- **FR-010**: `scripts/validate-manifests.sh` MUST wrap render + both gates as the single entry point CI invokes.
- **FR-011**: Documentation MUST be updated where it still names kubeconform — `CLAUDE.md` ("Validation Commands") and `.claude/rules/process.md` (evidence table).
- **FR-012**: The agent layer SHOULD be refreshed: `gitops-skills` 0.0.2 → v0.1.0, and the `schemas.fluxoperator.dev/mcp` server added to `.mcp.json` so agents validate at authoring time.

### Non-Goals

- **Schema-validating rendered Helm output as a feature in its own right.** Measured: 16 charts, 301 rendered documents, **297 valid, 0 real findings**. The Helm values are structurally clean; the yield does not justify a gate. Rendering is still built — it exists to feed Polaris (FR-007).
- **Triaging Polaris `warning` findings** (missing probes, resource limits, `readOnlyRootFilesystem`). The gate lands failing on `danger` only; the warning backlog across ~80 newly-visible workloads is separate work.
- **Enabling Trivy's `misconfig` scanner / `trivy config` in CI.** A real gap, but Polaris on the rendered bundle covers the same ground; consolidating on one enforcing gate beats adding a third. Tracked separately.
- Replacing the Dagger `pre-commit-tf` module or any OpenTofu validation.
- Adopting the upstream `fluxcd/flux-schema` composite action. Its `validate` action offers no `envsubst` hook, which FR-004 requires, and its `helm-charts` input renders only *local* charts (`Chart.yaml`) — of which this repository has zero.

---

## Success Criteria

- **SC-001**: `./scripts/validate-manifests.sh` exits 0 on this branch once FR-009 is fixed, and its `flux schema validate` report shows **zero** documents with status `skipped` and reason `schema-not-found`.
- **SC-002**: A deliberately malformed claim (a field not declared in the `App` XRD) causes the validation job to exit non-zero, naming the JSON path.
- **SC-003**: A deliberately introduced `privilegeEscalationAllowed` workload causes `polaris audit` to exit non-zero.
- **SC-004**: The `flux schema validate` report covers all four `cloud.ogenki.io` kinds across the 41 claim-carrying files — none reported as `skipped`.
- **SC-005**: `polaris audit` inspects ≥ 30 workloads (Deployments + StatefulSets + DaemonSets + Jobs) from the rendered bundle, versus 4 today.
- **SC-006**: `.github/workflows/ci.yaml` contains no reference to the `kubeconform` Dagger module, and CI is green on this branch.

---

## Open questions

<!-- Mark unresolved decisions here. Use /clarify to walk through each one.
Resolved decisions are appended to clarifications.md (never inlined here);
reference them by ID (CL-1, CL-2, ...) once resolved. -->

None outstanding.

<!-- Resolved questions appear below as `CL-N — <summary>` lines, appended by /clarify. -->

- CL-1 — Validate rendered Kustomize output, not raw files (patch fragments cannot satisfy a full schema).
- CL-2 — Render fresh every CI run; cache only the Helm chart download cache, never the rendered bundle.

---

## References

- Plan: [plan.md](plan.md) — design, tasks, review checklist
- Clarifications: [clarifications.md](clarifications.md)
- Constitution: [docs/specs/constitution.md](../constitution.md)
- Upstream announcement: [Flux schema validation](https://fluxcd.io/blog/2026/07/flux-schema-validation/) (2026-07)
- Upstream repo: [fluxcd/flux-schema](https://github.com/fluxcd/flux-schema) v0.10.2
- Ecosystem catalog: [schemas.fluxoperator.dev](https://schemas.fluxoperator.dev)
- Agent skills: [fluxcd/agent-skills](https://github.com/fluxcd/agent-skills) v0.1.0
