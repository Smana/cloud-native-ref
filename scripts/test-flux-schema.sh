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

exit "$fail"
