#!/usr/bin/env bash
#
# Pre-destroy seed for every CNPG database on the cluster being torn down —
# the OpenBao pre-destroy-snapshot pattern
# (opentofu/aws/openbao/cluster/workflows.tm.hcl, TM_OPENBAO_SKIP_SNAPSHOT)
# extended to the databases. One shared core behind both clouds' destroy
# lanes:
#
#   aws:  scripts/ops/aws/eks-prepare-destroy.sh — after the Flux suspension
#         and the fail-closed webhook teardown, before the CSI reclaim /
#         NodePool drain past which the operator and barman-plugin pods may
#         be unschedulable.
#   gcp:  opentofu/gcp/gke/init/workflows.tm.hcl, the stage2-seed-databases
#         job — before stage2-reclaim-volumes deletes the PVCs out from
#         under postgres, and before stage2-destroy-addons takes Cilium
#         down.
#
# Every SQLInstance with a spec.backup block is promoted to a destroy-day
# dated seed (<app>-YYYYMMDD), then the stable <app>-pre-destroy alias the
# next bootstrap restores from is refreshed from it.
# cnpg-promote-seed.sh's --rotate-alias touches the alias ONLY after
# verify_seed passed on the fresh dated seed this run produced, so a failed
# promotion leaves the alias holding the previous verified seed — which is
# what makes the failure posture warn-not-block. A same-day re-run hits the
# promote script's dated-collision guard and skips — correct, the alias is
# already refreshed. Skipping the hook entirely is the operator's explicit
# data-loss decision via CNPG_SKIP_PRE_DESTROY_SEED=true.
#
# Discovery is `kubectl get sqlinstance -A | select(.spec.backup)`, not an
# enumerated list, so the next platform database is caught without an edit
# here. The only cloud-specific input is the bucket name, passed in:
# ${region}-ogenki-cnpg-backups on aws, ${project_id}-ogenki-cnpg-backups on
# gcp (GCS bucket names are globally unique, so the region is not enough).
#
# Requires kubectl to already point at the cluster being destroyed.
# Never exits non-zero past argument parsing: a seeding failure must not
# block the destroy — the alias still holds the last verified seed.
set -uo pipefail

CLOUD=""
BUCKET=""
while [ $# -gt 0 ]; do
  case "$1" in
    --cloud)  CLOUD="$2"; shift 2 ;;
    --bucket) BUCKET="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
case "$CLOUD" in
  aws | gcp) ;;
  *) echo "--cloud must be aws or gcp" >&2; exit 2 ;;
esac
[ -n "$BUCKET" ] || { echo "--bucket is required" >&2; exit 2; }

echo "Seeding CNPG databases before destroy..."
if [ "${CNPG_SKIP_PRE_DESTROY_SEED:-false}" = "true" ]; then
  echo "[skip] CNPG_SKIP_PRE_DESTROY_SEED=true — databases will be destroyed without a fresh seed."
  echo "       The next restore falls back to the previous alias/seed and loses everything since."
  exit 0
fi

# Both API endpoints are private, so an unreachable cluster is the likeliest
# failure here — and discovery alone cannot tell it from "no SQLInstance CRD",
# which reads as "nothing to seed". Probe first, and say what is being lost.
if ! kubectl --request-timeout=20s get ns >/dev/null 2>&1; then
  echo "[warn] cluster unreachable — no pre-destroy seed taken."
  echo "       The next restore falls back to the previous alias/seed and loses everything since."
  exit 0
fi

SEED_DATE="$(date +%Y%m%d)"
if kubectl --request-timeout=20s api-resources --api-group=cloud.ogenki.io 2>/dev/null | grep -q sqlinstances; then
  kubectl --request-timeout=20s get sqlinstance -A -o json 2>/dev/null \
    | jq -r '.items[] | select(.spec.backup) | "\(.metadata.namespace) \(.metadata.name)"' \
    | while read -r seed_ns seed_claim; do
      [ -z "${seed_claim}" ] && continue
      seed_app="${seed_claim#xplane-}"
      "$(dirname "$0")/cnpg-promote-seed.sh" --cloud "${CLOUD}" --bucket "${BUCKET}" \
        --cluster "${seed_claim}" --namespace "${seed_ns}" --apply \
        --seed "${seed_app}-${SEED_DATE}" --rotate-alias "${seed_app}-pre-destroy" \
        || echo "[warn] seed for ${seed_claim} failed — destroy continues; the alias still holds the last verified seed"
    done || true
else
  echo "SQLInstance CRD not available, skipping CNPG pre-destroy seed."
fi
exit 0
