# Per-generation `serverName` for the SQLInstance composition

**Issue:** [#1963](https://github.com/Smana/cloud-native-ref/issues/1963)
**Status:** design approved, implementation not started
**Date:** 2026-09-03

## Problem

A from-scratch bootstrap cannot complete unattended. It wedges on CloudNativePG
before ZITADEL ever starts, and the platform comes up with no OIDC clients —
that is, nobody can log in to it.

Measured on a full `TM_CLOUD=all` bootstrap, 2026-09-02: all 14 stacks applied
with zero infrastructure errors, and two of three CNPG clusters latched:

```
NAMESPACE   NAME                                READY   STATUS
apps        xplane-image-gallery-cnpg-cluster   2       Cluster in healthy state
security    xplane-zitadel-cnpg-cluster                 Cluster is unrecoverable and needs manual intervention
tooling     xplane-harbor-cnpg-cluster                  Cluster is unrecoverable and needs manual intervention
```

```
barman-cloud-check-wal-archive: WAL archive check failed for server
xplane-zitadel-cnpg-cluster: Expected empty archive
  --cloud-provider aws-s3 s3://eu-west-3-ogenki-cnpg-backups xplane-zitadel-cnpg-cluster
```

`Cluster is unrecoverable` is terminal. Clearing the archive afterwards removes
the cause but does not restart the bootstrap — the `Cluster` CR has to be
deleted so Crossplane recreates it. Two interventions, neither automated.

## Root cause

CNPG refuses to start a cluster whose **destination** WAL archive is non-empty.
This is not paranoia: a new cluster begins its own timeline numbering and will
emit segment names that may already exist in that prefix from the previous
database — same filename, different content, indistinguishable afterwards.
Barman fails closed rather than let two unrelated databases interleave into one
archive.

The archive is keyed by `serverName`. The composition never sets one on the
write path, so barman defaults it to the CNPG `Cluster` name, which is derived
from the claim:

```kcl
# apis/sqlinstance/kcl/main.k — the Cluster
name = oxr.metadata.name + "-cnpg-cluster"        # xplane-zitadel-cnpg-cluster

# the backup plugin — no serverName, so the above is used
parameters = {
    barmanObjectName = oxr.metadata.name + "-cnpg-objectstore"
}
```

That string is **identical across cluster generations**. The backup buckets
outlive their clusters *by design*. Those two facts are in direct
contradiction, so generation N+1 always points at generation N's populated
prefix and the check always fails.

The check is about the destination, not about where data comes from, so this
hits clusters that bootstrap empty (`initdb`) exactly as hard as those that
restore.

The recovery path was designed correctly from the start and is not implicated:

```kcl
externalClusters[].plugin.parameters.serverName = oxr.spec.objectStoreRecovery.path
```

That reads from the frozen dated seed, explicitly, and has always been
decoupled from the live archive.

## Why the restore path is load-bearing

**The dated seed is the platform's configuration store, not a disaster-recovery
artifact.** The ZITADEL directory — projects, the five OIDC clients per
cluster, role grants, the `projectRoleAssertion` fix — exists only inside that
backup. Every bootstrap restores it precisely so none of it has to be recreated
at bootstrap or stored in Git.

This raises the stakes on two things:

1. The recovery path must stay byte-for-byte unchanged. It does; the fix is
   confined to the destination.
2. **Seed promotion is a routine, critical operation**, not an occasional
   drill — and it has the worst track record in this system. `zitadel-20260829-2`
   was *born unrestorable*: its WAL chain was copied seconds before the newest
   base backup's consistency point was archived, so recovery could never reach
   consistency. The defect was invisible until a rebuild needed it, because the
   verification used was "object count equal to source" — which that seed passed.

## Decisions

### 1. `serverName` derives from the XR uid

```kcl
serverName = oxr.metadata.name + "-cnpg-cluster-" + oxr.metadata.uid[:8]
```

The uid has exactly the required semantics: assigned at creation, stable for
the whole life of the XR, and different on every recreate. A recreated cluster
therefore writes to a prefix that is empty because it never existed, and the
check passes trivially without deleting anything.

Rejected alternatives:

- **Explicit field in the claim** (`backup.generation: "20260903"`) —
  human-readable and fully deterministic, but someone must remember to bump it
  on every rebuild, and a forgotten bump silently reinstates this exact bug.
  Retained as the fallback if the uid turns out to be unavailable (see Risks).
- **`creationTimestamp`** — automatic and readable, but must be pinned at
  create rather than re-derived; a re-render that recomputed it would split a
  running cluster's WAL chain.

The prefix becomes opaque in the bucket. That costs little, because the live
archive is never read by recovery — only the dated seeds are.

```
s3://eu-west-3-ogenki-cnpg-backups/
  xplane-zitadel-cnpg-cluster-a1b2c3d4/   generation N
  xplane-zitadel-cnpg-cluster-9f8e7d6c/   generation N+1, empty on create
  zitadel-20260902/                       frozen seed, read-only, unchanged
```

### 2. Fail closed if the uid is absent

If `oxr.metadata.uid` is empty the composition **fails the render**. It must
never fall back to the bare cluster name: a silent fallback reinstates the bug
while appearing fixed, which is strictly worse than an error.

### 3. Expire old generation prefixes after 30 days

Today the live prefix is cleared on every rebuild, so it never accumulates.
With per-generation prefixes nothing clears them, and `retentionPolicy` does
not help — it only manages the archive a *live* cluster owns, never orphaned
generations.

A bucket lifecycle rule filtered on `xplane-` expires generation archives and
is structurally incapable of touching a seed, because seeds are named
`zitadel-*` / `harbor-*` and never carry the prefix.

### 4. The rule lives in the one-time bootstrap step

Nothing in this repo creates these buckets — they are hand-created
prerequisites that deliberately outlive every cluster, as the teardown docs
state ("Keep `<project>-ogenki-cnpg-backups`"). The rule is therefore
documented alongside that existing one-time step, on both clouds.

Adopting the buckets into an OpenTofu stack was rejected: on GCS, lifecycle is
a field of `google_storage_bucket`, so managing it means importing the bucket,
and any stack in the reverse-destroy walk would then either destroy a bucket
that must survive or carry `prevent_destroy` and make `terramate destroy` fail
outright — a new instance of [#1964](https://github.com/Smana/cloud-native-ref/issues/1964).

This remains a manual step, but it is **once ever per cloud**, not once per
rebuild. That is a different category from what this work removes.

### 5. Seed promotion becomes a script

The change makes the promotion source prefix uid-suffixed, so the operator
would have to look it up. Removing a manual step from the bootstrap while
adding one to the procedure that keeps the platform's configuration alive is a
bad trade — especially on the operation that already produced one unrestorable
seed.

`scripts/cnpg-promote-seed.sh` performs the whole procedure and encodes the
lessons currently living in a comment block:

1. Create a one-shot `Backup`, wait for `phase=completed`
2. `SELECT pg_switch_wal()` and **wait for the backup's `end_wal` to appear
   under `wals/`** — the step whose absence made `-0829-2` unrestorable
3. Discover the current `serverName` from the live Cluster rather than
   assuming it
4. Copy the live prefix to a dated seed
5. Verify the copy is restorable by checking that the newest base backup's
   `begin_wal` and `end_wal` are both present in the seed, and that later
   segments exist so replay continues past the consistency point — **not** by
   comparing object counts, which is the check that let `-0829-2` through

## Scope

### `Smana/crossplane-configuration`

| File | Change |
|---|---|
| `apis/sqlinstance/kcl/main.k` | add `serverName` to the backup plugin parameters; assert non-empty uid |
| `apis/sqlinstance/kcl/main_test.k` | assert serverName present, uid-suffixed, differs between two XRs differing only by uid; assert recovery serverName still equals the seed path |
| `apis/sqlinstance/kcl/settings-example.yaml` | add `uid` to the example `oxr` |
| `tests/golden/sqlinstance-*.yaml` | regenerate |
| `apis/sqlinstance/README.md` | document the archive layout and the upgrade constraint |

Then `task check`, cut a release.

### `Smana/cloud-native-ref`

| File | Change |
|---|---|
| `infrastructure/base/crossplane/configuration-aws/configuration-packages.yaml` | pin bump from `v0.4.6` |
| `security/base/zitadel/sqlinstance.yaml` | delete the obsolete "RESTORING REQUIRES CLEARING THE LIVE ARCHIVE FIRST" block; point the promotion procedure at the new script |
| `tooling/aws-0/harbor/sqlinstance.yaml`, `tooling/gcp-0/harbor/sqlinstance.yaml` | same, where they carry the same guidance |
| `scripts/cnpg-promote-seed.sh` | new |
| `scripts/cnpg-prepare-restore.sh` | no longer on the normal path; retained as an escape hatch, re-documented as such |
| `website/content/docs/guides/restore-a-database.md` | update the layout and procedure |
| bootstrap docs, both clouds | add the lifecycle rule to the hand-created bucket step |
| `.doc-claims.yaml` | update any claim asserting the old archive layout |

## The upgrade hazard

Bumping the pin under a **running** cluster changes its `serverName` mid-life.
The new prefix is empty, the check passes, and archiving continues there — but
the cluster's existing base backups are left in the old prefix, orphaned from
every subsequent WAL. PITR across that boundary breaks.

Both clouds are empty as of 2026-09-03, so shipping before the next bootstrap
means no cluster ever experiences the transition. The README must nonetheless
state it: **bump the pin while rebuilding, or take a fresh base backup
immediately after.**

## Risks and unknowns

**`oxr.metadata.uid` availability is unproven.** No composition in
`crossplane-configuration` has ever read a metadata field other than `name` or
`namespace`, and the KCL test harness supplies neither `uid` nor anything else.
That Crossplane populates it in the observed XR at render time is an
assumption.

The first task in the implementation plan is a throwaway render proving it. If
the uid is empty at render time, the design falls back to the explicit claim
field (rejected alternative 1) and the rest of this document stands unchanged.

**The promotion script needs a live cluster to test properly.** Its verification
logic — WAL presence, replay continuation — cannot be exercised against an
empty cloud. It should be validated during the next bootstrap rather than
declared working on the strength of a dry run.

## Success criteria

1. A from-scratch bootstrap into an account whose backup bucket already holds a
   previous generation's prefixes completes with **no manual archive clearing**,
   and all CNPG clusters reach `Cluster in healthy state`.
2. ZITADEL starts, and the OIDC client registration runs automatically rather
   than timing out.
3. A restore from a dated seed still works, unchanged.
4. `cnpg-promote-seed.sh` produces a seed whose newest base backup has both
   `begin_wal` and `end_wal` present, verified by the script itself.
5. `task check` passes in `crossplane-configuration`;
   `./scripts/validate-manifests.sh` passes here with `Invalid: 0, Skipped: 0`.

## Out of scope

- The terminal `Cluster is unrecoverable` state. This change removes its cause,
  and there are no wedged clusters to recover — both clouds are empty. If it
  recurs for an unrelated reason it warrants its own fix.
- [#1964](https://github.com/Smana/cloud-native-ref/issues/1964), the teardown
  reverse-walk halt. Same theme, different root cause, tracked separately.
- The ZITADEL wait budget (`bd905bdb`), which makes this failure legible but
  does not fix it.
