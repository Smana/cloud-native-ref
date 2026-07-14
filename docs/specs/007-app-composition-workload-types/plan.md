# Plan: App composition workload types (web/worker/cron), sidecars, and container ergonomics

**Spec**: [SPEC-007](spec.md)
**Status**: draft
**Last updated**: 2026-07-14

> The **plan** covers *HOW* to deliver the spec. It may evolve during implementation (unlike `spec.md`, which freezes after approval). Append-only `clarifications.md` is where decisions are durable.

---

## Design

### API / Interface

All additions are optional; `image.repository` remains the only required field.

```yaml
apiVersion: cloud.ogenki.io/v1alpha1
kind: App
metadata:
  name: shop-consumer
  namespace: apps
spec:
  image:
    repository: myorg/shop
    tag: v3.1.0

  # ── Workload shape ─────────────────────────────
  type: worker                     # web | worker | cron, default: web
  # schedule: "0 3 * * *"          # required iff type=cron (CEL)
  # cron:                          # optional tuning (type=cron only)
  #   concurrencyPolicy: Forbid    # default; Allow | Replace
  #   backoffLimit: 3              # default
  #   activeDeadlineSeconds: 3600  # optional, no default
  #   restartPolicy: OnFailure     # default; Never allowed

  # ── Main container ergonomics ──────────────────
  command: ["./consume"]
  args: ["--queue", "orders"]
  imagePullSecrets: ["regcred"]
  terminationGracePeriodSeconds: 30

  # ── Multi-container ────────────────────────────
  initContainers:
    - name: migrate
      image: "myorg/shop:v3.1.0"   # plain string repo:tag (CL pending)
      command: ["./migrate"]
      # env, envFrom, resources, volumeMounts, securityContext (override)
  sidecars:
    - name: oauth-proxy
      image: "bitnami/oauth2-proxy:7.6"
      ports:
        - name: proxy
          containerPort: 4180
      # command, args, env, envFrom, resources, volumeMounts, securityContext

  # ── Persistence ────────────────────────────────
  persistence:
    enabled: true
    size: 10Gi
    mountPath: /data
    # storageClass: gp3            # default: cluster default
    # accessModes: [ReadWriteOnce] # default

  # ── Probes (reworked, web keeps today's HTTP defaults) ──
  healthProbes:
    liveness:
      type: http                   # http | tcp | grpc | exec
      path: /healthz               # http only
      port: 8080                   # default: service.port
      # command: [...]             # exec only
      initialDelaySeconds: 30
      periodSeconds: 10
    readiness: { ... }             # same shape
    startup: { ... }               # NEW, absent by default

  # ── Service ────────────────────────────────────
  service:
    port: 8080
    extraPorts:
      - name: metrics
        port: 9090
        # targetPort: 9090         # default: port
        # protocol: TCP            # default
```

### Resources Created

| Resource | Condition | Notes |
|----------|-----------|-------|
| Deployment | `type` in {web, worker} | Worker: no probe defaults |
| CronJob | `type == cron` | Forbid/backoffLimit=3/history=3, restricted-PSS pod template |
| Service | `type == web` | Main port + `extraPorts` |
| HTTPRoute / Gateway | `type == web` and enabled | Unchanged from today |
| PVC | `persistence.enabled` | `<name>-data`; strategy auto-`Recreate` (KCL default) |
| HPA / PDB | enabled, `type != cron` | CEL rejects on cron |
| ConfigMaps / ExternalSecrets / CNP / kvStore / SQLInstance / S3+EPI / VMRule / OTLP | unchanged | Orthogonal to `type` |

### Key Entities

- **`spec.type` discriminator**: single fork point in KCL — selects workload kind and which peripherals render.
- **Container schema (reduced)**: shared KCL schema used by `sidecars[]` and `initContainers[]` (initContainers: no `ports`); merges constitution security defaults with per-container overrides.
- **PVC**: `<xr-name>-data`, mounted only on the main container.
- **CronJob pod template**: built from the same pod-builder as the Deployment (env, volumes, security context, sidecars, init containers) to avoid drift between shapes.

### Dependencies

- [ ] No new providers/CRDs: Deployment, CronJob, PVC are core; function-kcl already renders arbitrary K8s kinds.
- [ ] Crossplane RBAC: verify the aggregate ClusterRole covers `batch/cronjobs` and `persistentvolumeclaims` (see `.claude/rules/crossplane-validation.md` trap #3, `additional-rbac.yaml`).
- [ ] Readiness: CronJob added to static-ready list in `.claude/rules/crossplane-validation.md`.

### Alternatives considered

`processes[]` (Procfile-style, all processes in one claim) rejected for schema depth — see CL-3. Separate `Worker`/`CronApp` kinds rejected: 3 XRDs to version and infra blocks duplicated. Named sidecar presets rejected as a treadmill — see CL-2. Full details in [clarifications.md](clarifications.md).

---

## Implementation Notes

- **Zero-breaking-change guard**: before touching `main.k`, snapshot `crossplane render` output for `app-basic.yaml` and `app-complete.yaml`; diff after (SC-001).
- **Pod-builder refactor**: extract the pod template construction (containers, volumes, security context) into a KCL schema/function reused by Deployment and CronJob. Respect the no-mutation rule (function-kcl #285) — build dicts inline with conditionals, single-line comprehensions.
- **`deploymentStrategy` default relocation (FR-007)**: remove `default: RollingUpdate` from the XRD so KCL can detect absence; document in the field description that the effective default is RollingUpdate, or Recreate when persistence is enabled.
- **Worker probes**: omit probes entirely when unset for `type: worker`/`cron`; the SRE checklist item "health checks defined" is satisfied by *explicit opt-out semantics* for non-HTTP workloads (a queue consumer's liveness is queue-lag, not an HTTP endpoint) — document this in the guide.
- **CEL messages** must name the offending field (SC-003), e.g. `"schedule is required when type is 'cron'"`.
- **User guide (FR-013)**: `docs/apps-user-guide.md`, written for app developers (assume kubectl basics, zero Crossplane knowledge). Structure: (1) What is an App + mental model diagram, (2) Quick start (web), (3) Workers, (4) Cron jobs, (5) Config & secrets, (6) Sidecars & init containers, (7) Persistence, (8) Probes, (9) Database/cache/S3, (10) Exposing & securing (route, network policies), (11) Full field reference table, (12) Troubleshooting (kubectl describe app, common CEL rejections, events). Every snippet must render (SC-006).
- **README drift fix**: correct `kcl/app/README.md` examples (`route.port`, `networkPolicies.policies`, probe paths `/health` vs `/healthz`) against the real schema; slim it to module-maintainer content and link the user guide for consumers.

### File structure (if composition)

```
infrastructure/base/crossplane/configuration/
├── app-definition.yaml            # XRD: type/cron/sidecars/persistence/probes/extraPorts + CEL
├── kcl/app/
│   ├── main.k                     # pod-builder refactor + CronJob/worker paths
│   ├── main_test.k                # new cases (SC-002/004/005)
│   ├── settings-example.yaml
│   └── README.md                  # drift fix + link to guide
├── examples/
│   ├── app-basic.yaml             # unchanged (SC-001 witness)
│   ├── app-complete.yaml          # + sidecar, initContainer, persistence, startup probe
│   ├── app-worker.yaml            # NEW
│   └── app-cron.yaml              # NEW
docs/apps-user-guide.md            # NEW (FR-013)
```

### Validation path

- `kcl fmt` passes
- `kcl run -Y settings-example.yaml` renders (note: needs `-Y`, see memory gotcha)
- `crossplane render` with all 4 examples succeeds
- Polaris score ≥ 85, kube-linter passes (via `./scripts/validate-kcl-compositions.sh`)
- `kubeconform` on rendered output and on every guide snippet

---

## Tasks

> Each task has a stable ID (`T001`, `T002`, …) — committable unit, referenced by PRs and `/verify-spec`. Before marking `[x]`, cite fresh evidence (see [`.claude/rules/process.md`](../../../.claude/rules/process.md)).

### Phase 1: Prerequisites

- [x] **T001**: Snapshot current `crossplane render` output for `app-basic.yaml` and `app-complete.yaml` (SC-001 baseline). — Evidence: `/tmp/spec007-baseline/` (4 + 15 resources), 2026-07-14.
- [x] **T002**: Verify Crossplane aggregate ClusterRole covers `batch/cronjobs` + `persistentvolumeclaims`; add to `additional-rbac.yaml` if missing. — Both were missing; added to `app-composition:aggregate-to-crossplane`.
- [x] **T003**: Resolve the two open `[NEEDS CLARIFICATION]` items in spec.md via `/clarify` (sidecar image form; cron × infra blocks). — CL-6, CL-7.

### Phase 2: Implementation

- [x] **T004**: XRD — add `type`, `schedule`, `cron`, `command`/`args`, `imagePullSecrets`, `terminationGracePeriodSeconds` + CEL rules (FR-001, FR-003, FR-004, FR-010, FR-011). — 8 new spec-level CEL rules + 2 per array.
- [x] **T005**: XRD — add `sidecars[]`/`initContainers[]` reduced container schema (FR-005). — maxItems 16 for CEL cost budget.
- [x] **T006**: XRD — add `persistence`, reworked `healthProbes` (type/startup), `service.extraPorts`; drop `deploymentStrategy` schema default (FR-006, FR-007, FR-008, FR-009).
- [x] **T007**: KCL — extract shared pod-builder (containers incl. sidecars/init, volumes incl. persistence, security defaults merge). — `_mainContainer`/`_sidecarContainers`/`_initContainerList`/`_podSpec` shared by Deployment and CronJob.
- [x] **T008**: KCL — `type` fork: worker (no Service/route/probe defaults) and cron (CronJob + defaults); readiness wiring (FR-002, FR-003, FR-012). — CronJob statically ready; VMServiceScrape gated to web (no Service otherwise).
- [x] **T009**: KCL — persistence PVC + strategy auto-`Recreate`; probe type variants; extraPorts (FR-006, FR-007, FR-008, FR-009).

### Phase 3: Validation & Documentation

- [x] **T010**: `main_test.k` — worker/cron rendering, sidecar+init security context, persistence strategy flip, probe variants, container-name rules (SC-002/004/005). — `kcl test . -Y settings-example.yaml` → PASS 27/27 (2026-07-14).
- [x] **T011**: Examples — `app-worker.yaml`, `app-cron.yaml`; extend `app-complete.yaml`; verify SC-001 diff on pre-existing examples. — SC-001 empty diff verified with unmodified examples BEFORE extending app-complete (local-source render harness; see Deviations).
- [x] **T012**: `./scripts/validate-kcl-compositions.sh` exit 0; Polaris ≥ 85; kube-linter clean (SC-002/004). — exit 0; kubeconform 0 invalid.
- [ ] **T013**: Negative tests — apply each invalid claim from SC-003 against a cluster (or `kubectl --dry-run=server`) and record the CEL messages. — **Deferred to post-merge `/verify-spec`**: the live cluster still runs the pre-SPEC-007 XRD, so server-side dry-run would validate against the old schema.
- [ ] **T014**: Write `docs/apps-user-guide.md` (FR-013); validate every snippet renders (SC-006).
- [ ] **T015**: Fix `kcl/app/README.md` drift; link guide; update CLAUDE.md key-file pointers if needed.

### Deviations from plan

<!-- Append as implementation surprises show up. Format:
- <date> T00N was [dropped|replaced|split]: <why>
Keep short — detailed rationale goes in clarifications.md if it is a decision. -->

- 2026-07-14 — SC-001/T011-T012 verification caveat: `app-composition.yaml` pins the OCI-published module (`crossplane-app:0.1.10-pr1434`), so plain `crossplane render` exercises the *published* code, not local `main.k`. SC-001 and the worker/cron render evidence were produced with a local-source harness (inline `source: |` substitution). Follow-up on PR open: `kcl.mod` bumped to `0.2.0`; CI publishes `0.2.0-pr<N>`; update the composition pin to that tag so render CI exercises the new code, then strip to `0.2.0` after merge (same flow as PR #1574/#1576).
- 2026-07-14 — T013 deferred to post-merge `/verify-spec` (live cluster still has the old XRD; `--dry-run=server` would test the wrong schema).

---

## Review Checklist

Complete this before implementation begins. Each persona enforces non-negotiable rules — do not skip.

### Project Manager

- [x] Problem statement in spec.md is clear and specific
- [x] User stories capture real user needs
- [x] Acceptance scenarios are testable
- [x] Scope is well-defined (goals AND non-goals)
- [x] Success criteria are measurable

### Platform Engineer

- [x] Design follows existing patterns (`App`, `SQLInstance`, `EPI` as references)
- [x] API is consistent with other compositions
- [x] Resource naming follows `xplane-*` convention (child resources keep the existing App naming scheme; PVC `<xr-name>-data`)
- [x] KCL avoids mutation pattern (function-kcl #285) — pod-builder built with inline conditionals, see Implementation Notes
- [ ] Examples provided (basic + complete) — deliverable of T011, pending

### Security & Compliance

- [x] Zero-trust networking (CiliumNetworkPolicy surface unchanged — existing opt-in CNP applies to all workload types)
- [x] Least-privilege RBAC (only additions: `batch/cronjobs` + `persistentvolumeclaims` to the Crossplane aggregate role, T002)
- [x] Secrets via External Secrets (no hardcoded credentials — surface unchanged)
- [x] Security context enforced (FR-005: sidecars/initContainers inherit constitution defaults unless overridden)
- [x] IAM policies scoped to `xplane-*` resources (no IAM change in this spec)

### SRE

- [x] Health checks defined (FR-008: liveness/readiness/startup; worker/cron opt-out semantics documented in Implementation Notes + user guide)
- [x] Observability configured (OTLP/VMRule blocks orthogonal to `type`, unchanged)
- [x] Resource requests + limits appropriate (mandatory today; sidecar schema includes `resources`)
- [x] Failure modes documented (CEL rejection matrix SC-003; RWO multi-attach handled by FR-007; guide troubleshooting section T014)
- [x] Recovery / rollback path clear (zero breaking change guaranteed by SC-001 render snapshot; revert = git revert, no state migration)

---

## References

- Spec: [spec.md](spec.md)
- Clarifications log: [clarifications.md](clarifications.md)
- Constitution: [docs/specs/constitution.md](../constitution.md)
- Phased specs: [docs/specs/PHASED.md](../PHASED.md)
- Similar composition: `infrastructure/base/crossplane/configuration/kcl/app/`
- Related ADR: [ADR-0001](../../decisions/0001-use-kcl-for-crossplane-compositions.md)
