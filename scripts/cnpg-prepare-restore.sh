#!/usr/bin/env bash
#
# Clear a CloudNativePG cluster's live WAL archive, so a new cluster can start.
#
# NOT PART OF THE NORMAL PATH ANY MORE.
#
# Since #1963 each cluster generation writes to its own WAL archive prefix, so a
# rebuild's destination is empty by construction and nothing needs clearing.
#
# This remains as an escape hatch for the cases that still collide: a cluster
# pinned to an explicit serverName, an archive left behind by a pre-#1963
# generation, or a deliberate reuse of a prefix. It still refuses to clear a
# live archive unless the named seed actually holds a base backup.
#
# TWO DIFFERENT QUESTIONS, TWO DIFFERENT PREDICATES
#
# The seed and the live archive are counted differently, and conflating them is
# the bug this script had on its first day:
#
#   SEED  "is there something to restore from?"  -> count BASE BACKUPS.
#         A seed with WALs but no base/ is unusable; a restore reads base/.
#
#   LIVE  "will barman's check refuse?"          -> count ANY OBJECT.
#         The check is about the WAL archive. A live prefix holding six WALs and
#         no base/ still refuses -- and a base-backup count calls it "empty".
#
# Found on 2026-08-29 preparing an aws-0 rebuild: xplane-zitadel-cnpg-cluster/
# held wals/ and nothing else, and this script reported "already empty; nothing
# to clear" for an archive that would have failed the bootstrap.
#
# THE GUARD, WHICH IS THE WHOLE POINT
#
# With --seed, it refuses unless that seed contains at least one base backup.
# Clearing the live prefix while the seed is absent or half-copied destroys the
# only copy of the database with nothing to restore from -- the one way this
# operation can go badly, and the reason it should not be a bare `rm -r` typed
# from memory.
#
# A cluster that bootstraps empty has no seed and therefore no such protection:
# clearing its archive discards its only backup. That case needs
# --accept-data-loss, spelled out, rather than an omitted flag.
#
# It never touches the seed, only the live cluster prefix.
#
# Usage:
#   cnpg-prepare-restore.sh --cloud gcp --bucket B --cluster C --seed zitadel-20260828 [--project ID] [--apply]
#   cnpg-prepare-restore.sh --cloud aws --bucket B --cluster C --seed zitadel-20260719 [--region R] [--profile P] [--apply]
#   cnpg-prepare-restore.sh --cloud aws --bucket B --cluster C --accept-data-loss [--apply]   # bootstraps empty
#
# Dry-run unless --apply.

set -o errexit
set -o nounset
set -o pipefail

# gcloud must run as the identity OpenTofu uses, not the CLI account -- see
# scripts/lib/gcloud-adc.sh. Without it this script reports "could not list the
# live archive" for a bucket the deploy writes to happily.
# shellcheck source=scripts/lib/gcloud-adc.sh
. "$(dirname "$0")/lib/gcloud-adc.sh"

CLOUD="" BUCKET="" CLUSTER="" SEED="" PROJECT="" PROFILE=""
REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-}}"
APPLY="false"
ACCEPT_LOSS="false"

while [ $# -gt 0 ]; do
    case "$1" in
        --cloud)             CLOUD="$2"; shift 2 ;;
        --bucket)            BUCKET="$2"; shift 2 ;;
        --cluster)           CLUSTER="$2"; shift 2 ;;
        --seed)              SEED="$2"; shift 2 ;;
        --project)           PROJECT="$2"; shift 2 ;;
        --region)            REGION="$2"; shift 2 ;;
        --profile)           PROFILE="$2"; shift 2 ;;
        --apply)             APPLY="true"; shift ;;
        --accept-data-loss)  ACCEPT_LOSS="true"; shift ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

for v in CLOUD BUCKET CLUSTER; do
    [ -n "${!v}" ] || { echo "--${v,,} is required" >&2; exit 2; }
done
case "$CLOUD" in aws|gcp) ;; *) echo "--cloud must be aws or gcp" >&2; exit 2 ;; esac

if [ -z "$SEED" ] && [ "$ACCEPT_LOSS" != "true" ]; then
    echo "--seed is required, or --accept-data-loss if this cluster bootstraps" >&2
    echo "empty. Without a seed there is nothing to restore from, so clearing the" >&2
    echo "archive discards this database's only backup -- say so explicitly." >&2
    exit 2
fi

# "COULD NOT CHECK" IS NOT "EMPTY", and conflating them is dangerous in exactly
# one direction. An expired auth token makes a listing fail; if that is read as
# "no backups" the script either refuses a restore that would have been fine, or
# -- far worse -- clears an archive believing a seed exists. So the CLI's own
# exit status decides, stderr is kept, and a failure is reported as a failure.
# Hit for real while testing this: a stale gcloud token produced "the seed has no
# base backup" for a seed holding three.
#
# Both counters echo either a number, or the literal `ERROR` with the CLI's
# message on stderr.

# SEED predicate: base backups, which is what a restore actually reads.
count_bases() {
    local prefix="$1" out rc
    case "$CLOUD" in
        gcp)
            out=$(gcp_gcloud storage ls "gs://${BUCKET}/${prefix}/base/" ${PROJECT:+--project "$PROJECT"} 2>&1)
            rc=$?
            # `ls` on a missing prefix is a legitimate "zero", not a failure.
            if [ "$rc" -ne 0 ]; then
                if grep -qi "matched no objects\|not found" <<< "$out"; then echo 0; return 0; fi
                echo "ERROR"; echo "$out" >&2; return 0
            fi
            grep -c '/$' <<< "$out" || true
            ;;
        aws)
            local aws_args=(--region "$REGION")
            [ -n "$PROFILE" ] && aws_args+=(--profile "$PROFILE")
            out=$(aws "${aws_args[@]}" s3 ls "s3://${BUCKET}/${prefix}/base/" 2>&1)
            rc=$?
            # `s3 ls` exits 1 on an empty or missing prefix with no output.
            if [ "$rc" -ne 0 ] && [ -n "$out" ]; then
                echo "ERROR"; echo "$out" >&2; return 0
            fi
            grep -c 'PRE' <<< "$out" || true
            ;;
    esac
}

# LIVE predicate: any object at all, because barman's check is about the WAL
# archive. Counting base backups here would call a wals/-only prefix empty.
count_objects() {
    local prefix="$1" out rc
    case "$CLOUD" in
        gcp)
            out=$(gcp_gcloud storage ls "gs://${BUCKET}/${prefix}/**" ${PROJECT:+--project "$PROJECT"} 2>&1)
            rc=$?
            if [ "$rc" -ne 0 ]; then
                if grep -qi "matched no objects\|not found" <<< "$out"; then echo 0; return 0; fi
                echo "ERROR"; echo "$out" >&2; return 0
            fi
            grep -c '^gs://' <<< "$out" || true
            ;;
        aws)
            local aws_args=(--region "$REGION")
            [ -n "$PROFILE" ] && aws_args+=(--profile "$PROFILE")
            out=$(aws "${aws_args[@]}" s3 ls --recursive "s3://${BUCKET}/${prefix}/" 2>&1)
            rc=$?
            if [ "$rc" -ne 0 ] && [ -n "$out" ]; then
                echo "ERROR"; echo "$out" >&2; return 0
            fi
            grep -c . <<< "$out" || true
            ;;
    esac
}

echo "cloud:   ${CLOUD}"
echo "bucket:  ${BUCKET}"
echo "seed:    ${SEED:-<none — cluster bootstraps empty>}"
echo "cluster: ${CLUSTER}"
echo

if [ -n "$SEED" ]; then
    seed_bases=$(count_bases "$SEED")
    if [ "$seed_bases" = "ERROR" ]; then
        echo "[REFUSED] could not list the seed -- the error above is why." >&2
        echo "          This is NOT the same as an empty seed, and nothing was" >&2
        echo "          deleted. A stale credential is the usual cause." >&2
        exit 1
    fi
    seed_bases=${seed_bases:-0}
    if [ "$seed_bases" -lt 1 ]; then
        echo "[REFUSED] the seed '${SEED}' has no base backup under ${SEED}/base/." >&2
        echo "          Clearing the live archive now would leave nothing to restore" >&2
        echo "          from. Take a one-shot Backup and copy the cluster prefix to" >&2
        echo "          ${SEED}/ first -- see docs/guides/restore-a-database." >&2
        exit 1
    fi
    echo "[ok     ] seed holds ${seed_bases} base backup(s)"
else
    echo "[warn   ] no seed: this cluster bootstraps empty, so clearing its archive"
    echo "          discards its only backup. Proceeding on --accept-data-loss."
fi

live_objects=$(count_objects "$CLUSTER")
if [ "$live_objects" = "ERROR" ]; then
    echo "[REFUSED] could not list the live archive -- see the error above." >&2
    exit 1
fi
live_objects=${live_objects:-0}
if [ "$live_objects" -lt 1 ]; then
    echo "[skip   ] live archive ${CLUSTER}/ holds no objects; nothing to clear"
    exit 0
fi

if [ "$APPLY" != "true" ]; then
    echo "[dry-run] would delete the live archive ${CLUSTER}/ (${live_objects} object(s))"
    echo
    echo "This was a DRY RUN. Re-run with --apply."
    exit 0
fi

case "$CLOUD" in
    gcp) gcp_gcloud storage rm --recursive "gs://${BUCKET}/${CLUSTER}/" ${PROJECT:+--project "$PROJECT"} >/dev/null ;;
    aws)
        aws_args=(--region "$REGION")
        [ -n "$PROFILE" ] && aws_args+=(--profile "$PROFILE")
        aws "${aws_args[@]}" s3 rm "s3://${BUCKET}/${CLUSTER}/" --recursive >/dev/null
        ;;
esac
echo "[cleared] ${CLUSTER}/ (${live_objects} object(s)) — the bootstrap can now start"
