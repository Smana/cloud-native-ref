# Spec-Driven Development (SDD)

Lightweight specs for non-trivial changes to the cloud-native-ref platform. Inspired by [GitHub Spec Kit](https://github.com/github/spec-kit).

## When to write a spec

| Change type | Examples |
|-------------|----------|
| **composition** | New KCL module, new XRD, Crossplane patterns |
| **infrastructure** | New OpenTofu stack, VPC changes, EKS upgrades |
| **security** | Network policies, RBAC, PKI, secrets management |
| **platform** | Multi-component features, observability, GitOps |

**Skip** for: version bumps, docs-only changes, single-file bug fixes, HelmRelease value tweaks.

## Core workflow — 4 commands

```
/spec  →  /clarify  →  /validate  →  /create-pr
```

That's the whole user-facing contract. Auto-archive on merge takes care of the rest. Power tools (`/spec-research`, `/spec-status`, `/verify-spec`) are optional and surface when you need them — see [Power tools](#power-tools).

### 1. `/spec [type] "description"`

Creates a GitHub issue (`spec:draft` label) and a directory `docs/specs/NNN-slug/` containing **3 files**:

```
docs/specs/NNN-slug/
├── spec.md            ← WHAT — requirements, user stories, FR-XXX, SC-XXX. Frozen after approval.
├── plan.md            ← HOW — design, tasks (T001+), 4-persona review checklist. May evolve.
└── clarifications.md  ← Append-only decision log (CL-1, CL-2, …). Never overwritten.
```

**Why three files**: each artifact has a different edit cadence. The contract (`spec.md`) shouldn't move when implementation evolves; design and tasks (`plan.md`) do; deliberations (`clarifications.md`) are append-only forever.

```bash
/spec composition "Add Valkey caching"
/spec infrastructure "Add GPU node pool"
/spec security "Restrict egress from observability namespace"
```

### 2. Fill the spec, mark unknowns

In `spec.md`: summary, problem, user stories with Gherkin scenarios, FR-XXX requirements, SC-XXX (falsifiable!) success criteria. Mark unknowns with `[NEEDS CLARIFICATION: ...]`.

In `plan.md`: design (XRD, generated resources, dependencies), `T001+` tasks, 4-persona review checklist (PM / Platform / Security / SRE).

### 3. `/clarify`

For each `[NEEDS CLARIFICATION: ...]` marker, presents 2–3 structured options. On answer:
- Appends a `## CL-N` entry to `clarifications.md` (options + decision + rationale + references — durable forever)
- Replaces the marker in `spec.md` with `CL-N — <one-line summary>` (a reference, not the answer)

Six months later, "why did we pick option A?" always has an answer.

### 4. `/validate`

Single quality gate. Runs `scripts/validate-spec.sh` plus semantic cross-artifact rules. Catches:

- Missing sections, placeholders, FR/SC counts
- FR-XXX with no implementing task (coverage gap)
- Vague adjectives in success criteria (`fast`, `scalable`, ...)
- Stale `CL-N` references
- Constitution violations (resource naming, KCL mutation, missing security context, hardcoded credentials, IRSA mention)

**Verdict**: BLOCK / PASS WITH WARNINGS / PASS. Fix BLOCK-level findings before implementing.

### 5. Implement

Work through the `T001+` tasks in `plan.md`. The `crossplane-validator` skill auto-runs for KCL changes. The `.claude/rules/spec-constitution.md` rules auto-load when editing infra / security / spec files.

### 6. `/create-pr`

Auto-detects the spec directory in the diff, references the issue (`Implements #XXX`), generates a PR body with mermaid diagram and file table.

### Auto-archive on merge

`.github/workflows/spec-archive.yaml`:
1. Generates `SUMMARY.md` (commits, file diffstat, SC snapshot, deviations).
2. Moves the directory to `docs/specs/done/YYYY-Qn/NNN-slug/`.
3. Closes the linked issue with `spec:done` label.

## Spec template structure

| File | Sections | Cadence |
|------|----------|---------|
| `spec.md` | Metadata, Summary, Problem, User Stories (Gherkin), Requirements (FR-XXX), Success Criteria (SC-XXX, falsifiable), Open questions, References | **Frozen after approval** |
| `plan.md` | Design, Implementation Notes, **Tasks (T001+)**, **Review Checklist (4 personas)**, References | Evolves with implementation |
| `clarifications.md` | Append-only `## CL-N` entries (options + decision + rationale + references) | Append-only — never edited |
| `SUMMARY.md` (post-merge) | Auto-generated: commits, files, SC snapshot, deviations | Written once on merge |

Templates: [`docs/specs/templates/`](templates/).

### Falsifiable success criteria

Avoid vague: ❌ "fast", "scalable", "secure"
Prefer measurable: ✅ "p95 latency < 100 ms", "sustains 10k req/s", "Polaris ≥ 85", "Crossplane XR Ready=True within 60s"

### 4-persona review (in `plan.md`)

| Persona | Focus |
|---------|-------|
| **PM** | Problem clarity, user-story testability, scope, measurable SCs |
| **Platform Engineer** | Existing patterns (App, SQLInstance, EPI), `xplane-*` naming, KCL no-mutation, examples |
| **Security & Compliance** | CiliumNetworkPolicy, least-privilege RBAC, External Secrets, security context, IAM scoping |
| **SRE** | Health probes, observability (VictoriaMetrics/Logs), resource limits, failure modes |

### Clarifications — append-only

Marker → reference, full decision in `clarifications.md`:

```markdown
# In spec.md, before /clarify:
- [ ] [NEEDS CLARIFICATION: Should cache support cross-namespace access?]

# After /clarify:
- [x] CL-3 — Cross-namespace cache access?

# clarifications.md (the durable record):
## CL-3 — 2026-04-18 — Should cache support cross-namespace access?
**Options considered**: A) namespace-scoped only  B) explicit allow-list
**Decision**: A — namespace-scoped only
**Rationale**: matches zero-trust default; cross-ns can be added later without breaking existing consumers
**References**: constitution.md → "zero-trust networking"
```

## GitHub issue labels

| Label | Transition |
|-------|------------|
| `spec:draft` | Auto-added by `/spec` |
| `spec:implementing` | Manual: `gh issue edit XXX --remove-label spec:draft --add-label spec:implementing` |
| `spec:done` | Auto-added by archive workflow on merge |

```bash
gh issue list --label "spec:draft"        # Specs needing work
gh issue list --label "spec:implementing" # Specs in progress
gh issue list --label "spec:done"         # Completed specs
```

## Power tools (optional)

You don't need these for the common case. They're here when:

| Skill | When you reach for it |
|-------|----------------------|
| `/spec-research <slug> "<question>"` | Before filling a spec, you want a fresh ecosystem scan (Context7 + repo) without burning main context |
| `/spec-status` | "Where are we with all the in-flight specs?" — pipeline overview with stale-detection |
| `/verify-spec <spec-dir>` | Post-merge: prove every SC-XXX is met against the live cluster (uses Flux + VictoriaMetrics + VictoriaLogs MCPs); writes `VERIFICATION.md` |

For features that span multiple PRs, see [`PHASED.md`](PHASED.md). Use sparingly.

## Constitution

[`docs/specs/constitution.md`](constitution.md) defines non-negotiable platform rules (`xplane-*` naming, KCL no-mutation, zero-trust, EKS Pod Identity, etc.). The path-scoped [`.claude/rules/spec-constitution.md`](../../.claude/rules/spec-constitution.md) auto-loads these whenever Claude is editing infrastructure / security / spec files.

## Related

- [Platform Constitution](constitution.md)
- [Phased specs](PHASED.md)
- [Architecture Decision Records](../decisions/)
- [Skills reference](../../.claude/skills/README.md)
