# Research: How should the platform pick a model per task and per chat, frontier included, under per-identity token budgets?

**Topic**: llm-complexity-routing · **Conducted**: 2026-09-23 · **Researcher**: Claude (subagent)

Every claim below was re-checked against a primary source: a release, source file, official doc or
rendered chart. **UNVERIFIED** marks what could not be. This file supersedes the raw scratch notes
where they disagree. Those notes overstated several points, listed under *Common pitfalls → notes
that were wrong*.

## TL;DR

- **Semantic Router (SR)**: v0.3.0 (2026-06-05) is the latest release. The 0.2 flat config is
  *rejected* by 0.3, and `vllm-sr config migrate` exists. The **published 0.3.0 Helm chart renders
  broken defaults** (`imagePullPolicy: Never`, `config_source: kubernetes`) because e2e values
  documents are appended to `values.yaml`. The 2026-09-17 nightly is clean.
- **Complexity signal**: embedding prototype banks (hard vs easy). The threshold applies to the
  **margin** `hard − easy`, which stayed ≤ 0.197 in the reporter's test, so the documented 0.70–0.75
  never fires ([#3246](https://github.com/vllm-project/semantic-router/issues/3246)). Maintained
  recipes use 0.08–0.15.
- **SR HTTP API**: `POST /api/v1/eval` evaluates *all* signals and returns the raw complexity margin
  and confidences, which is usable as a classification endpoint. Latency is not published.
- **SR model config from Kubernetes**: `IntelligentPool` / `IntelligentRoute` CRDs, but **exactly one
  of each per namespace**. SR discovers no models from the gateway.
- **Agent Router (ex-Envoy AI Gateway) v1.1.0**: OpenAI-format input **cannot** reach the native
  Anthropic API (no translator, PR #2127 open). It can reach Claude via Bedrock (`AWSAnthropic`) or
  Vertex (`GCPAnthropic`). Anthropic-format input (`/anthropic/v1/messages`) can reach native
  Anthropic, Bedrock, Vertex and OpenAI-schema backends.
- **Budgets**: two mechanisms, both needing Redis. Envoy Gateway global rate limit uses cost from
  response metadata. Agent Router `QuotaPolicy` is v1alpha1 and partly unimplemented in its own
  source. Envoy's JWT `claim_to_headers` **appends**, so client-sent identity headers must be
  stripped before authentication.
- **Evidence on routing value**: an independent four-router evaluation found gains track the *tier
  mix*, not per-prompt targeting. Fixed-tier baselines are required.
- **Jev** (TypeSafe AI): SaaS only, $0.042 per 1M input tokens, zero data retention for enterprise
  only. The vendor documents susceptibility to instructions injected in `state`. The published
  benchmark has 80 authored cases and did not measure answer quality.

## Standard stack

| Component | Pick (candidate) | Version | Source |
|---|---|---|---|
| Prompt router | vLLM Semantic Router | v0.3.0 (chart 0.3.0; nightlies `0.0.0-nightly.YYYYMMDD`) | [releases](https://github.com/vllm-project/semantic-router/releases), `oras repo tags ghcr.io/vllm-project/charts/semantic-router` |
| LLM gateway | Agent Router (Envoy AI Gateway) | v1.1.0 (2026-08-21), EG v1.8.1 tested upstream, repo runs EG 1.9.1 | [v1.1.0 notes](https://github.com/theagentrouter/agent-router/releases/tag/v1.1.0), `flux/sources/ocirepo-envoy-ai-gateway.yaml` |
| Token rate limiting | Envoy Gateway global rate limit (`BackendTrafficPolicy`) | EG 1.9.1 | [usage-based-ratelimiting.md](https://github.com/theagentrouter/agent-router/blob/v1.1.0/site/docs/capabilities/traffic/usage-based-ratelimiting.md) |
| Rate-limit store | Redis-protocol store; Valkey via the `KVStore` composition | — | [EG RateLimitRedisSettings](https://github.com/envoyproxy/gateway/blob/v1.9.1/api/v1alpha1/envoygateway_types.go) (`url` / `urlRef` / `tls`) |
| Frontier (open-weights family) | Z.ai GLM-5.2, OpenAI-compatible `https://api.z.ai/api/paas/v4/`, Anthropic-compatible `https://api.z.ai/api/anthropic` | — | [Z.ai pricing](https://docs.z.ai/guides/overview/pricing), [Claude Code guide](https://docs.z.ai/devpack/tool/claude) |
| Frontier (Claude) | Bedrock (`AWSAnthropic`), Vertex (`GCPAnthropic`), native (`Anthropic`) | Opus 5.5, Sonnet 5, Haiku 4.5 current | Anthropic model table (cached 2026-06-24); [aws-bedrock.md](https://github.com/theagentrouter/agent-router/blob/v1.1.0/site/docs/getting-started/connect-providers/aws-bedrock.md) |
| Complexity SaaS | TypeSafe Jev | `jev-1.13.0` (`jev-latest`) | [models.md](https://docs.typesafe.ai/models.md) |
| Evals | promptfoo (already deployed) | repo pin | `tooling/base/promptfoo/` |

### Prices (per 1M tokens, list)

| Model | Input | Cached input | Output | Source |
|---|---|---|---|---|
| GLM-5.2 | $1.40 | $0.26 | $4.40 | Z.ai pricing |
| GLM-5.3-FlashX | $0.37 | $0.075 | $1.25 | Z.ai pricing |
| GLM-5.3-Flash | $0.15 | $0.03 | $0.50 | Z.ai pricing |
| GLM-4.7-Flash, GLM-4.5-Flash | free | free | free | Z.ai pricing |
| Claude Opus 5.5 | $4 | ~0.1× input | $20 | Anthropic first-party list |
| Claude Sonnet 5 | $2 | ~0.1× | $10 | Anthropic first-party list |
| Claude Haiku 4.5 | $1 | ~0.1× | $5 | Anthropic first-party list |
| Bedrock / Vertex Claude | billed separately (Bedrock: through AWS Marketplace) | | | UNVERIFIED |
| Jev | $0.042 | — | free | TypeSafe models.md |

Z.ai model *API IDs* for the Flash variants (for example `glm-5.3-flash`) are UNVERIFIED. The pricing
page uses display names.

### Semantic Router facts (v0.3.0 source)

| Fact | Evidence |
|---|---|
| 0.2 flat keys are a hard error in 0.3: *"deprecated config fields are no longer supported … run `vllm-sr config migrate`"* | [loader.go](https://github.com/vllm-project/semantic-router/blob/v0.3.0/src/semantic-router/pkg/config/loader.go) |
| The migrator handles `vllm_endpoints`, `model_config`, flat signals and categories | [config_migration.py](https://github.com/vllm-project/semantic-router/blob/v0.3.0/src/vllm-sr/cli/config_migration.py) |
| API routes include `/api/v1/classify/{intent,pii,security,combined,batch}`, `/api/v1/eval`, `/v1/models` and `/config/router` (GET/PUT/PATCH with hot reload) | [routes.go](https://github.com/vllm-project/semantic-router/blob/v0.3.0/src/semantic-router/pkg/apiserver/routes.go) |
| `IntentResponse` returns `matched_signals.complexity` (e.g. `needs_reasoning:hard`) and `classification.processing_time_ms` | [classification_signal_types.go](https://github.com/vllm-project/semantic-router/blob/v0.3.0/src/semantic-router/pkg/services/classification_signal_types.go) |
| `/api/v1/eval` sets `EvaluateAllSignals`, so rules unused by decisions still evaluate. It returns `signal_values["complexity:<rule>:margin"]` and `…:text_hard_score` / `text_easy_score` | [route_classify.go](https://github.com/vllm-project/semantic-router/blob/v0.3.0/src/semantic-router/pkg/apiserver/route_classify.go), [classifier_signal_complexity.go](https://github.com/vllm-project/semantic-router/blob/v0.3.0/src/semantic-router/pkg/classification/classifier_signal_complexity.go) |
| The request accepts `text`, or `messages[]`, where the last user turn is the evaluation text | [intent_request_messages.go](https://github.com/vllm-project/semantic-router/blob/v0.3.0/src/semantic-router/pkg/services/intent_request_messages.go) |
| Complexity verdict: hard if `margin > t`, easy if `margin < −t`, else medium | issue #3246 quoting `complexity_rule_scoring.go:73-81` |
| Decision operators include `NOT` | [engine.go](https://github.com/vllm-project/semantic-router/blob/v0.3.0/src/semantic-router/pkg/decision/engine.go) |
| `config_source: kubernetes` requires exactly one `IntelligentPool` and one `IntelligentRoute` per namespace. More than one marks all `Conflict` | [reconciler.go#L182-L191](https://github.com/vllm-project/semantic-router/blob/v0.3.0/src/semantic-router/pkg/k8s/reconciler.go) |
| Session-aware selection (SAAR) picks among one decision's `modelRefs`, keyed on `x-session-id`. It hard-locks tool loops and resets on idle timeout (300 s) and decision drift | [session-aware.md](https://github.com/vllm-project/semantic-router/blob/v0.3.0/website/versioned_docs/version-v0.3/tutorials/algorithm/selection/session-aware.md) |
| Router replay stores routing records in memory, Postgres, Milvus or Qdrant, with per-route `capture_request_body` / `capture_response_body` | [router-replay.md](https://github.com/vllm-project/semantic-router/blob/v0.3.0/website/versioned_docs/version-v0.3/tutorials/plugin/router-replay.md), `pkg/routerreplay/store/` |
| Behind Envoy AI Gateway the SR config uses `listeners: []`, while `providers.models[]` still list `backend_refs` | [ai-gateway values](https://github.com/vllm-project/semantic-router/blob/v0.3.0/deploy/kubernetes/ai-gateway/semantic-router-values/values.yaml) |
| Chart 0.3.0: Deployment only (no PDB, no initContainers). Models download from HuggingFace at startup. RWO PVC; optional HPA | `helm pull oci://ghcr.io/vllm-project/charts/semantic-router --version 0.3.0` |

### Agent Router facts (v1.1.0 source)

| Fact | Evidence |
|---|---|
| Chat-completions translators: OpenAI, AWSBedrock, AWSAnthropic, AzureOpenAI, GCPVertexAI, GCPAnthropic. Anything else is *"unsupported API schema"* | [endpointspec.go#L164-L181](https://github.com/theagentrouter/agent-router/blob/v1.1.0/internal/endpointspec/endpointspec.go) |
| Messages (`/anthropic/v1/messages`) translators: GCPAnthropic, AWSAnthropic, Anthropic, OpenAI, AWSBedrock | same file, L402-L418 |
| The OpenAI→native-Anthropic translator is PR #2127, **open**. The upstream Anthropic guide's `/v1/chat/completions` curl test contradicts the source | [PR #2127](https://github.com/theagentrouter/agent-router/pull/2127), [anthropic.md](https://github.com/theagentrouter/agent-router/blob/v1.1.0/site/docs/getting-started/connect-providers/anthropic.md) |
| `BackendSecurityPolicy` types: APIKey, AWSCredentials (default chain, `credentialsFile`, OIDC exchange), AzureAPIKey, AzureCredentials, GCPCredentials (ADC incl. Workload Identity, or WIF), AnthropicAPIKey | [backendsecurity_policy.go](https://github.com/theagentrouter/agent-router/blob/v1.1.0/api/v1beta1/backendsecurity_policy.go) |
| Bedrock with EKS Pod Identity on the data-plane ServiceAccount is documented as recommended | [aws-bedrock.md](https://github.com/theagentrouter/agent-router/blob/v1.1.0/site/docs/getting-started/connect-providers/aws-bedrock.md) |
| `AIGatewayRoute.spec.rules` max 15. `llmRequestCosts` max 36. `backendRefs[].namespace` needs a ReferenceGrant. `backendRefs[].priority` maps to Envoy priority failover | [ai_gateway_route.go](https://github.com/theagentrouter/agent-router/blob/v1.1.0/api/v1beta1/ai_gateway_route.go) |
| Token usage is charged **after** the response. An admitted stream is never cut, so overshoot is up to one response | usage-based-ratelimiting.md |
| `QuotaPolicy` (v1alpha1): windows 1s/1m/1h/1d. Only `Shared` mode, where a request is allowed if **any** matching bucket has quota. `ServiceQuota` is not wired (*"descriptor set is not being set"*, TODO in source). Per-rule `shadowMode` | [quota_policy.go](https://github.com/theagentrouter/agent-router/blob/v1.1.0/api/v1alpha1/quota_policy.go), [quota-policy.md](https://github.com/theagentrouter/agent-router/blob/v1.1.0/site/docs/capabilities/traffic/quota-policy.md) |
| The ext_proc maps request headers to metric labels (`metricsRequestHeaderAttributes`), span and log attributes. The session header defaults to `agent-session-id` | `helm show values oci://docker.io/envoyproxy/ai-gateway-helm --version 1.1.0` |
| Controller PDB (`controller.podDisruptionBudget.enabled`) and topology spread: new in v1.1 | v1.1.0 notes |
| v1.1 notes list **no** JWT-claim-projection or token-rate-limit feature. Both are Envoy Gateway features | v1.1.0 notes |

### Bedrock facts (AWS model cards, 2026-09-24)

| Model | `bedrock-runtime` ID from `eu-west-3` | In-region | Source |
|---|---|---|---|
| Claude Opus 5.5 (launched 2026-09-22) | `eu.anthropic.claude-opus-5-5` (bare `anthropic.claude-opus-5-5`) | no | [card](https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-anthropic-claude-opus-5-5.html) |
| Claude Sonnet 5 | `eu.anthropic.claude-sonnet-5`. The bare ID is not supported on-demand | no | [card](https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-anthropic-claude-sonnet-5.html) |
| Claude Haiku 4.5 | `eu.anthropic.claude-haiku-4-5-20251001-v1:0`. The bare ID is not supported on-demand | no | [card](https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-anthropic-claude-haiku-4-5.html) |

- The EU geo profile *"keeps data within EU regions"*. From `eu-west-3` it routes to Frankfurt,
  Stockholm, Milan, Spain, Ireland and Paris, so residency is the EU, not Paris alone.
- These models are billed through AWS Marketplace. Claude Opus 5 also remains listed.

### Envoy Gateway / Envoy facts

| Fact | Evidence |
|---|---|
| `BackendTrafficPolicy.rateLimit.global.rules[]`: `clientSelectors.headers[].type` Exact, RegularExpression or Distinct; `cost.request/response.from` Number or Metadata; `limit.unit` Second…Year; `shadowMode` | flux-schema, EG v1.9.1 |
| `limit.fromMetadata` (per-request limit from dynamic metadata written by an upstream filter) exists in 1.9.x, **not** in 1.8.1 | [ratelimit_types.go@v1.9.1](https://github.com/envoyproxy/gateway/blob/v1.9.1/api/v1alpha1/ratelimit_types.go) vs `@v1.8.1` |
| Redis backend: `url` or `urlRef` (Secret), plus `tls`. Auth is not a field. The rate-limit Deployment env can carry `REDIS_AUTH` (EG test fixture) | envoygateway_types.go; `internal/infrastructure/kubernetes/ratelimit/testdata/deployments/redis-tls-settings.yaml` |
| `SecurityPolicy.jwt.providers[].claimToHeaders`: string, number and bool claims. Nested paths use `.`, so a key containing a dot (for example `kubernetes.io`) cannot be addressed | flux-schema EG v1.9.1; Envoy `StructUtils` path split |
| Envoy `claim_to_headers` uses `headers_->addCopy`, which **appends** to any client-sent value. A list claim such as a Kubernetes token's `aud` is written as base64 of its JSON | [authenticator.cc#L339-L380](https://github.com/envoyproxy/envoy/blob/v1.38.1/source/extensions/filters/http/jwt_authn/authenticator.cc) |
| `ClientTrafficPolicy.spec.headers.earlyRequestHeaders.remove/set` runs before routing and HTTP filters | flux-schema EG v1.9.1 |
| `SecurityPolicy.targetRefs[].sectionName` targets one Gateway listener | flux-schema EG v1.9.1 |

## Local patterns worth reusing

| Path | Why |
|---|---|
| `infrastructure/base/envoy-ai-gateway/envoypatchpolicy-semantic-router.yaml` | The ext_proc-before-extproc insertion (index 0, listener-scoped). The only way to rewrite `body.model` before `x-ai-eg-model` is derived |
| `infrastructure/base/envoy-ai-gateway/security-policy.yaml`, `api-keys-externalsecret.yaml` | API-key auth with `forwardClientIDHeader` and `sanitize`. The key-per-client pattern for system callers |
| `infrastructure/base/vllm-semantic-router/helmrelease.yaml` | Restricted-PSS hardening, HF cache paths on the models volume, and the reasons the semantic cache is off. Carry the rationale, not the 0.2 schema |
| `flux/sources/ocirepo-vllm-semantic-router.yaml` | Pin comment and Renovate bound (`<0.3.0`). The chart defaults it warns about are confirmed |
| `crossplane-configuration/apis/inferenceservice` (pinned v0.7.1) | `spec.gateway` renders a per-claim `AIGatewayRoute` with readiness latch and canaries. The natural place for claim-declared aliases |
| `apps/base/ai/llm/*.yaml` → `spec.routing.{tier,specialty}` | Declared *"for Semantic Router"* but consumed by nothing today |
| `clusters/aws-0/llm-platform.yaml` + `clusters/aws-0-llm-platform/` | The opt-in umbrella pattern (sibling directory, `suspend: true`) to copy for a CPU-only gateway layer |
| `tooling/base/harbor/kvstore.yaml` | `KVStore` (Valkey) claim with an existing password Secret, for the rate-limit store |
| `security/base/epis/runlore.yaml` | `EPI` claim pattern for Pod Identity, for Bedrock `InvokeModel` on the data-plane ServiceAccount |
| `security/base/openbao-stores/clustersecretstore-platform.yaml` | `openbao-platform` store for the human/system provider keys under `platform/`. It has no namespace `conditions`, so `agent-system` uses SP1's namespaced `agents-secrets` store (`platform/agents/*`) instead |
| `observability/base/runlore/helmrelease.yaml` (`model:` block) | GLM-5.2 through Z.ai's OpenAI endpoint via `provider: openai` + `base_url`. The key comes from `runlore/credentials` |
| `apps/base/ai/llm/grafana-dashboard-gateway.yaml` | Existing `gen_ai_client_token_usage_sum` panels by `gen_ai_original_model` |
| `apps/base/ai/llm/vmrule-ai-fleet.yaml` | `LLMPlatformSemanticRouterDown`, `PromptfooRegression` (< 0.85), `PromptfooStale` |
| `tooling/base/promptfoo/eval-suite-configmap.yaml` | Nightly suite already addressing models by name. Arms are more providers in the same config |
| `scripts/ci/validate-manifests.sh` | Renders every HelmRelease, which is the hook for asserting chart-rendered defaults |

## Don't hand-roll

| Need | Use | Not |
|---|---|---|
| Prompt difficulty signal | SR `complexity` (prototype banks) via ext_proc or `/api/v1/eval` | a bespoke embedding classifier |
| Guard before frontier | SR `pii`, `jailbreak` signals + `NOT` in decisions | regex scrubbing in a filter |
| Token accounting | Agent Router `llmRequestCosts` metadata + EG global rate limit | counting tokens in a sidecar |
| Keyless Claude | `AWSCredentials` default chain + EKS Pod Identity; `GCPCredentials` ADC | long-lived AWS or GCP keys in Secrets |
| Format translation | Agent Router translators (see matrix) | a proxy converting OpenAI↔Anthropic |
| Identity headers | EG `jwt.claimToHeaders` + `earlyRequestHeaders.remove` | trusting client headers, or a Lua rewrite |
| Model-level session stickiness (chat) | SR `session_aware` | a sticky-session cache |
| Offline routing analysis | SR router replay (bodies off) | request mirroring to a custom store |

Custom code that remains justified: a thin C7 adapter giving pluggable backends, a shadow mode and
insulation from SR API churn. No OSS project found offers that interface. LiteLLM's complexity router
is a whole second proxy, and its Jev custom instructions are Enterprise
([LiteLLM blog](https://docs.litellm.ai/blog/jev-auto-router-benchmark), secondary for the
Enterprise claim, UNVERIFIED).

## Common pitfalls

1. **SR 0.3.0 chart defaults.** The published `values.yaml` contains 40 `---` separators (41
   documents). `helm template` without values renders `imagePullPolicy: Never`, image tag
   `latest`, `config_source: kubernetes`, `EMBEDDING_MODEL_OVERRIDE=qwen3` and semantic cache on.
   `config_source: kubernetes` makes the router wait for CRDs. The nightly of 2026-09-17 renders one
   document with `IfNotPresent`. No upstream issue was found.
2. **Complexity threshold is a margin.** 0.75 is unreachable (#3246, fixed in examples only by PR
   #3260 on main, 2026-09-01). The v0.3.0 tagged doc still shows 0.75. Failure is silent: HTTP 200,
   no warning, and the escalation model never selected. Detect it with `x-vsr-debug: true` →
   `x-vsr-matched-complexity`, or with per-band counts.
3. **Complexity and cross-domain misfires.** Banks from one domain misfire on others. Separate rules
   per use (chat `MoM` vs task intake), with banks from real traffic.
4. **`/api/v1/classify/intent` skips unused signals.** A complexity rule no decision references is
   evaluated only by `/api/v1/eval`.
5. **One `IntelligentPool` per namespace.** A per-claim pool object conflicts. CRD mode is
   whole-config ownership, not a fragment merge.
6. **OpenAI clients → native Anthropic fail at runtime** with *unsupported API schema*, although the
   upstream guide shows a chat-completions test.
7. **`claim_to_headers` appends.** Without an early strip, a client-supplied `x-…` identity header
   survives, and descriptor extraction may read the forged value first.
8. **SA-token claims under `kubernetes.io`** cannot be addressed by EG `claimToHeaders`, because the
   dot is a path separator. `sub` is the usable claim.
9. **`QuotaPolicy` Shared mode** admits a request if *any* matching bucket has quota, so a
   per-principal bucket does not cap on its own while a default bucket has room.
10. **`rateLimit.global.rules[].shared` defaults to `false`**: each targeted xRoute gets its own
    bucket. Per-principal budgets over many generated routes need `shared: true`.
11. **Rate limits are charged after the response.** Streams overshoot by at most one response. Daily
    windows are fixed (UTC boundaries), not sliding.
12. **ext_proc at index 0 runs before authentication** and on every request of the listener,
    `failure_mode_allow` defaults to false, and the repo's patch uses `message_timeout: 60s`. An SR
    stall stalls the whole listener.
13. **gRPC ext_proc to a ClusterIP** pins each Envoy connection to one SR pod. Adding replicas does
    not spread load or fail over quickly without a headless Service or outlier detection.
14. **RWO model PVC plus more than one replica.** Pods on different nodes cannot share it. This is
    the origin of the repo's `do-not-disrupt` annotation.
15. **Per-request routing inside agent trajectories.** One under-routed step can fail the task, and
    switches lose provider prompt caches (Anthropic cache reads ≈0.1× input, writes 1.25× for 5 min).
    Every 2026 router surveyed pins per session, per task, or latches on escalation.
16. **Router evaluations without fixed-tier arms.** arXiv 2608.14641: *"observed gains track
    selected-tier composition more closely than demonstrated task-specific targeting"*. vLLM SR was
    the only router of four whose tier choice varied materially with prompt content, and it had the
    best success rate on none of the four benchmarks.
17. **Jev**: *"accuracy falls as the state grows with content unrelated to the decision"*; injected
    instructions in `state` can steer it. The LiteLLM benchmark (80 authored cases, median 127 ms,
    p95 231 ms, 95% tier match) states *"downstream answer quality was not measured"*.

### Notes that were wrong or overstated in earlier scratch research

| Earlier claim | Correction |
|---|---|
| "Agent Router v1.1: JWT claim projection, token rate limiting" | Not in v1.1 notes. These are Envoy Gateway features |
| LiteLLM Jev example `timeout_ms: 3000` | The benchmark used `timeout_ms` 10,000. 3000 is not in the post |
| TwinRouterBench "75/100 vs 74/100", "7 of 147 steps" | Not in the abstract. Only the abstract was verified, and these figures stay UNVERIFIED |
| RouterArena rank figures (SR #6, $0.42/1k) | UNVERIFIED (not re-checked) |
| Jev "early access behind a waitlist" | models.md says limits adjust dynamically under demand, with higher limits on enterprise plans. No waitlist is stated |

## Open questions surfaced

1. Does SR 0.3 validation accept `providers.models[]` entries with no `backend_refs` (role names
   only) in AI-gateway mode? UNVERIFIED.
2. With SR at filter index 0, does `/v1/models` through the gateway still list `MoM` in 0.3?
   UNVERIFIED.
3. Latency of `/api/v1/eval` on CPU (all signals, incl. domain LoRA and PII) for a 2–8k-character
   text? UNVERIFIED. The repo comment's "~250–300 ms" was the 0.2 full classify path, not measured
   here.
4. Does envoy-ratelimit (the EG deployment) work against Valkey with `REDIS_AUTH` injected through
   the rate-limit Deployment env? UNVERIFIED.
5. Does one EG rate-limit rule accept both a `Distinct` and a `RegularExpression` selector on the
   same header? UNVERIFIED.
6. Does the Envoy rate-limit filter mark its 429s with `x-envoy-ratelimited: true` in this EG
   version? UNVERIFIED.
7. Can an EG `EnvoyPatchPolicy` use `jsonPath` to insert SR after authentication and before the AI
   Gateway extproc? UNVERIFIED.
8. Bedrock prices for the three EU profiles below, and whether IAM must grant each EU destination
   region's foundation-model ARN as well as the profile. UNVERIFIED.
9. How faithful is Anthropic→OpenAI translation (tools, thinking) for Claude Code against GLM? Or is
   Z.ai's native Anthropic endpoint better for that client? UNVERIFIED.
10. Where does Z.ai process and store API traffic, and what are its retention terms? UNVERIFIED.
11. Does OpenWebUI forward a stable per-chat id that could serve as `x-session-id` for SAAR?
    UNVERIFIED.
12. When will SR 0.4 ship? Its milestone was due 2026-09-18 and main is well ahead of v0.3.0.
    UNVERIFIED.

## References

- vLLM Semantic Router releases — https://github.com/vllm-project/semantic-router/releases
- SR issue #3246 (complexity threshold) — https://github.com/vllm-project/semantic-router/issues/3246
- SR v0.3.0 source: `pkg/apiserver/routes.go`, `pkg/services/classification_signal_types.go`,
  `pkg/classification/classifier_signal_complexity.go`, `pkg/k8s/reconciler.go`,
  `pkg/config/loader.go`, `pkg/decision/engine.go`, `src/vllm-sr/cli/config_migration.py` —
  https://github.com/vllm-project/semantic-router/tree/v0.3.0
- SR v0.3 docs: complexity signal, session-aware selection, router replay —
  https://github.com/vllm-project/semantic-router/tree/v0.3.0/website/versioned_docs/version-v0.3
- SR chart — `oci://ghcr.io/vllm-project/charts/semantic-router` (0.3.0, nightly 20260917)
- Agent Router v1.1.0 release — https://github.com/theagentrouter/agent-router/releases/tag/v1.1.0
- Agent Router source: `internal/endpointspec/endpointspec.go`, `api/v1beta1/*.go`,
  `api/v1alpha1/quota_policy.go` — https://github.com/theagentrouter/agent-router/tree/v1.1.0
- Agent Router PR #2127 (OpenAI→Anthropic) — https://github.com/theagentrouter/agent-router/pull/2127
- Agent Router docs: usage-based rate limiting, quota policy, Bedrock, Anthropic —
  https://github.com/theagentrouter/agent-router/tree/v1.1.0/site/docs
- Envoy Gateway v1.9.1 `ratelimit_types.go`, `envoygateway_types.go` — https://github.com/envoyproxy/gateway/tree/v1.9.1/api/v1alpha1
- Envoy v1.38.1 jwt_authn `authenticator.cc` — https://github.com/envoyproxy/envoy/blob/v1.38.1/source/extensions/filters/http/jwt_authn/authenticator.cc
- Z.ai pricing — https://docs.z.ai/guides/overview/pricing ; Claude Code with GLM — https://docs.z.ai/devpack/tool/claude
- TypeSafe Jev: models, legal, jaggedness, intent routing — https://docs.typesafe.ai/models.md ,
  https://docs.typesafe.ai/legal.md , https://docs.typesafe.ai/model-jaggedness/jev-1.13.md ,
  https://docs.typesafe.ai/patterns/intent-routing.md
- LiteLLM Jev benchmark — https://docs.litellm.ai/blog/jev-auto-router-benchmark
- arXiv 2608.14641, *Task- and Session-Level Model Routing: A Common-Interface Hybrid Evaluation of
  Four Open-Source Routers Across Four Benchmarks* — https://arxiv.org/abs/2608.14641
- arXiv 2605.18859, *TwinRouterBench* — https://arxiv.org/abs/2605.18859
- Anthropic model table and caching multipliers — Claude API reference (cached 2026-06-24);
  Bedrock pricing — https://aws.amazon.com/bedrock/pricing/
