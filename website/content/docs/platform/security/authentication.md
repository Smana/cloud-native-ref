---
title: Authentication
weight: 15
description: One Google Workspace identity, brokered by ZITADEL, reaching Grafana, Harbor, the Flux UI, Headlamp and Kubernetes RBAC — and where each cloud differs.
lastVerified: 2026-08-30
---

Every human-facing service on this platform is behind the same identity. You log
in with a Google Workspace account and never see a per-application password.

This page is the chain that makes that true, in the order a login travels it.

## The intent

Three properties, in priority order:

1. **One identity, one place to revoke it.** Removing someone from Google
   Workspace removes their access to every service — there is no second user
   directory to remember.
2. **Authorisation from group membership, not per-app configuration.** A single
   ZITADEL role decides what you can do in Grafana, in the Flux UI, in Harbor and
   in Kubernetes itself.
3. **No shared credentials.** No service accounts handed round, no application
   passwords in a vault that people copy out of.

Everything below is machinery in service of those three.

## The chain

![One Google Workspace account is the only user directory; ZITADEL brokers it, creating a user on first login through isAutoCreation, holding the platform project with its admin, backend, frontend and data roles, and running the flatRoles Action that flattens those roles into the groups claim Headlamp and the Flux UI read and the roles claim Grafana reads; the token it issues carries every client of the project plus the project id in its audience, which is what the EKS OIDC provider is pinned to; Grafana, the Flux UI, Harbor and Headlamp each consume that token, and the two clouds diverge at the Kubernetes API, where EKS trusts ZITADEL directly and turns the groups claim into real Kubernetes groups while GKE reaches the same outcome through Workforce Identity Federation, exchanging that token for a Google federated one whose principalSet group an ordinary ClusterRoleBinding authorises](/images/diagrams/authentication-chain.svg)

### Google Workspace → ZITADEL

ZITADEL holds a Google identity provider at **instance level**, so every
organisation inherits it. It is created by `scripts/zitadel-idp.sh` from
credentials in the secret store, never by hand in a console.

`isAutoCreation` is on: a Workspace user logging in for the first time gets a
ZITADEL user built from their Google profile. **This is the only way a human user
ever comes into existence** — which is why no bootstrap script can seed one, and
why [restoring the database]({{< relref "/docs/guides/restore-a-database.md" >}})
matters more than it first appears.

{{< callout type="warning" >}}
**Creating the provider does not enable it.** The IdP template and the login
policy are separate objects. With the template present and the policy empty,
ZITADEL renders no Google button and resolves a typed email as a *local*
username — producing `User not found` on a correct configuration. `zitadel-idp.sh`
adds it to the login policy for exactly this reason.
{{< /callout >}}

### ZITADEL → a groups claim

ZITADEL has **no groups**. It has *project roles*, emitted as a nested object
keyed by role and then by organisation. Every consumer here wants a flat array of
strings instead.

`scripts/zitadel-actions/groups-from-roles.js` bridges that: an Action on the
token flow flattens the user's role grants and sets two claims — `groups`
(Headlamp, Flux UI) and `roles` (Grafana). Two names, one list, because the
consumers disagree and both are already deployed.

The roles themselves live on the `platform` project: `admin`, `backend`,
`frontend`, `data`. They are created by `zitadel-oidc-clients.sh`; granting one
to a *user* is deliberately manual, since a user exists only after a first login.

{{< callout type="warning" >}}
**`projectRoleAssertion` must be true on the project**, and ZITADEL defaults it to
false. With it off, no token carries roles **and** `ctx.v1.user.grants` is empty
inside the Action — so it returns early and sets no claim at all, while still
logging `action run succeeded`. One flag produces three unrelated-looking
failures: `no such key: groups` in the Flux UI, `unauthorized` in Headlamp, and
every Grafana user silently landing on `Viewer`.
{{< /callout >}}

## What each consumer does with it

| Service | How it authenticates | What decides authorisation |
|---|---|---|
| **Grafana** | direct OIDC | `role_attribute_path` matching `roles[*]` → Admin / Editor / Viewer |
| **Flux UI** | direct OIDC | impersonates `claims.email` with `claims.groups`, so Kubernetes RBAC decides |
| **Harbor** | direct OIDC | `oidc_auth` mode, auto-onboard on first login |
| **Headlamp** | **differs by cloud** | see below |

Harbor is worth one note: it stores `auth_mode` and the OIDC settings in its own
*database*, not in a config file — but the chart can still set them
declaratively. `core.configureUserSettings` renders into the `CONFIG_OVERWRITE_JSON`
env var Harbor's core container reads at startup, which writes those fields to
the database itself and locks them read-only thereafter. The client id and
secret reach it the same way every other consumer gets theirs — an
`ExternalSecret` synced from the `harbor-oidc` store entry — via the
`HelmRelease`'s `valuesFrom`. See
[ADR-0028]({{< relref "/docs/decisions/0028-harbor-oidc-config-overwrite-json.md" >}}).

## Reaching the Kubernetes API

This is where the two clouds genuinely diverge, and it is the most important
thing on this page to understand before changing anything.

### aws-0 — the API server trusts ZITADEL

EKS accepts an OIDC identity provider directly:

```hcl
identity_providers = {
  zitadel = {
    client_id      = "388445486190712688" # the platform PROJECT id, not an app
    issuer_url     = "https://auth.cloud.ogenki.io"
    username_claim = "email"
    groups_claim   = "groups"
  }
}
```

So a token issued by ZITADEL *is* a Kubernetes identity. The `groups` claim
becomes real Kubernetes groups, and `security/base/rbac/admin.yaml` binds the
`admin` group to `cluster-admin`. Headlamp simply forwards the user's token.

{{< callout type="warning" >}}
**`client_id` is a project id, and that is deliberate.** EKS compares it against
the token's `aud`, and ZITADEL issues an audience holding *every* client of the
project plus the project id itself:

```
[grafana, flux-ui, harbor, headlamp, headlamp-proxy, 388445486190712688]
```

Pin the project id and any client in `platform` is accepted, so adding a
consumer needs no change here. Pin one application's client id and that one app
works while every other is rejected — after a completely healthy OIDC round
trip, with no error logged by ZITADEL, by the consumer, or by the API server.
That was live on `aws-0` until 2026-08-29 and cost an evening to find.

Correcting it is not a plan-and-apply: an EKS identity provider config is
immutable, so it must be disassociated and re-associated — roughly 20 minutes
each way, with OIDC auth to the API server down in between. IAM authentication,
which `aws eks get-token` kubeconfigs use, keeps working throughout.
{{< /callout >}}

### gcp-0 — not directly, but the same outcome

GKE's managed control plane accepts no equivalent flag, and Identity Service for
GKE — which used to provide one — is deprecated as of 2026-07-01 and unsupported
in GKE 1.37+. So GKE never sees the ZITADEL token.

It does not need to. **Workforce Identity Federation** turns the ZITADEL
`id_token` into a Google federated token *before* it reaches the API server, and
GKE then resolves the same ZITADEL role into a Kubernetes group. A user is
authorised by an ordinary `ClusterRoleBinding`, exactly as on `aws-0` — the
group is merely spelled differently:

| | Kubernetes sees the group as |
|---|---|
| `aws-0` | `admin` |
| `gcp-0` | `principalSet://iam.googleapis.com/locations/global/workforcePools/ogenki-zitadel/group/admin` |

The mechanism, the failure modes and the four defects that only a live cluster
exposed are in
[Per-user RBAC on GKE]({{< relref "/docs/platform/security/gke-per-user-rbac.md" >}}).

{{< callout type="warning" >}}
This replaced an earlier design in which Headlamp talked to the API server as its
**own ServiceAccount**, bound to `cluster-admin`, with `--allowed-group=admin` on
oauth2-proxy as the entire authorisation model. Every admitted user was
effectively cluster-admin and no action was attributable to a person.
[ADR-0032]({{< relref "/docs/decisions/0032-workforce-identity-federation-for-gke-rbac.md" >}})
supersedes [ADR-0026]({{< relref "/docs/decisions/0026-headlamp-auth-proxy-on-gke.md" >}}),
whose conclusion rested on assuming the dashboard had to perform the token
exchange itself. It does not.
{{< /callout >}}

Note that oauth2-proxy emits `X-Forwarded-Groups` (**plural**) while Headlamp
defaults to the singular `X-Forwarded-Group`. Left at defaults the login
succeeds, the user has no groups, and nothing logs an error.

## Setting it up

The five ordered bootstrap steps — and why the order is load-bearing — are in
[Set up single sign-on]({{< relref "/docs/get-started/sso.md" >}}).

## Related

- [ADR-0024]({{< relref "/docs/decisions/0024-identity-provider-per-cloud.md" >}}) — why each cloud runs its own ZITADEL
- [ADR-0032]({{< relref "/docs/decisions/0032-workforce-identity-federation-for-gke-rbac.md" >}}) — how GKE gets per-user RBAC from ZITADEL
- [ADR-0026]({{< relref "/docs/decisions/0026-headlamp-auth-proxy-on-gke.md" >}}) — superseded; the shared-ServiceAccount design it chose, and why
- [Restore a database]({{< relref "/docs/guides/restore-a-database.md" >}}) — why an empty ZITADEL costs more than it looks
