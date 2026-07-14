# Spec: App composition workload types (web/worker/cron), sidecars, and container ergonomics

**ID**: SPEC-007
**Issue**: N/A <!-- pending — create with `gh issue create --title "[SPEC] App composition workload types" --label "spec,spec:draft"` and replace this line -->
**Status**: draft
**Type**: composition
**Created**: 2026-07-14
**Last updated**: 2026-07-14

> The **spec** is the contract: *WHAT* we are delivering and *why*. Freeze it once approved. How we build it lives in [`plan.md`](plan.md) (which also tracks tasks and the review checklist); decisions made during filling live append-only in [`clarifications.md`](clarifications.md).

---

## Summary

Extend the `App` composition to cover the three workload shapes most companies deploy — HTTP services, background workers, and scheduled jobs — plus multi-container pods (sidecars, init containers), simple persistence, flexible health probes, and extra service ports. Ship a comprehensive, task-oriented user guide so any application developer can self-serve without reading the KCL. Zero breaking changes: `image.repository` stays the only required field and every existing claim renders identically.

---

## Problem

The `App` abstraction is the platform's developer-facing entry point, but today it can only express a single-container HTTP service. Real application teams also ship:

- **Background workers** (queue consumers, event processors) — today they must abuse the web shape and get an unwanted Service plus failing HTTP probes.
- **Scheduled jobs** (nightly cleanup, report generation) — no CronJob support at all; teams fall back to raw manifests, losing security defaults, network policies, and GitOps consistency.
- **Sidecars and init containers** (auth proxies, log shippers, migrations, wait-for-dependency) — impossible today; the pod has exactly one container.
- **Simple persistent storage** — only via the `extraVolumes` passthrough, hand-writing PVCs; the `deploymentStrategy` docstring already documents the RWO multi-attach trap this causes.
- **Non-HTTP probes and multi-port services** — probes are hardcoded HTTP; gRPC services and separate metrics ports can't be modeled.

Without this, the abstraction covers maybe half of a typical company's workloads, and everything else bypasses the platform's guardrails. Additionally, the current README documents fields that don't match the actual XRD schema (e.g., `route.port`, `networkPolicies.policies`), so even the supported surface is hard to use correctly — a symptom that developer-facing docs are a second-class artifact.

---

## User Stories

### US-1: Deploy a background worker (Priority: P1)

As an **application developer**, I want to deploy a queue consumer with `type: worker`, so that I get the platform's security defaults and GitOps flow without a pointless Service, route, or failing HTTP probes.

**Acceptance Scenarios**:
1. **Given** an App claim with `type: worker` and a `command`, **When** the composition renders, **Then** a Deployment is created and no Service, HTTPRoute, or Gateway is rendered.
2. **Given** a worker claim with no `healthProbes` set, **When** the composition renders, **Then** the container has no liveness/readiness probes.
3. **Given** a worker claim with `autoscaling.enabled: true`, **When** the composition renders, **Then** an HPA is created targeting the Deployment.

### US-2: Deploy a scheduled job (Priority: P1)

As an **application developer**, I want to declare a recurring job with `type: cron` and a `schedule`, so that nightly tasks run under the same abstraction, image, env, and secrets as my services.

**Acceptance Scenarios**:
1. **Given** an App claim with `type: cron` and `schedule: "0 3 * * *"`, **When** the composition renders, **Then** a CronJob is created with `concurrencyPolicy: Forbid`, `backoffLimit: 3`, and restricted-PSS-compliant pod template.
2. **Given** a `type: cron` claim without `schedule`, **When** the claim is applied, **Then** the API server rejects it with a clear CEL validation message.
3. **Given** a `type: cron` claim with `route.enabled: true` or `autoscaling.enabled: true`, **When** the claim is applied, **Then** the API server rejects it.

### US-3: Add sidecars and init containers (Priority: P1)

As an **application developer**, I want to add sidecar containers (e.g., oauth proxy, log shipper) and init containers (e.g., DB migration, wait-for-dependency) to my App, so that common multi-container patterns work without leaving the abstraction.

**Acceptance Scenarios**:
1. **Given** an App with one entry in `sidecars`, **When** the composition renders, **Then** the pod has two containers and the sidecar carries the constitution's container security defaults (non-root, read-only rootfs, drop ALL, seccomp RuntimeDefault) unless explicitly overridden.
2. **Given** an App with one entry in `initContainers`, **When** the composition renders, **Then** the pod has one init container with the same security defaults.
3. **Given** a sidecar named `main` or two sidecars with the same name, **When** the claim is applied, **Then** the API server rejects it.

### US-4: Simple persistence (Priority: P2)

As an **application developer**, I want `persistence: {enabled: true, size: 10Gi, mountPath: /data}`, so that I get a PVC mounted without hand-writing volumes, and without hitting the RWO multi-attach trap on rollout.

**Acceptance Scenarios**:
1. **Given** an App with `persistence.enabled: true`, **When** the composition renders, **Then** a PVC is created and mounted at `mountPath`, and the Deployment strategy defaults to `Recreate`.
2. **Given** the same App with an explicit `deploymentStrategy: RollingUpdate`, **When** the composition renders, **Then** the explicit value wins.
3. **Given** `persistence.enabled: true` with RWO access mode and `autoscaling.enabled: true`, **When** the claim is applied, **Then** the API server rejects it.

### US-5: Flexible probes and service ports (Priority: P2)

As an **application developer**, I want TCP/gRPC/exec probes, a startup probe, and extra service ports, so that gRPC services, slow-boot apps, and separate metrics ports are expressible.

**Acceptance Scenarios**:
1. **Given** `healthProbes.liveness.type: grpc`, **When** the composition renders, **Then** the container has a gRPC liveness probe on the resolved port.
2. **Given** `service.extraPorts` with a `metrics` entry, **When** the composition renders, **Then** the Service exposes both the main port and the metrics port.

### US-6: Self-service user guide (Priority: P1)

As an **application developer new to the platform**, I want a comprehensive task-oriented guide, so that I can deploy a web app, worker, cron job, sidecar, or database-backed app without reading KCL or the XRD.

**Acceptance Scenarios**:
1. **Given** the guide, **When** a developer follows the "deploy your first app" section verbatim, **Then** the resulting claim is accepted by the API server and renders successfully.
2. **Given** the guide's field reference, **When** compared against the XRD schema, **Then** every documented field exists in the schema with matching defaults (no drift like the current README).

---

## Requirements

### Functional

- **FR-001**: The XRD MUST add `spec.type` with enum `web | worker | cron`, defaulting to `web`; existing claims (no `type`) MUST render byte-identical to today.
- **FR-002**: `type: worker` MUST render a Deployment without Service, HTTPRoute, or Gateway, and MUST NOT default any HTTP probes; explicitly configured probes are honored.
- **FR-003**: `type: cron` MUST render a CronJob (`schedule` required) with defaults `concurrencyPolicy: Forbid`, `backoffLimit: 3`, `successfulJobsHistoryLimit: 3`, `failedJobsHistoryLimit: 3`, `restartPolicy: OnFailure`, tunable via an optional `spec.cron` block.
- **FR-004**: The XRD MUST add top-level `command` and `args` for the main container.
- **FR-005**: The XRD MUST add `sidecars[]` and `initContainers[]` with a reduced container schema (name, image string, command, args, env, envFrom, resources, ports [sidecars only], volumeMounts, optional securityContext override); all containers inherit the constitution's security defaults unless overridden.
- **FR-006**: The XRD MUST add `persistence` (`enabled`, `size`, `mountPath`, optional `storageClass`, `accessModes` default `[ReadWriteOnce]`) rendering a PVC + volume + mount on the main container.
- **FR-007**: The `deploymentStrategy` schema default MUST move from the XRD into KCL: absent → `RollingUpdate`, except `Recreate` when `persistence.enabled`; an explicit user value always wins.
- **FR-008**: `healthProbes.{liveness,readiness}` MUST support `type: http | tcp | grpc | exec` (default `http`, port defaulting to `service.port`), and a new optional `healthProbes.startup` probe MUST be supported.
- **FR-009**: The XRD MUST add `service.extraPorts[]` (`name`, `port`, optional `targetPort`, `protocol` default TCP).
- **FR-010**: The XRD MUST add `imagePullSecrets[]` (secret names) and `terminationGracePeriodSeconds`.
- **FR-011**: CEL validations MUST enforce: `schedule` present iff `type == cron`; `route.enabled`/`gateway.enabled` only when `type == web`; `autoscaling.enabled`/`pdb.enabled` forbidden when `type == cron`; RWO persistence incompatible with autoscaling; container names unique with `main` reserved.
- **FR-012**: Readiness (`option("params").ocds`): Deployment-backed types keep the `Available` condition check; CronJob is statically ready when created.
- **FR-013**: A comprehensive user guide MUST ship at `docs/apps-user-guide.md`, task-oriented (quick start; one section per workload type; sidecars/init; persistence; probes; secrets/config; database/cache/S3; routing & network policies; troubleshooting) plus a complete field reference generated against the actual XRD; the module README MUST be corrected to match the schema and link to the guide.

### Non-Goals

- StatefulSets / ordered identity / per-pod PVCs (operators cover stateful workloads).
- Named sidecar presets (`oauthProxy.enabled`-style toggles).
- KEDA / custom-metrics autoscaling (InferenceService territory) and HPA memory target.
- One-shot Jobs (only recurring CronJobs; a one-shot can use `suspend`-style workarounds or raw manifests for now).
- Native Kubernetes sidecars (initContainer `restartPolicy: Always`); regular containers suffice for this round.
- Multi-process `processes[]` in a single claim (one claim per process; see CL-3).

---

## Success Criteria

Each criterion must be **falsifiable** — a human or `/verify-spec` must be able to answer yes/no with cluster evidence.

- **SC-001**: `crossplane render` of every pre-existing example (`app-basic.yaml`, `app-complete.yaml`) produces the same resources as before the change (diff empty modulo annotation noise).
- **SC-002**: A `type: worker` example renders a Deployment and zero Service/HTTPRoute/Gateway resources; a `type: cron` example renders a CronJob whose pod template passes restricted PSS (kube-linter + Polaris score ≥ 85).
- **SC-003**: Invalid claims (cron without schedule, cron with route, duplicate sidecar names, RWO persistence + autoscaling) are each rejected at apply time with a CEL message naming the offending field.
- **SC-004**: An App with a sidecar and an init container renders both with full constitution security context; `main_test.k` asserts container counts, naming, and security fields, and `./scripts/validate-kcl-compositions.sh` exits 0.
- **SC-005**: `persistence.enabled: true` renders a PVC and flips the strategy to `Recreate` unless explicitly overridden (asserted in `main_test.k`).
- **SC-006**: `docs/apps-user-guide.md` exists; every YAML snippet in it passes `kubeconform`/`crossplane render`; every field in its reference table exists in the XRD with matching type and default.

---

## Open questions

<!-- Mark unresolved decisions here. Use /clarify to walk through each one.
Resolved decisions are appended to clarifications.md (never inlined here);
reference them by ID (CL-1, CL-2, ...) once resolved. -->

- CL-1 — Workload scope: web + workers + cron in one App kind
- CL-2 — Multi-container model: primary + `sidecars[]`/`initContainers[]`
- CL-3 — Workload expression: `spec.type` discriminator, one claim per process
- CL-4 — Feature cut for this round (persistence, probes, extraPorts in; HPA memory out)
- CL-6 — Sidecar/initContainer image is a plain string `repo:tag`
- CL-7 — Infra blocks (sqlInstance/kvStore/s3Bucket) stay orthogonal to `type`; cron may provision them (guide notes the smell)

---

## References

- Plan: [plan.md](plan.md) — design, tasks, review checklist
- Clarifications: [clarifications.md](clarifications.md)
- Constitution: [docs/specs/constitution.md](../constitution.md)
- Similar spec: [SPEC-002 composition-owned gateway routing](../002-composition-owned-gateway-routing/spec.md)
- Related ADR: [ADR-0001 KCL for Crossplane compositions](../../decisions/0001-use-kcl-for-crossplane-compositions.md)
