#!/usr/bin/env bash
#
# Delete what a deleted GKE cluster leaves in the platform VPC: its
# LoadBalancers' forwarding rules and target pools, and the k8s-* firewall
# rules. No tofu state holds them, forwarding rules bill hourly, and the
# firewall rules block the VPC delete (memory gke_lb_orphans_block_vpc_delete;
# GCP parity GP-22). Dry-run unless --apply.
#
# Usage: sweep-lb-orphans.sh --project P --network N --cluster C [--apply]
set -euo pipefail

# shellcheck source=scripts/lib/gcloud-adc.sh
. "$(dirname "$0")/../../lib/gcloud-adc.sh"

PROJECT="" NETWORK="" CLUSTER="" APPLY=false
while [ $# -gt 0 ]; do
  case "$1" in
    --project) PROJECT="$2"; shift 2 ;;
    --network) NETWORK="$2"; shift 2 ;;
    --cluster) CLUSTER="$2"; shift 2 ;;
    --apply)   APPLY=true; shift ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
{ [ -n "$PROJECT" ] && [ -n "$NETWORK" ] && [ -n "$CLUSTER" ]; } \
  || { echo "--project, --network and --cluster are required" >&2; exit 2; }

# A live cluster still owns these: its service controller would recreate them,
# and deleting a live LoadBalancer's rule is an outage, not a sweep.
if ! clusters="$(gcp_gcloud container clusters list --project "$PROJECT" \
                   --filter="name=${CLUSTER}" --format='value(name)')"; then
  echo "cannot list clusters in ${PROJECT}: refusing to sweep blind" >&2; exit 3
fi
if [ -n "$clusters" ]; then
  echo "cluster ${CLUSTER} still exists: nothing is swept while it does" >&2; exit 3
fi

# GKE's service controller writes {"kubernetes.io/service-name": ...} into the
# description of every forwarding rule and target pool it creates; that, not a
# name pattern, is what makes an object GKE's.
rules="$(gcp_gcloud compute forwarding-rules list --project "$PROJECT" \
  --filter='description~kubernetes.io/service-name' --format='value(name,region.basename())')"
pools="$(gcp_gcloud compute target-pools list --project "$PROJECT" \
  --filter='description~kubernetes.io/service-name' --format='value(name,region.basename())')"
firewalls="$(gcp_gcloud compute firewall-rules list --project "$PROJECT" \
  --filter="name~^k8s- AND network~/${NETWORK}\$" --format='value(name)')"

failed=0
act() { # $1 = what, then the delete command
  local what="$1"; shift
  if [ "$APPLY" != true ]; then echo "[dry-run] would delete ${what}"; return 0; fi
  if "$@" --quiet >/dev/null; then echo "[deleted] ${what}"; else echo "[FAILED ] ${what}" >&2; failed=1; fi
}
# Rules before pools (a rule targets a pool), firewalls last.
while read -r name region; do
  [ -n "$name" ] || continue
  scope=(--global); [ -n "$region" ] && scope=(--region "$region")
  act "forwarding rule ${name}" gcp_gcloud compute forwarding-rules delete "$name" "${scope[@]}" --project "$PROJECT"
done <<<"$rules"
while read -r name region; do
  [ -n "$name" ] || continue
  act "target pool ${name}" gcp_gcloud compute target-pools delete "$name" --region "$region" --project "$PROJECT"
done <<<"$pools"
while read -r name; do
  [ -n "$name" ] || continue
  act "firewall rule ${name}" gcp_gcloud compute firewall-rules delete "$name" --project "$PROJECT"
done <<<"$firewalls"
exit "$failed"
