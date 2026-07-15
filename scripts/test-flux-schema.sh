#!/usr/bin/env bash
# Test suite for the SPEC-007 flux-schema tooling.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# Resolves FLUX_BIN / HELM_BIN / KUSTOMIZE_BIN and hard-fails on a too-old
# flux client, instead of letting a stale binary earlier on PATH silently
# misbehave. Exported so render-bundle.py (invoked below) picks them up.
# shellcheck source=./flux-schema/preflight.sh
source "${REPO_ROOT}/scripts/flux-schema/preflight.sh"

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

echo "== preflight guard (stubbed old flux — deterministic, runs in CI too) =="
# A real pre-2.9 flux binary may not exist on every machine (CI included);
# stub one instead so this assertion actually RUNS everywhere rather than
# silently SKIPping wherever it can't find one (SPEC-007 review M5).
stub_old_flux="$(mktemp)"
cat >"${stub_old_flux}" <<'EOF'
#!/usr/bin/env bash
# Minimal stand-in for a pre-2.9 flux client: understands `version --client`
# and nothing else (the real v2.8.8 has no `flux plugin` subcommand either).
if [[ "${1:-}" == "version" ]]; then
  echo "flux: v2.8.8"
  exit 0
fi
echo "stub-flux: unsupported command: $*" >&2
exit 1
EOF
chmod +x "${stub_old_flux}"

guard_status=0
guard_out="$(FLUX_BIN="${stub_old_flux}" ./scripts/flux-schema/gen-catalog.sh 2>&1)" || guard_status=$?
rm -f "${stub_old_flux}"

if [[ "${guard_status}" -ne 0 ]]; then
  echo "  PASS  guard rejects an old (< v2.9) flux binary"
else
  echo "  FAIL  guard accepted an old flux binary (exit 0)"
  fail=1
fi
check "guard names the v2.9 requirement" "2.9" "${guard_out}"

echo "== catalog integrity: partial/empty builds never reach disk (I1/I2) =="
good_catalog_sum="$(find .schemas -type f -name '*.json' | sort | xargs sha256sum | sha256sum)"

# I2: an unresolvable toolchain override must fail before the on-disk
# catalog is touched at all — not leave it emptied or half-built.
broken_status=0
broken_out="$(HELM_BIN=/nonexistent/helm ./scripts/flux-schema/gen-catalog.sh 2>&1)" || broken_status=$?

if [[ "${broken_status}" -ne 0 ]]; then
  echo "  PASS  gen-catalog.sh fails when HELM_BIN does not exist"
else
  echo "  FAIL  gen-catalog.sh exited 0 with a nonexistent HELM_BIN"
  fail=1
fi
check "failure message is actionable" "not an executable file" "${broken_out}"

after_broken_sum="$(find .schemas -type f -name '*.json' 2>/dev/null | sort | xargs sha256sum 2>/dev/null | sha256sum)"
if [[ "${after_broken_sum}" == "${good_catalog_sum}" ]]; then
  echo "  PASS  .schemas/ left in its previous good state after the failed run"
else
  echo "  FAIL  .schemas/ was mutated by a run that ultimately failed"
  fail=1
fi

# I1: `flux schema extract crd` exits 0 and writes 0 files for a
# CRD-less input (e.g. a Renovate bump to a chart version that moved its
# CRDs under crds/ without --include-crds, or an upstream packaging
# regression). Stub helm to simulate exactly that and assert the whole
# build fails loudly instead of silently dropping the aigateway group.
stub_empty_helm="$(mktemp)"
cat >"${stub_empty_helm}" <<'EOF'
#!/usr/bin/env bash
# Simulates `helm template` rendering a chart with zero CRDs in its output.
cat <<'YAML'
apiVersion: v1
kind: ConfigMap
metadata:
  name: not-a-crd
data:
  foo: bar
YAML
EOF
chmod +x "${stub_empty_helm}"

empty_status=0
empty_out="$(HELM_BIN="${stub_empty_helm}" ./scripts/flux-schema/gen-catalog.sh 2>&1)" || empty_status=$?
rm -f "${stub_empty_helm}"

if [[ "${empty_status}" -ne 0 ]]; then
  echo "  PASS  gen-catalog.sh fails when the AI Gateway render yields zero CRDs"
else
  echo "  FAIL  gen-catalog.sh exited 0 despite extracting zero aigateway.envoyproxy.io schemas"
  fail=1
fi
check "failure message names the missing group" "aigateway.envoyproxy.io" "${empty_out}"

after_empty_sum="$(find .schemas -type f -name '*.json' 2>/dev/null | sort | xargs sha256sum 2>/dev/null | sha256sum)"
if [[ "${after_empty_sum}" == "${good_catalog_sum}" ]]; then
  echo "  PASS  .schemas/ left in its previous good state after the zero-CRD run"
else
  echo "  FAIL  .schemas/ was mutated by the zero-CRD run"
  fail=1
fi

echo "== render-bundle =="
rm -rf .bundle
render_out="$(python3 scripts/flux-schema/render-bundle.py .bundle)"
echo "${render_out}"

check "renders with no failures" "failed=0" "${render_out}"

# grep -h (no per-file counts) + wc -l: total match count without depending
# on `bc`, which isn't guaranteed to be installed.
workloads="$(grep -rh '^kind: \(Deployment\|StatefulSet\|DaemonSet\|Job\)$' .bundle/*.yaml 2>/dev/null | wc -l)"
if [[ "${workloads:-0}" -ge 30 ]]; then
  echo "  PASS  bundle exposes ${workloads} workloads to Polaris (SC-005: >= 30)"
else
  echo "  FAIL  bundle exposes only ${workloads:-0} workloads (SC-005 requires >= 30)"
  fail=1
fi

echo "== chartRef HelmReleases rendered (no chartRef blind spot) =="
# chartRef (OCIRepository) HelmReleases must be helm-templated, not left as a
# bare CR. Karpenter, Envoy Gateway, Envoy AI Gateway, atlas-operator, vLLM
# router and flux-operator all use chartRef; each must produce a chart-*.yaml
# with real workloads for Polaris to audit.
for cf in chart-karpenter-karpenter.yaml \
          chart-envoy-gateway-system-envoy-gateway.yaml \
          chart-envoy-ai-gateway-system-envoy-ai-gateway.yaml \
          chart-infrastructure-atlas-operator.yaml \
          chart-llm-vllm-semantic-router.yaml \
          chart-flux-system-flux-operator.yaml; do
  if [[ -s ".bundle/${cf}" ]]; then
    echo "  PASS  chartRef chart rendered: ${cf}"
  else
    echo "  FAIL  chartRef chart NOT rendered (blind spot): ${cf}"
    fail=1
  fi
done

echo "== nested Flux-path overlays rendered (no silent overlay drop) =="
# Applied by their own Flux Kustomization (spec.path) but not referenced by a
# parent kustomization; the old top_most_overlays heuristic dropped them from
# both render paths.
for of in overlay-security-mycluster-0-zitadel.yaml \
          overlay-observability-mycluster-0-victoria-metrics-k8s-stack.yaml \
          overlay-infrastructure-mycluster-0-crossplane-configuration.yaml; do
  if [[ -s ".bundle/${of}" ]]; then
    echo "  PASS  nested overlay rendered: ${of}"
  else
    echo "  FAIL  nested overlay NOT rendered (silent drop): ${of}"
    fail=1
  fi
done

echo "== postRenderers applied (loggen) =="
# loggen's chart hardcodes readOnlyRootFilesystem/allowPrivilegeEscalation/
# capabilities at pod-level securityContext, where K8s rejects them; the
# HelmRelease's spec.postRenderers strips them via a kustomize patch. If
# render-bundle.py skips postRenderers, the bundle still has them and the
# schema gate reports a false positive on an already-fixed problem.
loggen_sc="$(python3 - <<'PY'
import yaml
for d in yaml.safe_load_all(open(".bundle/chart-observability-loggen.yaml")):
    if d and d.get("kind") == "Deployment" and d["metadata"]["name"] == "loggen-loggen":
        print(yaml.safe_dump(d["spec"]["template"]["spec"].get("securityContext") or {}))
PY
)"
if [[ "${loggen_sc}" == *"readOnlyRootFilesystem"* || "${loggen_sc}" == *"allowPrivilegeEscalation"* || "${loggen_sc}" == *"capabilities"* ]]; then
  echo "  FAIL  loggen postRenderer did not strip container-level fields from the pod securityContext"
  echo "        got: ${loggen_sc}"
  fail=1
else
  echo "  PASS  loggen postRenderer stripped container-level securityContext fields (spec.postRenderers applied)"
fi

echo "== List envelopes unwrapped =="
# `kind: List` is a client-side envelope (kubectl/kustomize expand it before
# apply), not an applyable resource - the aws-load-balancer-controller chart
# wraps an IngressClassParams + an IngressClass this way. None should survive
# into the bundle, and the IngressClass should appear as its own document.
list_count="$(grep -rh '^kind: List$' .bundle/*.yaml 2>/dev/null | wc -l || true)"
check "no List envelopes remain in the bundle" "0" "${list_count}"

if grep -rq '^kind: IngressClass$' .bundle/*.yaml 2>/dev/null; then
  echo "  PASS  IngressClass (formerly wrapped in a List) is present as a standalone resource"
else
  echo "  FAIL  IngressClass missing from the bundle after List unwrap"
  fail=1
fi

echo "== quantity normalization =="
# keda's chart defaults `resources.limits.cpu: 1` as a bare YAML number - the
# API server's Quantity.UnmarshalJSON accepts that, but flux-schema's catalog
# types Quantity as `string` only. render-bundle.py's normalize_quantities
# should stringify it so the bundle doesn't manufacture a false positive.
if grep -q "cpu: '1'" .bundle/chart-keda-keda.yaml 2>/dev/null; then
  echo "  PASS  keda's numeric cpu limit (bare 1) normalized to a string"
else
  echo "  FAIL  keda's numeric cpu limit was not normalized to a string"
  fail=1
fi

echo "== flux schema validate (gate 1, end-to-end) =="
validate_out="$("${FLUX_BIN}" schema validate .bundle --config .fluxschema.yml 2>&1)" || true
echo "${validate_out}"
check "gate 1 reports zero invalid/skipped resources" "Invalid: 0, Skipped: 0" "${validate_out}"

exit "$fail"
