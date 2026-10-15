# Research: agentgateway open issues that bear on the 1.6 pin (OD-2)

**Topic**: agentgateway-open-issues · **Conducted**: 2026-10-15 · **Researcher**: Claude (subagent)

Input to OD-2 of the [refreshed agent-router plan](https://github.com/Smana/cloud-native-ref/pull/2369)
(`docs/superpowers/plans/2026-10-15-agent-router-agentgateway-plan.md`, branch
`docs/agentgateway-plan-refresh`). It follows the [gap matrix and PoC](2026-10-01-agentgateway-gap-matrix-research.md),
whose findings N1–N10 are cited by number.

| Read at | |
|---|---|
| Releases | `v1.6.0` (latest GA) and `main` = `ebfbf04ded42` (2026-10-15), 154 commits ahead of `v1.6.0` |
| Issues | All 203 open issues by title; bodies and comments of the ones below; issues closed since 2026-09-28 |

**Not proven live.** Every claim below is from release notes, issues, pull requests or source. The
live test in [the recommendation](#recommendation-for-od-2) is what decides.

## TL;DR

- **No blocker for our use.** Each relevant open issue has a workaround or touches a path we do not use.
- **v1.6.1 may never ship.** v1.5 had no patch release, no 1.6.1 is planned, and the open milestone
  is **v1.7.0, due 2026-10-26**. ADR-0053 D3 ("a new minor only at its first patch") would skip
  1.5 and 1.6 both. OD-2 (b) is a wait with no end date.
- **The fixes that matter to us are on `main`, unreleased**: MCP session-key overwrite (#3802),
  HTTP/1 drain (#3833), and custom-provider path joining (#3853). They arrive in 1.7.0.
- **1.6.0 fixes two things 1.5.0 gets wrong for us**: N1's root cause (#3334) and the cached-token
  undercount on buffered conversions (#3041). Pinning 1.5.0 keeps both bugs.

## Releases

| Version | Date | Kind |
|---|---|---|
| [v1.5.0](https://github.com/agentgateway/agentgateway/releases/tag/v1.5.0) | 2026-08-27 | GA, the PoC's version. No v1.5.x patch |
| v1.6.0-alpha.1, alpha.2, rc.1 | 2026-09-14, 09-22, 10-01 | pre-release |
| [v1.6.0](https://github.com/agentgateway/agentgateway/releases/tag/v1.6.0) | 2026-10-02 | **latest GA**. No v1.6.x patch, no newer pre-release |
| [v1.7.0 milestone](https://github.com/agentgateway/agentgateway/milestone/9) | due 2026-10-26 | open, no 1.6.1 milestone; no release branch exists |

Patch history: 1.3.1 and 1.4.1 shipped; 1.5 got none.

## Breaking changes 1.5.0 → 1.6.0 that hit us

| Change | Our impact | Plan task |
|---|---|---|
| Anthropic Messages converts to OpenAI Responses first ([#3647](https://github.com/agentgateway/agentgateway/pull/3647)); "use the OpenAI provider only for the OpenAI API" | The Z.ai backend leaves `provider.openai` for `provider.custom` with `formats: [Completions]`. `AGENTGATEWAY_MESSAGES_PREFER_COMPLETIONS=true` is a stopgap, removed in 1.7 | C.1, AG5 |
| A provider base URL without a path means `/` | Z.ai's base carries `/api/paas/v4` explicitly | C.1, AG11 |
| CRDs no longer store defaults ([#3520](https://github.com/agentgateway/agentgateway/pull/3520)) | The gate reads explicit fields only; Flux drift is unaffected | A.3 |
| Built-in model catalog prices requests | Prices Claude 5.5; **no `zai` provider even on `main`**: GLM-5.3 appears only under `mistral` (`cacheRead` 0.14, not Z.ai's 0.26) and resellers | J.1 overlay stands |
| Input and total token counts always include cache tokens (legacy env var removed) | Matches the meter's "`cached_input` is a subset of `input`". Token types are `input`, `output`, `input_cache_read`, `input_cache_write`: E.2's relabel maps `input_cache_read` → `cached_input` | E.2, J0 |
| Priority-group backends evict failing targets by default | Only with failover groups (phase I) | I.3 |
| Rate-limit calls default to a 10 s timeout | Within D.1's budget | D.1 |
| `error_type` on request duration is `_OTHER` for every failure | Gives an error ratio, not a per-status split | E.2 |

**A correction to the plan.** B.3 says 1.6's graceful drain is standalone-only. The fix,
[#3334](https://github.com/agentgateway/agentgateway/pull/3334) (in 1.6.0), changes the shared proxy
(`crates/agentgateway/src/proxy/gateway.rs`, `crates/core/src/drain.rs`) and names N1's mechanism:
"on SIGTERM the gateway force-closes every open connection about 2 ms later". It also derives the
maximum from the pod's grace period minus 5 s. Keep the explicit `shutdown` from N1, and re-run
N1 on 1.6.0 with the defaults too, to learn whether it is still needed.

## Issues by use area

**Blocker**: no workaround for our use · **workaround**: we can live with it, at a stated cost ·
**cosmetic**: no effect on correctness or budgets · **n/a**: a path we do not use.
"Fix" says where the fix is: `1.6.0`, `main` (unreleased, so 1.7.0), or none.

### LLM proxying: Z.ai and Anthropic

| Issue | What | Affects | Fix | Class for us |
|---|---|---|---|---|
| [#3835](https://github.com/agentgateway/agentgateway/issues/3835) | Messages → Completions forwards non-spec request fields (`user`); a strict upstream answers 422. A non-OpenAI error body turns into 502 | 1.6.0 | none | **workaround**: C.1 probes the `/anthropic` path with the harness's real request. Whether Z.ai rejects unknown fields is UNVERIFIED. Alternative below |
| [#3700](https://github.com/agentgateway/agentgateway/issues/3700) | Messages → Completions sends `reasoning_effort` to models that reject it | 1.6.0 | `main` ([#3744](https://github.com/agentgateway/agentgateway/pull/3744)), OpenAI models only | **workaround**: C.1 checks GLM-5.3 accepts or ignores it |
| [#3853](https://github.com/agentgateway/agentgateway/pull/3853) | Custom and preset providers join base URL and path wrongly on `Detect`/`Passthrough` routes | 1.6.0 | `main` | **workaround**: C.1 uses typed routes (`Completions`, `Messages`), never `Detect` or `Passthrough` |
| [#3937](https://github.com/agentgateway/agentgateway/issues/3937) | The Anthropic provider overwrites the client's `anthropic-version` with `2023-06-01` | 1.6.0 | `main` ([#3957](https://github.com/agentgateway/agentgateway/pull/3957)) | cosmetic: beta features ride `anthropic-beta` |
| [#3707](https://github.com/agentgateway/agentgateway/issues/3707) | Anthropic backend rejects `tools[]` | 1.5.0 | config, not a bug: the backend needs `routes: {"/v1/messages": Messages}` | workaround, already in the PoC routes |
| [#3681](https://github.com/agentgateway/agentgateway/issues/3681) | Anthropic → Completions streams emit `tool_calls[].type: null`; openai-python's accumulator raises | 1.5.0 | 1.6.0 ([#3736](https://github.com/agentgateway/agentgateway/pull/3736)) | fixed in 1.6.0; hits OpenAI-format clients of Claude on 1.5.0 |
| [#3749](https://github.com/agentgateway/agentgateway/issues/3749) | A custom provider's `formats[].path` is static (no `{model}`) | all | none | n/a: Z.ai paths carry no model |

The 1.6.0 `AgentgatewayBackend` CRD lets `provider.custom.formats` list `Messages` with its own
`path`. That could send `/anthropic/v1/messages` to Z.ai's Anthropic-compatible endpoint without
converting it, which sidesteps the Responses preference, #3835 and #3700. UNVERIFIED: worth one
probe in C.1 against the planned conversion.

### MCP federation

| Issue | What | Affects | Fix | Class for us |
|---|---|---|---|---|
| [#3834](https://github.com/agentgateway/agentgateway/issues/3834), [#3802](https://github.com/agentgateway/agentgateway/pull/3802) | The controller can overwrite the session-key Secret (stale-cache race); every live `Mcp-Session-Id` then fails to decode and gets 400, not 404, so clients never re-initialize. Seen for a minute after a 1.5.0 → 1.6.0 upgrade | 1.5.0, 1.6.0 | `main` | **workaround**: `spec.mcp.sessionRouting: Stateless` on the federated backend (the reporter's fix). Live check: tool prefixing and per-target headers survive it |
| [#3622](https://github.com/agentgateway/agentgateway/issues/3622) | When one multiplexed upstream drops its session, its tools fail for the rest of the federated session; no 404 to the client | 1.5.0 (open) | none | **workaround**: the same `Stateless` mode re-initializes the upstream. Matters for the room broker restarting mid-run |
| [#3708](https://github.com/agentgateway/agentgateway/issues/3708) | `initialize` returns the `instructions` of targets the caller may not use | 1.5.0 (open) | none; per-target `condition` reached the CRD only on `main` ([#3824](https://github.com/agentgateway/agentgateway/pull/3824)) | cosmetic: tool lists are filtered; our targets' instructions hold no secrets |
| [#3586](https://github.com/agentgateway/agentgateway/issues/3586) | `initialize`/`list` fan out to targets the caller is denied | open | none | cosmetic: no denied tool is callable (N7's gate) |
| [#3710](https://github.com/agentgateway/agentgateway/issues/3710) | A call denied by `mcpAuthorization` logs as `Unknown tool`, like a typo | 1.5.0 (open) | none | cosmetic, the PoC's "denied MCP item" gap. The maintainer keeps the client answer opaque on purpose |
| [#3785](https://github.com/agentgateway/agentgateway/issues/3785) | Split `Accept` header lines get 406 | 1.6.0 | `main` ([#3786](https://github.com/agentgateway/agentgateway/pull/3786)) | cosmetic unless the OpenHands SDK splits it: C.5's probe shows it |
| [#3976](https://github.com/agentgateway/agentgateway/pull/3976) | `DELETE /mcp` on another replica never reaches upstreams; their sessions idle out | 1.6.0 | `main` | cosmetic |

### Identity: JWT from projected service-account tokens

| Issue | What | Affects | Fix | Class for us |
|---|---|---|---|---|
| [#2798](https://github.com/agentgateway/agentgateway/issues/2798) | An unknown `kid` never triggers a JWKS refetch; on Kubernetes the refresh is `cacheDuration`, minimum 5 min | open | none | **workaround**: rebuilds replace the proxies too. An EKS signing-key rotation could fail auth for up to 5 min if the new key is used before it is fetched: UNVERIFIED, B.6's JWKS check covers it |
| [#3616](https://github.com/agentgateway/agentgateway/issues/3616) | An unreachable JWKS fails the initial config load | open | none | n/a: standalone local config. On Kubernetes the controller fetches JWKS |
| [#3172](https://github.com/agentgateway/agentgateway/issues/3172) | `jwtAuth` 401 has no `WWW-Authenticate` | open | none | cosmetic |
| [#3698](https://github.com/agentgateway/agentgateway/issues/3698) | Controller crash with remote JWKS in `route-and-policy` grant mode | 1.5.0 | 1.6.0 | n/a, not our grant mode |

### Budgets and rate limits

| Issue | What | Affects | Fix | Class for us |
|---|---|---|---|---|
| [#3523](https://github.com/agentgateway/agentgateway/issues/3523) | A descriptor whose CEL fails to evaluate is dropped; if all drop, the request passes unlimited. `failureMode: failClosed` does not cover it | 1.6.0, `main` | none (maintainer open to an opt-in) | **workaround, and a gate rule**: B1/B2 descriptors read only claims the JWT policy already requires (`requiredClaims` or the CEL `Require`), so a missing claim is refused at auth. AG8 should fail a descriptor that reads anything else. D.2's live step sends a token without the claim |
| [#3778](https://github.com/agentgateway/agentgateway/pull/3778) | (breaking, `main`) `request.headers["x"]` returns a list when the header repeats | 1.7.0 | — | forward risk: a repeated `x-ar-agent` would fail its descriptor, then #3523 drops it. Re-check at the 1.7 bump |
| [#3888](https://github.com/agentgateway/agentgateway/pull/3888) | A route budget can wipe a Gateway's budget | 1.6.0 | `main` | n/a: our budgets are route-level remote rate limits |

### Streaming and token accounting

| Issue | What | Affects | Fix | Class for us |
|---|---|---|---|---|
| [#3739](https://github.com/agentgateway/agentgateway/issues/3739), [#3806](https://github.com/agentgateway/agentgateway/issues/3806) | A stream cut before its final usage update records the provisional `message_start` counts as final (seen: 27 in / 1 out instead of 27 / 403) | 1.6.0, `main` | none ([#3740](https://github.com/agentgateway/agentgateway/pull/3740) closed unmerged; a finality design is pending) | **workaround**: this is N2 in another shape. 1.5.0 charged a cut stream nothing; 1.6.0 charges its partial counts. Both undercount; N1's drain keeps cuts rare. Record it in ADR-0053's budget residual |
| [#3041](https://github.com/agentgateway/agentgateway/issues/3041) | Buffered Completions/Responses → Messages conversions subtract cache tokens twice in telemetry and cost | 1.5.0 | 1.6.0 ([#3687](https://github.com/agentgateway/agentgateway/pull/3687)) | fixed in 1.6.0. On 1.5.0 it skews phase J's cache-aware price |
| [#3167](https://github.com/agentgateway/agentgateway/issues/3167) | The `promptCaching` policy is a no-op for the native Anthropic provider | open | PR [#3265](https://github.com/agentgateway/agentgateway/pull/3265) open | **workaround**: phase J relies on the client's own `cache_control` markers, which native Messages passes through (J-AC3 proves it live) |
| [#3676](https://github.com/agentgateway/agentgateway/pull/3676) | A passthrough stream without a final blank line fails | 1.6.0 | `main` | cosmetic unless Z.ai ends streams that way: C.1's streaming probe shows it |

### Drain, memory, operations

| Issue | What | Affects | Fix | Class for us |
|---|---|---|---|---|
| [#3829](https://github.com/agentgateway/agentgateway/issues/3829) | During drain, idle HTTP/1 keep-alive connections are closed silently instead of with `Connection: close`; a client's next request on a pooled connection fails | 1.6.0 | `main` ([#3833](https://github.com/agentgateway/agentgateway/pull/3833)) | **workaround**: P4 (agent-platform#99) retries a reset-before-headers. Without P4, a rollout can end a run between two calls |
| [#3184](https://github.com/agentgateway/agentgateway/issues/3184) | No aggregate cap on buffered request bytes: overload ends in OOMKill, not 429 | open | none | **workaround**: 1.6 raised the LLM buffer default from 2 to 32 MiB. Size the proxy's memory limit to concurrent runs × largest prompt, and alert on restarts |
| [#3896](https://github.com/agentgateway/agentgateway/pull/3896) | Messages → Completions streams buffered every tool-call argument for the whole stream | 1.6.0 | `main` | cosmetic: memory on long streams |
| [#3968](https://github.com/agentgateway/agentgateway/issues/3968) | The hickory DNS resolver fails some queries | open | none | cosmetic unless a provider host fails to resolve on EKS: B.6 |

### `/v1/models` and telemetry

| Issue | What | Affects | Fix | Class for us |
|---|---|---|---|---|
| [#3989](https://github.com/agentgateway/agentgateway/issues/3989) | A model-router direct response (unknown model 404, model authz 403) logs no `jwt.*` or header attributes | 1.6.0, `main` | none | cosmetic: a refused model call has no `x_ar_agent` in its log. N3's `/v1/models` `directResponse` is a policy, which does snapshot |
| [#3965](https://github.com/agentgateway/agentgateway/pull/3965) | `/v1/models` renders catalog metadata | `main` | — | re-check N3 at 1.7: the `directResponse` must still win |
| [#3980](https://github.com/agentgateway/agentgateway/issues/3980) | Plan to adopt the renamed OTel gen_ai semconv, with a compatibility period | open | none | forward risk: E.2's relabel layer absorbs the rename |
| [#3296](https://github.com/agentgateway/agentgateway/issues/3296) | Per-status `error.type` and failover-health metrics | open | partly in 1.6.0 (`_OTHER` only) | cosmetic |

**EKS and Cilium**: no open or recently closed issue names either.

## Recommendation for OD-2

**Pin v1.6.0 for phases A–E, then re-test v1.7.0 before phase F's cutover.** Both conditional on
the live test below.

| Option | Verdict |
|---|---|
| (a) v1.6.0 now | **Yes, if L1–L8 pass.** No blocker found; it fixes N1's root cause (#3334) and the buffered cache-token count (#3041); the 1.6 deltas are already in the plan |
| (b) wait for v1.6.1 | No: likely never ships (above). The fixes we want land in 1.7.0 |
| (c) v1.5.0, bump later | Only if L1 or L2 fail on 1.6.0 and the 1.5 shape still works. It keeps #3334's drain bug, #3041 and #3681, and pays the 1.6 deltas at the bump |

Phases A–E are additive while Envoy serves runs, and P0 delays them past 1.7.0's due date anyway.
Re-run L1–L8 on 1.7.0 before F, and take it if it passes: it carries #3802, #3833 and #3853, and
retires the `MESSAGES_PREFER_COMPLETIONS` stopgap. ADR-0053 D3's "first patch release" rule should
become "a minor that passes our live gate", since the project ships patches rarely.

**The live test** (B.6 and C.5 on the OD-5 cluster). One failure moves to option (c):

| # | Check | Covers |
|---|---|---|
| L1 | Z.ai via `provider.custom`, `formats: [Completions]`, base `/api/paas/v4`: `POST /v1/chat/completions`, streamed and buffered, with tool calls | breaking change 1, #3853, #3676 |
| L2 | `POST /anthropic/v1/messages` with the harness's real request: no 4xx from forwarded fields or `reasoning_effort`; compare the native `Messages` format to Z.ai's Anthropic endpoint | #3835, #3700 |
| L3 | MCP federation with `sessionRouting: Stateless`: prefixed tools, per-target header injection, Allow lists, every `tools/list` page; restart the room broker and then the controller mid-session, tools keep working | #3834, #3622, N5, N7 |
| L4 | N1's 200 s stream survives proxy deletion, with the explicit `shutdown` and with the defaults; a pooled HTTP/1 client crosses the drain with P4's retry | #3334, #3829 |
| L5 | A token without the descriptor's claim is refused, never served unlimited | #3523 |
| L6 | `gen_ai` token usage carries `input` and `input_cache_read` for Z.ai and Claude, streamed and buffered, consistent with the provider's usage body | #3041, E.2 |
| L7 | `GET /v1/models` with a valid token gets N3's 404 body, not the 1.6 wildcard expansion | N3 |
| L8 | JWT from an EKS projected token, `requiredClaims` set; JWKS resolves | #2798, B.4 |

## References

- Plan: [PR #2369](https://github.com/Smana/cloud-native-ref/pull/2369); gap matrix: [2026-10-01 research](2026-10-01-agentgateway-gap-matrix-research.md)
- [v1.6.0 release notes](https://github.com/agentgateway/agentgateway/releases/tag/v1.6.0);
  [commits since v1.6.0](https://github.com/agentgateway/agentgateway/compare/v1.6.0...main)
- [Model catalog on `main`](https://github.com/agentgateway/agentgateway/blob/main/catalog/model-catalog.json)
- [`AgentgatewayBackend` CRD at v1.6.0](https://github.com/agentgateway/agentgateway/blob/v1.6.0/controller/install/helm/agentgateway-crds/templates/agentgateway.dev_agentgatewaybackends.yaml) (`provider.custom.formats`, `mcp.sessionRouting`)
