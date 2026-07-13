#!/usr/bin/env bash
# Test suite for the SPEC-007 flux-schema tooling.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

fail=0
check() {
  local name="$1" expected="$2" actual="$3"
  if [[ "$actual" == *"$expected"* ]]; then
    echo "  PASS  $name"
  else
    echo "  FAIL  $name"
    echo "        expected to contain: $expected"
    echo "        got: $actual"
    fail=1
  fi
}

echo "== xrd-to-crd =="
out="$(python3 scripts/flux-schema/xrd-to-crd.py \
  infrastructure/base/crossplane/configuration/app-definition.yaml)"

check "emits a CustomResourceDefinition" "kind: CustomResourceDefinition" "$out"
check "preserves the group"              "group: cloud.ogenki.io"          "$out"
check "preserves the kind"               "kind: App"                       "$out"
check "injects spec.crossplane"          "crossplane:"                     "$out"
check "injects compositionRef"           "compositionRef:"                 "$out"

echo "== gen-catalog =="
rm -rf .schemas
./scripts/flux-schema/gen-catalog.sh >/dev/null

for kind in app sqlinstance inferenceservice epi; do
  if [[ -f ".schemas/cloud.ogenki.io/${kind}_v1alpha1.json" ]]; then
    echo "  PASS  catalog has cloud.ogenki.io/${kind}"
  else
    echo "  FAIL  catalog missing cloud.ogenki.io/${kind}_v1alpha1.json"
    fail=1
  fi
done

if compgen -G ".schemas/aigateway.envoyproxy.io/*.json" >/dev/null; then
  echo "  PASS  catalog has aigateway.envoyproxy.io schemas"
else
  echo "  FAIL  catalog missing aigateway.envoyproxy.io schemas"
  fail=1
fi

echo "== preflight guard =="
old_flux="${HOME}/.local/share/mise/installs/flux2/2.8.8/flux"
if [[ -x "${old_flux}" ]]; then
  guard_status=0
  guard_out="$(FLUX_BIN="${old_flux}" ./scripts/flux-schema/gen-catalog.sh 2>&1)" || guard_status=$?

  if [[ "${guard_status}" -ne 0 ]]; then
    echo "  PASS  guard rejects an old (< v2.9) flux binary"
  else
    echo "  FAIL  guard accepted an old flux binary (exit 0)"
    fail=1
  fi
  check "guard names the v2.9 requirement" "2.9" "${guard_out}"
else
  echo "  SKIP  guard-rejects-old-flux (no v2.8.8 binary at ${old_flux} on this machine)"
fi

exit "$fail"
