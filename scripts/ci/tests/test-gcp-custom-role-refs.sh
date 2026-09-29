#!/usr/bin/env bash
#
# GCP parity GP-15: every custom role carries the generation suffix, and no
# manifest spells a custom role name -- they read ${gcp_dns_editor_role}, so a
# suffix bump never leaves a claim pointing at a deleted role.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
fails=0
while IFS= read -r line; do
  case "$line" in
    *'${var.custom_role_suffix}"'*) ;;
    *) echo "FAIL iam.tf: $line"; fails=$((fails + 1)) ;;
  esac
done < <(grep -E '^[[:space:]]*role_id[[:space:]]*=' "$ROOT/opentofu/gcp/gke/init/iam.tf")
[ "$(grep -cE '^[[:space:]]*role_id[[:space:]]*=' "$ROOT/opentofu/gcp/gke/init/iam.tf")" -eq 3 ] \
  || { echo "FAIL expected 3 custom roles in iam.tf"; fails=$((fails + 1)); }
hits="$(grep -rnE 'roles/xplane_' --include=*.yaml "$ROOT"/{clusters,infrastructure,security,observability,tooling,apps} 2>/dev/null)"
[ -z "$hits" ] || { echo "FAIL a manifest spells a custom role:"; echo "$hits"; fails=$((fails + 1)); }
grep -q 'gcp_dns_editor_role' "$ROOT/opentofu/gcp/gke/configure/kubernetes.tf" \
  || { echo "FAIL gke-gcp-0-vars has no gcp_dns_editor_role"; fails=$((fails + 1)); }
[ "$fails" -eq 0 ] || exit 1
echo PASS
