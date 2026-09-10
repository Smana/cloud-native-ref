---
title: An app's secrets are owned by its own ZITADEL group, and the policy for each app is generated rather than templated
linkTitle: 0036 · Per-app secret ownership
weight: 360
description: Two kv-v2 mounts in OpenBao's root namespace, `platform/` and `apps/`, with one policy and one external identity group generated per app by `for_each`. Identity templating is rejected because it makes the grant invisible in a plan diff; flat reader/writer tiers are rejected because a writer would reach every app's secrets. External Secrets is read-only on both mounts, which is what makes the per-app boundary mean anything.
lastVerified: 2026-09-10
---

**Status**: Accepted
**Date**: 2026-09-10
**Deciders**: Smana (Platform Owner)
**Related**: [ADR-0025](0025-cloud-managed-secret-stores.md) — the cloud managed
store this moves off; [ADR-0033](0033-openbao-store-of-record-lineage.md) — the
lineage that made OpenBao durable enough to hold the store of record;
[ADR-0034](0034-openbao-oidc-via-zitadel-project-roles.md) — the `groups` claim
this authorises against; [ADR-0023](0023-portable-secret-store-names.md) — the
dash grammar this replaces with a path

---

## Context

[ADR-0033](0033-openbao-store-of-record-lineage.md) made OpenBao durable enough
to be the store of record, and Stage 1 built the foundation for it: a JWT auth
mount per cluster, an OIDC mount, a restore drill that runs weekly. Stage 2 — the
repoint — was carved out of that work and left unplanned, so for a while the
platform had the door and not the key:

| Built by Stage 1 | State before this decision |
|---|---|
| `auth/jwt/aws-0/role/external-secrets` | `token_policies = [default]` — authenticates, reads nothing |
| `app` namespace + `secret/` mount + AppRole | no consumer anywhere in the cluster |
| `oidc/` mount with a `groups` claim | one coarse `admin` group, no grant on any secret |
| both `ClusterSecretStore`s | still `aws: SecretsManager` / `gcpsm` |

Every application secret was read from a cloud managed store, which answers
*where a secret lives* but not *who may read it*. On a managed store the answer is
"whoever holds cloud credentials scoped to that path", and this platform's IAM is
scoped by the `xplane-*` prefix rather than by application. There was no
mechanism by which one app's secrets could belong to one app's people.

Two questions had to be answered before a plan could be written:

1. **Where do application secrets live**, as distinct from platform component
   secrets?
2. **Who may read and write them?**

---

## Decision Drivers

- **A grant should be visible in a plan diff.** This platform is reviewed through
  `tofu plan` output; an authorisation change that does not appear there is one
  nobody reviews.
- **One app's credential must not reach another app's secrets** — the property
  that makes "ownership" more than a naming convention.
- **The blast radius of a compromised credential must be bounded**, including its
  ability to destroy history rather than merely read it.
- **Onboarding cost is allowed to be non-zero.** This is a reference platform; an
  explicit step that is reviewed beats an implicit one that is not.
- **The bootstrap path must not become circular.** Some secrets are read before
  OpenBao has an API.

---

## Considered Options

### Option 1: Identity templating — one policy for all apps

A single policy using OpenBao's identity templating, where the path itself
carries the group name:

```hcl
path "apps/data/{{identity.groups.names.<name>.id}}/*" { ... }
```

**Pros**:
- N apps collapse to one policy document; onboarding an app touches nothing in
  Terraform.
- No per-app resources to drift.

**Cons**:
- **The grant becomes invisible.** `tofu plan` shows one unchanged policy whether
  the platform has three apps or thirty. There is nothing to review.
- One mistake in the template widens *every* app's reach simultaneously, and the
  blast radius of a typo is the whole mount.
- Debugging an authorisation failure means reasoning about template expansion at
  request time rather than reading a rendered policy.

### Option 2: Flat tiers — reader, writer, admin over the whole store

Three policies by capability rather than by application.

**Pros**:
- Fewest moving parts; a familiar shape.
- No per-app resources at all.

**Cons**:
- **A writer reaches every app's secrets.** The tier is the capability, so there
  is no boundary between applications — precisely the property being sought.
- Adding an app changes nothing, which sounds like a benefit until you ask who
  may read its credentials: everyone already in the tier.

### Option 3: A namespace per app

OpenBao namespaces as the tenancy boundary, one per application.

**Pros**:
- The strongest isolation OpenBao offers.
- Matches the pre-existing `app` namespace, so it looks like the intended design.

**Cons**:
- **A policy binds only within the namespace it is created in**, and the `oidc/`
  mount, the identity groups and every existing policy are in root. Each app
  namespace would need its own auth mount and its own identity plumbing.
- That is the exact wall the pre-existing `app` namespace hit: it held a `secret/`
  kv-v2 mount reachable by nothing but a root token, and no human could get to it.
- Buys nothing over a path prefix for the threat this platform actually has.

### Option 4: One policy and one external group per app, generated by `for_each`

An explicit list of apps drives generation of one policy and one external
identity group each, matched on the `groups` claim ADR-0034 established.

**Pros**:
- **Every grant appears in `tofu plan`.** Adding an app is a visible diff of new
  named resources.
- A mistake is scoped to one app's policy.
- The rendered policy can be read directly on the cluster when debugging.

**Cons**:
- Onboarding an app touches Terraform, and is two-sided: a ZITADEL role must
  exist as well as the OpenBao group.
- N policies to keep consistent, mitigated by their all coming from one template.

---

## Decision Outcome

**Chosen option**: Option 4 — one policy and one external group per app,
generated with `for_each`, over two kv-v2 mounts in the **root** namespace.

### Two mounts

| Mount | Grammar | Written by |
|---|---|---|
| `platform/` | `platform/<component>/<name>` — maps one-to-one onto [ADR-0023](0023-portable-secret-store-names.md)'s dash names (`harbor-admin-password` → `platform/harbor/admin-password`) | platform admins |
| `apps/` | `apps/<app>/<key>` | the owning app's group |

Two rather than one because External Secrets' `vault` provider takes a single
mount per store (`spec.provider.vault.path`). The split is what lets the two
audiences carry different policies without path-prefix gymnastics inside one
policy document.

**Root namespace is load-bearing, not incidental.** A policy binds only within
its own namespace, and the `oidc/` mount, the identity groups and every existing
policy are in root. Putting the mounts anywhere else reintroduces the
cross-namespace identity problem that has no clean answer — Option 3's wall.

### Personas

| ZITADEL role | OpenBao external group | Policies |
|---|---|---|
| `admin` | `openbao-admin` | `admin`, `pki-admin`, **`secrets-admin`** — full CRUD over both mounts |
| `app-<name>` | `openbao-app-<name>` | `app-<name>` — CRUD on that app's own prefix in the `apps/` mount, plus `metadata`/`delete`/`undelete`; **no `destroy`** |

`destroy` is withheld from every per-app policy: a compromised credential must
not be able to erase secret history. Erasing history is an administrative act, so
`secrets-admin` does carry it.

### Machines read, humans write

The `external-secrets` JWT role gets a **read-only** policy over both mounts and
no write capability of any kind:

```hcl
path "platform/data/*" { capabilities = ["read"] }
path "apps/data/*"     { capabilities = ["read"] }
```

This is the property that makes per-app ownership mean something. External
Secrets resolves a store with the **controller's** identity, not the requester's.
If the controller could write, anything able to shape an `ExternalSecret` could
launder a value into another app's prefix, and the boundary above would be
decorative.

---

## Consequences

### Positive

- Every authorisation change is a reviewable diff of named resources.
- One app's credential cannot read another app's prefix, and cannot destroy
  history in its own.
- The `groups` claim already carried by [ADR-0034](0034-openbao-oidc-via-zitadel-project-roles.md)
  is reused rather than a second authorisation mechanism invented.
- Secret paths become paths. ADR-0023's dash grammar existed so one key name
  worked against two clouds' managed stores; there is one OpenBao for both
  clouds, so `apps-image-gallery-config` becomes `image-gallery/config` in the
  `apps/` mount.

### Negative

- **Onboarding an app is two-sided and cannot be driven from this repository
  alone**: the ZITADEL role must exist, and a human does not exist in ZITADEL
  until their first login.
- Adding an app touches Terraform. This is the accepted cost of Option 4 over
  Option 1, not an oversight.
- N per-app policies exist where one templated policy would do.

### Neutral

- The `app` tenant namespace becomes dead weight, and is scheduled for removal
  rather than kept as a decoy. It holds no data and nothing consumes it.
- A tier of secrets stays in the cloud managed store permanently — the CA chain,
  OpenBao's own server certificate, root token and recovery keys. These are read
  *before* OpenBao has an API, so moving them would be circular. The
  `openbao-ca` `ExternalSecret` is the clearest case: the OpenBao-backed stores
  cannot verify OpenBao's certificate without the CA it produces.

---

## Implementation Notes

Two things were learned by executing this that are worth recording, because both
were predicted in a comment and missed anyway.

**The break-glass login must carry `secrets-admin`.** When the mounts were
created, `secrets-admin` was attached only to the `openbao-admin` *identity
group* — which is reached through ZITADEL. The `userpass` admin that exists
precisely for when ZITADEL is unavailable could log in and got 403 on every read
of both mounts. Since `platform/zitadel/envvars` is the credential ZITADEL boots
from, the one path that exists for when the IdP is down was the one path that
could not read what would bring it back.
[ADR-0034](0034-openbao-oidc-via-zitadel-project-roles.md) had already stated the
hazard in its own description; `admin.hcl` had already written *"any kv mount
later created in root would need it back"*. Both were right, and the grant was
still missed.

**An App claim could not name a store.** Application secrets are not standalone
`ExternalSecret` documents on this platform — they are
`spec.externalSecrets[].remoteRef` on an `App` claim, and the Crossplane
composition hardcoded `secretStoreRef.name: clustersecretstore`. The XRD exposed
no store field at all. Moving app secrets therefore required an API change in
[`Smana/crossplane-configuration`](https://github.com/Smana/crossplane-configuration)
(an optional `store`, defaulting to the previous value so existing claims render
byte-identical), a release, and a coordinated pin bump — a dependency the design
did not anticipate.

Migration is non-destructive throughout: values are copied into OpenBao without
overwriting, `ExternalSecret` documents are repointed one at a time, and the
managed-store originals are deleted by hand only after the new source is proven
for that key.

---

## References

- Design: `docs/superpowers/specs/2026-09-10-openbao-stage2-secrets-personas-design.md`
- Parent design: `docs/superpowers/specs/2026-09-02-openbao-store-of-record-design.md`
- [Secrets]({{< relref "/docs/platform/security/secrets.md" >}}) — the operational page
- [`Smana/crossplane-configuration`](https://github.com/Smana/crossplane-configuration) — where the `App` composition lives
