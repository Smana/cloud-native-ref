# Clarifications Log — KVStore composition: replace Bitnami Valkey with official valkey-helm chart behind a cloud.ogenki.io XRD

**Spec**: [SPEC-012](spec.md)

> **Append-only.** Never rewrite earlier entries. Every entry has a stable ID (`CL-1`, `CL-2`, ...) so `spec.md` and `plan.md` can reference the decision by ID. This is the durable "why did we pick option A?" audit trail.

---

<!-- Template for each entry:

## CL-N — 2026-07-20 — <one-line question>

**Asked by**: <role or user>
**Context**: <1–3 sentences: why this decision matters; what is constrained>

**Options considered**:

| Option | Answer | Pros | Cons |
|--------|--------|------|------|
| A | <answer> | <pro> | <con> |
| B | <answer> | <pro> | <con> |
| C | <answer> | <pro> | <con> |

**Decision**: <Option letter + answer>
**Rationale**: <Why — tie back to constitution, existing patterns, or SC-XXX>
**Decided by**: <who — conversation / PR reviewer / ADR>
**References**: <links to ADR, similar spec, vendor doc>

-->

## CL-1 — 2026-07-20 — In-cluster Valkey or AWS-managed ElastiCache?

**Asked by**: Spec author (brainstorming session)
**Context**: All three Valkey consumers (Harbor, Grafana OnCall, App composition `kvStore`) run on the frozen `bitnamilegacy` supply chain. Replacing the delivery mechanism forces the in-cluster vs managed question.

**Options considered**:

| Option | Answer | Pros | Cons |
|--------|--------|------|------|
| A | In-cluster | Matches CNPG precedent for stateful services; no per-instance AWS cost; works for per-app kvStore | Self-managed upgrades |
| B | ElastiCache (Valkey engine) via Crossplane | Zero ops | ~$13+/mo per instance, slower provisioning, MR + activation-policy + CNP work per consumer |
| C | Hybrid (in-cluster + ElastiCache tier in App API) | Best of both | Two backends to maintain for cache-grade data |

**Decision**: A — in-cluster
**Rationale**: SQLInstance/CloudNativePG sets the repo precedent: stateful data services run in-cluster behind an XRD. Cache-grade data does not justify managed-service cost or provisioning latency.
**Decided by**: User (brainstorming, 2026-07-20)
**References**: `infrastructure/base/crossplane/configuration/kcl/cloudnativepg/`

## CL-2 — 2026-07-20 — Required availability level?

**Asked by**: Spec author (brainstorming session)
**Context**: The Bitnami "replication" architecture in use today runs primary+replica with **no automatic failover**. Whether any consumer needs Sentinel-style failover determines operator vs chart.

**Options considered**:

| Option | Answer | Pros | Cons |
|--------|--------|------|------|
| A | Cache semantics (restart-and-refill acceptable) | Small footprint; no operator machinery | Warm-cache loss on restart |
| B | Automatic failover | Resilience | Requires operator; none of the consumers stores durable data |
| C | Tiered `ha` flag | Flexibility | API surface for a need nobody has |

**Decision**: A — cache semantics; standalone by default, optional read replicas, no auto-failover
**Rationale**: All three consumers use Valkey as cache/broker. YAGNI.
**Decided by**: User (brainstorming, 2026-07-20)

## CL-3 — 2026-07-20 — Delivery mechanism: XRD + official chart, in-place swap, or operator?

**Asked by**: Spec author (brainstorming session)
**Context**: Drivers confirmed: leave `bitnamilegacy`, improve ops model, consolidate three copy-pasted delivery paths. The Valkey project now ships an official Helm chart (valkey-io/valkey-helm) created in response to the Bitnami shutdown; CloudPirates is discussing deprecating its chart in favor of it; hyperspike/valkey-operator remains v0.0.x.

**Options considered**:

| Option | Answer | Pros | Cons |
|--------|--------|------|------|
| A | `KVStore` XRD wrapping official valkey-helm chart | Hits all three drivers; mirrors the `sqlInstance` → SQLInstance nesting precedent; backend swappable later | New composition → spec + migration touching service names/labels |
| B | In-place chart swap (3 edits) | Minimal churn | Solves supply chain only; consolidation unaddressed |
| C | valkey-operator behind the XRD | True operator ops model | Immature (v0.0.x); failover machinery CL-2 says we don't need |

**Decision**: A — new namespaced `KVStore` XRD (`cloud.ogenki.io/v1alpha1`) wrapping the official chart
**Rationale**: Only option meeting all three drivers; the XRD boundary makes a future operator swap (option C) invisible to consumers.
**Decided by**: User (brainstorming, 2026-07-20)
**References**: <https://valkey.io/blog/valkey-helm-chart/>; <https://github.com/valkey-io/valkey-helm>

## CL-4 — 2026-07-20 — Default persistence: PVC or ephemeral?

**Asked by**: Spec author (brainstorming session)
**Context**: All three instances currently mount 4Gi PVCs. CL-2 establishes cache semantics.

**Options considered**:

| Option | Answer | Pros | Cons |
|--------|--------|------|------|
| A | Ephemeral (emptyDir) default; `persistence.size` opts into a PVC | Honest about cache semantics; no orphaned PVCs; faster pod cycling | Cold cache after restart |
| B | PVC default (4Gi), matching today | Warm cache survives restarts | PVC lifecycle management per instance |

**Decision**: A — ephemeral by default, PVC opt-in
**Rationale**: Consistent with CL-2; consumers that want warm restarts set `persistence.size` explicitly.
**Decided by**: User (brainstorming, 2026-07-20)

## CL-5 — 2026-07-20 — What happens to the App API's `kvStore.type` field (valkey|redis)?

**Asked by**: Plan author
**Context**: FR-005 freezes the App API surface, but the new backend is Valkey-only — the Bitnami-era `type: redis` option has no equivalent in the official chart.

**Options considered**:

| Option | Answer | Pros | Cons |
|--------|--------|------|------|
| A | Keep the field in the schema, ignore its value | No breaking change for existing claims; API frozen per FR-005 | Silent no-op for `type: redis` |
| B | Remove the field | Honest API | Breaking schema change contradicts US-2 |
| C | Add a redis backend to KVStore | Full compat | Reintroduces the unmaintained-chart problem the spec exists to remove |

**Decision**: A — schema keeps `type`, composition ignores it; deprecation noted in `docs/apps-user-guide.md` and the module README
**Rationale**: US-2/FR-005 require zero claim changes; no in-repo claim uses `type: redis`; the field can be dropped in a future App XRD version bump.
**Decided by**: Plan author (design review, 2026-07-20)

---

## Related

- Constitution: [docs/specs/constitution.md](../constitution.md)
- ADRs: [docs/decisions/](../../decisions/)
