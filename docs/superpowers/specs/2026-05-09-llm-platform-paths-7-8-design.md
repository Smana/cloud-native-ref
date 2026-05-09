# LLM Platform — Paths 7 & 8 Design

**Status:** approved (brainstorming session 2026-05-09)
**Owner:** smana
**Repo:** `cloud-native-ref` @ branch `wip/self-hosted-llm-platform-draft` — added to PR #1434 (no separate PR)
**Branches affected:** `infrastructure/base/crossplane/configuration/kcl/inference-service/`, `apps/base/ai/llm/qwen-coder.yaml`, `tooling/base/promptfoo/eval-suite-configmap.yaml`, `clusters/mycluster-0-llm-platform/README.md`, `README.md`, `docs/llm-platform-future-paths.md`
**Sibling docs:** [`2026-05-06-oss-llm-foundation-showcase-design.md`](./2026-05-06-oss-llm-foundation-showcase-design.md) (the foundation this design extends)

## Why this design exists

A review of the current branch against five 2026 self-hosted-LLM articles surfaced two gaps relative to the foundation-showcase:

1. **Multi-adapter serving on one base** — the LinkedIn / KDnuggets framing of "self-hosted LLM is a cost-efficiency story when one base serves N specializations" is not yet demonstrated. Adding LoRA adapter serving on `xplane-qwen-coder` closes that gap with a small, well-bounded change.
2. **Per-tenant FinOps observability** — Sam Desseaux's framing (cardinality climbs faster than on regular services; volume scales with token throughput, not request rate; alerting moves from "service is down" to "tenant X exceeded budget") is absent from the catalog of future paths. A documentation-only entry surfaces the direction without expanding the foundation-showcase non-goals.

Both items reinforce the existing target ("self-hosted open-weights LLM, GitOps-deployed, demonstrably honest about scope") without amending the foundation-showcase non-goals (no production multi-tenant serving; no quotas; no auth; no in-cluster training).

## Scope split

| Path | Deliverable | Surface |
|---|---|---|
| **Path 7 — LoRA adapter serving** | Real ship: composition field, two HF-published adapters, AI Gateway routing, eval coverage, README docs | Code + manifests + docs |
| **Path 8 — Per-tenant FinOps observability** | Documentation-only future-path entry in `docs/llm-platform-future-paths.md` | Docs only |

Path 7 is shipped, so it does **not** go into `docs/llm-platform-future-paths.md` (that doc is for trajectory options, not delivered work). Only path 8 lands there. In `docs/llm-platform-future-paths.md`, path 8 takes the next free slot (path 7 in that document, since the existing list is paths 1–6).

## Goal & success criteria

**Goal.** Extend the foundation-showcase platform with (a) a real LoRA-adapter serving demonstration on `xplane-qwen-coder`, and (b) a documented future-direction paragraph for per-tenant FinOps observability.

### Path 7 success criteria

| ID | Criterion |
|---|---|
| SC-7.1 | `xplane-qwen-coder` claim accepts `loraAdapters: []` field; composition renders vLLM `--enable-lora --max-loras 2 --max-lora-rank 64 --lora-modules <name>=<path> ...` cleanly. Verified by `./scripts/validate-kcl-compositions.sh` exit 0. |
| SC-7.2 | Two HF-published adapters are downloaded by the extended preload Job into the existing S3 Files PVC at `/models/loras/<adapter-name>/`. Verified by `kubectl exec` ls into the PVC after first reconcile. |
| SC-7.3 | Both adapter names are addressable as separate model strings via the AI Gateway. `curl /v1/chat/completions` with `model: "<adapter-name>"` returns 200 and produces output materially different from the base model on a probe prompt. |
| SC-7.4 | Two new promptfoo eval entries (one per adapter) confirm each adapter alters output meaningfully. CronJob exits green. |
| SC-7.5 | No regression in cold-start budget on `xplane-qwen-coder` (foundation-showcase SC-2: ≤180s p95). Measured via promptfoo. |
| SC-7.6 | No regression in `xplane-qwen-coder-fim` latency (foundation-showcase SC-3: <200ms p95) — confirmed by NOT enabling `--enable-lora` on the FIM claim. |
| SC-7.7 | `clusters/mycluster-0-llm-platform/README.md` and main `README.md` updated with "How to invoke an adapter" example and adapter-vs-base comparison snippet. |
| SC-7.8 | Composition v0.6.0 backward-compatible: existing claims (`xplane-qwen3-8b`, `xplane-qwen-coder-fim`, `xplane-llamaguard3-1b`) render identically against `v0.6.0` with empty `loraAdapters`. Verified by `main_test.k` regression case + `kubeconform` on rendered manifests. |

### Path 8 success criterion

| ID | Criterion |
|---|---|
| SC-8.1 | New ~150-word entry added to `docs/llm-platform-future-paths.md` (as path 7 in that doc) covering: agentic-AI observability problem shape, tenant-tagging approach via `x-tenant` header at AI Gateway, budget alert + FinOps panels as future implementation work, trigger condition, explicit non-amendment of the foundation-showcase non-goals. No code, no manifests. |

## Non-goals (no change to foundation-showcase non-goals)

- No tenant authentication, quotas, fairness, or global rate limiting (path 8 stays documentation-only).
- No in-cluster LoRA training pipeline.
- No LoRA hot-swap admin endpoint exposure (declarative-only management; admin endpoint stays unreachable).
- No LoRA on the FIM, Qwen3-8B, or LlamaGuard claims.
- No new region split, NodePool, or GPU SKU.

## Architecture (path 7)

One claim, two adapters, one preload Job, one vLLM pod, two new AI Gateway routes. No new infrastructure, no new CRDs, no new managed resources from Crossplane.

### Composition API change

New optional field in the `inference-service` claim spec, sibling to `model:` and `gpu:`:

```yaml
loraAdapters:
  - name: qwen-coder-sql        # the model name clients send via /v1/chat/completions `model:`
    repository: <hf-org>/<repo> # HF repo id (selected during implementation)
    revision: main              # optional, defaults to main
  - name: qwen-coder-style-x
    repository: <hf-org>/<repo>
```

Empty/absent list = no LoRA enabled (current behavior, no regression for existing claims).

KCL composition rules — must comply with `.claude/rules/kcl-crossplane.md`:

- If `loraAdapters` is non-empty: emit `--enable-lora --max-loras <len> --max-lora-rank 64 --lora-modules <name1>=<path1> ...` into vLLM args via inline conditional. **No dict mutation** (function-kcl issue #285).
- One preload-Job step per adapter: `huggingface-cli download <repo> --local-dir /models/loras/<name>`. Single-line list comprehension (CI strict).
- For each adapter, emit one AIGatewayRoute matchRule routing `model: <name>` requests to the same `xplane-qwen-coder` AIServiceBackend as the base. Loop variable rename pattern (avoid the dict-comprehension shadowing trap).

Composition version: `v0.5.x` → `v0.6.0`. Source URL gets PR-suffixed tag during dev (`-pr1434` matching the existing pattern), stripped pre-merge.

### Storage layout (existing S3 Files PVC, unchanged shape)

```
/models/
  Qwen/Qwen2.5-Coder-7B-Instruct/        # base model (unchanged)
  loras/
    qwen-coder-sql/
      adapter_model.safetensors
      adapter_config.json
    qwen-coder-style-x/
      adapter_model.safetensors
      adapter_config.json
```

The preload Job already pulls the base from HF into S3 Files; we extend its bash loop to also iterate `loraAdapters`. Idempotency: existing fast-path-guard pattern (skip when `adapter_model.safetensors` is present and not `.incomplete`) applies unchanged.

### vLLM serving pod

Single L4, single base in VRAM, two adapters loaded on top. Defaults:

- `--max-loras 2` — both adapters can be active simultaneously per request batch.
- `--max-lora-rank 64` — covers rank-32/rank-64 majority of published adapters; bump at implementation time only if a chosen adapter exceeds it.
- Base quantization stays `fp8`. **Pre-implementation check:** confirm pinned vLLM is ≥ 0.7.0 (LoRA + fp8 base path stabilized there). If pinned version is older, bump in the same PR.

### AI Gateway routing

Two new AIGatewayRoute matchRules, one per adapter, each pointing to the existing `xplane-qwen-coder` AIServiceBackend. AI Gateway resolves routing by the `x-ai-eg-model` header (set from the request body's `model:` field by AI Gateway's pre-router). vLLM does the adapter dispatch internally based on the `model:` value.

### What does NOT change

- **CiliumNetworkPolicy**: no new external egress at runtime — adapters land on PVC at preload time, vLLM never reaches HF Hub once running. Preload Job's existing HF egress allow-list applies.
- **KEDA scaling** on `xplane-qwen-coder`: unchanged. `min=0`, `max=1`, prometheus trigger on `running/max-num-seqs` ratio + KV-cache util.
- **FIM claim**: untouched. Latency budget intact.
- **LlamaGuard, Qwen3-8B**: untouched.
- **Crossplane RBAC / `ManagedResourceActivationPolicy`**: no new MR Kinds, no new aggregate ClusterRole, no policy change.
- **Existing promptfoo eval suite**: only adds 2 new entries; existing tests stay.

## Path 8 — paragraph draft (to be appended to `docs/llm-platform-future-paths.md`)

> ## 7. Per-tenant FinOps observability
>
> Self-hosted LLM serving collapses the "infra cost vs. token cost" boundary onto a single bill, which makes per-consumer accounting structurally important. The 2026 framing (cardinality climbs faster than on a regular service because every FinOps dimension wants to be a label; volume scales with token throughput, not request rate; alerting moves from "the service is down" to "tenant X exceeded their hourly budget") describes the shape of the problem.
>
> **Approach** (compatible with the foundation-showcase non-goal of *no production multi-tenant serving*): tenant identity comes from a static `x-tenant` request header (default `anonymous`). Envoy AI Gateway extracts it via stats config and emits a `tenant` label on its existing token counters. A new VMRule defines per-tenant burn-rate alerts on `sum by(tenant) (rate(envoy_ai_gateway_tokens_total[5m]))`. A new Grafana dashboard panel set surfaces tokens-per-tenant, cost-per-tenant (constant-times-tokens approximation), and top-talker over time.
>
> **Cost**: ~zero infra cost; the only meaningful overhead is metric cardinality. Cap at ~10 tenants for the showcase via VMAgent `metric_relabel_configs` allowlist.
>
> **Trigger**: when any real (or simulated) workload routes through the platform with multiple addressable consumers — including LoRA adapter names (already shipped via the `loraAdapters` field on `inference-service`), used as proxy "tenants" to demo the cost-attribution story without standing up auth.
>
> **What this is *not***: tenant authentication, quotas, fairness scheduling, or rate limiting. Those remain non-goals for this platform's posture; doing them would warrant amending the foundation-showcase spec, not this future-path entry.

(Path 8 is delivered as the literal text above committed into `docs/llm-platform-future-paths.md`. Path number in that doc is the next free slot — currently 7, since the existing list is 1–6.)

## Implementation outline (sketch — full plan from `superpowers:writing-plans`)

**A. Composition (`infrastructure/base/crossplane/configuration/kcl/inference-service/`)**

1. Add `loraAdapters: [LoraAdapter]` field to the input schema with `LoraAdapter = {name: str, repository: str, revision?: str}`.
2. Inline-conditional vLLM args for `--enable-lora --max-loras --max-lora-rank --lora-modules`.
3. Inline-conditional preload-Job extension for per-adapter `huggingface-cli download`.
4. Per-adapter AIGatewayRoute matchRule emission.
5. `main_test.k` regression cases: empty list (current behavior unchanged), 1-adapter, 2-adapter.
6. Bump `kcl.mod` version to `0.6.0`. PR uses `0.6.0-pr1434`; pre-merge cleanup strips suffix.

**B. Claim spec (`apps/base/ai/llm/qwen-coder.yaml`)**

- Add `loraAdapters: [...]` with the two selected HF repositories.
- Bump composition source URL to `0.6.0-pr1434`.

**C. vLLM version verification**

- Inspect Helm chart values / image tag in the composition. Confirm vLLM ≥ 0.7.0 for fp8+LoRA. Bump if needed (one-line change, separate commit for clarity).

**D. Eval (`tooling/base/promptfoo/eval-suite-configmap.yaml`)**

- Two new test entries hitting `model: <adapter-name>`. Probe prompts that produce demonstrably different output from the base.

**E. Docs**

- `clusters/mycluster-0-llm-platform/README.md`: section "Invoking a LoRA adapter" with `curl` example.
- Main `README.md` LLM Platform bullet: one-line mention.
- `docs/llm-platform-future-paths.md`: append the path 8 paragraph (above) as the next numbered entry.

**F. Validation gates** (per repo `.claude/rules/process.md`)

- `./scripts/validate-kcl-compositions.sh` → exit 0
- `kubeconform` on rendered manifests
- `kcl fmt` clean (CI-strict)
- `trivy config` clean
- Composition v0.6.0 regression: existing claims render identically with empty `loraAdapters`
- promptfoo CronJob green post-deploy
- AI Gateway routing manually verified with `curl` (probe `model: <adapter-name>` returns 200 + meaningful output)

## Risks & open questions

1. **HF availability of two suitable adapters over `Qwen/Qwen2.5-Coder-7B-Instruct`.** Search at implementation time. If only 1 found, ship 1 and flag the second slot in the spec; small synthetic LoRA only as last resort.
2. **vLLM pinned version.** Confirm ≥ 0.7.0 supports fp8 base + LoRA without regressions. If pinned is older, bump in the same PR.
3. **Cold-start budget impact.** Adapter download adds ~30s to preload (assuming <500MB per adapter). Existing budget is 180s p95 — acceptable headroom.
4. **Adapter rank > 64.** If a chosen HF adapter has rank 128 or 256, `--max-lora-rank` needs the bump and we pay the VRAM overhead. Verify at selection time.

## Quality gates the PR must pass before merge

- All Path 7 SCs (SC-7.1 through SC-7.8)
- Path 8 SC (SC-8.1)
- Foundation-showcase SCs preserved (notably SC-2 cold-start, SC-3 FIM latency, SC-6 architecture-fits-one-slide — composition stays well under the 4-HelmRelease ceiling)
- No new CiliumNetworkPolicy regressions
- Composition source URL stripped of `-pr1434` suffix pre-merge
