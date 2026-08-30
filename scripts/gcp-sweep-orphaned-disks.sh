#!/usr/bin/env bash
#
# Delete Persistent Disks that GKE's CSI driver created and nothing is using.
#
# WHY THIS EXISTS
#
# scripts/k8s-reclaim-csi-volumes.sh tries to reclaim every PV *before* the
# cluster is deleted, which is the only moment the CSI controller can do it. When
# it cannot finish in time it prints a warning and exits 0, ending with:
#
#   "The cloud-side sweep is the backstop; anything still attached to a draining
#    node is caught by the NEXT destroy run."
#
# BOTH HALVES OF THAT SENTENCE WERE FALSE. There was no cloud-side sweep -- no
# job anywhere deleted a disk from GCP -- and "the next destroy run" cannot help
# either: a later run operates on a DIFFERENT cluster, whose PVs do not reference
# these disks, so nothing ever looks at them again. The warning read like a
# handoff to a step that did not exist, which is worse than no warning: it is why
# the leak was noticed twice and fixed neither time.
#
#   2026-08-27 teardown:  3 disks orphaned  (20/10/5 GB)
#   2026-08-28 teardown:  8 disks orphaned  (43 GB total)
#
# This script is that backstop, made real.
#
# WHAT IT MATCHES, AND WHY IT IS SAFE
#
# Two conditions, both required:
#
#   1. NO USERS -- the disk is attached to no instance. A disk in use is never
#      touched, so running this against a live project cannot detach anything.
#   2. Created by the GKE PD CSI driver, proven from the disk's own description:
#        "storage.gke.io/created-by": "pd.csi.storage.gke.io"
#      which the driver writes alongside the PVC name and namespace it was
#      created for. A hand-made disk, a boot disk or another tool's volume has no
#      such marker and is left alone.
#
# Deliberately NOT matched on the `pvc-` name prefix alone: that is a convention,
# not a guarantee, and it would delete a hand-created disk that happened to be
# named that way.
#
# Usage:
#   gcp-sweep-orphaned-disks.sh --project ID [--apply]
#
# Dry-run unless --apply, and it lists exactly what it would delete.

set -o errexit
set -o nounset
set -o pipefail

# gcloud must run as the identity OpenTofu uses, not the CLI account.
# shellcheck source=scripts/lib/gcloud-adc.sh
. "$(dirname "$0")/lib/gcloud-adc.sh"

PROJECT=""
APPLY="false"

while [ $# -gt 0 ]; do
    case "$1" in
        --project) PROJECT="$2"; shift 2 ;;
        --apply)   APPLY="true"; shift ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

[ -n "$PROJECT" ] || { echo "--project is required" >&2; exit 2; }

# `-users:*` is the unattached filter. The description match cannot be expressed
# in a --filter reliably (it is a JSON blob), so it is checked per disk below.
mapfile -t CANDIDATES < <(
    gcp_gcloud compute disks list --project "$PROJECT" \
        --filter="-users:*" \
        --format='value(name,zone,sizeGb)' 2>/dev/null || true
)

if [ "${#CANDIDATES[@]}" -eq 0 ]; then
    echo "No unattached disks in ${PROJECT}."
    exit 0
fi

swept=0 kept=0 failed=0
for row in "${CANDIDATES[@]}"; do
    [ -n "$row" ] || continue
    name=$(awk '{print $1}' <<< "$row")
    zone=$(awk '{print $2}' <<< "$row")
    size=$(awk '{print $3}' <<< "$row")
    # zone comes back as a URL; the basename is what the delete call wants.
    zone="${zone##*/}"

    desc=$(gcp_gcloud compute disks describe "$name" --project "$PROJECT" --zone "$zone" \
             --format='value(description)' 2>/dev/null || true)

    if ! grep -q "pd.csi.storage.gke.io" <<< "$desc"; then
        echo "[keep   ] ${name} (${size}GB, ${zone}) — not CSI-created"
        kept=$((kept + 1))
        continue
    fi

    # The PVC it belonged to, purely so the log says what is being removed.
    pvc=$(python3 -c "
import json,sys
try:
    d=json.loads(sys.argv[1])
    print(d.get('kubernetes.io/created-for/pvc/namespace','?') + '/' + d.get('kubernetes.io/created-for/pvc/name','?'))
except Exception:
    print('?')
" "$desc" 2>/dev/null || echo "?")

    if [ "$APPLY" != "true" ]; then
        echo "[dry-run] would delete ${name} (${size}GB, ${zone}) — was ${pvc}"
        swept=$((swept + 1))
        continue
    fi

    if gcp_gcloud compute disks delete "$name" --project "$PROJECT" --zone "$zone" --quiet >/dev/null 2>&1; then
        echo "[deleted] ${name} (${size}GB, ${zone}) — was ${pvc}"
        swept=$((swept + 1))
    else
        echo "[FAILED ] ${name} (${size}GB, ${zone})" >&2
        failed=$((failed + 1))
    fi
done

echo
echo "swept: ${swept}, kept: ${kept}, failed: ${failed}"

# Never fail the teardown. A disk that cannot be deleted right now is a cost
# problem to chase, not a reason to abort a destroy that has already removed the
# cluster -- and the run's own log names it.
exit 0
