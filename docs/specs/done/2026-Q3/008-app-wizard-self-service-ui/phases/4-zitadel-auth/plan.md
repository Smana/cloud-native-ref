# Phase 4: Zitadel authentication + linked GitHub token

**Parent**: [SPEC-008 plan](../../plan.md) · **Depends on**: 1-create-flow · **Decision**: [CL-11](../../clarifications.md)

## Phase design

Put **Zitadel OIDC** in front of the wizard as the authentication + authorization
gate, and demote the existing GitHub OAuth to a **linked `repo` token** used only
to open the PR (CL-11). Two OAuth flows, decoupled:

```
1. Zitadel OIDC (Auth Code + PKCE)   → who you are + allowed? (role/group claim)
       │  session: zitadel identity + roles
       ▼
2. Direct GitHub OAuth (scope: repo) → token to open the PR (linked on first use)
       │  session: + github token
       ▼
   PR opened as the user (CL-3 audit trail preserved)
```

**Why two flows (not one):** Zitadel's retrieve-idp-intent API returns external
*profile* info (`rawInformation`), **not** the IdP access token — so the wizard
cannot get a `repo`-scoped GitHub token through Zitadel. GitHub needs its own
OAuth. (See CL-11 doc research.)

**Authorization** comes from a Zitadel role/group claim (e.g. `app-wizard:user`),
checked server-side — not from GitHub. GitHub is purely the repo credential.

In-repo analogue: OpenWebUI already logs in via Zitadel OIDC
(`apps/base/openwebui/externalsecret-oauth-zitadel.yaml`) — reuse that
client-registration + ExternalSecret pattern.

## Tasks

- [ ] **T401**: Register a Zitadel application (Web, OIDC, Auth Code + PKCE) for the wizard; define the authz role/group (e.g. `app-wizard:user`). ExternalSecret for the Zitadel client id/secret (mirror openwebui).
- [ ] **T402**: `internal/auth`: add a Zitadel OIDC handler as the **primary** login (`github.com/zitadel/oidc` or `x/oauth2` + OIDC discovery); session carries the Zitadel identity + roles; `/api/me` returns it; enforce the authz claim.
- [ ] **T403**: Demote GitHub OAuth to a **"Connect GitHub"** secondary flow: `/api/pr` requires a linked `repo` token; if absent, return a "link GitHub" action; store the token in the session linked to the Zitadel identity.
- [ ] **T404**: Retire `AUTH_MODE=dev` as the default local path (keep it, but document Zitadel as the real gate); update the deployment claim env/ExternalSecret (Zitadel client + GitHub OAuth app).
- [ ] **T405**: Docs: update `docs/app-wizard.md` (sign-in is Zitadel; GitHub is linked once) and the module README; note the authz claim.
