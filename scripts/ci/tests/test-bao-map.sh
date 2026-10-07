#!/usr/bin/env bash
#
# The managed-store -> OpenBao map lives in one file (GCP parity GP-5): migrate
# copies through it, and the OIDC sync mirrors through it. Two copies would drift
# and put a client secret where no ExternalSecret reads it.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
fails=0
check() { if [ "$2" = "$3" ]; then echo "  ok   $1"; else echo "  FAIL $1: want '$2' got '$3'"; fails=1; fi; }
# shellcheck source=scripts/lib/bao-map.sh
. "$REPO_ROOT/scripts/lib/bao-map.sh" \
  || { echo "FAIL cannot source scripts/lib/bao-map.sh"; exit 1; }
check "grafana-envvars" "platform/victoria-metrics/grafana-envvars" "$(bao_target_for observability-victoria-metrics-k8s-stack-grafana-envvars)"
check "harbor-oidc" "platform/harbor/oidc" "$(bao_target_for harbor-oidc)"
check "app-wizard llm" "apps/app-wizard/llm" "$(bao_target_for apps-app-wizard-llm)"
bao_target_for openbao-oidc >/dev/null; check "openbao-oidc is unmapped" "1" "$?"
grep -q '^bao_target_for()' "$REPO_ROOT/scripts/provision/secret-store.sh" && { echo "  FAIL secret-store.sh still defines its own copy"; fails=1; }
grep -q 'lib/bao-map.sh' "$REPO_ROOT/scripts/provision/secret-store.sh" || { echo "  FAIL secret-store.sh does not source the map"; fails=1; }
[ "$fails" -eq 0 ] && echo "all checks passed"
exit "$fails"
