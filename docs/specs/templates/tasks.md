# Tasks: [Title]

**Spec**: [SPEC-XXX](spec.md)
**Plan**: [plan.md](plan.md)
**Last updated**: YYYY-MM-DD

> The **task list** tracks *WHEN / WHO* executes what. Task state moves during implementation; this file is expected to change commit-by-commit. Archived spec directories preserve the final state so readers can audit what shipped vs. what was planned.

Each task has a stable ID (`T001`, `T002`, ...) so PRs, validation, and `/verify-spec` can reference them.

---

## Phase 1: Prerequisites

- [ ] **T001**: <task description> — <files / components touched>
- [ ] **T002**: <task description>

## Phase 2: Implementation

- [ ] **T003**: <task description>
- [ ] **T004**: <task description>
- [ ] **T005**: <task description>

## Phase 3: Validation & Documentation

- [ ] **T006**: Basic example renders with `crossplane render`
- [ ] **T007**: Complete example renders
- [ ] **T008**: Polaris score ≥ 85
- [ ] **T009**: `main_test.k` covers resource counts / naming / security context
- [ ] **T010**: README.md in composition directory
- [ ] **T011**: `settings-example.yaml` + `examples/` populated

## Phase 4: Integration (if applicable)

- [ ] **T012**: Flux Kustomization wired in `<cluster>/crossplane/`
- [ ] **T013**: ServiceMonitor / PrometheusRule for observability
- [ ] **T014**: Runtime example deployed in dev cluster

---

## Deviations from plan

<!-- Append as implementation surprises show up. Format:
- <YYYY-MM-DD> T00N was [dropped|replaced|split]: <why>
Keep short — detailed rationale goes in clarifications.md if it is a decision. -->

---

## Completion note

When all tasks check off, mark the spec `status: done` in `spec.md`, ensure `VERIFICATION.md` exists (from `/verify-spec`), and let the archive workflow move the directory to `docs/specs/done/YYYY-Qn/`.
