#!/usr/bin/env bash
#
# GCP parity GP-15: every custom role carries the generation suffix, and no
# manifest spells a custom role name -- they read ${gcp_dns_editor_role} or
# ${gcp_vertex_predict_role}, so a suffix bump never leaves a claim pointing at
# a deleted role.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
fails=0
while IFS= read -r line; do
  case "$line" in
    *'${var.custom_role_suffix}"'*) ;;
    *) echo "FAIL iam.tf: $line"; fails=$((fails + 1)) ;;
  esac
done < <(grep -E '^[[:space:]]*role_id[[:space:]]*=' "$ROOT/opentofu/gcp/gke/init/iam.tf")
[ "$(grep -cE '^[[:space:]]*role_id[[:space:]]*=' "$ROOT/opentofu/gcp/gke/init/iam.tf")" -eq 4 ] \
  || { echo "FAIL expected 4 custom roles in iam.tf"; fails=$((fails + 1)); }
hits="$(grep -rnE 'roles/xplane_' --include=*.yaml "$ROOT"/{clusters,infrastructure,security,observability,tooling,apps} 2>/dev/null)"
[ -z "$hits" ] || { echo "FAIL a manifest spells a custom role:"; echo "$hits"; fails=$((fails + 1)); }
for v in gcp_dns_editor_role gcp_vertex_predict_role; do
  grep -q "$v" "$ROOT/opentofu/gcp/gke/configure/kubernetes.tf" \
    || { echo "FAIL gke-gcp-0-vars has no $v"; fails=$((fails + 1)); }
  grep -q "\"$v\"" "$ROOT/scripts/ci/flux-schema/render-bundle.py" \
    || { echo "FAIL render-bundle.py's fixture has no $v"; fails=$((fails + 1)); }
done
# The vertex role is prediction only, and grantable (Gemini design G3).
grep -q '"aiplatform.endpoints.predict",' "$ROOT/opentofu/gcp/gke/init/iam.tf" \
  || { echo "FAIL iam.tf has no aiplatform.endpoints.predict"; fails=$((fails + 1)); }
grep -q 'google_project_iam_custom_role.vertex_predict.name,' "$ROOT/opentofu/gcp/gke/init/iam.tf" \
  || { echo "FAIL the vertex role is not in crossplane_grantable_roles"; fails=$((fails + 1)); }
[ "$fails" -eq 0 ] || exit 1
echo PASS
