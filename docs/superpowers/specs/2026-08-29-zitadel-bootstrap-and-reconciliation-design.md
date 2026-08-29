# ZITADEL bootstrap and reconciliation

**Date**: 2026-08-29
**Status**: Design — approved, not implemented
**Depends on**: [ADR-0027](../../../website/content/docs/decisions/0027-primary-cloud-provider.md) · **Amends framing in**: [ADR-0024](../../../website/content/docs/decisions/0024-identity-provider-per-cloud.md)

## The problem

A cluster restored from a frozen ZITADEL database comes back with **configuration
from the day the seed was taken**, and with **no way to correct it**.

Both halves were observed on 2026-08-29 during a from-scratch `aws-0` build.

`aws-0` restores from `zitadel-20260719`. The cloud split moved the private domain
to `priv.aws.ogenki.io` on 2026-08-23. So every OIDC client in the restored
database still pointed at `priv.cloud.ogenki.io`, a month out of date, and every
login failed:

```
error: invalid_request
error_description: The requested redirect_uri is missing in the client configuration
```

The obvious repair — re-run `scripts/zitadel-oidc-clients.sh sync` — could not
work, for two independent reasons:

1. It **skipped every existing client** by design, so it reported five clients
   fine and changed nothing. Fixed on the day (PR #1919): `sync` now reconciles
   redirect URIs through the `oidc_config` endpoint, which does not rotate the
   client secret.
2. It **could not authenticate at all**. Every ZITADEL script reads an admin
   Personal Access Token from the `security/iam-admin-pat` Secret, which the Helm
   chart writes during `FirstInstance` — and **a restored database never runs
   FirstInstance**. Neither cluster has that Secret today.

So the platform restores stale configuration and, in the same act, removes the
means to fix it. That second half is what this design closes.

## What the restore is for

The database carries two kinds of state, and they deserve opposite treatment.

**Identity — keep restoring it.** Human users, Google IdP links, role grants. A
human user exists only after a first interactive login, so no script can seed
one. This is why the restore exists and it is worth keeping.

It also carries something less obvious: **the OIDC clients themselves**. The app
row holds the client ID and the secret's hash, and the plaintext secret is
already in the cloud secret store from when the client was created — those
entries outlive clusters by design. Restore therefore keeps client credentials
**stable across rebuilds**, and consumers never notice a rebuild happened.

Dropping the restore was considered and rejected for exactly that reason: a fresh
bootstrap recreates all five clients with new IDs and secrets, which then need an
External Secrets refresh (interval `1h`) *and* a restart of every consumer that
reads them as environment variables, *and* a re-run of `harbor-oidc.sh`. Trading
one stale field for five rotated credentials on every rebuild is a bad trade.

**Configuration — stop restoring it, start reconciling it.** Redirect URIs,
project roles, `projectRoleAssertion`, the Google IdP entry, the login policy,
Harbor's auth mode. All of it is derivable from the repository. Restoring it
means importing whatever was true when the seed was frozen, and nothing converges
it afterwards.

> **The rule this design establishes:** the database owns identity, the
> repository owns configuration. Where the two disagree, the repository wins, on
> every deploy.

## Design

### 1. Persist the admin PAT, rehydrate it on every deploy

The chart's `FirstInstance` provisions an `iam-admin` machine user with both a
`MachineKey` and a `Pat`, each valid to 2029-01-01. Both are written only to a
Kubernetes Secret, which dies with the cluster.

Persist the PAT to the hosting cloud's secret store as soon as it is created, and
rehydrate it with an ExternalSecret thereafter:

```
FirstInstance (fresh DB only)
  └─> chart writes Secret security/iam-admin-pat
        └─> [new] copied to the cloud secret store, once
              └─> ExternalSecret rehydrates it on every later deploy
```

This works because a restored database still contains the machine user **and its
token hash**, so a token persisted at first bootstrap remains valid against the
restored instance. It is also the pattern every other credential here already
uses — [ADR-0025](../../../website/content/docs/decisions/0025-cloud-managed-secret-stores.md)
makes the cloud secret store the store of record precisely because it outlives
the platform.

**Naming**, following the per-cloud conventions already in force:

| Cloud | Secret name |
|---|---|
| AWS | `zitadel/iam-admin-pat` |
| GCP | `zitadel-iam-admin-pat` (Secret Manager forbids `/`) |

**Why not the MachineKey (approach B).** A JSON key exchanged for short-lived
JWTs is the better credential in principle — no long-lived bearer token at rest.
But it needs the identical persistence treatment, plus a key-exchange step in
four scripts, to solve a problem the existing Kubernetes Secret already has.
Recorded as available hardening, deliberately not done now.

**Rejected: re-minting by hand after each restore.** No code, but a manual step
on every rebuild of both clouds. Today is a demonstration of what happens to
manual steps that are not written down.

### 2. The setup scripts become reconcilers

`sync` reconciling redirect URIs (#1919) fixed one script. The rest are
create-if-missing and must be audited to converge instead:

| Script | Owns | Today |
|---|---|---|
| `zitadel-oidc-clients.sh` | clients, redirect URIs, project roles, `projectRoleAssertion` | redirect URIs reconcile as of #1919; roles and the assertion flag need checking |
| `zitadel-idp.sh` | Google IdP, login-policy entry, `groupsFromRoles` action | `ensure_*` helpers look idempotent; needs confirming they *correct* drift rather than skip |
| `harbor-oidc.sh` | Harbor's `auth_mode` and OIDC endpoint, stored in Harbor's own database | unknown; Harbor's config is not in git, so drift here is invisible |
| `secret-store.sh grant` | External Secrets' access to the above (GCP only) | additive; likely fine |

Two properties each must hold: **converge, don't skip**, and **never rotate a
client secret to fix a non-secret field** — the reason `sync` updates
`oidc_config` rather than recreating the app.

`oidc_config` **replaces** rather than patches, so every field the create call
sets must be resent. Omitting one silently reverts it to a ZITADEL default, and
`accessTokenRoleAssertion` / `idTokenRoleAssertion` reverting to `false` is the
same failure as `projectRoleAssertion` being off: authentication keeps working
and every consumer quietly loses its groups.

### 3. Migration is an exception, and documented

**AWS is the default host and stays so.** ZITADEL relocates only when the
platform runs GCP-only — the scenario ADR-0024 exists for. It is a deliberate,
occasional event, so it needs a correct written procedure, not automation.

Three things travel together, and a move that copies some of them fails silently:

1. the **database seed** — copied into the target cloud's backup bucket;
2. the **admin PAT** — written into the target cloud's secret store under that
   cloud's name;
3. the **client secrets** — the five consumer entries, likewise.

Then the two ADR-0024 gates flip, and the deploy reconciles configuration to the
new cluster's domain. The redirect URIs change with the move, which is exactly
what step 2's reconciliation is for — and the Google OAuth client already accepts
both clusters' callback URIs, so nothing is needed in the Google console.

### 4. ADR-0024 is amended, not replaced

Its decision holds: per-cloud deployable, AWS default, two gates that must agree.

Its **accepted cost** does not. "One user directory per cloud" describes two
coexisting directories; the real model is **one directory, hosted on AWS, which
relocates only for a GCP-only platform**. That framing is what made today's state
— ZITADEL running on both clusters at once — look intended rather than a testing
artifact.

## Success criteria

1. A rebuilt `aws-0` restoring from any seed, however old, ends with every OIDC
   client's redirect URI matching the current private domain, without manual
   intervention.
2. `zitadel-oidc-clients.sh sync` runs successfully on a restored cluster —
   the `iam-admin-pat` Secret is present without anyone creating it by hand.
3. Client IDs and secrets are unchanged across a rebuild; no consumer restart is
   required.
4. Re-running any setup script twice changes nothing the second time.
5. The GCP-only migration procedure has been followed once, end to end, and the
   restored instance serves logins on the GCP domain.

## Out of scope

- Replacing the PAT with MachineKey/JWT (hardening, recorded above).
- Automating the cloud migration.
- Rotating client secrets on a schedule.
- Anything about Harbor's own user database beyond its `auth_mode`.

## Open questions

None blocking. One to settle during implementation: whether the PAT copy is a
Kubernetes Job in the ZITADEL Kustomization or a step in
`scripts/zitadel-oidc-clients.sh` invoked at deploy time. A Job keeps it
declarative and runs without an operator present; a script step is easier to
debug and matches how the other ZITADEL setup already works.
