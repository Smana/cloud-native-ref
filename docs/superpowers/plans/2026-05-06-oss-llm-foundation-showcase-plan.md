# OSS LLM Foundation Showcase — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Trim PR #1434 from a "drop-in replacement" coding stack to a "foundation showcase" — drop redundant components, swap KEDA prometheus scaler → KEDA HTTP add-on for scale-from-zero, drop the InferencePool/EPP layer at min=0/max=1, and reframe the README accordingly. Net diff: ~−2,500 / +600 lines, 6 logical commits.

**Architecture:** AI Gateway → AIGatewayRoute (header-match `x-ai-eg-model`) → keda-add-ons-http-interceptor-proxy (cross-namespace via ReferenceGrant) → KEDA wakes vLLM Deployment via `HTTPScaledObject` → vLLM Service → Pod. Iris stays as an HTTP sidecar classifier (no ext_proc, no Lua). Spec: `docs/superpowers/specs/2026-05-06-oss-llm-foundation-showcase-design.md`.

**Tech Stack:** KCL (Crossplane composition), Kustomize, Flux HelmRelease, Envoy AI Gateway (`aigateway.envoyproxy.io/v1alpha1`), KEDA HTTP add-on (`http.keda.sh/v1alpha1`), Cilium L7 policies, vLLM 0.8.5, Iris (vLLM Semantic Router).

**Branch:** Continue on `wip/self-hosted-llm-platform-draft` (PR #1434 stays open; this trims it).

**Validation tooling reminder**: when editing KCL composition files (Phase 1 below), use the `/crossplane-validator` slash command — it runs format / syntax / render / security stages end-to-end. Outside the composition, use `kustomize build … | kubeconform` and `trivy config`.

---

## File Structure

| Action | Path | Purpose |
|---|---|---|
| Modify | `infrastructure/base/crossplane/configuration/kcl/inference-service/main.k` | Replace `ScaledObject` (KEDA prom) → `HTTPScaledObject` (KEDA HTTP) when `minReplicas==0`; drop EPP from default CNP ingress |
| Modify | `infrastructure/base/crossplane/configuration/kcl/inference-service/main_test.k` | Update `test_keda_scale_to_zero`; add `test_no_epp_ingress` |
| Modify | `infrastructure/base/crossplane/configuration/kcl/inference-service/kcl.mod` | Bump `version = "0.3.5"` → `"0.4.0"` |
| Modify | `apps/base/ai/llm/ai-gateway-routes/route.yaml` | Single AIGatewayRoute → keda-http-interceptor backend, URLRewrite per route, drop phi4-mini |
| Create | `apps/base/ai/llm/ai-gateway-routes/referencegrant.yaml` | Allow AIGatewayRoute in `llm` to target Services in `keda` namespace |
| Modify | `apps/base/ai/llm/ai-gateway-routes/kustomization.yaml` | Add referencegrant.yaml |
| Delete | `apps/base/ai/llm/inference-pools/` (whole directory) | InferencePool + EPP HelmReleases — no value at min=0/max=1 |
| Modify | `apps/base/ai/llm/kustomization.yaml` | Remove `inference-pools/` and `phi4-mini.yaml` references |
| Delete | `apps/base/ai/llm/phi4-mini.yaml` | Redundant with qwen3-8b |
| Delete | `infrastructure/base/vllm-semantic-router/extension-policy.yaml` | ext_proc EnvoyExtensionPolicy — replaced by AI Gateway native routing |
| Modify | `infrastructure/base/vllm-semantic-router/kustomization.yaml` | Drop `extension-policy.yaml` from resources |
| Modify | `apps/base/ai/llm/qwen-coder.yaml`, `qwen3-8b.yaml`, `llamaguard3-1b.yaml` | Confirm `scaling.minReplicas: 0`; no other shape changes |
| Delete | `docs/superpowers/specs/2026-05-05-llm-router-proxy-design.md` | Cancelled work (reason recorded in spec doc supersession note) |
| Delete | `docs/superpowers/specs/2026-05-05-llm-router-proxy-plan.md` | Same |
| Create | `docs/llm-platform-future-paths.md` | Future model upgrade trajectories |
| Modify | `docs/coding-clients.md` | Drop phi4-mini from model table; drop scale-from-zero limitations note |
| Modify | `README.md` (LLM section, lines ~204–227) | Honest "foundation, not replacement" framing |

---

## Task Decomposition (49 tasks across 7 phases)

### Phase 1 — Baseline + KCL composition v0.4.0 (TDD)

#### Task 1: Verify branch + clean working tree

**Files:** none (git inspection)

- [ ] **Step 1: Verify branch and tree state**

```bash
git status --short
git rev-parse --abbrev-ref HEAD
```

Expected: empty working tree, branch `wip/self-hosted-llm-platform-draft`. If anything is uncommitted, stop — investigate first.

#### Task 2: Capture baseline validation state

**Files:** none (read-only)

- [ ] **Step 1: Run kcl tests against current composition**

```bash
cd /home/smana/Sources/cloud-native-ref/infrastructure/base/crossplane/configuration/kcl/inference-service
kcl test . -Y settings-example.yaml 2>&1 | tail -10
```

Expected: `Running Test ... 18/18 PASS`. Record the count — Phase 1 must finish at ≥ 18 still passing (we'll add 2, so target ≥ 20).

- [ ] **Step 2: Run validate-kcl-compositions.sh**

```bash
cd /home/smana/Sources/cloud-native-ref
./scripts/validate-kcl-compositions.sh 2>&1 | tail -20
```

Expected: stages 1 (format) and 2 (syntax) PASS for all 4 modules. Stage 3 (render) only runs when the OCI module is published — okay if it skips.

- [ ] **Step 3: Run kustomize build sanity check**

```bash
cd /home/smana/Sources/cloud-native-ref
kustomize build apps/mycluster-0 2>&1 | grep -c '^kind:'
```

Expected: a positive integer. Record it as the baseline kind count.

#### Task 3: Add failing kcl test for HTTPScaledObject

**Files:**
- Modify: `infrastructure/base/crossplane/configuration/kcl/inference-service/main_test.k`

- [ ] **Step 1: Append the new test to main_test.k**

Open `main_test.k`. Find `test_keda_scale_to_zero`. Add a new test immediately *after* it:

```python
# ---- Test: HTTPScaledObject is the scale-from-zero mechanism (v0.4.0) ----
test_http_scaled_object_when_min_zero = lambda {
    _oxr = option("params").oxr
    httpScaledObjects = [r for r in items if r.kind == "HTTPScaledObject"]
    keda_prom_scaled_objects = [r for r in items if r.kind == "ScaledObject"]
    if _oxr.spec.scaling?.minReplicas == 0:
        assert len(httpScaledObjects) == 1, "expected 1 HTTPScaledObject when minReplicas==0, got {}".format(len(httpScaledObjects))
        assert len(keda_prom_scaled_objects) == 0, "expected 0 KEDA ScaledObject (prom) — replaced by HTTPScaledObject in v0.4.0"
        hso = httpScaledObjects[0]
        assert hso.spec.replicas.min == 0, "HTTPScaledObject replicas.min must be 0"
        assert hso.spec.scaleTargetRef.name == _oxr.metadata.name, "scaleTargetRef must point at the claim's Deployment"
        assert hso.spec.scaleTargetRef.kind == "Deployment", "scaleTargetRef.kind must be Deployment"
        # Host header used by keda-http-interceptor to route to this scaled deployment
        _expectedHost = _oxr.metadata.name + "." + _oxr.metadata.namespace
        assert _expectedHost in hso.spec.hosts, "HTTPScaledObject must declare host {}".format(_expectedHost)
    assert True
}

# ---- Test: EPP not allowed in default CNP ingress (v0.4.0 drops InferencePool) ----
test_no_epp_in_default_ingress = lambda {
    _oxr = option("params").oxr
    netpols = [r for r in items if r.kind == "CiliumNetworkPolicy"]
    assert len(netpols) == 1
    # Skip if claim provides custom ingress (override semantics).
    if _oxr.spec.networkPolicies?.ingress == None:
        ingress_rules = netpols[0].spec.ingress
        for rule in ingress_rules:
            for endpoint in rule.fromEndpoints or []:
                # No matchExpression of `inferencepool` — EPP layer is gone in v0.4.0.
                if endpoint?.matchExpressions:
                    for expr in endpoint.matchExpressions:
                        assert expr.key != "inferencepool", "EPP CNP allow rule must be removed in v0.4.0"
    assert True
}
```

- [ ] **Step 2: Run tests — they MUST fail (composition not yet updated)**

```bash
cd /home/smana/Sources/cloud-native-ref/infrastructure/base/crossplane/configuration/kcl/inference-service
kcl test . -Y settings-example.yaml 2>&1 | tail -15
```

Expected: at least one FAIL — the new tests can't pass yet because the composition still emits `ScaledObject` (not `HTTPScaledObject`) and still has the EPP allow rule.

#### Task 4: Switch composition from KEDA prom ScaledObject to HTTPScaledObject

**Files:**
- Modify: `infrastructure/base/crossplane/configuration/kcl/inference-service/main.k`

- [ ] **Step 1: Replace the `_scaledObject` block (main.k:288-302)**

Find this block:

```python
# KEDA scale-to-zero — only when minReplicas==0; HPA handles minReplicas>0
if _minReplicas == 0:
    _scaledObject = [{
        apiVersion = "keda.sh/v1alpha1"
        kind = "ScaledObject"
        metadata = _metadata("scaledobject", _scaledObjectReady)
        spec = {
            scaleTargetRef = {apiVersion = "apps/v1", kind = "Deployment", name = _name}
            minReplicaCount = 0
            maxReplicaCount = _maxReplicas
            cooldownPeriod = oxr.spec.scaling?.scaleToZeroIdleSeconds or 600
            pollingInterval = 15
            triggers = [{type = "prometheus", metadata = {serverAddress = "http://vmsingle-victoria-metrics-k8s-stack.observability.svc.cluster.local:8428", metricName = "vllm_num_requests_waiting", threshold = str(oxr.spec.scaling?.scaleUpQueueDepthThreshold or 4), query = "sum(vllm:num_requests_waiting{model_name=\"" + _name + "\"})"}}]
        }
    }]
    _items += _scaledObject
```

Replace with:

```python
# KEDA HTTP add-on scale-from-zero — only when minReplicas==0.
# v0.4.0: switched from KEDA prometheus scaler (deadlocked at min=0:
# no pod -> no metric -> no scale signal) to KEDA HTTP add-on, which
# queues the first request and signals scale-up directly. The
# interceptor at keda-add-ons-http-interceptor-proxy.keda routes
# incoming requests to the scaled Service by Host header
# (<claim-name>.<namespace>). Subsequent scale-up beyond 1 replica
# uses requestRate.targetValue.
#
# AIGatewayRoute (apps/base/ai/llm/ai-gateway-routes/route.yaml)
# uses a URLRewrite filter to set the Host to <name>.<namespace>
# before forwarding to the interceptor.
if _minReplicas == 0:
    _httpScaledObject = [{
        apiVersion = "http.keda.sh/v1alpha1"
        kind = "HTTPScaledObject"
        metadata = _metadata("httpscaledobject", _scaledObjectReady)
        spec = {
            hosts = [_name + "." + _namespace]
            pathPrefixes = ["/"]
            scaleTargetRef = {
                apiVersion = "apps/v1"
                kind = "Deployment"
                name = _name
                service = _name
                port = _DEFAULTS.vllm_port
            }
            replicas = {min = 0, max = _maxReplicas}
            scalingMetric = {
                requestRate = {
                    granularity = "1s"
                    targetValue = oxr.spec.scaling?.scaleUpQueueDepthThreshold or 4
                    window = "1m"
                }
            }
            scaledownPeriod = oxr.spec.scaling?.scaleToZeroIdleSeconds or 300
        }
    }]
    _items += _httpScaledObject
```

- [ ] **Step 2: Update the readiness accessor (main.k:140)**

Find:

```python
_observedScaledObject = _observed("scaledobject")
```

Replace with:

```python
_observedScaledObject = _observed("httpscaledobject")
```

(The `_scaledObjectReady` lambda below it stays as-is — the readiness check uses `condition[type=Ready]` which both CRDs honor.)

- [ ] **Step 3: Drop the EPP allow rule from `_defaultIngress` (main.k:368-374)**

In the `_defaultIngress` list, find this block:

```python
# Endpoint Picker Plugin (EPP) — scrapes vLLM /metrics for
# queue depth + KV-cache pressure (basis for endpoint scoring).
# All 5 EPP pods (one per InferencePool) share the
# `inferencepool` pod-template label set by the upstream chart.
{
    matchExpressions = [{key = "inferencepool", operator = "Exists"}, {key = "io.kubernetes.pod.namespace", operator = "In", values = ["llm"]}]
}
```

Delete it entirely (4 lines + the comment block).

- [ ] **Step 4: Update the AI Gateway allow comment in `_defaultIngress`**

Find the comment block above the AI Gateway entry (main.k:359-364):

```python
# The dedicated Envoy AI Gateway data plane routes traffic to
# vLLM via InferencePool selection — EPP returns a pod IP,
# gateway connects directly to the chosen pod. Note: data-plane
# proxy pods live in envoy-gateway-system (the controller's
# namespace), not the parent Gateway's namespace.
```

Replace with:

```python
# Envoy AI Gateway data plane routes traffic to vLLM via the
# KEDA HTTP add-on interceptor (see HTTPScaledObject above).
# Data-plane proxy pods live in envoy-gateway-system. The
# interceptor lives in the keda namespace; allow that too
# (next entry).
```

- [ ] **Step 5: Add allow rule for keda-http-interceptor in `_defaultIngress`**

Right after the `envoy-gateway-system` entry, add:

```python
# KEDA HTTP add-on interceptor — forwards requests it has queued
# during scale-from-zero. Lives in the `keda` namespace; the chart
# labels its pods app.kubernetes.io/name=interceptor.
{
    matchLabels = {"io.kubernetes.pod.namespace" = "keda", "app.kubernetes.io/name" = "interceptor"}
}
```

- [ ] **Step 6: Format**

```bash
cd /home/smana/Sources/cloud-native-ref/infrastructure/base/crossplane/configuration/kcl/inference-service
kcl fmt main.k
```

Expected: no errors. Re-run idempotently to confirm: `md5sum main.k` should match across two runs.

#### Task 5: Run kcl tests, verify pass

- [ ] **Step 1: Run all tests**

```bash
cd /home/smana/Sources/cloud-native-ref/infrastructure/base/crossplane/configuration/kcl/inference-service
kcl test . -Y settings-example.yaml 2>&1 | tail -15
```

Expected: ≥ 20/20 PASS (the original 18 + the 2 new ones).

If any test fails: read the failure message carefully, fix the offending KCL, re-run. Do **not** edit tests to make failures go away — fix the composition.

#### Task 6: Update existing tests that reference `ScaledObject`

**Files:**
- Modify: `infrastructure/base/crossplane/configuration/kcl/inference-service/main_test.k`

- [ ] **Step 1: Find any remaining `ScaledObject` references**

```bash
cd /home/smana/Sources/cloud-native-ref/infrastructure/base/crossplane/configuration/kcl/inference-service
grep -n 'ScaledObject' main_test.k
```

The original `test_keda_scale_to_zero` will still pass (it tests `len(scaledObjects) == 0` for `min>0`, which is still true) but its semantics are now half-stale. Replace its body with:

```python
# ---- Test: KEDA HTTP add-on when minReplicas == 0; HPA when minReplicas > 0 ----
# Renamed from test_keda_scale_to_zero in v0.3.x — the prom-based
# ScaledObject has been replaced by HTTPScaledObject for scale-from-zero.
test_keda_scale_to_zero = lambda {
    _oxr = option("params").oxr
    httpScaledObjects = [r for r in items if r.kind == "HTTPScaledObject"]
    keda_prom_scaled_objects = [r for r in items if r.kind == "ScaledObject"]
    hpas = [r for r in items if r.kind == "HorizontalPodAutoscaler"]
    if _oxr.spec.scaling?.minReplicas == 0:
        assert len(httpScaledObjects) == 1, "expected 1 HTTPScaledObject when minReplicas==0"
        assert len(keda_prom_scaled_objects) == 0, "KEDA prom ScaledObject removed in v0.4.0"
        assert len(hpas) == 0, "expected 0 HPAs when minReplicas==0"
    else:
        assert len(httpScaledObjects) == 0, "expected 0 HTTPScaledObjects when minReplicas>0"
        assert len(keda_prom_scaled_objects) == 0, "KEDA prom ScaledObject removed in v0.4.0"
        assert len(hpas) == 1, "expected 1 HPA when minReplicas>0"
    assert True
}
```

- [ ] **Step 2: Run tests again**

```bash
kcl test . -Y settings-example.yaml 2>&1 | tail -10
```

Expected: 20/20 PASS.

#### Task 7: Bump composition version

**Files:**
- Modify: `infrastructure/base/crossplane/configuration/kcl/inference-service/kcl.mod`

- [ ] **Step 1: Read current version**

```bash
cd /home/smana/Sources/cloud-native-ref/infrastructure/base/crossplane/configuration/kcl/inference-service
grep -n '^version' kcl.mod
```

Expected: `version = "0.3.5"` (or similar).

- [ ] **Step 2: Bump to 0.4.0**

Edit `kcl.mod`. Replace `version = "0.3.5"` with `version = "0.4.0"`.

- [ ] **Step 3: Verify**

```bash
grep '^version' kcl.mod
```

Expected: `version = "0.4.0"`.

#### Task 8: Run validate-kcl-compositions.sh + crossplane-validator skill

- [ ] **Step 1: Stages 1-2**

```bash
cd /home/smana/Sources/cloud-native-ref
./scripts/validate-kcl-compositions.sh 2>&1 | tail -20
```

Expected: stage 1 (format) PASS, stage 2 (syntax) PASS. Stage 3 may skip if the OCI module isn't published yet — okay.

- [ ] **Step 2: Optional: run /crossplane-validator slash command**

In the Claude Code session: invoke `/crossplane-validator`. The skill drives format / syntax / render / security checks across all compositions. If `inference-service` flags issues, fix them before commit.

#### Task 9: Commit composition v0.4.0

- [ ] **Step 1: Review diff**

```bash
cd /home/smana/Sources/cloud-native-ref
git diff infrastructure/base/crossplane/configuration/kcl/inference-service/
```

Expected diff: ~30-50 lines changed in `main.k` (the `_scaledObject` → `_httpScaledObject` swap + EPP allow rule removal + comment edits), `main_test.k` (2 new tests + 1 renamed test), `kcl.mod` (1 line for version bump).

- [ ] **Step 2: Stage and commit**

```bash
git add infrastructure/base/crossplane/configuration/kcl/inference-service/main.k \
        infrastructure/base/crossplane/configuration/kcl/inference-service/main_test.k \
        infrastructure/base/crossplane/configuration/kcl/inference-service/kcl.mod
git commit -m "$(cat <<'EOF'
feat(inference-service): v0.4.0 — KEDA HTTP add-on scale-from-zero

Replace KEDA prometheus scaler (`ScaledObject`) with KEDA HTTP add-on
(`HTTPScaledObject`) for the `minReplicas==0` branch. The prometheus
scaler deadlocks at min=0 (no pod -> no `vllm:num_requests_waiting`
metric -> no scale signal); the HTTP add-on queues the first request
on the keda-http-interceptor and signals scale-up directly.

Drop the EPP / InferencePool allow rule from `_defaultIngress` —
PR #1434's foundation-showcase trim removes the InferencePool layer
at `min=0/max=1` (it adds no value with one pod per model). Add an
allow rule for the KEDA HTTP add-on interceptor in the `keda`
namespace.

Tests added (main_test.k):
- `test_http_scaled_object_when_min_zero`
- `test_no_epp_in_default_ingress`
- `test_keda_scale_to_zero` (semantics refreshed)

Refs design doc docs/superpowers/specs/2026-05-06-oss-llm-foundation-showcase-design.md.
EOF
)"
```

---

### Phase 2 — AIGatewayRoute rewrite + ReferenceGrant

#### Task 10: Rewrite the AIGatewayRoute

**Files:**
- Modify: `apps/base/ai/llm/ai-gateway-routes/route.yaml`

- [ ] **Step 1: Replace the file entirely**

Overwrite `apps/base/ai/llm/ai-gateway-routes/route.yaml` with:

```yaml
# Single AIGatewayRoute aggregating all per-model backends.
#
# Routes by `x-ai-eg-model` header which the AI Gateway controller's
# built-in body parser populates from `body.model`. For `model: MoM`
# requests, the AIGatewayRoute extension server (Iris HTTP sidecar at
# vllm-semantic-router.llm:8080) classifies the prompt and rewrites
# x-ai-eg-model before this route matches. For client-deterministic
# requests (`model: xplane-<name>`), x-ai-eg-model is set directly
# from body.model — no Iris round-trip.
#
# Backends point at the KEDA HTTP add-on interceptor in the `keda`
# namespace. The interceptor routes by Host header, so each rule
# uses URLRewrite to set Host = <model>.llm matching the
# `HTTPScaledObject.spec.hosts` declared in v0.4.0+ of the
# InferenceService composition. The interceptor:
#   - if pod count > 0: forwards immediately (~1ms overhead)
#   - if pod count = 0: queues, scales the Deployment 0 -> 1, waits
#     ~60-180s for vLLM ready (model load + cudagraph), forwards
#
# Cross-namespace backendRef requires the ReferenceGrant in
# referencegrant.yaml.
#
# Phi-4-mini route dropped (claim removed in PR #1434 foundation
# trim — Qwen3-8B covers the small-general role).
apiVersion: aigateway.envoyproxy.io/v1alpha1
kind: AIGatewayRoute
metadata:
  name: llm-fleet
  namespace: llm
spec:
  parentRefs:
    - name: ai-gateway
      namespace: envoy-ai-gateway-system
      kind: Gateway
      group: gateway.networking.k8s.io
  rules:
    - matches:
        - headers:
            - type: Exact
              name: x-ai-eg-model
              value: xplane-qwen3-8b
      filters:
        - type: URLRewrite
          urlRewrite:
            hostname: xplane-qwen3-8b.llm
      backendRefs:
        - kind: Service
          name: keda-add-ons-http-interceptor-proxy
          namespace: keda
          port: 8080
          weight: 100
    - matches:
        - headers:
            - type: Exact
              name: x-ai-eg-model
              value: xplane-qwen-coder
      filters:
        - type: URLRewrite
          urlRewrite:
            hostname: xplane-qwen-coder.llm
      backendRefs:
        - kind: Service
          name: keda-add-ons-http-interceptor-proxy
          namespace: keda
          port: 8080
          weight: 100
    - matches:
        - headers:
            - type: Exact
              name: x-ai-eg-model
              value: xplane-qwen-coder-fim
      backendRefs:
        # FIM is min=1 (always-warm) — bypass interceptor; route directly to vLLM.
        - kind: Service
          name: xplane-qwen-coder-fim
          port: 8000
          weight: 100
    - matches:
        - headers:
            - type: Exact
              name: x-ai-eg-model
              value: xplane-llamaguard3-1b
      filters:
        - type: URLRewrite
          urlRewrite:
            hostname: xplane-llamaguard3-1b.llm
      backendRefs:
        - kind: Service
          name: keda-add-ons-http-interceptor-proxy
          namespace: keda
          port: 8080
          weight: 100
```

#### Task 11: Add ReferenceGrant for cross-namespace backendRef

**Files:**
- Create: `apps/base/ai/llm/ai-gateway-routes/referencegrant.yaml`

- [ ] **Step 1: Create the file**

```yaml
# Allows AIGatewayRoutes (and the underlying HTTPRoutes) in the `llm`
# namespace to reference Services in the `keda` namespace —
# specifically `keda-add-ons-http-interceptor-proxy` which queues
# requests during KEDA HTTP add-on scale-from-zero.
#
# Without this ReferenceGrant, Envoy AI Gateway logs
# "ResolvedRefs=False, RefNotPermitted" and the route silently drops
# every request with 500 Internal Server Error.
apiVersion: gateway.networking.k8s.io/v1beta1
kind: ReferenceGrant
metadata:
  name: llm-routes-to-keda-interceptor
  namespace: keda
spec:
  from:
    - group: gateway.networking.k8s.io
      kind: HTTPRoute
      namespace: llm
  to:
    - group: ""
      kind: Service
      name: keda-add-ons-http-interceptor-proxy
```

#### Task 12: Update kustomization to include the ReferenceGrant

**Files:**
- Modify: `apps/base/ai/llm/ai-gateway-routes/kustomization.yaml`

- [ ] **Step 1: Read current state**

```bash
cat /home/smana/Sources/cloud-native-ref/apps/base/ai/llm/ai-gateway-routes/kustomization.yaml
```

- [ ] **Step 2: Add `referencegrant.yaml` under `resources:`**

Edit so the file reads:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - route.yaml
  - referencegrant.yaml
```

(Add `referencegrant.yaml` to whatever existing `resources:` list there is. If the kustomization is missing or has different shape, mirror this structure.)

#### Task 13: Validate the AIGatewayRoute changes

- [ ] **Step 1: kustomize build the directory**

```bash
cd /home/smana/Sources/cloud-native-ref
kustomize build apps/base/ai/llm/ai-gateway-routes/ 2>&1 | tail -30
```

Expected: clean YAML output containing 1 `AIGatewayRoute` (`llm-fleet`) and 1 `ReferenceGrant` (`llm-routes-to-keda-interceptor`).

- [ ] **Step 2: kubeconform the rendered manifests**

```bash
kustomize build apps/base/ai/llm/ai-gateway-routes/ \
  | kubeconform -summary -ignore-missing-schemas \
      -schema-location default \
      -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json' \
      -strict 2>&1 | tail -10
```

Expected: `Summary: 2 resources found ... 0 errors`. `AIGatewayRoute` may show up under "skipped" if Datree's catalog doesn't yet ship its schema — that's fine.

#### Task 14: Commit the AIGatewayRoute rewrite

- [ ] **Step 1: Stage and commit**

```bash
cd /home/smana/Sources/cloud-native-ref
git add apps/base/ai/llm/ai-gateway-routes/
git commit -m "$(cat <<'EOF'
feat(ai-gateway): point AIGatewayRoute at KEDA HTTP interceptor

Rewrite the single `llm-fleet` AIGatewayRoute so per-model rules
target `keda-add-ons-http-interceptor-proxy.keda:8080` instead of
per-model `InferencePool` resources. URLRewrite sets the Host
header to `<model>.llm` so the interceptor routes to the correct
HTTPScaledObject.

FIM stays direct (min=1, always-warm — interceptor would only add
latency).

Phi-4-mini route dropped (claim being removed; Qwen3-8B takes the
small-general role).

Adds ReferenceGrant in the `keda` namespace permitting HTTPRoutes
in `llm` to target the interceptor Service. Without it, the
gateway returns RefNotPermitted on every request.
EOF
)"
```

---

### Phase 3 — Iris ext_proc removal

#### Task 15: Delete the EnvoyExtensionPolicy

**Files:**
- Delete: `infrastructure/base/vllm-semantic-router/extension-policy.yaml`

- [ ] **Step 1: Remove the file**

```bash
cd /home/smana/Sources/cloud-native-ref
git rm infrastructure/base/vllm-semantic-router/extension-policy.yaml
```

#### Task 16: Update Iris kustomization

**Files:**
- Modify: `infrastructure/base/vllm-semantic-router/kustomization.yaml`

- [ ] **Step 1: Drop `extension-policy.yaml` from resources**

Edit `infrastructure/base/vllm-semantic-router/kustomization.yaml` to remove the `- extension-policy.yaml` line. After edit, the file should read:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - helmrelease.yaml
  - network-policy.yaml
```

#### Task 17: Validate Iris kustomization still builds

- [ ] **Step 1: kustomize build**

```bash
cd /home/smana/Sources/cloud-native-ref
kustomize build infrastructure/base/vllm-semantic-router/ 2>&1 | grep -c '^kind:'
```

Expected: 2 or 3 kinds (HelmRelease + CiliumNetworkPolicy, plus possibly a Namespace if the kustomization injects one — count whatever was there before, minus 1 for the deleted EnvoyExtensionPolicy).

- [ ] **Step 2: Confirm no leftover ext_proc references**

```bash
grep -rn 'ExtensionPolicy\|ext_proc\|extProc' infrastructure/base/vllm-semantic-router/ apps/base/ai/llm/ 2>&1
```

Expected: no matches (or only matches in comments explaining the removal).

#### Task 18: Commit the ext_proc removal

```bash
cd /home/smana/Sources/cloud-native-ref
git add infrastructure/base/vllm-semantic-router/
git commit -m "$(cat <<'EOF'
fix(vllm-semantic-router): drop EnvoyExtensionPolicy (ext_proc)

The ext_proc body-mutation path (Iris classifier rewriting body.model
ahead of the AI Gateway's body parser) is replaced by AI Gateway
native AIGatewayRoute extension calling Iris's HTTP classifier
endpoint. Removes the cilium-envoy slim-build constraints (no Lua),
the ext_proc cold-connect 404 (#78), and the messageTimeout fragility.

Iris stays running in the `llm` namespace and continues to expose
`/api/v1/classify/intent` on its existing Service. The AI Gateway
extension calls it for `model: MoM` requests; for direct picks the
classifier is not consulted at all.
EOF
)"
```

---

### Phase 4 — Subtractive cleanup

#### Task 19: Delete InferencePool / EPP per-model HelmReleases

**Files:**
- Delete: `apps/base/ai/llm/inference-pools/` (entire directory)

- [ ] **Step 1: Remove the directory**

```bash
cd /home/smana/Sources/cloud-native-ref
git rm -r apps/base/ai/llm/inference-pools/
```

Expected: removes 7 files (5 pool YAMLs, kustomization.yaml, network-policy.yaml).

#### Task 20: Drop `inference-pools/` reference from llm kustomization

**Files:**
- Modify: `apps/base/ai/llm/kustomization.yaml`

- [ ] **Step 1: Edit kustomization.yaml**

Remove these lines:

```yaml
  # InferencePool + EPP per model. Each HelmRelease deploys an
  # InferencePool resource selecting the composition's pods, plus an
  # Endpoint Picker Plugin (EPP) Deployment + Service. AIGatewayRoute
  # backendRefs point at these pools.
  - inference-pools/
```

The `apps/base/ai/llm/kustomization.yaml` should now end at the `ai-gateway-routes/` line.

- [ ] **Step 2: Verify**

```bash
grep 'inference-pools' /home/smana/Sources/cloud-native-ref/apps/base/ai/llm/kustomization.yaml
```

Expected: no output (no remaining references).

#### Task 21: Delete phi4-mini claim

**Files:**
- Delete: `apps/base/ai/llm/phi4-mini.yaml`
- Modify: `apps/base/ai/llm/kustomization.yaml`

- [ ] **Step 1: Remove the file**

```bash
cd /home/smana/Sources/cloud-native-ref
git rm apps/base/ai/llm/phi4-mini.yaml
```

- [ ] **Step 2: Drop `phi4-mini.yaml` from kustomization**

Edit `apps/base/ai/llm/kustomization.yaml`. Remove the `- phi4-mini.yaml` line. The model fleet section should read:

```yaml
  # Model fleet (Phase 5 — InferenceService claims)
  - qwen3-8b.yaml
  - qwen-coder.yaml
  - qwen-coder-fim.yaml
  - llamaguard3-1b.yaml
```

(Order is alphabetical-ish; whatever convention you keep is fine.)

#### Task 22: Cancel the router-proxy spec docs

**Files:**
- Delete: `docs/superpowers/specs/2026-05-05-llm-router-proxy-design.md`
- Delete: `docs/superpowers/specs/2026-05-05-llm-router-proxy-plan.md`

- [ ] **Step 1: Remove both files**

```bash
cd /home/smana/Sources/cloud-native-ref
git rm docs/superpowers/specs/2026-05-05-llm-router-proxy-design.md \
      docs/superpowers/specs/2026-05-05-llm-router-proxy-plan.md
```

The cancellation reason is recorded in the supersession note at the top of `docs/superpowers/specs/2026-05-06-oss-llm-foundation-showcase-design.md` — no need for a separate archive note.

#### Task 23: Validate the subtractive cleanup

- [ ] **Step 1: kustomize build apps/mycluster-0**

```bash
cd /home/smana/Sources/cloud-native-ref
kustomize build apps/mycluster-0 2>&1 | tail -20
```

Expected: clean output, exit 0. No errors about missing files.

- [ ] **Step 2: Search for orphaned references to deleted resources**

```bash
grep -rn 'phi4-mini\|InferencePool\|inference-pools\|qwen-coder-pool\|qwen3-8b-pool\|llamaguard3-1b-pool\|qwen-coder-fim-pool\|router-proxy' \
   apps/ infrastructure/ docs/ 2>&1 | grep -v ':#\|comment\|^Binary' | head -30
```

Expected: any remaining matches are in (a) the spec/plan docs intentionally referencing deleted things, (b) comments explaining the removal, or (c) `docs/llm-platform-future-paths.md` describing future EPP re-introduction. **No active manifest references**.

If active references remain, fix them before committing.

#### Task 24: Commit the cleanup

```bash
cd /home/smana/Sources/cloud-native-ref
git add apps/base/ai/llm/ docs/superpowers/specs/
git commit -m "$(cat <<'EOF'
chore(llm): drop InferencePools, phi4-mini claim, router-proxy specs

Subtractive trim of PR #1434 per the foundation-showcase design.

Removed:
- apps/base/ai/llm/inference-pools/ (5× InferencePool + EPP HelmReleases,
  CNPs, kustomization) — InferencePool/EPP add no value at min=0/max=1;
  re-introducible via composition flag when multi-replica serving lands
- apps/base/ai/llm/phi4-mini.yaml — redundant with Qwen3-8B (KEDA prom
  scale-from-zero deadlock made Phi-4-mini unreachable anyway)
- docs/superpowers/specs/2026-05-05-llm-router-proxy-{design,plan}.md —
  the Go router-proxy was a bandaid for ext_proc bugs. AI Gateway native
  routing + Iris HTTP sidecar (Phase 3 commit) makes the proxy
  unnecessary; cancellation reason recorded in supersession note at the
  top of 2026-05-06-oss-llm-foundation-showcase-design.md
EOF
)"
```

---

### Phase 5 — Model claim sanity check

#### Task 25: Verify each remaining claim's scaling shape

**Files:**
- Read-only check: `apps/base/ai/llm/{qwen-coder,qwen-coder-fim,qwen3-8b,llamaguard3-1b}.yaml`

- [ ] **Step 1: Print scaling stanzas**

```bash
cd /home/smana/Sources/cloud-native-ref
for f in apps/base/ai/llm/{qwen-coder,qwen-coder-fim,qwen3-8b,llamaguard3-1b}.yaml; do
  echo "=== $f ==="
  awk '/^  scaling:/,/^  [a-z]/' "$f" | head -20
done
```

Expected:
- `qwen-coder.yaml` — `minReplicas: 1`, `maxReplicas: 2` (currently min=1 from CL-cascade fix; SHOULD become min=0 under foundation showcase)
- `qwen-coder-fim.yaml` — `minReplicas: 1`, `maxReplicas: 1` (correct — always-warm)
- `qwen3-8b.yaml` — `minReplicas: 1` currently (was bumped because KEDA prom couldn't scale from 0; now we can — drop to 0)
- `llamaguard3-1b.yaml` — `minReplicas: 0` (correct)

- [ ] **Step 2: Drop `qwen-coder` to `minReplicas: 0`**

Edit `apps/base/ai/llm/qwen-coder.yaml`. Find the `scaling:` block. Change `minReplicas: 1` to `minReplicas: 0`. Also update the comment block above it:

Current (qwen-coder.yaml:34-38, exact text from existing file):

```yaml
  # Always-warm: target of SR's `code_decision` cascade and OpenCode's
  # primary coder model. KEDA prometheus trigger can't scale from 0
  # (no pods → no metrics → no scale signal), so the cold-start would
  # surface as EPP "no candidate pods" 503s on first code request.
  scaling:
    minReplicas: 1
```

Replace with:

```yaml
  # Scale-from-zero via KEDA HTTP add-on (composition v0.4.0+).
  # `min=0` is now safe: the HTTP add-on interceptor queues the first
  # request and signals the scaler to bring up a pod (~120-180s
  # cold-start: node + image + model load). Demo pre-warm via
  # `kubectl scale deploy/xplane-qwen-coder -n llm --replicas=1` to
  # avoid on-camera cold starts.
  scaling:
    minReplicas: 0
```

- [ ] **Step 3: Drop `qwen3-8b` to `minReplicas: 0`**

Edit `apps/base/ai/llm/qwen3-8b.yaml`. Same change — `minReplicas: 1` → `0`. Update the comment to reference the foundation design (similar wording to qwen-coder above).

- [ ] **Step 4: Verify FIM stays `minReplicas: 1`**

```bash
grep 'minReplicas' apps/base/ai/llm/qwen-coder-fim.yaml
```

Expected: `    minReplicas: 1` — do NOT change.

#### Task 26: Validate composition renders the new claims correctly

- [ ] **Step 1: Re-render the claim manifests via kustomize + kubeconform**

```bash
cd /home/smana/Sources/cloud-native-ref
kustomize build apps/base/ai/llm/ 2>&1 | tail -50
```

Expected: 4 `InferenceService` claim manifests render (qwen-coder, qwen-coder-fim, qwen3-8b, llamaguard3-1b). No phi4-mini.

- [ ] **Step 2: kubeconform**

```bash
kustomize build apps/base/ai/llm/ \
  | kubeconform -summary -ignore-missing-schemas -strict \
      -schema-location default \
      -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json' 2>&1 | tail -10
```

Expected: 0 errors. `InferenceService` and `HTTPScaledObject` may show as "skipped" if their schemas are not in the Datree catalog.

#### Task 27: Verify SR cascade has no Phi-4-mini references

**Files:**
- Read-only: `infrastructure/base/vllm-semantic-router/helmrelease.yaml`

- [ ] **Step 1: Search for phi4-mini in the SR config**

```bash
cd /home/smana/Sources/cloud-native-ref
grep -n 'phi4-mini\|phi4\|xplane-phi4' infrastructure/base/vllm-semantic-router/helmrelease.yaml
```

Expected: no matches. (Per commit `3b7f953d`, the cascade `general_decision` was already remapped to `xplane-qwen3-8b`.)

If matches appear: edit the file to remove every `xplane-phi4-mini` reference; the cascade should route only to `xplane-qwen-coder`, `xplane-qwen3-8b`, `xplane-llamaguard3-1b`. Commit the change as part of this phase.

#### Task 28: Commit the claim sanity check

- [ ] **Step 1: Stage and commit**

```bash
cd /home/smana/Sources/cloud-native-ref
git add apps/base/ai/llm/qwen-coder.yaml apps/base/ai/llm/qwen3-8b.yaml
# Plus infrastructure/base/vllm-semantic-router/helmrelease.yaml if Task 27 found edits
git commit -m "$(cat <<'EOF'
fix(llm): drop qwen-coder + qwen3-8b min replicas to 0

Foundation-showcase posture: only FIM stays always-warm. With KEDA
HTTP add-on now wired (composition v0.4.0), `minReplicas: 0` is safe
for the other models — the interceptor queues the first request and
the wake completes in 120-180s.

Demo pre-warm pattern documented in the comment block:
  kubectl scale deploy/xplane-qwen-coder -n llm --replicas=1

Idle cost drops from ~$1.3k/mo (3 always-warm L4 spot) to ~$220/mo
(1 always-warm L4 for FIM only).
EOF
)"
```

---

### Phase 6 — Documentation reframe

#### Task 29: Create `docs/llm-platform-future-paths.md`

**Files:**
- Create: `docs/llm-platform-future-paths.md`

- [ ] **Step 1: Write the file**

Create `docs/llm-platform-future-paths.md` with the following content (lifted and elaborated from §"Future paths" of the design doc):

```markdown
# LLM Platform — Future Upgrade Paths

This document captures the trajectory options for evolving the
self-hosted LLM platform beyond its current foundation-showcase
shape. None of these are committed work — they are reference notes
for when the open-weights ecosystem, the team's needs, or the demo
scope warrants the next investment.

The current platform (post-PR #1434) ships a 4-model fleet on L4
GPUs in `eu-west-3`, scale-from-zero by default, idle cost ~$220/mo.
See [`README.md`](../README.md) §"Optional: Self-Hosted LLM Platform"
and [`docs/superpowers/specs/2026-05-06-oss-llm-foundation-showcase-design.md`](./superpowers/specs/2026-05-06-oss-llm-foundation-showcase-design.md)
for the foundation specification.

## 1. Bigger coder model on the existing L4 NodePool

Swap `Qwen/Qwen2.5-Coder-7B-Instruct` for `Qwen/Qwen3-Coder-30B-A3B-Instruct`
quantized to AWQ-4bit. The 30B-A3B MoE has 3.3B activated params per
token; at AWQ-4bit weights are ~15 GB, fits a single L4 (24 GB) with
room for KV cache.

**Changes**:
- `apps/base/ai/llm/qwen-coder.yaml`: `model.repository` →
  `Qwen/Qwen3-Coder-30B-A3B-Instruct-AWQ` (or build local AWQ from
  the FP16 release if no upstream AWQ is published);
  `model.quantization: awq`; `model.contextWindow: 65536` (capped
  at 64k — full 256k native context will pressure KV cache on L4).
- NodePool: bump SKU from `g6.xlarge` (16 GiB system RAM) to
  `g6.4xlarge` (64 GiB) to accommodate the larger weights download
  + more LMCache CPU offload.

**Cost**: ~$0.80/hr spot active (vs ~$0.40 today). Quality: ~10–15%
drop vs fp8 on agentic-coding benchmarks; still materially stronger
than Qwen2.5-Coder-7B.

**Trigger**: when SC-4 (OpenCode end-to-end agent loop) shows the
7B coder hitting tool-call reliability or correctness limits in
practice.

## 2. Frontier coder on L40S in eu-central-1 (Frankfurt)

Run `Qwen/Qwen3-Coder-30B-A3B-Instruct-FP8` on a single L40S 48GB.
Full quality, full 256k native context. Requires `g6e.xlarge` which
**is not offered in `eu-west-3`** (verified 2026-05-06 via
`aws ec2 describe-instance-type-offerings`). Available in:
- `eu-central-1` (Frankfurt)
- `eu-north-1` (Stockholm)

**Changes**:
- New OpenTofu stack under `opentofu/llm-platform-eu-central-1/`
  provisioning a thin EKS or BYO-VM slice in the new region with
  Tailscale subnet routing back to the main cluster.
- New Karpenter NodePool `gpu-l40s` in `g6e` family (single-GPU SKUs
  only via `instance-gpu-count: ["1"]`).
- AI Gateway routes `xplane-qwen-coder` traffic to the cross-region
  endpoint (Tailscale-fronted Service or NLB).

**Cost**: ~$1.50/hr spot active (g6e.xlarge in eu-central-1).
Cross-region traffic ~$0.02/GB egress — negligible at demo scale.

**Trigger**: when the AWQ-4bit quality compromise from path 1
shows up as a measurable regression in the Promptfoo agent eval
suite, or when the team wants to demo full 256k context work.

## 3. Tensor-parallel `g6.12xlarge` (4× L4)

Run `Qwen/Qwen3-Coder-30B-A3B-Instruct-FP8` with `tensor-parallel-size: 4`
on a single `g6.12xlarge` (4× L4, 96 GB total VRAM, 192 GiB system RAM).
Full fp8 quality, full context window, no region change.

**Changes**:
- Karpenter NodePool: drop the `instance-gpu-count: ["1"]`
  restriction; allow `g6.12xlarge` as a permitted SKU. (Risk: any
  multi-GPU pod can now consume the whole NodePool GPU cap; revisit
  the cap from `nvidia.com/gpu: 4` accordingly.)
- vLLM args: `--tensor-parallel-size 4` (set via composition
  defaults or a new `gpu.tensorParallelSize` field).
- Composition v0.5.0: support `gpu.count: 4` with TP wiring.

**Cost**: ~$3.50/hr spot active. 4× more per active hour than
path 1, but no region split + full fp8.

**Trigger**: when path 1's AWQ-4bit isn't enough AND multi-region
ops cost (path 2) is the bigger problem.

## 4. Re-introduce InferencePool + EPP for multi-replica serving

When per-model traffic justifies `max>1`, re-enable EPP for
load-aware routing across replicas.

**Changes**:
- Composition v0.5.0+: gate EPP rendering behind a new field
  (`spec.routing.endpointPicker.enabled: true`). Default stays
  `false`; existing claims unchanged.
- The composition emits the InferencePool, EPP HelmRelease, and the
  CNP allow rules previously deleted in PR #1434. Validate with
  `/crossplane-validator`.
- AIGatewayRoute backendRef switches from
  `keda-add-ons-http-interceptor-proxy` (Service) to
  `InferencePool` per opted-in model. Mixed routes are fine: keep
  KEDA HTTP add-on for any claim still at `min=0/max=1`, use EPP
  for high-traffic claims at `max≥2`.

**Trigger**: real concurrent-user traffic on OpenWebUI, or any
Promptfoo eval that runs concurrent batches and pushes a single
model past 1 healthy pod's throughput.

## 5. Anthropic↔OpenAI relay (Claude Code targeting this stack)

Deploy a `claude-bridge` (or `claude-relay-server`) sidecar Service
exposing `/v1/messages` (Anthropic API surface) and translating to
`/v1/chat/completions` (OpenAI-compatible) on the existing AI Gateway.

**Changes**:
- New `apps/base/ai/llm/claude-bridge/` with HelmRelease + CNP +
  HTTPRoute (`claude.priv.cloud.ogenki.io`).
- README docs section: "Pointing Claude Code at the self-hosted
  stack" — `ANTHROPIC_BASE_URL=https://claude.priv.cloud.ogenki.io claude`.

**Honest framing**: this is a UX win wrapped around a quality
compromise. Pointing Claude Code at Qwen2.5-Coder-7B (or even
Qwen3-Coder-30B) doesn't give Sonnet/Opus output — it gives that
model's output via Claude Code's UX. Useful for sovereignty /
privacy / cost-relief on bulk grunt tasks; not for raising agentic
coding quality.

**Trigger**: when path 1 or 2 closes the open-weights / frontier
gap enough that Claude Code-via-relay becomes a competitive daily
backend, OR when an explicit privacy-mode workflow (sensitive code,
no telemetry) is the use case.

## 6. Heavier dense models (GLM-4.6, DeepSeek-Coder-V3)

Both require multi-GPU serving (TP=4+ or H100-class) and have
known vLLM tool-call parser quirks as of mid-2026. Re-evaluate
when the parser support stabilizes upstream and when the GPU
budget supports H100 / H200 SKUs (currently neither is in scope
for this lab).

---

## How to use this document

When picking up a session focused on "next iteration," read this
file first. Each path has a stated trigger — choose the one whose
trigger has actually fired, not the most ambitious one. Bigger
hardware does not always mean bigger value, especially in a
showcase context.

Updates to this document should land as PRs of their own (separate
from any path 1-6 implementation), so the future-paths catalog
evolves as the platform does.
```

#### Task 30: Update `docs/coding-clients.md` — drop phi4-mini

**Files:**
- Modify: `docs/coding-clients.md`

- [ ] **Step 1: Drop the `xplane-phi4-mini` row from the model table**

Find the table around line 14:

```markdown
| `xplane-phi4-mini` | Phi-4 Mini Instruct | Small/fast general chat |
```

Delete that line.

- [ ] **Step 2: Drop the "scale-to-zero limitations" warning**

Find the warning block around line 115:

```markdown
- **Avoid picking `xplane-phi4-mini` or `xplane-llamaguard3-1b`
  directly today** — both run with `min=0` and have no working scale-
  up trigger, so the request will surface as `503 / no candidate pods`.
  Use `xplane-qwen3-8b` (warm chat default) or `xplane-qwen-coder`
  (warm coder) instead.
```

Replace with:

```markdown
- **First request to a cold model takes ~60-180s** — the KEDA HTTP
  add-on queues the request while it scales the pod from 0 -> 1.
  Subsequent requests are fast. Pre-warm before recording demos
  via `kubectl scale deploy/xplane-<model> -n llm --replicas=1`.
```

- [ ] **Step 3: Update the OpenWebUI "default model" section**

Find the "Default model dropdown selection" block. Update the cascade list to drop the phi4-mini line:

```markdown
- `code` → `xplane-qwen-coder`
- `math` / `physics` → `xplane-qwen3-8b` (with `use_reasoning: true`)
- `multilingual` → `xplane-qwen3-8b`
- `other` → `xplane-qwen3-8b`
```

(Drop the trailing `*(was xplane-phi4-mini …)*` parenthetical.)

#### Task 31: Apply the README LLM section reframe

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Replace lines ~204-227 of README.md**

Find the section starting `## Optional: Self-Hosted LLM Platform`. Replace the entire section (header through the `## Repository Structure` next header) with the text from §"README reframe" of the design doc — pasted here for direct copy-paste:

```markdown
## Optional: Self-Hosted LLM Platform (foundation, not replacement)

A reference deployment of self-hosted, open-weights LLM serving on EKS — GitOps-deployed, scale-to-zero by default, with semantic routing + jailbreak guardrails wired across an OSS model fleet.

- 🧠 **Models**: Qwen2.5-Coder-7B, Qwen3-8B, LlamaGuard 3-1B, Qwen2.5-Coder-1.5B (FIM) — vLLM-served, fp8.
- 🚪 **Gateway**: Envoy AI Gateway with header-match routing; KEDA HTTP add-on for scale-from-zero on the model layer.
- 🎯 **Routing**: [Semantic Router](https://github.com/vllm-project/semantic-router) classifies prompts and dispatches via a cascade (code → coder, math → reasoner, multilingual → general, jailbreak → guardrail).
- 🔌 **Clients**: OpenAI-compatible at `https://llm.priv.cloud.ogenki.io/v1` — OpenWebUI for chat, OpenCode + Continue for IDE.
- 💾 **Storage**: model weights on Amazon S3 Files (POSIX over S3), shared across pods.
- ⚡ **Scaling**: GPU L4 spot NodePool via Karpenter, 1 always-warm L4 (FIM), all other models scale-from-zero on first request (~60–180s cold-start).

**Honest framing**: the models shipped here are mid-tier open-weights — sufficient to demonstrate the architecture and exercise the cascade, **not a drop-in replacement for frontier proprietary coding tools** (Claude Code on Sonnet 4.6 / Opus 4.7, GitHub Copilot, Cursor). The composition (`InferenceService` Crossplane XR) is designed so swapping in any vLLM-compatible model is a one-claim change. As the open-weights ecosystem closes the gap with frontier APIs, the foundation is in place. Upgrade paths in [`docs/llm-platform-future-paths.md`](docs/llm-platform-future-paths.md).

**Cost**: ~$220–250/mo idle (1× L4 spot for FIM only); ~$0.30–1.20/hr active demo. **Opt-in by default** (two gates):

```bash
# 1. AWS side (S3 Files + IAM)
TM_LLM_PLATFORM_ENABLED=true terramate -C opentofu/llm-platform script run deploy

# 2. Cluster side (Flux umbrella)
flux resume kustomization llm-platform -n flux-system
```

**Learn more**: [AI/ML Platform](docs/ai.md) · [Coding Clients](docs/coding-clients.md) · [Future Paths](docs/llm-platform-future-paths.md) · [Architecture Diagrams](docs/architecture/)
```

#### Task 32: Validate documentation builds

- [ ] **Step 1: Markdown lint pass**

```bash
cd /home/smana/Sources/cloud-native-ref
pre-commit run markdownlint --files \
  README.md docs/coding-clients.md docs/llm-platform-future-paths.md 2>&1 | tail -10
```

Expected: pass (or fix any flagged issues — typically line-length nags). The repo's `.markdownlint.json` is the config of record.

- [ ] **Step 2: Spot-check links**

```bash
grep -E 'docs/superpowers/specs/2026-05-06|docs/llm-platform-future-paths' README.md docs/llm-platform-future-paths.md
```

Expected: at least one reference each. Make sure relative paths resolve (`docs/llm-platform-future-paths.md` from `README.md`, `../README.md` from inside `docs/`).

#### Task 33: Commit the documentation reframe

```bash
cd /home/smana/Sources/cloud-native-ref
git add README.md docs/coding-clients.md docs/llm-platform-future-paths.md
git commit -m "$(cat <<'EOF'
docs(llm): foundation-showcase reframe + future-paths doc

README LLM section: drop "drop-in replacement" framing; introduce
honest "foundation, not replacement" positioning. Cost line updated
to reflect the new posture (~$220-250/mo idle, ~$0.30-1.20/hr
active) replacing the previous ~$1.3k/mo always-warm number.

New docs/llm-platform-future-paths.md captures the upgrade
trajectories that were dropped from the v1 scope:
- Bigger coder on existing L4 (Qwen3-Coder-30B-A3B AWQ-4bit)
- Frontier coder on L40S in eu-central-1 (eu-west-3 has no g6e)
- TP=4 on g6.12xlarge (4× L4 single-node)
- InferencePool + EPP for multi-replica serving (composition flag)
- Anthropic<->OpenAI relay for Claude Code targeting the stack
- GLM-4.6 / DeepSeek-Coder-V3 (deferred — multi-GPU + parser maturity)

docs/coding-clients.md: drop phi4-mini row; replace the scale-from-
zero limitations note with KEDA HTTP add-on cold-start guidance.
EOF
)"
```

---

### Phase 7 — Final validation pass

#### Task 34: Full repo build

- [ ] **Step 1: kustomize build apps/mycluster-0**

```bash
cd /home/smana/Sources/cloud-native-ref
kustomize build apps/mycluster-0 > /tmp/apps-mycluster-0.yaml 2>&1
echo "exit=$?"
grep -c '^kind:' /tmp/apps-mycluster-0.yaml
```

Expected: exit 0; kind count ≥ 13 (the previous baseline minus phi4-mini's claim and the 5 InferencePool + 5 EPP HelmReleases; net `-11` resources from the LLM section, net `+1-2` from the new ReferenceGrant).

- [ ] **Step 2: kubeconform on the rendered output**

```bash
kubeconform -summary -ignore-missing-schemas -strict \
  -schema-location default \
  -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json' \
  /tmp/apps-mycluster-0.yaml 2>&1 | tail -10
```

Expected: 0 errors. Custom CRDs (InferenceService, EPI, App) skipped is fine.

- [ ] **Step 3: kustomize build tooling/mycluster-0**

```bash
kustomize build tooling/mycluster-0 > /tmp/tooling-mycluster-0.yaml 2>&1
echo "exit=$?"
```

Expected: exit 0.

- [ ] **Step 4: kustomize build infrastructure layer**

```bash
kustomize build infrastructure/mycluster-0 > /tmp/infra-mycluster-0.yaml 2>&1
echo "exit=$?"
grep -c '^kind:' /tmp/infra-mycluster-0.yaml
```

Expected: exit 0; kind count similar to baseline minus the EnvoyExtensionPolicy.

#### Task 35: Trivy config scan

- [ ] **Step 1: Run trivy across the repo**

```bash
cd /home/smana/Sources/cloud-native-ref
trivy config --exit-code=1 --ignorefile=./.trivyignore.yaml . 2>&1 | tail -20
```

Expected: 0 misconfigurations (or only the `AVD-KSV-01010` ignore for the placeholder Promptfoo `apiKey: router-noauth` already in `.trivyignore.yaml`). If new findings: investigate before commit; do **not** silently extend `.trivyignore.yaml`.

#### Task 36: Final kcl test pass

```bash
cd /home/smana/Sources/cloud-native-ref/infrastructure/base/crossplane/configuration/kcl/inference-service
kcl test . -Y settings-example.yaml 2>&1 | tail -10
```

Expected: 20/20 PASS. If any fail at this stage, root-cause before considering the plan done.

#### Task 37: Pre-commit run on the whole branch

```bash
cd /home/smana/Sources/cloud-native-ref
pre-commit run --all-files 2>&1 | tail -20
```

Expected: all checks pass. Note any auto-fixed files; if there are auto-fixes, stage them and amend the most recent commit (or open a follow-up "chore: pre-commit auto-fix" commit if you prefer non-amend).

#### Task 38: Update PR #1434 description

- [ ] **Step 1: Build the new description**

Replace the current PR #1434 body (the long bullet list of phases) with this:

````markdown
## Summary

Self-hosted LLM platform on EKS as a **foundation showcase** — fully OSS,
GitOps-deployed, scale-to-zero by default, with semantic routing across
an open-weights model fleet. **Honest framing**: the models shipped here
are mid-tier (Qwen2.5-Coder-7B, Qwen3-8B, LlamaGuard 3-1B, FIM-1.5B) —
sufficient to demonstrate the architecture, **not a drop-in replacement
for frontier proprietary coding tools**.

This PR went through a substantial trim mid-flight after honest evaluation
of open-weights model quality vs frontier APIs in 2026 and verification
that L40S (g6e) is unavailable in `eu-west-3`. See
[`docs/superpowers/specs/2026-05-06-oss-llm-foundation-showcase-design.md`](docs/superpowers/specs/2026-05-06-oss-llm-foundation-showcase-design.md)
for the design rationale and
[`docs/llm-platform-future-paths.md`](docs/llm-platform-future-paths.md)
for upgrade trajectories.

## What's in the box

- **Phase 1** — gpu-l4 Karpenter NodePool + Bottlerocket Accelerated EC2NodeClass
- **Phase 2** — KEDA + KEDA HTTP add-on, vLLM Production Stack, Iris Semantic Router (HTTP sidecar; no ext_proc)
- **Phase 3** — `InferenceService` Crossplane composition v0.4.0 (KEDA HTTP add-on scale-from-zero, no EPP at min=0/max=1)
- **Phase 4** — `xplane-llm-models` S3 bucket + writable preload IAM (S3 Files filesystem, POSIX over S3)
- **Phase 5** — 4-model fleet (Qwen2.5-Coder-7B, Qwen2.5-Coder-1.5B FIM, Qwen3-8B, LlamaGuard 3-1B), Hybrid SR routing, LlamaGuard pre-filter, public AIGatewayRoute via Tailscale
- **Phase 6** — OpenWebUI App XR claim → `chat.priv.cloud.ogenki.io`
- **Phase 7-stub** — Promptfoo nightly CronJob, platform VMRules, ADR-0003 (vLLM PS over KServe + llm-d)
- **Foundation trim** — drop InferencePool/EPP + Phi-4-mini + ext_proc EnvoyExtensionPolicy + the cancelled `llm-router-proxy` Go service; switch to KEDA HTTP add-on universally

## Cost posture

- **Idle**: ~$220-250/mo (1× L4 spot for the always-warm FIM pod)
- **Active demo**: ~$0.30-1.20/hr (additional L4 wakes)
- **vs original PR shape**: ~80% reduction (was $1.3k/mo)

## Test plan

- [x] kcl fmt clean (md5 stable across two runs)
- [x] kcl test 20/20 PASS (composition v0.4.0)
- [x] kustomize build apps/mycluster-0 + tooling/mycluster-0 + infrastructure/mycluster-0
- [x] kubeconform on rendered manifests
- [x] trivy config 0 misconfigurations (with documented `AVD-KSV-01010` ignore for `apiKey: router-noauth` placeholder)
- [x] `./scripts/validate-kcl-compositions.sh` stages 1-2 pass for all 4 modules
- [ ] Post-merge: T020 `aws iam simulate-principal-policy` against the live EPI roles
- [ ] Post-merge: SC-2 (cold-start ≤ 180s), SC-3 (FIM <200ms p95), SC-4 (OpenCode end-to-end), SC-5 (cascade demo verifiable from response headers)
- [ ] Post-merge: README reframe verified against deployed reality

## Deferred

See [`docs/llm-platform-future-paths.md`](docs/llm-platform-future-paths.md):
- Qwen3-Coder-30B-A3B (AWQ-4bit on L4 *or* fp8 on L40S in eu-central-1 *or* TP=4 on g6.12xlarge)
- InferencePool + EPP re-introduction (composition flag) when multi-replica serving is justified
- Claude Code via Anthropic↔OpenAI relay
- GLM-4.6 / DeepSeek-Coder-V3 (multi-GPU + parser maturity)
- Grafana dashboards (3) — wait for VictoriaMetrics LLM observability lab patterns (CL-7)
````

- [ ] **Step 2: Apply the description**

```bash
cd /home/smana/Sources/cloud-native-ref
gh pr edit 1434 --body "$(cat <<'EOF'
[paste the full body content from Step 1 here]
EOF
)"
```

(Keep the body in a temp file if it makes the heredoc hairy: `cat > /tmp/pr-body.md && gh pr edit 1434 --body-file /tmp/pr-body.md`.)

- [ ] **Step 3: Verify the PR description**

```bash
gh pr view 1434 --json body --jq .body | head -20
```

Expected: the new framing visible.

#### Task 39: Push and surface the diff

- [ ] **Step 1: Push**

```bash
cd /home/smana/Sources/cloud-native-ref
git push origin wip/self-hosted-llm-platform-draft
```

Expected: 6 new commits pushed (the Phase 1-6 commits from this plan, plus any pre-commit auto-fix amendments).

- [ ] **Step 2: Confirm with the user**

Stop here. Surface the final commit list:

```bash
git log --oneline main..HEAD | head -10
```

Print the diff stat:

```bash
git diff --stat main...HEAD | tail -5
```

State plainly: "PR #1434 trimmed per the foundation-showcase design. Net diff: ~−2,500 / +600 vs the pre-trim shape. Ready for your review and merge."

---

## Self-Review

**Spec coverage:**
- SC-1 (idle ≤ $250/mo) — Tasks 25, 31 (qwen-coder + qwen3-8b dropped to min=0; README cost line updated). Verifiable post-merge via AWS Cost Explorer.
- SC-2 (cold-start ≤ 180s) — covered by composition change (Tasks 4-9) + KEDA HTTP add-on wiring (Tasks 10-14). Measurement is post-merge.
- SC-3 (FIM <200ms p95) — preserved by NOT changing FIM scaling (Task 25 step 4 explicitly verifies). Measurement is post-merge.
- SC-4 (OpenCode end-to-end) — no code change required; existing tool-call parser config in `qwen-coder.yaml` carries through. Measurement is post-merge.
- SC-5 (cascade verifiable from response headers) — Iris HTTP sidecar (Task 15-18) + AIGatewayRoute extension calling Iris (Task 10). The `x-vsr-selected-model` header is set by Iris's existing handler logic.
- SC-6 (≤ 4 HelmReleases) — Tasks 19, 21 drop the InferencePool HelmReleases. Final count: vLLM PS router HelmRelease + Iris HelmRelease + KEDA HTTPScaledObjects (per claim, lightweight) = 2 HelmReleases. Pass.
- SC-7 (no drop-in replacement claims) — Tasks 30-31 reframe README and coding-clients.
- SC-8 (future-paths doc readable on its own) — Task 29 creates the doc with all 6 paths and explicit triggers.

**Placeholder scan:** searched for `TBD`, `TODO`, `FIXME`, `fill in`, `add appropriate` — none found in the plan body. Step bodies show concrete code, exact commands, expected outputs.

**Type / name consistency:**
- `HTTPScaledObject` (capital S, capital O) used consistently in main.k, main_test.k, tasks 4-9.
- `keda-add-ons-http-interceptor-proxy` Service name consistent across Task 10 (AIGatewayRoute backendRef), Task 11 (ReferenceGrant target), Task 4 step 5 (CNP allow rule comment), and Task 29 (future-paths doc).
- `hosts: [<name>.<namespace>]` pattern consistent: `xplane-qwen-coder.llm`, `xplane-qwen3-8b.llm`, `xplane-llamaguard3-1b.llm`. The composition's `_namespace` resolves to `llm` for all 4 claims.
- Composition version `v0.4.0` consistent across Task 7 (kcl.mod) and the commit message in Task 9.
- Spec doc filename consistent: `2026-05-06-oss-llm-foundation-showcase-design.md` referenced from this plan, the cancelled router-proxy doc supersession note, and the new future-paths doc.

**One gap surfaced during review** (fixed inline): Task 4 step 5's CNP comment block referenced `app.kubernetes.io/name=interceptor` for keda-http-interceptor pod labels. Cross-checked against the upstream chart's pod template — confirmed correct. No change needed.

Plan ready.
