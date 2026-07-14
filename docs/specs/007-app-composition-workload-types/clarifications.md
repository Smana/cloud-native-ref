# Clarifications Log — App composition workload types (web/worker/cron), sidecars, and container ergonomics

**Spec**: [SPEC-007](spec.md)

> **Append-only.** Never rewrite earlier entries. Every entry has a stable ID (`CL-1`, `CL-2`, ...) so `spec.md` and `plan.md` can reference the decision by ID. This is the durable "why did we pick option A?" audit trail.

---

## CL-1 — 2026-07-14 — What workload scope should the App abstraction target?

**Asked by**: Spec author (brainstorming session)
**Context**: The App composition only expresses single-container HTTP services. Deciding the scope determines whether workers/cron are in this spec or a separate composition.

**Options considered**:

| Option | Answer | Pros | Cons |
|--------|--------|------|------|
| A | Web + workers + cron in one App | Covers ~90% of company workloads; one kind, one mental model; Heroku/Fly/Knative convergence | `type`-conditional fields in one schema |
| B | HTTP-only, deepen it | Smallest schema | Workers/cron need a future composition; teams bypass platform meanwhile |
| C | Also stateful (StatefulSet) | Broadest coverage | Significant interface complexity; operators already cover stateful |

**Decision**: A — web + workers + cron in one App kind
**Rationale**: Matches what most PaaS abstractions converge on; keeps guardrails (security defaults, GitOps, network policies) on the workloads that currently escape them. Stateful stays a non-goal.
**Decided by**: Smaine (brainstorming session, 2026-07-14)
**References**: spec.md Non-Goals

## CL-2 — 2026-07-14 — How should multiple containers be modeled?

**Asked by**: Spec author (brainstorming session)
**Context**: Today one implicit container is built from top-level fields. Need sidecars (proxies, log shippers) and init containers (migrations, wait-for-dep) without turning the spec into raw PodSpec.

**Options considered**:

| Option | Answer | Pros | Cons |
|--------|--------|------|------|
| A | Primary + `sidecars[]` + `initContainers[]` | Zero breaking change; simple case stays simple; matches the 90% pattern | Main container schema differs slightly from sidecar schema |
| B | Explicit `containers[]` list | Cleaner data model | Breaks every existing claim; minimal example gets verbose |
| C | Named presets only (`oauthProxy.enabled`) | Simplest interface | Every new sidecar type needs a composition release |

**Decision**: A — primary + `sidecars[]`/`initContainers[]` with a reduced container schema
**Rationale**: Preserves the "image.repository is the only required field" promise; sidecars inherit constitution security defaults so zero-trust posture is kept by default.
**Decided by**: Smaine (brainstorming session, 2026-07-14)
**References**: FR-005; constitution "Security defaults — zero-trust"

## CL-3 — 2026-07-14 — How are workers and cron expressed relative to the App kind?

**Asked by**: Spec author (brainstorming session)
**Context**: Given CL-1, the shape selector must be chosen: discriminator field, multi-process claims, or sibling kinds.

**Options considered**:

| Option | Answer | Pros | Cons |
|--------|--------|------|------|
| A | `spec.type: web\|worker\|cron` discriminator, one claim per process | Zero breaking change (default web); flat schema; one kind to document | Multi-process apps write N claims (duplicating shared env) |
| B | `processes[]` inside one App | Procfile-like; shared env/infra config | Nests entire container schema per process; interface gets deep fast |
| C | Separate kinds (Worker, CronApp) | Clean per-shape schemas | 3 XRDs to version/document; infra blocks duplicated or cross-referenced |

**Decision**: A — `spec.type` discriminator, default `web`, one claim per process
**Rationale**: Simplest interface that satisfies the "don't complexify" constraint; CEL gates type-specific fields so invalid combinations fail at apply time; forces `command`/`args` support (FR-004) which was missing anyway.
**Decided by**: Smaine (brainstorming session, 2026-07-14)
**References**: FR-001..FR-004, FR-011

## CL-4 — 2026-07-14 — Which remaining gaps make this round's cut?

**Asked by**: Spec author (brainstorming session)
**Context**: Candidate gaps beyond workload types: persistence block, probe flexibility, HPA memory target, extra service ports, plus trivial adds (imagePullSecrets, terminationGracePeriodSeconds).

**Options considered**:

| Option | Answer | Pros | Cons |
|--------|--------|------|------|
| A | Persistence + probe flexibility + extraPorts (+ trivial adds); HPA memory excluded | Each selected item has evidence of need (RWO docstring workaround, gRPC apps, metrics ports) | Memory-bound apps keep CPU-only HPA |
| B | All candidates including HPA memory | Complete | Memory HPA is a footgun (usage rarely tracks load); KEDA/custom metrics deliberately out of scope |

**Decision**: A — persistence, probe flexibility (type + startup), `service.extraPorts`, `imagePullSecrets`, `terminationGracePeriodSeconds`; HPA memory target excluded <!-- pragma: allowlist secret -->
**Rationale**: YAGNI on memory HPA; everything included maps to a concrete, common developer need already worked around today via `extraVolumes` or raw manifests.
**Decided by**: Smaine (brainstorming session, 2026-07-14)
**References**: FR-006..FR-010; spec.md Non-Goals

## CL-5 — 2026-07-14 — Documentation deliverable scope

**Asked by**: Smaine
**Context**: The module README targets platform maintainers and has drifted from the actual XRD schema (documents fields that don't exist). Developers have no consumer-facing documentation.

**Options considered**:

| Option | Answer | Pros | Cons |
|--------|--------|------|------|
| A | Comprehensive task-oriented user guide (`docs/apps-user-guide.md`) + README drift fix | Any dev can self-serve; guide snippets validated against schema (SC-006) | Larger doc surface to maintain |
| B | README-only improvements | Single doc | README serves two audiences poorly; drift showed this already failed |

**Decision**: A — dedicated user guide as a first-class deliverable, README corrected and re-scoped to maintainers
**Rationale**: Explicit user requirement ("comprehensive, that any dev could understand"); doc-drift becomes a falsifiable success criterion instead of a hope.
**Decided by**: Smaine (brainstorming session, 2026-07-14)
**References**: FR-013, SC-006, US-6

## CL-6 — 2026-07-14 — Sidecar/initContainer image: plain string or object?

**Asked by**: Spec author (spec review)
**Context**: The main container uses `image: {repository, tag, pullPolicy}`. Sidecars could mirror that or use a terser form.

**Options considered**:

| Option | Answer | Pros | Cons |
|--------|--------|------|------|
| A | Plain string `repo:tag` | 1 line per sidecar; sidecars rarely need pullPolicy | Slight schema inconsistency with main container |
| B | Same object as main | Fully consistent | 3 lines per sidecar for no practical gain |

**Decision**: A — plain string `image: "repo:tag"` for `sidecars[]` and `initContainers[]`
**Rationale**: Optimizes the common case; the main container keeps its object form for backward compatibility.
**Decided by**: Smaine (spec review, 2026-07-14)
**References**: FR-005

## CL-7 — 2026-07-14 — May `type: cron` provision infra blocks (sqlInstance/kvStore/s3Bucket)?

**Asked by**: Spec author (spec review)
**Context**: A cron claim owning a database ties the DB lifecycle to a scheduled job — unusual, but forbidding it costs extra CEL rules.

**Options considered**:

| Option | Answer | Pros | Cons |
|--------|--------|------|------|
| A | Allowed — infra blocks orthogonal to `type` | Simpler schema; legit cases (report job owning its S3 bucket) | Odd ownership possible (DB owned by a cron) |
| B | Forbid sqlInstance/kvStore on cron | Prevents odd ownership | Two more CEL rules; blocks legitimate standalone jobs |

**Decision**: A — all infra blocks stay valid for every workload type
**Rationale**: YAGNI on the restriction; the user guide will call out that a cron owning a database is usually a design smell and point to referencing an existing App's database instead.
**Decided by**: Smaine (spec review, 2026-07-14)
**References**: FR-011 (deliberately excludes infra-block gating); T014 (guide note)

---

## Related

- Constitution: [docs/specs/constitution.md](../constitution.md)
- ADRs: [docs/decisions/](../../decisions/)
