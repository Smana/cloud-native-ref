# Clarifications Log — InferenceService v0.8.0: spec.engineArgs escape hatch with reserved-flag CEL denylist and structured status.servedModels

**Spec**: [SPEC-003](spec.md)

> **Append-only.** Never rewrite earlier entries. Every entry has a stable ID (`CL-1`, `CL-2`, ...) so `spec.md` and `plan.md` can reference the decision by ID. This is the durable "why did we pick option A?" audit trail.

---

## CL-1 — 2026-07-11 — Enforcement semantics for reserved (composition-managed) flags in engineArgs?

**Asked by**: User (design session, 2026-07-11)
**Context**: The escape hatch forwards arbitrary vLLM flags, but a handful are load-bearing: `--served-model-name` and `--max-num-seqs` feed the KEDA scale-up denominator and the AI-Gateway pin/canary match values (SPEC-002). If a user overrode those, the autoscaler and gateway would diverge from what the composition believes it deployed. The question is *when* to catch a collision.

**Options considered**:

| Option | Answer | Pros | Cons |
|--------|--------|------|------|
| A | Reject at admission (XRD CEL) | Fails fast at `kubectl apply` / Flux dry-run; keeps KEDA denominator + served-model names trustworthy; single enforcement point; no spec-vs-runtime drift | 16 CEL rules to author and maintain |
| B | Composition-wins-silently (drop the colliding user flag at render) | No claim ever fails to apply | Silent — user's intent is discarded with no signal; hides misconfiguration; two sources of truth (spec says X, runtime does Y) |
| C | Reject at render (KCL `assert`) | Enforcement co-located with the flags in `main.k` | Failure surfaces late (Flux Kustomization/Function error, not the apply); worse UX; the claim exists in a broken state until reconcile |

**Decision**: A — reject at admission via XRD CEL.
**Rationale**: Fail fast, no spec/runtime drift; the KEDA denominator and gateway served-model names stay trustworthy; enforcement is a single source of truth in the XRD (KCL stays a plain verbatim append, no re-validation). Matches SPEC-002's precedent of doing structural validation as CEL at admission (canary adapter membership, weight-sum guard).
**Decided by**: User (design session, 2026-07-11)
**References**: SPEC-002 `spec.md` FR-005 (CEL-at-admission precedent); `main.k:136-159` (managed flags); `.claude/rules/crossplane-validation.md`

## CL-2 — 2026-07-11 — status.servedModels shape: structured objects or a plain string list?

**Asked by**: User (design session, 2026-07-11)
**Context**: The claim needs to expose what model names it serves (base + adapters) and any canary split. This is consumed by ML users at the CLI and by dashboards/UIs.

**Options considered**:

| Option | Answer | Pros | Cons |
|--------|--------|------|------|
| A | Structured objects `{name, kind, canaryWeightPercent?}` | Self-describing (base vs adapter, weight inline); dashboards/UIs parse it directly; forward-compatible (new fields are additive) | Slightly larger status schema |
| B | Plain `[]string` of model names | Minimal schema | Loses base/adapter distinction and canary weight; consumers must re-derive from spec; a later shape change would be a breaking status migration |

**Decision**: A — structured objects.
**Rationale**: Self-describing for ML users and UI/dashboards; the base/adapter distinction and canary weight are exactly the information not otherwise available without reading the composition internals or the rendered `AIGatewayRoute`. The `additionalPrinterColumns` entry (FR-006) still gives a compact name list at the CLI, so the structured form costs nothing at the terminal. Matches the repo's arrays-of-objects forward-compat discipline (SPEC-002 CL-6).
**Decided by**: User (design session, 2026-07-11)
**References**: SPEC-002 `clarifications.md` CL-6 (arrays/objects forward-compat); XRD `loraAdapters[]` object-array convention

## CL-3 — 2026-07-11 — Sequencing relative to SPEC-002 / PR #1559?

**Asked by**: User (design session, 2026-07-11)
**Context**: SPEC-002 (PR #1559) introduced `gateway.canaries[]` and the dxr status-patch that `status.servedModels` builds on. This work needs that context but should not block or bloat #1559.

**Options considered**:

| Option | Answer | Pros | Cons |
|--------|--------|------|------|
| A | Follow-up PR after #1559 merges; branch stacked on #1559 for numbering + `canaries[]` context | Keeps #1559 reviewable; this PR builds on the merged `canaries[]` + dxr-status idiom; small focused diff | Must wait for #1559 to merge before this can land |
| B | Fold engineArgs + servedModels into #1559 | One PR | Over-loads an already large routing PR; unrelated concerns; harder review |

**Decision**: A — follow-up PR after #1559 merges; branch stacked for numbering and `canaries[]` context. The related `gateway.canary` → `canaries[]` rename was folded into #1559 itself (SPEC-002 CL-6), so this spec inherits the array shape and only reads it for `status.servedModels`.
**Rationale**: `status.servedModels` and the escape hatch are orthogonal to route rendering; stacking keeps each PR single-purpose while giving this branch the merged `canaries[]` API to compute canary weights against.
**Decided by**: User (design session, 2026-07-11)
**References**: PR #1559; SPEC-002 `clarifications.md` CL-6

## CL-4 — 2026-07-11 — engineArgs token form: single-token `--flag[=value]` or free two-token args?

**Asked by**: User (design session, 2026-07-11)
**Context**: vLLM accepts both `--flag value` (two tokens) and `--flag=value` (one token). The reserved-flag denylist and the render-append are simplest if each list entry is exactly one flag.

**Options considered**:

| Option | Answer | Pros | Cons |
|--------|--------|------|------|
| A | Single-token `--flag[=value]` only, CEL-enforced `--` prefix | Each entry is self-contained and order-insensitive per-entry; denylist is a simple prefix/`split("=")[0]` match; two-token ambiguity is structurally impossible | Users must write `--flag=value` not `--flag value` |
| B | Free `[]string` (allow bare value tokens) | Mirrors how you'd type it on a shell | A bare value token can't be distinguished from a flag; denylist must track positional pairing; `--served-model-name`\n`foo` split across two entries would evade a naive per-entry check |

**Decision**: A — single-token `--flag[=value]` only; CEL enforces every entry `startsWith("--")` (FR-004). `maxItems: 16` bounds the CEL validation cost of the per-flag denylist.
**Rationale**: Makes the list order-insensitive per-entry and the denylist a simple per-entry prefix match (`a.split("=")[0]`), so a reserved flag cannot be smuggled in split across two list elements. `maxItems: 16` keeps the `16 reserved-rules × 16 entries` CEL cost well inside the per-resource budget. Users needing a valued flag write `--flag=value`, which vLLM's argparse accepts identically to the two-token form.
**Decided by**: User (design session, 2026-07-11)
**References**: `.claude/rules/crossplane-validation.md` (CEL); vLLM engine-args argparse (`--flag=value` accepted); `main.k:136-159` (reserved flags derived from actual emitted args)

## CL-5 — 2026-07-11 — Printer-column source for the served-model names?

**Asked by**: User (quality review, 2026-07-11)
**Context**: FR-006 adds a `SERVED MODELS` printer column so `kubectl get inferenceservice` shows the served-model names at a glance. The column was pointed at the wildcard JSONPath `.status.servedModels[*].name`. Kubernetes' server-side `additionalPrinterColumns` table convertor renders only the FIRST match of a wildcard JSONPath, so the column would show just the base model — never the adapters.

**Options considered**:

| Option | Answer | Pros | Cons |
|--------|--------|------|------|
| A | Keep the wildcard JSONPath on `servedModels[*].name` | No schema addition | Broken: server-side rendering shows only the first match (the base model), never the adapters |
| B | Add a scalar `status.servedModelsSummary` (comma-joined names) computed by the composition, point the column at it | Server-side-rendering-safe; shows all names at the CLI; structured `servedModels` stays the machine-readable API | One extra scalar status field to populate |
| C | Drop the printer column | Nothing to render wrong | Loses the at-a-glance served-model view FR-006 asked for |

**Decision**: B — add a composition-computed scalar `status.servedModelsSummary` and point the printer column at it.
**Rationale**: FR-006's intent is at-a-glance served-model names in `kubectl get`; a composition-computed scalar is the only server-side-rendering-safe source (a wildcard JSONPath renders only its first match). The structured `status.servedModels` (CL-2) stays the machine-readable API for dashboards/UIs; `servedModelsSummary` is a pure projection over it for the CLI.
**Decided by**: User (quality review, 2026-07-11)
**References**: CL-2 (structured `servedModels`); FR-006; Kubernetes `additionalPrinterColumns` server-side table convertor (first-match-only wildcard)

---

## Related

- Constitution: [docs/specs/constitution.md](../constitution.md)
- ADRs: [docs/decisions/](../../decisions/)
