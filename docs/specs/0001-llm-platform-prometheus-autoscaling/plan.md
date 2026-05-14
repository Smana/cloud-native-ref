# Plan: vLLM autoscaling on production-realistic signals

**Spec**: [SPEC-001](spec.md)
**Status**: done
**Last updated**: 2026-05-07

> Implementation plan for replacing KEDA HTTP add-on with `prometheus`-trigger `ScaledObject`s on leading vLLM saturation metrics. Folded into PR #1434 (`wip/self-hosted-llm-platform-draft`).

---

## Design

### Triggers (per `ScaledObject`)

```yaml
spec:
  scaleTargetRef:
    name: xplane-<model>
  minReplicaCount: 1
  maxReplicaCount: 2  # per-model, from InferenceService.spec.scaling.maxReplicas
  pollingInterval: 15
  cooldownPeriod: 300
  triggers:
    # PRIMARY — leading: scale before batch saturates.
    - type: prometheus
      metadata:
        serverAddress: http://vmsingle-victoria-metrics-k8s-stack.observability.svc:8429
        query: |
          max(vllm:num_requests_running{model_name="<model>"})
            / on() group_left scalar(<max_num_seqs>)
        threshold: "0.7"
        activationThreshold: "0.05"

    # SECONDARY — leading: catches long-context bursts.
    - type: prometheus
      metadata:
        serverAddress: http://vmsingle-victoria-metrics-k8s-stack.observability.svc:8429
        query: max(vllm:gpu_cache_usage_perc{model_name="<model>"})
        threshold: "0.6"
        activationThreshold: "0.05"
```

KEDA combines the two triggers via `OR` semantics (any one triggers scale-up). `activationThreshold` is the bar between "scale to `minReplicas`" and "active" — set low so the controller is responsive once any load arrives.

### Composition changes (`inference-service` KCL)

| Field | Today | New |
|---|---|---|
| Resource emitted | `HTTPScaledObject` (http.keda.sh/v1alpha1) | `ScaledObject` (keda.sh/v1alpha1) |
| Trigger source | KEDA HTTP add-on (push, host-header dispatch) | VictoriaMetrics queries |
| `spec.scaling.minReplicas` default | `0` | `1` |
| `spec.maxNumSeqs` (new) | — | `64` (matches vLLM default for L4-class GPUs); plumbed into trigger query via composition |
| `kcl.mod` version | `0.4.3` | `0.5.0` (breaking on the trigger Kind) |

### Routes (`apps/base/ai/llm/ai-gateway-routes/route.yaml`)

| File state | Today | New |
|---|---|---|
| `Backend keda-interceptor` | exists, FQDN to interceptor proxy | **removed** |
| `AIServiceBackend xplane-qwen-coder-fim` | direct (already correct) | unchanged |
| `AIServiceBackend xplane-qwen-coder` | discovery-only, ref to keda-interceptor | direct: `Backend(FQDN=xplane-qwen-coder.llm.svc.cluster.local:8000)` |
| `AIServiceBackend xplane-qwen3-8b` | discovery-only, ref to keda-interceptor | direct: `Backend(FQDN=xplane-qwen3-8b.llm.svc.cluster.local:8000)` |
| `AIServiceBackend xplane-llamaguard3-1b` | discovery-only, ref to keda-interceptor | direct: `Backend(FQDN=xplane-llamaguard3-1b.llm.svc.cluster.local:8000)` |
| `HTTPRoute llm-fleet-keda-*` (3 of them) | plain HTTPRoute with URL-rewrite hack | **removed** — no longer needed |
| `AIGatewayRoute llm-fleet` | 4 rules referencing AIServiceBackends | unchanged in shape, all 4 backendRefs now route directly |

Net: ~120 lines of route YAML get simpler. The comment block at the top explaining the workaround gets removed.

### CNP changes (`infrastructure/base/crossplane/configuration/kcl/inference-service/main.k`)

The model CNP `_defaultIngress` rule for KEDA HTTP interceptor:

```kcl
# REMOVED:
# - Allow keda/component=interceptor → vLLM:8000
```

Stays:
```kcl
# - Allow envoy-gateway-system/owning-gateway=ai-gateway → vLLM:8000  (direct routing)
# - Allow llm/vllm-semantic-router → vLLM:8000  (MoM cascade, future)
# - Allow apps/xplane-openwebui → vLLM:8000  (chat UI)
# - Allow promptfoo/promptfoo → vLLM:8000  (eval suite)
```

The `_defaultEgress` rules are unchanged (DNS only — vLLM doesn't talk out).

### Cleanup (defer to a follow-up PR)

- `keda-add-ons-http` HelmRelease (`infrastructure/base/keda/helmrelease-http-add-on.yaml`) becomes unreferenced.
- Aggregate ClusterRole grant for `httpscaledobjects.http.keda.sh` (`infrastructure/base/crossplane/providers/additional-rbac.yaml`) becomes unneeded.
- The `httpScaledObject` test assertion in `inference-service/main_test.k` rewrites to test `ScaledObject` shape.

These are bounded one-line removals; tracked in plan but **not** part of this PR's scope to keep the diff focused.

### Alternatives considered

- **Pure HPA + prometheus-adapter**: standard but loses any future scale-to-zero option entirely (HPA can't go to 0). Rejected because we want to preserve the *option* (e.g., for rare specialty models) even though we default to `min=1`.
- **Knative Serving + KPA**: best-of-breed for sub-second concurrency-based reaction, but introduces an entire new serving stack alongside Envoy AI Gateway. Out of scope; revisit if leading-trigger reaction time proves insufficient.
- **vLLM Production Stack swap**: prefix-cache-aware routing is genuinely better for vLLM than what Envoy can do, but reframes the entire platform routing layer. Tracked as a future architectural decision; not this spec.

---

## Tasks

### Phase 1 — Composition update

- [x] **T-001** — Bump `kcl.mod` version to `0.5.0` (breaking on emitted Kind).
- [x] **T-002** — Add `maxNumSeqs` field to `InferenceService` spec (KCL schema), default `64`. Plumb into composition rendering.
- [x] **T-003** — Replace `HTTPScaledObject` block in `main.k` with `ScaledObject` block (both prometheus triggers, polling/cooldown values per FR-004).
- [x] **T-004** — Remove the `keda/component=interceptor` ingress rule from `_defaultIngress`.
- [x] **T-005** — Update `main_test.k` to assert `ScaledObject` shape (kind, 2 triggers, minReplicas=1, maxReplicas, both thresholds match composition input).
- [x] **T-006** — Run `./scripts/validate-kcl-compositions.sh` — exit 0.
- [x] **T-007** — Push commit, wait for CI to publish `oci://ghcr.io/smana/cloud-native-ref/crossplane-inference-service:0.5.0-pr1434`.

### Phase 2 — Composition source URL bump

- [x] **T-008** — Bump `infrastructure/base/crossplane/configuration/inference-service-composition.yaml` source to `0.5.0-pr1434`.

### Phase 3 — Routing simplification

- [x] **T-009** — Rewrite `apps/base/ai/llm/ai-gateway-routes/route.yaml`:
  - Remove `Backend keda-interceptor`.
  - Remove 3× `HTTPRoute llm-fleet-keda-*`.
  - Re-add 3× `AIServiceBackend` (qwen-coder, qwen3-8b, llamaguard3-1b) with direct per-model `Backend(FQDN=...)`.
  - Drop the long comment block explaining the workaround.

### Phase 4 — InferenceService claim updates

- [x] **T-010** — Update each of `apps/base/ai/llm/{qwen-coder,qwen3-8b,llamaguard3-1b}.yaml`:
  - `spec.scaling.minReplicas: 1` (was `0`).
  - Add `spec.maxNumSeqs` (default `64`).
- [x] **T-011** — `qwen-coder-fim.yaml` keeps `min=1` (unchanged). Add `maxNumSeqs` for trigger consistency even though FIM has no scaling triggers (see plan §Triggers).

### Phase 5 — Validation

- [x] **T-012** — Wait for Flux reconcile. Verify `kubectl get scaledobject -A` shows 3 (not 4 — FIM has none) `ScaledObject`s with `prometheus` triggers. Verify `kubectl get httpscaledobject -n llm` is empty.
- [x] **T-013** — `kubectl get deploy -n llm` — all 4 models READY=1/1.
- [x] **T-014** — Run sustained-load test against `xplane-qwen-coder` (T-Spec SC-002): `seq 8 | xargs -P8 -I% curl -m 60 ... -d 'max_tokens:200'`. Watch `kubectl get deploy xplane-qwen-coder -n llm -w`. Expect 1→2 scale-up within ~120s.
- [x] **T-015** — Run long-context test (T-Spec SC-003): single curl with a 31k-token prompt to `xplane-qwen3-8b`. Watch deployment + VictoriaMetrics: scale-up should fire on cache utilisation alone.
- [x] **T-016** — Idle-stability test (T-Spec SC-004): wait 15min idle, verify all 4 deployments still READY=1/1.
- [x] **T-017** — Verify `vllm:num_requests_waiting > 0` is **never** the trigger that fires during the load test (read VictoriaMetrics history during the 1→2 transition window).

### Phase 6 — VMRule alerts (SC-006)

- [x] **T-018** — Add `apps/base/ai/llm/vmrule-llm-slo.yaml`:
  - Alert `LLMQueueDepthSustained`: `vllm:num_requests_waiting > 0 for 60s`.
  - Alert `LLMTTFTBreached`: `histogram_quantile(0.95, rate(vllm:time_to_first_token_seconds_bucket[5m])) > 1` for 5min.

### Phase 7 — Documentation

- [x] **T-019** — Update `clusters/mycluster-0-llm-platform/README.md` (architecture description) to remove KEDA HTTP from the routing diagram and add a note on the prometheus-trigger scaling.
- [x] **T-020** — Update `CLAUDE.md` § "Self-Hosted LLM Platform" to reflect `min=1` default and trigger summary.
- [x] **T-021** — `clarifications.md` entry for "why not Knative KPA" and "why min=1 over min=0" — link back to brainstorming session.

---

## Review checklist (4-persona)

### Platform Engineer

- [x] Composition diff renders successfully via `./scripts/validate-kcl-compositions.sh`.
- [x] CRD coverage: every emitted Kind (`ScaledObject`) is listed in `infrastructure/base/crossplane/providers/activation-policy.yaml` (already is — keda.sh provider).
- [x] No post-creation dict mutation (function-kcl #285).
- [x] List comprehensions single-line, `kcl fmt` clean.

### Security Reviewer

- [x] CNP `_defaultIngress` no longer references `keda/interceptor` — confirmed.
- [x] Crossplane SA aggregate ClusterRole still works (no new RBAC needed; `keda.sh/scaledobjects` was already granted).
- [x] No new ingress paths opened on vLLM pods.
- [x] EKS Pod Identity scoping unchanged.

### SRE / Observability

- [x] Both triggers query metrics that *already* exist in VictoriaMetrics (verified live: `vllm:num_requests_running`, `vllm:gpu_cache_usage_perc`).
- [x] `pollingInterval=15s` doesn't pressure VictoriaMetrics (3 ScaledObjects × 2 queries × 4/min = 24 queries/min — negligible).
- [x] VMRule alerts cover the lagging-signal SLOs (queue depth, TTFT) — replace the implicit "404 from interceptor" failure mode with explicit alerts.
- [x] Cooldown=300s aligns with prefix-cache reuse value (avg cache-warm-up cost ~30s, so a 5min cooldown gives 10× amortisation).

### PM / Product

- [x] Demo viewer sees scale-up under load (US-2). Verified by SC-002.
- [x] OpenWebUI / OpenCode UX is not affected (data-path simpler, latency only improves).
- [x] FIM (IDE autocomplete) keeps sub-second TTFT — unchanged because FIM stays direct-routed.
- [x] No client-side change required for any consumer.

---

## Risks / Rollback

- **Risk**: leading-trigger thresholds (running > 0.7 of max-num-seqs, cache > 0.6) are guesses. Real-world traffic patterns may have load curves that don't match. **Mitigation**: thresholds are data-driven via composition inputs; tunable per InferenceService at runtime via `spec.scaling.runningRatioThreshold` + `spec.scaling.cacheThreshold` (SHOULD-have for v0.5.1).
- **Risk**: KEDA prometheus polling lag (15s) + scale-up time (~90-120s) means we can still under-provision under sudden traffic spikes faster than ~75-135s end-to-end. **Mitigation**: documented in spec NON-GOALS; "predictive" scaling is out of scope. Ops can pre-warm by setting min=2 for hot models.
- **Risk**: `cooldownPeriod=300s` may be too aggressive if KV-cache reuse benefit is low at our prefix-cache hit rates (currently observed ~24%). **Mitigation**: easy tune-down to 120s without composition change.
- **Rollback**: revert this PR's composition source URL bump (`0.5.0-pr1434` → `0.4.3-pr1434`) — Flux reconciles previous composition shape; HTTPScaledObjects re-render. Single-commit revert.
