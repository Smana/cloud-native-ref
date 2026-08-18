# Coding-LLM Fleet — implementation plan

Companion to `2026-05-04-coding-llm-fleet-design.md`. Concrete, ordered steps, each with the file paths touched and the verification command.

## Status (as of 2026-05-04 destroy boundary)

| Phase | Status | Where |
|---|---|---|
| **1.** Swap DeepSeek → Qwen2.5-Coder-7B-Instruct | ✅ shipped | commit `79395495` |
| **2.** Add Qwen2.5-Coder-1.5B-Base FIM claim | ✅ shipped | commit `79395495` (+ NodePool `consolidationPolicy: WhenEmpty` in same commit because the InferenceService composition v0.3.2-pr1434 doesn't expose pod-template annotations — see plan body for the substitution) |
| **3.** SR routing rewrite (cascade decisions[]) | ✅ shipped | commit `33aaf657` |
| **3b.** SR signal-fusion (keyword + context-length signals + `code_with_reasoning` decision @ priority 110) | ✅ shipped | commit `7cb8d30e` |
| **4.** Client config docs (`docs/coding-clients.md`) | ✅ shipped | commit `33aaf657` |
| **5.** Smoke tests (cascade routing + FIM + Karpenter pinning + signal-fusion) | ⏳ pending — needs deployed cluster | post-redeploy |
| **6.** Cleanup old DeepSeek weights from S3 | ⏳ pending | post-redeploy `aws s3 rm` |
| **7.** Composition republish + drop per-claim CNP overrides (task #76) | ⏳ pending — needs `crossplane-modules.yml` workflow run on `main` | follow-up PR |
| **8.** OpenCode adoption (experimental secondary TUI client; CC stays primary) | ⏳ pending | follow-on PR — design at `Smana/opencode-config:docs/2026-05-05-opencode-migration-design.md` |

The cluster was destroyed at the end of the brainstorming session; the
file-level changes (Phases 1-4) are committed and survive on Git.
Phases 5-6 require a redeployed cluster to run; Phase 7 is a separate
infrastructure follow-up.

## Pre-conditions

- Cluster freshly redeployed (post `terramate script run --reverse destroy`).
- `TM_LLM_PLATFORM_ENABLED=true` set during the redeploy so the `opentofu/llm-platform` stack runs (filesystem + IAM + Pod Identity bindings).
- `flux resume kustomization llm-platform -n flux-system` to lift the umbrella suspend.
- Hugging Face token at `/platform/llm/hf_token` in AWS Secrets Manager (already in place from previous deployment — only needed for LlamaGuard 3-1B which is gated).

## Phase 1: replace DeepSeek-R1-Distill with Qwen2.5-Coder-7B-Instruct

### Step 1.1 — rename the claim manifest

```bash
git mv apps/base/ai/llm/deepseek-r1-distill-qwen3-8b.yaml \
       apps/base/ai/llm/qwen-coder.yaml
```

### Step 1.2 — rewrite the manifest body

`apps/base/ai/llm/qwen-coder.yaml`:
- `metadata.name`: `xplane-qwen-coder`
- `model.repository`: `Qwen/Qwen2.5-Coder-7B-Instruct`
- `model.revision`: `main`
- `model.quantization`: `fp8`
- `model.contextWindow`: `32768` (start here; bump to 128k via `--rope-scaling` later if needed)
- `routing.tier`: `medium`
- `routing.specialty`: `code`
- `scaling.minReplicas`: `1` (was `0`; pinned warm because KEDA's prometheus trigger can't scale-from-zero — primary OpenCode coder + SR `code_decision` cascade target), `maxReplicas`: `2`, `scaleUpQueueDepthThreshold`: `4`
- `cache.kvOffload.enabled`: `true`, `cache.kvOffload.sizeGB`: `16`
- `cache.prefixCache.enabled`: `true`
- `envFromSecrets`: keep `[hf-token]`
- Per-claim `networkPolicies.ingress` override (mirroring the pattern in commit `c73d1e36`) — same set of `fromEndpoints` plus the `xplane-openwebui`/`apps` rule.

### Step 1.3 — kustomize wiring

`apps/base/ai/llm/kustomization.yaml`:
- Replace `deepseek-r1-distill-qwen3-8b.yaml` with `qwen-coder.yaml` in the `resources:` list.

### Step 1.4 — verify the Crossplane composition still renders

```bash
kustomize build apps/base/ai/llm | kubeconform -summary -output text
./scripts/validate-kcl-compositions.sh inference-service
```

## Phase 2: add the FIM tab-completion claim

### Step 2.1 — new claim manifest

`apps/base/ai/llm/qwen-coder-fim.yaml` — a new InferenceService:
- `metadata.name`: `xplane-qwen-coder-fim`
- `model.repository`: `Qwen/Qwen2.5-Coder-1.5B-Base` *(Base, not Instruct — FIM tokens trained in)*
- `model.quantization`: `fp8`
- `model.contextWindow`: `8192` (FIM context windows are short; saves VRAM)
- `routing.tier`: `small`
- `routing.specialty`: `code-fim`
- **`scaling.minReplicas`: `1`** *(always-warm)* `maxReplicas`: `1`
- `cache.prefixCache.enabled`: `true` (huge wins on FIM — every keystroke shares the file prefix)
- `envFromSecrets`: `[hf-token]`
- **Pod-template annotation** `karpenter.sh/do-not-disrupt: "true"` to defend against Karpenter consolidation eviction (see commit `bb3cdc98` for the SR pod equivalent rationale)
- Per-claim `networkPolicies.ingress` override — Continue (running as a VSCode extension, talks via Tailscale to the gateway) reaches this claim through the same `MoM` Service. The CNP allow-list mirrors the other claims.

### Step 2.2 — kustomize wiring

`apps/base/ai/llm/kustomization.yaml` — add `qwen-coder-fim.yaml` to `resources:`.

### Step 2.3 — verify GPU budget is not over the cap

```bash
kubectl get nodepool gpu-l4 -o jsonpath='{.spec.limits}'
# expects "nvidia.com/gpu": "4"
```

Final fleet = 5 claims, **3 always warm** (qwen-coder-fim, qwen3-8b, qwen-coder) + up to 1 elastic (phi4-mini or llamaguard3-1b on burst). Budget OK against the 4-GPU cap. The 3-warm baseline was forced by the KEDA prometheus scale-from-zero deadlock; revisit when an HTTP-queue scaler is wired.

## Phase 3: SR routing rewrite (cascade decisions[])

### Step 3.1 — HelmRelease values

`infrastructure/base/vllm-semantic-router/helmrelease.yaml`:

- Replace existing `categories[]` + `decisions[]` block with the design-spec mapping:

```yaml
categories:
  - {name: code, description: "Code", mmlu_categories: ["computer science", "engineering"]}
  - {name: math, description: "Math", mmlu_categories: ["math"]}
  - {name: physics, description: "Physics", mmlu_categories: ["physics"]}
  - {name: multilingual, description: "Multilingual + longer context", mmlu_categories: ["philosophy", "law"]}
  - {name: other, description: "General", mmlu_categories: ["business", "psychology", "biology", "chemistry", "history", "other", "health", "economics"]}

decisions:
  - name: code_decision
    priority: 100
    rules: {operator: OR, conditions: [{type: domain, name: code}]}
    modelRefs: [{model: xplane-qwen-coder, use_reasoning: false}]
  - name: reasoning_decision
    priority: 90
    rules: {operator: OR, conditions: [{type: domain, name: math}, {type: domain, name: physics}]}
    modelRefs: [{model: xplane-qwen3-8b, use_reasoning: true}]
  - name: multilingual_decision
    priority: 80
    rules: {operator: OR, conditions: [{type: domain, name: multilingual}]}
    modelRefs: [{model: xplane-qwen3-8b, use_reasoning: false}]
  - name: general_decision
    priority: 50
    rules: {operator: OR, conditions: [{type: domain, name: other}]}
    # Was xplane-phi4-mini; remapped to qwen3-8b because phi4-mini stays
    # scale-to-zero and KEDA prometheus can't scale-from-zero. qwen3-8b
    # is min=1 (chat default + math/multilingual cascade). Restore once
    # an HTTP-queue scaler unblocks scale-from-zero.
    modelRefs: [{model: xplane-qwen3-8b, use_reasoning: false}]
```

- Add `model_config` entries for `xplane-qwen-coder` and `xplane-qwen-coder-fim`, drop the `xplane-deepseek-r1-distill-qwen3-8b` entry.
- Add `vllm_endpoints[]` entries for the two new claims (point at `xplane-qwen-coder.llm.svc.cluster.local:8000` and `xplane-qwen-coder-fim.llm.svc.cluster.local:8000`), drop the DeepSeek entry.
- **Set `router.include_config_models_in_list: true`** so the model picker exposes individual models alongside `MoM`.
- Keep `router.auto_model_name: MoM`, `default_model: xplane-qwen3-8b` (fallback when no decision matches; was `xplane-phi4-mini` — same scale-from-zero rationale).

### Step 3.2 — apply + restart

```bash
flux reconcile source git flux-system -n flux-system
flux reconcile hr vllm-semantic-router -n llm
kubectl rollout restart deployment vllm-semantic-router -n llm
```

Verify the new decisions are loaded:

```bash
kubectl exec -n llm deploy/vllm-semantic-router -- \
  cat /app/config/config.yaml | grep -A2 'auto_model\|include_config'
```

### Step 3.3 — verify model picker

```bash
kubectl exec -n apps deploy/xplane-openwebui -- \
  curl -sS http://llm-router.llm.svc.cluster.local/v1/models \
  | jq '.data[].id'
# expect: "MoM", "xplane-qwen-coder", "xplane-qwen-coder-fim",
#         "xplane-phi4-mini", "xplane-qwen3-8b"
```

## Phase 3b: SR signal fusion (keyword + context-length signals)

### Why this phase exists

The base cascade in Phase 3 routes purely on `domain`, which is the LoRA MMLU classifier's output. That misses two real categories of code prompts:

1. **Slang-heavy prompts.** "Refactor this," "what does this stack trace mean," "the build is failing" — surface vocabulary is coder-jargon but topic isn't a CS textbook, so MMLU lands them in `other` and the cascade picks Phi-4 mini.
2. **Long borderline prompts.** A 1500-token "walk me through this code" benefits from `use_reasoning: true` even when the LoRA isn't sure of the domain.

Verified by reading `src/semantic-router/pkg/decision/engine.go` at v0.2.0: all 13 condition types — `domain`, `keyword`, `context`, `complexity`, `embedding`, `language`, `modality`, `authz`, `jailbreak`, `pii`, `fact_check`, `user_feedback`, `preference` — are supported, just not used in the default chart values.

### Step 3b.1 — add `signals` block to HelmRelease

`infrastructure/base/vllm-semantic-router/helmrelease.yaml`, under `config:`:

```yaml
signals:
  keyword_rules:
    - name: code_keywords
      operator: OR
      case_sensitive: false
      keywords: [debug, refactor, "stack trace", traceback, compile,
                 "syntax error", ...]   # full list in helmrelease.yaml
    - name: reasoning_keywords
      operator: OR
      case_sensitive: false
      keywords: [explain, why, " how ", prove, "trade-off", tradeoff,
                 compare, ...]
  context_rules:
    - name: long_query
      min_tokens: 500
      max_tokens: 32000
```

### Step 3b.2 — add `code_with_reasoning` decision at priority 110

Inserted before the existing `code_decision` (100). First-match-wins, so the higher-priority rule needs to be more specific (`AND` of two `OR` clusters):

```yaml
- name: code_with_reasoning
  priority: 110
  rules:
    operator: AND
    conditions:
      - operator: OR     # left side: any code signal
        conditions:
          - {type: domain,  name: code}
          - {type: keyword, name: code_keywords}
      - operator: OR     # right side: any reasoning trigger
        conditions:
          - {type: keyword, name: reasoning_keywords}
          - {type: context, name: long_query}
  modelRefs:
    - {model: xplane-qwen-coder, use_reasoning: true}
```

### Step 3b.3 — relax existing `code_decision` to OR domain+keyword

Phase-3's `code_decision` only matched `domain.code`. Widen to also catch `code_keywords` so slang-heavy prompts still route to qwen-coder even when MMLU says `other`:

```yaml
- name: code_decision
  priority: 100
  rules:
    operator: OR
    conditions:
      - {type: domain,  name: code}
      - {type: keyword, name: code_keywords}
  modelRefs:
    - {model: xplane-qwen-coder, use_reasoning: false}
```

### Step 3b.4 — verify

`helmrelease.yaml` already covered by the kustomize-build + kubeconform check in Step 1.4. Runtime verification is part of Phase 5.

## Phase 4: client documentation

### Step 4.1 — write `docs/coding-clients.md`

Copy-paste config snippets for each client. Covers:

- **OpenCode CLI** (`~/.opencode/config.toml`):
  ```toml
  [providers.local]
  type = "openai"
  base_url = "https://llm.priv.cloud.ogenki.io/v1"
  api_key = "noauth"  # pragma: allowlist secret
  default_model = "xplane-qwen-coder"
  ```

- **VSCode + Continue** (`~/.continue/config.yaml`):
  ```yaml
  models:
    - name: Qwen Coder (chat)
      provider: openai
      model: xplane-qwen-coder
      apiBase: https://llm.priv.cloud.ogenki.io/v1
      apiKey: noauth  # pragma: allowlist secret
      roles: [chat, edit, apply]

    - name: Qwen Coder FIM (autocomplete)
      provider: openai
      model: xplane-qwen-coder-fim
      apiBase: https://llm.priv.cloud.ogenki.io/v1
      apiKey: noauth  # pragma: allowlist secret
      roles: [autocomplete]
      template: qwen
  ```

- **OpenWebUI** — already configured via `apps/base/openwebui/app.yaml`. Document the `model: MoM` default + how to pick individual models from the dropdown.

### Step 4.2 — link from `clusters/mycluster-0-llm-platform/README.md`

Cross-reference `docs/coding-clients.md` from the README's "Enable" section.

## Phase 5: smoke tests

### 5.1 — Auto routing through SR

```bash
# Code prompt → expect xplane-qwen-coder
kubectl exec -n apps deploy/xplane-openwebui -- curl -sS \
  -X POST http://llm-router.llm.svc.cluster.local/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"MoM","messages":[{"role":"user","content":"refactor this Go function for clarity: ..."}]}' \
  -D - -o /dev/null | grep -i x-vsr-selected

# Math prompt → expect xplane-qwen3-8b
kubectl exec -n apps deploy/xplane-openwebui -- curl -sS \
  -X POST http://llm-router.llm.svc.cluster.local/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"MoM","messages":[{"role":"user","content":"prove sqrt(2) is irrational"}]}' \
  -D - -o /dev/null | grep -i x-vsr-selected
```

### 5.2 — Direct model selection (bypass SR cascade)

```bash
# OpenCode-style: pick xplane-qwen-coder directly
kubectl exec -n apps deploy/xplane-openwebui -- curl -sS \
  -X POST http://llm-router.llm.svc.cluster.local/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"xplane-qwen-coder","messages":[{"role":"user","content":"hello"}]}' \
  -w "\nHTTP %{http_code}\n"
```

### 5.3 — FIM endpoint

```bash
# Continue-style: FIM completion (using the OpenAI completions API)
kubectl exec -n apps deploy/xplane-openwebui -- curl -sS \
  -X POST http://llm-router.llm.svc.cluster.local/v1/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "xplane-qwen-coder-fim",
    "prompt": "<|fim_prefix|>def fibonacci(n):\n    if n < 2:\n        return n\n    <|fim_suffix|>\n    return fib(n-1) + fib(n-2)<|fim_middle|>",
    "max_tokens": 50
  }' -w "\nHTTP %{http_code}\n"
```

### 5.4 — Signal-fusion routing

Verifies Phase 3b's keyword + context-length signals lift coverage beyond pure domain matching.

```bash
# Slang-heavy code prompt that MMLU mis-routes to "other" — should still
# land on xplane-qwen-coder via code_keywords match (use_reasoning: false).
kubectl exec -n apps deploy/xplane-openwebui -- curl -sS \
  -X POST http://llm-router.llm.svc.cluster.local/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"MoM","messages":[{"role":"user","content":"the build is failing with a stack trace, can you debug it"}]}' \
  -D - -o /dev/null | grep -i x-vsr-selected
# expect: xplane-qwen-coder

# Long code-y prompt with a reasoning keyword — should hit code_with_reasoning
# (priority 110) and serve xplane-qwen-coder with use_reasoning: true.
kubectl exec -n apps deploy/xplane-openwebui -- curl -sS \
  -X POST http://llm-router.llm.svc.cluster.local/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"MoM","messages":[{"role":"user","content":"explain why this refactor is correct: ...<paste 600+ tokens of code>..."}]}' \
  -D - -o /dev/null | grep -i x-vsr-selected
# expect: xplane-qwen-coder; SR logs show decision=code_with_reasoning
```

### 5.5 — Karpenter consolidation does not evict FIM

```bash
# After ~10min of idle, FIM pod should still be on the same node
kubectl get pod -n llm -l app.kubernetes.io/name=xplane-qwen-coder-fim \
  -o jsonpath='{.items[0].metadata.creationTimestamp}{"\n"}'
# Repeat 10min later — same value means the pod hasn't been recreated
```

### 5.6 — End-to-end via OpenWebUI UI

1. Browse `chat.priv.cloud.ogenki.io`, log in via Zitadel OIDC.
2. Pick `MoM` from the model dropdown, send a code-y prompt → DevTools Network tab shows `x-vsr-selected-model: xplane-qwen-coder`.
3. Pick `xplane-qwen3-8b` from the dropdown, send a code-y prompt → DevTools shows `x-vsr-selected-model: xplane-qwen3-8b` (or no header for direct model selection).
4. Open Continue in VSCode against the gateway; type a function signature and verify inline tab-complete suggestion appears in <500ms.

## Phase 6: cleanup

### 6.1 — Remove DeepSeek weights from the S3 Files filesystem

The Bucket itself is orphaned (preserved across destroy/redeploy), so the old DeepSeek weights still live in S3. Reclaim space:

```bash
aws s3 rm --recursive s3://eu-west-3-ogenki-llm-models/deepseek-ai/DeepSeek-R1-Distill-Qwen-7B/
```

### 6.2 — Drop the per-claim CNP override (when KCL composition gets republished)

Tracked separately as task #76. Once the `crossplane-modules.yml` workflow republishes the composition with the `apps` namespace label baked into `_defaultIngress`, all `apps/base/ai/llm/*.yaml` claims can drop their `networkPolicies.ingress` block.

## Phase 7: nice-to-have follow-ups (not in this plan)

- **Claude Code translator** — deploy `claude-relay-server` (or equivalent) as a sidecar Service that exposes the Anthropic API and proxies to our OpenAI gateway. Wire `ANTHROPIC_BASE_URL` in the user's environment.
- **AutoMix selector** — turn on `router.selector_strategy: automix` for the SR cascade once we want confidence-based small-to-large escalation. Adds a small-then-big round-trip on hard prompts; saves nothing for code (which already routes deterministically).
- **128k context for `xplane-qwen-coder`** — pass `--rope-scaling '{"type":"yarn","factor":4.0}'` via vLLM args. Useful for whole-file refactors, not needed for solo day-to-day.

## Rollback

If any step breaks chat or autocomplete in production:

1. Revert the offending commit on `wip/self-hosted-llm-platform-draft`.
2. `flux reconcile source git flux-system -n flux-system`.
3. The previous (pre-coding-fleet) configuration restores. DeepSeek weights still exist in the S3 bucket (cleanup not done in step 6.1) so the model can be served again.
