#!/usr/bin/env bash
#
# #2078 on every copy of the OpenBao OIDC login (GCP parity GP-2): tofu must never
# rewrite the rotating client fields. A management apply runs before ZITADEL is up
# on every rebuild, and rewriting them replays OIDC discovery against an IdP that
# is not there yet; zitadel-oidc-clients.sh's reconcile_openbao_oidc rotates them.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
fails=0
for f in opentofu/aws/openbao/management/oidc.tf opentofu/shared/modules/openbao-store-of-record/oidc.tf; do
  [ -f "$ROOT/$f" ] || { echo "FAIL $f is missing"; fails=$((fails + 1)); continue; }
  grep -Eq 'ignore_changes[[:space:]]*=[[:space:]]*\[oidc_client_id, oidc_client_secret\]' "$ROOT/$f" \
    || { echo "FAIL $f: the backend does not ignore oidc_client_id/oidc_client_secret"; fails=$((fails + 1)); }
  grep -Eq 'ignore_changes[[:space:]]*=[[:space:]]*\[bound_audiences\]' "$ROOT/$f" \
    || { echo "FAIL $f: the default role does not ignore bound_audiences"; fails=$((fails + 1)); }
done
[ "$fails" -eq 0 ] || exit 1
echo PASS
