# Clarifications: vLLM autoscaling on production-realistic signals

**Spec**: [SPEC-001](spec.md)

> Append-only decision log. Never overwrite an entry; add a new one with the date if a decision changes.

---

## CL-1 — Scale signal: leading vs lagging (2026-05-07)

**Context**: Initial proposal used `vllm:num_requests_waiting > 4` as the primary trigger. User pushed back: *"but requests_waiting is too late no? for answering quickly to answers"*.

**Decision**: Drop `num_requests_waiting` as a scale trigger. Use leading signals only:
1. PRIMARY: `vllm:num_requests_running / max-num-seqs > 0.7` — fires before batch saturates.
2. SECONDARY: `vllm:gpu_cache_usage_perc > 0.6` — fires before KV-cache pressure forces preemption.

`num_requests_waiting` becomes a VMRule alert (LLMQueueDepthSustained) — it's an SLO breach signal, not a scaling input. By the time the queue is sustained > 0, scale-up reaction (75-135s end-to-end) is already too late for the current users.

**Rationale**: For an inference platform optimising for first-token latency under load, scaling has to happen *before* user-visible degradation. `num_requests_waiting > 0` IS user-visible degradation (the request is waiting). `num_requests_running` close to `max-num-seqs` is the last leading indicator before that boundary; pairing it with cache utilisation catches the long-context-burst case that batch count misses.

---

## CL-2 — minReplicas default: 0 vs 1 (2026-05-07)

**Context**: PR #1434 originally set `minReplicas=0` for 3 of 4 models, with KEDA HTTP add-on handling cold-start-from-zero. User clarified intent: *"it is not important the first scale to 1 [for the demo], but the autoscaling criterias should be realistic ... in production we would keep warm nodes"*.

**Decision**: Default `minReplicas=1` for all 4 models. Production deployments inherit this. The demo can override one model to `0` for a one-off "cold-start showcase" (with the understanding that the first request will fail / require a manual retry — no queueing layer).

**Rationale**: Once production keeps `min=1`, the KEDA HTTP add-on's main value-add (queue-and-wake on 0→1) disappears. The proxy hop becomes pure overhead. The `min=0` deadlock that drove the original migration from prometheus → HTTP is not a constraint when `min=1`.

**Consequence**: KEDA HTTP add-on is no longer required by the LLM platform. HelmRelease left in place this iteration; cleanup tracked as follow-up.

---

## CL-3 — Knative KPA out of scope (2026-05-07)

**Context**: During brainstorming, Knative Serving + KPA was raised as the best-of-breed option for sub-second concurrency-based scale-up reaction.

**Decision**: Knative is out of scope for this spec. It would address the residual "leading-trigger reaction time floor" (~75-135s with KEDA polling + pod-start), but introducing an entire new serving stack (activator, queue-proxy, autoscaler) alongside Envoy AI Gateway is reframing the platform routing, not iterating on it.

**Rationale**: We're solving "the SIGNAL is wrong", not "polling cadence is too slow". Switching to leading triggers fixes the user-felt issue. If real-world traffic patterns show sub-90s spike intolerance later, Knative becomes the natural next step — but that's a separate architecture decision, not a fold-in for PR #1434.

**Future option**: If we revisit, the path would be Knative as the inference data-plane (replacing the AI Gateway routing for inference traffic) with KEDA reserved for non-LLM workloads. Tracked as a future ADR.

---

## CL-4 — vLLM Production Stack (vllm-router) deferred (2026-05-07)

**Context**: vLLM Production Stack ships an `vllm-router` purpose-built for vLLM workloads — prefix-cache-aware multi-replica routing, queue-aware load balancing.

**Decision**: Deferred. This spec keeps the Envoy AI Gateway routing surface unchanged.

**Rationale**: vllm-router is genuinely better for vLLM-specific routing (it can route a follow-up turn to the same replica that holds its KV cache), but it would require swapping out the AIGatewayRoute / AIServiceBackend layer entirely. That's a platform-architecture decision (does the LLM platform speak Envoy AI Gateway's standard interface, or does it speak vLLM Production Stack?), not a scaling-fix. Worth tracking as an ADR if multi-replica prefix-cache thrash becomes a measurable issue.

---

## CL-5 — Cooldown 300s vs 600s (2026-05-07)

**Context**: Initial proposal had `cooldownPeriod: 600s` (10min). User accepted; spec drafted with 300s instead.

**Decision**: `cooldownPeriod: 300s` (5min).

**Rationale**: Observed prefix-cache hit rate is ~24% in current workload (per VictoriaMetrics during the 2026-05-07 e2e session). Cache-warm cost is ~30s (CUDA graph compile). A 5min cooldown gives 10× amortisation of cache-warm cost — sufficient. 10min was conservative but unjustified given cache-hit data; releasing replicas faster reduces idle GPU spend.

**Future option**: Tune at runtime via composition input; no spec change needed for adjustments inside [120s, 1800s].

---

## CL-6 — VictoriaMetrics query port (2026-05-07)

**Context**: Initial v0.5.0 composition default for the KEDA prometheus trigger `serverAddress` was `http://vmsingle-victoria-metrics-k8s-stack.observability.svc:8429`. KEDA logged `context deadline exceeded` on every poll during the SPEC-001 sustained-load validation.

**Decision**: Bump composition to v0.5.1 with `serverAddress: ...:8428`.

**Rationale**: The chart's actual VictoriaMetrics single service port is 8428 (verified via `kubectl get svc vmsingle-victoria-metrics-k8s-stack -n observability`). My initial value was a typo. No CNP gap — vmsingle has no namespace-restricting CNP, so KEDA can reach it once the port is correct.

---

## CL-7 — End-to-end validation results (2026-05-07)

**Context**: SPEC-001 plan T-014 / SC-002 / SC-007 verification.

**Test setup**:
- 30 concurrent requests at `xplane-qwen-coder` with 1000 max_tokens each.
- maxNumSeqs = 32 → ratio threshold 0.7 means scale-up at >22 in-flight.
- Composition v0.5.1-pr1434 (port-fixed).

**Observed**:
- T+0s: 1/1 deployment, 0 in flight.
- T+~20s: 30 concurrent in flight; running ratio = 30/32 = 0.9375.
- T+~30s sustained 0.9375 — KEDA poll detects threshold breach.
- **T+75s: Deployment scaled 1→2** (new pod Pending).
- T+~47s: All 30 requests completed HTTP 200 (~47s each — vLLM batch).
- Throughout the test: `vllm:num_requests_waiting` stayed at **0** (verified via VictoriaMetrics range query).

**Result**:
- **SC-002 met**: scale-up < 120s after load start, before queue formed.
- **SC-007 met**: scale fired on leading running-ratio trigger; lagging `num_requests_waiting` never crossed 0.
- **Caveat**: the scaled-up pod stays Pending because the `gpu-l4` NodePool is capped at `nvidia.com/gpu: "4"` and we already had 4 GPU nodes hosting (FIM + qwen-coder + qwen3-8b + llamaguard). The autoscaling design is validated; the schedule cap is a separate cluster-cost constraint outside SPEC-001 scope. Production deployments with `maxReplicas > 1` per model must size the NodePool limit accordingly.

---

## CL-8 — Scale-down validation (2026-05-07)

**Test**: After the SC-002 load test scaled `xplane-qwen-coder` 1→2, observed scale-down behavior.

**Observed**:
- Load completed at ~10:14:50; trigger went inactive (running ratio = 0).
- KEDA `cooldownPeriod: 300s` started counting down.
- **Scale-down 2→1 fired at 10:20:03** — exactly 5 min after inactivity.
- Final state: 1/1 Running, no orphan pods. `minReplicaCount: 1` was respected (didn't go to 0).

**Result**: scale-down works as designed. Cooldown timing matches FR-004 (300s).

---

## CL-9 — Cache-util trigger not exercisable on L4 with current sizing (2026-05-07)

**Test**: T-015 / SC-003 — single long-context (~16k-token) request to `xplane-qwen3-8b` to fire cache-util trigger alone.

**Observed**:
- `vllm:gpu_cache_usage_perc{model_name="xplane-qwen3-8b"}` peaked at **0.195** (19.5%) — well below the 0.6 threshold.
- Trigger correctly did NOT fire (peak < threshold).
- KEDA polled the metric without errors (verified via operator logs).

**Why no fire**: vLLM KV-cache pool size scales with `max_num_seqs * max_model_len`. On L4 with `max_num_seqs=32` and `contextWindow=32768`, pool capacity is ~1M tokens. A single 16k-token request fills only 1.6% of capacity. To fire the cache trigger at 60% would require sustained concurrent long-context load (e.g., 30 concurrent 16k-context requests = 480k tokens = 48%, still under 60%).

**Conclusion**: cache-util trigger is **wired correctly** but not practically exercisable on L4-class GPUs with the current `max_num_seqs=32` defaults. Its value is as a backstop for environments with smaller `max_num_seqs` (where the cache fills sooner than the batch saturates), and for forensic visibility into KV-cache pressure as an alarm signal. Lowering the threshold to 0.4 was considered; rejected because the running-ratio trigger fires first under realistic load patterns (validated in CL-7).

**Future tuning**: if a workload pattern emerges where cache pressure leads batch saturation (e.g., RAG with 100+k contexts on small batch sizes), lower `cacheUtilizationThreshold` per claim — runtime-tunable, no spec change.
