# Spec: KVStore composition: replace Bitnami Valkey with official valkey-helm chart behind a cloud.ogenki.io XRD

**ID**: SPEC-012
**Issue**: [#1662](https://github.com/Smana/cloud-native-ref/issues/1662)
**Status**: draft
**Type**: composition
**Created**: 2026-07-20
**Last updated**: 2026-07-20

> The **spec** is the contract: *WHAT* we are delivering and *why*. Freeze it once approved. How we build it lives in [`plan.md`](plan.md) (which also tracks tasks and the review checklist); decisions made during filling live append-only in [`clarifications.md`](clarifications.md).

---

## Summary

Introduce a namespaced `KVStore` XRD (`cloud.ogenki.io/v1alpha1`) backed by the official
[valkey-io/valkey-helm](https://github.com/valkey-io/valkey-helm) chart, and migrate all three
Valkey consumers (App composition `kvStore`, Harbor, Grafana OnCall) onto it — removing every
`bitnamilegacy` image and the Bitnami Helm repository from the platform.

---

## Problem

All in-cluster Valkey today rides the Bitnami valkey chart 3.0.31 with `bitnamilegacy/valkey`
and `bitnamilegacy/redis-exporter` images — a registry **frozen since Broadcom shut the free
Bitnami catalog (Aug 2025)**: no updates, no CVE patches. Three consumers duplicate the same
delivery path independently:

1. `tooling/base/harbor/helmrelease-valkey.yaml` (auth via ExternalSecret)
2. `observability/base/grafana-oncall/helmrelease-valkey.yaml` (auth via ExternalSecret)
3. `infrastructure/base/crossplane/configuration/kcl/app/main.k` — a ~70-line inline
   HelmRelease blob per app with `kvStore.enabled`

Chart upgrades, image pins, and security posture must be maintained in three places; the
standalone instances (Harbor, OnCall) have **no CiliumNetworkPolicy** despite the constitution's
default-deny mandate; and the App composition latches kvStore readiness statically instead of
reading real conditions.

Decision context: in-cluster per [CL-1](clarifications.md), cache semantics per
[CL-2](clarifications.md), XRD + official chart per [CL-3](clarifications.md).

---

## User Stories

### US-1: Single maintained KV-store abstraction (Priority: P1)

As a **platform engineer**, I want **one `KVStore` composition wrapping a maintained chart and
official images**, so that **chart/image upgrades and security posture are managed in exactly
one place and the `bitnamilegacy` supply chain is gone**.

**Acceptance Scenarios**:
1. **Given** the composition is installed, **When** a `KVStore` claim is applied, **Then** a
   Valkey instance running official `valkey/valkey` images reaches Ready without any
   Bitnami chart or `bitnamilegacy` image involved.
2. **Given** the migration is complete, **When** the rendered bundle
   (`./scripts/validate-manifests.sh`) is searched for `bitnamilegacy` or the `bitnami`
   HelmRepository, **Then** there are zero references.

### US-2: App composition keeps its API (Priority: P1)

As an **application developer**, I want **`kvStore.enabled: true` in my App claim to keep
working unchanged**, so that **the migration is invisible at the App API surface**.

**Acceptance Scenarios**:
1. **Given** an App with `kvStore.enabled: true`, **When** the composition renders, **Then** a
   `KVStore` XR is created (mirroring the `sqlInstance` nesting pattern) and the workload still
   receives a working `REDIS_URL` environment variable pointing at the new service.
2. **Given** the same App claim used before the migration, **When** it is applied after the
   migration, **Then** no change to the claim manifest is required.

### US-3: Platform components as claims (Priority: P2)

As a **platform engineer**, I want **Harbor and Grafana OnCall to consume Valkey via small
`KVStore` claims with `auth.existingSecret`**, so that **their copy-pasted HelmReleases
disappear and both gain a default-deny network policy they lack today**.

**Acceptance Scenarios**:
1. **Given** the Harbor `KVStore` claim references its existing ExternalSecret, **When** Harbor
   reconciles, **Then** Harbor authenticates to the new Valkey and its UI/jobservice function.
2. **Given** the OnCall `KVStore` claim, **When** OnCall reconciles, **Then** OnCall workers
   connect with no Redis errors in logs.

---

## Requirements

### Functional

- **FR-001**: The platform MUST provide a namespaced XRD `KVStore` (`cloud.ogenki.io/v1alpha1`)
  with spec fields: `size` (nano|small|medium|large → explicit requests/limits), `replicas`
  (default 0 = standalone; N = read replicas, no auto-failover per CL-2), optional
  `auth.existingSecret`/`auth.passwordKey` (omitted = auth disabled), optional
  `persistence.size` (omitted = ephemeral per CL-4), `metrics` (default true).
- **FR-002**: The composition MUST render a HelmRelease of the official `valkey-io/valkey-helm`
  chart pinned to official `valkey/valkey` images, with the chart's HelmRepository defined
  under `flux/sources` (unsharded, per the flux-controller-sharding constraint).
- **FR-003**: Every `KVStore` instance MUST get a default-deny CiliumNetworkPolicy: ingress on
  the Valkey and exporter ports from same-namespace pods only; egress limited to DNS (+
  intra-instance replication traffic when `replicas > 0`).
- **FR-004**: When `metrics` is enabled the instance MUST be scraped by VictoriaMetrics
  (VMServiceScrape or chart-provided ServiceMonitor — whichever the plan verifies works).
- **FR-005**: The App composition MUST replace its inline kvStore HelmRelease with a nested
  `KVStore` XR, preserving the existing App API (`kvStore.enabled`, `type`, `size`) and the
  `REDIS_URL` auto-env behavior (value updated to the new service DNS name).
- **FR-006**: Harbor and Grafana OnCall MUST consume Valkey via `KVStore` claims wired to their
  existing ExternalSecrets; their Bitnami HelmReleases are removed.
- **FR-007**: After migration the `bitnami` HelmRepository and all `bitnamilegacy` image
  references MUST be removed, provided a repo-wide search confirms no other consumer remains.
- **FR-008**: Rendered workloads MUST satisfy the constitution's restricted-PSS security
  context (non-root, read-only rootfs, no privilege escalation, drop ALL, RuntimeDefault
  seccomp) and carry explicit resource requests and limits.
- **FR-009**: The composition MUST ship the constitution's documentation set: `README.md`,
  `settings-example.yaml`, `examples/` (basic + complete), `main_test.k` (resource counts,
  naming, security context).

### Non-Goals

- Automatic failover / Sentinel / cluster mode (CL-2; the XRD boundary allows adding a backend
  later without touching consumers).
- An ElastiCache-backed tier (CL-1).
- Data migration from the existing Bitnami instances — caches refill on redeploy; old PVCs are
  deleted after cutover.
- Adopting a Valkey operator (CL-3; revisit if failover requirements appear).
- Changing Valkey major version or eviction/tuning defaults beyond what the chart ships.

---

## Success Criteria

Each criterion must be **falsifiable** — a human or `/verify-spec` must be able to answer yes/no with cluster evidence.

- **SC-001**: `./scripts/validate-manifests.sh` exits 0 with `Invalid: 0, Skipped: 0`, and the
  rendered bundle contains zero occurrences of `bitnamilegacy` or the Bitnami valkey chart.
- **SC-002**: A `KVStore` claim (basic example) reaches `Synced=True, Ready=True` and its
  Valkey pod is Running/Ready on official `valkey/valkey` images within 5 minutes of apply.
- **SC-003**: An App with `kvStore.enabled: true` has `REDIS_URL` injected and its workload
  establishes a TCP connection to the Valkey service (no `DROPPED` verdicts between app and
  KVStore pods in Hubble).
- **SC-004**: Harbor and OnCall pods are Ready after cutover with no Redis/Valkey connection
  errors in their logs; Harbor jobservice processes a job.
- **SC-005**: `up == 1` for each instance's exporter target in VictoriaMetrics, for all three
  migrated consumers.
- **SC-006**: A connection attempt to a `KVStore` service from a pod in another namespace is
  dropped (Hubble `Policy denied` evidence), demonstrating the default-deny CNP.
- **SC-007**: `main_test.k` assertions pass via `./scripts/validate-kcl-compositions.sh`
  (exit 0), covering resource counts, `xplane-*`-consistent naming, and security context.

---

## Open questions

<!-- Mark unresolved decisions here. Use /clarify to walk through each one.
Resolved decisions are appended to clarifications.md (never inlined here);
reference them by ID (CL-1, CL-2, ...) once resolved. -->

- CL-1 — In-cluster (CNPG precedent) over ElastiCache/hybrid
- CL-2 — Cache semantics: standalone default, no auto-failover
- CL-3 — `KVStore` XRD wrapping the official valkey-helm chart
- CL-4 — Ephemeral storage by default; PVC opt-in

Plan-time verifications (HOW-level, tracked in `plan.md`): official chart's Service DNS
names/labels (feeds `REDIS_URL` + CNP selectors), ServiceMonitor vs VMServiceScrape choice,
security-context value paths in the official chart, remaining consumers of the `bitnami`
HelmRepository.

---

## References

- Plan: [plan.md](plan.md) — design, tasks, review checklist
- Clarifications: [clarifications.md](clarifications.md)
- Constitution: [docs/specs/constitution.md](../constitution.md)
- Official chart announcement: <https://valkey.io/blog/valkey-helm-chart/>
- Official chart repo: <https://github.com/valkey-io/valkey-helm>
- Nesting precedent: `kcl/app/main.k` `sqlInstance` block → `SQLInstance` XR
- Related composition: `infrastructure/base/crossplane/configuration/kcl/cloudnativepg/`
