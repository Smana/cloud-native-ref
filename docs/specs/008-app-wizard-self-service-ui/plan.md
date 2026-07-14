# Plan: App Wizard — schema-driven self-service UI that opens GitOps PRs

**Spec**: [SPEC-008](spec.md)
**Status**: draft
**Last updated**: 2026-07-14

> The **plan** covers *HOW* to deliver the spec. This is a **phased spec**: the root plan holds the overall design and phase map; each phase directory under [`phases/`](phases/) holds a thin phase-local plan with its own tasks.

---

## Design

### Architecture

```
Browser SPA ──► app-wizard backend (single Go service)
                 │  schema pipeline: XRD + ui-hints + stacks.yaml (from Git)
                 │  validation: OpenAPI + CEL (cel-go) + secret scan
                 │  preview: crossplane render → resource list
                 │  LLM assists: AI Gateway / Claude API (optional)
                 │  gitprovider interface → GitHub (user OAuth token)
                 ▼
        GitHub repo apps/<stack>/<app_name>/ ──► Flux ──► cluster
```

- **Backend**: one Go binary. Serves the SPA, exposes a small JSON API (`/schema`, `/stacks`, `/apps`, `/validate`, `/render-preview`, `/pr`, `/assist/*`). Reads the repo via the user's token (or anonymous read for public repo); never holds cluster credentials (FR-004).
- **Frontend**: SPA with a form renderer driven entirely by the `/schema` payload (JSON Schema + hints + CEL). Live YAML pane (FR-012). Framework decision at open-question resolution.
- **Schema pipeline** (FR-001, FR-002, FR-003): parse `app-definition.yaml` from Git → JSON Schema + CEL rule list (CEL surfaced as inline form messages, FR-002); merge `ui-hints.yaml` (tiers/groups/labels/examples); cache with ETag on repo HEAD.
- **PR flow** (FR-005, FR-006, FR-007, FR-008): generate 3 files, run validation gates, create branch `wizard/<stack>-<app>-<shortid>` + PR with the user's token, post the render-preview comment (FR-008).
- **Edit/decommission** (FR-009): structure-preserving YAML via `yaml.v3` node API; unknown fields → read-only pane.
- **LLM assists** (FR-011): structured output constrained by the XRD-derived JSON schema; prompt embeds `.claude/rules/cilium-network-policies.md` trap knowledge for the policy suggester.
- **Deployment** (FR-013): `container-images/app-wizard/` (source + Dockerfile, built by the existing images workflow), claimed via `apps/<stack>/app-wizard/app.yaml` — the wizard is its own first user.

### Resources Created

| Artifact | Where | Notes |
|----------|-------|-------|
| `container-images/app-wizard/` | this repo | Go backend + SPA source, Dockerfile, CI build |
| `apps/stacks.yaml` | this repo | platform-owned stack registry (FR-006) |
| `apps/<stack>/<app>/…` | generated per PR | app.yaml + kustomization + parent registration |
| `ui-hints.yaml` | `container-images/app-wizard/` | presentation overlay (FR-003) |
| App claim for the wizard | `apps/<stack>/app-wizard/` | type web, Tailscale route, CNP, ExternalSecret (OAuth creds) |

### Key Entities

- **Schema payload**: `{jsonSchema, celRules[], hints, stacks[]}` — the single contract between backend and form renderer.
- **gitprovider**: interface `{ReadTree, ReadFile, CreateBranch, CommitFiles, OpenPR, CommentPR}` — GitHub impl in v1 (FR-014).
- **Stack registry entry**: `{name, description, namespace, ownerTeam}` — also feeds CODEOWNERS review routing.

### Dependencies

- [ ] SPEC-007 merged (the schema the wizard renders, incl. workload types).
- [ ] GitHub OAuth app registered (open question #3).
- [ ] Decision on `crossplane render` execution model (open question #2).
- [ ] LLM endpoint reachable from the cluster (AI Gateway opt-in stack, or Claude API key via ExternalSecret) — Phase 3 only.

### Alternatives considered

Backstage scaffolder (portal adoption too heavy for one form), GitHub Issue Forms + Action (zero hosting but flat forms, no live validation), Headlamp plugin (cluster-oriented, PR flow bolted on) — see CL-1. Hand-crafted form rejected for guaranteed drift — see CL-2, and SPEC-007's README-drift finding as evidence.

---

## Phases

| Phase | Scope | Depends on | Issue | Status |
|-------|-------|------------|-------|--------|
| [1-create-flow](phases/1-create-flow/plan.md) | Schema pipeline, form (basic+advanced tiers), validation gates, secret guardrail, GitHub OAuth, create PR + render comment, wizard deployed as App claim | — | TBD | 🚧 implemented (T101–T108; T109 E2E deferred to live OAuth) |
| [2-day2-operations](phases/2-day2-operations/plan.md) | App list, edit with round-trip fidelity, decommission PR | 1-create-flow | TBD | ⏸ pending |
| [3-llm-assists](phases/3-llm-assists/plan.md) | Describe-to-prefill, network-policy suggester, prompt-set eval | 1-create-flow | TBD | ⏸ pending |

Phase acceptance maps to SCs: Phase 1 → SC-001..004, SC-006, SC-008; Phase 2 → SC-005; Phase 3 → SC-007.

---

## Implementation Notes

- Implementation is executed by **Opus subagents** per task cluster (user directive), with fresh-evidence verification in this session before any completion claim.
- The wizard reads the XRD from **Git, not the cluster** (version-skew decision, spec §8): the form must match what the PR will be validated against after merge.
- CEL evaluation: reuse `cel-go` server-side; client-side mirror via cel-js or fall back to debounced `/validate` calls — behavior (inline messages) is the requirement, mechanism is free.
- Secret scanning: reuse detect-secrets-style heuristics (entropy + known patterns); the repo's pre-commit hook is the second net, the wizard is the first.
- The parent-kustomization edit must be idempotent and conflict-aware (two wizard PRs racing to register different apps in the same stack must not conflict beyond normal Git semantics).

### File structure

```
container-images/app-wizard/
├── cmd/app-wizard/main.go
├── internal/{schema,gitprovider,render,validate,assist}/
├── ui/            # SPA source
├── ui-hints.yaml
├── Dockerfile
└── README.md
apps/stacks.yaml
docs/specs/008-app-wizard-self-service-ui/phases/*/plan.md
```

### Validation path

- Go: `go test ./...`, golangci-lint
- UI: form-renderer unit tests against schema fixtures (incl. a synthetic "future field" fixture for SC-002)
- E2E: against a fork/sandbox repo — create, edit, decommission PR flows
- Platform: `kubeconform` on generated manifests; Polaris ≥ 85 on the wizard's own rendered claim (SC-008)

---

## Tasks

> Cross-phase tasks only — phase-local tasks live in each phase's `plan.md`. Before marking `[x]`, cite fresh evidence (see [`.claude/rules/process.md`](../../../.claude/rules/process.md)).

- [ ] **T001**: Resolve the 3 open questions in spec.md (frontend stack; render execution model; OAuth app registration) via `/clarify`.
- [ ] **T002**: Create `apps/stacks.yaml` registry + document the stack-creation process (platform PR).
- [ ] **T003**: Register the GitHub OAuth app; store client secret in AWS Secrets Manager under `apps/app-wizard/oauth`.
- [ ] **T004**: Per-phase GitHub issues (`[Phase N]` convention) once the parent spec issue exists.

### Deviations from plan

<!-- Append as implementation surprises show up. -->

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

- [x] Design follows existing patterns (App claim deployment, container-images build flow, ExternalSecrets)
- [x] API is consistent (wizard renders the XRD as-is; no parallel schema)
- [x] Resource naming follows conventions (wizard is a standard App claim)
- [ ] Examples provided — Phase 1 deliverable (sandbox E2E fixtures)
- [x] Schema-drift risk addressed (FR-001/SC-002 make it structural)

### Security & Compliance

- [x] Zero-trust networking (wizard ships with its own CiliumNetworkPolicy, FR-013)
- [x] Least-privilege: no cluster credentials at all; Git scope = user's own token (FR-004)
- [x] Secrets via External Secrets; wizard structurally refuses secret values (FR-010, SC-006)
- [x] Security context: restricted-PSS via the App composition defaults (FR-013)
- [x] OAuth client secret stored in AWS Secrets Manager (T003)

### SRE

- [x] Health checks: standard App composition probes on the wizard deployment
- [x] Observability: OTLP metrics/traces via the composition's observability block
- [x] Resource requests + limits via composition defaults
- [x] Failure modes documented (LLM down → assists degrade, FR-011; render failure → PR blocked with error, FR-007)
- [x] Recovery path: wizard is stateless; all state is Git — redeploy is the recovery

---

## References

- Spec: [spec.md](spec.md)
- Clarifications: [clarifications.md](clarifications.md)
- Constitution: [docs/specs/constitution.md](../constitution.md)
- Phased specs: [docs/specs/PHASED.md](../PHASED.md)
- Related: [SPEC-007](../007-app-composition-workload-types/spec.md), [docs/apps-user-guide.md](../../apps-user-guide.md)
