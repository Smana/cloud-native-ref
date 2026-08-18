# Phase 2: Day-2 operations — edit and decommission

**Parent**: [SPEC-008 plan](../../plan.md) · **Depends on**: 1-create-flow · **Acceptance**: SC-005

## Phase design

App list (walk `apps/` in Git), edit mode with structure-preserving YAML round-trip (yaml.v3 node API; comments + unknown fields survive), "managed in YAML" read-only rendering for un-renderable fields, and decommission PRs (delete app dir + parent-kustomization entry). Duplicate-name detection from Phase 1 links here.

## Tasks

- [ ] **T201**: App inventory endpoint: walk `apps/<stack>/*/app.yaml`, list with stack/name/image/type.
- [ ] **T202**: Round-trip loader: app.yaml → form state + preserved-node remainder; read-only "managed in YAML" pane (FR-009).
- [ ] **T203**: Edit PR flow: minimal diff generation; SC-005 fidelity test against `apps/base/openwebui/app.yaml`.
- [ ] **T204**: Decommission flow: removal PR (app dir + parent registration) with confirmation UX (US-4.3).
- [ ] **T205**: E2E: create → edit tag → decommission lifecycle against the sandbox repo.
