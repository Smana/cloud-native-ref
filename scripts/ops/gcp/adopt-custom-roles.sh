#!/usr/bin/env bash
#
# Adopt gke/init's three custom IAM roles when they already exist.
#
# WHY: GCP reserves a deleted custom role's ID for 37 days and can undelete it
# for 7 only, so a rebuild within 37 days of a teardown that deleted the roles
# fails on the first create. gke/init's destroy therefore drops them from state
# instead of deleting them, and every deploy adopts them here (GCP parity GP-15).
#
# Usage (from opentofu/gcp/gke/init, after `tofu init`):
#   adopt-custom-roles.sh --project ID --suffix S [--apply]
# Dry-run unless --apply.
set -euo pipefail

# shellcheck source=scripts/lib/gcloud-adc.sh
. "$(dirname "$0")/../../lib/gcloud-adc.sh"

PROJECT="" SUFFIX="" APPLY=false
while [ $# -gt 0 ]; do
  case "$1" in
    --project) PROJECT="$2"; shift 2 ;;
    --suffix)  SUFFIX="$2"; shift 2 ;;
    --apply)   APPLY=true; shift ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
[ -n "$PROJECT" ] || { echo "--project is required" >&2; exit 2; }

ROLES=(
  "google_project_iam_custom_role.crossplane_dns=xplane_dns_editor"
  "google_project_iam_custom_role.crossplane_storage=xplane_storage_admin"
  "google_project_iam_custom_role.crossplane_role_reader=xplane_role_reader"
)

in_state="$(tofu state list 2>/dev/null || true)"
for entry in "${ROLES[@]}"; do
  addr="${entry%%=*}"
  id="${entry#*=}${SUFFIX}"
  name="projects/${PROJECT}/roles/${id}"
  if grep -qxF "$addr" <<<"$in_state"; then
    echo "[ok     ] ${addr} is in state"
    continue
  fi
  if ! deleted="$(gcp_gcloud iam roles describe "$id" --project "$PROJECT" --format='value(deleted)' 2>/dev/null)"; then
    echo "[absent ] ${name}: the apply creates it"
    continue
  fi
  if [ "$deleted" = "True" ]; then
    echo "[deleted] ${name} is soft-deleted: the provider undeletes it within 7 days; after that, bump custom_role_suffix" >&2
    continue
  fi
  if [ "$APPLY" = true ]; then
    tofu import -var-file=variables.tfvars "$addr" "$name"
    echo "[adopted] ${addr} <- ${name}"
  else
    echo "[dry-run] would import ${addr} <- ${name}"
  fi
done
