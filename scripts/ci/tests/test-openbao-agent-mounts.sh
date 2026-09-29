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

AGENTS_PATHS='path "agents/data/*" {
path "agents/metadata/*" {
path "auth/token/lookup-self" {
path "auth/token/renew-self" {'

for cloud in aws gcp; do
  P="$ROOT/opentofu/$cloud/openbao/management"
  grep -Eq '^[[:space:]]*path[[:space:]]*=[[:space:]]*"agents"' "$P/mounts.tf" || fail "$cloud: no vault_mount with path agents"
  if [ ! -f "$P/policies/agents-secrets.hcl" ]; then
    fail "$cloud: policies/agents-secrets.hcl is missing"
    continue
  fi
  [ "$(grep -E '^[[:space:]]*path "' "$P/policies/agents-secrets.hcl" | LC_ALL=C sort)" = "$AGENTS_PATHS" ] \
    || fail "$cloud: agents-secrets grants a path other than agents/data, agents/metadata and the token self-operations"
done
# validate-openbao-policies.sh compares only the five module policies; this pair is outside it.
cmp -s "$ROOT/opentofu/aws/openbao/management/policies/agents-secrets.hcl" "$ROOT/opentofu/gcp/openbao/management/policies/agents-secrets.hcl" \
  || fail "the aws and gcp agents-secrets.hcl have diverged"

# Every other policy, on both clouds and in the module: no grant on the agents
# mount, nor a `+` or `*` first segment that would reach it without naming it.
scanned=0
for f in "$ROOT"/opentofu/{aws,gcp}/openbao/management/policies/*.hcl* "$ROOT"/opentofu/shared/modules/openbao-store-of-record/policies/*.hcl*; do
  [ -f "$f" ] || continue
  case "$(basename "$f")" in agents-secrets.hcl | secrets-admin.hcl) continue ;; esac
  scanned=$((scanned + 1))
  grep -Eq '^[[:space:]]*path "(agents|\+|\*)' "$f" && fail "${f#"$ROOT"/} can reach the agents mount"
done
[ "$scanned" -gt 0 ] || fail "no policy file scanned -- the boundary check checked nothing"
for f in opentofu/aws/openbao/management/policies/secrets-admin.hcl opentofu/shared/modules/openbao-store-of-record/policies/secrets-admin.hcl; do
  grep -q '^path "agents/data/\*"' "$ROOT/$f" || fail "$f cannot write the agents mount (the owner's bao kv put)"
done
grep -q 'agents-secrets = {' "$ROOT/opentofu/gcp/gke/configure/openbao.tf" || fail "gcp: no agents-secrets role on jwt/gcp-0"
grep -q '^      path: "agents"$' "$ROOT/security/base/agent-secrets/secretstore.yaml" || fail "the agents-secrets SecretStore is not on the agents mount"
grep -rq 'key: agents/' "$ROOT/security/base/octo-sts" "$ROOT/infrastructure/base/agent-router" && fail "an ExternalSecret still carries the old agents/ prefix"

[ "$fails" -eq 0 ] || exit 1
echo PASS
