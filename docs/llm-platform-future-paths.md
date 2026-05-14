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
- AIGatewayRoute backendRef switches from the per-model
  `xplane-<name>` AIServiceBackend (current SPEC-001 direct-routing
  shape) to an `InferencePool` per opted-in model. Mixed routes are
  fine: leave low-traffic claims on direct AIServiceBackend, opt
  high-traffic claims into EPP at `max≥2`.

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

## 7. Per-tenant FinOps observability

Self-hosted LLM serving collapses the "infra cost vs. token cost"
boundary onto a single bill, which makes per-consumer accounting
structurally important. The 2026 framing (cardinality climbs faster
than on a regular service because every FinOps dimension wants to
be a label; volume scales with token throughput, not request rate;
alerting moves from "the service is down" to "tenant X exceeded
their hourly budget") describes the shape of the problem.

**Approach** (compatible with the foundation-showcase non-goal of
*no production multi-tenant serving*): tenant identity comes from
a static `x-tenant` request header (default `anonymous`). Envoy AI
Gateway extracts it via stats config and emits a `tenant` label on
its existing token counters. A new VMRule defines per-tenant
burn-rate alerts on
`sum by(tenant) (rate(envoy_ai_gateway_tokens_total[5m]))`. A new
Grafana dashboard panel set surfaces tokens-per-tenant,
cost-per-tenant (constant-times-tokens approximation), and
top-talker over time.

**Cost**: ~zero infra cost; the only meaningful overhead is metric
cardinality. Cap at ~10 tenants for the showcase via VMAgent
`metric_relabel_configs` allowlist.

**Trigger**: when any real (or simulated) workload routes through
the platform with multiple addressable consumers — including LoRA
adapter names (already shipped via the `loraAdapters` field on
`inference-service` v0.6.0+), used as proxy "tenants" to demo the
cost-attribution story without standing up auth.

**What this is *not***: tenant authentication, quotas, fairness
scheduling, or rate limiting. Those remain non-goals for this
platform's posture; doing them would warrant amending the
foundation-showcase spec, not this future-path entry.

---

## How to use this document

When picking up a session focused on "next iteration," read this
file first. Each path has a stated trigger — choose the one whose
trigger has actually fired, not the most ambitious one. Bigger
hardware does not always mean bigger value, especially in a
showcase context.

Updates to this document should land as PRs of their own (separate
from any path 1-7 implementation), so the future-paths catalog
evolves as the platform does.
