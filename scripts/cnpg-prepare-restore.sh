#!/usr/bin/env bash
#
# Clear a CloudNativePG cluster's live WAL archive, so a restore can bootstrap.
#
# WHY THIS STEP EXISTS AT ALL
#
# CloudNativePG refuses to start a restored cluster whose DESTINATION archive is
# non-empty -- a restore opens a new timeline that would collide with the WALs
# already there:
#
#   barman-cloud-check-wal-archive: WAL archive check failed for server
#   <cluster>: Expected empty archive
#
# And the backup buckets here outlive their clusters ON PURPOSE, so the
# destination is never empty on a rebuild. Clearing it is therefore a normal part
# of restoring, not an incident -- it is what an operator already does by hand
# before an aws-0 rebuild.
#
# This script is that step, with the check that makes it safe to run.
#
# THE CHECK, WHICH IS THE WHOLE POINT
#
# It refuses unless the dated seed exists AND contains at least one base backup.
# Clearing the live prefix while the seed is absent or half-copied destroys the
# only copy of the database with nothing to restore from -- the one way this
# operation can go badly, and the reason it should not be a bare `rm -r` typed
# from memory.
#
# It never touches the seed, only the live cluster prefix.
#
# Usage:
#   cnpg-prepare-restore.sh --cloud gcp --bucket B --cluster C --seed zitadel-20260828 [--project ID] [--apply]
#   cnpg-prepare-restore.sh --cloud aws --bucket B --cluster C --seed zitadel-20260719 [--region R] [--profile P] [--apply]
#
# Dry-run unless --apply.

set -o errexit
set -o nounset
set -o pipefail

CLOUD="" BUCKET="" CLUSTER="" SEED="" PROJECT="" PROFILE=""
REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-}}"
APPLY="false"

while [ $# -gt 0 ]; do
    case "$1" in
        --cloud)   CLOUD="$2"; shift 2 ;;
        --bucket)  BUCKET="$2"; shift 2 ;;
        --cluster) CLUSTER="$2"; shift 2 ;;
        --seed)    SEED="$2"; shift 2 ;;
        --project) PROJECT="$2"; shift 2 ;;
        --region)  REGION="$2"; shift 2 ;;
        --profile) PROFILE="$2"; shift 2 ;;
        --apply)   APPLY="true"; shift ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

for v in CLOUD BUCKET CLUSTER SEED; do
    [ -n "${!v}" ] || { echo "--${v,,} is required" >&2; exit 2; }
done
case "$CLOUD" in aws|gcp) ;; *) echo "--cloud must be aws or gcp" >&2; exit 2 ;; esac

# Count base backups under a prefix. The base/ directory is what a restore
# actually reads, so an empty one means the seed is unusable even if WALs happen
# to be present.
#
# "COULD NOT CHECK" IS NOT "EMPTY", and conflating them is dangerous in exactly
# one direction. An expired auth token makes the listing fail; if that is read as
# "no backups" the script either refuses a restore that would have been fine, or
# -- far worse in a variant that trusted the live count -- clears an archive
# believing a seed exists. So the CLI's own exit status decides, stderr is kept,
# and a failure is reported as a failure. Hit for real while testing this: a
# stale gcloud token produced "the seed has no base backup" for a seed holding
# three.
#
# Echoes either a count, or the literal string `ERROR` followed by the CLI's
# message on stderr.
count_bases() {
    local prefix="$1" out rc
    case "$CLOUD" in
        gcp)
            out=$(gcloud storage ls "gs://${BUCKET}/${prefix}/base/" ${PROJECT:+--project "$PROJECT"} 2>&1)
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

echo "cloud:   ${CLOUD}"
echo "bucket:  ${BUCKET}"
echo "seed:    ${SEED}"
echo "cluster: ${CLUSTER}"
echo

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

live_bases=$(count_bases "$CLUSTER")
if [ "$live_bases" = "ERROR" ]; then
    echo "[REFUSED] could not list the live archive -- see the error above." >&2
    exit 1
fi
live_bases=${live_bases:-0}
if [ "$live_bases" -lt 1 ]; then
    echo "[skip   ] live archive ${CLUSTER}/ is already empty; nothing to clear"
    exit 0
fi

if [ "$APPLY" != "true" ]; then
    echo "[dry-run] would delete the live archive ${CLUSTER}/ (${live_bases} base backup(s) + WALs)"
    echo
    echo "This was a DRY RUN. Re-run with --apply."
    exit 0
fi

case "$CLOUD" in
    gcp) gcloud storage rm --recursive "gs://${BUCKET}/${CLUSTER}/" ${PROJECT:+--project "$PROJECT"} >/dev/null ;;
    aws)
        aws_args=(--region "$REGION")
        [ -n "$PROFILE" ] && aws_args+=(--profile "$PROFILE")
        aws "${aws_args[@]}" s3 rm "s3://${BUCKET}/${CLUSTER}/" --recursive >/dev/null
        ;;
esac
echo "[cleared] ${CLUSTER}/ — the restore can now bootstrap from ${SEED}"
