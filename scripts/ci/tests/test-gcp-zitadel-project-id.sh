#!/usr/bin/env bash
#
# GCP parity GP-4: a fresh directory has a new project id every build. The sync
# publishes it, and gke/configure reads it, so the standalone configure apply
# that runs after stage 3 cannot put the committed id back.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
C="$ROOT/opentofu/gcp/gke/configure"
fails=0
f() { echo "FAIL $*"; fails=$((fails + 1)); }
grep -Eq '^[[:space:]]*zitadel_project_id[[:space:]]*=[[:space:]]*local\.zitadel_project_id[[:space:]]*$' "$C/kubernetes.tf" || f "the ConfigMap does not publish local.zitadel_project_id"
grep -q 'data "google_secret_manager_secrets" "zitadel_project"' "$C/data.tf" || f "configure does not list zitadel-project-id before reading it"
grep -q 'data "google_secret_manager_secret_version" "zitadel_project"' "$C/data.tf" || f "configure does not read zitadel-project-id"
grep -Eq 'zitadel_project_id[[:space:]]*=.*var\.zitadel_project_id' "$C/locals.tf" || f "no fallback to the committed id"
grep -q 'store_write zitadel-project-id' "$ROOT/scripts/provision/zitadel-oidc-clients.sh" || f "the sync never publishes zitadel-project-id"
[ "$fails" -eq 0 ] || exit 1
echo PASS
