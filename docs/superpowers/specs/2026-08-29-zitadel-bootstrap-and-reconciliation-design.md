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

### 1. Persist the admin PAT, resolve it from the store on every run

The chart's `FirstInstance` provisions an `iam-admin` machine user with both a
`MachineKey` and a `Pat`, each valid to 2029-01-01. Both are written only to a
Kubernetes Secret, which dies with the cluster.

Persist the PAT to the hosting cloud's secret store the first time any setup
script needs it, and have every later run — on any cluster, restored or not —
read it back from there:

```
FirstInstance (fresh DB only)
  └─> chart writes Secret security/iam-admin-pat
        └─> first script run captures it into the cloud secret store
              └─> every later run, on any cluster, reads it from there
```

**Not an ExternalSecret.** Nothing running *in* the cluster consumes this
credential — only the operator scripts do, from outside, over each cloud's own
CLI — and an ExternalSecret targeting `security/iam-admin-pat` would contend
with the Helm chart for ownership of the very Secret the chart writes at
`FirstInstance`: two controllers asserting the same object is how one of them
starts losing writes. `scripts/lib/zitadel-pat.sh`'s `resolve_zitadel_pat`
reads the store directly instead, so there is no in-cluster object and no
ownership question to have.

This works because a restored database still contains the machine user **and its
token hash**, so a token captured at first bootstrap remains valid against the
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

### 2. The setup scripts became reconcilers

`sync` reconciling redirect URIs (#1919) fixed one script before this plan
started. The rest were create-if-missing, and each was audited end to end
rather than assumed — the guesses below turned out wrong in both directions,
some scripts already converging where none was expected and some silently not
converging where it looked like they did:

| Script | Owns | Finding |
|---|---|---|
| `zitadel-oidc-clients.sh` | clients, redirect URIs, project roles, `projectRoleAssertion` | redirect URIs reconcile as of #1919. `ensure_project_role_assertion` and `ensure_project_roles` already read current state and converge correctly — verified directly against the code, not touched by this plan. |
| `zitadel-idp.sh` | Google IdP, login-policy entry, the `groupsFromRoles` action and its flow trigger | `login_policy_has_idp` already compared and converged; left alone. `ensure_idp` created once and then reported `[skip]` forever — fixed to compare `clientId` and PUT in place on drift (an in-place update, so existing user↔IdP links survive). `ensure_action` and `ensure_flow` always wrote on `--apply` and never reported `[ok]` — fixed to compare against the live object first, both endpoints returning what's needed inline with no extra GET. |
| `harbor-oidc.sh` | Harbor's `auth_mode` and OIDC endpoint, stored in Harbor's own database | the pre-existing code already compared all three observable fields (`auth_mode`, `oidc_client_id`, `oidc_endpoint`) in one bundled check and only skipped when every one matched — the staleness this row worried about was already caught. What was missing was per-field *reporting*: a dry run couldn't say which field was stale without reading the raw `current:` line by hand. Fixed to report each field independently. The audit also found and closed two pre-existing client-secret argv leaks, unrelated to convergence. |
| `secret-store.sh grant` | External Secrets' access to the above (GCP only) | additive, as expected; unchanged |

**Where the Google IdP actually drifts.** A Google-type provider has no
caller-set `issuer` at all — Google's is fixed (`accounts.google.com`), and
`AddGoogleProvider`/`UpdateGoogleProvider` don't accept one. `zitadel-idp.sh`'s
`IDP_URL` is never written into any object ZITADEL stores; it is only the base
URL the script's own API calls use and an operator-facing hint printed at the
end. So the drift this design set out to close is not a hostname changing
underneath the IdP — it is **objects that exist but no longer match the
repository**: a rotated or replaced Google OAuth client leaving `clientId`
stale, or `scripts/zitadel-actions/groups-from-roles.js` being edited on disk
after the action was created, leaving the deployed copy behind. Both are now
checked; a secret-only rotation (same `clientId`, regenerated secret) stays
invisible to this check, because neither ZITADEL nor Harbor ever echoes a
stored secret back on GET — there is nothing to compare it against.

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

None remaining. The one open at design time — whether the PAT copy is a
Kubernetes Job or a script step — resolved to neither exactly as framed:
`resolve_zitadel_pat` in `scripts/lib/zitadel-pat.sh` captures the PAT lazily,
the first time any setup script needs it, rather than as a dedicated step at
deploy time. No Job, and no separate capture invocation — every script that
already reads the PAT (`zitadel-oidc-clients.sh`, `zitadel-idp.sh`) gets the
capture for free by calling the resolver.
