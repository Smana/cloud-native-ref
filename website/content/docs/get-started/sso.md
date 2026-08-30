---
title: Set up single sign-on
weight: 30
description: The ordered commands that give a fresh cluster working Google login, on either cloud, and the one step no script can do for you.
lastVerified: 2026-08-29
---

A freshly deployed cluster has ZITADEL running and **nothing configured in it**.
These are the steps that turn that into a working Google login for Grafana,
Harbor, the Flux UI and Headlamp — the same steps on both clouds, with different
values.

For what the resulting stack actually does — and why ZITADEL sits in the middle
of it — see
[Authentication]({{< relref "/docs/platform/security/authentication.md" >}}).

## The values for your cluster

Everything below is the same on both clouds except these:

| | `aws-0` | `gcp-0` |
|---|---|---|
| `--cluster` | `aws-0` | `gcp-0` |
| `--cloud` | `aws` | `gcp` |
| account flag | `--region eu-west-3` | `--project ogenki-435905` |
| `IDP_URL` | `https://auth.cloud.ogenki.io` | `https://auth.gcp.cloud.ogenki.io` |
| `PRIVATE_DOMAIN` | `priv.aws.ogenki.io` | `priv.gcp.ogenki.io` |
| step 2 | **not needed** — External Secrets uses EKS Pod Identity, granted by OpenTofu | **required** |

Set them once and the rest of the page copies straight into a shell:

On `aws-0`:

```bash
CL="--cluster aws-0 --cloud aws --region eu-west-3"
IDP_URL=https://auth.cloud.ogenki.io
PRIVATE_DOMAIN=priv.aws.ogenki.io
```

On `gcp-0`:

```bash
CL="--cluster gcp-0 --cloud gcp --project ogenki-435905"
IDP_URL=https://auth.gcp.cloud.ogenki.io
PRIVATE_DOMAIN=priv.gcp.ogenki.io
```

## The steps

The order is load-bearing: each one creates what the next reads. Running only the
first leaves you with OIDC clients and no way to log in through Google.

Every step is idempotent — re-running prints `[skip …]` and changes nothing.

```bash
# 1. Register the OIDC clients, the project, its roles, and
#    projectRoleAssertion. That last one is not optional: with it off ZITADEL
#    puts NO roles in any token AND leaves ctx.v1.user.grants empty inside the
#    groups action, so every consumer authenticates and then has no groups.
./scripts/zitadel-oidc-clients.sh sync $CL --apply
```

```bash
# 2. GCP ONLY. Let External Secrets read what step 1 just created. Those secrets
#    did not exist when the OpenTofu stack applied, so nothing granted access to
#    them. On AWS this step does not exist — External Secrets authenticates with
#    EKS Pod Identity, which OpenTofu already granted.
./scripts/secret-store.sh grant --cloud gcp --project ogenki-435905 --apply
```

```bash
# 3. The Google identity provider, the LOGIN POLICY entry that actually enables
#    it, and the action that flattens project roles into a `groups` claim.
#    Creating the provider without the policy entry gives "User not found".
IDP_URL=$IDP_URL ./scripts/zitadel-idp.sh sync $CL --apply
```

**There is no manual step for Harbor.** Step 1 already wrote its client id and
secret to the `harbor-oidc` store entry; an `ExternalSecret` syncs that into the
cluster and Harbor's `HelmRelease` renders it into `CONFIG_OVERWRITE_JSON`
declaratively — the same shape as every other consumer. It converges on its own
within the `ExternalSecret` refresh interval and the next `HelmRelease`
reconcile. See [ADR-0028]({{< relref "/docs/decisions/0028-harbor-oidc-config-overwrite-json.md" >}}).

**Then log in once through Google**, at any consumer. That first login is what
CREATES your ZITADEL user — the IdP auto-registers it — so there is nobody to
authorise before it. Afterwards:

```bash
# 4. Give yourself the admin role. Group-based RBAC (cluster-admin via the
#    `admin` group) does nothing until a user actually holds it.
./scripts/zitadel-oidc-clients.sh sync $CL --grant-admin you@example.com --apply
```

## The one step no script can do

The OAuth client's **authorized redirect URI**, on the Google side, must list:

```
https://auth.<public domain>/ui/login/login/externalidp/callback
```

Google accepts many redirect URIs on one client, so a single client serves every
cluster — add both clusters' URIs once and you are done.
`zitadel-idp.sh` prints the exact URI on every run and cannot add it for you.

## Then check it worked

Open Grafana, Harbor, the Flux UI or Headlamp. You should be offered a Google
button rather than a username field, and after logging in your ZITADEL user
exists.

The per-cloud verify pages cover the rest of the post-deploy checks:
[aws-0]({{< relref "/docs/get-started/aws/verify.md" >}}) ·
[gcp-0]({{< relref "/docs/get-started/gcp/verify.md" >}}).

{{< callout type="warning" >}}
**A restored ZITADEL can predate its own configuration.** `aws-0` bootstraps its
database from a frozen backup, so a cluster rebuilt today comes back with
whatever OIDC clients and roles existed when that seed was taken — not the ones
this page creates. Re-run steps 1 and 3 after a restore; they are idempotent
and will fill in whatever the seed is missing. Harbor needs no re-run — it
converges from whatever step 1 last wrote to the `harbor-oidc` store entry. See
[Restore a database]({{< relref "/docs/guides/restore-a-database.md" >}}).
{{< /callout >}}

{{< callout type="info" >}}
**The admin PAT every script above needs is automatic, not a prerequisite.** The
chart writes it once, into the `iam-admin-pat` Secret in the `security`
namespace, at `FirstInstance`. The first script run above reads that Secret and
captures the token into the cloud secret store; every later run — on any
cluster, restored or not — reads it back from there. Nothing here needs a token
minted by hand.
{{< /callout >}}

{{< callout type="warning" >}}
**Recovery only: a cluster restored before this landed has no PAT anywhere.** If
every script above fails with `no ZITADEL admin PAT available`, the store was
never seeded — this cluster's seed predates the capture step above, or its store
entry was deleted. Mint a PAT for the `iam-admin` machine user in the ZITADEL
console, then:

```bash
kubectl create secret generic iam-admin-pat \
  -n security --from-literal=pat=<token>
```

and re-run step 1 — it persists the token into the store, so this is a one-time
recovery rather than a routine step.
{{< /callout >}}

## Related

- [Authentication]({{< relref "/docs/platform/security/authentication.md" >}}) —
  what the stack does and where the two clouds genuinely differ
- [ADR-0024]({{< relref "/docs/decisions/0024-identity-provider-per-cloud.md" >}}) —
  why each cloud runs its own ZITADEL rather than sharing one
