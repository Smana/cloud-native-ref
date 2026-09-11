# An access matrix driven by Google Workspace groups

Supersedes [`2026-09-10-openbao-stage2-secrets-personas-design.md`](2026-09-10-openbao-stage2-secrets-personas-design.md)
on the question of who owns an application's secrets, and closes the gap
[ADR-0034](../../../website/content/docs/decisions/0034-openbao-oidc-via-zitadel-project-roles.md)
named but did not fill.

## Why this exists

Authorisation on this platform is a set of ZITADEL project roles granted **by
hand**, one person at a time, after that person's first login. Google Workspace
sits upstream as the identity provider but contributes nothing to *authorisation*
— it decides who can log in, not what they may do.

Two consequences follow, and the second is the one that motivated this design.

**Offboarding is incomplete.** ADR-0034 states it plainly: removing someone in
Google stops their login but leaves the role grant behind as an artefact. The
grant is the thing that says what they could do, and nothing removes it.

**Nobody can answer "who can read this?" from the repository.** The grants live
only in ZITADEL's database. There is no reviewable artefact, no diff, and no
audit trail in Git.

There is also a defect to clear up. Stage 2 shipped per-app OpenBao identity
groups (`openbao-app-<name>`, aliased to a ZITADEL role `app-<name>`) — and
**nothing creates an `app-*` role**. `ZITADEL_PROJECT_ROLES` in
`scripts/zitadel-oidc-clients.sh` is a hardcoded four-element list
(`admin backend frontend data`) that was never extended. The groups can never
match a token. They are inert, and this design deletes rather than repairs them.

## What the platform reads today

Every consumer already agrees on one claim, which is what makes an incremental
design possible:

| Consumer | How it authorises |
|---|---|
| Kubernetes (`aws-0`) | OIDC `groups` claim → `kind: Group, name: admin` → `ClusterRoleBinding` |
| Kubernetes (`gcp-0`) | Workforce pool → `principalSet://…/workforcePools/<pool>/group/admin` |
| Grafana | `role_attribute_path` over the `roles` claim |
| Flux UI | CEL `claims.groups` |
| Headlamp | `groups` claim |
| OpenBao | `groups` claim → identity group alias → policy |

The claim itself is produced by `groupsFromRoles`, a ZITADEL **v1 Action** that
flattens `ctx.v1.user.grants` — role grants, not groups.

## Target

### The matrix

One file with **one row per team and a column per consumer**. It is not a lookup
table that something reads at runtime — it is the source the platform's
authorisation config is *rendered from*:

```yaml
# security/base/access-matrix/matrix.yaml
teams:
  - team: platform
    googleGroup: platform@ogenki.io
    kubernetes: cluster-admin
    secrets: all                      # both mounts
    grafana: Admin
    fluxUI: cluster-admin
  - team: backend
    googleGroup: backend@ogenki.io
    kubernetes: view
    secrets: own                      # apps/backend/* only
    grafana: Editor
    fluxUI: view                      # was edit; owner, 2026-09-11: read-only, GitOps only
  - team: data
    googleGroup: data-eng@ogenki.io
    kubernetes: view
    secrets: own
    grafana: Editor
    fluxUI: view                      # was edit; owner, 2026-09-11: read-only, GitOps only
  - team: frontend
    googleGroup: frontend@ogenki.io
    kubernetes: none
    secrets: none
    grafana: Editor
    fluxUI: none
```

**The team name is one name in three systems**: the ZITADEL project role, the
OpenBao identity group suffix (`openbao-team-<team>`), and the secret-path
segment (`apps/<team>/…`). Three names for one concept is how they drift.

**The teams are defined fresh.** `admin` becomes `platform`, so every row is a
team rather than a permission level. There is no migration cost to pay for this:
every consumer binding is a file in this repository — `security/base/rbac/admin.yaml`,
`flux/operator/rbac.yaml`, `security/gcp-0/rbac/admin.yaml`, Grafana's
`role_attribute_path`, and the hardcoded `ZITADEL_PROJECT_ROLES` — and the
reconciler recreates every ZITADEL grant from this file by definition, so there
are no in-flight grants to preserve.

### What the matrix renders

| Output | Rendered from | Where |
|---|---|---|
| ZITADEL project role list | the `team` column | replaces the hardcoded `ZITADEL_PROJECT_ROLES` |
| `ClusterRoleBinding` per team | `kubernetes` ≠ `none` | `kind: Group, name: <team>` on AWS; `principalSet://…/group/<team>` on GCP |
| OpenBao identity group + policy | `secrets` | `all` → `admin`+`pki-admin`+`secrets-admin`; `own` → the team-prefix policy; `none` → no group at all |

`secrets: all` is how the former `openbao-admin` group is expressed, so the
special case disappears into data rather than living in `oidc.tf` as a
hand-written exception.

**Grafana, the Flux UI and Headlamp keep their own mapping**, and a validator
asserts it agrees with the matrix — that the set of teams named in Grafana's
`role_attribute_path` and the Flux UI's CEL is exactly the set with a non-`none`
value here. Generating those two expressions was considered and rejected:
`role_attribute_path` is a JMESPath expression that changes rarely, and a
generator bug in it becomes a login-authorisation bug. A validator catches drift
without owning the file.

> **`kubernetes: view`, not `edit`, for the app-owning teams — deliberately.**
> `edit` is only meaningful scoped to a namespace, and every app shares the
> `apps` namespace today. [`per-user-rbac.md`](../../../website/content/docs/platform/security/per-user-rbac.md)
> already made this call — *"inventing namespace conventions before there are
> teams to fit them is how you get bindings nobody matches"*. Now there are
> teams, but still one namespace. Namespace-scoped `edit` waits on per-team
> namespaces, which is the same prerequisite as per-team `ClusterSecretStore`s;
> the two should land together or not at all.

### The reconciler

A **CronJob**, every 15 minutes, whose entire job is:

```
read matrix.yaml
  → for each team: list Workspace group members     (Directory API)
  → list current ZITADEL grants for that role       (ZITADEL management API)
  → grant what is missing, revoke what is no longer in the group
```

A controller was rejected: there is no Kubernetes resource to watch, the input is
an external directory that must be polled regardless, and a CronJob running a
script matches the repo's existing operational tooling and can be run by hand
during an incident. Fifteen minutes of lag is acceptable because losing the
Google account blocks the login itself immediately.

**It runs on the primary cloud only** — a singleton for the same reason ZITADEL
is one ([ADR-0027](../../../website/content/docs/decisions/0027-primary-cloud-provider.md)).
Two reconcilers writing the same grants would fight.

**Credentials — neither is a new static secret:**

| Need | Mechanism |
|---|---|
| ZITADEL management API | the existing `zitadel/iam-admin-pat`, which every setup script already resolves |
| Workspace Directory API | **no service-account key.** Workload Identity on GCP; on AWS the existing `opentofu/shared/aws-gcp-federation` stack impersonates the service account |

Domain-wide delegation traditionally implies a downloaded private key to sign the
impersonation JWT. It does not have to: `iamcredentials.signJwt` produces the
same assertion with no key material on disk. **The plan must pin this mechanism
concretely and prove it, rather than inherit this paragraph's optimism** — it is
the one piece of the credential path not already in use somewhere in this repo.

Scope requested is `https://www.googleapis.com/auth/admin.directory.group.readonly`
— read-only, groups only.

### Team-scoped secrets

Secrets move from `apps/<app>/<key>` to **`apps/<team>/<app>/<key>`**, and one
policy plus one identity group is generated per **team**, `for_each` over the
matrix rather than over a list of apps:

```hcl
path "apps/data/<team>/*"     { capabilities = ["create","read","update","patch","delete","list"] }
path "apps/metadata/<team>/*" { capabilities = ["create","read","update","list","delete"] }
path "apps/delete/<team>/*"   { capabilities = ["update"] }
path "apps/undelete/<team>/*" { capabilities = ["update"] }
# no destroy -- unchanged from ADR-0036's reasoning
```

This deletes the cost ADR-0036 explicitly accepted: **adding an app needs no
OpenBao change at all**, because the grant is on the team prefix rather than on
an enumerated app. The `platform/` mount is untouched and stays admin-only.

**The hand-written `openbao-admin` group in `oidc.tf` is deleted**, replaced by
the `secrets: all` row. Leaving both would be a correctness bug, not untidiness:
an identity group alias must be unique per mount accessor, so a generated group
and a hand-written one both claiming `platform` would conflict at apply time or
silently reassign. One generator, one group per team, no exceptions — which is
the benefit of putting the permission in a column rather than in a special case.

> **kv-v2's literal `data/` segment collides with a team named `data`.** The
> policy path is `apps/data/data/*` — first segment the API, second the team. It
> reads like a typo and is correct. The policy template carries this comment at
> the point of confusion, because the alternative is someone "fixing" it.

### Declaring an app's team

The `App` claim declares its team once; the composition derives the path:

```yaml
spec:
  team: data
  externalSecrets:
    - name: image-gallery-app-config
      remoteRef: config          # -> apps/data/image-gallery/config
      store: openbao-apps
```

Preferred over having the developer write `data/image-gallery/config` by hand: a
typo cannot silently point at another team's prefix, and moving an app between
teams is a one-field edit rather than a path rewrite.

`spec.team` is **optional**, defaulting to unset, so every existing claim keeps
rendering unchanged; a claim with no team keeps the flat `apps/<app>/<key>` path
until it is migrated.

### What this boundary does and does not do

**It governs humans, not claims.** External Secrets resolves a store with the
*controller's* identity, so ESO can read all of `apps/` and a claim in any
namespace can still name any team's path. Closing that would need a
`ClusterSecretStore` per team **plus** per-team namespaces for ESO's
`namespaceSelector` to discriminate — every app shares the `apps` namespace
today, so it would buy nothing. Out of scope, stated here because the phrase
"per-team ownership" invites the opposite assumption.

## Failure modes

These are the behaviours to write tests against first; most of the risk is in
what the reconciler does when something is missing.

**An empty API response must never mean "revoke everyone."** "Could not list
group X" and "group X has no members" are different states. The first skips team
X and exits non-zero. Only an authoritative empty list may revoke, and it still
meets the guard below. This single rule is what stops a Google outage becoming a
platform-wide lockout.

**Blast-radius guard.** A run that would revoke more than **half of a role's
grants, or more than two, whichever is larger** stops and reports rather than
proceeding; the threshold is configurable and that is the default. The "or more
than two" half matters: on a role with two members, a pure percentage lets both
go one at a time without ever tripping. A matrix typo, a renamed Workspace group
and a partial directory outage are indistinguishable at the moment of revocation;
mass removal should require a human.

**Never leave a role with zero members**, `platform` above all. The blast-radius
guard would usually catch it, but "zero admins" deserves a rule of its own rather
than depending on a percentage threshold.

**A group member with no ZITADEL user is normal.** A user does not exist until
first login, so the grant cannot be made yet. Skip, count, succeed — and because
the job runs every 15 minutes the grant lands shortly after that person's first
login, with no ghost users pre-created.

**Hand-made grants are revoked**, because Git is the source of truth. That is
correct and it is also how someone's emergency access disappears, so each
revocation logs the matrix row that justified it.

**The escape hatch already exists.** OpenBao's `userpass` break-glass is
independent of ZITADEL and carries `secrets-admin`. Worst case, the reconciler
locks everyone out of the OIDC path and that login still works. **Kubernetes has
no equivalent**, which is why the zero-admins rule is hard rather than advisory.

**Dry-run by default**, `--apply` to write, matching `secret-store.sh`. A
`VMServiceScrape` and a `VMRule` so a reconciler that has silently stopped
succeeding is an alert rather than a discovery — a sync with nothing to do and a
sync that is broken look identical from outside.

## Decomposition — two plans, not one

This is more than one implementation plan's worth, and the two halves have
different risk profiles and only one ordering constraint between them:

| Plan | Contents | Risk |
|---|---|---|
| **A — the matrix and the reconciler** | matrix file, the renderers for ZITADEL roles and `ClusterRoleBinding`s, the drift validator, the team rename, CronJob, credentials, guards, tests, three-gate rollout | can lock people out; gated |
| **B — team-scoped secrets** | OpenBao team policies/groups rendered from the matrix, `spec.team` on the App XRD, composition path derivation, key migration, deleting ADR-0036's inert artefacts and the hand-written `openbao-admin` group | non-destructive; copy-first |

**A before B**, because B's team prefixes are meaningless until a team name is a
role someone can actually hold. B is otherwise independent and could be paused
after A without leaving anything half-built.

The team rename (`admin` → `platform`) belongs to **A**, in one commit with the
five files that name it. Splitting a rename across two plans is how half of a
codebase ends up on each name.

## Migration

1. **Ship the reconciler in dry-run.** It reports the Workspace↔ZITADEL diff and
   writes nothing. Every row should be explainable; if not, the matrix is wrong.
2. **Grants only.** Revocation off. This can only widen access.
3. **Revocation on**, with the guards above.

The secrets migration rides separately, with one ordering constraint: the team
names must exist as ZITADEL roles first. Keys move copy-first → repoint →
delete-later, the non-destructive sequence Stage 2 used successfully.

The composition change adds `spec.team` and the path derivation — a
`crossplane-configuration` release and pin bump, **with the core `dependsOn`
floor raised in the same release**: the field lands on the App XRD in the *core*
package, and a stale floor silently leaves the cluster on an XRD without it.

## Prerequisites (Google side, manual)

- The team groups themselves, in Workspace.
- Admin SDK (or Cloud Identity) API enabled on the project.
- A service account, and domain-wide delegation authorised for
  `admin.directory.group.readonly`.

## Records

- **New ADR** — *platform access is an access matrix in Git, reconciled from
  Google Workspace groups*. Supersedes ADR-0036. Rejected alternatives: a
  token-time Action V2 calling the Directory API (a directory outage becomes a
  login outage, and an Action cannot read a Git matrix); naming-convention
  mapping with no matrix file (a Workspace rename silently changes permissions);
  bypassing ZITADEL per consumer (adds a second mechanism without removing the
  first).
- **Amend ADR-0034.** Its rejection of Workspace groups was correct when written
  — "nothing carries it into ZITADEL". This design builds that carrier, so the
  record should say so rather than quietly contradict it. Its worked examples
  also name the `admin` role and need the rename.
- **ADR-0036 marked superseded**, including the note that its per-app groups were
  inert.
- Update `website/content/docs/platform/security/secrets.md`, `authentication.md`
  and `per-user-rbac.md` — the last one carries the "who gets what" table, which
  becomes a rendering of the matrix rather than a hand-maintained copy of it.
- Add a doc claim binding that table to the matrix file, so the two cannot drift
  the way the role list and `ZITADEL_PROJECT_ROLES` did.

## Success criteria

1. Adding a person to a Workspace group grants them the team's access within one
   reconcile interval, with no human action in ZITADEL.
2. Removing them revokes it within one interval.
3. `git log` on the matrix file answers "who could do what, when" without
   querying ZITADEL.
4. **The matrix is the only place a team's permissions are written.** Changing a
   team's `kubernetes` column and re-rendering changes the `ClusterRoleBinding`
   on both clouds, with no other file edited by hand.
5. The drift validator fails when Grafana's `role_attribute_path` names a team
   the matrix does not, or omits one it does.
6. A simulated directory outage produces **zero** revocations and a non-zero exit.
7. A run that would revoke the last member of the `platform` team refuses.
8. A second consecutive run makes no changes (idempotence).
9. A human in one team can read and write their team's prefix in the OpenBao UI
   and is denied on another team's.
10. Adding an app to an existing team requires no OpenBao or Terraform change.
11. No file outside the matrix contains the string `admin` as a ZITADEL role or
    Kubernetes group name — the rename is complete rather than partial.
12. `./scripts/validate-manifests.sh` reports `Invalid: 0, Skipped: 0`.

## Risks

- **Lockout is the headline risk**, mitigated by the three-gate rollout, the
  guards, and the OpenBao break-glass. Kubernetes has no break-glass, so the
  zero-admins rule carries more weight than it first appears.
- **Domain-wide delegation is a powerful grant**, even read-only. It is scoped to
  groups, the credential is keyless, and the reconciler is the only consumer.
- **`groupsFromRoles` is a v1 Action, and Actions V1 is removed in ZITADEL V6**
  (upstream #10833, closed 2026-07-30; the platform runs 4.6.1). This design
  neither worsens nor fixes that. It remains a prerequisite for the V6 upgrade
  and is tracked separately — but note that when it breaks, it takes every
  consumer in the table above with it, including this design.
- **ZITADEL has no native group→authorization** (upstream #5822: CRUD done,
  token scope and authorisations not). If it ever lands, the reconciler could
  write groups instead of per-user grants and shed most of its bookkeeping. The
  design should not wait for it.

## Out of scope

- The Actions V1 → V2 migration.
- GKE's native `authenticator_groups_config` / `gke-security-groups@`, which
  would let GKE resolve Workspace groups directly and could eventually retire the
  token-exchange-proxy shim of ADR-0032. A genuinely attractive second design,
  deliberately not folded in here.
- Per-team `ClusterSecretStore`s and per-team namespaces.
- Harbor, whose OIDC group wiring was not located during design and must be
  confirmed before it is claimed as a consumer.
