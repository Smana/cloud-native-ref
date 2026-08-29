---
title: Set up single sign-on
weight: 20
description: The five ordered commands that give a fresh cluster working SSO, and the one step no script can do for you.
lastVerified: 2026-08-29
---

A freshly deployed cluster has ZITADEL running and **nothing configured in it**.
These are the steps that turn that into a working Google login for Grafana,
Harbor, the Flux UI and Headlamp.

They used to live at the bottom of [Verify the cluster]({{< relref "verify.md" >}}),
which is the wrong place: this is setup, and nobody bootstrapping a cluster looks
under "verify". For what the resulting stack actually does — and why ZITADEL is in
the middle of it — see
[Authentication]({{< relref "/docs/platform/security/authentication.md" >}}).

SSO needs **five** steps, and the order is load-bearing: each one creates what
the next reads. Running only the first — which is all this page used to say —
leaves you with OIDC clients and no way to log in through Google.

Every step is idempotent: re-running prints `[skip …]` and changes nothing.

```bash
# 1. Register the OIDC clients, the project, its roles, and
#    projectRoleAssertion. That last one is not optional: with it off ZITADEL
#    puts NO roles in any token AND leaves ctx.v1.user.grants empty inside the
#    groups action, so every consumer authenticates and then has no groups.
./scripts/zitadel-oidc-clients.sh sync --cluster gcp-0 --cloud gcp \
  --project ogenki-435905 --apply

# 2. Let External Secrets read what step 1 just created. Those secrets did not
#    exist when the OpenTofu stack applied, so nothing granted access to them —
#    this reads the cluster's ExternalSecrets and grants what exists.
./scripts/secret-store.sh grant --cloud gcp --project ogenki-435905 --apply

# 3. The Google identity provider, the LOGIN POLICY entry that actually enables
#    it, and the action that flattens project roles into a `groups` claim.
#    Creating the provider without the policy entry gives "User not found".
IDP_URL=https://auth.gcp.cloud.ogenki.io \
  ./scripts/zitadel-idp.sh sync --cluster gcp-0 --cloud gcp \
  --project ogenki-435905 --apply

# 4. Harbor's auth mode. Harbor stores this in its DATABASE, not in the chart,
#    so no manifest can express it and a fresh cluster has no SSO button.
PRIVATE_DOMAIN=priv.gcp.ogenki.io \
  ./scripts/harbor-oidc.sh sync --cluster gcp-0 --cloud gcp \
  --project ogenki-435905 --apply
```

**Then log in once through Google**, at any consumer. That first login is what
CREATES your ZITADEL user — the IdP auto-registers it — so there is nobody to
authorise before it. Afterwards:

```bash
# 5. Give yourself the admin role. Group-based RBAC (cluster-admin via the
#    `admin` group) does nothing until a user actually holds it.
./scripts/zitadel-oidc-clients.sh sync --cluster gcp-0 --cloud gcp \
  --project ogenki-435905 --grant-admin you@example.com --apply
```

The **only** thing left in a console is Google-side: the OAuth client's
authorized redirect URI must list
`https://auth.<public domain>/ui/login/login/externalidp/callback`. Google
accepts many, so one client serves every cluster; `zitadel-idp.sh` prints the
exact URI on every run and cannot add it for you.

## Then check it worked

Open Grafana, Harbor, the Flux UI or Headlamp. You should be offered a Google
button rather than a username field, and after logging in your ZITADEL user
exists — [Verify the cluster]({{< relref "verify.md" >}}) covers the rest of the
post-deploy checks.
