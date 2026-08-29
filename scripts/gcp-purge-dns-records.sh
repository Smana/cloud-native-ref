#!/usr/bin/env bash
#
# Empty a Cloud DNS managed zone so the zone itself can be destroyed.
#
# WHY THIS EXISTS
#
# Cloud DNS refuses to delete a managed zone that still holds record sets:
#
#   Error 400: The container is not empty., containerNotEmpty
#
# external-dns writes records into the private zone for every HTTPRoute on the
# cluster, and those records outlive the cluster -- nothing deletes them when
# the GKE cluster goes away, because the controller that owned them is gone
# with it. So `tofu destroy` of the network stack fails at the very end, after
# it has already torn down the VPC's other contents, and the teardown has to be
# finished by hand.
#
# That is exactly what happened on 2026-08-27: twelve records (six A, six `a-`
# TXT ownership entries) had to be deleted one at a time with gcloud before
# gcp/network would destroy.
#
# NS and SOA at the zone apex are deliberately left alone. Cloud DNS creates
# them with the zone, refuses to delete them independently, and removes them
# when the zone goes -- so they never block the destroy.
#
# Usage:
#   gcp-purge-dns-records.sh <zone-name> <project-id>
#
# Safe to run when the zone is already gone or already empty: it reports and
# exits 0 either way, so a destroy that is re-run does not fail here.

set -o errexit
set -o nounset
set -o pipefail

# gcloud must run as the identity OpenTofu uses, not the CLI account.
# shellcheck source=scripts/lib/gcloud-adc.sh
. "$(dirname "$0")/lib/gcloud-adc.sh"

ZONE="${1:-}"
PROJECT="${2:-}"

if [ -z "$ZONE" ] || [ -z "$PROJECT" ]; then
    echo "usage: $(basename "$0") <zone-name> <project-id>" >&2
    exit 2
fi

if ! gcp_gcloud dns managed-zones describe "$ZONE" --project "$PROJECT" >/dev/null 2>&1; then
    echo "Cloud DNS zone '${ZONE}' does not exist — nothing to purge."
    exit 0
fi

# name<TAB>type, apex NS/SOA excluded.
records=$(gcp_gcloud dns record-sets list \
    --zone "$ZONE" --project "$PROJECT" \
    --format='value[separator="	"](name,type)' 2>/dev/null \
    | awk -F'\t' '$2 != "NS" && $2 != "SOA"')

if [ -z "$records" ]; then
    echo "Cloud DNS zone '${ZONE}' holds no deletable records."
    exit 0
fi

count=$(printf '%s\n' "$records" | wc -l)
echo "Purging ${count} record set(s) from '${ZONE}' so the zone can be destroyed:"

failed=0
while IFS=$'\t' read -r name type; do
    [ -z "$name" ] && continue
    if gcp_gcloud dns record-sets delete "$name" --type "$type" \
         --zone "$ZONE" --project "$PROJECT" >/dev/null 2>&1; then
        echo "  deleted  ${type} ${name}"
    else
        echo "  FAILED   ${type} ${name}"
        failed=$((failed + 1))
    fi
done <<< "$records"

if [ "$failed" -gt 0 ]; then
    echo
    echo "WARNING: ${failed} record set(s) could not be deleted. The zone destroy will"
    echo "fail with containerNotEmpty until they are removed."
    exit 1
fi

echo "Zone '${ZONE}' is empty apart from its apex NS/SOA, which go with the zone."
