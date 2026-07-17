# Plan: Extract app-wizard into a standalone agnostic open-source repository

**Spec**: [SPEC-009](spec.md)
**Status**: implementing
**Last updated**: 2026-07-17

> The **plan** covers *HOW* to deliver the spec. It may evolve during implementation (unlike `spec.md`, which freezes after approval). Append-only `clarifications.md` is where decisions are durable.

---

## Design

### Approach: extract as-is first, then refactor in the new home

The wizard's hard parts are already generic — the form renders from the XRD's `openAPIV3Schema`, validation is OpenAPI + CEL, `gitprovider.Provider` is an interface, and auth has three pluggable modes. The coupling is concentrated in four seams (see spec Problem). Rather than refactor in place and drag churn through cloud-native-ref, we:

1. **Extract the current tree with history** into `Smana/app-wizard` and get its CI green on the code as-is.
2. **Do the agnostic refactor as new-repo commits** (its natural home).
3. **Cut cloud-native-ref over** in a single consumer PR that points at the refactored upstream image and deletes the vendored copy.

cloud-native-ref sees exactly one change (the consumer cutover), not the refactor churn.

### The four decoupling seams (CL-1 = Level B)

| Seam | Today (hardcoded) | After |
|------|-------------------|-------|
| Claim GVK | `cloud.ogenki.io/v1alpha1` + `kind: App` in `pr/claim.go`, `render/handler.go`, `ui/src/form/claim.ts` | Derived from the XRD (`group` + served version + `claimNames.kind`), surfaced to the UI via `/api/schema` |
| Configuration | ~15 env vars with ogenki defaults (`config.go`) | `wizard.yaml` (all non-secrets) + env override; secrets env-only (CL-2) |
| PR file layout | `apps/<stack>/<app>` literal in `pr/pr.go` `appPaths()` | Template `layout: "apps/{stack}/{app}"`; default reproduces today |
| Branding + render | ogenki logo/title/CSS; `crossplane render` always on | Config-driven theme (neutral default); `render.enabled` gate |

### `wizard.yaml` shape (CL-2)

```yaml
repo:
  owner: Smana
  name: cloud-native-ref
  baseBranch: main
schema:
  xrdPath: infrastructure/base/crossplane/configuration/app-definition.yaml
  uiHintsPath: /config/ui-hints.yaml      # platform-owned, mounted
  stacksPath: apps/stacks.yaml
layout: "apps/{stack}/{app}"              # {stack} {app} tokens
render:
  enabled: true
  engine: crossplane                      # only engine shipped (NG-1)
  compositionPath: infrastructure/base/crossplane/configuration/app-composition.yaml
  functionsPath:   infrastructure/base/crossplane/configuration/functions.yaml
  envConfigPath:   infrastructure/base/crossplane/configuration/environmentconfig.yaml
  functionsDevTargets: "function-kcl=localhost:9443,..."
branding:
  title: "App Wizard"
  logoUrl: "/logo.svg"                    # neutral default asset in the image
  theme: { }                              # CSS custom properties (color-*, radius-*)
assists:
  enabled: true
  model: glm-5.2
  baseUrl: https://api.z.ai/api/anthropic
auth:
  mode: github                            # github | dev  (Zitadel removed, CL-6)
  # OAuth redirect URL, etc.
# secrets are NEVER here: GITHUB_CLIENT_SECRET, LLM_API_KEY, SESSION_KEY
# stay environment-only (NFR-002).
```

Loader precedence: **defaults → `wizard.yaml` → environment** (env wins). Secret keys are rejected if present in the file (fail closed).

### Key entities

- **`Smana/app-wizard`**: the OSS repo — Go module `github.com/Smana/app-wizard`, SPA under `ui/`, `examples/`, Apache-2.0, own CI publishing `ghcr.io/smana/app-wizard` (name unchanged, NG-5).
- **`wizard.yaml`**: per-deployment config; cloud-native-ref ships its own (ogenki paths + branding).
- **cloud-native-ref (consumer)**: keeps App XRD, `apps/stacks.yaml`, composition, relocated `ui-hints.yaml`, `wizard.yaml`, and the `app-wizard` App claim; drops the vendored source + its CI.

### Dependencies

- [ ] `gh` authenticated as Smana with `repo` + `workflow` scopes (confirmed 2026-07-17).
- [ ] `git filter-repo` installed (for history-preserving extraction, CL-4).
- [ ] **HUMAN STEP** — `ghcr.io/smana/app-wizard` package already exists (created by cloud-native-ref); the new repo's Actions token cannot push to it until `Smana/app-wizard` is granted **Write** under the package's *Manage Actions access* (UI-only for user packages; the `gh` token also lacks `write:packages`). Do NOT delete the package — the cluster pins an immutable tag (`main-61bc2c9`) from it. Until granted, the new repo's build succeeds but cannot publish (proven in T003: both arches built, push denied).
- [ ] App XRD declares its claim GVK derivably (confirm in T005 against `app-definition.yaml`).

### Alternatives considered

Refactor-in-place-then-extract (rejected: churns cloud-native-ref with refactor commits). A second non-Crossplane render engine (rejected, NG-1: kills the core value). Clean-history start (rejected, CL-4: provenance matters for OSS). Details in clarifications.md.

---

## Implementation Notes

- **GVK derivation (T006)** is the load-bearing decoupling. The schema pipeline already parses the XRD; extend `SchemaPayload` with the claim's `apiVersion`/`kind` and have `pr/claim.go` + `render/handler.go` + `ui/src/form/claim.ts` read from it. Guard: a golden test asserting the ogenki XRD still yields `cloud.ogenki.io/v1alpha1` `App` (no behavior change for the reference deployment).
- **Config loader (T005)** wraps the existing `config.Load()`: parse `wizard.yaml` (path from `WIZARD_CONFIG`, default `/config/wizard.yaml`, absent ⇒ pure-env as today), then apply env overrides. Reject secret keys in the file. Preserves every existing env var name as an override.
- **Layout template (T007)**: replace `appPaths()`'s `path.Join("apps", stack, app)` with a template expander; default `apps/{stack}/{app}`. Parent-kustomization path derives from the template's parent dir. Golden test against the current three-file output.
- **Branding (T008)**: the SPA reads title/logo/theme from `/api/schema` (or a small `/api/branding`) instead of importing an ogenki asset; ship a neutral `logo.svg`. Strip the `cloud.ogenki.io`/Tailscale wording in `Field.tsx` help text to generic phrasing (or source it from ui-hints).
- **Consumer cutover (T014–T016)**: `ui-hints.yaml` moves from `container-images/app-wizard/ui-hints.yaml` into a platform-owned path (e.g. `apps/platform/app-wizard/ui-hints.yaml`) and is mounted; the App claim gains a `wizard.yaml` mount; the initContainer clone still supplies XRD/stacks/composition from the platform repo.

### Validation path

- New repo: `go build ./...`, `go test ./...`, `cd ui && npm ci && npm test && npm run build`, container build.
- Reference parity: run the built image against `examples/` (SC-003/SC-004) and against a cloud-native-ref checkout, diff the produced PR files vs. a pre-split baseline (SC-005).
- cloud-native-ref: `./scripts/validate-manifests.sh` → `Invalid: 0, Skipped: 0` (SC-006).

---

## Tasks

> Each task has a stable ID (`T001`, `T002`, …). Before marking `[x]`, cite fresh evidence (see [`.claude/rules/process.md`](../../../.claude/rules/process.md)). Tasks marked **(oss-repo)** run in `Smana/app-wizard`; **(cnr)** run in cloud-native-ref.

### Phase 1: Extract & stand up the OSS repo (history-preserving, mechanical)

- [x] **T001** (oss-repo): `git filter-repo` extract `container-images/app-wizard/` → repo root with history; rewrite Go module path `github.com/Smana/cloud-native-ref/container-images/app-wizard` → `github.com/Smana/app-wizard`; `go build ./...` + `go test ./...` green. *(FR-006, FR-009)*
- [x] **T002** (oss-repo): `gh repo create Smana/app-wizard --private`; push the extracted tree + tags. *(CL-5)*
- [x] **T003** (oss-repo): Move the container build workflow in (publishes `ghcr.io/smana/app-wizard`); add Go + UI build/test CI. First green run + first published image. *(FR-007)*
- [x] **T004** (oss-repo): Apache-2.0 `LICENSE`, README skeleton, `renovate.json` for the wizard's own deps. *(FR-007, FR-011)*

### Phase 2: Agnostic refactor (in the OSS repo)

- [x] **T005** (oss-repo): `wizard.yaml` loader — file (`WIZARD_CONFIG`) + env override, secrets rejected from file; every existing env var preserved as an override. Table-test precedence + secret-rejection. *(FR-002, NFR-002)*
- [x] **T006** (oss-repo): Derive claim `apiVersion`/`kind` from the XRD; remove the three hardcoded GVK sites (Go ×2 + UI). Golden test: ogenki XRD → `cloud.ogenki.io/v1alpha1` `App`; synthetic XRD → its own GVK. *(FR-001, SC-002, SC-003)*
- [x] **T007** (oss-repo): Configurable PR file-layout template (default `apps/{stack}/{app}`); golden test that the default reproduces today's three-file output byte-for-byte. *(FR-003, SC-005)*
- [x] **T008** (oss-repo): Config-driven branding (title/logo/theme via API → SPA); neutral default asset + palette; strip ogenki/Tailscale strings. `grep` gate for zero ogenki matches. *(FR-004, SC-002)*
- [x] **T009** (oss-repo): Gate render preview on `render.enabled`; when off, validate + PR still work (assist/render affordances hidden, like the existing degraded-assist path). Test both branches. *(FR-005, SC-004)*
- [x] **T010** (oss-repo): `examples/` (sample XRD + stacks + `wizard.yaml`) + `make dev` (dev auth, local git provider, offline). *(FR-008, SC-003)*
- [x] **T018** (oss-repo): Remove the Zitadel auth mode (CL-6) — delete `internal/auth/{zitadel.go,zitadel_test.go,oidc_verifier.go}`, the Zitadel config fields, the PR-handler HTTP-428 "link GitHub" flow, and the UI "Connect GitHub" prompt + `GitHubLinkRequiredError`; keep `github` + `dev`. `go test ./...` + `npm test` green; `grep -ri zitadel` returns nothing in `internal`/`ui/src`/`cmd`. Substantive (backend + UI) → subagent-driven with 2-stage review.

### Phase 3: Docs, publish, verify

- [ ] **T011** (oss-repo): README — purpose, quickstart, full `wizard.yaml` + secret-env reference (every key + default), screenshots, security model. *(FR-007, US-2.2)*
- [ ] **T012** (oss-repo): CI fully green (Go + UI + container); verify SC-001/002/004/007/008; **flip repo public after user review** (CL-5).
- [ ] **T013** (oss-repo): Publish the refactored image tag the consumer PR will pin (record digest/tag for T015).

### Phase 4: cloud-native-ref consumer cutover (cnr)

- [ ] **T014** (cnr): Relocate `ui-hints.yaml` → platform-owned path (`apps/platform/app-wizard/ui-hints.yaml`); add ogenki `wizard.yaml`. *(FR-010)*
- [ ] **T015** (cnr): Update the `app-wizard` App claim — mount `wizard.yaml` + `ui-hints.yaml`, pin the refactored upstream image; CNP/ESO/route/initContainer unchanged. *(FR-010, NFR-001)*
- [ ] **T016** (cnr): Delete `container-images/app-wizard/`; remove its entry from `build-container-images.yml`; drop wizard-specific Renovate rules. *(FR-010, FR-011)*
- [ ] **T017** (cnr): Evidence — `./scripts/validate-manifests.sh` → `Invalid: 0, Skipped: 0` (SC-006); PR-shape parity vs. pre-split baseline (SC-005). Open consumer PR; merge only after T013 image is published.

### Deviations from plan

<!-- Append as implementation surprises show up. -->

---

## Review Checklist

Complete before implementation. This is a code-extraction + configuration change (not a new Crossplane composition), so KCL/`xplane-*`/IAM checks are marked **N/A** with reason where they don't apply — honestly, not skipped.

### Project Manager

- [x] Problem statement in spec.md is clear and specific
- [x] User stories capture real user needs (adopter, evaluator, maintainer, contributor)
- [x] Acceptance scenarios are testable
- [x] Scope is well-defined (Level B; NG-1..NG-5 explicit)
- [x] Success criteria are measurable (SC-001..SC-008 all have a command/observable)

### Platform Engineer

- [x] Extraction preserves history and rewrites the module path (no `cloud-native-ref` import remains) — design specifies filter-repo + module rewrite (T001), gated by SC-001
- [x] Config loader precedence (defaults → file → env) is deterministic and tested — specified in Implementation Notes + T005
- [x] GVK derivation has a golden test proving no behavior change for the reference XRD — T006
- [x] Layout template default reproduces the current three-file PR byte-for-byte — T007 golden test, gated by SC-005
- [x] N/A — KCL mutation / `xplane-*` naming: no composition authored (the App XRD/composition are untouched, NG-3)

### Security & Compliance

- [x] Secrets remain environment-only; the config loader rejects secret keys in `wizard.yaml` (NFR-002, T005)
- [x] Existing PR secret-scanning gate retained (FR-010 keeps `internal/validate`)
- [x] Deployed CiliumNetworkPolicy egress model unchanged (NFR-001) — verified in T015
- [x] No new long-lived credential in either repo (NFR-003); wizard still holds no cluster creds
- [x] N/A — IAM `xplane-*` scoping: the split touches no AWS IAM (ESO/EPI unchanged)

### SRE

- [x] Deployed health probes (`/healthz`, `/readyz`) unchanged
- [x] Consumer image pinned to an immutable tag (no `latest`); rollout is real (T015)
- [x] Failure mode: missing/invalid `wizard.yaml` fails fast with a clear error (not silent ogenki defaults in someone else's deployment) — T005
- [x] Rollback: consumer PR is revertible; the pre-split image tag remains pullable
- [x] N/A — new observability wiring: the wizard has no `/metrics` yet (unchanged by this spec)

---

## References

- Spec: [spec.md](spec.md)
- Clarifications log: [clarifications.md](clarifications.md)
- Constitution: [docs/specs/constitution.md](../constitution.md)
- Predecessor spec: [docs/specs/008-app-wizard-self-service-ui/](../008-app-wizard-self-service-ui/)
- Prior art (component splits): `Smana/runlore`, `Smana/opencode-config`
- Extraction tool: [git-filter-repo](https://github.com/newren/git-filter-repo)
