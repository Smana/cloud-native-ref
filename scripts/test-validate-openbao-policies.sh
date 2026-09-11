#!/usr/bin/env bash
#
# Fixture-driven tests for validate-openbao-policies.sh.
#
# The state it exists to catch -- a JWT role naming a policy its OpenBao never
# defines -- shipped silently when Stage 2 landed (gcp-0's external-secrets
# role). Reproducing that live costs a GCP deploy, so it is tested against
# synthetic trees instead.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VALIDATOR="${SCRIPT_DIR}/validate-openbao-policies.sh"
failures=0

# role_policies <root> <cloud> <quoted,list> -- a configure stack naming policies
role_policies() {
  mkdir -p "$1/opentofu/$2/k8s/configure"
  cat >"$1/opentofu/$2/k8s/configure/openbao.tf" <<EOF
locals {
  openbao_roles = {
    external-secrets = {
      policies = [$3]
    }
  }
}
EOF
}

# define_policy <dir> <name> -- a vault_policy with a literal name
define_policy() {
  mkdir -p "$1"
  cat >>"$1/policies.tf" <<EOF
resource "vault_policy" "p_${2//-/_}" {
  name   = "$2"
  policy = "{}"
}
EOF
}

# expect <label> <exit-code> <root> [substring]
expect() {
  local label="$1" want="$2" root="$3" needle="${4:-}" out rc=0
  out="$("$VALIDATOR" "$root" 2>&1)" || rc=$?
  if [ "$rc" != "$want" ]; then
    echo "FAIL ${label}: exit ${rc}, expected ${want}"; echo "$out" | sed 's/^/       /'
    failures=$((failures + 1)); return
  fi
  if [ -n "$needle" ] && ! grep -qF -- "$needle" <<<"$out"; then
    echo "FAIL ${label}: output lacks: ${needle}"; echo "$out" | sed 's/^/       /'
    failures=$((failures + 1)); return
  fi
  echo "ok   ${label}"
}

t=$(mktemp -d); trap 'rm -rf "$t"' EXIT

r="$t/defined"; role_policies "$r" aws '"default", "external-secrets"'
define_policy "$r/opentofu/aws/openbao/management" external-secrets
expect "a defined policy passes" 0 "$r"

r="$t/missing"; role_policies "$r" gcp '"default", "external-secrets"'
define_policy "$r/opentofu/gcp/openbao/management" cert-manager
expect "the Stage 2 gap fails, naming cloud and policy" 1 "$r" 'gcp: a JWT role names policy "external-secrets"'

r="$t/module"; role_policies "$r" gcp '"external-secrets"'
mkdir -p "$r/opentofu/gcp/openbao/management"
cat >"$r/opentofu/gcp/openbao/management/store.tf" <<'EOF'
module "store" {
  source = "../../../shared/modules/store"
}
EOF
define_policy "$r/opentofu/shared/modules/store" external-secrets
expect "a policy defined through a called module passes" 0 "$r"

r="$t/default"; role_policies "$r" aws '"default"'
mkdir -p "$r/opentofu/aws/openbao/management"
expect "the built-in default policy is never required" 0 "$r"

r="$t/templated"; role_policies "$r" aws '"app-x"'
mkdir -p "$r/opentofu/aws/openbao/management"
cat >"$r/opentofu/aws/openbao/management/apps.tf" <<'EOF'
resource "vault_policy" "app" {
  name   = "app-${each.value}"
  policy = "{}"
}
EOF
expect "a templated name does not count as defining a literal one" 1 "$r" 'policy "app-x"'

r="$t/nomgmt"; role_policies "$r" gcp '"external-secrets"'
expect "a cloud with roles but no management stack fails" 1 "$r" "no opentofu/gcp/openbao/management"

r="$t/empty"; mkdir -p "$r/opentofu"
expect "a tree with no configure stack at all fails" 1 "$r" "no opentofu/<cloud>/*/configure/openbao.tf"

expect "the repository itself passes" 0 "$(cd "${SCRIPT_DIR}/.." && pwd)"

if [ "$failures" -ne 0 ]; then echo "==> ${failures} failure(s)"; exit 1; fi
echo "==> all checks passed"
