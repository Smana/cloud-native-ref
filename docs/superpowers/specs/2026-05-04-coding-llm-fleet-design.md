# Coding-LLM Fleet — design

**Status:** approved (brainstorming session 2026-05-04, conversation context preserved in agent memory)
**Owner:** smana
**Repo:** cloud-native-ref @ branch `wip/self-hosted-llm-platform-draft`
**Branches affected:** `apps/base/ai/llm/`, `infrastructure/base/vllm-semantic-router/`, `infrastructure/base/llm-ai-gateway/`

## Why this design exists

The current LLM-platform fleet (Phi-4 Mini, Qwen3-8B, DeepSeek-R1-Distill-Qwen-7B, LlamaGuard 3-1B) was built when the use case was "general assistant + safety post-filter, with cascade routing as the v1 demonstration." The owner's actual primary workload is **coding** — specifically:

- VSCode + Continue extension's **inline FIM tab-completion** (sub-100ms, always warm)
- Terminal-based agentic CLI: **OpenCode** (native OpenAI-compat) and Claude Code (deferred — needs OpenAI↔Anthropic translator)
- OpenWebUI chat for **non-coding general questions** (still wanted as a first-class secondary use)

The current fleet does not adequately serve this:

- **DeepSeek-R1-Distill-Qwen-7B** is a *reasoning* distill — strong at debugging logic, weaker at code generation than dedicated code models. Doesn't reliably support function calling, which agentic CLIs need.
- **No FIM-tuned model** in the fleet — Continue's autocomplete config has nothing to point at, so tab-complete falls back to chat completions and feels sluggish.
- **`MoM`-only `/v1/models`** — clients can't pick a specific model, so cmdline tools can't bypass the SR classifier even when they already know the workload is code.

## Architecture

```
                           ┌─ OpenCode CLI ─────────┐
   Developer ─────────────┤                        │  model: xplane-qwen-coder
                           ├─ Continue VSCode chat ─┤  (explicit, bypasses MoM)
                           │                        │
                           ├─ Continue VSCode tab ──┤  model: xplane-qwen-coder-fim
                           │  (FIM autocomplete)    │  (explicit, FIM endpoint)
                           │                        │
                           └─ OpenWebUI chat ───────┘  model: MoM
                                    │                   (SR auto-routes by domain)
                                    │
                            HTTPRoute (Tailscale)
                                    │
                                    ▼
              ┌──────────────────────────────────────┐
              │   llm-router Service (Cilium CEC)    │
              │   ext_proc → SR (classifies, sets    │
              │   selected model, rewrites body)     │
              └──────────────┬───────────────────────┘
                             │
                             ▼ (single catch-all cluster, body's
                                model: field decides upstream)
        ┌────────────┬───────┼───────┬─────────────┬──────────────┐
        ▼            ▼       ▼       ▼             ▼              ▼
   xplane-qwen-  xplane-   xplane-  xplane-      LlamaGuard
   coder-fim     qwen-     phi4-    qwen3-8b     3-1B
   1.5B Base     coder     mini                  (input
   FIM-tuned     7B Inst   3.8B     8B Inst       guardrail
   ALWAYS WARM   fn-call    small    multi-       via SR
                            generic  lingual /     prompt_guard,
                                     reasoning     not category-
                                                   routed)
   ──── warm ────  ──────── scale-to-zero, KEDA queue triggers ────────
```

## Fleet specification

| Claim | Model | Role | Replicas |
|---|---|---|---|
| **`xplane-qwen-coder-fim`** | `Qwen/Qwen2.5-Coder-1.5B-Base` | FIM tab-completion (Continue inline). Always warm; latency-sensitive. | min=1 max=1, no scale-to-zero |
| **`xplane-qwen-coder`** | `Qwen/Qwen2.5-Coder-7B-Instruct` | Code chat + agentic edits (OpenCode, Continue chat, OpenWebUI when SR routes `code`). Function calling. | **min=1** max=2, scale-up via queue depth 4 |
| `xplane-phi4-mini` | `microsoft/Phi-4-mini-instruct` (kept) | General fallback for short non-code chat. | min=0 max=2 |
| **`xplane-qwen3-8b`** | `Qwen/Qwen3-8B` (kept) | Multilingual + 32k context + math/reasoning + general chat default for OpenWebUI. | **min=1** max=2 |
| `xplane-llamaguard3-1b` | `meta-llama/Llama-Guard-3-1B` (kept) | Input-side jailbreak guardrail via SR `prompt_guard`. | min=0 max=3 |

> **Why three models min=1, not just qwen-coder-fim.** KEDA's prometheus
> trigger reads vLLM's runtime metrics — with min=0 there is no pod, no
> metric, no scale signal. Models pinned at `min=1` cover the always-on
> entry surfaces (FIM tab-completion, OpenWebUI chat default, OpenCode
> code agent). The two scale-to-zero claims (`phi4-mini`,
> `llamaguard3-1b`) are reached only when a warm peer is already
> serving (cascade fallback or jailbreak guardrail invocation), so
> their cold-start manifests as latency rather than 503. A future HTTP-
> queue scaler (KEDA HTTP add-on) would unblock true scale-from-zero on
> first request and let phi4-mini revert to min=0.

**Dropped:** `xplane-deepseek-r1-distill-qwen3-8b` — its math/reasoning role moves to Qwen3-8B (good math benchmarks); its code role moves to Qwen2.5-Coder-7B-Instruct (purpose-built for code).

**GPU budget vs the existing `gpu-l4` NodePool cap of `nvidia.com/gpu: 4`:**

- 3 always-warm GPUs: `qwen-coder-fim` (FIM), `qwen3-8b` (chat default),
  `qwen-coder` (code cascade target + OpenCode primary).
- 0–1 elastic GPU for `phi4-mini` / `llamaguard3-1b` bursts.
- Solo workload = baseline 3 GPUs, peaks at 4 (cap).

## Routing rules

### Client-side (deterministic — bypasses SR)

- **OpenCode CLI** → `OPENAI_API_BASE_URL=http://llm-router.llm.svc.cluster.local/v1`, `OPENAI_API_KEY=anything`, `model=xplane-qwen-coder`. The CLI knows the workload is code, no need to round-trip through the classifier.
- **Continue VSCode `chat` profile** → `model: xplane-qwen-coder`.
- **Continue VSCode `autocomplete` profile** → `model: xplane-qwen-coder-fim` with `template: qwen` (Continue knows the FIM tokens for that family).

### SR cascade (only the OpenWebUI `MoM` path)

```yaml
# Domain metadata, mapped from MMLU-Pro labels emitted by the LoRA classifier.
categories:
  - {name: code,       mmlu_categories: [computer science, engineering]}
  - {name: math,       mmlu_categories: [math]}
  - {name: physics,    mmlu_categories: [physics]}
  - {name: multilingual, mmlu_categories: [philosophy, law]}
  - {name: other,      mmlu_categories: [business, psychology, biology,
                                         chemistry, history, other,
                                         health, economics]}

# Signal fusion: keyword + context-length signals widen domain coverage.
# Catches code prompts that the MMLU classifier mis-routes (slang like
# "stack trace" / "refactor"), and bumps long prompts (>500 tokens) onto
# reasoning when the topic also feels code-y.
signals:
  keyword_rules:
    - name: code_keywords        # OR over coder-vocabulary tokens
      operator: OR
      keywords: [debug, refactor, "stack trace", traceback, compile, ...]
    - name: reasoning_keywords   # signals an "explain the why" prompt
      operator: OR
      keywords: [explain, why, prove, "trade-off", compare, ...]
  context_rules:
    - name: long_query           # >500 tokens of input ⇒ likely complex
      min_tokens: 500
      max_tokens: 32000

# First-match-wins. modelRefs[0].model = served-name SR rewrites into body.
decisions:
  - name: code_with_reasoning     # priority 110 — code AND (reasoning OR long)
    rules:
      operator: AND
      conditions:
        - operator: OR
          conditions:
            - {type: domain,  name: code}
            - {type: keyword, name: code_keywords}
        - operator: OR
          conditions:
            - {type: keyword, name: reasoning_keywords}
            - {type: context, name: long_query}
    modelRefs: [{model: xplane-qwen-coder, use_reasoning: true}]

  - name: code_decision           # priority 100 — fast path: code, no reasoning
    rules:
      operator: OR
      conditions:
        - {type: domain,  name: code}
        - {type: keyword, name: code_keywords}
    modelRefs: [{model: xplane-qwen-coder, use_reasoning: false}]

  - name: reasoning_decision      # priority 90
    rules: {operator: OR, conditions: [{type: domain, name: math},
                                       {type: domain, name: physics}]}
    modelRefs: [{model: xplane-qwen3-8b, use_reasoning: true}]

  - name: multilingual_decision   # priority 80
    rules: {operator: OR, conditions: [{type: domain, name: multilingual}]}
    modelRefs: [{model: xplane-qwen3-8b, use_reasoning: false}]

  - name: general_decision        # priority 50
    rules: {operator: OR, conditions: [{type: domain, name: other}]}
    # Was xplane-phi4-mini; remapped to qwen3-8b because phi4-mini
    # stays scale-to-zero (KEDA prometheus trigger can't scale from 0)
    # and qwen3-8b is always-warm. Restore phi4-mini once an HTTP-queue
    # scaler unblocks scale-from-zero.
    modelRefs: [{model: xplane-qwen3-8b, use_reasoning: false}]
```

**Why signal fusion**: the LoRA MMLU classifier only sees the prompt's *topic*, not its *vocabulary* or *length*. A user asking "can you refactor this regex?" lands in `other` because nothing about the surface looks like the academic CS papers MMLU was trained on — but `code_keywords` catches it. Similarly a 1500-token "walk me through this stack trace" prompt benefits from the reasoning toggle even when the domain classifier is unsure. Fusion lifts coverage on the long tail without rewriting the classifier.

**LlamaGuard runs in the request-prelude as the `prompt_guard` jailbreak classifier (ModernBERT-based) — not category-routed.**

### Exposing individual models in `/v1/models`

```yaml
router:
  auto_model_name: MoM
  include_config_models_in_list: true   # NEW
```

OpenWebUI's model picker now shows: `MoM` (auto), `xplane-qwen-coder`, `xplane-qwen-coder-fim`, `xplane-phi4-mini`, `xplane-qwen3-8b`. The owner can pick `xplane-qwen-coder` directly when they know it's a coding session.

## OpenCode as experimental TUI client

The agentic-CLI workload introduced in §1 is exercised by **OpenCode** as a secondary, occasional-use client of the self-hosted fleet. **Claude Code remains the primary daily-driver agent** — OpenCode is coexistence, not replacement, and serves as a real-workload validator for SR cascade routing + per-subagent model dispatch.

OpenCode publishes an explicit Claude Code compatibility shim and ships near-isomorphic primitives (`AGENTS.md` ≈ `CLAUDE.md`, `agent/` ≈ subagents, `command/` ≈ slash commands, per-agent MCP scoping). The full setup design lives in the standalone [`Smana/opencode-config`](https://github.com/Smana/opencode-config) repo (`docs/2026-05-05-opencode-migration-design.md`). This branch only documents the **role** OpenCode plays in the platform.

**Per-subagent model assignment** is the new lever the SR cascade fleet unlocks:

| OpenCode role | Model | Why |
|---|---|---|
| Primary `build` agent | `xplane-qwen-coder` | Strongest 7B code, native tool calls, always-warm |
| `plan` (planning mode) | `xplane-qwen3-8b` | Reasoning + 32k context for long specs |
| `Explore` subagent (read-only greps) | `xplane-phi4-mini` | Cheap one-shot reads; scale-from-zero acceptable |
| `kcl-developer` subagent | `xplane-qwen-coder` | KCL = code |
| `kubernetes-reviewer` / `security-reviewer` / `code-reviewer` | `xplane-qwen3-8b` | Long YAML + reasoning |
| `MoM` (auto-routed) | SR cascade decides | Used when the user types in chat without picking a subagent |

This is the leverage moment for the fleet: instead of one model per workload, OpenCode's primary agent and each subagent are pinned to the right-sized model, and the always-warm `xplane-qwen-coder` carries the hot-path coding traffic.

**Why OpenCode over alternatives:** Aider has no MCP support; Codex CLI has higher migration cost (no Claude Code compat shim); Goose recipes are powerful but a different paradigm than skills. OpenCode's explicit Claude Code compat — *"existing CLAUDE.md files and skill directories serve as fallbacks"* — drove the choice.

## Cost & operational notes

- **Marginal cost** vs current setup = +1 always-warm GPU (FIM):
  - `g6.2xlarge` on-demand eu-west-3 ≈ **$800/month**
  - Spot (with cold-start tolerance during reclaim) ≈ **$300/month**
- All other claims are scale-to-zero — they cost ≈ $0 while idle.
- Total stack ballpark with FIM on spot: **$700–900/month** (cluster + GPU + storage + network).
- Compared to GitHub Copilot Business at $19/seat/mo, this is ~35–50× more expensive — paid for in sovereignty, no telemetry, custom routing, platform-engineering reference.

**Cost lever options (defer until proven needed):**

1. `scaleToZeroIdleSeconds: 14400` (4h) on the FIM claim — warm during workday, cold overnight, ~30s morning cold-start. Saves ~30% of the always-warm cost.
2. Drop `xplane-qwen3-8b` if multilingual + 32k context aren't actually used. No cost savings (scale-to-zero), but frees a GPU slot.
3. Bump FIM to `Qwen2.5-Coder-3B-Base` only if 1.5B's quality is found wanting in practice.

## Operational concerns

**Cold-start budget:** the FIM claim must be warm. The other 4 claims have a documented ~90s cold-start budget (FR-005 in the parent SDD spec); not a UX concern for chat workloads but blocking for FIM, which is why FIM is the only `min=1`.

**Karpenter consolidation eviction:** `karpenter.sh/do-not-disrupt: "true"` is set on the SR pod template (commit `bb3cdc98`). Same annotation needs to be set on the FIM claim once it exists — Karpenter's "Underutilized" eviction during quiet typing periods would cause a 30-90s PVC re-attach and break the tab-complete UX.

**ext_proc cold-connect 404 (task #78):** the first request after a cilium-envoy CDS update or long idle hits a transient gRPC stream "protocol error"; SR's body rewrite is skipped and vLLM 404s. Subsequent requests succeed. Workaround for users today: retry. Long-term fixes are tracked in #78. *This affects the SR-routed `MoM` path only — clients picking models explicitly bypass ext_proc body modification (they send the right `model` field already), so OpenCode and Continue do not see this issue.*

**InferenceService CNP per-claim override (task #76):** the new `xplane-qwen-coder` and `xplane-qwen-coder-fim` claims need the same OpenWebUI cross-namespace allow as the existing 4 (commit `c73d1e36`).

**HuggingFace gated models:** Qwen2.5-Coder is Apache 2.0, no gated access needed. The existing `hf-token` secret stays in place for LlamaGuard 3-1B (gated).

## Out of scope / explicit non-goals

- **Claude Code** integration (Anthropic API ≠ OpenAI API). Deferred — needs an OpenAI↔Anthropic translator (`claude-relay-server`, `claude-bridge`, etc.). Filed as follow-up.
- **Codestral** (gated by Mistral commercial license).
- **DeepSeek-Coder-V2-Lite** (~31Gi VRAM at fp8, doesn't fit on L4).
- **AutoMix selector** (the "is the small model confident?" reflective router from `vllm-semantic-router`'s research mode). Defer until we have telemetry showing the cascade is misrouting in measurable ways.
- **GitHub Copilot–style request volume tier-2 caching/batching.** Solo dev = unnecessary.
- **Security context advanced (SPIFFE/SPIRE for IDE auth).** Tailscale ACL on the gateway HTTPRoute is the boundary.

## Implementation steps (high-level — detail in writing-plans)

1. **Apps layer:** rename `apps/base/ai/llm/deepseek-r1-distill-qwen3-8b.yaml` → `qwen-coder.yaml`, swap `model.repository` to `Qwen/Qwen2.5-Coder-7B-Instruct`. Add new `apps/base/ai/llm/qwen-coder-fim.yaml` for the FIM Base model with `min=1`, `do-not-disrupt`. Update `apps/base/ai/llm/kustomization.yaml`.
2. **Routing:** rewrite SR HelmRelease `decisions[]` so `code → xplane-qwen-coder`, `math/physics → xplane-qwen3-8b` (taking over DeepSeek's slot), `multilingual → qwen3-8b`, `other → phi4-mini`. Add `router.include_config_models_in_list: true`. Wire keyword + context-length signal fusion (commit `7cb8d30e`): `code_keywords` + `reasoning_keywords` keyword rules + `long_query` context rule, plus a priority-110 `code_with_reasoning` decision that ORs domain/keyword on the left and keyword/context on the right.
3. **CNP:** the InferenceService composition's `_defaultIngress` already covers the new claims (it's based on Service name selectors); the per-claim `networkPolicies.ingress` overrides need to be replicated for the two new claims.
4. **Preload:** the existing preload-Job pattern handles the model download from HF → S3 Files. Two new claims = two new preload Jobs. Same `xplane-llm-models-preload` SA.
5. **Client docs:** add `docs/coding-clients.md` with copy-paste config snippets for OpenCode + Continue (chat profile + autocomplete profile).

## Acceptance

This design is shipped when:

- A fresh chat in OpenWebUI with `model: MoM` auto-selects `xplane-qwen-coder` for a code-y prompt (verified via `x-vsr-selected-model` response header).
- Continue's tab-complete in VSCode produces inline suggestions in <200ms p95 over 100 keystrokes.
- OpenCode CLI completes a "implement this function" task end-to-end against `model: xplane-qwen-coder`, with successful tool-call execution.
- All 5 claims are visible in `GET /v1/models`.
- Kill the FIM pod manually — verify Karpenter does not consolidate the GPU node away during a 5-minute test window.
- Total p95 cost over a 30-day window matches the projected $700–900 envelope (or surface a clear deviation reason).
