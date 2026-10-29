#!/usr/bin/env bash
#
# Report the PersistentVolumeClaims whose phase is not Bound, oldest first.
# READ-ONLY.
#
# A Pending claim means the CSI driver has not matched a volume yet; a Lost
# one means the volume it was bound to is gone. Neither shows up anywhere a
# workload can see — the pod that mounts the claim just stays unschedulable,
# while everything around it keeps reporting green.
#
# One line per claim, as
#   <namespace>/<name> <phase> <storageClass> <requested size> <age>
# oldest first, so the claims that have waited longest lead the report. The
# age is `kubectl`'s own shorthand (10m, 3d, 400d).
#
# It is a report, not a gate: exit 0 whatever the count, and exit 0 with a
# warning on stderr when the cluster is unreachable, so it never breaks
# whatever runs it.
#
# Usage:
#   scripts/ops/k8s/pvc-unbound.sh

set -uo pipefail

raw="$(mktemp)"
trap 'rm -f "$raw"' EXIT

if ! kubectl get pvc --all-namespaces --request-timeout=20s \
        -o json >"$raw" 2>/dev/null; then
    echo "could not list PersistentVolumeClaims (cluster unreachable)" >&2
    exit 0
fi

# Claims with no storageClassName are bound by the default class, which the
# API server writes back as spec.storageClassName: an absent one means the
# claim predates that or was created against a cluster with none — "?" keeps
# the column aligned either way.
jq -r '
    .items[]
    | select(.status.phase != "Bound")
    | [
        (.metadata.namespace // "?") + "/" + (.metadata.name // "?"),
        (.status.phase // "?"),
        (.spec.storageClassName // "?"),
        (.spec.resources.requests.storage // "?"),
        ((now - (.metadata.creationTimestamp | fromdateiso8601)) | round)
    ]
    | @tsv
' "$raw" | sort -t"$(printf '\t')" -k5,5rn | while IFS=$'\t' read -r id phase class size seconds; do  # oldest first
    age="$(awk -v s="$seconds" 'BEGIN {
        if (s < 60)         printf "%ds", s
        else if (s < 3600)  printf "%dm", int(s/60)
        else if (s < 86400) printf "%dh", int(s/3600)
        else                printf "%dd", int(s/86400)
    }')"
    printf '%s %s %s %s %s\n' "$id" "$phase" "$class" "$size" "$age"
done

exit 0
