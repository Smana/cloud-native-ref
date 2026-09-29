#!/usr/bin/env bash
#
# SP2 ruling P38 (external review M1), on both clouds (GCP parity GP-8): the
# agents' secrets live on a mount only agent-system's own store reads.
# `external-secrets` backs a ClusterSecretStore any namespace can use (T14), so it
# must never name it. The real tree.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
fails=0
fail() { printf 'FAIL  %s\n' "$*" >&2; fails=$((fails + 1)); }

for cloud in aws gcp; do
  P="$ROOT/opentofu/$cloud/openbao/management"
  grep -Eq '^[[:space:]]*path[[:space:]]*=[[:space:]]*"agents"' "$P/mounts.tf" || fail "$cloud: no vault_mount with path agents"
  grep -Eq '^path "platform/' "$P/policies/agents-secrets.hcl" && fail "$cloud: agents-secrets still reads platform/"
  [ "$(grep -c '^path "agents/' "$P/policies/agents-secrets.hcl")" -eq 2 ] || fail "$cloud: agents-secrets reads agents/data and agents/metadata, nothing else"
done
# validate-openbao-policies.sh compares only the five module policies; this pair is outside it.
cmp -s "$ROOT/opentofu/aws/openbao/management/policies/agents-secrets.hcl" "$ROOT/opentofu/gcp/openbao/management/policies/agents-secrets.hcl" \
  || fail "the aws and gcp agents-secrets.hcl have diverged"
for f in opentofu/aws/openbao/management/policies/external-secrets.hcl opentofu/shared/modules/openbao-store-of-record/policies/external-secrets.hcl; do
  grep -Eq '^path "agents/' "$ROOT/$f" && fail "$f names the agents mount"
done
for f in opentofu/aws/openbao/management/policies/secrets-admin.hcl opentofu/shared/modules/openbao-store-of-record/policies/secrets-admin.hcl; do
  grep -q '^path "agents/data/\*"' "$ROOT/$f" || fail "$f cannot write the agents mount (the owner's bao kv put)"
done
grep -q 'agents-secrets = {' "$ROOT/opentofu/gcp/gke/configure/openbao.tf" || fail "gcp: no agents-secrets role on jwt/gcp-0"
grep -q '^      path: "agents"$' "$ROOT/security/base/agent-secrets/secretstore.yaml" || fail "the agents-secrets SecretStore is not on the agents mount"
grep -rq 'key: agents/' "$ROOT/security/base/octo-sts" "$ROOT/infrastructure/base/agent-router" && fail "an ExternalSecret still carries the old agents/ prefix"

[ "$fails" -eq 0 ] || exit 1
echo PASS
