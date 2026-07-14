# App Wizard

Schema-driven self-service UI that turns a form (or a plain-language
description) into a reviewable GitOps pull request under `apps/<stack>/<app>/`.
See the spec: [`docs/specs/008-app-wizard-self-service-ui/`](../../docs/specs/008-app-wizard-self-service-ui/).

> **Two ways to declare an app.** The wizard is the *assisted* path; you can
> also just **write the App YAML yourself and open a PR** — same schema, same
> gates, same review flow. Both are documented for developers in
> [`docs/app-wizard.md`](../../docs/app-wizard.md). There is deliberately no
> in-UI YAML editor: a text editor + git already do that well, and the
> `generate` subcommand (below) covers local scaffolding/validation.

## What it is

A single Go binary that serves a React SPA and a small JSON API. The form is
**generated from the App XRD** (`infrastructure/base/crossplane/configuration/app-definition.yaml`)
so it never drifts from the schema. PRs are opened **as the signed-in developer**
via GitHub OAuth; the wizard holds no cluster credentials.

## Architecture

```
React SPA ──► Go backend (this binary)
               │  /api/schema     XRD → JSON Schema + CEL + ui-hints + stacks
               │  /api/validate   OpenAPI + CEL + secret scan
               │  /api/render-preview   crossplane render (function sidecars)
               │  /api/pr         branch + files + PR as the user
               ▼
      GitHub apps/<stack>/<app>/ ──► Flux ──► cluster
```

The wizard is itself deployed as an `App` claim (dogfooding) — see
`apps/<stack>/app-wizard/`.

## Layout

| Path | Purpose |
|------|---------|
| `cmd/app-wizard/` | main; HTTP wiring |
| `internal/api/` | wire contract (source of truth; mirrored in `ui/src/api/types.ts`) |
| `internal/schema/` | XRD → SchemaPayload pipeline |
| `internal/validate/` | OpenAPI + CEL + secret scanning |
| `internal/render/` | `crossplane render` via function sidecars |
| `internal/gitprovider/` | provider-agnostic Git ops (GitHub impl) |
| `internal/pr/` | claim-file generation + PR flow |
| `internal/web/` | embeds the built SPA |
| `ui/` | React + Vite SPA |
| `ui-hints.yaml` | presentation overlay (tiers/groups/labels) |

## Develop

```bash
# backend (serves stub /api/schema on :8080)
go run ./cmd/app-wizard

# frontend (proxies /api to :8080)
cd ui && npm install && npm run dev

# tests
go test ./...
cd ui && npm test
```

## Build

Built by `.github/workflows/build-container-images.yml` on changes under
`container-images/app-wizard/` → `ghcr.io/smana/app-wizard`. Multi-stage
Docker build compiles the SPA, embeds it, and produces a distroless non-root
image.
