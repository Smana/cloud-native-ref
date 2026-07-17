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

## Authentication

`AUTH_MODE` selects the login backend (see `internal/config/config.go`):

| `AUTH_MODE` | Login | Opens PRs as | Notes |
|-------------|-------|--------------|-------|
| `github` (default) | GitHub OAuth | the GitHub user | single sign-in step |
| `dev` | none | — | local development only |
| `zitadel` | Zitadel OIDC (SSO) | the linked GitHub user | **two-flow** (below) |

### zitadel mode — two-flow model (CL-11)

In `zitadel` mode the login and the GitHub identity used for PRs are **decoupled**:

1. **Sign in** — `/api/auth/login` → `/api/auth/callback` runs the Zitadel OIDC
   flow. `/api/me` then returns the user with `githubLinked: false`.
2. **Connect GitHub** — because PRs are authored under the user's own GitHub
   identity, the user must also link a GitHub token: `/api/auth/github/link`
   (redirect) → `/api/auth/github/callback`. After that `/api/me` reports
   `githubLinked: true`.

If `POST /api/pr` is called before GitHub is linked, the backend returns
**HTTP 428** (Precondition Required) with a `Location: /api/auth/github/link`
header; the SPA surfaces this as a "Connect GitHub" prompt. In `github`/`dev`
modes `/api/me` always reports `githubLinked: true`, so this step never appears.

### Environment variables

Non-secret (set via `env` in the App claim):

| Var | Purpose |
|-----|---------|
| `AUTH_MODE` | `github` \| `dev` \| `zitadel` (default `github`) |
| `ZITADEL_ISSUER` | Zitadel issuer URL, e.g. `https://id.priv.cloud.ogenki.io` |
| `ZITADEL_REDIRECT_URL` | OIDC callback (default `.../api/auth/callback`) |
| `ZITADEL_REQUIRED_ROLE` | project role a user must hold, e.g. `app-wizard:user` (empty ⇒ any authenticated user) |
| `OAUTH_REDIRECT_URL` | GitHub OAuth / GitHub-link callback |
| `LLM_MODEL` | assist model id (default `claude-opus-4-8`; deployed as `glm-5.2` — see below) |
| `LLM_BASE_URL` | optional Anthropic-API-compatible endpoint (deployed: `https://api.z.ai/api/anthropic`; can also target the in-cluster AI Gateway) |

Secret (via `envFrom` from two ESO-materialized Secrets):

- `app-wizard-oauth` (source blob `apps/app-wizard/oauth`): `GITHUB_CLIENT_ID`,
  `GITHUB_CLIENT_SECRET`, `SESSION_KEY`, `ZITADEL_CLIENT_ID`, `ZITADEL_CLIENT_SECRET`.
- `app-wizard-llm` (source blob `apps/app-wizard/llm`): `LLM_API_KEY` — a copy of
  runlore's Z.ai GLM key in a wizard-owned blob (own rotation lifecycle).

The deployed assists run on **GLM 5.2 via Z.ai's Anthropic-compatible endpoint**
(the assist backend speaks the Anthropic Messages API with forced tool use, which
that endpoint implements). `LLM_MODEL=glm-5.2` is set explicitly because the
endpoint maps the Anthropic alias `claude-opus-4-8` to the older `glm-4.7`.

Switching a deployment to `zitadel` requires registering the Zitadel app
(Web / OIDC / PKCE) and its role, plus populating the `ZITADEL_*` secret keys
(human steps T401 / T003). See `apps/platform/app-wizard/app.yaml` for the wired
claim.

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
