# Phase 1: Create flow — schema pipeline, form, PR

**Parent**: [SPEC-008 plan](../../plan.md) · **Depends on**: — · **Acceptance**: SC-001..004, SC-006, SC-008

## Phase design

Everything needed for US-1/2/3/6 create-path: Go backend (schema pipeline, validation gates, secret scan, gitprovider/GitHub, render preview), SPA form renderer (tiers from ui-hints, live CEL messages, YAML pane), GitHub OAuth, PR creation with parent-kustomization registration, and the wizard deployed as its own App claim. No edit, no LLM.

## Tasks

- [ ] **T101**: Repo scaffold `container-images/app-wizard/` (Go module, SPA toolchain, Dockerfile, CI build wiring).
- [ ] **T102**: Schema pipeline: parse App XRD from Git → JSON Schema + CEL list; merge `ui-hints.yaml`; `/schema` endpoint with repo-HEAD caching; synthetic future-field fixture (SC-002).
- [ ] **T103**: Form renderer driven by `/schema`: basic tier (≤8 inputs), expandable advanced groups, live YAML pane, CEL messages inline (SC-003).
- [ ] **T104**: GitHub OAuth login; gitprovider interface + GitHub impl using the user token (FR-004/014).
- [ ] **T105**: Validation gates endpoint: OpenAPI + CEL + `crossplane render` + kubeconform; secret scanning (FR-007/010, SC-006).
- [ ] **T106**: PR flow: 3-file generation incl. idempotent parent-kustomization edit; render-preview PR comment (FR-005/008, SC-004).
- [ ] **T107**: `apps/stacks.yaml` consumption (dropdown, namespace derivation) (FR-006).
- [ ] **T108**: Deploy the wizard as an App claim (Tailscale route, CNP, ExternalSecret for OAuth creds); verify SC-008.
- [ ] **T109**: E2E test against a sandbox repo: basic form → mergeable PR (SC-001).
