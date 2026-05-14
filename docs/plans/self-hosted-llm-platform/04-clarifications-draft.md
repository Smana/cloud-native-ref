# Clarifications Log — Self-Hosted LLM Platform with Cascade Routing

**Spec**: [SPEC-NNN](spec.md)

> **Append-only.** Never rewrite earlier entries. Every entry has a stable ID (`CL-1`, `CL-2`, ...) so `spec.md` and `plan.md` can reference the decision by ID. This is the durable "why did we pick option A?" audit trail.
>
> **Status of every entry below: DRAFT — awaiting `/clarify` resolution.** The "Decision" line on each is the spec author's recommendation, included to anchor the conversation; it is not binding until ratified.

---

## CL-1 — 2026-04-26 — Should `model: auto` cascade tiny→mid→large on confidence, or hard-route by classifier?

**Asked by**: Spec author (Smana)
**Context**: The Semantic Router can either (a) call the small model first and escalate when confidence drops, or (b) classify the prompt up-front and dispatch to the predicted-best model with no retry. Option (a) saves cost on easy prompts but adds latency on misses (50–200ms per RouteLLM 2026 measurements). Option (b) is faster on average but wastes the small model when the classifier mispredicts. Both are supported by Semantic Router Iris.

**Options considered**:

| Option | Answer | Pros | Cons |
|--------|--------|------|------|
| A | **Cascade only** — always start at smallest tier, escalate on `vllm_semantic_router_confidence` < threshold | Cheapest in steady state; demonstrates the cascade pattern (showcase value) | Worst-case latency = sum of tiers tried; cold-start amplification when escalating to a scaled-to-zero tier |
| B | **Classifier only** — hard-route per LoRA MoM classifier output | Single hop; latency floor is one model's TTFT | Misclassification ≠ retry, so wrong-tier answers ship to the user; less interesting engineering |
| C | **Hybrid** — classifier picks the family (general vs code vs guardrail), then cascade within tier | Best of both; matches the brief ("route to the proper model for the best efficiency") | Two decision stages = compounding latency budget; more router config to maintain |

**Decision**: **C — Hybrid** (classifier picks specialty family; cascade within tier with `confidenceThreshold: 0.75`, `maxHops: 2`, `perHopTimeoutMs: 4500`).
**Rationale**: The brief was "route to the proper model for the best efficiency". Hybrid keeps the cheap default (Phi-4 Mini) while the LoRA classifier prevents wrong-family routing on code/math/multilingual. Cascade depth capped at 2 hops + 4.5s/hop budget keeps p95 under SC-004 (200ms classifier + 1 GPU hop). Wired in Phase 5 (`infrastructure/base/vllm-semantic-router/helmrelease.yaml` `router.mode: hybrid`).
**Decided by**: Smana, 2026-04-29 (light SDD path — recommendation accepted in conversation).
**References**: [Semantic Router Iris release notes](https://vllm.ai/blog/vllm-sr-iris); [RouteLLM cascade latency observations 2026](https://www.augmentcode.com/guides/ai-model-routing-guide); SC-003, SC-004 in spec.md.

---

## CL-2 — 2026-04-26 — LlamaGuard 3-1B placement: pre-filter, post-filter, or both?

**Asked by**: Spec author (Smana)
**Context**: LlamaGuard 3-1B can run as (1) input filter at the router (block bad prompts before they reach a serving model), (2) output filter on the model's response (block bad outputs before user sees them), or (3) both. Each filter call costs one ~500ms LlamaGuard inference. Constitution mandates zero-trust + observability; FR-009 mandates the platform "MUST block prompts matching the Semantic Router jailbreak / PII plugins and MUST run LlamaGuard 3-1B as a post-filter on model output."

**Options considered**:

| Option | Answer | Pros | Cons |
|--------|--------|------|------|
| A | **Post-filter only** | Cheapest; jailbreak/PII already handled by Iris built-in plugins (no double-filter); only one extra inference per request | A successful jailbreak that bypasses Iris plugins still hits the model and burns GPU; risk of model leaking sensitive info even if output is blocked |
| B | **Pre-filter only** | Bad prompts never reach the model (cost saving + reduces blast radius); single extra inference | Model output not vetted; subtle output failures (hallucinated PII, encoded bypass) ship to user |
| C | **Both** | Defense-in-depth; matches enterprise patterns | 2× LlamaGuard latency cost per request (~1s extra); more complex monitoring (which filter blocked?) |

**Decision**: **A — Post-filter only** (LlamaGuard 3-1B runs only on model output via `postFilter.llamaguard.enabled: true`; Iris built-in plugins handle the input side).
**Rationale**: Iris ships first-class jailbreak + PII plugins on the input path; running LlamaGuard there too would double the latency overhead with diminishing returns. FR-009 explicitly asks for LlamaGuard as a *post-filter*. Wired in Phase 5 with `onError: pass` (fail-open on guardrail timeout — better UX than blocking; tradeoff captured for SC-005 audit). Revisit if SC-005 or a security review reveals input-side gaps.
**Decided by**: Smana, 2026-04-29 (light SDD path — recommendation accepted in conversation).
**References**: FR-009 in spec.md; [LlamaGuard 3 NeMo Guardrails integration](https://docs.nvidia.com/nemo/guardrails/user_guides/advanced/llama-guard-deployment.html).

---

## CL-3 — 2026-04-26 — Model weight preload trigger: auto on first claim, or manual per-model Job?

**Asked by**: Spec author (Smana)
**Context**: Model weights (5–15 GB each) need to be in S3 before vLLM pods start, or the first request hits a 10-minute Hugging Face download. Two approaches: (1) the `XInferenceService` composition automatically renders a `model-preload` Job alongside the Deployment that runs once per `(model.repository, model.revision)` tuple, or (2) operators apply a `preload-job.yaml` manually before applying the claim.

**Options considered**:

| Option | Answer | Pros | Cons |
|--------|--------|------|------|
| A | **Auto Job rendered by composition** | One claim = one ready model, no operator memory needed; correct CR readiness (XR Ready=True only after preload Job complete) | Composition complexity grows; Job race conditions if two claims for same model land in same reconciliation |
| B | **Manual Job per model** | Explicit operator step prevents accidental large download (e.g., typo in `repository`); easier to audit | Adds a step to "deploy a new model" workflow; new model claims silently delay first response by 10 min if operator forgets |

**Decision**: *(pending /clarify; recommendation: **A — Auto Job rendered by composition**, because the platform's value is "one claim, one model" and composition can guard against race conditions via name-based deduplication. Add a hard cap on model size in the XRD (`model.maxSizeGB`) to defend against typos.)*
**Rationale**: *(to be written at decision time)*
**Decided by**: *(to be set during /clarify)*
**References**: T019 in plan.md; FR-011.

---

## CL-4 — 2026-04-26 — Promptfoo eval cadence: nightly only, or per Flux reconciliation of an `XInferenceService`?

**Asked by**: Spec author (Smana)
**Context**: Promptfoo runs an eval suite against the routing endpoint and emits Prometheus metrics. Two cadences: (1) nightly CronJob — predictable cost, captures gradual drift; or (2) trigger an eval Job on every Flux reconciliation that touches an `XInferenceService` — catches model swaps immediately, but burns GPU on no-op reconciliations.

**Options considered**:

| Option | Answer | Pros | Cons |
|--------|--------|------|------|
| A | **Nightly only** | Predictable cost (~$0.50/night with 50-prompt suite on warm GPU); deterministic baseline trend in dashboard | Up to 24h gap between bad change and detection; SC-008 alert may fire too late for a fast-revert workflow |
| B | **On every XR reconciliation** | Immediate feedback (regression caught within minutes); gates merges via PR check feedback loop | Many no-op reconciliations (GitOps refresh) → many redundant evals; cost spikes hard to predict; can wedge if eval blocks reconciliation |
| C | **Hybrid: nightly + on-PR-checkpoint** | Catches both gradual drift and per-change regression; bounded cost | Requires CI integration outside Flux; more moving parts |

**Decision**: **A — Nightly only** (`schedule: "0 2 * * *"`, Europe/Paris).
**Rationale**: Matches FR-008 ("nightly"). Predictable cost (~$0.50/night on warm GPUs), deterministic baseline trend, and the SC-008 1-hour alert window is acceptable for an internal platform where the team can revert in-day. CI eval gate (option C) is out of scope for v1 but cleanly addable later — Promptfoo Job manifest is reusable.
**Decided by**: Smana, 2026-04-30 (light SDD path — recommendation accepted in conversation).
**References**: FR-008 in spec.md; SC-007, SC-008.

---

## CL-5 — 2026-04-26 — Extend `App` XR with `gpu` field, or keep `App` CPU-only and require `XInferenceService` for any GPU workload?

**Asked by**: Spec author (Smana)
**Context**: The existing `App` XRD has no GPU support. We could add an optional `gpu` block to `App`, opening the door to non-inference GPU workloads (e.g., a CUDA-accelerated batch job using the `App` pattern). Or we keep the boundary clean: `App` is the CPU-stateless contract, `XInferenceService` is the inference contract, and any other GPU need gets its own composition.

**Options considered**:

| Option | Answer | Pros | Cons |
|--------|--------|------|------|
| A | **Keep `App` CPU-only** | Clear boundaries (`App` = web/API, `XInferenceService` = inference); no scope creep on `App` schema; simpler tests | If a GPU non-inference workload arrives later, we either build a third composition or stretch `XInferenceService` |
| B | **Extend `App` with optional `gpu` block** | One composition for any pod-shaped workload; future-proofs against general GPU jobs | `App` schema grows; ambiguous when to use `App` vs `XInferenceService`; constitution checklist becomes harder to enforce per-XR-type |

**Decision**: *(pending /clarify; recommendation: **A — Keep `App` CPU-only**, captured as a non-goal in spec.md. If a non-inference GPU workload appears, we propose a separate spec for it.)*
**Rationale**: *(to be written at decision time)*
**Decided by**: *(to be set during /clarify)*
**References**: Non-Goals section in spec.md; `App` composition at `infrastructure/base/crossplane/configuration/kcl/app/main.k`.

---

## CL-6 — 2026-04-26 — `gpu-l4` Karpenter NodePool capacity ceiling — what hard cap on `nvidia.com/gpu`?

**Asked by**: Spec author (Smana)
**Context**: Constitution mandates resource limits on every workload. The `default` NodePool is capped at `cpu=20, memory=64Gi`. Without a similar cap on the GPU NodePool, a runaway HPA or a typo in `scaling.maxReplicas` could land us with N idle G6 instances overnight. We need a defensible ceiling that allows the steady-state fleet (4 models × 1 replica = 4 GPUs) plus burst headroom.

**Options considered**:

| Option | Answer | Pros | Cons |
|--------|--------|------|------|
| A | **`nvidia.com/gpu: 4`** | Exactly the steady-state fleet; safest cost ceiling | No headroom for parallel scale-up across models during demo / load-test |
| B | **`nvidia.com/gpu: 8`** | 4 baseline + 4 burst (one extra replica per model under load) | Worst-case bill: 8 × g6.xlarge spot ≈ $2.60/hr ≈ $1,900/mo if pinned |
| C | **No cap, rely on per-`XInferenceService` `scaling.maxReplicas`** | Most flexible | Trusts every claim author; one bad value escapes the safety net |

**Decision**: **A — `nvidia.com/gpu: 4`** (overrides spec author's recommendation B).
**Rationale**: "Not deploy / for now" posture chooses safer cost ceiling. Steady-state fleet (4 models × 1 replica) exactly matches the cap, so the floor and ceiling are identical and any unscheduled GPU burst is *visible* (pending pods, no silent over-spend). Reconsideration trigger: first KEDA scale-up that fails to schedule due to NodePool cap → revisit to B (cap=8). Until then, the cost-bound is hard.

**2026-04-30 follow-up — known consequence**: With four claims at `maxReplicas` ≥ 2 and the cap at 4, the warm fleet at `minReplicas: 1` per claim already consumes the budget. Any KEDA-driven horizontal scale-up of one claim will cause Karpenter to refuse provisioning until another claim cools down. The platform's effective concurrency strategy is therefore **vertical** (vLLM batching + KV cache reuse on a single GPU), not horizontal pod scaling. Documented in `docs/ai.md` "GPU foundation > Cap math". Raise to B (cap=8) when traffic patterns show queue depth > 4 sustained across multiple models simultaneously.

**Decided by**: Smana, 2026-04-26 (light SDD path — in-conversation, no /clarify ceremony).
**References**: T002 in plan.md; existing `default-nodepool.yaml` cap pattern; constitution §"Resource limits".

---

## CL-7 — 2026-04-26 — VictoriaMetrics LLM observability lab patterns: adopt now, wait, or design from scratch?

**Asked by**: Spec author (Smana)
**Context**: Erythix shared a forthcoming "VictoriaMetrics as an LLM Observability Backend" lab (LinkedIn, 2026-04-26): VM Single + OTel Collector + vmagent + vmalert + Grafana, OTLP-instrumented FastAPI demo emitting LLM + RAG traces, pre-provisioned dashboard (4 rows × 14 panels), 8 recording rules ("10–100× query speedup"), 7 production alert rules (RAG drift, latency SLO, GPU saturation, daily budget, TTFT). Repo is unpublished — author says "a few days" and DM for early access. Phase 7 in our plan already scopes `VMServiceScrape` + 3 Grafana dashboards (`llm-platform-overview`, `llm-routing`, `llm-cost`) + `VMRule`s (queue depth, cold-start, error rate, $/hour) but has *not* designed the cardinality strategy for token histograms or the recording-rule layer — both known footguns for LLM metrics at any non-trivial scale.

**Options considered**:

| Option | Answer | Pros | Cons |
|--------|--------|------|------|
| A | **Wait for lab → adopt cardinality + recording rules into Phase 7** | One-time investment with multiplicative payoff; cardinality strategy is a known LLM footgun (token histograms blow up Prom); recording rules give 10–100× query speedup the dashboard will need from day one | Phase 7 partly blocked on external publication (~few days); need to filter lab content (RAG drift not relevant for v1, no RAG) |
| B | **Design Phase 7 from scratch using vLLM `/metrics` docs only** | Zero external dependency; ships now | Re-discovers cardinality limits the hard way (likely under first load test); recording rules likely retrofitted later under pressure |
| C | **Wait + extend scope** — pull in the lab's full alert catalog (incl. RAG drift) and OTel SDK instrumentation | Most complete observability story; positions the showcase repo as the canonical LLM-on-VM example | Scope creep on a paused initiative; RAG drift alert without RAG is dead code |

**Decision**: *(pending /clarify; recommendation: **A — Wait for lab + adopt patterns**, because token-histogram cardinality and recording rules are exactly the unscoped pieces in Phase 7 and the cost of getting them wrong is much higher than the few-day wait. The 4 alerts that align with our scope (latency SLO, TTFT, GPU saturation, daily budget) directly map to FR-007 / FR-008 / SC-007. Phase 7 is already last in the dependency chain, so this adds zero critical-path delay.)*
**Rationale**: *(to be written at decision time)*
**Decided by**: *(to be set during /clarify)*
**References**: Phase 7 in plan.md; FR-007, FR-008; SC-007; T009, T026–T030; Smaine LinkedIn share 2026-04-26 (Erythix lab, repo on request).

---

## CL-8 — 2026-04-26 — Model weight storage: stick with S3 + EPI, or self-host with rustfs?

**Asked by**: Spec author (Smana)
**Context**: The current plan uses S3 bucket `xplane-llm-models` (rendered by `App` XR `s3Bucket.enabled`) + `EPI` `xplane-llm-models-s3-read` for IAM, with weights cached to local NVMe on cold start and EBS-snapshot warmup baking them into the GPU AMI. So S3 is **cold-pull only**, not on the hot path. Alternative proposed: deploy `rustfs` (Rust-based S3-compatible distributed object store, MinIO alternative) in-cluster as the model registry, either replacing S3 or fronting it.

**Options considered**:

| Option | Answer | Pros | Cons |
|--------|--------|------|------|
| A | **S3 + EPI (current plan)** | Constitution-aligned (`xplane-*`, EPI XR, no hardcoded creds); reuses `App.s3Bucket.enabled` pattern; cold start solved by EBS snapshot warmup; warm read = local NVMe; S3 egress in-region is free | AWS dependency for model storage; weakens "fully self-hostable" narrative for the showcase repo |
| B | **rustfs in-cluster (replaces S3)** | Removes AWS dependency for the model layer; demonstrates a self-hosted object-storage path; potentially lower cold-pull latency over cluster network than S3 | New stateful workload to operate (PVC sizing, replication factor, backup story, its own `CiliumNetworkPolicy`, secret rotation, upgrades); rustfs is young — operational maturity unknown; need a new XRD or HelmRelease pattern; constitution checklist (no-deletion IAM, EPI scoping) doesn't map cleanly |
| C | **Hybrid** — S3 as system-of-record, rustfs as in-cluster cache/replica for faster cold pulls | Defence in depth; survives S3 outage; could speed cold pulls if the network case beats S3 | Two storage systems to keep consistent; adds complexity well beyond the v1 brief; cold pulls already infrequent (EBS-snapshot warmup covers most) |

**2026-04-29 follow-up research** (after Phase 4 + Phase 5 shipped with Option A):

- **rustfs project state**: v1.0.0-beta.1, Apache 2.0, claims 2.3× MinIO on 4KB payloads.
- **Single-node** mode is GA-ish; **distributed** mode is "Under Testing" — single-PVC failure = total data loss.
- **Auth**: static credentials (default `rustfsadmin/rustfsadmin`), OIDC, S3 IAM-style policies — **no Kubernetes Service Account binding** equivalent to EKS Pod Identity. Model pods would auth via static keys mounted from a Secret.
- **Persistence**: local PV; no stable distributed erasure coding yet.
- **Helm chart**: available; no Operator yet.
- **Demo value**: showcases self-hosted / portable storage but bypasses ADR-0002 (EKS Pod Identity over IRSA), the constitution's IAM rule.
- **Refactor cost from current state**: ~5 file changes (delete `apps/base/llm-platform/s3-bucket.yaml` + `preload-serviceaccount.yaml`, delete `security/base/epis/llm-models-preload.yaml`, add `infrastructure/base/rustfs/helmrelease.yaml` + PVC + Secret, rewrite InferenceService composition `main.k` to drop EPI render and switch init/preload containers from aws-cli + EPI to mc/rustfs-cli + static keys, regenerate XRD field semantics).

**Decision**: **A — S3 + EPI** (ratified 2026-04-29 after explicit rustfs reassessment). Phase 4/5 implementations stay as shipped (`apps/base/llm-platform/s3-bucket.yaml`, `security/base/epis/llm-models-preload.yaml`, per-claim read EPI rendered by InferenceService composition).
**Rationale**: Three load-bearing reasons. (1) **Constitution alignment** — ADR-0002 mandates EKS Pod Identity over static credentials; rustfs offers no Service-Account-bound auth today, so adopting it would force a regression to mounted static keys. (2) **Production maturity** — rustfs distributed mode is "Under Testing" (v1.0.0-beta.1); single-node is the only stable deployment, and that gives the model registry no replication / no backup story. (3) **Concrete benefit gap** — the agnostic-storage argument is correct in principle but only pays off with a non-AWS deployment target, which this repo does not have in flight. Refactor cost (~5 file changes + composition rewrite) is non-trivial for an unrealised benefit. **Trigger to reconsider B**: a multi-cluster / on-prem target appears, OR rustfs ships SA-bound auth + GA distributed mode, OR self-hosted storage is scoped as its own platform capability spec (not a substitution).
**Decided by**: Smana, 2026-04-29 (light SDD path; explicit reassessment in conversation, ratified A after research surfaced the constitution + maturity gaps).
**References**: T015 in plan.md; FR-011; ADR-0002 (EKS Pod Identity over IRSA); [rustfs README — current beta status](https://github.com/rustfs/rustfs); [rustfs S3 compatibility docs](https://docs.rustfs.com/features/s3-compatibility/); existing `App.s3Bucket.enabled` pattern; existing `EPI` XR.

> **2026-05-01 update — narrowed scope, not superseded**: CL-8 ratified the **storage layer** (S3 + EPI). The init-container `aws s3 sync` + emptyDir mechanism that consumed it lives in plan T013 / T019, not in this CL — see [CL-9](#cl-9--2026-05-01--how-do-pods-mount-the-s3-bucket-init-container-aws-s3-sync-vs-amazon-s3-files-vs-mountpoint-s3-csi) and [ADR-0004](../../decisions/0004-amazon-s3-files-for-model-weights-storage.md) for the mount-mechanism pivot. The S3 bucket + EPI ratification stand intact.

---

## CL-9 — 2026-05-01 — How do pods mount the S3 bucket: init-container `aws s3 sync`, vs Amazon S3 Files, vs Mountpoint-S3 CSI?

**Asked by**: Smana.

**Context**: First deploy of the original `aws s3 sync` + `emptyDir` staging mechanism surfaced four problems (cold-start budget regression, disk-pressure eviction, wasted bytes, source-of-truth duplication). Full analysis in [ADR-0004 § Context](../../decisions/0004-amazon-s3-files-for-model-weights-storage.md#context). Amazon S3 Files (AWS, April 2026, GA) provides a POSIX file-system view over the same bucket that eliminates the staging step.

**Options considered**: status quo `aws s3 sync` + `emptyDir`; Mountpoint for Amazon S3 (CSI); JuiceFS / s3fs / goofys; Amazon S3 Files. Full matrix in [ADR-0004 § Considered Options](../../decisions/0004-amazon-s3-files-for-model-weights-storage.md#considered-options).

**Decision**: **Amazon S3 Files** with bootstrap path **OpenTofu now → native Crossplane CRDs on Upbound `provider-upjet-aws` v2.6+**. Mountpoint for S3 (CSI) is the rollback target if `mmap` latency on safetensors proves problematic.

**Rationale**: Eliminates the four staging problems in one move; matches the cluster-ephemeral / bucket-as-durable intent; OpenTofu interim is consistent with how the rest of platform bootstrap (Network / OpenBao / EKS) runs; migration to native CRDs is a swap with zero composition change.

**Decided by**: Smana, 2026-05-01.

**References**: [ADR-0004 — Amazon S3 Files for LLM Model Weights Storage](../../decisions/0004-amazon-s3-files-for-model-weights-storage.md) (canonical home for context, options, consequences, implementation notes); CL-8 (storage layer, unchanged); spec FR-005, FR-011; SC-001, SC-002, SC-011; plan revision Phase 4a/4b.

---

## Related

- Constitution: [docs/specs/constitution.md](../constitution.md)
- ADRs: [docs/decisions/](../../decisions/)
- Spec: [spec.md](spec.md)
- Plan: [plan.md](plan.md)
