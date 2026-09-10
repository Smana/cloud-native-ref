---
title: Secrets
weight: 18
description: Where a secret lives, who may read and write it, how a human and a controller each prove who they are, and what a developer writes to give an application a secret of its own.
lastVerified: 2026-09-10
---

Two questions decide a secrets design, and most of the interesting failures come
from answering only the first:

1. **Where does the secret live?**
2. **Who may read it?**

A cloud managed store answers the first well and the second badly — the answer
there is "whoever holds cloud credentials scoped to that path", and this
platform's IAM is scoped by the `xplane-*` prefix rather than by application. So
until recently there was no mechanism by which one application's secrets could
belong to one application's people.

This page is the answer to both, in the order a secret travels: where it is
stored, who is allowed near it, how each kind of caller proves it, and what a
developer types to get one.

## Where a secret lives

**OpenBao is the store of record.** It holds two kv-v2 mounts, both in the root
namespace:

| Mount | Holds | Example |
|---|---|---|
| `platform/` | platform component credentials | `platform/harbor/admin-password` |
| `apps/` | application credentials | `apps/image-gallery/config` |

Two mounts rather than one because External Secrets' `vault` provider takes
exactly one mount per store, so the split is what lets the two audiences carry
different policies without path-prefix gymnastics inside a single policy
document. Both live in **root** because a policy binds only within the namespace
it is created in, and the OIDC mount and every identity group are in root — the
reasoning is in [ADR-0036]({{< relref "/docs/decisions/0036-per-app-secret-ownership-via-zitadel-groups.md" >}}).

### What deliberately does *not* live there

A small **bootstrap tier** stays in the cloud managed store, permanently:

- the CA chain (`certificates/priv.aws.ogenki.io/ca-chain`)
- OpenBao's own server certificate and key
- the root token and recovery keys

These are read *before* OpenBao has an API. The clearest case is the
`openbao-ca` `ExternalSecret`: the OpenBao-backed stores below verify OpenBao's
certificate against a CA `Secret` that this `ExternalSecret` produces. Repointing
it at OpenBao would be circular, so it reads the cloud store and always will.

Three `cnpg/*` credentials also stay put. They are generated at runtime by the
database seeding path rather than curated by a human, and moving them would mean
granting a machine write access to a mount — the exact property removed below.

{{< callout type="warning" >}}
**A store of record is only as durable as its restore.** OpenBao's storage here
is *derived state*: it is rebuilt from its newest snapshot on every deploy. What
persists is the lineage, not the volume — see
[ADR-0033]({{< relref "/docs/decisions/0033-openbao-store-of-record-lineage.md" >}})
and [the OpenBao page]({{< relref "/docs/platform/security/openbao.md#the-lineage-and-rehydrate-at-boot" >}}).
Putting the store of record on OpenBao was gated on that drill running green.
{{< /callout >}}

## Who may read it

Three kinds of caller reach these mounts, and each gets a different answer.

| Caller | Authenticates by | May read | May write |
|---|---|---|---|
| A platform admin | ZITADEL OIDC → `openbao-admin` group | both mounts | both mounts, including `destroy` |
| An app's owner | ZITADEL OIDC → `openbao-app-<name>` group | `apps/<name>/*` | `apps/<name>/*`, **never `destroy`** |
| External Secrets | projected ServiceAccount token → `jwt/<cluster>` | both mounts | **nothing** |

### Machines read, humans write

That last row is the one that makes the second row mean anything.

External Secrets resolves a store with the **controller's** identity, not the
requester's. The controller reads on behalf of whatever `ExternalSecret` asks. If
it could also write, then anything able to shape an `ExternalSecret` — any
workload with create access in its own namespace — could launder a value into
another app's prefix, and per-app ownership would be decorative.

So the `external-secrets` role holds a read-only policy over `platform/data/*`
and `apps/data/*` and no write capability of any kind. Proven by logging in as
that identity and trying:

```console
$ bao kv put platform/canary probe=1
Code: 403. Errors:

	* permission denied
```

### `destroy` is withheld from apps

A per-app policy grants `create`, `read`, `update`, `patch`, `delete`, `list` on
its own prefix, plus `metadata`, `delete` and `undelete` — but not `destroy`.
`delete` in kv-v2 is a soft delete that can be undone; `destroy` erases version
history irreversibly. A compromised app credential should not be able to burn the
history of its own secrets. Erasing history is an administrative act, so
`secrets-admin` does carry it.

## How a human gets in

Authorisation rides the `groups` claim that
[Authentication]({{< relref "/docs/platform/security/authentication.md#zitadel--a-groups-claim" >}})
already establishes for Headlamp, Grafana and the Flux UI. Nothing new is
invented for OpenBao:

```
Google Workspace  →  ZITADEL user  →  project role `app-image-gallery`
                  →  groups claim  →  OpenBao external group `openbao-app-image-gallery`
                  →  policy `app-image-gallery`  →  apps/data/image-gallery/*
```

One policy and one external group are generated **per app**, from an explicit
list, rather than one templated policy covering all of them. The trade is
deliberate: templating collapses N policies into one but makes the grant
invisible in a `tofu plan` diff, and one template mistake widens every app at
once. [ADR-0036]({{< relref "/docs/decisions/0036-per-app-secret-ownership-via-zitadel-groups.md" >}})
records the alternatives.

{{< callout type="warning" >}}
**A per-app group that appears to grant nothing is almost always the claim, not
the policy.** Three things must all hold, and only the third produces an error
that looks like an authorisation problem:

1. ZITADEL's `projectRoleAssertion` is **true** — it defaults to false, and with
   it off no role reaches any token at all.
2. The `groupsFromRoles` Action is present on the token flow — ZITADEL has
   project roles, not groups, and this is what flattens them.
3. The OIDC role requests the `groups` scope — without it the claim is simply
   absent, and the symptom is `claim "email" not found in token` rather than a
   permission denial.

Check them in that order before reading any policy.
{{< /callout >}}

## The break-glass path

OpenBao keeps a `userpass` admin login alongside OIDC, and it is not a leftover.
[ADR-0034]({{< relref "/docs/decisions/0034-openbao-oidc-via-zitadel-project-roles.md" >}})
kept it on purpose, because the credential ZITADEL itself boots from now lives in
`platform/zitadel/envvars`. An OIDC-only login would have no way back in.

```bash
export VAULT_ADDR=https://bao.priv.aws.ogenki.io:8200
export VAULT_CACERT=opentofu/aws/openbao/management/.tls/ca.pem
bao login -method=userpass username=admin

# the password is generated by the management stack and published here
aws secretsmanager get-secret-value \
  --secret-id openbao/cloud-native-ref/users/admin \
  --query SecretString --output text | jq -r .password
```

{{< callout type="warning" >}}
**This login must carry `secrets-admin`, and once did not.** When the two mounts
were created, `secrets-admin` was attached only to the `openbao-admin` *identity
group* — which is reached through ZITADEL. The break-glass login authenticated
fine and returned 403 on every read of both mounts:

```
Code: 403. Errors:
	* preflight capability check returned 403, please ensure client's
	  policies grant access to path "platform/zitadel/envvars/"
```

So the one path that exists for when ZITADEL is unavailable was the one path that
could not read what would bring ZITADEL back. It is fixed in
`opentofu/aws/openbao/management/auth.tf`; if you add a mount, add it to this
login's policies in the same change.
{{< /callout >}}

## How a controller gets in

External Secrets authenticates with a **projected ServiceAccount token** — no
AppRole, no long-lived credential anywhere:

```yaml
auth:
  jwt:
    path: "jwt/${cluster_name}"     # jwt/aws-0, jwt/gcp-0
    role: "external-secrets"
    kubernetesServiceAccountToken:
      serviceAccountRef:
        name: external-secrets
        namespace: security
      audiences:
        - openbao
```

There are two `ClusterSecretStore`s, one per mount, both shaped like this and
differing only in `path: platform` / `path: apps`. Both reach OpenBao in-cluster
at `openbao.security.svc.cluster.local:8200` and verify its certificate against
the `openbao-ca` Secret from the bootstrap tier.

The cluster's third store, `clustersecretstore`, still points at the cloud
managed store and still serves the bootstrap tier. Its shape and the reasoning
behind the shared name are in
[PKI & Secrets]({{< relref "/docs/platform/security/pki-and-secrets.md#external-secrets-the-other-direction" >}}).

## Declaring an app that has a secret

Here is the part a developer actually touches. An application on this platform is
an `App` claim, and a secret is four lines in it:

```yaml
apiVersion: cloud.ogenki.io/v1alpha1
kind: App
metadata:
  name: image-gallery
  namespace: apps
spec:
  externalSecrets:
    - name: image-gallery-app-config     # the Kubernetes Secret this becomes
      remoteRef: image-gallery/config    # path within the store's mount
      store: openbao-apps                # omit for the cloud managed store
  envFrom:
    - secretRef:
        name: image-gallery-app-config
        optional: true
```

That is the whole thing. The composition renders the `ExternalSecret`, wires the
store reference, and the operator materialises a Kubernetes `Secret` of the same
name with **every key from that path** as an entry — which `envFrom` then turns
into environment variables of the same names. There is no `ExternalSecret` to
write, no store to configure, and no IAM to request.

Three details are worth knowing before the first one bites you.

**`remoteRef` is relative to the store's mount.** `image-gallery/config`, not
`apps/image-gallery/config` — the store already carries the mount. Under the
cloud managed store the path was absolute and dash-separated
(`apps-app-wizard-oauth`), because [ADR-0023]({{< relref "/docs/decisions/0023-portable-secret-store-names.md" >}})
needed one key name to work against two clouds' managed stores. There is one
OpenBao for both clouds, so a path is just a path.

**`store` defaults to `clustersecretstore`.** A claim written before the field
existed keeps reading the cloud managed store, unchanged. Naming `openbao-apps`
is what moves it.

**Writing the value is now self-service, and that is the point.** A human in the
app's own group can create and update `apps/<app>/*` in the OpenBao UI without a
platform admin, and cannot touch another app's prefix. Before this, populating an
application credential meant someone with cloud credentials writing to a managed
store.

### Onboarding a new app is two-sided

The one cost of generating a policy per app rather than templating one: a new app
needs both halves, and neither can be created from the other.

1. A **ZITADEL project role** `app-<name>`, granted to the humans who own it.
2. An entry in the app list in `opentofu/aws/openbao/management`, which generates
   the `app-<name>` policy and the `openbao-app-<name>` external group.

A human does not exist in ZITADEL until their first login, so step 1 cannot be
fully seeded ahead of time either. An app with no secrets needs neither: no
group is created for an app that holds nothing.

## Migration state

The move off the cloud managed store was done key by key, copy-first, and nothing
was deleted before the new source was proven for that key. Where it stands:

| Reading OpenBao | Still on the managed store |
|---|---|
| every platform component credential — Harbor, Grafana, Alertmanager, the Flux UI and Slack app, runlore, Tailscale, Headlamp | the bootstrap tier (CA chain, server cert, root token, recovery keys) — permanently |
| ZITADEL's own envvars and masterkey | the three runtime-generated `cnpg/*` credentials |
| the three application secrets | components not currently running (the suspended LLM platform, `gha-runners`, `promptfoo`) |

ZITADEL moved last and alone, deliberately: it is the IdP behind the OIDC login
that reaches OpenBao itself, so it moved only once the break-glass path above was
known good.

## Related

- [ADR-0036]({{< relref "/docs/decisions/0036-per-app-secret-ownership-via-zitadel-groups.md" >}}) — per-app ownership, and the three rejected alternatives
- [ADR-0033]({{< relref "/docs/decisions/0033-openbao-store-of-record-lineage.md" >}}) — the lineage that makes OpenBao durable enough to hold this
- [ADR-0034]({{< relref "/docs/decisions/0034-openbao-oidc-via-zitadel-project-roles.md" >}}) — human login through ZITADEL, and why userpass survives
- [ADR-0025]({{< relref "/docs/decisions/0025-cloud-managed-secret-stores.md" >}}) — the earlier decision this supersedes for everything but the bootstrap tier
- [OpenBao]({{< relref "/docs/platform/security/openbao.md" >}}) — mounts, auth methods, backup and restore
- [Authentication]({{< relref "/docs/platform/security/authentication.md" >}}) — where the `groups` claim comes from
- [PKI & Secrets]({{< relref "/docs/platform/security/pki-and-secrets.md" >}}) — the certificate half, and the managed store that remains
