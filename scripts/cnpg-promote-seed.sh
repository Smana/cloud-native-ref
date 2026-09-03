#!/usr/bin/env bash
#
# Promote a live CNPG cluster's archive to a frozen, dated restore seed --
# or, with --verify-seed, check an EXISTING seed's restorability on its own,
# with no cluster and no mutation at all.
#
# WHY THIS IS A SCRIPT AND NOT A PROCEDURE
#
# The seed is the platform's configuration store: the ZITADEL directory --
# projects, OIDC clients, role grants -- exists only inside it, and every
# bootstrap restores from it rather than reconfiguring from scratch.
#
# zitadel-20260829-2 was born unrestorable. Recovery targets the seed's NEWEST
# base backup; that backup's consistency point sat in a WAL segment archived
# seconds AFTER the copy was taken, so replay could never reach consistency and
# the recovery Job looped forever. The check used at the time -- "object count
# equal to source" -- passed: the seed had a backup.info, a base/ dir and WAL
# objects. It was missing exactly one WAL segment: the one the backup actually
# needed. The failure surfaced weeks later, during a rebuild.
#
# So this script:
#   - switches WAL and waits for the SPECIFIC end_wal segment CNPG reports for
#     the backup it just took -- not "any WAL count increase". An increase
#     driven by unrelated WAL activity satisfies that check while the segment
#     actually needed is still missing, which is how 20260829-2 happened.
#   - verifies a seed (freshly copied, or via --verify-seed on an existing
#     one) by parsing the newest base backup's backup.info and confirming
#     status=DONE and that BOTH its begin_wal and end_wal segments are present
#     under wals/. Object counts are never used as evidence: an object
#     existing is not the same as the RIGHT object existing.
#   - refuses to copy into a seed prefix that already holds objects. A
#     same-day re-run defaults to the same dated name; copying into it would
#     merge two backup generations into one seed and silently overwrite
#     same-key WAL objects.
#
# Dry-run unless --apply. --verify-seed is always read-only, regardless of
# --apply, and never touches --cluster/--namespace.
set -uo pipefail

CLUSTER=""; NAMESPACE=""; CLOUD=""; BUCKET=""; SEED=""; APPLY=0; VERIFY_SEED=""
while [ $# -gt 0 ]; do
  case "$1" in
    --cluster)     CLUSTER="$2"; shift 2 ;;
    --namespace)   NAMESPACE="$2"; shift 2 ;;
    --cloud)       CLOUD="$2"; shift 2 ;;
    --bucket)      BUCKET="$2"; shift 2 ;;
    --seed)        SEED="$2"; shift 2 ;;
    --verify-seed) VERIFY_SEED="$2"; shift 2 ;;
    --apply)       APPLY=1; shift ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

for v in CLOUD BUCKET; do
  [ -n "${!v}" ] || { echo "--${v,,} is required" >&2; exit 2; }
done

case "$CLOUD" in
  aws) URI="s3://$BUCKET"; CP="aws s3 cp" ;;
  gcp) URI="gs://$BUCKET"; CP="gcloud storage cp" ;;
  *) echo "--cloud must be aws or gcp" >&2; exit 2 ;;
esac

# ---- cloud-abstraction helpers ---------------------------------------------

# Raw listing, for existence/substring checks and simple counts. Output
# format differs by cloud but both put the object/prefix name somewhere on
# the line, which is all a grep/wc -l caller needs.
ls_raw() { # $1 = URI prefix (should end in /)
  case "$CLOUD" in
    aws) aws s3 ls "$1" 2>/dev/null ;;
    gcp) gcloud storage ls "$1" 2>/dev/null ;;
  esac
}

# Bare basenames of the immediate "subdirectories" under a prefix. Needed only
# where the NAME itself is parsed (picking the newest one): `aws s3 ls` prints
# "PRE <name>/" per line, but `gcloud storage ls` prints the full
# gs://.../<name>/ URI per line -- reusing the aws-shaped
# `awk '{print $NF}' | tr -d '/'` against that mangles the whole URI into one
# deslashed blob instead of a name (e.g. "gs:bucketserverbase20260902T123813").
list_subdir_names() { # $1 = URI prefix (should end in /)
  case "$CLOUD" in
    aws) ls_raw "$1" | awk '{print $NF}' | tr -d '/' ;;
    gcp) ls_raw "$1" | sed 's:/*$::' | awk -F/ '{print $NF}' ;;
  esac
}

# Stream one object's content to stdout. Read-only on both clouds: `aws s3 cp
# <src> -` and `gcloud storage cat` never write anything.
cat_object() { # $1 = full URI to the object
  case "$CLOUD" in
    aws) aws s3 cp --only-show-errors "$1" - 2>/dev/null ;;
    gcp) gcloud storage cat "$1" 2>/dev/null ;;
  esac
}

# True if a WAL segment is present under <prefix-root>/wals/. Barman shards by
# the segment's first 16 hex chars, and the object carries a compression
# suffix (.bz2, .gz, ...) that depends on config -- match the segment name as
# a substring of the shard listing rather than a full filename.
wal_present() { # $1 = URI root (.../<serverName-or-seed>), $2 = segment name
  local sub="${2:0:16}"
  ls_raw "$1/wals/$sub/" | grep -qF "$2"
}

# Verify a seed's restorability by parsing its NEWEST base backup's
# backup.info -- not by counting objects. This is the check that would have
# caught zitadel-20260829-2: it had a backup.info, a base/ dir and WAL
# objects; it was missing exactly the one WAL segment (end_wal) the backup
# needed. Strictly read-only.
verify_seed() { # $1 = seed name (prefix under the bucket root)
  local seed="$1"
  local seed_uri="$URI/$seed"
  local newest
  newest="$(list_subdir_names "$seed_uri/base/" | sort | tail -1)"
  [ -n "$newest" ] || { echo "[fail] seed $seed holds no base backup" >&2; return 1; }
  echo "[ok    ] seed $seed: newest base backup $newest"

  local info
  info="$(cat_object "$seed_uri/base/$newest/backup.info")"
  [ -n "$info" ] || { echo "[fail] seed $seed: $newest/backup.info missing or unreadable" >&2; return 1; }

  local status begin_wal end_wal
  status="$(printf '%s\n' "$info" | sed -n 's/^status=//p')"
  begin_wal="$(printf '%s\n' "$info" | sed -n 's/^begin_wal=//p')"
  end_wal="$(printf '%s\n' "$info" | sed -n 's/^end_wal=//p')"

  [ "$status" = "DONE" ] || { echo "[fail] seed $seed: $newest status=${status:-<empty>}, expected DONE" >&2; return 1; }
  [ -n "$begin_wal" ] || { echo "[fail] seed $seed: $newest backup.info has no begin_wal" >&2; return 1; }
  [ -n "$end_wal" ] || { echo "[fail] seed $seed: $newest backup.info has no end_wal" >&2; return 1; }

  wal_present "$seed_uri" "$begin_wal" \
    || { echo "[fail] seed $seed: begin_wal segment $begin_wal is not present under wals/ -- unrestorable" >&2; return 1; }
  wal_present "$seed_uri" "$end_wal" \
    || { echo "[fail] seed $seed: end_wal segment $end_wal is not present under wals/ -- unrestorable (this is the zitadel-20260829-2 failure)" >&2; return 1; }

  echo "[ok    ] seed $seed: status=DONE, begin_wal=$begin_wal present, end_wal=$end_wal present"
  return 0
}

# ---- --verify-seed: read-only, standalone, no cluster involved ------------

if [ -n "$VERIFY_SEED" ]; then
  echo "verify:    $VERIFY_SEED ($CLOUD, $URI)"
  verify_seed "$VERIFY_SEED"
  exit $?
fi

# ---- normal mode: promote a live cluster's archive to a new seed ----------

for v in CLUSTER NAMESPACE; do
  [ -n "${!v}" ] || { echo "--${v,,} is required" >&2; exit 2; }
done
[ -n "$SEED" ] || SEED="${CLUSTER#xplane-}-$(date +%Y%m%d)"

CNPG="${CLUSTER}-cnpg-cluster"

echo "cluster:   $CNPG (ns $NAMESPACE)"
echo "seed:      $SEED"

# 1. Discover the live prefix rather than assuming it. Since #1963 the
#    serverName carries a per-generation uid suffix, so it cannot be guessed.
SERVER_NAME="$(kubectl get cluster "$CNPG" -n "$NAMESPACE" \
  -o jsonpath='{.spec.plugins[?(@.name=="barman-cloud.cloudnative-pg.io")].parameters.serverName}' 2>/dev/null)"
[ -n "$SERVER_NAME" ] || { echo "[fail] could not read serverName from $CNPG" >&2; exit 1; }
echo "[ok    ] serverName $SERVER_NAME"

# 2. Refuse a destination collision before ANYTHING mutates. A same-day
#    re-run defaults to the same SEED name; copying into it would merge two
#    backup generations into one seed and silently overwrite same-key WAL
#    objects -- an operator could recreate the 20260829-2 failure by hand this
#    way. Read-only, so it runs in dry-run too.
existing="$(ls_raw "$URI/$SEED/" | wc -l)"
if [ "$existing" -gt 0 ]; then
  echo "[fail] seed $SEED already has objects in it -- refusing to merge into an existing seed. Pass an explicit --seed with a name that does not exist yet." >&2
  exit 1
fi

if [ "$APPLY" != "1" ]; then
  echo "[dry-run] would create a one-shot Backup, pg_switch_wal, wait for its end_wal segment,"
  echo "[dry-run] then copy $SERVER_NAME/ -> $SEED/ and verify. Re-run with --apply."
  exit 0
fi

# 3. Find the primary. Pod ordinals are fixed at creation and the primary
#    role moves after any failover, so "${CNPG}-1" is not reliably the
#    primary.
PRIMARY_POD="$(kubectl get pod -n "$NAMESPACE" \
  -l "cnpg.io/cluster=$CNPG,cnpg.io/instanceRole=primary" \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)"
[ -n "$PRIMARY_POD" ] || { echo "[fail] could not find the primary pod for $CNPG" >&2; exit 1; }
echo "[ok    ] primary pod $PRIMARY_POD"

# 4. One-shot backup.
BACKUP="promote-$(date +%Y%m%d%H%M%S)"
if ! kubectl create -n "$NAMESPACE" -f - >/dev/null <<EOF
apiVersion: postgresql.cnpg.io/v1
kind: Backup
metadata:
  name: $BACKUP
spec:
  cluster:
    name: $CNPG
  method: plugin
  pluginConfiguration:
    name: barman-cloud.cloudnative-pg.io
EOF
then
  echo "[fail] could not create Backup $BACKUP" >&2
  exit 1
fi

phase=""
for _ in $(seq 1 60); do
  phase="$(kubectl get backup "$BACKUP" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null)"
  [ "$phase" = "completed" ] && break
  [ "$phase" = "failed" ] && { echo "[fail] backup $BACKUP failed" >&2; exit 1; }
  sleep 10
done
[ "$phase" = "completed" ] || { echo "[fail] backup $BACKUP did not complete" >&2; exit 1; }
echo "[ok    ] backup $BACKUP completed"

# 5. The specific WAL segment THIS backup needs archived -- read from CNPG's
#    own status, never guessed. Force it out with pg_switch_wal (PostgreSQL
#    only archives a segment once it is full; without forcing the switch, the
#    segment can sit open and unarchived indefinitely -- the exact
#    zitadel-20260829-2 failure), then poll for THAT segment specifically.
#    Breaking on "any WAL count increase" was the bug: unrelated WAL churn
#    satisfies it while the segment actually needed is still missing, and if
#    the count never rises the old loop exited by exhaustion and copied
#    anyway.
END_WAL="$(kubectl get backup "$BACKUP" -n "$NAMESPACE" -o jsonpath='{.status.endWal}' 2>/dev/null)"
[ -n "$END_WAL" ] || { echo "[fail] backup $BACKUP has no status.endWal" >&2; exit 1; }
echo "[ok    ] backup $BACKUP needs end_wal $END_WAL"

kubectl exec -n "$NAMESPACE" "$PRIMARY_POD" -c postgres -- \
  psql -tAc "SELECT pg_switch_wal();" >/dev/null 2>&1 \
  || { echo "[fail] pg_switch_wal failed" >&2; exit 1; }
echo "[ok    ] pg_switch_wal issued"

settled=0
for _ in $(seq 1 30); do
  if wal_present "$URI/$SERVER_NAME" "$END_WAL"; then
    settled=1
    break
  fi
  sleep 10
done
[ "$settled" = "1" ] || { echo "[fail] end_wal $END_WAL did not land in the archive within 5 minutes" >&2; exit 1; }
echo "[ok    ] end_wal $END_WAL archived"

# 6. Copy. The destination-empty check in step 2 is what makes this safe to
#    run unconditionally.
$CP --recursive "$URI/$SERVER_NAME/" "$URI/$SEED/" >/dev/null \
  || { echo "[fail] copy failed" >&2; exit 1; }
echo "[ok    ] copied $SERVER_NAME/ -> $SEED/"

# 7. Verify RESTORABILITY, not object counts -- the same check --verify-seed
#    runs standalone.
if verify_seed "$SEED"; then
  echo
  echo "Set spec.objectStoreRecovery.path to: $SEED"
else
  exit 1
fi
