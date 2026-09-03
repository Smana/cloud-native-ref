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
#   - treats every cloud-CLI listing/read as capable of FAILING, distinctly
#     from returning "nothing". A transient S3/GCS API error (throttling, a
#     credential refresh, a network blip) is not the same fact as "this
#     prefix is empty" or "this segment is absent", and conflating the two
#     produces exactly the same class of false confidence as the object-count
#     bug: a real seed reported unrestorable, or (the more dangerous
#     direction) an unrestorable one reported fine, because a listing call
#     failed silently and an empty result was read as data. Every call site
#     below (`ls_raw`, `cat_object`, `wal_present`, the destination-collision
#     check, the archive-settle loop) fails closed and prints the CLI's own
#     error instead of guessing.
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
#
# Every helper here distinguishes "the call failed" from "the call succeeded
# and found nothing" and NEVER collapses the former into the latter -- see
# the header. Concretely:
#   `aws s3 ls` on a genuinely empty/nonexistent prefix exits 0 with empty
#     stdout; any non-zero exit is a real failure.
#   `gcloud storage ls` exits 1 BOTH for "matched no objects" (empty, not a
#     failure) and for every other error (bucket gone, network, auth) --
#     verified live against a real bucket during this fix, so it is not a
#     bare assumption:
#       $ gcloud storage ls gs://<bucket>/definitely-does-not-exist/
#       ERROR: (gcloud.storage.ls) One or more URLs matched no objects.  (rc=1)
#       $ gcloud storage ls gs://<nonexistent-bucket>/
#       ERROR: (gcloud.storage.ls) gs://<nonexistent-bucket> not found: 404.  (rc=1)
#     so on GCP the exit code alone cannot tell those apart -- the message
#     text has to.

# Raw listing, for existence/substring checks and simple counts. Prints the
# listing on stdout and returns 0 on success (possibly with nothing to
# print -- an empty prefix is not a failure). On a REAL failure, prints the
# CLI's own error to stderr and returns 1 -- callers MUST check this, not
# just look at whether anything was printed.
#
# stdout and stderr are captured SEPARATELY (a temp file for stderr, not
# 2>&1) so a benign stderr notice on an otherwise-successful call can never
# leak into the parsed listing. Round-2 merged them with 2>&1 to get real
# error text on the failure path, but that also re-emitted stderr on the
# SUCCESS path -- `list_subdir_names`'s unanchored `sort | tail -1` then
# happily picked up a stray line like AWS CLI v2's
# "Note: switching to next-gen CRT-based S3 transfer client" (its last word,
# "client", sorts after a timestamp and wins) as if it were the newest base
# backup's name. Demonstrated live with a stub emitting exactly that notice
# under exit 0.
ls_raw() { # $1 = URI prefix (should end in /)
  local out err rc errfile
  errfile="$(mktemp)"
  case "$CLOUD" in
    aws) out="$(aws s3 ls "$1" 2>"$errfile")"; rc=$? ;;
    gcp) out="$(gcloud storage ls "$1" 2>"$errfile")"; rc=$? ;;
  esac
  err="$(cat "$errfile")"; rm -f "$errfile"
  if [ "$rc" -ne 0 ]; then
    if [ "$CLOUD" = "gcp" ] && printf '%s' "$err" | grep -q "matched no objects"; then
      return 0
    fi
    echo "[error ] listing $1 failed (exit $rc): $err" >&2
    return 1
  fi
  [ -n "$out" ] && printf '%s\n' "$out"
  return 0
}

# Bare basenames of the immediate "subdirectories" under a prefix. Needed only
# where the NAME itself is parsed (picking the newest one): `aws s3 ls` prints
# "PRE <name>/" per line, but `gcloud storage ls` prints the full
# gs://.../<name>/ URI per line -- reusing the aws-shaped
# `awk '{print $NF}' | tr -d '/'` against that mangles the whole URI into one
# deslashed blob instead of a name (e.g. "gs:bucketserverbase20260902T123813").
# Propagates ls_raw's exit code (via `set -o pipefail`) -- a listing failure
# here surfaces as a non-zero return, not as "no subdirectories".
list_subdir_names() { # $1 = URI prefix (should end in /)
  case "$CLOUD" in
    aws) ls_raw "$1" | awk '{print $NF}' | tr -d '/' ;;
    gcp) ls_raw "$1" | sed 's:/*$::' | awk -F/ '{print $NF}' ;;
  esac
}

# Stream one object's content to stdout. Read-only on both clouds: `aws s3 cp
# <src> -` and `gcloud storage cat` never write anything. Returns 0 with the
# content on success; on failure (missing object OR a real API error) prints
# the CLI's own error to stderr and returns 1 -- callers must not treat empty
# output alone as proof the object doesn't exist.
#
# Same stdout/stderr separation as ls_raw, for the same reason and for
# consistency -- not currently at risk the way ls_raw was (callers parse this
# with anchored `sed -n 's/^key=//p'`, so a stray stderr line just fails to
# match any pattern), but conflating the streams on success is the wrong
# default to leave lying around here too.
cat_object() { # $1 = full URI to the object
  local out err rc errfile
  errfile="$(mktemp)"
  case "$CLOUD" in
    aws) out="$(aws s3 cp --only-show-errors "$1" - 2>"$errfile")"; rc=$? ;;
    gcp) out="$(gcloud storage cat "$1" 2>"$errfile")"; rc=$? ;;
  esac
  err="$(cat "$errfile")"; rm -f "$errfile"
  if [ "$rc" -ne 0 ]; then
    echo "[error ] reading $1 failed (exit $rc): $err" >&2
    return 1
  fi
  printf '%s\n' "$out"
}

# Whether a WAL segment is present under <prefix-root>/wals/. Barman shards by
# the segment's first 16 hex chars, and the object carries a compression
# suffix (.bz2, .gz, ...) that depends on config -- match the segment name as
# a substring of the shard listing rather than a full filename.
#
# Returns 0 = present, 1 = genuinely absent, 2 = COULD NOT TELL (the listing
# call itself failed). Callers must never treat 2 the same as 1 -- that
# conflation is exactly the round-2 finding: a transient AWS API failure made
# a known-good, still-restorable seed (zitadel-20260902) intermittently
# report "unrestorable" because the listing came back empty for the wrong
# reason.
wal_present() { # $1 = URI root (.../<serverName-or-seed>), $2 = segment name
  local sub="${2:0:16}" out
  out="$(ls_raw "$1/wals/$sub/")" || return 2
  printf '%s\n' "$out" | grep -qF "$2"
}

# Verify a seed's restorability by parsing its NEWEST base backup's
# backup.info -- not by counting objects. This is the check that would have
# caught zitadel-20260829-2: it had a backup.info, a base/ dir and WAL
# objects; it was missing exactly the one WAL segment (end_wal) the backup
# needed. Strictly read-only. Fails closed -- and honestly -- on any listing
# or read error, distinct from a genuine "this seed is incomplete" verdict.
verify_seed() { # $1 = seed name (prefix under the bucket root)
  local seed="$1"
  local seed_uri="$URI/$seed"
  local newest rc
  newest="$(list_subdir_names "$seed_uri/base/" | sort | tail -1)"; rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "[fail] seed $seed: could not list $seed_uri/base/ -- see error above" >&2
    return 1
  fi
  [ -n "$newest" ] || { echo "[fail] seed $seed holds no base backup" >&2; return 1; }
  echo "[ok    ] seed $seed: newest base backup $newest"

  local info
  info="$(cat_object "$seed_uri/base/$newest/backup.info")"; rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "[fail] seed $seed: could not read $newest/backup.info -- see error above" >&2
    return 1
  fi
  [ -n "$info" ] || { echo "[fail] seed $seed: $newest/backup.info is empty" >&2; return 1; }

  local status begin_wal end_wal
  status="$(printf '%s\n' "$info" | sed -n 's/^status=//p')"
  begin_wal="$(printf '%s\n' "$info" | sed -n 's/^begin_wal=//p')"
  end_wal="$(printf '%s\n' "$info" | sed -n 's/^end_wal=//p')"

  [ "$status" = "DONE" ] || { echo "[fail] seed $seed: $newest status=${status:-<empty>}, expected DONE" >&2; return 1; }
  [ -n "$begin_wal" ] || { echo "[fail] seed $seed: $newest backup.info has no begin_wal" >&2; return 1; }
  [ -n "$end_wal" ] || { echo "[fail] seed $seed: $newest backup.info has no end_wal" >&2; return 1; }

  wal_present "$seed_uri" "$begin_wal"; rc=$?
  if [ "$rc" -eq 2 ]; then
    echo "[fail] seed $seed: could not verify begin_wal $begin_wal -- listing failed, see error above" >&2
    return 1
  elif [ "$rc" -ne 0 ]; then
    echo "[fail] seed $seed: begin_wal segment $begin_wal is not present under wals/ -- unrestorable" >&2
    return 1
  fi

  wal_present "$seed_uri" "$end_wal"; rc=$?
  if [ "$rc" -eq 2 ]; then
    echo "[fail] seed $seed: could not verify end_wal $end_wal -- listing failed, see error above" >&2
    return 1
  elif [ "$rc" -ne 0 ]; then
    echo "[fail] seed $seed: end_wal segment $end_wal is not present under wals/ -- unrestorable (this is the zitadel-20260829-2 failure)" >&2
    return 1
  fi

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
#    objects -- an operator could recreate the 20260829-2 failure by hand
#    this way. Read-only, so it runs in dry-run too. A listing failure here
#    fails closed too: "could not tell if it's empty" must never be read as
#    "it's empty, go ahead".
existing="$(ls_raw "$URI/$SEED/")"; existing_rc=$?
if [ "$existing_rc" -ne 0 ]; then
  echo "[fail] could not check whether seed $SEED already exists -- listing failed, see error above" >&2
  exit 1
fi
if [ -n "$existing" ]; then
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
settle_rc=0
for _ in $(seq 1 30); do
  wal_present "$URI/$SERVER_NAME" "$END_WAL"
  settle_rc=$?
  if [ "$settle_rc" -eq 0 ]; then
    settled=1
    break
  fi
  sleep 10
done
if [ "$settled" != "1" ]; then
  if [ "$settle_rc" -eq 2 ]; then
    echo "[fail] could not check for end_wal $END_WAL -- listing kept failing, see errors above" >&2
  else
    echo "[fail] end_wal $END_WAL did not land in the archive within 5 minutes" >&2
  fi
  exit 1
fi
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
