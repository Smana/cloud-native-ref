#!/usr/bin/env bash
#
# Delete EBS volumes this cluster's CSI driver created and nothing is using,
# AFTER the cluster has been destroyed.
#
# WHY A SECOND SWEEP, WHEN eks-prepare-destroy.sh ALREADY SWEEPS
#
# It does, and this does not replace it. The difference is WHEN.
#
# eks-prepare-destroy.sh runs BEFORE `tofu destroy`, right after it deletes the
# PVCs -- so it only sees volumes that have finished detaching by that moment.
# Its own failure message admits the rest: "may still be detaching -- the next
# run retries". The next run is the next TEARDOWN, which is a rebuild away. A
# volume that was one second late to detach therefore bills from now until the
# cluster is next built and destroyed again, and forever if it never is. That is
# how 62 volumes (~518 GiB) accumulated by 2026-07, with 12 more (~138 GiB) from
# the single 2026-07-21 rebuild -- each teardown leaving a few behind for the
# following one to find.
#
# This sweep runs after `tofu destroy` returns, when every node is terminated
# and so every volume of this cluster is unambiguously detached. There is no
# in-flight state left to race, which is exactly what makes the late moment the
# reliable one. GCP's equivalent (gcp-sweep-orphaned-disks.sh) had to be written
# from scratch because GKE had no sweep at all; here the moment is the fix.
#
# WHAT IT MATCHES, AND WHY IT IS SAFE
#
# The same three conditions as the pre-destroy sweep, deliberately identical:
#
#   1. status=available -- attached to nothing. An in-use volume is invisible to
#      this script, so it cannot detach or delete a running cluster's storage.
#   2. tagged `kubernetes.io/cluster/<name>=owned`, so a second cluster's
#      volumes in the same region are never candidates.
#   3. tagged `kubernetes.io/created-for/pvc/name`, which the EBS CSI driver
#      writes alongside the PVC's namespace. A hand-made or root volume carries
#      no such tag.
#
# Dropping condition 2 would sweep the whole region and could catch another
# live cluster's volume during a reschedule. Keep all three.
#
# Usage:
#   aws-sweep-orphaned-volumes.sh --cluster-name N --region R [--profile P] [--apply]
#
# Dry-run unless --apply, and it lists exactly what it would delete.

set -o errexit
set -o nounset
set -o pipefail

CLUSTER_NAME=""
REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-}}"
PROFILE=""
APPLY="false"

while [ $# -gt 0 ]; do
    case "$1" in
        --cluster-name) CLUSTER_NAME="$2"; shift 2 ;;
        --region)       REGION="$2"; shift 2 ;;
        --profile)      PROFILE="$2"; shift 2 ;;
        --apply)        APPLY="true"; shift ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

[ -n "$CLUSTER_NAME" ] || { echo "--cluster-name is required" >&2; exit 2; }
[ -n "$REGION" ] || { echo "--region is required (or set AWS_REGION)" >&2; exit 2; }

AWS=(aws --region "$REGION")
[ -n "$PROFILE" ] && AWS+=(--profile "$PROFILE")

# All three conditions are filters, so nothing else is even returned.
rows=$("${AWS[@]}" ec2 describe-volumes \
    --filters "Name=status,Values=available" \
              "Name=tag:kubernetes.io/cluster/${CLUSTER_NAME},Values=owned" \
              "Name=tag-key,Values=kubernetes.io/created-for/pvc/name" \
    --query 'Volumes[].[VolumeId,Size,Tags[?Key==`kubernetes.io/created-for/pvc/namespace`]|[0].Value,Tags[?Key==`kubernetes.io/created-for/pvc/name`]|[0].Value]' \
    --output text 2>/dev/null || true)

if [ -z "$rows" ]; then
    echo "No orphaned CSI volumes left by ${CLUSTER_NAME} in ${REGION}."
    exit 0
fi

swept=0 failed=0 gib=0
while read -r vol size ns pvc; do
    [ -n "$vol" ] || continue
    gib=$((gib + size))
    if [ "$APPLY" != "true" ]; then
        echo "[dry-run] would delete ${vol} (${size}GiB) — was ${ns}/${pvc}"
        swept=$((swept + 1))
        continue
    fi
    if "${AWS[@]}" ec2 delete-volume --volume-id "$vol" >/dev/null 2>&1; then
        echo "[deleted] ${vol} (${size}GiB) — was ${ns}/${pvc}"
        swept=$((swept + 1))
    else
        echo "[FAILED ] ${vol} (${size}GiB) — was ${ns}/${pvc}" >&2
        failed=$((failed + 1))
    fi
done <<< "$rows"

echo
echo "swept: ${swept} (${gib} GiB), failed: ${failed}"

# Never fail the teardown: a volume that cannot be deleted right now is a cost to
# chase, not a reason to abort a destroy that has already removed the cluster.
exit 0
