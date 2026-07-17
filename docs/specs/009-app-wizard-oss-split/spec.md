# Spec: Extract app-wizard into a standalone agnostic open-source repository

**ID**: SPEC-009
**Issue**: [#1631](https://github.com/Smana/cloud-native-ref/issues/1631)
**Status**: approved
**Type**: platform
**Created**: 2026-07-17
**Last updated**: 2026-07-17

> The **spec** is the contract: *WHAT* we are delivering and *why*. Freeze it once approved. How we build it lives in [`plan.md`](plan.md) (which also tracks tasks and the review checklist); decisions made during filling live append-only in [`clarifications.md`](clarifications.md).

---

## Summary

Extract the App Wizard (today vendored at `container-images/app-wizard/` and hardwired to this repo) into a standalone, **Apache-2.0 open-source** project, `Smana/app-wizard`, that any team running Crossplane + GitOps can adopt. The tool stays the same — a schema-driven form that turns a Crossplane XRD into a reviewable GitOps PR — but every cloud-native-ref-specific assumption (repo coordinates, the App claim GVK, file layout, ogenki branding) becomes configuration. `cloud-native-ref` becomes the **reference deployment**, consuming the published upstream image and keeping only platform-owned inputs (XRD, stacks, composition, `ui-hints.yaml`, a `wizard.yaml`).

---

## Problem

The wizard is already a strong self-service pattern, but it lives inside this platform repo, which causes three problems:

- **Not adoptable.** The value — "schema-driven Crossplane-claim-to-GitOps-PR, no YAML by hand" — is generic, but the code hardcodes `Smana/cloud-native-ref`, the `cloud.ogenki.io/v1alpha1` `App` GVK, `apps/<stack>/<app>` layout, and ogenki branding. Nobody else can run it without forking and editing Go.
- **Repo churn.** The wizard is an independent product with its own release cadence, its own dependency-update stream (Renovate), and its own CI. Carrying it inside the platform repo pollutes the platform's history and CI surface (already visible: the wizard drives a large share of recent `chore(deps)` commits).
- **Wrong ownership boundary.** The platform *consumes* the wizard the way it consumes any other image; it should not *host* its source. The platform owns its schema (the App XRD) and its presentation (`ui-hints.yaml`), not the form engine.

This mirrors the split already done for other components (`Smana/runlore`, `Smana/opencode-config`): the reusable engine lives in its own repo; this repo holds only the config that points the engine at this platform.

Doing nothing keeps a genuinely reusable tool locked to one platform and keeps unrelated churn in the platform's history.

---

## User Stories

### US-1: Adopt the wizard on a different platform (Priority: P1)

As an **operator of another Crossplane + GitOps platform**, I want to run the wizard against my own repo and my own XRD without editing its source code, so that I can offer self-service app declaration on my platform.

**Acceptance Scenarios**:
1. **Given** a `wizard.yaml` pointing at my repo, my XRD path, and my stacks file, **When** I run the published image with my GitHub OAuth app, **Then** the wizard serves a form generated from *my* XRD and opens PRs against *my* repo — with no code change and no ogenki string anywhere in the UI.
2. **Given** an XRD whose claim is `platform.example.com/v1beta1` `kind: Service`, **When** the form is submitted, **Then** the generated claim carries *that* apiVersion and kind (read from the XRD), not a hardcoded `cloud.ogenki.io` `App`.
3. **Given** I have no Crossplane render sidecars available, **When** I set `render.enabled: false`, **Then** the wizard still validates (OpenAPI + CEL + secret scan) and opens PRs — only the "what it composes into" preview is absent.

### US-2: Run it locally in minutes from the OSS repo (Priority: P1)

As a **developer evaluating the tool**, I want a working example checked into the repo, so that I can see it run without owning a Crossplane platform first.

**Acceptance Scenarios**:
1. **Given** a fresh clone of `Smana/app-wizard`, **When** I run the documented `make dev` (or equivalent) against `examples/`, **Then** the wizard starts in dev auth mode, renders a form from the example XRD, and validates input — end to end, offline.
2. **Given** the repo's README, **When** I read the Quickstart + Configuration reference, **Then** every `wizard.yaml` key and every secret env var is documented with its default.

### US-3: cloud-native-ref keeps working, now as a consumer (Priority: P1)

As the **platform maintainer**, I want cloud-native-ref to consume the upstream image instead of vendoring the source, so that the deployed wizard is unchanged for users while the code lives upstream.

**Acceptance Scenarios**:
1. **Given** the consumer PR is merged, **When** Flux reconciles, **Then** the `app-wizard` App claim runs the published `ghcr.io/smana/app-wizard` image with a `wizard.yaml` carrying ogenki's paths + branding, and the create → PR flow behaves exactly as before the split.
2. **Given** the split is complete, **When** I inspect cloud-native-ref, **Then** `container-images/app-wizard/` and its CI entry are gone, `ui-hints.yaml` lives at a platform-owned path, and the App XRD / `apps/stacks.yaml` / composition are untouched.
3. **Given** the wizard's own dependency updates, **When** Renovate runs, **Then** those PRs land on `Smana/app-wizard`, not on cloud-native-ref.

### US-4: The OSS repo is a credible open-source project (Priority: P2)

As a **potential contributor**, I want the repo to have the hallmarks of a maintained project, so that I can trust and contribute to it.

**Acceptance Scenarios**:
1. **Given** the repo, **When** I open it, **Then** it has an Apache-2.0 LICENSE, a README with screenshots, its own green CI (Go + UI build/test, container build), and preserved commit history showing real provenance.
2. **Given** the Go module, **When** I `go build ./...`, **Then** the module path is `github.com/Smana/app-wizard` and there is no residual import of `github.com/Smana/cloud-native-ref/...`.

---

## Requirements

### Functional

- **FR-001**: The claim's `apiVersion` and `kind` MUST be derived from the configured XRD (its `group`, served version, and `claimNames.kind`), not hardcoded. No `cloud.ogenki.io` or `App` literal may remain in Go or UI source as the claim GVK.
- **FR-002**: All non-secret configuration MUST be expressible in a single `wizard.yaml` config file: repo coordinates (owner/name/base branch), XRD path, stacks path, render engine + composition/functions/environmentconfig paths, PR file-layout template, branding (title, logo, theme), and assist settings. Environment variables MUST override file values (12-factor); secrets (`GITHUB_CLIENT_SECRET`, `LLM_API_KEY`, `SESSION_KEY`) MUST remain environment-only and MUST NOT be accepted from the file.
- **FR-003**: The PR file layout MUST be a configurable template (default `apps/{stack}/{app}`) that determines the app directory, its `kustomization.yaml`, and the parent-kustomization registration path. The default MUST reproduce today's behavior exactly.
- **FR-004**: Branding MUST be configuration-driven: application title, logo (URL or mounted asset), and a theme (CSS custom properties). The shipped default MUST be neutral (no "ogenki"/"Ogenki" string, neutral palette, generic mark). cloud-native-ref supplies ogenki branding via its own `wizard.yaml`.
- **FR-005**: The `crossplane render` preview MUST be gated by config (`render.enabled`). When disabled, schema validation, CEL evaluation, secret scanning, and PR creation MUST all still function; only the rendered-resource preview and its PR comment are omitted.
- **FR-006**: The extracted repository MUST be a self-contained Go module `github.com/Smana/app-wizard` with no build-time or import dependency on cloud-native-ref. `go build ./...` and `go test ./...` MUST pass from a clean clone.
- **FR-007**: The repository MUST ship an `Apache-2.0` LICENSE, a README (purpose, quickstart, full configuration reference, screenshots, security model), and its own CI publishing `ghcr.io/smana/app-wizard` on changes.
- **FR-008**: The repository MUST include a runnable `examples/` set (sample XRD, stacks, `wizard.yaml`) and a documented dev entrypoint that starts the wizard in dev auth mode against those examples with no external dependencies.
- **FR-009**: Commit history for the extracted tree MUST be preserved (paths rewritten to repo root) via a history-preserving extraction.
- **FR-010**: In cloud-native-ref, the consumer change MUST: delete `container-images/app-wizard/` and its CI entry; relocate `ui-hints.yaml` to a platform-owned path; add a `wizard.yaml`; and update the `app-wizard` App claim to mount that config and run the published upstream image. The App XRD, `apps/stacks.yaml`, and the composition MUST NOT change behavior.
- **FR-011**: Renovate configuration for the wizard's own dependencies MUST move to `Smana/app-wizard`; cloud-native-ref MUST stop tracking the wizard's Go/npm dependency streams.

### Non-Functional

- **NFR-001**: No regression in the deployed wizard's behavior for cloud-native-ref users — the create → validate → render-preview → PR flow, GitHub/dev auth modes (Zitadel removed per [CL-6](clarifications.md)), and the CiliumNetworkPolicy egress model are preserved.
- **NFR-002**: Secrets never transit the config file or logs; the existing secret-scanning gate on PR content is retained.
- **NFR-003**: The split introduces no new long-lived credential in either repo; the wizard continues to hold no cluster credentials and opens PRs as the signed-in user.

### Out of scope (non-goals)

- **NG-1**: Supporting non-Crossplane CRDs or a kustomize/kubeconform render engine (the "generic Kubernetes CRD" level). The tool stays Crossplane-claim-oriented; `render.enabled: false` is the escape hatch, not a second engine.
- **NG-2**: Multi-provider Git hosting beyond the existing `gitprovider.Provider` interface (GitHub stays the only shipped implementation; the interface already allows others later).
- **NG-3**: Any change to the App XRD, the App composition, or `apps/stacks.yaml` semantics.
- **NG-4**: New wizard features (the W3 UX batch and W4 render-review assist are separate initiatives that land in the new repo *after* the split).
- **NG-5**: Transferring repo ownership to an org or changing the `ghcr.io/smana/app-wizard` image name.

---

## Success Criteria

- **SC-001**: From a clean clone of `Smana/app-wizard`, `go build ./...` and `go test ./...` pass, and `grep -r "cloud-native-ref" --include=*.go` returns no import path. *(FR-006)*
- **SC-002**: `grep -rniE "ogenki|cloud\.ogenki\.io" <oss-repo>/{internal,ui/src,cmd}` returns zero matches for branding or a hardcoded claim GVK. *(FR-001, FR-004)*
- **SC-003**: Running the published image with the `examples/` `wizard.yaml` serves a form whose live-claim preview shows the *example* XRD's apiVersion/kind, and submitting produces a claim with that GVK. *(FR-001, FR-008)*
- **SC-004**: With `render.enabled: false` and no render sidecars, a valid submission still opens a PR (verified with the fake/local git provider); with it `true` against the example composition, the render preview lists resources. *(FR-005)*
- **SC-005**: After the consumer PR merges, the deployed cloud-native-ref wizard opens a create PR identical in shape (files, paths, PR body, render comment) to one opened before the split — same three files under `apps/<stack>/<app>/`. *(FR-010, NFR-001)*
- **SC-006**: cloud-native-ref no longer contains `container-images/app-wizard/`; `ui-hints.yaml` resolves at its new platform-owned path; `./scripts/validate-manifests.sh` → `Invalid: 0, Skipped: 0`. *(FR-010)*
- **SC-007**: `Smana/app-wizard` CI is green (Go build/test, UI build/test, container build) and the repo carries Apache-2.0 + README with a documented config reference. *(FR-007)*
- **SC-008**: The extracted repo's `git log` shows the pre-split commit history for the wizard tree (e.g. the #1590 render-engine commits), with paths at repo root. *(FR-009)*

---

## Assumptions

- The `ghcr.io/smana/app-wizard` package can be published from the new repo under the same name (ghcr package under the `smana` user namespace, re-pointed to the new source repo).
- `gh` (authenticated as Smana, `repo` + `workflow` scopes) can create the public repository and push workflows.
- The App XRD sufficiently declares its claim GVK (`group`, served version, `claimNames.kind`) for FR-001 derivation — to be confirmed in T-tasks against the actual `app-definition.yaml`.
