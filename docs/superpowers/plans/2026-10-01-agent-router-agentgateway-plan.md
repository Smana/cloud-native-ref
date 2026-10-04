# Agent router on agentgateway Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Every agent call (LLM, MCP, octo-sts exchange) crosses agentgateway's Gateway
`agent-gateway/agent-router` with ADR-0042's boundaries intact or stronger, B1–B2 count in shadow on
our own rate-limit server, and the Envoy agent-router is deleted once verified.

**Architecture:** agentgateway v1.5.0 (controller in `agentgateway-system`, proxies in a new
`agent-gateway` namespace) runs beside the Envoy agent-router. Routes, backends and Secrets stay in
`agent-system`. New runs switch by one FQDN change in the shared identity-proxy ConfigMap, after a
crossplane-configuration release lets the run CNP reach both gateways. After the live gates pass, a
second release drops the old egress and the Envoy objects go. Last, phase I gives `internal` the
Anthropic API (ADR-0054) and per-provider budgets, provable on gcp-0; optional backends (OpenRouter,
Bedrock, Vertex) sit in an appendix, off by default. Phase J then makes prompt caching
provider-agnostic: the gateway asks the providers that need asking, prices every request from one
table, and budgets, the run meter and the run page count that price.

**Tech Stack:**
- agentgateway v1.5.0: charts `oci://cr.agentgateway.dev/charts/agentgateway{,-crds}` (CRDs `agentgateway.dev/v1alpha1`: `AgentgatewayBackend`, `AgentgatewayPolicy`, `AgentgatewayParameters`, `AgentgatewayModel`);
- `envoyproxy/ratelimit` `0482748e` (the image Envoy Gateway runs), Valkey through the `KVStore` claim;
- Gateway API 1.6.2, Flux 2.9 (`kustomize.toolkit.fluxcd.io/v1`, `helm.toolkit.fluxcd.io/v2`), Cilium CNP, VictoriaMetrics `VMPodScrape`/`VMRule`, grafana-operator;
- crossplane-configuration (KCL, function-kcl v0.12.2), `Smana/agent-platform` (Go, the room bridge);
- Python 3 + PyYAML for the gates.

**Spec:** [`docs/superpowers/specs/2026-10-01-agent-router-agentgateway-design.md`](../specs/2026-10-01-agent-router-agentgateway-design.md)
(binding; read it whole, rulings D1–D8 and the providers table included),
[ADR-0053](../../../website/content/docs/decisions/0053-agent-router-on-agentgateway.md) and
[ADR-0054](../../../website/content/docs/decisions/0054-agent-model-providers-anthropic-direct.md). Evidence:
the [gap matrix and PoC result](../specs/2026-10-01-agentgateway-gap-matrix-research.md). The PoC
manifests on `integration/agent-factory` (`infrastructure/gcp-0/agentgateway{,-poc}/`) are the
starting point for most YAML below.

## Global Constraints

- **Names.**

  | Thing | Value |
  |---|---|
  | GatewayClass | `agentgateway` (created by the controller, not declared in Git; PoC N9) |
  | Controller | HelmReleases `agentgateway-crds`, `agentgateway` in `agentgateway-system`; Flux child `agentgateway` |
  | Gateway | `agent-router` in `agent-gateway`; listeners `public:8080`, `internal:8081`, `sts:8082`; Flux child `agent-gateway` |
  | Data-plane Service | `agent-router.agent-gateway.svc.cluster.local` (ClusterIP) |
  | Proxy pod selector | `io.kubernetes.pod.namespace: agent-gateway` + `gateway.networking.k8s.io/gateway-name: agent-router` (always both: F1) |
  | Parameters | `AgentgatewayParameters agent-router` in `agent-gateway` |
  | Routes, backends, Secrets | `agent-system`: `HTTPRoute agent-models`, `agent-models-list`, `agent-mcp-public`, `agent-mcp-internal`, `octo-sts`; `AgentgatewayBackend zai`, `agent-mcp` |
  | Budgets | Deployment/Service `agent-ratelimit`, ConfigMap `agent-ratelimit-config`, domain `agent-router`, `KVStore xplane-agent-ratelimit`, Secret `agent-ratelimit-valkey` (key `REDIS_PASSWORD`), all in `agent-gateway` |
  | Gate | `scripts/ci/flux-schema/assert-agent-gateway.py`, checks AG1–AG9 |
  | MCP tool names | `<target>_<tool>`, targets `flux-operator-mcp`, `mcp-victoriametrics`, `mcp-victorialogs`, `room-broker` |
  | Providers (ADR-0054) | `public` → `AgentgatewayBackend zai`; `internal` → `AgentgatewayBackend anthropic`, Secret `agents-anthropic-api-key` from OpenBao `agents/anthropic` field `api_key`; optional `openrouter` (public only), `bedrock`/`vertexai` (internal), all off by default <!-- pragma: allowlist secret --> |
  | Price table (design D10) | ConfigMap `agent-model-prices` in `agent-gateway`, key `catalog.json`, named by `AgentgatewayParameters agent-router` `spec.modelCatalog` (phase J) |
  | Reference token (design D11) | a request's gateway price ÷ REF, REF = `0.0000017` USD per token ($1.70 per million). Every token descriptor's `cost` is `BILLABLE_COST` = `has(llm.cost) ? uint(llm.cost.total / 0.0000017) : uint(llm.totalTokens)` (phase J) |
  | ADRs | **0053** (gateway), **0054** (providers) |

- **Pins** (resolved 2026-10-01 from the PoC; re-resolve on the day of Task B.2 with
  `helm show chart` and `crane digest`, and stop if they moved):
  - chart `agentgateway-crds` `v1.5.0@sha256:3a6cf44559c612ac8afb7f867aace69bbd4cdba765f1def6377b7a3186c603e3`;
  - chart `agentgateway` `v1.5.0@sha256:9216ce83965ad2ce0888014d14aac5e71333fd9d4057cd167da92b37630fbee1`;
  - controller image tag `v1.5.0@sha256:319489cb86b7f901a52a3fc532ad07f136c92756f88cf02a4040909e20001120`;
  - proxy image `cr.agentgateway.dev/agentgateway:v1.5.0@sha256:bf2f339ef326d32def2aaeb44b1b4549801293c19b89e764a4228667d97d9896`;
  - `docker.io/envoyproxy/ratelimit:0482748e@sha256:5fdd8e3ae335ab6d64316f8d2fd9a886830075cbbb40a1d8065c869275909162`.
- **Unchanged contracts.** Audiences `agent-router.<role>.<class>` and `octo-sts/Smana/cloud-native-ref/<role>`,
  issuer and JWKS vars (`${oidc_issuer_url}`, `${oidc_jwks_uri}`, `${oidc_jwks_host}`), listener
  ports, the identity-proxy's localhost ports, the four C5 identity headers. A token valid on one
  gateway is valid on the other (D2).
- **Both clouds.** Bases are cloud-neutral; render roots `infrastructure/{aws-0,gcp-0}/{agentgateway,agent-gateway}`;
  Flux children in both `clusters/aws-0-agent-platform/` and `clusters/gcp-0-agent-platform/`, substituting
  `eks-aws-0-vars` and `gke-gcp-0-vars`. Nothing on the default path is cloud-specific (Z.ai and
  Anthropic serve both clouds); only the optional Bedrock/Vertex backends are. aws-0 is destroyed: CI renders it.
- **No merge, no release tag before the owner's UX sign-off** (SP2 ruling P33, which binds this
  plan).
  - One stack per repo, merge-only, never rebased. Each PR is based on its *Base* (PR map).
  - Live gates run on `integration/agent-factory` on **gcp-0**, with CI pre-releases pinned by
    digest and `XRD_CRDS_FILE` from `./scripts/ci/fetch-xrd-crds.sh` (SP2 H-1, P40).
  - The crossplane-configuration pre-release is named after the PR's **synthetic merge commit**:
    copy it from the CI job summary, never derive it from a SHA.
  - Crossplane never upgrades an installed dependency. During a live check, patch the core package
    by hand: `kubectl patch configuration.pkg.crossplane.io smana-crossplane-configuration-core --type merge -p '{"spec":{"package":"ghcr.io/smana/crossplane-configuration-core:<pre-release>"}}'`.
- **Never merge `feat/agent-router-agentgateway` or `feat/agentgateway-poc` into a stack branch.**
  Both are cut from `integration/agent-factory` and carry its do-not-merge content (`feat/gcp-primary`).
  AGW-1 cherry-picks every `docs(...)` commit of the design branch instead (Task A.1 Step 2).
- **Flux substitution.** Every directory below is applied with `postBuild.substituteFrom`: a literal
  `${…}` that is not a cluster var is written `$${…}`. Bare `$1` in relabel replacements passes Flux
  untouched. `python3 scripts/ci/flux-schema/check-substitution.py` fails otherwise.
- **Constitution.** Default-deny CNP on every new pod set; requests and limits; liveness and
  readiness probes; restricted securityContext with `seccompProfile: RuntimeDefault`; no hardcoded
  credential (ESO only); `xplane-` prefix on the KVStore claim.
- **Memory.** Wrap every `go test`, `task check` and `validate-manifests.sh` run in
  `systemd-run --user --scope -q -p MemoryMax=6G -p MemorySwapMax=0`. Never run two
  `validate-manifests.sh` in one checkout at once (they race on `.bundle/`).
- **Evidence.** No "done / passing" without a command run in the same response and its output
  cited.
  - This repo: `export XRD_CRDS_FILE="$(./scripts/ci/fetch-xrd-crds.sh)" && ./scripts/ci/validate-manifests.sh`
    → exit 0 with `Invalid: 0, Skipped: 0` and `assert-agent-gateway: 9 checks, 0 violations` (from
    Task B.5 on; `10 checks` from Task J.1 on), then `./scripts/ci/validate-links.sh`, `./scripts/ci/verify-doc-paths.sh`,
    `python3 scripts/ci/flux-schema/check-substitution.py`, `./scripts/ci/validate-vmrules.sh` and
    `task check` → exit 0.
  - crossplane-configuration: `task check` → exit 0. agent-platform: `go test ./...` → `ok`.
- **Git.** Conventional commits in English, no `Co-Authored-By` trailer, no generated-with line.
  Merge the stack parent and `origin/main` in before each push; never rebase. `ship-it`'s simplify,
  prune, gates and review apply; its merge does not (P33).

**Markers.** **[LIVE]** needs gcp-0 running `integration/agent-factory` with the named PRs merged
in (merge commits). **[OWNER]** needs the owner; the executor stops and asks.

---

## Pre-flight rulings

The design's D1–D8 bind. These are the plan's own:

| # | Ruling | Why | Cost if wrong |
|---|---|---|---|
| R1 | The AGW stack's base is **`feat/rooms-driver` (#2150)**, the head of SP2's chain. SP3's chain (`feat/factory-pair`, #2153) is a sibling and meets this stack only in the merge wave | The MCP routes carry room-broker (SP2 phase 3); the collector CNP and dashboards come from O-1, which `feat/rooms-driver` contains. Nothing here needs SP3 code | One conflict in `agent-traces-collector.yaml`'s :4317 rule at wave time, resolved by keeping both peers |
| R2 | The gate is written and unit-tested in phase A and **wired into `validate-manifests.sh` in phase B**, in the same PR as the Gateway and its listener policies | Wired in A, AG1 fails the build (no Gateway yet); a Gateway without its JWT policies must never render either | — |
| R3 | The agentgateway OCIRepositories live in `infrastructure/base/agentgateway/`, not `flux/sources/`, and the namespace `agentgateway-system` is declared there too | As in the PoC: `flux-sources` applies with no platform gate, and moving the namespace between Kustomizations during the PoC → real handover would let the old child's prune delete it | Two locations for sources; `gen-catalog.sh` reads this file |
| R4 | `agent-gateway` is declared in `namespaces/base/`, like `agent-system` | Policies, the KVStore claim and CNPs land there before and after the Gateway child; the namespace must outlive it | An empty namespace on a cluster with the platform suspended |
| R5 | The real child takes over the PoC child's **name** `agentgateway`, and the PoC teardown is a commit on `feat/agentgateway-poc` merged into integration together with AGW-2 | Same name and same HelmRelease names: Flux adopts instead of deleting and re-creating the controller | If merged apart, the controller is uninstalled for one interval |
| R6 | The run CNP and the MCP/octo-sts/room-broker/collector ingress CNPs gain **additive** selectors for the new proxies (phases C, E, F) and lose the Envoy ones only in phase H | Run-beside needs both paths; removing early breaks rollback | A wider window, bounded by the namespace + label pins |
| R7 | `test-agent-mcp-scope.sh` keeps its MCPRoute checks until phase H and gains an agentgateway check in phase C, both against the same `EXPECTED_ROLE_TOOLS` | One source of truth for per-role tool sets across the overlap | — |
| R8 | The drain ships at `{min: 120, max: 660}`; Task G.4 tries `min: 10` and phase H lowers it only if a stream survives two rollouts | PoC N1: 120/660 is proven, `max`-alone is not | 120 s per pod on every rollout until then |
| R9 | Anthropic is pinned to `internal`, Z.ai and OpenRouter to `public` (gate AG5, Task I.1) | B6 can then be a listener-scoped policy, and no provider sees the other class's data | If a team wants Anthropic on `public`, B6 needs the CEL fallback of Task I.4 Step 4 |

## PR map

`AGW-*` is this repo, `CC-*` `Smana/crossplane-configuration`, `AP-*` `Smana/agent-platform`.
**Nothing merges before the owner's UX sign-off** (P33).

| # | Repo · branch | Base (stack parent) | Phase | Carries | Live gate (gcp-0) |
|---|---|---|---|---|---|
| AGW-1 | this · `feat/agw-gate` | `feat/rooms-driver` (#2150) | A | design, plan, ADR-0053, ADR-0054, programme-spec alignment (cherry-picked); CRD schemas in the local catalog; `assert-agent-gateway.py` + tests | — |
| AGW-2 | this · `feat/agw-platform` | AGW-1 | B | controller, Gateway, parameters, listener identity, CNPs, both clouds; gate wired | B.6 |
| — | this · `feat/agentgateway-poc` | (existing) | B | PoC teardown commit (R5) | B.6 |
| AGW-3 | this · `feat/agw-routes` | AGW-2 | C | LLM, `/v1/models`, MCP, octo-sts route, additive ingress CNPs, probe | C.5 |
| AGW-4 | this · `feat/agw-budgets` | AGW-3 | D | rate-limit server, KVStore, B1–B2 shadow | D.3 |
| AGW-5 | this · `feat/agw-observability` | AGW-4 | E | telemetry, scrape relabel, alerts, dashboards | E.4 |
| AP-AGW1 | agent-platform · `feat/bridge-agentgateway-tools` | `feat/room-approvals` (#11) | F | classifier reads `<server>_<tool>` | via AGW-6 |
| CC-AGW1 | crossplane-configuration · `feat/agentrun-agentgateway` | `chore/room-bridge-v0.4.0` (#35) | F | run CNP reaches both gateways; AP-AGW1's bridge pin | via AGW-6 |
| AGW-6 | this · `feat/agw-cutover` | AGW-5 | F | CC-AGW1 pin; identity-proxy → agentgateway | phase G |
| CC-AGW2 | crossplane-configuration · `feat/agentrun-agentgateway-only` | CC-AGW1 | H | run CNP reaches agentgateway only | H.4 |
| AGW-7 | this · `feat/agw-remove-envoy-router` | AGW-6 | H | Envoy agent-router deleted; A5–A7 retired; docs | H.4 |
| AGW-8 | this · `feat/agent-frontier-tiers` | AGW-7 | I | Anthropic backend on `internal`, tiers, B6, budget alerts (SP4 PR 2's agent half) | I.2, I.4, I.6 on gcp-0 |
| AGW-9 | this · `feat/agw-prompt-caching` | AGW-8 | J | price table, AG10, reference-token budgets, Anthropic caching intent, token-type relabel, run page, run-token rule and alerts | J.7, J.8 on gcp-0 |
| — | this · SP3's stack head (`feat/factory-pair` on 2026-10-04) | (existing) | J | the run meter's query in reference tokens (Task J.5 Step 5) | J.7 |

**Live-check routine** (each [LIVE] step): merge the PR into `integration/agent-factory` with a merge
commit; if it pins a crossplane-configuration pre-release, hand-patch the core package (Global
Constraints); run the evidence command; wait for Ready one child per call
(`flux get kustomization agentgateway -n flux-system`, then `agent-gateway`, `agent-mcp`, …).

**Merge order in the wave** (P33 Phase 7): agent-platform AP-AGW1 after #11; crossplane-configuration
CC-AGW1 → CC-AGW2 after #35, then one release tag; this repo AGW-1 → … → AGW-9 after #2150, each
re-pinned to the release. Task J.5 Step 5's commit merges with SP3's PR that carries it.

## File structure

**This repo**

| Path | Phase | Responsibility |
|---|---|---|
| `scripts/ci/flux-schema/gen-catalog.sh` | A | Render `agentgateway-crds` from the pinned OCIRepository into `.schemas/agentgateway.dev/` |
| `scripts/ci/flux-schema/assert-agent-gateway.py`, `scripts/ci/tests/flux-schema/test-assert-agent-gateway.py` | A | AG1–AG9 and their tests |
| `scripts/ci/validate-manifests.sh`, `scripts/AGENTS.md` | B | Wire gate 3b |
| `scripts/ci/flux-schema/assert-cloud-shape.py`, its test | B | Learn the `agentgateway` and `agent-gateway` overlays |
| `namespaces/base/agent-gateway.yaml`, `namespaces/base/kustomization.yaml` | B | The data-plane namespace |
| `infrastructure/base/agentgateway/` (`kustomization.yaml`, `namespace.yaml`, `ocirepositories.yaml`, `helmrelease-crds.yaml`, `helmrelease.yaml`, `network-policy.yaml`) | A (sources), B | The controller |
| `infrastructure/{aws-0,gcp-0}/agentgateway/kustomization.yaml` | B | Render roots |
| `infrastructure/base/agent-gateway/` (`gateway.yaml`, `parameters.yaml`, `policies-identity.yaml`, `network-policy.yaml`, `kustomization.yaml`) | B | Gateway, G3 overlay, listener identity, data-plane CNP |
| `infrastructure/base/agent-gateway/{ratelimit.yaml,kvstore.yaml,externalsecret-valkey.yaml,policy-budgets.yaml}` | D | Budgets |
| `infrastructure/base/agent-gateway/{policy-telemetry.yaml,vmpodscrape.yaml}` | E | Telemetry |
| `infrastructure/{aws-0,gcp-0}/agent-gateway/kustomization.yaml` | B | Render roots |
| `clusters/{aws-0,gcp-0}-agent-platform/infrastructure-{agentgateway,agent-gateway}.yaml`, `kustomization.yaml` | B | Flux children |
| `infrastructure/base/agent-router/agentgateway-llm.yaml` | C | `zai` backend, `agent-models`, `agent-models-list` and its 404 |
| `infrastructure/base/agent-mcp/agentgateway-mcp.yaml` | C | MCP backend, two routes, two Allow lists |
| `security/base/octo-sts/httproute.yaml`, `security/base/octo-sts/network-policy.yaml` | C | Second parent; new ingress peer |
| `infrastructure/base/agent-mcp/{flux-operator-mcp-network-policy,mcp-victoriametrics,mcp-victorialogs}.yaml`, `infrastructure/base/room-broker/network-policy.yaml` | C | New ingress peer |
| `scripts/ops/k8s/agent-probe.yaml`, `scripts/ops/k8s/agent-probe-mcp.sh` | C | Probe either gateway |
| `scripts/ci/tests/test-agent-mcp-scope.sh` | C | Per-role tool sets from the Allow lists |
| `observability/base/agent-platform/{agent-traces-collector.yaml,referencegrant-agent-traces.yaml,vmrule.yaml,vmrule-logs.yaml,grafana-dashboard-agent-run.yaml}`, `scripts/ci/tests/test-agent-observability.py` | E | Collector peer, grant, alerts, dashboards |
| `infrastructure/base/agent-runtime/identity-proxy-configmap.yaml`, `infrastructure/base/crossplane/configuration-{aws,gcp}/configuration-packages.yaml` | F | The switch; CC-AGW1 pin |
| `infrastructure/base/agent-router/*` (Envoy objects), `infrastructure/base/agent-mcp/mcproutes.yaml`, `scripts/ci/flux-schema/assert-ai-gateway.py` A5–A7 | H | Removal |
| `docs/runbooks/agent-factory/{02,04,06,08}-*.md`, `website/content/docs/platform/ai-platform/gateways.md`, `website/content/docs/platform/ai-platform/agents/*.md`, `website/content/docs/platform/ai-platform/observability.md`, `website/content/docs/platform/ai-platform/status.md` | H | Docs (the restructured AI Platform section, on `main` first) |
| `infrastructure/base/agent-router/{externalsecret-anthropic,agentgateway-anthropic,agentgateway-llm}.yaml`, `infrastructure/base/agent-gateway/policy-budgets-providers.yaml`, `infrastructure/base/agent-model-routing/` | I | Anthropic backend, tiers, B6, alerts and prices |
| `infrastructure/base/agent-gateway/model-prices.yaml`, `parameters.yaml` (`modelCatalog`) | J | The one price table |
| `infrastructure/base/agent-gateway/{policy-budgets,policy-budgets-providers,ratelimit,vmpodscrape}.yaml` | J | Reference-token budgets; the token-type relabel |
| `infrastructure/base/agent-router/agentgateway-anthropic.yaml` | J | Anthropic's caching intent |
| `infrastructure/base/agent-model-routing/vmrule-agent-budgets.yaml`, `observability/base/agent-platform/{vmrule.yaml,grafana-dashboard-agent-run.yaml}`, `scripts/ci/tests/test-agent-observability.py` | J | Run tokens, alerts, the run page |
| `scripts/ci/flux-schema/assert-agent-gateway.py` (AG8, AG10), its test, `scripts/AGENTS.md` | J | The gate |
| `container-images/agent-harness/{agent_run.py,tests/test_agent_run.py}` | J | The price comment; the prompt-prefix pin |
| `website/content/docs/decisions/0050-token-budgets-envoy-gateway-rate-limit.md` | J | The reference-token unit |
| `infrastructure/base/agent-router/optional/openrouter/` (unreferenced), Bedrock/Vertex overlays | Appendix | Optional backends, off by default |

**crossplane-configuration**: `apis/agentrun/kcl/main.k` (`_ROUTER_FQDNS`, `_ROUTER_ENDPOINTS`, `_BRIDGE_IMAGE`),
`apis/agentrun/kcl/main_test.k`, `tests/golden/agentrun-{basic,complete}.yaml`, `apis/agentrun/kcl/README.md`.

**agent-platform**: `internal/bridge/classify.go`, `internal/bridge/classify_test.go`.

**SP3's stack in this repo** (Task J.5 Step 5): `tooling/base/agent-factory/helm-values-configmap.yaml`.

## Success criteria → proving task

| SC (design) | Offline | Live |
|---|---|---|
| SC-1 model calls in agentgateway's logs, attributed | C.1 | G.3 |
| SC-2 wrong-namespace token → 403 | A.3 (AG2) | C.5, G.2 |
| SC-3 forged `x-ar-agent` never reaches a backend | A.3 (AG3) | C.5, G.2 |
| SC-4 per-role tool sets, no `Authorization` to MCP, room key | C.2 | C.5, G.3 |
| SC-5 GitHub token through `sts` | A.3 (AG4) | G.3 |
| SC-6 B1/B2 shadow counters on the KVStore | D.2 | D.3, G.3 |
| SC-7 stream survives a rollout, charged | A.3 (AG9) | G.4 |
| SC-8 dashboards | E.3 | G.3 |
| SC-9 trace joined, no `http.path` | E.1 | G.3 |
| SC-10 rollback drill | — | G.4 |
| SC-11 no Envoy agent-router left | H.2 | H.4 |
| SC-12 internal on Claude, never Z.ai | I.1 (AG5) | I.2, I.6 |
| SC-13 B6 counts Anthropic tokens, B1–B2 too | I.4 | I.4 |
| SC-14 cache reads, no provider field in the request | J.3 (AG10), J.6 | J.7 |
| SC-15 budgets and the run meter in reference tokens | J.2, J.5 (AG8) | J.7 |
| SC-16 run page cache view, exact pricing | J.1 (AG10), J.4 | J.7 |
| SC-17 the same task twice, measured | — | J.8 |

## Owner actions

| Marker | Task | What |
|---|---|---|
| [OWNER] | G.5 | Decide phase H after the evidence table (the exit criterion: every gate + 10 clean real runs) |
| [OWNER] | I.2 | Prerequisite P1: store the Anthropic API key (below) |
| [OWNER] | I.6 | Rotate the Anthropic key once (drill), and revoke the old one |
| [OWNER] | — | The programme's UX sign-off (P33) before any merge |

## Owner prerequisites

| # | Before | Action |
|---|---|---|
| P1 | Task I.2 Step 6 | **Store the Anthropic API key at OpenBao mount `agents`, secret `anthropic`, field `api_key`** (KV v2: API path `agents/data/anthropic`). The `agents-secrets` policy already reads `agents/data/*`; nothing else changes. The key comes from stdin, never argv: <!-- pragma: allowlist secret --> |

```bash
# Paste the key, then Ctrl-D (or pipe it from a password manager). `api_key=-` reads stdin,
# so the key never appears in argv, shell history or `ps`.
bao kv put -mount=agents anthropic api_key=-
bao kv get -mount=agents -field=api_key anthropic | wc -c     # > 1, without printing the key
```

The key belongs to an Anthropic workspace used only by agents; set a monthly spend limit on that
workspace as B6's provider-side backstop.

---

## Phase A — AGW-1: the gate and pinned schemas first (N10)

Gate: the unit tests pass, `gen-catalog.sh` builds `agentgateway.dev` schemas, every evidence gate
exits 0, AGW-1 open as a draft on `feat/rooms-driver`.

### Task A.1: Worktree, stack, the design commits

- [ ] **Step 1: Worktree on the stack parent**

`EnterWorktree` with branch `feat/agw-gate`, then `git reset --hard origin/feat/rooms-driver` before
the first commit (the tool branches from `origin/main`; this branch stacks). Merge `origin/main` in:
the pre-push hook requires it.

- [ ] **Step 2: Cherry-pick every docs commit of the design branch**

Run: `git log --reverse --no-merges --format='%h %s' origin/integration/agent-factory..origin/feat/agent-router-agentgateway`
Expected: only `docs(...)` commits, oldest first. On 2026-10-02 they are, by subject:

1. `docs(agents): design for the agent router on agentgateway`
2. `docs(adr): ADR-0053, the agent router runs on agentgateway`
3. `docs(agents): implementation plan for the agent router on agentgateway`
4. `docs(adr): ADR-0054, internal agent work calls the Anthropic API directly`
5. `docs(agents): agent router design follows the cloud-agnostic provider strategy`
6. `docs(agents): phase I becomes the Anthropic backend and budgets, on gcp-0`
7. `docs(agents): phase H gate proves internal by probe; dependsOn audit; A.1 picks the whole range`
8. `docs(agents): programme spec's data class follows ADR-0054`

Any later `docs(...)` commit on the branch belongs here too. Stop if a non-`docs` commit appears.
Pick the whole range, so ADR-0054 and the provider updates are never dropped:

```bash
git cherry-pick $(git rev-list --reverse --no-merges origin/integration/agent-factory..origin/feat/agent-router-agentgateway)
```

Never merge that branch (Global Constraints).

- [ ] **Step 3: The base carries both umbrellas suspended**

Run: `grep -n '^  suspend:' clusters/aws-0/agent-platform.yaml clusters/aws-0/ai-gateway.yaml`
Expected: `suspend: true` twice.

### Task A.2: The agentgateway CRD schemas come from the pinned chart

**Files:**
- Create: `infrastructure/base/agentgateway/ocirepositories.yaml`
- Modify: `scripts/ci/flux-schema/gen-catalog.sh`

**Interfaces:**
- Produces: `.schemas/agentgateway.dev/{agentgatewaybackend,agentgatewaypolicy,agentgatewayparameters,agentgatewaymodel}_v1alpha1.json`,
  generated from the same OCIRepository Flux installs (Task B.2 references this file).

- [ ] **Step 1: The failing check.** The catalog has no local agentgateway schema:

Run: `./scripts/ci/flux-schema/gen-catalog.sh >/dev/null && ls .schemas/agentgateway.dev/ 2>&1 | head -1`
Expected: `ls: cannot access '.schemas/agentgateway.dev/'`.

- [ ] **Step 2: The source of truth.** Create `infrastructure/base/agentgateway/ocirepositories.yaml`:

```yaml
# Pinned by tag AND digest (ADR-0053: a new minor only at its first patch
# release, after reading its breaking changes). gen-catalog.sh reads the url
# and tag here, so CI validates against the schemas Flux installs.
# Not under flux/sources: that child applies with no platform gate.
apiVersion: source.toolkit.fluxcd.io/v1
kind: OCIRepository
metadata:
  name: agentgateway-crds
  namespace: agentgateway-system
spec:
  interval: 24h
  url: oci://cr.agentgateway.dev/charts/agentgateway-crds
  ref:
    tag: "v1.5.0"
    digest: sha256:3a6cf44559c612ac8afb7f867aace69bbd4cdba765f1def6377b7a3186c603e3
---
apiVersion: source.toolkit.fluxcd.io/v1
kind: OCIRepository
metadata:
  name: agentgateway
  namespace: agentgateway-system
spec:
  interval: 24h
  url: oci://cr.agentgateway.dev/charts/agentgateway
  ref:
    tag: "v1.5.0"
    digest: sha256:9216ce83965ad2ce0888014d14aac5e71333fd9d4057cd167da92b37630fbee1
```

- [ ] **Step 3: Render and extract.** In `scripts/ci/flux-schema/gen-catalog.sh`:

Add to the header's source list, after item 6:

```bash
#   7. agentgateway CRDs               -> agentgateway.dev/*
#      (PRESENT in the hosted ecosystem catalog but tracking upstream daily, not
#      our pin: v1alpha1 breaks every minor, so the local copy must win; PoC N10)
```

After the Karpenter version block, add:

```bash
# The first document in the file is the CRD chart's OCIRepository.
AGW_SOURCE="infrastructure/base/agentgateway/ocirepositories.yaml"
AGW_CHART="$(sed -nE 's#^[[:space:]]*url:[[:space:]]*"?(oci://[^"[:space:]]+-crds)"?[[:space:]]*$#\1#p' "${AGW_SOURCE}" | head -n1 || true)"
AGW_VERSION="$(sed -nE 's/^[[:space:]]*tag:[[:space:]]*"?(v?[0-9][^"[:space:]]*)"?[[:space:]]*$/\1/p' "${AGW_SOURCE}" | head -n1 || true)"
if [[ -z "${AGW_CHART}" || -z "${AGW_VERSION}" ]]; then
  echo "error: could not read the agentgateway CRD chart url/tag from ${AGW_SOURCE}" >&2
  exit 1
fi
```

After the Karpenter `helm template` call, add:

```bash
echo "==> Rendering agentgateway CRDs (chart ${AGW_VERSION})"
"${HELM_BIN}" template agw-crds "${AGW_CHART}" --version "${AGW_VERSION}" --include-crds \
  > "${tmp}/agentgateway-crds.yaml"
```

After the Karpenter `schema extract` line, add:

```bash
"${FLUX_BIN}" schema extract crd "${tmp}/agentgateway-crds.yaml" -d "${build_dir}"
```

After the EC2NodeClass assertion, add:

```bash
for kind in agentgatewaybackend agentgatewaypolicy agentgatewayparameters agentgatewaymodel; do
  if [[ ! -s "${build_dir}/agentgateway.dev/${kind}_v1alpha1.json" ]]; then
    echo "error: catalog build produced no agentgateway.dev/${kind}_v1alpha1.json (chart ${AGW_VERSION})" >&2
    exit 1
  fi
done
```

- [ ] **Step 4: It builds, and the local schema is the one used**

Run: `./scripts/ci/flux-schema/gen-catalog.sh && ls .schemas/agentgateway.dev/`
Expected: exit 0; the four `*_v1alpha1.json` files.

Prove the local copy wins (the PoC validated against the hosted catalog). In a scratch copy of the
bundle, add a policy with a bogus field and validate:

```bash
mkdir -p /tmp/claude-agw && cat > /tmp/claude-agw/bogus.yaml <<'EOF'
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayPolicy
metadata: {name: bogus, namespace: agent-gateway}
spec:
  targetRefs: [{group: gateway.networking.k8s.io, kind: Gateway, name: agent-router}]
  traffic: {jwtAuthentication: {mode: Strict, notAField: true, providers: []}}
EOF
flux schema validate /tmp/claude-agw --config .fluxschema.yml; echo "exit=$?"
```

Expected: `Invalid: 1` naming `notAField`, `exit=1`. Then `rm -rf /tmp/claude-agw`.

- [ ] **Step 5: Commit**

```bash
git add infrastructure/base/agentgateway/ocirepositories.yaml scripts/ci/flux-schema/gen-catalog.sh
git commit -m "ci(flux-schema): validate agentgateway kinds against the pinned chart"
```

### Task A.3: `assert-agent-gateway.py`, AG1–AG9

**Files:**
- Create: `scripts/ci/flux-schema/assert-agent-gateway.py`
- Test: `scripts/ci/tests/flux-schema/test-assert-agent-gateway.py`

**Interfaces:**
- Produces: `run(objs: list[dict]) -> list[str]` (each violation starts with its check id, `AG1`…`AG9`),
  `main(argv) -> int` (0 clean, 1 violations, 2 no bundle), constants `LISTENERS`, `AUDIENCES`,
  `SUB_PREFIX`, `IDENTITY_HEADERS`, `ALTERNATIVE` (the N7 expression grammar, reused by Task C.2's
  scope test).

- [ ] **Step 1: Write the failing test.** Create `scripts/ci/tests/flux-schema/test-assert-agent-gateway.py`:

```python
#!/usr/bin/env python3
"""Tests for assert-agent-gateway.py, the agent router's cross-object gate.

Each invariant is pinned both ways: the compliant bundle passes, and each way of
breaking it fails with a message naming the check.

Run: python3 scripts/ci/tests/flux-schema/test-assert-agent-gateway.py
"""
import copy
import importlib.util
import pathlib
import sys
import tempfile

import yaml

HERE = pathlib.Path(__file__).resolve().parent
SUBJECT_DIR = HERE.parent.parent / "flux-schema"
sys.path.insert(0, str(SUBJECT_DIR))
spec = importlib.util.spec_from_file_location("assert_agent_gateway", SUBJECT_DIR / "assert-agent-gateway.py")
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)

FAILURES = []
ROLES = ("implementer", "reviewer", "tester", "triager")
GW_REF = {"group": "gateway.networking.k8s.io", "kind": "Gateway", "name": "agent-router"}


def check(name, condition, detail=""):
    print(f"  {'ok  ' if condition else 'FAIL'} {name}{'' if condition or not detail else ' -- ' + detail}")
    if not condition:
        FAILURES.append(name)


def obj(kind, ns, name, spec, api="agentgateway.dev/v1alpha1"):
    return {"apiVersion": api, "kind": kind, "metadata": {"namespace": ns, "name": name}, "spec": spec}


def listener_policy(section, auds, preserve=False):
    jwt = {"mode": "Strict", "providers": [{"issuer": "https://issuer.example", "audiences": sorted(auds),
                                            "jwks": {"remote": {"url": "https://issuer.example/jwks"}}}]}
    if preserve:
        jwt["preserveToken"] = True
    return obj("AgentgatewayPolicy", "agent-gateway", f"listener-{section}", {
        "targetRefs": [dict(GW_REF, sectionName=section)],
        "traffic": {"jwtAuthentication": jwt,
                    "authorization": {"action": "Require", "policy": {"matchExpressions": [gate.SUB_PREFIX]}},
                    "transformation": {"request": {"set": [{"name": "x-ar-agent", "value": "jwt.sub"}]}}}})


def route(name, section, backend, path=None):
    match = [{"path": path}] if path else [{"path": {"type": "PathPrefix", "value": "/v1"}}]
    rule = {"matches": match}
    if backend:
        rule["backendRefs"] = [{"group": "agentgateway.dev", "kind": "AgentgatewayBackend", "name": backend}]
    return obj("HTTPRoute", "agent-system", name, {
        "parentRefs": [dict(GW_REF, namespace="agent-gateway", sectionName=section)], "rules": [rule]},
        api="gateway.networking.k8s.io/v1")


def compliant():
    selector = {"from": "Selector", "selector": {"matchLabels": {"kubernetes.io/metadata.name": "agent-system"}}}
    objs = [
        obj("Gateway", "agent-gateway", "agent-router", {
            "gatewayClassName": "agentgateway",
            "listeners": [{"name": n, "port": p, "protocol": "HTTP", "allowedRoutes": {"namespaces": selector}}
                          for n, p in gate.LISTENERS.items()],
            "infrastructure": {"parametersRef": {"group": "agentgateway.dev", "kind": "AgentgatewayParameters",
                                                 "name": "agent-router"}}}, api="gateway.networking.k8s.io/v1"),
        obj("AgentgatewayParameters", "agent-gateway", "agent-router", {
            "image": {"digest": "sha256:" + "0" * 64}, "shutdown": {"min": 120, "max": 660},
            "resources": {"limits": {"cpu": "1", "memory": "512Mi"}},
            "service": {"spec": {"type": "ClusterIP"}}, "podDisruptionBudget": {"spec": {"minAvailable": 1}},
            "deployment": {"spec": {"replicas": 2, "template": {"spec": {
                "securityContext": {"seccompProfile": {"type": "RuntimeDefault"}},
                "containers": [{"name": "agentgateway",
                                "securityContext": {"seccompProfile": {"type": "RuntimeDefault"}},
                                "livenessProbe": {"httpGet": {"path": "/healthz/ready", "port": 15021}}}]}}}}}),
        obj("AgentgatewayPolicy", "agent-gateway", "strip-identity-headers", {
            "targetRefs": [GW_REF],
            "traffic": {"phase": "PreRouting",
                        "transformation": {"request": {"remove": list(gate.IDENTITY_HEADERS)}}}}),
        listener_policy("public", gate.AUDIENCES["public"]),
        listener_policy("internal", gate.AUDIENCES["internal"]),
        listener_policy("sts", gate.AUDIENCES["sts"], preserve=True),
        obj("AgentgatewayBackend", "agent-system", "zai", {"ai": {"provider": {"openai": {"model": "glm-5.3"}}}}),
        route("agent-models", "public", "zai"),
        route("agent-models-list", "public", None, {"type": "Exact", "value": "/v1/models"}),
        obj("AgentgatewayPolicy", "agent-system", "agent-models-list", {
            "targetRefs": [{"group": "gateway.networking.k8s.io", "kind": "HTTPRoute", "name": "agent-models-list"}],
            "traffic": {"directResponse": {"status": 404, "body": '{"error":"model listing is not served on agent-router"}'}}}),
        obj("AgentgatewayBackend", "agent-system", "agent-mcp", {"mcp": {"prefixMode": "Always", "targets": [
            {"name": "room-broker", "static": {"host": "room-broker.agent-system.svc.cluster.local", "port": 8090,
                                                "path": "/mcp", "protocol": "StreamableHTTP", "policies": {"auth": {
                                                    "credentials": [{"location": {"header": {"name": "x-room-mcp-key"}},
                                                                     "secretRef": {"name": "room-broker-mcp-key", "key": "apiKey"}}]}}}}]}}),
        route("agent-mcp-public", "public", "agent-mcp", {"type": "PathPrefix", "value": "/mcp"}),
        obj("AgentgatewayPolicy", "agent-system", "agent-mcp-public", {
            "targetRefs": [{"group": "gateway.networking.k8s.io", "kind": "HTTPRoute", "name": "agent-mcp-public"}],
            "backend": {"mcp": {"authorization": {"action": "Allow", "policy": {"matchExpressions": [
                '"agent-router.implementer.public" in jwt.aud && mcp.tool.target == "room-broker"'
                ' && mcp.tool.name in ["room_read", "room_post"]']}}}}}),
        obj("AgentgatewayPolicy", "agent-gateway", "token-budgets", {
            "targetRefs": [GW_REF],
            "traffic": {"rateLimit": {"global": {
                "backendRef": {"name": "agent-ratelimit", "port": 8081}, "domain": "agent-router",
                "failureMode": "FailOpen", "descriptors": [
                    {"entries": [{"name": "agent", "expression": "jwt.sub"}], "unit": "Tokens"},
                    {"entries": [{"name": "fleet", "expression": '"agents"'}], "unit": "Tokens"}]}}}}),
        {"apiVersion": "v1", "kind": "ConfigMap", "metadata": {"namespace": "agent-gateway", "name": "agent-ratelimit-config"},
         "data": {"config.yaml": yaml.safe_dump({"domain": "agent-router", "descriptors": [
             {"key": "agent", "rate_limit": {"unit": "day", "requests_per_unit": 5000000}, "shadow_mode": True},
             {"key": "fleet", "value": "agents", "rate_limit": {"unit": "day", "requests_per_unit": 40000000}, "shadow_mode": True}]})}},
    ]
    return objs


def find(objs, kind, name):
    return next(o for o in objs if o["kind"] == kind and o["metadata"]["name"] == name)


def violations_after(mutate):
    objs = copy.deepcopy(compliant())
    mutate(objs)
    return gate.run(objs)


def expect(name, mutate, code):
    v = violations_after(mutate)
    check(name, any(x.startswith(code) for x in v), f"got {v}")


print("compliant bundle")
base = gate.run(compliant())
check("compliant bundle passes", base == [], f"got {base}")

print("AG1 gateway")
expect("no Gateway fails", lambda o: o.remove(find(o, "Gateway", "agent-router")), "AG1")
expect("a dropped listener fails", lambda o: find(o, "Gateway", "agent-router")["spec"]["listeners"].pop(), "AG1")
expect("listener from Same fails", lambda o: find(o, "Gateway", "agent-router")["spec"]["listeners"][0]
       ["allowedRoutes"].update({"namespaces": {"from": "All"}}), "AG1")

print("AG2 listener identity")
expect("a missing listener policy fails", lambda o: o.remove(find(o, "AgentgatewayPolicy", "listener-internal")), "AG2")
expect("an internal audience on public fails", lambda o: find(o, "AgentgatewayPolicy", "listener-public")["spec"]["traffic"]
       ["jwtAuthentication"]["providers"][0]["audiences"].append("agent-router.implementer.internal"), "AG2")
expect("Allow instead of Require fails", lambda o: find(o, "AgentgatewayPolicy", "listener-public")["spec"]["traffic"]
       ["authorization"].update({"action": "Allow"}), "AG2")
expect("no x-ar-agent set fails", lambda o: find(o, "AgentgatewayPolicy", "listener-sts")["spec"]["traffic"]
       .pop("transformation"), "AG2")

print("AG3 strip")
expect("a strip missing agent-session-id fails", lambda o: find(o, "AgentgatewayPolicy", "strip-identity-headers")["spec"]
       ["traffic"]["transformation"]["request"]["remove"].remove("agent-session-id"), "AG3")

print("AG4 token isolation")
expect("preserveToken on public fails", lambda o: find(o, "AgentgatewayPolicy", "listener-public")["spec"]["traffic"]
       ["jwtAuthentication"].update({"preserveToken": True}), "AG4")
expect("no preserveToken on sts fails", lambda o: find(o, "AgentgatewayPolicy", "listener-sts")["spec"]["traffic"]
       ["jwtAuthentication"].pop("preserveToken"), "AG4")
expect("an MCP key in Authorization fails", lambda o: find(o, "AgentgatewayBackend", "agent-mcp")["spec"]["mcp"]["targets"][0]
       ["static"]["policies"]["auth"]["credentials"][0]["location"]["header"].update({"name": "Authorization"}), "AG4")
expect("auth.secretRef (default Authorization) fails", lambda o: find(o, "AgentgatewayBackend", "agent-mcp")["spec"]["mcp"]
       ["targets"][0]["static"]["policies"].update({"auth": {"secretRef": {"name": "k"}}}), "AG4")

print("AG5 routes")
expect("no sectionName fails", lambda o: find(o, "HTTPRoute", "agent-models")["spec"]["parentRefs"][0].pop("sectionName"), "AG5")
expect("zai on internal fails", lambda o: find(o, "HTTPRoute", "agent-models")["spec"]["parentRefs"][0]
       .update({"sectionName": "internal"}), "AG5")
expect("route-level jwtAuthentication fails", lambda o: find(o, "AgentgatewayPolicy", "agent-mcp-public")["spec"]
       .update({"traffic": {"jwtAuthentication": {"mode": "Strict"}}}), "AG5")

print("AG6 MCP authorization")
expect("a role-only expression fails", lambda o: find(o, "AgentgatewayPolicy", "agent-mcp-public")["spec"]["backend"]["mcp"]
       ["authorization"]["policy"]["matchExpressions"].append('"agent-router.reviewer.public" in jwt.aud'), "AG6")
expect("an || expression fails", lambda o: find(o, "AgentgatewayPolicy", "agent-mcp-public")["spec"]["backend"]["mcp"]
       ["authorization"]["policy"]["matchExpressions"].append(
           '"agent-router.reviewer.public" in jwt.aud || mcp.tool.name == "room_post"'), "AG6")
expect("an internal audience on a public route fails", lambda o: find(o, "AgentgatewayPolicy", "agent-mcp-public")["spec"]
       ["backend"]["mcp"]["authorization"]["policy"]["matchExpressions"].append(
           '"agent-router.implementer.internal" in jwt.aud && mcp.tool.target == "room-broker" && mcp.tool.name in ["room_read"]'), "AG6")

print("AG7 /v1/models")
expect("no /v1/models answer fails", lambda o: o.remove(find(o, "AgentgatewayPolicy", "agent-models-list")), "AG7")

print("AG8 budgets")
expect("FailClosed fails", lambda o: find(o, "AgentgatewayPolicy", "token-budgets")["spec"]["traffic"]["rateLimit"]["global"]
       .update({"failureMode": "FailClosed"}), "AG8")
expect("a request-unit descriptor fails", lambda o: find(o, "AgentgatewayPolicy", "token-budgets")["spec"]["traffic"]
       ["rateLimit"]["global"]["descriptors"][0].update({"unit": "Requests"}), "AG8")
expect("a route-keyed entry fails", lambda o: find(o, "AgentgatewayPolicy", "token-budgets")["spec"]["traffic"]
       ["rateLimit"]["global"]["descriptors"][0]["entries"].append({"name": "route", "expression": "request.path"}), "AG8")


def unshadow(o):
    cm = find(o, "ConfigMap", "agent-ratelimit-config")
    cfg = yaml.safe_load(cm["data"]["config.yaml"])
    cfg["descriptors"][0]["shadow_mode"] = False
    cm["data"]["config.yaml"] = yaml.safe_dump(cfg)


expect("an enforcing descriptor fails", unshadow, "AG8")
expect("a missing ConfigMap fails", lambda o: o.remove(find(o, "ConfigMap", "agent-ratelimit-config")), "AG8")

print("AG9 parameters")
expect("a LoadBalancer Service fails", lambda o: find(o, "AgentgatewayParameters", "agent-router")["spec"]["service"]["spec"]
       .update({"type": "LoadBalancer"}), "AG9")
expect("the default drain fails", lambda o: find(o, "AgentgatewayParameters", "agent-router")["spec"]
       .update({"shutdown": {"min": 10, "max": 60}}), "AG9")
expect("no liveness probe fails", lambda o: find(o, "AgentgatewayParameters", "agent-router")["spec"]["deployment"]["spec"]
       ["template"]["spec"]["containers"][0].pop("livenessProbe"), "AG9")

print("main")
with tempfile.TemporaryDirectory() as d:
    pathlib.Path(d, "bundle.yaml").write_text(yaml.safe_dump_all(compliant()))
    check("main exits 0 on the compliant bundle", gate.main(["x", d]) == 0)
    check("main exits 2 on a missing bundle", gate.main(["x", d + "/missing"]) == 2)

if FAILURES:
    print(f"\n{len(FAILURES)} failure(s)")
    sys.exit(1)
print("\nall passed")
```

- [ ] **Step 2: Run it to see it fail**

Run: `python3 scripts/ci/tests/flux-schema/test-assert-agent-gateway.py`
Expected: `FileNotFoundError` for `assert-agent-gateway.py`.

- [ ] **Step 3: Write the gate.** Create `scripts/ci/flux-schema/assert-agent-gateway.py` (mode 0755):

```python
#!/usr/bin/env python3
"""Gate the rendered bundle on the agent router's invariants (ADR-0042, ADR-0053).

The agent router is the Gateway agent-gateway/agent-router of class agentgateway.
Each check relates objects that `flux schema validate` sees one at a time, and
breaking any of them leaves every object valid and the boundary quietly open:

  AG1  Exactly one Gateway of class agentgateway, agent-gateway/agent-router,
       with listeners public:8080, internal:8081, sts:8082, each admitting
       routes from agent-system only. Zero is a layout regression.
  AG2  Each listener has exactly one listener-scoped jwtAuthentication (mode
       Strict) whose audiences equal its class set, an authorization Require on
       the `agents` sub prefix, and a `set` of x-ar-agent from jwt.sub.
  AG3  A Gateway-scoped PreRouting transformation removes the four identity
       headers before routing.
  AG4  preserveToken is true on the sts listener and nowhere else, and no MCP
       target credential or transformation writes Authorization.
  AG5  Every route on agent-router sets sectionName and lives in agent-system;
       the zai backend is reachable from `public` only; no policy other than
       the listener ones carries jwtAuthentication.
  AG6  Every MCP authorization is an Allow list whose expressions are each one
       complete alternative (role AND target AND tool names), for the route's
       own class: Allow expressions are OR-ed at runtime (PoC N7).
  AG7  Every listener with an LLM route answers an Exact /v1/models with a
       404 direct response (PoC N3).
  AG8  Every rateLimit.global fails open, charges Tokens, names no route or
       backend, and its domain resolves to a rate-limit ConfigMap whose
       matching descriptors are in shadow mode.
  AG9  The Gateway's AgentgatewayParameters keeps the constitution's pod shape
       (seccomp, liveness, memory limit), ClusterIP, 2 replicas, a PDB, a
       digest-pinned image, and a drain of at least 660 s (PoC N1).

Usage: assert-agent-gateway.py [BUNDLE_DIR]    (default .bundle)
Exit:  0 clean, 1 violations (each printed), 2 bundle missing.
"""
import pathlib
import re
import sys

import yaml

from yamlcompat import YAML_LOADER

CLASS = "agentgateway"
GW_NS, GW_NAME = "agent-gateway", "agent-router"
ROUTES_NS = "agent-system"
LISTENERS = {"public": 8080, "internal": 8081, "sts": 8082}
ROLES = ("implementer", "reviewer", "tester", "triager")
AUDIENCES = {
    "public": {f"agent-router.{r}.public" for r in ROLES},
    "internal": {f"agent-router.{r}.internal" for r in ROLES},
    "sts": {f"octo-sts/Smana/cloud-native-ref/{r}" for r in ROLES},
}
SUB_PREFIX = 'jwt.sub.startsWith("system:serviceaccount:agents:")'
IDENTITY_HEADERS = ("x-ar-agent", "x-ar-human", "x-ai-gateway-client-id", "agent-session-id")
MIN_DRAIN_MAX = 660
ALTERNATIVE = re.compile(
    r'^"agent-router\.(?P<role>[a-z]+)\.(?P<cls>public|internal)" in jwt\.aud'
    r' && mcp\.tool\.target == "(?P<target>[a-z0-9-]+)"'
    r' && mcp\.tool\.name in \[(?P<names>"[a-z0-9_]+"(, "[a-z0-9_]+")*)\]$')
ROUTE_KINDS = ("HTTPRoute", "GRPCRoute")


def meta(obj):
    return obj.get("metadata") or {}


def ref(obj):
    return f"{obj.get('kind')} {meta(obj).get('namespace', '')}/{meta(obj).get('name', '')}"


def spec_of(obj):
    return obj.get("spec") or {}


def load_objects(bundle_dir):
    objs = []
    for path in sorted(pathlib.Path(bundle_dir).glob("*.yaml")):
        for doc in yaml.load_all(path.read_text(), Loader=YAML_LOADER):
            if isinstance(doc, dict) and doc.get("kind"):
                objs.append(doc)
    return objs


def kind(objs, k):
    return [o for o in objs if o.get("kind") == k]


def policies(objs):
    return kind(objs, "AgentgatewayPolicy")


def gateway_targets(policy):
    """(sectionName or None) for each targetRef naming agent-router from its namespace."""
    if meta(policy).get("namespace") != GW_NS:
        return []
    return [t.get("sectionName") for t in spec_of(policy).get("targetRefs") or []
            if t.get("kind") == "Gateway" and t.get("name") == GW_NAME]


def router_parents(route):
    out = []
    for p in spec_of(route).get("parentRefs") or []:
        if p.get("kind", "Gateway") == "Gateway" and p.get("name") == GW_NAME \
                and p.get("namespace", meta(route).get("namespace")) == GW_NS:
            out.append(p)
    return out


def router_routes(objs):
    return [r for r in objs if r.get("kind") in ROUTE_KINDS and router_parents(r)]


def route_listeners(route):
    return {p.get("sectionName") for p in router_parents(route)}


def check_gateway(objs):
    gws = [g for g in kind(objs, "Gateway") if spec_of(g).get("gatewayClassName") == CLASS]
    if not gws:
        return [f"AG1: no Gateway of class {CLASS} (zero is a layout regression, not compliance)"]
    out = [f"AG1: {ref(g)} is a second Gateway of class {CLASS}; only {GW_NS}/{GW_NAME} may exist"
           for g in gws if (meta(g).get("namespace"), meta(g).get("name")) != (GW_NS, GW_NAME)]
    for g in gws:
        if (meta(g).get("namespace"), meta(g).get("name")) != (GW_NS, GW_NAME):
            continue
        got = {lst.get("name"): lst.get("port") for lst in spec_of(g).get("listeners") or []}
        if got != LISTENERS:
            out.append(f"AG1: {ref(g)} listeners are {got}, expected {LISTENERS}")
        for lst in spec_of(g).get("listeners") or []:
            ns = (lst.get("allowedRoutes") or {}).get("namespaces") or {}
            labels = (ns.get("selector") or {}).get("matchLabels") or {}
            if ns.get("from") != "Selector" or labels != {"kubernetes.io/metadata.name": ROUTES_NS}:
                out.append(f"AG1: {ref(g)} listener {lst.get('name')} must admit routes from {ROUTES_NS} only")
    return out


def check_listener_identity(objs):
    out = []
    by_listener = {name: [] for name in LISTENERS}
    for p in policies(objs):
        jwt = (spec_of(p).get("traffic") or {}).get("jwtAuthentication")
        sections = gateway_targets(p)
        if jwt is None:
            continue
        listener_sections = [s for s in sections if s in LISTENERS]
        if not listener_sections:
            out.append(f"AG5: {ref(p)} carries jwtAuthentication but targets no agent-router listener")
        for s in listener_sections:
            by_listener[s].append(p)
    for listener, found in by_listener.items():
        if len(found) != 1:
            out.append(f"AG2: listener {listener} has {len(found)} jwtAuthentication policies, expected exactly 1")
            continue
        p = found[0]
        traffic = spec_of(p).get("traffic") or {}
        jwt = traffic.get("jwtAuthentication") or {}
        if jwt.get("mode") != "Strict":
            out.append(f"AG2: {ref(p)} jwtAuthentication.mode must be Strict")
        providers = jwt.get("providers") or []
        auds = {a for prov in providers for a in prov.get("audiences") or []}
        if len(providers) != 1 or auds != AUDIENCES[listener]:
            out.append(f"AG2: {ref(p)} audiences are {sorted(auds)}, expected {sorted(AUDIENCES[listener])}")
        authz = traffic.get("authorization") or {}
        exprs = (authz.get("policy") or {}).get("matchExpressions") or []
        if authz.get("action") != "Require" or exprs != [SUB_PREFIX]:
            out.append(f"AG2: {ref(p)} must Require exactly {SUB_PREFIX}")
        sets = ((traffic.get("transformation") or {}).get("request") or {}).get("set") or []
        if {"name": "x-ar-agent", "value": "jwt.sub"} not in sets:
            out.append(f"AG2: {ref(p)} must set x-ar-agent from jwt.sub")
        preserve = bool(jwt.get("preserveToken"))
        if preserve != (listener == "sts"):
            out.append(f"AG4: {ref(p)} preserveToken is {preserve}; only the sts listener forwards the bearer")
    return out


def check_strip(objs):
    for p in policies(objs):
        if None not in gateway_targets(p):
            continue
        traffic = spec_of(p).get("traffic") or {}
        removed = {h.lower() for h in ((traffic.get("transformation") or {}).get("request") or {}).get("remove") or []}
        if traffic.get("phase") == "PreRouting" and set(IDENTITY_HEADERS) <= removed:
            return []
    return [f"AG3: no Gateway-scoped PreRouting policy on {GW_NS}/{GW_NAME} removes {', '.join(IDENTITY_HEADERS)}"]


def check_token_isolation(objs):
    out = []
    for p in policies(objs):
        traffic = spec_of(p).get("traffic") or {}
        jwt = traffic.get("jwtAuthentication") or {}
        if jwt.get("preserveToken") and "sts" not in gateway_targets(p):
            out.append(f"AG4: {ref(p)} sets preserveToken outside the sts listener")
        for section in (traffic, spec_of(p).get("backend") or {}):
            req = (section.get("transformation") or {}).get("request") or {}
            for h in (req.get("set") or []) + (req.get("add") or []):
                if str(h.get("name", "")).lower() == "authorization":
                    out.append(f"AG4: {ref(p)} writes Authorization in a transformation")
    for b in kind(objs, "AgentgatewayBackend"):
        for t in (spec_of(b).get("mcp") or {}).get("targets") or []:
            auth = ((t.get("static") or {}).get("policies") or {}).get("auth")
            if not auth:
                continue
            creds = auth.get("credentials") or []
            headers = [((c.get("location") or {}).get("header") or {}).get("name", "") for c in creds]
            if set(auth) - {"credentials"} or not creds or any(not h or h.lower() == "authorization" for h in headers):
                out.append(f"AG4: {ref(b)} target {t.get('name')} must inject its key in a named header other than Authorization")
    return out


def check_routes(objs):
    out = []
    for r in router_routes(objs):
        if meta(r).get("namespace") != ROUTES_NS:
            out.append(f"AG5: {ref(r)} attaches to agent-router from outside {ROUTES_NS}")
        if any(not p.get("sectionName") for p in router_parents(r)):
            out.append(f"AG5: {ref(r)} attaches to agent-router without sectionName (it would bind every listener)")
        names_zai = any(b.get("kind") == "AgentgatewayBackend" and b.get("name") == "zai"
                        for rule in spec_of(r).get("rules") or [] for b in rule.get("backendRefs") or [])
        if names_zai and route_listeners(r) != {"public"}:
            out.append(f"AG5: {ref(r)} reaches zai from {sorted(route_listeners(r))}; Z.ai is public-only")
    return out


def targeted_routes(objs, policy):
    names = {t.get("name") for t in spec_of(policy).get("targetRefs") or [] if t.get("kind") in ROUTE_KINDS}
    ns = meta(policy).get("namespace")
    return [r for r in router_routes(objs) if meta(r).get("name") in names and meta(r).get("namespace") == ns]


def check_mcp_authz(objs):
    out = []
    for p in policies(objs):
        authz = ((spec_of(p).get("backend") or {}).get("mcp") or {}).get("authorization")
        if authz is None:
            continue
        classes = {s for r in targeted_routes(objs, p) for s in route_listeners(r)}
        if authz.get("action") != "Allow":
            out.append(f"AG6: {ref(p)} MCP authorization must be an Allow list (deny by default)")
        for e in (authz.get("policy") or {}).get("matchExpressions") or []:
            m = ALTERNATIVE.match(e.strip())
            if "||" in e or not m:
                out.append(f"AG6: {ref(p)} expression is not one complete alternative: {e}")
            elif m.group("cls") not in classes:
                out.append(f"AG6: {ref(p)} grants a {m.group('cls')} audience on {sorted(classes)} routes: {e}")
    return out


def llm_backends(objs):
    return {(meta(b).get("namespace"), meta(b).get("name")) for b in kind(objs, "AgentgatewayBackend")
            if spec_of(b).get("ai")}


def check_models_list(objs):
    out = []
    llm = llm_backends(objs)
    llm_listeners = set()
    for r in router_routes(objs):
        for rule in spec_of(r).get("rules") or []:
            for b in rule.get("backendRefs") or []:
                if (b.get("namespace", meta(r).get("namespace")), b.get("name")) in llm:
                    llm_listeners |= route_listeners(r)
    answered = set()
    for p in policies(objs):
        direct = (spec_of(p).get("traffic") or {}).get("directResponse") or {}
        if direct.get("status") != 404:
            continue
        for r in targeted_routes(objs, p):
            exact = any(m.get("path") == {"type": "Exact", "value": "/v1/models"}
                        for rule in spec_of(r).get("rules") or [] for m in rule.get("matches") or [])
            if exact:
                answered |= route_listeners(r)
    for listener in sorted(llm_listeners - answered):
        out.append(f"AG7: listener {listener} serves an LLM route but no Exact /v1/models 404 direct response")
    return out


def ratelimit_configs(objs):
    configs = {}
    for cm in kind(objs, "ConfigMap"):
        raw = (cm.get("data") or {}).get("config.yaml")
        if not raw:
            continue
        try:
            cfg = yaml.safe_load(raw)
        except yaml.YAMLError:
            continue
        if isinstance(cfg, dict) and cfg.get("domain") and isinstance(cfg.get("descriptors"), list):
            configs[cfg["domain"]] = (cm, cfg)
    return configs


def check_budgets(objs):
    out = []
    configs = ratelimit_configs(objs)
    for p in policies(objs):
        glob = ((spec_of(p).get("traffic") or {}).get("rateLimit") or {}).get("global")
        if glob is None:
            continue
        if glob.get("failureMode") != "FailOpen":
            out.append(f"AG8: {ref(p)} must fail open (a store outage must not stop agents)")
        domain = glob.get("domain")
        if domain not in configs:
            out.append(f"AG8: {ref(p)} domain {domain!r} has no rate-limit ConfigMap in the bundle")
            continue
        cm, cfg = configs[domain]
        rules = {d.get("key"): d for d in cfg["descriptors"]}
        for d in glob.get("descriptors") or []:
            if d.get("unit") != "Tokens":
                out.append(f"AG8: {ref(p)} descriptor must charge unit Tokens")
            for entry in d.get("entries") or []:
                text = f"{entry.get('name', '')} {entry.get('expression', '')}"
                if re.search(r"route|backend|request\.path", text):
                    out.append(f"AG8: {ref(p)} descriptor entry {entry.get('name')} keys on a route; buckets must be shared")
                rule = rules.get(entry.get("name"))
                if rule is None:
                    out.append(f"AG8: {ref(p)} entry {entry.get('name')} has no descriptor in {ref(cm)}")
                elif rule.get("shadow_mode") is not True:
                    out.append(f"AG8: {ref(cm)} descriptor {entry.get('name')} must set shadow_mode: true until enforcement")
    return out


def check_parameters(objs):
    gw = next((g for g in kind(objs, "Gateway") if spec_of(g).get("gatewayClassName") == CLASS
               and (meta(g).get("namespace"), meta(g).get("name")) == (GW_NS, GW_NAME)), None)
    if gw is None:
        return []
    pref = (spec_of(gw).get("infrastructure") or {}).get("parametersRef") or {}
    params = next((p for p in kind(objs, "AgentgatewayParameters")
                   if meta(p).get("namespace") == GW_NS and meta(p).get("name") == pref.get("name")), None)
    if params is None or pref.get("kind") != "AgentgatewayParameters":
        return [f"AG9: {ref(gw)} has no AgentgatewayParameters in {GW_NS}"]
    s, out = spec_of(params), []
    dep = (s.get("deployment") or {}).get("spec") or {}
    pod = (dep.get("template") or {}).get("spec") or {}
    container = next((c for c in pod.get("containers") or [] if c.get("name") == "agentgateway"), {})
    checks = [
        ((dep.get("replicas") or 0) >= 2, "2 replicas"),
        (((pod.get("securityContext") or {}).get("seccompProfile") or {}).get("type") == "RuntimeDefault", "pod seccompProfile RuntimeDefault"),
        (((container.get("securityContext") or {}).get("seccompProfile") or {}).get("type") == "RuntimeDefault", "container seccompProfile RuntimeDefault"),
        (bool(container.get("livenessProbe")), "a liveness probe"),
        (bool(((s.get("resources") or {}).get("limits") or {}).get("memory")), "a memory limit"),
        ((((s.get("service") or {}).get("spec") or {}).get("type")) == "ClusterIP", "service type ClusterIP"),
        (bool((s.get("podDisruptionBudget") or {}).get("spec")), "a PodDisruptionBudget"),
        (bool((s.get("image") or {}).get("digest")), "a digest-pinned image"),
        (((s.get("shutdown") or {}).get("max") or 0) >= MIN_DRAIN_MAX, f"shutdown.max >= {MIN_DRAIN_MAX}"),
    ]
    out += [f"AG9: {ref(params)} lacks {what}" for ok, what in checks if not ok]
    return out


CHECKS = (check_gateway, check_listener_identity, check_strip, check_token_isolation,
          check_routes, check_mcp_authz, check_models_list, check_budgets, check_parameters)


def run(objs):
    return [v for check in CHECKS for v in check(objs)]


def main(argv):
    bundle = pathlib.Path(argv[1] if len(argv) > 1 else ".bundle")
    if not bundle.is_dir():
        print(f"error: bundle directory {bundle} not found", file=sys.stderr)
        return 2
    violations = run(load_objects(bundle))
    for v in violations:
        print(f"  VIOLATION {v}")
    print(f"assert-agent-gateway: {len(CHECKS)} checks, {len(violations)} violations")
    return 1 if violations else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
```

- [ ] **Step 4: Run the tests**

Run: `python3 scripts/ci/tests/flux-schema/test-assert-agent-gateway.py && ./scripts/ci/tests/run.sh 2>&1 | grep assert-agent-gateway`
Expected: 31 `ok` lines and `all passed`; the runner lists `PASS  flux-schema/test-assert-agent-gateway`.
(Verified 2026-10-01 against this exact code in a scratch tree.)

- [ ] **Step 5: Commit**

```bash
git add scripts/ci/flux-schema/assert-agent-gateway.py scripts/ci/tests/flux-schema/test-assert-agent-gateway.py
git commit -m "ci(flux-schema): gate the agent router's agentgateway invariants (AG1-AG9)"
```

### Task A.4: Gates and AGW-1 as a draft

- [ ] **Step 1: Every gate**

Run: `export XRD_CRDS_FILE="$(./scripts/ci/fetch-xrd-crds.sh)" && systemd-run --user --scope -q -p MemoryMax=6G -p MemorySwapMax=0 ./scripts/ci/validate-manifests.sh && ./scripts/ci/validate-links.sh && ./scripts/ci/verify-doc-paths.sh && task check`
Expected: all exit 0; `Invalid: 0, Skipped: 0`.

- [ ] **Step 2: Open AGW-1 with `create-pr`**, draft, base `feat/rooms-driver`. Title:
`ci(agents): agentgateway schemas and the agent router gate (ADR-0053 phase A)`. Body: the design
link, ADR-0053, the gate table, a mermaid diagram of the stack (PR map), and the line
**"Held until the owner's UX sign-off (P33)."**

---

## Phase B — AGW-2: the platform install, on both clouds

Gate: the gate wired and green; on gcp-0 the Gateway is `Programmed`, PSS-clean, and refuses
unauthenticated requests on all three listeners.

### Task B.1: Worktree and the `agent-gateway` namespace

**Files:**
- Create: `namespaces/base/agent-gateway.yaml`
- Modify: `namespaces/base/kustomization.yaml`

- [ ] **Step 1: Worktree.** `EnterWorktree` with branch `feat/agw-platform`, then
`git reset --hard origin/feat/agw-gate`; merge `origin/main` in.

- [ ] **Step 2: Write the namespace.** Create `namespaces/base/agent-gateway.yaml`:

```yaml
# The agent router's data plane (ADR-0053): agentgateway proxies run in their
# Gateway's namespace, so the controller writes here and nowhere else
# (rbac.gatewayNamespaces). Routes, backends and keys stay in agent-system.
apiVersion: v1
kind: Namespace
metadata:
  name: agent-gateway
  labels:
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/audit: restricted
    pod-security.kubernetes.io/warn: restricted
```

In `namespaces/base/kustomization.yaml`, add `  - agent-gateway.yaml` after `  - agent-system.yaml`.

- [ ] **Step 3: Verify and commit**

Run: `kustomize build namespaces/base | grep -c 'name: agent-gateway$'`
Expected: `1`.

```bash
git add namespaces/base/agent-gateway.yaml namespaces/base/kustomization.yaml
git commit -m "feat(namespaces): agent-gateway for the agent router's data plane"
```

### Task B.2: The controller child, both clouds

**Files:**
- Create: `infrastructure/base/agentgateway/{kustomization.yaml,namespace.yaml,helmrelease-crds.yaml,helmrelease.yaml,network-policy.yaml}`,
  `infrastructure/{aws-0,gcp-0}/agentgateway/kustomization.yaml`,
  `clusters/{aws-0,gcp-0}-agent-platform/infrastructure-agentgateway.yaml`
- Modify: `clusters/{aws-0,gcp-0}-agent-platform/kustomization.yaml`, `scripts/ci/flux-schema/assert-cloud-shape.py`,
  `scripts/ci/tests/flux-schema/test-assert-cloud-shape.py`

**Interfaces:**
- Consumes: `infrastructure/base/agentgateway/ocirepositories.yaml` (A.2).
- Produces: Flux child `agentgateway` (HelmReleases `agentgateway-crds`, `agentgateway` Ready);
  controller pods labelled `app.kubernetes.io/name: agentgateway`, `app.kubernetes.io/instance: agentgateway`,
  serving xDS on `:9978`.

- [ ] **Step 1: The failing check**

Run: `kustomize build infrastructure/gcp-0/agentgateway 2>&1 | head -1`
Expected: an error: the directory does not exist.

- [ ] **Step 2: Write the base.** Copy the PoC's files from integration and adapt:

```bash
git show origin/integration/agent-factory:infrastructure/gcp-0/agentgateway/helmrelease-crds.yaml > infrastructure/base/agentgateway/helmrelease-crds.yaml
git show origin/integration/agent-factory:infrastructure/gcp-0/agentgateway/helmrelease.yaml > infrastructure/base/agentgateway/helmrelease.yaml
git show origin/integration/agent-factory:infrastructure/gcp-0/agentgateway/network-policy-controller.yaml > infrastructure/base/agentgateway/network-policy.yaml
```

Then edit:
- `helmrelease.yaml`: `rbac.gatewayNamespaces` becomes `[agent-gateway]`; replace the comment above
  it with `# Writes (Deployments, Services, Secrets) only in agent-gateway, which holds proxies and
  nothing else (ADR-0053 D1). Reads stay cluster-wide, Secrets included, as for Envoy Gateway.`
  Add under `values`:

  ```yaml
      # The chart's proxy PodMonitor would scrape without our relabel (G2);
      # infrastructure/base/agent-gateway/vmpodscrape.yaml does it instead.
      metrics:
        proxy:
          podMonitor:
            enabled: false
  ```

  Check the key path first: `helm show values oci://cr.agentgateway.dev/charts/agentgateway --version v1.5.0 | grep -n -B4 'gatewayClassNames'`
  and use the path printed there.
- `network-policy.yaml`: the ingress `fromEndpoints` becomes
  `{io.kubernetes.pod.namespace: agent-gateway, gateway.networking.k8s.io/gateway-name: agent-router}`;
  keep `host → 9093`, DNS, `kube-apiserver:443` and `${oidc_jwks_host}:443`. Prepend the namespace's
  default deny, which the PoC kept in its other directory and the teardown prunes:

  ```yaml
  # Default deny in agentgateway-system; the controller's allows follow.
  apiVersion: cilium.io/v2
  kind: CiliumNetworkPolicy
  metadata:
    name: default-deny
    namespace: agentgateway-system
  spec:
    endpointSelector: {}
    ingress:
      - {}
    egress:
      - {}
  ---
  ```

Create `infrastructure/base/agentgateway/namespace.yaml`:

```yaml
# Declared by this child, not namespaces/base (plan R3): the PoC declared it
# here, and moving it would let the old inventory's prune delete it.
apiVersion: v1
kind: Namespace
metadata:
  name: agentgateway-system
  labels:
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/audit: restricted
    pod-security.kubernetes.io/warn: restricted
```

Create `infrastructure/base/agentgateway/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

# The agent router's controller (ADR-0053). Its own GatewayClass `agentgateway`
# is created by the controller at startup, not by Git (PoC N9).
resources:
  - namespace.yaml
  - ocirepositories.yaml
  - helmrelease-crds.yaml
  - helmrelease.yaml
  - network-policy.yaml
```

Create `infrastructure/aws-0/agentgateway/kustomization.yaml` and `infrastructure/gcp-0/agentgateway/kustomization.yaml`, each:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

# A render root per cloud (GCP parity GP-14) over the shared base.
resources:
  - ../../base/agentgateway
```

- [ ] **Step 3: The Flux children.** Create `clusters/gcp-0-agent-platform/infrastructure-agentgateway.yaml`:

```yaml
---
# The agent router's controller (ADR-0053). Takes over the PoC child's name,
# so Flux adopts its HelmReleases instead of re-installing (plan R5).
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: agentgateway
  namespace: flux-system
spec:
  prune: true
  interval: 10m0s
  retryInterval: 30s
  timeout: 5m0s
  path: ./infrastructure/gcp-0/agentgateway
  sourceRef:
    kind: ExternalArtifact
    name: infra-artifact
  postBuild:
    substituteFrom:
      - kind: ConfigMap
        name: gke-gcp-0-vars
  healthChecks:
    - apiVersion: helm.toolkit.fluxcd.io/v2
      kind: HelmRelease
      name: agentgateway-crds
      namespace: agentgateway-system
    - apiVersion: helm.toolkit.fluxcd.io/v2
      kind: HelmRelease
      name: agentgateway
      namespace: agentgateway-system
```

Create `clusters/aws-0-agent-platform/infrastructure-agentgateway.yaml` identical except
`path: ./infrastructure/aws-0/agentgateway` and `name: eks-aws-0-vars`. Add
`  - infrastructure-agentgateway.yaml` after `  - infrastructure-agent-router.yaml` in both
`clusters/*-agent-platform/kustomization.yaml`.

- [ ] **Step 4: Teach the cloud-shape gate the new overlays.** In `scripts/ci/flux-schema/assert-cloud-shape.py`,
the `SCOPED` alternation gains `agentgateway` (`agent-[a-z-]+` already covers `agent-gateway`), and
`RUN_TOKEN` becomes `re.compile(r"-gcp-0-agent-(router|mcp|gateway)\.yaml$")`. Add
`"overlay-infrastructure-gcp-0-agentgateway.yaml"` and `"overlay-infrastructure-gcp-0-agent-gateway.yaml"`
to the expected-overlays list beside `overlay-infrastructure-gcp-0-agent-router.yaml`. In
`test-assert-cloud-shape.py`, add a case asserting an `amazonaws.com` host in
`overlay-infrastructure-gcp-0-agentgateway.yaml` is a violation, written like the file's existing
`agent-router` case.

- [ ] **Step 5: Render both clouds, commit**

Run: `kustomize build infrastructure/gcp-0/agentgateway | grep -c '^kind: HelmRelease' && kustomize build infrastructure/aws-0/agentgateway | grep -c '^kind: HelmRelease' && python3 scripts/ci/tests/flux-schema/test-assert-cloud-shape.py`
Expected: `2`, `2`, all ok.

```bash
git add infrastructure/base/agentgateway infrastructure/aws-0/agentgateway infrastructure/gcp-0/agentgateway \
  clusters/aws-0-agent-platform clusters/gcp-0-agent-platform scripts/ci/flux-schema/assert-cloud-shape.py \
  scripts/ci/tests/flux-schema/test-assert-cloud-shape.py
git commit -m "feat(agentgateway): the agent router's controller on both clouds"
```

### Task B.3: The Gateway, its parameters and its data-plane CNP

**Files:**
- Create: `infrastructure/base/agent-gateway/{kustomization.yaml,gateway.yaml,parameters.yaml,network-policy.yaml}`,
  `infrastructure/{aws-0,gcp-0}/agent-gateway/kustomization.yaml`,
  `clusters/{aws-0,gcp-0}-agent-platform/infrastructure-agent-gateway.yaml`
- Modify: `clusters/{aws-0,gcp-0}-agent-platform/kustomization.yaml`

**Interfaces:**
- Produces: Gateway `agent-gateway/agent-router` (AG1), `AgentgatewayParameters agent-router` (AG9),
  Flux child `agent-gateway` with `dependsOn: [agentgateway, agent-secrets]`.

- [ ] **Step 1: The failing check.** The gate's unit tests already describe the shape; render the
real tree through the gate:

Run: `mkdir -p /tmp/claude-agwb && kustomize build infrastructure/gcp-0/agent-gateway > /tmp/claude-agwb/b.yaml; python3 scripts/ci/flux-schema/assert-agent-gateway.py /tmp/claude-agwb`
Expected: `kustomize` fails (no directory) and the gate prints `AG1: no Gateway of class agentgateway`.

- [ ] **Step 2: Write `gateway.yaml`:**

```yaml
# The agents' Gateway on agentgateway (ADR-0053). One listener per data class,
# as on Envoy (ADR-0042): an internal token never reaches Z.ai because Z.ai
# routes attach to `public` only. Same name as the Envoy Gateway it replaces,
# in its own namespace so both run side by side during the cutover.
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: agent-router
  namespace: agent-gateway
spec:
  gatewayClassName: agentgateway
  listeners:
    - name: public
      protocol: HTTP
      port: 8080
      allowedRoutes: &fromAgentSystem
        namespaces:
          from: Selector
          selector:
            matchLabels:
              kubernetes.io/metadata.name: agent-system
    - name: internal
      protocol: HTTP
      port: 8081
      allowedRoutes: *fromAgentSystem
    - name: sts
      protocol: HTTP
      port: 8082
      allowedRoutes: *fromAgentSystem
  infrastructure:
    parametersRef:
      group: agentgateway.dev
      kind: AgentgatewayParameters
      name: agent-router
```

If `render-bundle.py` or Flux rejects the YAML anchors, write the three `allowedRoutes` blocks out
in full.

- [ ] **Step 3: Write `parameters.yaml`** (the PoC's G3 overlay, with the zone spread Envoy had):

```yaml
# agentgateway's generated proxy has no seccomp profile, no liveness probe, no
# limits and a LoadBalancer Service (gap G3); these are strategic-merge
# overlays on what the controller renders. The default drain (10s/60s) cut an
# in-flight stream ~18 s after SIGTERM; 120/660 held a 200 s stream through
# both replicas' deletion (PoC N1). 660 = the 600 s request timeout + 60 s.
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayParameters
metadata:
  name: agent-router
  namespace: agent-gateway
spec:
  image:
    registry: cr.agentgateway.dev
    repository: agentgateway
    tag: v1.5.0
    digest: sha256:bf2f339ef326d32def2aaeb44b1b4549801293c19b89e764a4228667d97d9896
  logging:
    format: json
  shutdown:
    min: 120
    max: 660
  resources:
    requests:
      cpu: 100m
      memory: 128Mi
    limits:
      cpu: "1"
      memory: 512Mi
  deployment:
    spec:
      # Two replicas and a PDB: a drain never takes every in-flight completion,
      # and the harness does not retry.
      replicas: 2
      template:
        spec:
          securityContext:
            runAsNonRoot: true
            seccompProfile:
              type: RuntimeDefault
          topologySpreadConstraints:
            - maxSkew: 1
              topologyKey: topology.kubernetes.io/zone
              whenUnsatisfiable: ScheduleAnyway
              labelSelector:
                matchLabels:
                  gateway.networking.k8s.io/gateway-name: agent-router
            - maxSkew: 1
              topologyKey: kubernetes.io/hostname
              whenUnsatisfiable: ScheduleAnyway
              labelSelector:
                matchLabels:
                  gateway.networking.k8s.io/gateway-name: agent-router
          containers:
            - name: agentgateway
              securityContext:
                allowPrivilegeEscalation: false
                readOnlyRootFilesystem: true
                runAsNonRoot: true
                capabilities:
                  drop: ["ALL"]
                seccompProfile:
                  type: RuntimeDefault
              livenessProbe:
                httpGet:
                  path: /healthz/ready
                  port: 15021
                periodSeconds: 10
                failureThreshold: 6
  service:
    spec:
      # ClusterIP: a LoadBalancer would give the agents' boundary a cloud
      # address, and agents reach it in-cluster (GCP L7 hairpin note).
      type: ClusterIP
  podDisruptionBudget:
    spec:
      minAvailable: 1
```

- [ ] **Step 4: Write `network-policy.yaml`:**

```yaml
# Default deny in agent-gateway (`- {}` selects no peer: it switches
# enforcement on and allows nothing), then the data plane's own peers. The
# controller fetches the JWKS and serves the keyset over xDS, so the proxies
# never call the issuer. Sandboxes only: Kyverno reserves the audiences and the
# listeners require the `agents` sub prefix; this keeps every other pod out of
# the TCP path too.
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: default-deny
  namespace: agent-gateway
spec:
  endpointSelector: {}
  ingress:
    - {}
  egress:
    - {}
---
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: agent-router-data-plane
  namespace: agent-gateway
spec:
  endpointSelector:
    matchLabels:
      gateway.networking.k8s.io/gateway-name: agent-router
  ingress:
    - fromEndpoints:
        - matchLabels:
            io.kubernetes.pod.namespace: agents
          matchExpressions:
            - key: agents.ogenki.io/run-id
              operator: Exists
      toPorts:
        - ports:
            - port: "8080"
              protocol: TCP
            - port: "8081"
              protocol: TCP
            - port: "8082"
              protocol: TCP
    - fromEntities:
        - host
      toPorts:
        - ports:
            - port: "15021"
              protocol: TCP
    - fromEndpoints:
        - matchLabels:
            io.kubernetes.pod.namespace: observability
            app.kubernetes.io/name: vmagent
      toPorts:
        - ports:
            - port: "15020"
              protocol: TCP
  egress:
    - toEndpoints:
        - matchLabels:
            io.kubernetes.pod.namespace: kube-system
            k8s-app: kube-dns
      toPorts:
        - ports:
            - port: "53"
              protocol: UDP
            - port: "53"
              protocol: TCP
          rules:
            dns:
              - matchPattern: "*"
    - toEndpoints:
        - matchLabels:
            io.kubernetes.pod.namespace: agentgateway-system
            app.kubernetes.io/name: agentgateway
      toPorts:
        - ports:
            - port: "9978"
              protocol: TCP
```

Phases C, D and E add egress rules to `agent-router-data-plane`.

- [ ] **Step 5: Kustomization, render roots, Flux children.** `infrastructure/base/agent-gateway/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

# The agent router on agentgateway (ADR-0053): Gateway and data plane here;
# its routes and backends live in agent-system with agent-router and agent-mcp.
resources:
  - gateway.yaml
  - parameters.yaml
  - policies-identity.yaml
  - network-policy.yaml
```

The two render roots `infrastructure/{aws-0,gcp-0}/agent-gateway/kustomization.yaml` follow Task
B.2's shape with `../../base/agent-gateway`. Create `clusters/gcp-0-agent-platform/infrastructure-agent-gateway.yaml`:

```yaml
---
# The agent router's Gateway on agentgateway (ADR-0053).
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: agent-gateway
  namespace: flux-system
spec:
  prune: true
  interval: 5m0s
  retryInterval: 30s
  timeout: 5m0s
  path: ./infrastructure/gcp-0/agent-gateway
  sourceRef:
    kind: ExternalArtifact
    name: infra-artifact
  postBuild:
    substituteFrom:
      - kind: ConfigMap
        name: gke-gcp-0-vars
  dependsOn:
    - name: agentgateway
    - name: agent-secrets
  healthChecks:
    - apiVersion: gateway.networking.k8s.io/v1
      kind: Gateway
      name: agent-router
      namespace: agent-gateway
  healthCheckExprs:
    - apiVersion: gateway.networking.k8s.io/v1
      kind: Gateway
      current: status.conditions.filter(c, c.type == 'Programmed').all(c, c.status == 'True')
      failed: status.conditions.filter(c, c.type == 'Programmed').all(c, c.status == 'False')
```

and its aws-0 twin (`./infrastructure/aws-0/agent-gateway`, `eks-aws-0-vars`). Add
`  - infrastructure-agent-gateway.yaml` after `  - infrastructure-agentgateway.yaml` in both
cluster kustomizations. `policies-identity.yaml` comes in Task B.4; the build fails until then.

- [ ] **Step 6: Commit** (with B.4's file, after B.4 Step 4 passes).

### Task B.4: Listener identity and the early strip

**Files:**
- Create: `infrastructure/base/agent-gateway/policies-identity.yaml`

**Interfaces:**
- Produces: AG2, AG3 and AG4 satisfied on the real tree.

- [ ] **Step 1: Write `policies-identity.yaml`:**

```yaml
# ADR-0042 on agentgateway (ADR-0053). Per listener: validate the run's
# projected ServiceAccount token offline, require the `agents` sub prefix
# (which Envoy Gateway could not express; PoC P1), and REPLACE x-ar-agent with
# the verified sub. The validated JWT is removed before any backend sees it
# (preserveToken defaults off); only `sts` forwards it, to octo-sts.
# Audiences are the Envoy agent-router's, so one token works on both gateways
# during the cutover. Kyverno still reserves them for namespace agents.
#
# Defence in depth for the identity headers: dropped before routing, so no
# route or backend sees a forged one even where `set` does not run.
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayPolicy
metadata:
  name: strip-identity-headers
  namespace: agent-gateway
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: Gateway
      name: agent-router
  traffic:
    phase: PreRouting
    transformation:
      request:
        remove:
          - x-ar-agent
          - x-ar-human
          - x-ai-gateway-client-id
          - agent-session-id
---
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayPolicy
metadata:
  name: listener-public
  namespace: agent-gateway
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: Gateway
      name: agent-router
      sectionName: public
  traffic:
    jwtAuthentication:
      mode: Strict
      providers:
        - issuer: ${oidc_issuer_url}
          audiences:
            - agent-router.implementer.public
            - agent-router.reviewer.public
            - agent-router.tester.public
            - agent-router.triager.public
          jwks:
            remote:
              url: ${oidc_jwks_uri}
    authorization:
      action: Require
      policy:
        matchExpressions:
          - 'jwt.sub.startsWith("system:serviceaccount:agents:")'
    transformation:
      request:
        set:
          - name: x-ar-agent
            value: jwt.sub
    # A long GLM completion must not 504 (agent-router's agent-models rule).
    timeouts:
      request: 600s
---
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayPolicy
metadata:
  name: listener-internal
  namespace: agent-gateway
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: Gateway
      name: agent-router
      sectionName: internal
  traffic:
    jwtAuthentication:
      mode: Strict
      providers:
        - issuer: ${oidc_issuer_url}
          audiences:
            - agent-router.implementer.internal
            - agent-router.reviewer.internal
            - agent-router.tester.internal
            - agent-router.triager.internal
          jwks:
            remote:
              url: ${oidc_jwks_uri}
    authorization:
      action: Require
      policy:
        matchExpressions:
          - 'jwt.sub.startsWith("system:serviceaccount:agents:")'
    transformation:
      request:
        set:
          - name: x-ar-agent
            value: jwt.sub
    timeouts:
      request: 600s
---
# octo-sts's trust policies match the EKS issuer by pattern (it changes every
# rebuild); this pins THIS cluster's issuer and the four audiences first. These
# audiences ARE the per-repository opt-in (ADR-0043): another repository fails
# closed here. The only listener that forwards the bearer.
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayPolicy
metadata:
  name: listener-sts
  namespace: agent-gateway
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: Gateway
      name: agent-router
      sectionName: sts
  traffic:
    jwtAuthentication:
      mode: Strict
      preserveToken: true
      providers:
        - issuer: ${oidc_issuer_url}
          audiences:
            - octo-sts/Smana/cloud-native-ref/implementer
            - octo-sts/Smana/cloud-native-ref/reviewer
            - octo-sts/Smana/cloud-native-ref/tester
            - octo-sts/Smana/cloud-native-ref/triager
          jwks:
            remote:
              url: ${oidc_jwks_uri}
    authorization:
      action: Require
      policy:
        matchExpressions:
          - 'jwt.sub.startsWith("system:serviceaccount:agents:")'
    transformation:
      request:
        set:
          - name: x-ar-agent
            value: jwt.sub
```

- [ ] **Step 2: Run the gate on the real render**

Run: `kustomize build infrastructure/gcp-0/agent-gateway > /tmp/claude-agwb/b.yaml && python3 scripts/ci/flux-schema/assert-agent-gateway.py /tmp/claude-agwb; rm -rf /tmp/claude-agwb`
Expected: `assert-agent-gateway: 9 checks, 0 violations`.

- [ ] **Step 3: Commit B.3 and B.4**

```bash
git add infrastructure/base/agent-gateway infrastructure/aws-0/agent-gateway infrastructure/gcp-0/agent-gateway \
  clusters/aws-0-agent-platform clusters/gcp-0-agent-platform
git commit -m "feat(agent-gateway): the agent router Gateway on agentgateway, with ADR-0042's listeners"
```

### Task B.5: Wire the gate

**Files:**
- Modify: `scripts/ci/validate-manifests.sh`, `scripts/AGENTS.md`

- [ ] **Step 1: Wire it.** In `scripts/ci/validate-manifests.sh`, after the Gate 3 line, add:

```bash
echo "==> [5/6] Gate 3b — agent router invariants on agentgateway (ADR-0053: listeners, identity, MCP, budgets, data plane)"
python3 scripts/ci/flux-schema/assert-agent-gateway.py "${BUNDLE_DIR}"
```

In `scripts/AGENTS.md`, in the table of what each validator checks, add a row for
`assert-agent-gateway.py` (AG1–AG9, one line each, from the module docstring) and the line
"what it cannot catch: CEL that parses but means something else at runtime; Task C.5's live checks
do". Keep the table's existing format.

- [ ] **Step 2: Prove it is not vacuous**

Run: `export XRD_CRDS_FILE="$(./scripts/ci/fetch-xrd-crds.sh)" && systemd-run --user --scope -q -p MemoryMax=6G -p MemorySwapMax=0 ./scripts/ci/validate-manifests.sh 2>&1 | grep -E 'Invalid|assert-agent-gateway|All gates'`
Expected: `Invalid: 0, Skipped: 0`, `assert-agent-gateway: 9 checks, 0 violations`, `All gates passed`.
Then delete `sectionName: sts` from `listener-sts`, re-run, expect `AG2` and `AG4` violations and
exit 1, and restore the line.

- [ ] **Step 3: Commit**

```bash
git add scripts/ci/validate-manifests.sh scripts/AGENTS.md
git commit -m "ci(validate): run the agent router gate on every render"
```

### Task B.6: PoC teardown, live install on gcp-0, AGW-2 as a draft

- [ ] **Step 1: The PoC teardown commit.** In a separate `EnterWorktree` on `feat/agentgateway-poc`
(`git reset --hard origin/feat/agentgateway-poc`):

```bash
git rm -r infrastructure/gcp-0/agentgateway infrastructure/gcp-0/agentgateway-poc \
  clusters/gcp-0-agent-platform/infrastructure-agentgateway-poc.yaml
sed -i '/infrastructure-agentgateway-poc.yaml/d' clusters/gcp-0-agent-platform/kustomization.yaml
git add clusters/gcp-0-agent-platform/kustomization.yaml
git commit -m "chore(agentgateway): retire the PoC, superseded by the real install (ADR-0053)"
git push origin feat/agentgateway-poc
```

- [ ] **Step 2: Gates, push, draft.** Run Task A.4 Step 1's gates (expect the Gate 3b line). Open
AGW-2 as a draft on `feat/agw-gate`: title `feat(agents): agentgateway platform for the agent router
(ADR-0053 phase B)`; body with a mermaid diagram of the two namespaces and the controller, the P33
hold line, and an empty "Live evidence" section.

- [ ] **Step 3: [LIVE] Install on gcp-0.** Merge `feat/agentgateway-poc` (Step 1) **and** AGW-2 into
`integration/agent-factory` in one push, merge commits only. Then, one call each:

```bash
flux get kustomization agentgateway -n flux-system      # Ready, path ./infrastructure/gcp-0/agentgateway
flux get kustomization agent-gateway -n flux-system     # Ready
kubectl get gatewayclass agentgateway                   # ACCEPTED True
kubectl get gateway -n agent-gateway agent-router       # PROGRAMMED True
kubectl get ns agw-poc agw-poc-clients                  # NotFound (pruned)
kubectl get svc -n agent-gateway agent-router -o jsonpath='{.spec.type}'                       # ClusterIP
kubectl get deploy -n agent-gateway agent-router -o jsonpath='{.spec.template.spec.terminationGracePeriodSeconds}'  # >= 660
kubectl get secret -n agent-gateway agent-router-session-key -o name                           # exists (MCP sessions, not base64)
kubectl get sa -n agent-gateway -o name                                                         # record the proxies' SA name for Task I.3
kubectl get pods -n agent-gateway -l gateway.networking.k8s.io/gateway-name=agent-router        # 2 Running, on 2 nodes
```

If `terminationGracePeriodSeconds` is below 660, add
`terminationGracePeriodSeconds: 660` under `deployment.spec.template.spec` in `parameters.yaml`,
commit `fix(agent-gateway): give the proxies the full drain window`, and re-check.

The unauthenticated-request checks need the probe's egress (Task C.4) and run in Task C.5.
Paste the outputs into AGW-2's "Live evidence".

---

## Phase C — AGW-3: routes and policies at parity

Gate: AG5–AG7 green on the real tree; the scope test derives per-role tool sets from the Allow
lists; the probe proves P1, P2, P4, P8 and the `/v1/models` 404 against the new gateway.

### Task C.1: The LLM path and `/v1/models`

**Files:**
- Create: `infrastructure/base/agent-router/agentgateway-llm.yaml`
- Modify: `infrastructure/base/agent-router/kustomization.yaml`, `infrastructure/base/agent-gateway/network-policy.yaml`

**Interfaces:**
- Consumes: Secret `agents-zai-api-key` (key `apiKey`) from `externalsecret-zai.yaml`.
- Produces: `AgentgatewayBackend agent-system/zai`, `HTTPRoute agent-models` (public, `/v1` and `/anthropic`),
  `HTTPRoute agent-models-list` + its 404 policy.

The objects live in the `agent-router` child beside the Envoy objects they replace, so the Z.ai key
is never copied and phase H deletes the Envoy files from one directory.

- [ ] **Step 1: The failing check.** Render the agent-router and agent-gateway roots together and run the gate:

Run: `mkdir -p /tmp/claude-agwc && kustomize build infrastructure/gcp-0/agent-gateway > /tmp/claude-agwc/a.yaml && kustomize build infrastructure/gcp-0/agent-router > /tmp/claude-agwc/b.yaml && python3 scripts/ci/flux-schema/assert-agent-gateway.py /tmp/claude-agwc; grep -c 'kind: AgentgatewayBackend' /tmp/claude-agwc/b.yaml`
Expected: `0 violations` and `0` backends: nothing routes yet.

- [ ] **Step 2: Write `agentgateway-llm.yaml`:**

```yaml
# The agents' Z.ai path on agentgateway (ADR-0053), beside the Envoy objects in
# this directory until phase H. The key is read by reference (agents-zai-api-key,
# the agents' own key), never copied.
#
# The backend pins the provider model: whatever name a run asks for, it gets
# glm-5.3, so no request can pick another (paid) Z.ai model. Envoy answered an
# unknown name 404; tiers and name routing arrive with SP4 PR 2 (design D8).
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayBackend
metadata:
  name: zai
  namespace: agent-system
spec:
  ai:
    provider:
      openai:
        model: glm-5.3
      host: api.z.ai
      port: 443
      pathPrefix: /api/paas/v4
  policies:
    auth:
      secretRef:
        name: agents-zai-api-key
        key: apiKey
    tls:
      sni: api.z.ai
---
# `public` only: Z.ai is a SaaS model, and internal data never reaches it
# (ADR-0042; gate AG5). /anthropic takes the Messages format for clients that
# speak it; agentgateway translates to the provider's.
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: agent-models
  namespace: agent-system
spec:
  parentRefs:
    - group: gateway.networking.k8s.io
      kind: Gateway
      name: agent-router
      namespace: agent-gateway
      sectionName: public
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /v1
        - path:
            type: PathPrefix
            value: /anthropic
      backendRefs:
        - group: agentgateway.dev
          kind: AgentgatewayBackend
          name: zai
---
# The AI backend parses every request as a completion, so GET /v1/models with
# a valid token would be a 400 (PoC N3). Answer it as Envoy's agent-router does:
# a 404 JSON body, after authentication (an Exact match outranks the prefix).
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: agent-models-list
  namespace: agent-system
spec:
  parentRefs:
    - group: gateway.networking.k8s.io
      kind: Gateway
      name: agent-router
      namespace: agent-gateway
      sectionName: public
  rules:
    - matches:
        - path:
            type: Exact
            value: /v1/models
---
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayPolicy
metadata:
  name: agent-models-list
  namespace: agent-system
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: HTTPRoute
      name: agent-models-list
  traffic:
    directResponse:
      status: 404
      body: '{"error":"model listing is not served on agent-router"}'
```

Add `  - agentgateway-llm.yaml` to `infrastructure/base/agent-router/kustomization.yaml`. The
`agent-router` child must also wait for the Gateway: add `- name: agent-gateway` to its `dependsOn`
in both `clusters/*-agent-platform/infrastructure-agent-router.yaml`.

In `infrastructure/base/agent-gateway/network-policy.yaml`, append to `agent-router-data-plane`'s egress:

```yaml
    - toFQDNs:
        - matchName: api.z.ai
      toPorts:
        - ports:
            - port: "443"
              protocol: TCP
```

- [ ] **Step 3: Run the gate again**

Run: Step 1's command.
Expected: `0 violations`, `1` backend. Then delete the `agent-models-list` policy from the render,
re-run, and expect `AG7: listener public serves an LLM route but no Exact /v1/models 404`.

- [ ] **Step 4: Commit**

```bash
git add infrastructure/base/agent-router infrastructure/base/agent-gateway/network-policy.yaml clusters/*-agent-platform/infrastructure-agent-router.yaml
git commit -m "feat(agent-router): Z.ai and /v1/models on agentgateway"
```

### Task C.2: MCP federation, the tool renames and the Allow lists (N5, N7)

**Files:**
- Create: `infrastructure/base/agent-mcp/agentgateway-mcp.yaml`
- Modify: `infrastructure/base/agent-mcp/kustomization.yaml`, `scripts/ci/tests/test-agent-mcp-scope.sh`,
  `infrastructure/base/agent-gateway/network-policy.yaml`, `clusters/*-agent-platform/infrastructure-agent-mcp.yaml`

**Interfaces:**
- Consumes: Secret `room-broker-mcp-key` (key `apiKey`); `ALTERNATIVE` from the gate (A.3).
- Produces: tools named `<target>_<tool>` on `/mcp` of `public` and `internal`; per-role sets equal to
  the scope test's `EXPECTED_ROLE_TOOLS`.

- [ ] **Step 1: Write the failing test.** In `scripts/ci/tests/test-agent-mcp-scope.sh`, before the
`# --- flux-operator-mcp RBAC` section, add:

```python
# --- agentgateway: the same per-role sets, read from the Allow lists (ADR-0053) ---
# Each expression is one alternative in the gate's canonical grammar (AG6), so the
# grants can be recomputed exactly; an expression outside it is an error here too.
import importlib.util, re
_spec = importlib.util.spec_from_file_location(
    "agw_gate", os.path.join(root, "scripts/ci/flux-schema/assert-agent-gateway.py"))
sys.path.insert(0, os.path.join(root, "scripts/ci/flux-schema"))
_agw = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_agw)

AGW_FILE = os.path.join(base, "agentgateway-mcp.yaml")
AGW_TARGETS = {"flux-operator-mcp", "mcp-victoriametrics", "mcp-victorialogs", "room-broker"}
agw_docs = [d for d in yaml.safe_load_all(open(AGW_FILE)) if d]
backend = [d for d in agw_docs if d["kind"] == "AgentgatewayBackend"]
if len(backend) != 1:
    errors.append(f"agentgateway-mcp.yaml: expected one AgentgatewayBackend, found {len(backend)}")
else:
    mcp = backend[0]["spec"]["mcp"]
    if mcp.get("prefixMode") != "Always":
        errors.append("agent-mcp backend: prefixMode must be Always, so tool names are <target>_<tool>")
    names = {t["name"] for t in mcp["targets"]}
    if names != AGW_TARGETS:
        errors.append(f"agent-mcp backend targets are {sorted(names)}, expected {sorted(AGW_TARGETS)}")
for pol in (d for d in agw_docs if d["kind"] == "AgentgatewayPolicy"):
    route = pol["metadata"]["name"]
    if route not in EXPECTED_ROLE_TOOLS:
        errors.append(f"agentgateway-mcp.yaml: unexpected policy {route}")
        continue
    got = {}
    for e in pol["spec"]["backend"]["mcp"]["authorization"]["policy"]["matchExpressions"]:
        m = _agw.ALTERNATIVE.match(e.strip())
        if not m:
            errors.append(f"{route}: expression outside the canonical grammar: {e}")
            continue
        aud = f"agent-router.{m.group('role')}.{m.group('cls')}"
        tools = set(re.findall(r'"([a-z0-9_]+)"', m.group("names")))
        got.setdefault(aud, {}).setdefault(m.group("target"), set()).update(tools)
    if got != EXPECTED_ROLE_TOOLS[route]:
        errors.append(f"{route}: Allow lists grant {got}, expected {EXPECTED_ROLE_TOOLS[route]}")
```

(The file's heredoc already imports `os`, `sys` and `yaml`.)

- [ ] **Step 2: Run it to see it fail**

Run: `bash scripts/ci/tests/test-agent-mcp-scope.sh`
Expected: a `FileNotFoundError` for `agentgateway-mcp.yaml`.

- [ ] **Step 3: Write `infrastructure/base/agent-mcp/agentgateway-mcp.yaml`:**

```yaml
# The agents' MCP tools on agentgateway (ADR-0053): one backend federating four
# servers, one route per agent-router listener, one Allow list per route.
#
# Tools are named <target>_<tool> (prefixMode Always). Target names are the
# MCPRoute backend names they replace, so a tool reads room-broker_room_post
# where Agent Router said room-broker__room_post.
#
# Allow expressions are OR-ed at runtime, whatever the CRD text says (PoC N7):
# each one is a complete alternative (role AND target AND tool names), and an
# item no expression matches is hidden from lists and refused on call. That
# covers prompts and resources too, which this file grants to nobody.
# assert-agent-gateway.py AG6 and test-agent-mcp-scope.sh pin both properties.
#
# No MCP server ever sees a run's token: the listener strips the validated JWT
# (preserveToken defaults off), and room-broker's key travels in its own header.
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayBackend
metadata:
  name: agent-mcp
  namespace: agent-system
spec:
  mcp:
    prefixMode: Always
    targets:
      - name: flux-operator-mcp
        static:
          host: flux-operator-mcp.agent-system.svc.cluster.local
          port: 9090
          path: /mcp
          protocol: StreamableHTTP
      - name: mcp-victoriametrics
        static:
          host: mcp-victoriametrics.agent-system.svc.cluster.local
          port: 8081
          path: /mcp
          protocol: StreamableHTTP
      - name: mcp-victorialogs
        static:
          host: mcp-victorialogs.agent-system.svc.cluster.local
          port: 8081
          path: /mcp
          protocol: StreamableHTTP
      - name: room-broker
        static:
          host: room-broker.agent-system.svc.cluster.local
          port: 8090
          path: /mcp
          protocol: StreamableHTTP
          policies:
            auth:
              credentials:
                - location:
                    header:
                      name: x-room-mcp-key
                  secretRef:
                    name: room-broker-mcp-key
                    key: apiKey
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: agent-mcp-public
  namespace: agent-system
spec:
  parentRefs:
    - group: gateway.networking.k8s.io
      kind: Gateway
      name: agent-router
      namespace: agent-gateway
      sectionName: public
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /mcp
      backendRefs:
        - group: agentgateway.dev
          kind: AgentgatewayBackend
          name: agent-mcp
---
# public: documentation only, plus each role's room tools.
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayPolicy
metadata:
  name: agent-mcp-public
  namespace: agent-system
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: HTTPRoute
      name: agent-mcp-public
  backend:
    mcp:
      authorization:
        action: Allow
        policy:
          matchExpressions:
            - '"agent-router.implementer.public" in jwt.aud && mcp.tool.target == "flux-operator-mcp" && mcp.tool.name in ["search_flux_docs"]'
            - '"agent-router.implementer.public" in jwt.aud && mcp.tool.target == "mcp-victoriametrics" && mcp.tool.name in ["documentation"]'
            - '"agent-router.implementer.public" in jwt.aud && mcp.tool.target == "mcp-victorialogs" && mcp.tool.name in ["documentation"]'
            - '"agent-router.implementer.public" in jwt.aud && mcp.tool.target == "room-broker" && mcp.tool.name in ["room_read", "room_post", "room_handoff"]'
            - '"agent-router.reviewer.public" in jwt.aud && mcp.tool.target == "flux-operator-mcp" && mcp.tool.name in ["search_flux_docs"]'
            - '"agent-router.reviewer.public" in jwt.aud && mcp.tool.target == "mcp-victoriametrics" && mcp.tool.name in ["documentation"]'
            - '"agent-router.reviewer.public" in jwt.aud && mcp.tool.target == "mcp-victorialogs" && mcp.tool.name in ["documentation"]'
            - '"agent-router.reviewer.public" in jwt.aud && mcp.tool.target == "room-broker" && mcp.tool.name in ["room_read", "room_post", "room_verdict"]'
            - '"agent-router.tester.public" in jwt.aud && mcp.tool.target == "flux-operator-mcp" && mcp.tool.name in ["search_flux_docs"]'
            - '"agent-router.tester.public" in jwt.aud && mcp.tool.target == "mcp-victoriametrics" && mcp.tool.name in ["documentation"]'
            - '"agent-router.tester.public" in jwt.aud && mcp.tool.target == "mcp-victorialogs" && mcp.tool.name in ["documentation"]'
            - '"agent-router.tester.public" in jwt.aud && mcp.tool.target == "room-broker" && mcp.tool.name in ["room_read", "room_post", "room_handoff", "room_verdict"]'
            - '"agent-router.triager.public" in jwt.aud && mcp.tool.target == "flux-operator-mcp" && mcp.tool.name in ["search_flux_docs"]'
            - '"agent-router.triager.public" in jwt.aud && mcp.tool.target == "mcp-victoriametrics" && mcp.tool.name in ["documentation"]'
            - '"agent-router.triager.public" in jwt.aud && mcp.tool.target == "mcp-victorialogs" && mcp.tool.name in ["documentation"]'
            - '"agent-router.triager.public" in jwt.aud && mcp.tool.target == "room-broker" && mcp.tool.name in ["room_read", "room_post", "room_handoff"]'
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: agent-mcp-internal
  namespace: agent-system
spec:
  parentRefs:
    - group: gateway.networking.k8s.io
      kind: Gateway
      name: agent-router
      namespace: agent-gateway
      sectionName: internal
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /mcp
      backendRefs:
        - group: agentgateway.dev
          kind: AgentgatewayBackend
          name: agent-mcp
---
# internal: read tools. No role gets VictoriaMetrics' operator introspection
# (tsdb_status, active_queries, top_queries); an implementer gets neither
# get_kubernetes_resources nor get_kubernetes_logs (external review M2, M3).
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayPolicy
metadata:
  name: agent-mcp-internal
  namespace: agent-system
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: HTTPRoute
      name: agent-mcp-internal
  backend:
    mcp:
      authorization:
        action: Allow
        policy:
          matchExpressions:
            - '"agent-router.implementer.internal" in jwt.aud && mcp.tool.target == "flux-operator-mcp" && mcp.tool.name in ["search_flux_docs", "get_flux_instance", "get_kubernetes_api_versions", "get_kubernetes_metrics"]'
            - '"agent-router.implementer.internal" in jwt.aud && mcp.tool.target == "mcp-victoriametrics" && mcp.tool.name in ["documentation", "query", "query_range", "metrics", "metrics_metadata", "labels", "label_values", "series", "alerts", "rules", "explain_query", "prettify_query", "metric_statistics"]'
            - '"agent-router.implementer.internal" in jwt.aud && mcp.tool.target == "mcp-victorialogs" && mcp.tool.name in ["documentation"]'
            - '"agent-router.implementer.internal" in jwt.aud && mcp.tool.target == "room-broker" && mcp.tool.name in ["room_read", "room_post", "room_handoff"]'
            - '"agent-router.reviewer.internal" in jwt.aud && mcp.tool.target == "flux-operator-mcp" && mcp.tool.name in ["search_flux_docs", "get_flux_instance", "get_kubernetes_api_versions", "get_kubernetes_resources", "get_kubernetes_metrics", "get_kubernetes_logs"]'
            - '"agent-router.reviewer.internal" in jwt.aud && mcp.tool.target == "mcp-victoriametrics" && mcp.tool.name in ["documentation", "query", "query_range", "metrics", "metrics_metadata", "labels", "label_values", "series", "alerts", "rules", "explain_query", "prettify_query", "metric_statistics"]'
            - '"agent-router.reviewer.internal" in jwt.aud && mcp.tool.target == "mcp-victorialogs" && mcp.tool.name in ["documentation", "query", "hits", "facets", "field_names", "field_values", "stats_query", "stats_query_range", "streams", "stream_ids", "stream_field_names", "stream_field_values"]'
            - '"agent-router.reviewer.internal" in jwt.aud && mcp.tool.target == "room-broker" && mcp.tool.name in ["room_read", "room_post", "room_verdict"]'
            - '"agent-router.tester.internal" in jwt.aud && mcp.tool.target == "flux-operator-mcp" && mcp.tool.name in ["search_flux_docs", "get_flux_instance", "get_kubernetes_api_versions", "get_kubernetes_resources", "get_kubernetes_metrics", "get_kubernetes_logs"]'
            - '"agent-router.tester.internal" in jwt.aud && mcp.tool.target == "mcp-victoriametrics" && mcp.tool.name in ["documentation", "query", "query_range", "metrics", "metrics_metadata", "labels", "label_values", "series", "alerts", "rules", "explain_query", "prettify_query", "metric_statistics"]'
            - '"agent-router.tester.internal" in jwt.aud && mcp.tool.target == "mcp-victorialogs" && mcp.tool.name in ["documentation", "query", "hits", "facets", "field_names", "field_values", "stats_query", "stats_query_range", "streams", "stream_ids", "stream_field_names", "stream_field_values"]'
            - '"agent-router.tester.internal" in jwt.aud && mcp.tool.target == "room-broker" && mcp.tool.name in ["room_read", "room_post", "room_handoff", "room_verdict"]'
            - '"agent-router.triager.internal" in jwt.aud && mcp.tool.target == "flux-operator-mcp" && mcp.tool.name in ["search_flux_docs", "get_flux_instance", "get_kubernetes_api_versions", "get_kubernetes_resources", "get_kubernetes_metrics", "get_kubernetes_logs"]'
            - '"agent-router.triager.internal" in jwt.aud && mcp.tool.target == "mcp-victoriametrics" && mcp.tool.name in ["documentation", "query", "query_range", "metrics", "metrics_metadata", "labels", "label_values", "series", "alerts", "rules", "explain_query", "prettify_query", "metric_statistics"]'
            - '"agent-router.triager.internal" in jwt.aud && mcp.tool.target == "mcp-victorialogs" && mcp.tool.name in ["documentation", "query", "hits", "facets", "field_names", "field_values", "stats_query", "stats_query_range", "streams", "stream_ids", "stream_field_names", "stream_field_values"]'
            - '"agent-router.triager.internal" in jwt.aud && mcp.tool.target == "room-broker" && mcp.tool.name in ["room_read", "room_post", "room_handoff"]'
```

Add `  - agentgateway-mcp.yaml` to `infrastructure/base/agent-mcp/kustomization.yaml`, and
`- name: agent-gateway` to the `dependsOn` of both `clusters/*-agent-platform/infrastructure-agent-mcp.yaml`.

In `infrastructure/base/agent-gateway/network-policy.yaml`, append to the data plane's egress:

```yaml
    # The four MCP targets (agent-mcp backend).
    - toEndpoints:
        - matchLabels:
            io.kubernetes.pod.namespace: agent-system
            app.kubernetes.io/name: flux-operator-mcp
      toPorts:
        - ports:
            - port: "9090"
              protocol: TCP
    - toEndpoints:
        - matchLabels:
            io.kubernetes.pod.namespace: agent-system
            app.kubernetes.io/name: mcp-victoriametrics
        - matchLabels:
            io.kubernetes.pod.namespace: agent-system
            app.kubernetes.io/name: mcp-victorialogs
      toPorts:
        - ports:
            - port: "8081"
              protocol: TCP
    - toEndpoints:
        - matchLabels:
            io.kubernetes.pod.namespace: agent-system
            app.kubernetes.io/name: room-broker
      toPorts:
        - ports:
            - port: "8090"
              protocol: TCP
```

- [ ] **Step 4: Run the tests and the gate**

Run: `bash scripts/ci/tests/test-agent-mcp-scope.sh && kustomize build infrastructure/gcp-0/agent-mcp > /tmp/claude-agwc/c.yaml && python3 scripts/ci/flux-schema/assert-agent-gateway.py /tmp/claude-agwc`
Expected: the scope test passes; `0 violations`. Then change one expression's `"room_read"` to
`"room_verdict"` in a scratch copy and expect the scope test to fail naming that role.

- [ ] **Step 5: Commit**

```bash
git add infrastructure/base/agent-mcp scripts/ci/tests/test-agent-mcp-scope.sh infrastructure/base/agent-gateway/network-policy.yaml clusters/*-agent-platform/infrastructure-agent-mcp.yaml
git commit -m "feat(agent-mcp): federate the agents' MCP tools on agentgateway, deny by default"
```

### Task C.3: The `sts` route and the servers' ingress peers

**Files:**
- Modify: `security/base/octo-sts/httproute.yaml`, `security/base/octo-sts/network-policy.yaml`,
  `infrastructure/base/agent-mcp/flux-operator-mcp-network-policy.yaml`, `infrastructure/base/agent-mcp/mcp-victoriametrics.yaml`,
  `infrastructure/base/agent-mcp/mcp-victorialogs.yaml`, `infrastructure/base/room-broker/network-policy.yaml`,
  `infrastructure/base/agent-gateway/network-policy.yaml`

- [ ] **Step 1: The failing check**

Run: `grep -c 'gateway.networking.k8s.io/gateway-name: agent-router' security/base/octo-sts/network-policy.yaml infrastructure/base/agent-mcp/*.yaml infrastructure/base/room-broker/network-policy.yaml`
Expected: `0` everywhere.

- [ ] **Step 2: octo-sts's route gets a second parent.** In `security/base/octo-sts/httproute.yaml`,
append to `parentRefs`:

```yaml
    # agentgateway's sts listener (ADR-0053); the Envoy parent goes in phase H.
    - group: gateway.networking.k8s.io
      kind: Gateway
      name: agent-router
      namespace: agent-gateway
      sectionName: sts
```

- [ ] **Step 3: Each server admits the new proxies too.** In each of the five CNPs, the existing
`fromEndpoints` entry for `envoy-gateway-system` / `owning-gateway-name: agent-router` gets a sibling
entry in the same list:

```yaml
        # agentgateway's agent router (ADR-0053); the Envoy peer goes in phase H.
        - matchLabels:
            io.kubernetes.pod.namespace: agent-gateway
            gateway.networking.k8s.io/gateway-name: agent-router
```

Files: `security/base/octo-sts/network-policy.yaml`, `infrastructure/base/agent-mcp/flux-operator-mcp-network-policy.yaml`,
`infrastructure/base/agent-mcp/mcp-victoriametrics.yaml`, `infrastructure/base/agent-mcp/mcp-victorialogs.yaml`,
`infrastructure/base/room-broker/network-policy.yaml`.

In `infrastructure/base/agent-gateway/network-policy.yaml`, append to the data plane's egress:

```yaml
    # octo-sts behind the sts listener.
    - toEndpoints:
        - matchLabels:
            io.kubernetes.pod.namespace: agent-system
            app.kubernetes.io/name: octo-sts
      toPorts:
        - ports:
            - port: "8080"
              protocol: TCP
```

- [ ] **Step 4: Verify and commit**

Run: Step 1's grep, then `kustomize build infrastructure/gcp-0/agent-router >/dev/null && kustomize build security/base/octo-sts | grep -c 'sectionName: sts'`
Expected: `1` in each of the five files; `2`.

```bash
git add security/base/octo-sts infrastructure/base/agent-mcp infrastructure/base/room-broker/network-policy.yaml infrastructure/base/agent-gateway/network-policy.yaml
git commit -m "feat(agents): octo-sts and the MCP servers accept the agentgateway router"
```

### Task C.4: The probe reaches either gateway

**Files:**
- Modify: `scripts/ops/k8s/agent-probe.yaml`, `scripts/ops/k8s/agent-probe-mcp.sh`

- [ ] **Step 1: The probe's CNP.** In `scripts/ops/k8s/agent-probe.yaml`, the egress rule to the
Envoy data plane gets a sibling `toEndpoints` entry:

```yaml
        - matchLabels:
            io.kubernetes.pod.namespace: agent-gateway
            gateway.networking.k8s.io/gateway-name: agent-router
```

and its DNS rule allows `agent-router.agent-gateway.svc.cluster.local` beside the Envoy FQDN.

- [ ] **Step 2: The host is a parameter.** In `scripts/ops/k8s/agent-probe-mcp.sh`, replace the `URL=` line with:

```sh
# AGENT_ROUTER_HOST picks the gateway during the cutover (ADR-0053).
HOST=${AGENT_ROUTER_HOST:-agent-router.envoy-gateway-system.svc.cluster.local}
URL=http://$HOST:$PORT/mcp
```

and the usage comment gains `AGENT_ROUTER_HOST=agent-router.agent-gateway.svc.cluster.local`.

- [ ] **Step 3: Verify and commit**

Run: `sh -n scripts/ops/k8s/agent-probe-mcp.sh && ./scripts/ci/tests/run.sh 2>&1 | grep -E 'no-secret-argv|script-paths'`
Expected: no syntax error; both `PASS`.

```bash
git add scripts/ops/k8s/agent-probe.yaml scripts/ops/k8s/agent-probe-mcp.sh
git commit -m "chore(ops): the agent probe can target either agent router"
```

### Task C.5: Gates, AGW-3, and the probe's live checks

- [ ] **Step 1: Gates and draft.** Task A.4 Step 1's gates; AGW-3 as a draft on `feat/agw-platform`,
title `feat(agents): agent router routes and policies on agentgateway (ADR-0053 phase C)`, the P33
hold line, a mermaid diagram of the three listeners and what attaches to each.

- [ ] **Step 2: [LIVE] Merge AGW-3 into integration.** Wait for `agent-router`, `agent-mcp`, `octo-sts`
Ready. Then `kubectl get httproute -n agent-system agent-models agent-mcp-public agent-mcp-internal octo-sts -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.parents[*].conditions[?(@.type=="Accepted")].status}{"\n"}{end}'`
Expected: `True` for every parent, both gateways for `octo-sts`. This settles D1's cross-namespace
attachment; if any is `False` with `NotAllowedByListeners`, stop and apply D1's fallback.

- [ ] **Step 3: [LIVE] Probe the new gateway.** `kubectl apply -f scripts/ops/k8s/agent-probe.yaml`,
wait Ready, copy `agent-probe-mcp.sh` in as runbook 06 does, then with
`H=agent-router.agent-gateway.svc.cluster.local`:

| Check | Command (inside the probe) | Expected |
|---|---|---|
| P8 no token | `curl -s -o /dev/null -w '%{http_code}' http://$H:8080/v1/models` | `401` |
| PC5 `/v1/models` | same with `-H @<public token header file>` | `404`, body `{"error":"model listing is not served on agent-router"}` |
| P1 cross-class | public token on `:8081` | `401` |
| P2 forged header | `POST /v1/chat/completions` model `agent-default`, header `x-ar-agent: system:serviceaccount:agents:forged` | `200`; the proxy access log shows `x_ar_agent` = the probe's own sub |
| P4 public tools | `AGENT_ROUTER_HOST=$H sh /tmp/mcp.sh public tools/list \| grep -o '"name":"[^"]*"'` | exactly `flux-operator-mcp_search_flux_docs`, `mcp-victoriametrics_documentation`, `mcp-victorialogs_documentation`, `room-broker_room_read`, `room-broker_room_post`, `room-broker_room_handoff` |
| P4 resources | `… public resources/list` | an empty list |
| P4 no bearer | `kubectl logs -n agent-system -l app.kubernetes.io/name=mcp-victoriametrics --since=5m \| grep -ci authorization` | `0` |
| P1 wrong namespace | a pod outside `agents` cannot even connect (data-plane CNP); the 403 path is proven by the gate's AG2 and in G.2 | connection refused/timeout |

Tear the probe down: `kubectl delete -f scripts/ops/k8s/agent-probe.yaml`. Paste every output into
AGW-3's "Live evidence".

---

## Phase D — AGW-4: budgets on our rate-limit server (G1, N2)

Gate: AG8 green on a real `rateLimit.global`; on gcp-0, B1 and B2 shadow counters rise by exact token
totals on the KVStore and no request is refused.

### Task D.1: The store and the rate-limit server

**Files:**
- Create: `infrastructure/base/agent-gateway/{kvstore.yaml,externalsecret-valkey.yaml,ratelimit.yaml}`
- Modify: `infrastructure/base/agent-gateway/kustomization.yaml`, `infrastructure/base/agent-gateway/network-policy.yaml`

**Interfaces:**
- Produces: Service `agent-ratelimit.agent-gateway:8081` (RLS v3 gRPC), ConfigMap `agent-ratelimit-config`
  (domain `agent-router`), metrics on `:19001`.

- [ ] **Step 1: The failing check**

Run: `kustomize build infrastructure/gcp-0/agent-gateway | grep -c 'name: agent-ratelimit$'`
Expected: `0`.

- [ ] **Step 2: Write `externalsecret-valkey.yaml`** (the `ai-gateway` store's pattern, design D4):

```yaml
# Read by both ends: the KVStore composition sets it as Valkey's password, and
# agent-ratelimit presents it as REDIS_AUTH. Generated in-cluster: the counters
# are ephemeral, so a per-cluster password loses nothing. CreatedOnce: a
# rotation would lock the running Valkey out.
apiVersion: generators.external-secrets.io/v1alpha1
kind: Password
metadata:
  name: agent-ratelimit-valkey
  namespace: agent-gateway
spec:
  length: 48
  symbols: 0
  noUpper: false
  allowRepeat: true
  secretKeys:
    - REDIS_PASSWORD
---
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: agent-ratelimit-valkey
  namespace: agent-gateway
spec:
  refreshPolicy: CreatedOnce
  dataFrom:
    - sourceRef:
        generatorRef:
          apiVersion: generators.external-secrets.io/v1alpha1
          kind: Password
          name: agent-ratelimit-valkey
  target:
    creationPolicy: Owner
    deletionPolicy: Retain
    name: agent-ratelimit-valkey
```

- [ ] **Step 3: Write `kvstore.yaml`:**

```yaml
# B1-B2 counters (ADR-0053). Its own store, not ai-gateway's: that password
# lives in envoy-gateway-system, and agent budgets never share a bucket with
# B3-B5. Ephemeral, as there: a restart resets the day, harmless in shadow.
apiVersion: cloud.ogenki.io/v1alpha1
kind: KVStore
metadata:
  name: xplane-agent-ratelimit
  namespace: agent-gateway
spec:
  size: nano
  auth:
    existingSecret: agent-ratelimit-valkey # pragma: allowlist secret — checkov:skip=CKV_SECRET_6 secret name, not a value
    passwordKey: REDIS_PASSWORD # pragma: allowlist secret
```

- [ ] **Step 4: Write `ratelimit.yaml`:**

```yaml
# agentgateway speaks Envoy's RLS v3 and bundles no server (gap G1): this is
# envoyproxy/ratelimit, the image Envoy Gateway runs, with a static config.
# Shadow mode lives here, per descriptor, not in any CRD; gate AG8 reads both
# objects. Limits are ADR-0050's: B1 5M tokens/day per run, B2 40M/day fleet.
apiVersion: v1
kind: ConfigMap
metadata:
  name: agent-ratelimit-config
  namespace: agent-gateway
data:
  config.yaml: |
    domain: agent-router
    descriptors:
      - key: agent
        rate_limit:
          unit: day
          requests_per_unit: 5000000
        shadow_mode: true
      - key: fleet
        value: agents
        rate_limit:
          unit: day
          requests_per_unit: 40000000
        shadow_mode: true
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: agent-ratelimit
  namespace: agent-gateway
automountServiceAccountToken: false
---
# One replica: the policy fails open, so a restart costs a few unmetered
# requests in shadow mode. Enforcement (SP4 PR 7) revisits HA.
apiVersion: apps/v1
kind: Deployment
metadata:
  name: agent-ratelimit
  namespace: agent-gateway
spec:
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: agent-ratelimit
  template:
    metadata:
      labels:
        app.kubernetes.io/name: agent-ratelimit
    spec:
      serviceAccountName: agent-ratelimit
      automountServiceAccountToken: false
      securityContext:
        runAsNonRoot: true
        runAsUser: 65534
        runAsGroup: 65534
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: ratelimit
          image: docker.io/envoyproxy/ratelimit:0482748e@sha256:5fdd8e3ae335ab6d64316f8d2fd9a886830075cbbb40a1d8065c869275909162
          command: ["/bin/ratelimit"]
          env:
            - {name: RUNTIME_ROOT, value: /data}
            - {name: RUNTIME_SUBDIRECTORY, value: ratelimit}
            - {name: RUNTIME_WATCH_ROOT, value: "false"}
            - {name: RUNTIME_IGNOREDOTFILES, value: "true"}
            - {name: LOG_LEVEL, value: info}
            - {name: LOG_FORMAT, value: json}
            - {name: USE_STATSD, value: "false"}
            - {name: USE_PROMETHEUS, value: "true"}
            - {name: PROMETHEUS_ADDR, value: ":19001"}
            - {name: REDIS_SOCKET_TYPE, value: tcp}
            - {name: REDIS_URL, value: xplane-agent-ratelimit-valkey.agent-gateway.svc.cluster.local:6379}
            - name: REDIS_AUTH
              valueFrom:
                secretKeyRef:
                  name: agent-ratelimit-valkey
                  key: REDIS_PASSWORD
            - {name: GRPC_PORT, value: "8081"}
            - {name: PORT, value: "8080"}
          ports:
            - {name: grpc, containerPort: 8081, protocol: TCP}
            - {name: http, containerPort: 8080, protocol: TCP}
            - {name: metrics, containerPort: 19001, protocol: TCP}
          readinessProbe:
            httpGet: {path: /healthcheck, port: http}
          livenessProbe:
            httpGet: {path: /healthcheck, port: http}
            periodSeconds: 20
          resources:
            requests: {cpu: 10m, memory: 32Mi}
            limits: {cpu: 200m, memory: 128Mi}
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            runAsNonRoot: true
            capabilities:
              drop: ["ALL"]
            seccompProfile:
              type: RuntimeDefault
          volumeMounts:
            - name: config
              mountPath: /data/ratelimit/config
              readOnly: true
      volumes:
        - name: config
          configMap:
            name: agent-ratelimit-config
---
apiVersion: v1
kind: Service
metadata:
  name: agent-ratelimit
  namespace: agent-gateway
spec:
  selector:
    app.kubernetes.io/name: agent-ratelimit
  ports:
    - name: grpc
      port: 8081
      targetPort: grpc
      appProtocol: kubernetes.io/h2c
    - name: metrics
      port: 19001
      targetPort: metrics
---
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: agent-ratelimit
  namespace: agent-gateway
spec:
  endpointSelector:
    matchLabels:
      app.kubernetes.io/name: agent-ratelimit
  ingress:
    - fromEndpoints:
        - matchLabels:
            gateway.networking.k8s.io/gateway-name: agent-router
      toPorts:
        - ports:
            - {port: "8081", protocol: TCP}
    - fromEntities: [host]
      toPorts:
        - ports:
            - {port: "8080", protocol: TCP}
    - fromEndpoints:
        - matchLabels:
            io.kubernetes.pod.namespace: observability
            app.kubernetes.io/name: vmagent
      toPorts:
        - ports:
            - {port: "19001", protocol: TCP}
  egress:
    - toEndpoints:
        - matchLabels:
            io.kubernetes.pod.namespace: kube-system
            k8s-app: kube-dns
      toPorts:
        - ports:
            - {port: "53", protocol: UDP}
            - {port: "53", protocol: TCP}
          rules:
            dns:
              - matchPattern: "*"
    - toEndpoints:
        - matchLabels:
            app.kubernetes.io/name: valkey
            app.kubernetes.io/instance: xplane-agent-ratelimit-valkey
      toPorts:
        - ports:
            - {port: "6379", protocol: TCP}
---
# Shadow counters: the only evidence of what B1-B2 WOULD refuse.
apiVersion: operator.victoriametrics.com/v1beta1
kind: VMPodScrape
metadata:
  name: agent-ratelimit
  namespace: agent-gateway
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: agent-ratelimit
  podMetricsEndpoints:
    - port: metrics
      path: /metrics
      interval: 30s
```

Add the three files to `infrastructure/base/agent-gateway/kustomization.yaml`. Append to the data
plane's egress in `network-policy.yaml`:

```yaml
    # Budget checks (fail open: a dropped check admits the request).
    - toEndpoints:
        - matchLabels:
            app.kubernetes.io/name: agent-ratelimit
      toPorts:
        - ports:
            - port: "8081"
              protocol: TCP
```

- [ ] **Step 5: Verify and commit**

Run: Step 1's command; `kustomize build infrastructure/aws-0/agent-gateway | grep -c 'kind: KVStore'`
Expected: `≥ 1`; `1`.

```bash
git add infrastructure/base/agent-gateway
git commit -m "feat(agent-gateway): our rate-limit server and its Valkey store for agent budgets"
```

### Task D.2: B1–B2 in shadow

**Files:**
- Create: `infrastructure/base/agent-gateway/policy-budgets.yaml`
- Modify: `infrastructure/base/agent-gateway/kustomization.yaml`

- [ ] **Step 1: The failing check.** Prove AG8 sees nothing yet:

Run: `kustomize build infrastructure/gcp-0/agent-gateway | grep -c 'rateLimit:'`
Expected: `0`.

- [ ] **Step 2: Write `policy-budgets.yaml`:**

```yaml
# B1-B2 (ADR-0050's limits, ADR-0053's mechanism). Gateway-wide, so one bucket
# per principal across every listener and route: descriptors name the verified
# sub (B1) or a constant (B2), never a route (gate AG8). Cost = total tokens,
# charged after completion; a zero-cost check runs first. A stream cut before
# completion is never charged (PoC N2; ADR-0053 records the residual).
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayPolicy
metadata:
  name: token-budgets
  namespace: agent-gateway
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: Gateway
      name: agent-router
  traffic:
    rateLimit:
      global:
        backendRef:
          name: agent-ratelimit
          port: 8081
        domain: agent-router
        failureMode: FailOpen
        descriptors:
          - entries:
              - name: agent
                expression: jwt.sub
            unit: Tokens
          - entries:
              - name: fleet
                expression: '"agents"'
            unit: Tokens
```

Add it to the kustomization.

- [ ] **Step 3: Gate both ways**

Run: `mkdir -p /tmp/claude-agwd && kustomize build infrastructure/gcp-0/agent-gateway > /tmp/claude-agwd/a.yaml && python3 scripts/ci/flux-schema/assert-agent-gateway.py /tmp/claude-agwd`
Expected: `0 violations`. Then set `shadow_mode: false` on `agent` in the render, re-run, expect
`AG8: … descriptor agent must set shadow_mode: true`. `rm -rf /tmp/claude-agwd`.

- [ ] **Step 4: Commit**

```bash
git add infrastructure/base/agent-gateway
git commit -m "feat(agent-gateway): per-run and fleet token budgets, in shadow"
```

### Task D.3: Gates, AGW-4, and PC6 live

- [ ] **Step 1: Gates and draft** (Task A.4 Step 1). AGW-4 on `feat/agw-routes`, title
`feat(agents): agent budgets on agentgateway, in shadow (ADR-0053 phase D)`, P33 hold line.

- [ ] **Step 2: [LIVE] PC6.** Merge into integration; wait for `agent-gateway` Ready and
`kubectl get kvstore -n agent-gateway xplane-agent-ratelimit` Ready. From the probe (Task C.4), make
two non-streamed completions and one streamed (`max_tokens` 2000) on `public`, one MCP `tools/list`,
then:

```bash
kubectl port-forward -n agent-gateway svc/agent-ratelimit 19001:19001 &
curl -s localhost:19001/metrics | grep -E 'ratelimit_service_rate_limit_(total_hits|shadow_mode)\{.*domain="agent-router"'
```

Expected: `key1="agent"` and `key1="fleet"` series; `total_hits` equals the sum of the three
responses' `usage.total_tokens` (the MCP call adds 0); `shadow_mode` > 0 only if a limit was crossed;
every response `200`. Then `kubectl delete pod -n agent-gateway -l app.kubernetes.io/name=agent-ratelimit`
and send one completion while it restarts: `200` (fail open). Paste outputs into AGW-4.

---

## Phase E — AGW-5: observability (G2, traces)

Gate: on gcp-0 the run page shows a probe call's tokens, latency and gateway logs; the guard alert is
inactive with traffic flowing; spans join the caller's trace without `http.path`.

### Task E.1: Telemetry policy, the trace grant, and the facts E.2–E.3 need

**Files:**
- Create: `infrastructure/base/agent-gateway/policy-telemetry.yaml`
- Modify: `infrastructure/base/agent-gateway/kustomization.yaml`, `infrastructure/base/agent-gateway/network-policy.yaml`,
  `observability/base/agent-platform/referencegrant-agent-traces.yaml`, `observability/base/agent-platform/agent-traces-collector.yaml`,
  `scripts/ci/tests/test-agent-observability.py`

- [ ] **Step 1: Write the failing test.** In `scripts/ci/tests/test-agent-observability.py`, the
`CNP_INGRESS` :4317 rule's `fromEndpoints` gains, after the Envoy entry:

```python
                       {"matchLabels": {"io.kubernetes.pod.namespace": "agent-gateway",
                                        "gateway.networking.k8s.io/gateway-name": "agent-router"}},
```

and `check_reference_grant()` additionally requires a `ReferenceGrant` `agent-gateway-traces` in
`observability` whose `from` is `[{"group": "agentgateway.dev", "kind": "AgentgatewayPolicy", "namespace": "agent-gateway"}]`
and whose `to` is the collector Service, written like the existing EnvoyProxy grant check.

Run: `python3 scripts/ci/tests/test-agent-observability.py`
Expected: FAIL on the collector ingress and the missing grant.

- [ ] **Step 2: Implement.** In `agent-traces-collector.yaml`'s CNP, add the same entry to the :4317
rule's `fromEndpoints`. Append to `referencegrant-agent-traces.yaml`:

```yaml
---
# agentgateway enforces cross-namespace backendRefs (unlike EG 1.9.2), so
# without this grant the agent router's spans never leave the proxy.
apiVersion: gateway.networking.k8s.io/v1beta1
kind: ReferenceGrant
metadata:
  name: agent-gateway-traces
  namespace: observability
spec:
  from:
    - group: agentgateway.dev
      kind: AgentgatewayPolicy
      namespace: agent-gateway
  to:
    - group: ""
      kind: Service
      name: agent-traces-collector
```

(Use the `apiVersion` the existing grant in that file uses.) Create `policy-telemetry.yaml`:

```yaml
# Spans, access logs and metric labels for the agent router (ADR-0051 on
# agentgateway). attributes.remove drops the request path and user agent at
# the source, the residual Envoy Gateway could not close; the collector's
# transform/cap still bounds what is left. Every identity label is the
# verified sub. The buffer is Envoy's 8Mi: the 2mb default broke federated
# resources/list (PoC N4).
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayPolicy
metadata:
  name: telemetry
  namespace: agent-gateway
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: Gateway
      name: agent-router
  frontend:
    http:
      maxBufferSize: 8Mi
    tracing:
      backendRef:
        name: agent-traces-collector
        namespace: observability
        port: 4317
      protocol: GRPC
      randomSampling: "true"
      attributes:
        remove:
          - http.path
          - user_agent.name
        add:
          - name: agent.principal
            expression: jwt.sub
    accessLog:
      attributes:
        add:
          - name: x_ar_agent
            expression: jwt.sub
    metrics:
      attributes:
        add:
          - name: ar_agent
            expression: jwt.sub
```

Add it to the kustomization, and append to the data plane's egress:

```yaml
    - toEndpoints:
        - matchLabels:
            io.kubernetes.pod.namespace: observability
            app.kubernetes.io/name: agent-traces-collector
      toPorts:
        - ports:
            - port: "4317"
              protocol: TCP
```

- [ ] **Step 3: Run the test, commit**

Run: `python3 scripts/ci/tests/test-agent-observability.py`
Expected: all checks pass.

```bash
git add infrastructure/base/agent-gateway observability/base/agent-platform scripts/ci/tests/test-agent-observability.py
git commit -m "feat(agent-gateway): traces, access logs and metric labels for the agent router"
```

- [ ] **Step 4: [LIVE] Capture the facts.** Merge into integration, make one probe completion, then
record in AGW-5's body (these values pin E.2 and E.3; stop if they differ from the assumptions):

```bash
kubectl port-forward -n agent-gateway deploy/agent-router 15020:15020 &
curl -s localhost:15020/metrics | grep -E '^agentgateway_(gen_ai|requests_total)' | sed 's/{.*//' | sort -u
curl -s localhost:15020/metrics | grep -E '^agentgateway_gen_ai_server_request_duration_bucket' | head -3
kubectl logs -n agent-gateway -l gateway.networking.k8s.io/gateway-name=agent-router --since=5m | head -2
```

Assumptions to confirm: the token series is `agentgateway_gen_ai_client_token_usage_sum` with
`gen_ai_token_type`, `gen_ai_request_model`, `ar_agent`; the duration histogram's `le` values are
seconds (the largest finite bucket is under 1000); `agentgateway_requests_total` carries `status`
and `reason`; the access-log JSON field names for path and status (record them, for example
`http.path`/`http.status`).

### Task E.2: Scrape relabel and the alerts (G2)

**Files:**
- Create: `infrastructure/base/agent-gateway/vmpodscrape.yaml`
- Modify: `infrastructure/base/agent-gateway/kustomization.yaml`, `observability/base/agent-platform/vmrule.yaml`,
  `observability/base/agent-platform/vmrule-logs.yaml`

- [ ] **Step 1: The failing check**

Run: `grep -c 'AgentRouterMetricContractBroken\|AgentRateLimitDown' observability/base/agent-platform/vmrule.yaml`
Expected: `0`.

- [ ] **Step 2: Write `vmpodscrape.yaml`** (if E.1 Step 4 found the histogram in milliseconds, drop
the second relabel rule and divide by 1000 in E.3's queries instead):

```yaml
# The agent router's proxies (ADR-0053), relabelled to the gen_ai_* names
# ai-gateway still emits, so dashboards, alerts and the run meter keep one
# metric contract across both gateways (design D5). The guard alert
# AgentRouterMetricContractBroken catches an upstream rename.
apiVersion: operator.victoriametrics.com/v1beta1
kind: VMPodScrape
metadata:
  name: agent-router
  namespace: agent-gateway
spec:
  selector:
    matchLabels:
      gateway.networking.k8s.io/gateway-name: agent-router
  podMetricsEndpoints:
    - port: metrics
      path: /metrics
      interval: 30s
      metricRelabelConfigs:
        - sourceLabels: [__name__]
          regex: agentgateway_gen_ai_(.+)
          targetLabel: __name__
          replacement: gen_ai_$1
        - sourceLabels: [__name__]
          regex: gen_ai_server_request_duration_(bucket|sum|count)
          targetLabel: __name__
          replacement: gen_ai_server_request_duration_seconds_$1
```

Check the proxy container's metrics port name first:
`kubectl get deploy -n agent-gateway agent-router -o jsonpath='{.spec.template.spec.containers[0].ports}'`.
If `15020` has no name, use `targetPort: 15020` instead of `port: metrics`.

- [ ] **Step 3: The alerts.** In `observability/base/agent-platform/vmrule.yaml`, append to the
`agent-platform` group (keep its annotation shape):

```yaml
        # G2 guard: the relabel above keeps the gen_ai_* contract only while
        # upstream's names hold. LLM requests flowing with no token series is
        # the signature of a silent rename.
        - alert: AgentRouterMetricContractBroken
          expr: sum(increase(agentgateway_requests_total{namespace="agent-gateway", route=~"agent-system/agent-models.*"}[15m])) > 0 unless sum(increase(gen_ai_client_token_usage_sum{namespace="agent-gateway"}[15m])) > 0
          for: 15m
          labels:
            severity: warning
          annotations:
            summary: "agent-router serves model calls but no gen_ai token series exists"
            description: "An agentgateway upgrade renamed a metric the VMPodScrape relabel expects (infrastructure/base/agent-gateway/vmpodscrape.yaml). Dashboards, budgets alerts and the run meter read zero until fixed."
            runbook_url: "https://github.com/Smana/cloud-native-ref/blob/integration/agent-factory/docs/runbooks/agent-factory/08-observability.md"
            dashboard: "https://grafana.${private_domain_name}/d/agent-platform"
        - alert: AgentRateLimitDown
          expr: absent(up{namespace="agent-gateway", pod=~"agent-ratelimit-.*"} == 1)
          for: 5m
          labels:
            severity: warning
          annotations:
            summary: "agent-ratelimit is down: agent budgets count nothing"
            description: "The agent router fails open, so agents keep running unmetered. kubectl get pods -n agent-gateway -l app.kubernetes.io/name=agent-ratelimit"
            runbook_url: "https://github.com/Smana/cloud-native-ref/blob/integration/agent-factory/docs/runbooks/agent-factory/04-gateway-secrets-budgets.md"
            dashboard: "https://grafana.${private_domain_name}/d/agent-platform"
        # Replaces the LogsQL AgentRouterUnauthorizedBurst for agentgateway:
        # requests_total carries the refusal reason (PoC), which promtool can check.
        - alert: AgentGatewayUnauthorizedBurst
          expr: sum(increase(agentgateway_requests_total{namespace="agent-gateway", reason=~"JwtAuth|Authorization"}[5m])) > 20
          labels:
            severity: warning
          annotations:
            summary: "agent-router (agentgateway) refused {{ $value }} requests in 5 minutes"
            description: "Invalid tokens, wrong audience or a sub outside namespace agents. T8: replayed or foreign tokens."
            runbook_url: "https://github.com/Smana/cloud-native-ref/blob/integration/agent-factory/docs/runbooks/agent-factory/02-identity-tokens.md"
            dashboard: "https://grafana.${private_domain_name}/d/agent-platform"
```

Use the label names E.1 Step 4 recorded for `route` and `reason`. `vmrule-logs.yaml` is unchanged
until phase H (its Envoy alert keeps covering runs still on Envoy).

- [ ] **Step 4: Verify and commit**

Run: `./scripts/ci/validate-vmrules.sh && python3 scripts/ci/flux-schema/check-substitution.py`
Expected: exit 0 both.

```bash
git add infrastructure/base/agent-gateway observability/base/agent-platform/vmrule.yaml
git commit -m "feat(observability): one gen_ai metric contract across both gateways, and its guard"
```

### Task E.3: Dashboards across both gateways

**Files:**
- Modify: `observability/base/agent-platform/grafana-dashboard-agent-run.yaml`, `scripts/ci/tests/test-agent-observability.py`

- [ ] **Step 1: Write the failing test.** In `test-agent-observability.py`'s dashboard checks, add:

```python
    raw_run = (ROOT / "observability/base/agent-platform/grafana-dashboard-agent-run.yaml").read_text()
    check("gateway.networking.k8s.io/gateway-name:\\\"agent-router\\\"" in raw_run,
          "the run page's gateway log panels select agentgateway's proxies too (ADR-0053)")
    check("agentgateway_requests_total" in raw_run,
          "the run page's error rate covers agentgateway, which has no error_type label (G2)")
```

Run: `python3 scripts/ci/tests/test-agent-observability.py`
Expected: FAIL on both.

- [ ] **Step 2: The LogsQL panels.** In panels 6, 7 and 8B of `grafana-dashboard-agent-run.yaml`,
each selector
`kubernetes.pod_labels.gateway.envoyproxy.io/owning-gateway-name:\"agent-router\" AND kubernetes.pod_labels.gateway.envoyproxy.io/owning-gateway-namespace:\"agent-system\"`
becomes
`((kubernetes.pod_labels.gateway.envoyproxy.io/owning-gateway-name:\"agent-router\" AND kubernetes.pod_labels.gateway.envoyproxy.io/owning-gateway-namespace:\"agent-system\") OR (kubernetes.pod_namespace:\"agent-gateway\" AND kubernetes.pod_labels.gateway.networking.k8s.io/gateway-name:\"agent-router\"))`,
and each filter on `log.path`/`log.response_code` becomes an OR of the Envoy field and the
agentgateway field recorded in E.1 Step 4 (for example
`(log.path:~\"chat/completions\" OR log.http.path:~\"chat/completions\")`).

- [ ] **Step 3: The error rate.** Panel 12's target becomes two targets, A (Envoy, unchanged) and:

```json
{"refId": "B", "instant": true, "expr": "(sum(increase(agentgateway_requests_total{ar_agent=\"system:serviceaccount:agents:xplane-run-$${run}\", status=~\"5..\"}[$__range])) or vector(0)) / sum(increase(agentgateway_requests_total{ar_agent=\"system:serviceaccount:agents:xplane-run-$${run}\"}[$__range]))"}
```

with the panel reducing both by `max` (a run used one gateway or the other). Token, cost and
latency panels need nothing: the relabel keeps their names (D5).

- [ ] **Step 4: Run the test, commit**

Run: `python3 scripts/ci/tests/test-agent-observability.py && python3 scripts/ci/flux-schema/check-substitution.py`
Expected: pass; exit 0.

```bash
git add observability/base/agent-platform/grafana-dashboard-agent-run.yaml scripts/ci/tests/test-agent-observability.py
git commit -m "feat(observability): the run page reads both agent routers during the cutover"
```

### Task E.4: Gates, AGW-5, live

- [ ] **Step 1: Gates and draft** (Task A.4 Step 1 plus `./scripts/ci/validate-vmrules.sh`). AGW-5 on
`feat/agw-budgets`, title `feat(agents): agent router observability on agentgateway (ADR-0053 phase E)`,
P33 hold line.

- [ ] **Step 2: [LIVE] SC-8 and SC-9 on the probe's traffic.** Merge into integration. With one probe
completion sent with `traceparent: 00-<32 hex>-<16 hex>-01`:
- VictoriaMetrics: `sum by (gen_ai_token_type) (gen_ai_client_token_usage_sum{namespace="agent-gateway", ar_agent=~".*:agent-probe"})` returns input and output;
- `AgentRouterMetricContractBroken` and `AgentRateLimitDown` inactive (`mcp__victoriametrics__alerts`);
- VictoriaTraces `GET /select/jaeger/api/traces/<trace id>`: a server span of service `agent-router`
  whose parent is the sent span id, `agent.principal` = the probe's sub, no `http.path` tag.
Paste into AGW-5.

---

## Phase F — the cutover (G4, N5)

Gate: a real run started after AGW-6 reaches the model, MCP tools and octo-sts through agentgateway;
runs started before it finish on Envoy.

### Task F.1: AP-AGW1, the bridge reads agentgateway's tool names

**Files (Smana/agent-platform):**
- Modify: `internal/bridge/classify.go`, `internal/bridge/classify_test.go`

- [ ] **Step 1: Worktree.** In `~/Sources/agent-platform`, `EnterWorktree` with branch
`feat/bridge-agentgateway-tools`, then `git reset --hard origin/feat/room-approvals`.

- [ ] **Step 2: Write the failing test.** Append to `internal/bridge/classify_test.go`:

```go
// ADR-0053: agentgateway names federated tools <server>_<tool>, Agent Router
// <server>__<tool>. Both are read-only during the cutover; a harness prefix
// still cannot hide the server, and a bare name never matches.
func TestReadOnlyAcceptsBothGatewayNamings(t *testing.T) {
	for name, want := range map[string]bool{
		"room-broker__room_read":               true,
		"room-broker_room_read":                true,
		"platform__mcp-victorialogs_hits":      true,
		"agent-router__mcp-victorialogs__hits": true,
		"mcp-victoriametrics_query":            true,
		"room_read":                            false,
		"file_editor":                          false,
		"unknown-server_query":                 false,
		"platform__room-broker_room_write":     false,
	} {
		if got := readOnly(name); got != want {
			t.Errorf("readOnly(%q) = %v, want %v", name, got, want)
		}
	}
}
```

Run: `systemd-run --user --scope -q -p MemoryMax=6G -p MemorySwapMax=0 go test ./internal/bridge/ -run TestReadOnlyAcceptsBothGatewayNamings`
Expected: FAIL on the three `<server>_<tool>` names.

- [ ] **Step 3: Implement.** Replace `readOnly` and its comment in `internal/bridge/classify.go`:

```go
// readOnly matches the last <server>__<tool> pair (Agent Router) or, in the last
// segment, <server>_<tool> (agentgateway, ADR-0053), so a prefix the harness adds
// cannot hide the server, and a bare tool name never matches. Server names hold
// no underscore, so the first one ends the server.
func readOnly(tool string) bool {
	p := strings.Split(tool, "__")
	if len(p) >= 2 && readOnlyMCP[p[len(p)-2]+"__"+p[len(p)-1]] {
		return true
	}
	server, name, ok := strings.Cut(p[len(p)-1], "_")
	return ok && readOnlyMCP[server+"__"+name]
}
```

The comment above `readOnlyMCP` becomes `// The MCP tools a run can reach, keyed <server>__<tool> whichever gateway named them:`.

- [ ] **Step 4: Run, commit, pre-release**

Run: `systemd-run --user --scope -q -p MemoryMax=6G -p MemorySwapMax=0 go test ./...`
Expected: `ok` for every package.

```bash
git add internal/bridge/classify.go internal/bridge/classify_test.go
git commit -m "feat(bridge): read agentgateway's <server>_<tool> names as read-only too"
git push -u origin feat/bridge-agentgateway-tools
```

Open AP-AGW1 as a draft on `feat/room-approvals` with the P33 hold line. Copy the room-bridge
pre-release image `tag@digest` from the CI job summary for Task F.2.

### Task F.2: CC-AGW1, the run CNP reaches both gateways

**Files (Smana/crossplane-configuration):**
- Modify: `apis/agentrun/kcl/main.k`, `apis/agentrun/kcl/main_test.k`, `apis/agentrun/kcl/README.md`,
  `tests/golden/agentrun-basic.yaml`, `tests/golden/agentrun-complete.yaml`

- [ ] **Step 1: Worktree.** In `~/Sources/crossplane-configuration`, `EnterWorktree` with branch
`feat/agentrun-agentgateway`, then `git reset --hard origin/chore/room-bridge-v0.4.0`.

- [ ] **Step 2: Write the failing test.** Append to `apis/agentrun/kcl/main_test.k`:

```kcl
# ADR-0053 cutover: a run may reach either agent router until CC-AGW2. Both
# selectors pin their namespace (F1), so a tenant Gateway named agent-router
# elsewhere never matches.
test_run_reaches_both_agent_routers = lambda {
    _spec = _kind(_run({}), "CiliumNetworkPolicy")[0].spec
    _dns = [n.matchName for n in _spec.egress[0].toPorts[0].rules.dns]
    assert "agent-router.envoy-gateway-system.svc.cluster.local" in _dns
    assert "agent-router.agent-gateway.svc.cluster.local" in _dns
    _router = [e for e in _spec.egress if e.toEndpoints and e.toEndpoints[0].matchLabels["gateway.envoyproxy.io/owning-gateway-name"] == "agent-router"][0]
    assert {"io.kubernetes.pod.namespace" = "agent-gateway", "gateway.networking.k8s.io/gateway-name" = "agent-router"} in [s.matchLabels for s in _router.toEndpoints]
    assert [p.port for t in _router.toPorts for p in t.ports] == ["8080", "8082"]
}
```

Run: `task check`
Expected: FAIL on `test_run_reaches_both_agent_routers`.

- [ ] **Step 3: Implement.** In `apis/agentrun/kcl/main.k`, replace `_ROUTER_FQDN = …` with:

```kcl
# Both agent routers during the cutover (ADR-0053): Envoy's until CC-AGW2,
# agentgateway's after. Fully qualified, so ndots:1 sends them to kube-dns as-is
# and the L7 DNS rule answers exactly these names (Q4).
_ROUTER_FQDNS = ["agent-router.envoy-gateway-system.svc.cluster.local", "agent-router.agent-gateway.svc.cluster.local"]
_ROUTER_ENDPOINTS = [
    {"io.kubernetes.pod.namespace" = "envoy-gateway-system", "gateway.envoyproxy.io/owning-gateway-name" = "agent-router", "gateway.envoyproxy.io/owning-gateway-namespace" = "agent-system"}
    {"io.kubernetes.pod.namespace" = "agent-gateway", "gateway.networking.k8s.io/gateway-name" = "agent-router"}
]
```

`_dnsNames = [_ROUTER_FQDN, _TRACES_FQDN] + …` becomes `_dnsNames = _ROUTER_FQDNS + [_TRACES_FQDN] + …`.
In the router egress rule, `toEndpoints = [{matchLabels = {…envoy-gateway-system…}}]` becomes
`toEndpoints = [{matchLabels = l} for l in _ROUTER_ENDPOINTS]` (one line: `kcl fmt` rule), and its
F1 comment gains "Both selectors pin a namespace." `_BRIDGE_IMAGE` becomes AP-AGW1's pre-release
`tag@digest` (Task F.1 Step 4). In `README.md`, the CNP row names both routers.

- [ ] **Step 4: Goldens, check, pre-release**

Run: `task golden:update 2>/dev/null || task render:golden; task check`
(use whichever golden task `task --list` shows). Expected: exit 0; the goldens' diff adds the
second FQDN and selector and the bridge pin, nothing else.

```bash
git add apis/agentrun tests/golden
git commit -m "feat(agentrun): runs reach either agent router during the agentgateway cutover"
git push -u origin feat/agentrun-agentgateway
```

Open CC-AGW1 as a draft on `chore/room-bridge-v0.4.0` (P33 hold line). Copy its pre-release name
from the CI job summary (the synthetic merge commit).

### Task F.3: AGW-6, the identity-proxy switch

**Files:**
- Modify: `infrastructure/base/agent-runtime/identity-proxy-configmap.yaml`,
  `infrastructure/base/crossplane/configuration-aws/configuration-packages.yaml`,
  `infrastructure/base/crossplane/configuration-gcp/configuration-packages.yaml`

- [ ] **Step 1: Worktree.** `EnterWorktree` with branch `feat/agw-cutover`, then
`git reset --hard origin/feat/agw-observability`; merge `origin/main`.

- [ ] **Step 2: Pin CC-AGW1.** Both `configuration-packages.yaml` package tags become CC-AGW1's
pre-release. `apps/platform/app-wizard/app.yaml` stays on its release tag.

Run: `export XRD_CRDS_FILE="$(./scripts/ci/fetch-xrd-crds.sh)" && systemd-run --user --scope -q -p MemoryMax=6G -p MemorySwapMax=0 ./scripts/ci/validate-manifests.sh`
Expected: `Invalid: 0, Skipped: 0`.

```bash
git add infrastructure/base/crossplane/configuration-*/configuration-packages.yaml
git commit -m "chore(crossplane): pin CC-AGW1, runs may reach either agent router"
```

- [ ] **Step 3: The failing check**

Run: `grep -c 'agent-router.agent-gateway.svc.cluster.local' infrastructure/base/agent-runtime/identity-proxy-configmap.yaml`
Expected: `0`.

- [ ] **Step 4: Switch.** In `identity-proxy-configmap.yaml`, the three `socket_address` lines become
`{address: agent-router.agent-gateway.svc.cluster.local, port_value: 8080|8081|8082}`, and the header
comment's three arrows read `agent-router (agentgateway) public :8080` etc. Add to the header:

```yaml
# Upstream: agentgateway's agent-router (ADR-0053). A sandbox reads this file at
# start, so a change reaches new runs only; reverting this commit is the
# rollback, and the run CNP admits both gateways until CC-AGW2.
```

Run: Step 3's grep → `3`; `grep -c 'envoy-gateway-system' infrastructure/base/agent-runtime/identity-proxy-configmap.yaml` → `0`.

- [ ] **Step 5: Commit, gates, draft**

```bash
git add infrastructure/base/agent-runtime/identity-proxy-configmap.yaml
git commit -m "feat(agent-runtime): new runs reach the agent router on agentgateway"
```

Task A.4 Step 1's gates. AGW-6 as a draft on `feat/agw-observability`, title
`feat(agents): switch new runs to the agentgateway agent router (ADR-0053 phase F)`, with the cutover
mermaid diagram from the design, the rollback command (`git revert <switch sha>` on integration), the
three linked PRs (AP-AGW1, CC-AGW1), and the P33 hold line.

---

## Phase G — live gates on gcp-0

Runs on `integration/agent-factory` with AGW-1…AGW-6 merged and CC-AGW1's pre-release patched into
the core package. Every probe torn down in the same task. Evidence goes into AGW-6's "Live evidence".

### Task G.1: [LIVE] Deploy and platform checks

- [ ] **Step 1:** Merge AGW-6 into integration; patch the core package to CC-AGW1's pre-release.
- [ ] **Step 2:** One call each, all Ready: `agentgateway`, `agent-gateway`, `agent-router`, `agent-mcp`,
`agent-runtime`, `octo-sts`, `agent-observability`.
- [ ] **Step 3:** `kubectl get configmap -n agents agent-identity-proxy -o yaml | grep -c agent-gateway.svc` → `3`.
- [ ] **Step 4:** `kubectl get gatewayclass` → `agentgateway`, `envoy-ai-gateway`, `cilium` all `ACCEPTED True`.

### Task G.2: [LIVE] P1–P8 on the real gateway

Re-run the PoC's eight assertions with the real audiences, from the `agent-probe` sandbox (it carries
`agents.ogenki.io/run-id: probe000`). P1's wrong-namespace leg cannot be replayed with real audiences
without weakening the cluster: Kyverno refuses to mint `agent-router.*` outside `agents`
(`kubectl create token default -n default --audience agent-router.implementer.public` → denied). Record
that refusal as the first layer; the gateway's own 403 stands on the PoC's live proof of the same
expression and on AG2.

| # | Expected |
|---|---|
| P1 | `.public` → 200 on `:8080`; `.internal` → 401 there; another namespace → Kyverno refuses the token (and 403 per the PoC) |
| P2 | forged `x-ar-agent`/`x-ar-human` never reach the backend; `gen_ai_client_token_usage_sum{ar_agent}` = the probe's sub |
| P3 | a streamed completion of `max_tokens` 12000 lasting > 60 s ends `200` |
| P4 | per role, the tool lists of Task C.5; `room-broker` sees `x-room-mcp-key` (room-broker logs), no MCP server sees `Authorization` |
| P5 | Task G.3's real OpenHands session survives a proxy pod deletion |
| P6 | Task D.3's counters on the KVStore |
| P7 | Task E.4's span |
| P8 | `/v1/models` no token → 401 |

### Task G.3: [LIVE] Parity with real runs

- [ ] **Step 1: Real runs.** Start, through `task agent:run`, one run per role on `public` and one
room run (implementer → reviewer handoff). During the implementer run,
`kubectl delete pod -n agent-gateway <one proxy>` once mid-session (P5). No `internal` run: Envoy's
`internal` listener has no model route, so one is not a parity item; PC2 proves the `internal`
surface by probe, and the first real `internal` run is I.6 Step 3 (design, "Exit criterion for H").

| # | Check | Expected |
|---|---|---|
| PC1 | `log.x_ar_agent:"system:serviceaccount:agents:xplane-run-<id>"` in agentgateway proxy logs; none in Envoy's for that run | present / absent |
| PC2 | from the probe with an `agent-router.reviewer.internal` token: `tools/list` on `:8081/mcp` equals `agent-mcp-internal`'s reviewer set; `POST :8080` with the same token → `401` | exact set; `401` |
| PC3 | implementer opens a PR: `octo-sts` logs a successful exchange for the run's sub; the run's `git push` succeeds | success |
| PC4 | the room run's `room-broker_room_handoff` and the reviewer's `room-broker_room_verdict` land in the room log | both events |
| PC6 | `ratelimit_service_rate_limit_total_hits{key1="agent"}` rose by the runs' token totals | ≈ `gen_ai_client_token_usage_sum` increase |
| PC8 | the run and fleet dashboards show tokens, cost, latency, error rate and gateway log lines for the implementer run ([OWNER] one look: Grafana is SSO-gated) | non-empty |
| PC9 | the run's trace holds agentgateway spans under the harness root | present |
| PC11 | the room run's `room_read` produced no approval request in the room log | none |

### Task G.4: [LIVE] Drain experiment and rollback drill

- [ ] **Step 1: PC7 at 120/660.** From the probe, a 200 s stream; meanwhile
`kubectl rollout restart deploy -n agent-gateway agent-router`. Expected: `200`, and `total_hits`
rises by the stream's exact `total_tokens` (N2).
- [ ] **Step 2: `max` alone (R8).** On integration only, set `shutdown.min: 10` in `parameters.yaml`
(commit `test(agent-gateway): drain experiment, min 10`), wait for the rollout, repeat Step 1 twice.
Record the outcome; revert the commit. Phase H applies `min: 10` only if both runs passed.
- [ ] **Step 3: PC10 / SC-10, the rollback drill.** `git revert` the identity-proxy switch on integration, wait
for `agent-runtime` Ready, start one run: its calls appear in Envoy's logs. Revert the revert and
start one more: agentgateway again.

### Task G.5: Evidence and the exit criterion

- [ ] **Step 1:** Fill AGW-6's "Live evidence" with every table above (commands and outputs).
- [ ] **Step 2:** Count real runs since the switch with no gateway-attributable failure (from the
fleet dashboard and the runs' `status.reason`). Phase H needs ≥ 10, at least one per role and one
room run, plus PC2's probe evidence for `internal`.
- [ ] **Step 3: [OWNER]** The owner reads the evidence and says go for phase H.

---

## Phase H — removal of the Envoy agent-router

### Task H.1: CC-AGW2, agentgateway only

**Files (crossplane-configuration):** `apis/agentrun/kcl/main.k`, `main_test.k`, `README.md`, goldens.

- [ ] **Step 1:** `EnterWorktree` `feat/agentrun-agentgateway-only`, `git reset --hard origin/feat/agentrun-agentgateway`.
- [ ] **Step 2: Failing test.** Replace `test_run_reaches_both_agent_routers` with:

```kcl
test_run_reaches_only_the_agentgateway_router = lambda {
    _spec = _kind(_run({}), "CiliumNetworkPolicy")[0].spec
    _dns = [n.matchName for n in _spec.egress[0].toPorts[0].rules.dns]
    assert "agent-router.agent-gateway.svc.cluster.local" in _dns
    assert "agent-router.envoy-gateway-system.svc.cluster.local" not in _dns
    _router = [e for e in _spec.egress if e.toEndpoints and e.toEndpoints[0].matchLabels["gateway.networking.k8s.io/gateway-name"] == "agent-router"][0]
    assert [s.matchLabels for s in _router.toEndpoints] == [{"io.kubernetes.pod.namespace" = "agent-gateway", "gateway.networking.k8s.io/gateway-name" = "agent-router"}]
}
```

and update the three existing tests that read `matchLabels["gateway.envoyproxy.io/owning-gateway-name"]`
or `["io.kubernetes.pod.namespace"] == "envoy-gateway-system"` (`test_public_run_reaches_only_the_public_listener`,
`test_cnp_is_default_deny_with_named_egress`) to the agentgateway labels, keeping their assertions.
`task check` → FAIL.
- [ ] **Step 3:** `_ROUTER_FQDNS` and `_ROUTER_ENDPOINTS` keep only the agentgateway entries. Goldens,
`task check` → exit 0. Commit `feat(agentrun): runs reach only the agentgateway agent router`, push,
draft on `feat/agentrun-agentgateway`, copy the pre-release.

### Task H.2: AGW-7, delete the Envoy agent-router

**Files:**
- Delete: `infrastructure/base/agent-router/{envoyproxy,gateway,clienttrafficpolicy,securitypolicy-public,securitypolicy-internal,securitypolicy-sts,backend-zai,aigatewayroute-agent-models,httproute-agent-models-list,httproutefilter-agent-models-list,network-policy-data-plane}.yaml`,
  `infrastructure/base/agent-mcp/mcproutes.yaml`, the EnvoyProxy grant in `observability/base/agent-platform/referencegrant-agent-traces.yaml`
- Modify: `infrastructure/base/agent-router/kustomization.yaml`, `infrastructure/base/agent-mcp/kustomization.yaml`,
  the five server CNPs and `security/base/octo-sts/httproute.yaml` (drop the Envoy peer/parent),
  `agent-traces-collector.yaml` (drop the Envoy :4317 peer), `scripts/ops/k8s/agent-probe{.yaml,-mcp.sh}`,
  `observability/base/agent-platform/{vmrule-logs.yaml,grafana-dashboard-agent-run.yaml}`,
  `clusters/{aws-0,gcp-0}-agent-platform/infrastructure-agent-router.yaml` (`dependsOn` drops `envoy-ai-gateway`, the Gateway health check goes: Step 3),
  `clusters/{aws-0,gcp-0}/agent-platform.yaml` (the comment above `dependsOn: ai-gateway`: Step 3),
  `scripts/ci/flux-schema/assert-ai-gateway.py`, its test, `scripts/ci/validate-manifests.sh` (Gate 3's label),
  `scripts/ci/tests/{test-agent-mcp-scope.sh,test-agent-observability.py}`,
  `infrastructure/base/crossplane/configuration-{aws,gcp}/configuration-packages.yaml` (CC-AGW2),
  `infrastructure/base/agent-gateway/parameters.yaml` (`min: 10` only if G.4 Step 2 passed)

- [ ] **Step 1: The failing check**

Run: `export XRD_CRDS_FILE="$(./scripts/ci/fetch-xrd-crds.sh)" && systemd-run --user --scope -q -p MemoryMax=6G -p MemorySwapMax=0 ./scripts/ci/validate-manifests.sh >/dev/null && grep -lE 'owning-gateway-name: agent-router|kind: MCPRoute' .bundle/*.yaml | wc -l`
Expected: a positive count.

- [ ] **Step 2: Retire A5–A7.** In `assert-ai-gateway.py`, delete `check_agent_router_*` (A5), the
MCPRoute check (A6) and the `/v1/models` guard check (A7) with their docstring entries, and their
tests in `test-assert-ai-gateway.py`; A1–A4 stay for `ai-gateway`. Gate 3's echo line becomes
`AI gateway invariants (budget rules, identity-header strip, merge type)`. The scope test drops its
MCPRoute half (R7); `test-agent-observability.py` drops the Envoy :4317 peer and the EnvoyProxy grant.
- [ ] **Step 3: Delete and edit** the files listed above. The `agent-router` child keeps its name and
path (it now holds `agentgateway-llm.yaml` and `externalsecret-zai.yaml`); replace its Gateway
health check with `dependsOn: [agent-gateway, agent-secrets]` only. The probe's host default becomes
`agent-router.agent-gateway.svc.cluster.local`. `vmrule-logs.yaml` drops `AgentRouterUnauthorizedBurst`
(E.2's metric alert replaces it). The run page drops the Envoy halves of its OR selectors and target A.
Pin CC-AGW2. In `clusters/gcp-0/agent-platform.yaml:22-23` and `clusters/aws-0/agent-platform.yaml:28-29`,
the comment "Agents run on frontier models through the ai-gateway controllers" becomes false once the
Envoy router is gone; replace it with `# Kept for the Semantic Router (C7, soft) pending the H.5 audit;
zero GPUs: never llm-platform (C1).` The `dependsOn` itself stays.
- [ ] **Step 4: Docs.** Update, on the restructured AI Platform section (on `main` first):
  - `website/content/docs/platform/ai-platform/gateways.md`: the agent gateway half describes
    agentgateway (listeners, identity, MCP tool names, budgets, the rate-limit server), with a
    mermaid diagram from the design's topology; link ADR-0053;
  - `website/content/docs/platform/ai-platform/agents/` (runtime and user-guide pages): the
    identity-proxy upstream, the `<target>_<tool>` names, the `Unknown tool` denial (N6);
  - `website/content/docs/platform/ai-platform/observability.md`: the relabel contract, the new
    alerts, the LogsQL selector;
  - `website/content/docs/platform/ai-platform/status.md`: agent router on agentgateway, built and verified;
  - runbooks `docs/runbooks/agent-factory/02-identity-tokens.md`, `04-gateway-secrets-budgets.md`,
    `06-mcp.md` (expected tool names become `flux-operator-mcp_search_flux_docs` etc.), `08-observability.md`;
  - ADR-0042 and ADR-0050 Implementation Notes: one dated line each pointing to the agentgateway files.
  Run `./scripts/ci/verify-doc-paths.sh` after `git add`.
- [ ] **Step 5: Verify**

Run: Step 1's command.
Expected: `0`; `assert-agent-gateway: 9 checks, 0 violations`; `Invalid: 0, Skipped: 0`. Then the
remaining gates (Task A.4 Step 1 plus `validate-vmrules.sh`, `validate-doc-claims.sh`).
- [ ] **Step 6: Commit** in three commits: `refactor(agent-router)!: delete the Envoy agent-router`,
`ci(flux-schema): retire A5-A7 with the Envoy agent-router`, `docs(agents): the agent router on agentgateway`.

### Task H.3: AGW-7 as a draft

- [ ] Draft on `feat/agw-cutover`, title `refactor(agents): remove the Envoy agent-router (ADR-0053 phase H)`,
with the before/after mermaid diagram, CC-AGW2's link, the P33 hold line.

### Task H.4: [LIVE] SC-11

- [ ] Merge AGW-7 into integration; patch the core package to CC-AGW2's pre-release. Then:
`kubectl get gateway -n agent-system` → none of class `envoy-ai-gateway`;
`kubectl get mcproute -A` → none; `kubectl get pods -n envoy-gateway-system -l gateway.envoyproxy.io/owning-gateway-name=agent-router` → none;
`kubectl get gateway -n envoy-ai-gateway-system ai-gateway` still `PROGRAMMED True` (ai-gateway untouched);
one real run end to end → `Succeeded`. Paste into AGW-7.

### Task H.5: `dependsOn: ai-gateway` audit

`clusters/{aws-0,gcp-0}/agent-platform.yaml` depend on the `ai-gateway` umbrella because the Envoy
agent-router needed Envoy Gateway and Envoy AI Gateway. After H that reason is gone (agentgateway,
its KVStore and the Gateway API CRDs come from elsewhere), but the Semantic Router stays a **soft**
runtime dependency: SP4's `complexity-classifier`, deployed by `agent-platform`, calls SR
`/api/v1/eval` and falls back to `static` behind a circuit breaker. This is an audit, not a removal.
Informational; it gates nothing.

- [ ] **Step 1: Render with phase H applied.** On AGW-7's head:
`systemd-run --user --scope -q -p MemoryMax=6G -p MemorySwapMax=0 python3 scripts/ci/flux-schema/render-bundle.py .bundle`.
- [ ] **Step 2: The agent-platform tree has no Envoy kind left**

```bash
files=$(for p in $(yq -N '.spec.path' clusters/gcp-0-agent-platform/*.yaml | grep -v '^null$' | sed 's|^\./||'); do
  s=${p//\//-}; ls .bundle/overlay-"$s".yaml .bundle/chart-"$s"-*.yaml 2>/dev/null; done)
cat $files | grep -cE 'apiVersion: (gateway|aigateway)\.envoyproxy\.io'
```

Expected: `0` (it is `12` before H, on the migration branch's render of 2026-10-02).
- [ ] **Step 3: Every remaining reference, with its reason.**
`grep -nE 'envoy-gateway-system|envoy-ai-gateway-system|semantic-router' $files`. List each hit and
why it stays (a CNP peer for SR is expected; an Envoy namespace is not).
- [ ] **Step 4: Verdict in AGW-7's body.** Keep, or remove. Removal, if warranted, is a separate PR
with a live test under a suspended `ai-gateway`: the agent-platform tree reaches Ready, and C7 falls
back to `static`.

---

## Phase I — AGW-8: Anthropic API backend for the internal listener, and budgets

Provable on gcp-0 at once: the providers are the same on both clouds (ADR-0054). Needs the owner
prerequisite [P1](#owner-prerequisites) before Task I.2's live step.

SP4 PR 2 (`2026-09-25-llm-frontier-backends-plan.md`, Tasks 9–15) splits:

| SP4 task | Fate |
|---|---|
| 9 gate A4–A5 (agent pinning, Z.ai public-only) | **Here**: AG5 already enforces Z.ai public-only and gains Anthropic internal-only and OpenRouter public-only (I.1); agent pinning is I.1's check |
| 10 Bedrock EPIs | **Optional**: both EPIs move to the [appendix](#appendix--optional-backends-off-by-default) (OB.2) |
| 11 `claude-*` on `ai-gateway` | **SP4**, re-targeted to the Anthropic API with a platform key (ADR-0054); not in this plan |
| 12 agent tiers on `agent-router` | **Here** (I.2 public, I.3 internal) |
| 13 B1–B2, run-token rule, budget alerts | B1–B2 **done in phase D**; per-provider B6 here (I.4); rule and alerts here (I.5) |
| 14 `oidc` listener on `ai-gateway`, `/anthropic` | **SP4, unchanged** |
| 15 live verification | Agent half here (I.6, gcp-0); `ai-gateway` half in SP4 |

### Task I.1: The gate pins each provider to its listener, and names to one backend

**Files:**
- Modify: `scripts/ci/flux-schema/assert-agent-gateway.py`, `scripts/ci/tests/flux-schema/test-assert-agent-gateway.py`

**Interfaces:**
- Produces: `PROVIDER_LISTENERS = {"zai": {"public"}, "openrouter": {"public"}, "anthropic": {"internal"}}`
  used by `check_routes`; AG5 messages `… reaches <backend> from [...]; it is <listeners>-only`.

- [ ] **Step 1: Write the failing tests.** Append to the test file, before `print("main")`:

```python
print("AG5 providers per listener (ADR-0054)")


def add_backend_route(o, backend, section, spec):
    o.append(obj("AgentgatewayBackend", "agent-system", backend, spec))
    o.append(route(f"{backend}-route", section, backend))


expect("anthropic on public fails", lambda o: add_backend_route(
    o, "anthropic", "public", {"ai": {"provider": {"anthropic": {}}}}), "AG5")
expect("openrouter on internal fails", lambda o: add_backend_route(
    o, "openrouter", "internal", {"ai": {"provider": {"openai": {}}, "host": "openrouter.ai"}}), "AG5")
expect("a weighted agent route fails", lambda o: find(o, "HTTPRoute", "agent-models")["spec"]["rules"][0]
       ["backendRefs"].append({"group": "agentgateway.dev", "kind": "AgentgatewayBackend", "name": "zai", "weight": 10}), "AG5")
v = violations_after(lambda o: add_backend_route(o, "anthropic", "internal", {"ai": {"provider": {"anthropic": {}}}})
                     or o.append(route("anthropic-list", "internal", None, {"type": "Exact", "value": "/v1/models"}))
                     or o.append(obj("AgentgatewayPolicy", "agent-system", "anthropic-list", {
                         "targetRefs": [{"group": "gateway.networking.k8s.io", "kind": "HTTPRoute", "name": "anthropic-list"}],
                         "traffic": {"directResponse": {"status": 404}}})))
check("anthropic on internal with its /v1/models answer passes", v == [], f"got {v}")
```

Run: `python3 scripts/ci/tests/flux-schema/test-assert-agent-gateway.py`
Expected: FAIL on the first three.

- [ ] **Step 2: Implement.** In `assert-agent-gateway.py`, add after `ROUTE_KINDS`:

```python
# ADR-0054: which listener each provider may serve. Anthropic is internal-only so
# B6 can be scoped to that listener; Z.ai and OpenRouter never see internal data.
PROVIDER_LISTENERS = {"zai": {"public"}, "openrouter": {"public"}, "anthropic": {"internal"}}
```

In `check_routes`, replace the `names_zai` block with:

```python
        for rule in spec_of(r).get("rules") or []:
            refs = [b for b in rule.get("backendRefs") or [] if b.get("kind") == "AgentgatewayBackend"]
            for b in refs:
                allowed = PROVIDER_LISTENERS.get(b.get("name"))
                if allowed and not route_listeners(r) <= allowed:
                    out.append(f"AG5: {ref(r)} reaches {b.get('name')} from {sorted(route_listeners(r))}; "
                               f"it is {'/'.join(sorted(allowed))}-only")
            if len(refs) > 1 or any(b.get("weight") not in (None, 100) for b in refs):
                out.append(f"AG5: {ref(r)} splits traffic; agent names map 100 % to one backend")
```

and update the AG5 docstring line to "the zai and openrouter backends are public-only, anthropic
internal-only, and no agent route splits traffic".

- [ ] **Step 3: Run, commit**

Run: `python3 scripts/ci/tests/flux-schema/test-assert-agent-gateway.py`
Expected: every check `ok`, `all passed` (35 checks; verified 2026-10-01 against this code in a
scratch tree).

```bash
git add scripts/ci/flux-schema/assert-agent-gateway.py scripts/ci/tests/flux-schema/test-assert-agent-gateway.py
git commit -m "ci(flux-schema): pin each model provider to its listener (ADR-0054)"
```

### Task I.2: The Anthropic backend on `internal`

**Files:**
- Create: `infrastructure/base/agent-router/externalsecret-anthropic.yaml`, `infrastructure/base/agent-router/agentgateway-anthropic.yaml`
- Modify: `infrastructure/base/agent-router/kustomization.yaml`, `infrastructure/base/agent-gateway/network-policy.yaml`

**Interfaces:**
- Consumes: OpenBao `agents` mount, secret `anthropic`, field `api_key` (owner prerequisite P1); SecretStore `agents-secrets` in `agent-system`.
- Produces: Secret `agents-anthropic-api-key` (key `apiKey`); `AgentgatewayBackend agent-system/anthropic`; <!-- pragma: allowlist secret -->
  `HTTPRoute agent-models-internal` and `agent-models-list-internal` on `internal`.

- [ ] **Step 1: The failing check**

Run: `kustomize build infrastructure/gcp-0/agent-router | grep -c 'name: anthropic$'`
Expected: `0`.

- [ ] **Step 2: Write `externalsecret-anthropic.yaml`:**

```yaml
---
# The agents' Anthropic key (ADR-0054): internal data goes to the Anthropic API
# directly. Same store and mount as the Z.ai key; never the platform's key.
# The gateway injects it; no run ever holds it.
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: agents-anthropic-api-key
  namespace: agent-system
spec:
  refreshInterval: 1h
  secretStoreRef:
    kind: SecretStore
    name: agents-secrets
  target:
    name: agents-anthropic-api-key
    creationPolicy: Owner
    deletionPolicy: Retain
  data:
    - secretKey: apiKey  # pragma: allowlist secret
      remoteRef:
        key: anthropic
        property: api_key  # pragma: allowlist secret
```

- [ ] **Step 3: Write `agentgateway-anthropic.yaml`** (the model map; I.3 extends it):

```yaml
# internal → the Anthropic API (ADR-0054), the same on both clouds. Native
# provider: AgentgatewayBackend.spec.ai.provider.anthropic (agentgateway v1.5.0).
# The key goes in x-api-key: agentgateway's default location is
# Authorization: Bearer, which Anthropic API keys do not use.
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayBackend
metadata:
  name: anthropic
  namespace: agent-system
spec:
  ai:
    provider:
      anthropic:
        model: claude-opus-5-5
  policies:
    auth:
      secretRef:
        name: agents-anthropic-api-key
        key: apiKey
      location:
        header:
          name: x-api-key
---
# `internal` only (gate AG5): Anthropic is internal's provider, and B6 counts
# it by listener.
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: agent-models-internal
  namespace: agent-system
spec:
  parentRefs:
    - group: gateway.networking.k8s.io
      kind: Gateway
      name: agent-router
      namespace: agent-gateway
      sectionName: internal
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /v1
        - path:
            type: PathPrefix
            value: /anthropic
      backendRefs:
        - group: agentgateway.dev
          kind: AgentgatewayBackend
          name: anthropic
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: agent-models-list-internal
  namespace: agent-system
spec:
  parentRefs:
    - group: gateway.networking.k8s.io
      kind: Gateway
      name: agent-router
      namespace: agent-gateway
      sectionName: internal
  rules:
    - matches:
        - path:
            type: Exact
            value: /v1/models
---
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayPolicy
metadata:
  name: agent-models-list-internal
  namespace: agent-system
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: HTTPRoute
      name: agent-models-list-internal
  traffic:
    directResponse:
      status: 404
      body: '{"error":"model listing is not served on agent-router"}'
```

If the provider rejects an explicit `location` (an `Invalid` from `flux schema validate`, or a 401
`authentication_error` in Step 6), remove `location` and record that the anthropic provider maps
the key to `x-api-key` itself.

Add both files to `infrastructure/base/agent-router/kustomization.yaml`. Append to the data plane's
egress in `infrastructure/base/agent-gateway/network-policy.yaml`:

```yaml
    - toFQDNs:
        - matchName: api.anthropic.com
      toPorts:
        - ports:
            - port: "443"
              protocol: TCP
```

- [ ] **Step 4: Gate**

Run: `mkdir -p /tmp/claude-agwi && kustomize build infrastructure/gcp-0/agent-gateway > /tmp/claude-agwi/a.yaml && kustomize build infrastructure/gcp-0/agent-router > /tmp/claude-agwi/b.yaml && python3 scripts/ci/flux-schema/assert-agent-gateway.py /tmp/claude-agwi; rm -rf /tmp/claude-agwi`
Expected: `0 violations` (AG5 and AG7 both satisfied on `internal`).

- [ ] **Step 5: Commit**

```bash
git add infrastructure/base/agent-router infrastructure/base/agent-gateway/network-policy.yaml
git commit -m "feat(agent-router): internal runs reach the Anthropic API directly (ADR-0054)"
```

- [ ] **Step 6: [LIVE] SC-12 on gcp-0.** Owner prerequisite P1 done. Merge into integration; wait for
`agent-router` Ready and `kubectl get externalsecret -n agent-system agents-anthropic-api-key` `SecretSynced`.
From the probe with its `internal` token: `POST http://agent-router.agent-gateway.svc.cluster.local:8081/v1/chat/completions`
model `agent-default` → `200`; `gen_ai_client_token_usage_sum{namespace="agent-gateway", gen_ai_request_model="claude-opus-5-5"}`
rises; `hubble observe --from-pod agent-gateway/<proxy> --to-fqdn api.anthropic.com` shows the flow
and `--to-fqdn api.z.ai` none for it; `kubectl get secret -n agents -o name | grep -ci anthropic` → `0`.

### Task I.3: Tiers on both listeners

**Files:** Modify `infrastructure/base/agent-router/agentgateway-llm.yaml`, `infrastructure/base/agent-router/agentgateway-anthropic.yaml`.

- [ ] **Step 1: Spike, how names route (D8).** On integration only, add an `AgentgatewayModel`
`agent-default` in `agent-system` (`parentRefs` the `public` listener, `match.model: agent-default`,
openai provider at `zai`'s host, model `glm-5.3`) and probe: `agent-default` → `200` from `glm-5.3`;
`gpt-4o` → refused with no `api.z.ai` client span; `/v1/models` still `404`. If all three hold,
names use one `AgentgatewayModel` each; otherwise one backend per provider model and an HTTPRoute
header match per name. Record the ruling in AGW-8's body; revert the spike.

- [ ] **Step 2: The map**, in Step 1's shape. Before writing, confirm the two Z.ai Flash API IDs
against Z.ai's model list (SP4 marks them UNVERIFIED) and use what it says.

| Name | `public` (Z.ai) | `internal` (Anthropic) |
|---|---|---|
| `tier-light` | `glm-5.3-flash` | `claude-haiku-4-5` |
| `tier-standard` | `glm-5.3-flashx` | `claude-sonnet-5-5` |
| `tier-frontier` | `glm-5.2` | `claude-opus-5-5` |
| `agent-default` | `glm-5.2` | `claude-opus-5-5` |

- [ ] **Step 3: Gate, commit.** Task I.2 Step 4's command → `0 violations`. Commit
`feat(agent-router): agent tiers on both listeners (SP4 PR 2 on agentgateway)`.

### Task I.4: B6, the Anthropic fleet budget

**Files:** Create `infrastructure/base/agent-gateway/policy-budgets-providers.yaml`; modify
`infrastructure/base/agent-gateway/ratelimit.yaml` (ConfigMap), `infrastructure/base/agent-gateway/kustomization.yaml`.

- [ ] **Step 1: The failing check**

Run: `kustomize build infrastructure/gcp-0/agent-gateway | grep -c 'key: provider'`
Expected: `0`.

- [ ] **Step 2: Implement.** Append to the ConfigMap's descriptors:

```yaml
      # B6: Anthropic tokens, all runs (ADR-0054). Opus costs ~3-5x GLM per
      # token, so the shared B2 bucket alone would let internal spend run hot.
      - key: provider
        value: anthropic
        rate_limit:
          unit: day
          requests_per_unit: 10000000
        shadow_mode: true
```

Create `policy-budgets-providers.yaml`:

```yaml
# Per-provider budgets (ADR-0054). Scoped to the internal listener because
# Anthropic is its only provider (gate AG5 pins it there).
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayPolicy
metadata:
  name: token-budgets-anthropic
  namespace: agent-gateway
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: Gateway
      name: agent-router
      sectionName: internal
  traffic:
    rateLimit:
      global:
        backendRef:
          name: agent-ratelimit
          port: 8081
        domain: agent-router
        failureMode: FailOpen
        descriptors:
          - entries:
              - name: provider
                expression: '"anthropic"'
            unit: Tokens
```

Add it to the kustomization. Gate: `0 violations` (AG8 sees a shadowed `provider` descriptor).

- [ ] **Step 3: Commit** `feat(agent-gateway): an Anthropic fleet budget, in shadow`.

- [ ] **Step 4: [LIVE] SC-13 and the merge question.** After two `internal` probe completions:
`ratelimit_service_rate_limit_total_hits{domain="agent-router",key1="provider"}` and `{key1="agent"}`
**both** rise by the calls' exact token totals. If `key1="agent"` does not rise, the listener policy
replaced the Gateway-level one: move the `provider` descriptor into `token-budgets` with a CEL value
that is `"anthropic"` only for internal requests (find the listener/backend variable in
agentgateway's CEL reference for v1.5.0), delete `policy-budgets-providers.yaml`, extend AG8's
allowed entries to exactly that expression, and re-run this step.

### Task I.5: Run-token rule and budget alerts

- [ ] Port SP4 Task 13's `vmrule-agent-budgets.yaml` (recording rule
`agent_router:run_tokens:total{principal="agent:<runId>"}`, alerts `AgentRunNearCeiling`,
`FleetBudgetNearCap`) into `infrastructure/base/agent-model-routing/` unchanged: the relabel keeps
`gen_ai_client_token_usage_sum{ar_agent}` (D5). Add `AnthropicFleetNearCap`:

```yaml
        - alert: AnthropicFleetNearCap
          expr: sum(increase(gen_ai_client_token_usage_sum{namespace="agent-gateway", gen_ai_request_model=~"claude-.*", gen_ai_token_type=~"input|output"}[24h])) > 8e6
          for: 10m
          labels:
            severity: warning
          annotations:
            summary: "Agents spent more than 80 % of B6 (10M Anthropic tokens) in 24h"
            description: "B6 is in shadow until SP4 PR 7: nothing is refused yet. Find the noisiest run on the fleet dashboard and revoke it if needed."
            runbook_url: "https://github.com/Smana/cloud-native-ref/blob/integration/agent-factory/docs/runbooks/agent-factory/04-gateway-secrets-budgets.md"
            dashboard: "https://grafana.${private_domain_name}/d/agent-fleet"
```

Add `llm_gateway:price_usd_per_mtoken` rows for the three Claude IDs (input/output: Opus 5.5 4.00/20.00,
Sonnet 5.5 2.00/10.00, Haiku 4.5 1.00/5.00 USD per MTok, Anthropic list prices on 2026-10-01) in the same
file, so the run page's cost panel covers internal runs. `./scripts/ci/validate-vmrules.sh` → exit 0.
Commit `feat(observability): agent budget alerts and Claude prices`.

### Task I.6: SP4 cross-edit, gates, AGW-8, live, key rotation drill

- [ ] **Step 1:** In `docs/superpowers/plans/2026-09-25-llm-frontier-backends-plan.md`, under
`## PR 2 — …`, add: "2026-10-01: the agent half (Tasks 9, 12, 13, 15's agent checks) moved to
`2026-10-01-agent-router-agentgateway-plan.md` phase I, on agentgateway, with internal on the Anthropic
API (ADR-0053, ADR-0054). Task 10's EPIs are optional (that plan's appendix). Task 11 targets the
Anthropic API with a platform key. Task 14 is unchanged."
- [ ] **Step 2:** Every gate; AGW-8 as a draft on `feat/agw-remove-envoy-router`, P33 hold line.
- [ ] **Step 3: [LIVE] gcp-0.** Each tier name on each listener answers from its mapped model
(`gen_ai_request_model`); an unknown name is refused (I.3's shape); a real `internal` reviewer run
completes on Claude; B1, B2 and B6 count it. This is the programme's **first real `internal` run**
(moved here from G.3: no gateway had an `internal` model route before I.2).
- [ ] **Step 4: [LIVE] rotation drill.** [OWNER] writes a new key with prerequisite P1's command;
`kubectl annotate externalsecret -n agent-system agents-anthropic-api-key force-sync=$(date +%s) --overwrite`;
the next `internal` call → `200`; the owner revokes the old key in the Anthropic console.

---

## Phase J — AGW-9: prompt caching and cache-aware accounting

Design: [Prompt caching](../specs/2026-10-01-agent-router-agentgateway-design.md#prompt-caching),
rulings D9–D13. It follows phase I because it amends what phase I lands: the Anthropic backend (I.2),
B6 (I.4) and the run-token rule (I.5). Gate: AG8 and AG10 green; on gcp-0 an `internal` probe reads
from cache with no provider-specific field in its request, budgets and the run meter count reference
tokens, and the run page shows the cache-hit ratio.

REF and `BILLABLE_COST` are the Global Constraints' values. Prices below were read on 2026-10-04 from
[Z.ai pricing](https://docs.z.ai/guides/overview/pricing) and
[Anthropic pricing](https://platform.claude.com/docs/en/about-claude/pricing); re-read both on the day.

### Task J.1: The price table and gate AG10

**Files:**
- Create: `infrastructure/base/agent-gateway/model-prices.yaml`
- Modify: `infrastructure/base/agent-gateway/parameters.yaml`, `infrastructure/base/agent-gateway/kustomization.yaml`,
  `scripts/ci/flux-schema/assert-agent-gateway.py`, `scripts/ci/tests/flux-schema/test-assert-agent-gateway.py`, `scripts/AGENTS.md`

**Interfaces:**
- Produces: ConfigMap `agent-gateway/agent-model-prices` (key `catalog.json`); `CATALOG_PROVIDER`,
  `model_catalog`, `check_prices` (AG10) in the gate, reused by Task J.3.

- [ ] **Step 1: Worktree.** `EnterWorktree` with branch `feat/agw-prompt-caching`, then
`git reset --hard origin/feat/agent-frontier-tiers`; merge `origin/main` in.

- [ ] **Step 2: Write the failing tests.** In `test-assert-agent-gateway.py`, add `import json` to the
imports. In `compliant()`, the `AgentgatewayParameters` spec gains
`"modelCatalog": {"sources": [{"configMap": {"name": "agent-model-prices", "key": "catalog.json"}}]}`,
and the list gains:

```python
        {"apiVersion": "v1", "kind": "ConfigMap", "metadata": {"namespace": "agent-gateway", "name": "agent-model-prices"},
         "data": {"catalog.json": json.dumps({"providers": {"openai": {"models": {
             "glm-5.3": {"rates": {"input": "1.40", "output": "4.40", "cacheRead": "0.26"}}}}}})}},
```

Before `print("main")`, add:

```python
print("AG10 price table (design D10)")
expect("a pinned model without a price row fails", lambda o: find(o, "AgentgatewayBackend", "zai")["spec"]["ai"]
       ["provider"]["openai"].update({"model": "glm-9"}), "AG10")
expect("a row without cacheRead fails", lambda o: find(o, "ConfigMap", "agent-model-prices")["data"].update(
    {"catalog.json": json.dumps({"providers": {"openai": {"models": {
        "glm-5.3": {"rates": {"input": "1.40", "output": "4.40"}}}}}})}), "AG10")
expect("no modelCatalog on the parameters fails", lambda o: find(o, "AgentgatewayParameters", "agent-router")["spec"]
       .pop("modelCatalog"), "AG10")
v = violations_after(lambda o: find(o, "AgentgatewayBackend", "zai")["spec"]["ai"]["provider"].update({"openai": {}}))
check("an unpinned backend is not priced at build time", not any(x.startswith("AG10") for x in v), f"got {v}")
```

Run: `python3 scripts/ci/tests/flux-schema/test-assert-agent-gateway.py`
Expected: FAIL on the first three (no AG10 yet).

- [ ] **Step 3: The gate.** In `assert-agent-gateway.py`, add `import json`; add to the docstring after
AG9: `AG10 Every model an agent backend pins has input, output and cacheRead rates (and cacheWrite
where the provider charges cache writes) in the model catalog the Gateway's parameters name
(design D10).` After `PROVIDER_LISTENERS`, add:

```python
# Design D10: one price table for agent traffic. Rows are keyed by agentgateway's
# provider name, so Z.ai, served by the `openai` provider, is priced under "openai".
CATALOG_PROVIDER = {"openai": "openai", "anthropic": "anthropic", "bedrock": "aws.bedrock", "vertexai": "gcp.vertex_ai"}
RATES = ("input", "output", "cacheRead")
CACHE_WRITE_PROVIDERS = ("anthropic", "bedrock")


def model_catalog(objs):
    """The merged price table the Gateway's parameters name; None when they name none."""
    gw = next((g for g in kind(objs, "Gateway")
               if (meta(g).get("namespace"), meta(g).get("name")) == (GW_NS, GW_NAME)), None)
    pref = ((spec_of(gw).get("infrastructure") or {}).get("parametersRef") or {}) if gw else {}
    params = next((p for p in kind(objs, "AgentgatewayParameters")
                   if meta(p).get("namespace") == GW_NS and meta(p).get("name") == pref.get("name")), None)
    sources = ((spec_of(params).get("modelCatalog") or {}).get("sources") or []) if params else []
    if not sources:
        return None
    providers = {}
    for source in sources:
        cm_ref = source.get("configMap") or {}
        cm = next((c for c in kind(objs, "ConfigMap")
                   if meta(c).get("namespace") == GW_NS and meta(c).get("name") == cm_ref.get("name")), {})
        raw = (cm.get("data") or {}).get(cm_ref.get("key") or "catalog.json")
        try:
            data = json.loads(raw) if raw else {}
        except json.JSONDecodeError:
            data = {}
        for name, entry in (data.get("providers") or {}).items():
            providers.setdefault(name, {}).update((entry or {}).get("models") or {})
    return providers


def check_prices(objs):
    backends = [b for b in kind(objs, "AgentgatewayBackend") if (spec_of(b).get("ai") or {}).get("provider")]
    if not backends:
        return []
    catalog = model_catalog(objs)
    if catalog is None:
        return [f"AG10: {GW_NS}/{GW_NAME}'s AgentgatewayParameters names no modelCatalog; agent requests go unpriced"]
    out = []
    for b in backends:
        for provider, conf in spec_of(b)["ai"]["provider"].items():
            if provider not in CATALOG_PROVIDER:
                continue  # host, port, pathPrefix
            model = (conf or {}).get("model")
            if not model:
                continue  # unpinned (OB.1's OpenRouter): AgentModelUnpriced covers it at runtime
            key = CATALOG_PROVIDER[provider]
            rates = ((catalog.get(key) or {}).get(model) or {}).get("rates") or {}
            need = RATES + (("cacheWrite",) if provider in CACHE_WRITE_PROVIDERS else ())
            missing = [r for r in need if not rates.get(r)]
            if missing:
                out.append(f"AG10: {ref(b)} pins {provider}/{model}, which the price table does not price "
                           f"({', '.join(missing)} missing under providers.{key})")
    return out
```

Append `check_prices` to `CHECKS`. If Task I.3 chose `AgentgatewayModel` for the tiers, extend
`check_prices` to read each model's concrete provider and model the same way (I.3's ruling records
the field path). In `scripts/AGENTS.md`, the gate's row gains AG10.

- [ ] **Step 4: The table.** Create `infrastructure/base/agent-gateway/model-prices.yaml` (the two
Flash IDs are the ones Task I.3 Step 2 confirmed):

```yaml
# The one price table for agent traffic (design D10), USD per million tokens,
# keyed by agentgateway's provider name (Z.ai is served by `openai`) and the
# model a backend pins. The gateway prices every request from it (llm.cost,
# gen_ai_client_cost) and the budgets charge that price (D11). A new provider
# or model is a row here; gate AG10 fails a pinned model without input, output
# and cacheRead, plus cacheWrite where the provider charges cache writes.
# Read 2026-10-04: docs.z.ai/guides/overview/pricing,
# platform.claude.com/docs/en/about-claude/pricing (5-minute cache writes, D13).
apiVersion: v1
kind: ConfigMap
metadata:
  name: agent-model-prices
  namespace: agent-gateway
data:
  catalog.json: |
    {
      "providers": {
        "openai": {
          "models": {
            "glm-5.3": {"rates": {"input": "1.40", "output": "4.40", "cacheRead": "0.26"}},
            "glm-5.2": {"rates": {"input": "1.40", "output": "4.40", "cacheRead": "0.26"}},
            "glm-5.3-flash": {"rates": {"input": "0.15", "output": "0.50", "cacheRead": "0.03"}},
            "glm-5.3-flashx": {"rates": {"input": "0.37", "output": "1.25", "cacheRead": "0.075"}}
          }
        },
        "anthropic": {
          "models": {
            "claude-opus-5-5": {"rates": {"input": "4.00", "output": "20.00", "cacheRead": "0.20", "cacheWrite": "5.00"}},
            "claude-sonnet-5-5": {"rates": {"input": "2.00", "output": "10.00", "cacheRead": "0.20", "cacheWrite": "2.50"}},
            "claude-haiku-4-5": {"rates": {"input": "1.00", "output": "5.00", "cacheRead": "0.10", "cacheWrite": "1.25"}}
          }
        }
      }
    }
```

Add `  - model-prices.yaml` to `infrastructure/base/agent-gateway/kustomization.yaml`. In
`parameters.yaml`, add under `spec`:

```yaml
  # One price table (design D10). Read only from Gateway-level parameters and
  # the Gateway's namespace (CRD agentgatewayparameters); reloaded live.
  modelCatalog:
    sources:
      - configMap:
          name: agent-model-prices
          key: catalog.json
```

- [ ] **Step 5: Run the tests and the gate**

Run: `python3 scripts/ci/tests/flux-schema/test-assert-agent-gateway.py && mkdir -p /tmp/claude-agwj && kustomize build infrastructure/gcp-0/agent-gateway > /tmp/claude-agwj/a.yaml && kustomize build infrastructure/gcp-0/agent-router > /tmp/claude-agwj/b.yaml && python3 scripts/ci/flux-schema/assert-agent-gateway.py /tmp/claude-agwj`
Expected: `all passed`; `assert-agent-gateway: 10 checks, 0 violations`. Then delete the
`claude-opus-5-5` row from `a.yaml`, re-run the gate, and expect
`AG10: AgentgatewayBackend agent-system/anthropic pins anthropic/claude-opus-5-5, which the price table does not price`.
`rm -rf /tmp/claude-agwj`.

- [ ] **Step 6: Commit**

```bash
git add infrastructure/base/agent-gateway scripts/ci/flux-schema/assert-agent-gateway.py \
  scripts/ci/tests/flux-schema/test-assert-agent-gateway.py scripts/AGENTS.md
git commit -m "feat(agent-gateway): one price table for agent models, gated (AG10)"
```

### Task J.2: Budgets charge reference tokens

**Files:**
- Modify: `infrastructure/base/agent-gateway/policy-budgets.yaml`, `infrastructure/base/agent-gateway/policy-budgets-providers.yaml`,
  `infrastructure/base/agent-gateway/ratelimit.yaml`, `scripts/ci/flux-schema/assert-agent-gateway.py`,
  `scripts/ci/tests/flux-schema/test-assert-agent-gateway.py`

**Interfaces:**
- Produces: `REF`, `BILLABLE_COST` in the gate; AG8 refuses a `Tokens` descriptor without them.

- [ ] **Step 1: Write the failing tests.** In `compliant()`, both `token-budgets` descriptors gain
`"cost": gate.BILLABLE_COST`. Before `print("main")`, add:

```python
print("AG8 reference tokens (design D11)")
expect("a Tokens descriptor without cost fails", lambda o: find(o, "AgentgatewayPolicy", "token-budgets")["spec"]
       ["traffic"]["rateLimit"]["global"]["descriptors"][0].pop("cost"), "AG8")
expect("another cost expression fails", lambda o: find(o, "AgentgatewayPolicy", "token-budgets")["spec"]
       ["traffic"]["rateLimit"]["global"]["descriptors"][1].update({"cost": "llm.totalTokens"}), "AG8")
```

Run: `python3 scripts/ci/tests/flux-schema/test-assert-agent-gateway.py`
Expected: `AttributeError` naming `BILLABLE_COST`.

- [ ] **Step 2: The gate.** After `MIN_DRAIN_MAX`, add:

```python
# Design D11: a request costs its gateway price in reference tokens (REF USD per
# token: SP4's B1 conversion, $8.5 for 5M), or its total tokens when unpriced.
# agentgateway skips a descriptor whose cost fails to evaluate, so the string is pinned.
REF = "0.0000017"
BILLABLE_COST = f"has(llm.cost) ? uint(llm.cost.total / {REF}) : uint(llm.totalTokens)"
```

In `check_budgets`, after the `unit` check, add:

```python
            if d.get("unit") == "Tokens" and d.get("cost") != BILLABLE_COST:
                out.append(f"AG8: {ref(p)} Tokens descriptor must charge reference tokens: cost: {BILLABLE_COST}")
```

and the AG8 docstring line becomes "Every rateLimit.global fails open, charges Tokens at the
reference-token cost (design D11), names no route or backend, …".

- [ ] **Step 3: The policies.** In `policy-budgets.yaml` and `policy-budgets-providers.yaml` (or wherever
Task I.4 Step 4 left the `provider` descriptor), every descriptor gains, after `unit: Tokens`:

```yaml
            # Reference tokens (design D11): the request's price from the one
            # table over $1.70 per million, so cached input charges its real
            # price on any provider. Unpriced: total tokens, as before.
            cost: 'has(llm.cost) ? uint(llm.cost.total / 0.0000017) : uint(llm.totalTokens)'
```

In `policy-budgets.yaml`'s header, "Cost = total tokens, charged after completion" becomes "Cost =
the request's price in reference tokens (design D11), charged after completion". In
`ratelimit.yaml`, the header's limits line gains "in reference tokens (design D11)", and B6's
`requests_per_unit: 10000000` becomes `33000000` with the comment
`# B6 in reference tokens: ≈ $56/day, what 10M Opus tokens at 90 % input cost (design D11).`
B1 and B2 keep their numbers.

- [ ] **Step 4: Gate both ways**

Run: Task J.1 Step 5's commands.
Expected: `all passed`; `10 checks, 0 violations`. Then remove `cost` from B6's descriptor in the
render, re-run, expect `AG8: … must charge reference tokens`.

- [ ] **Step 5: Commit**

```bash
git add infrastructure/base/agent-gateway scripts/ci/flux-schema/assert-agent-gateway.py scripts/ci/tests/flux-schema/test-assert-agent-gateway.py
git commit -m "feat(agent-gateway): budgets charge each request's price, in reference tokens"
```

### Task J.3: Anthropic's caching intent, on its backend

**Files:**
- Modify: `infrastructure/base/agent-router/agentgateway-anthropic.yaml`, `scripts/ci/flux-schema/assert-agent-gateway.py`,
  `scripts/ci/tests/flux-schema/test-assert-agent-gateway.py`

- [ ] **Step 1: Write the failing test.** Before `print("main")`, add:

```python
print("AG10 caching intent (design D12)")


def anthropic_backend(o, ai_policy=None):
    spec = {"ai": {"provider": {"anthropic": {"model": "claude-opus-5-5"}}}}
    if ai_policy is not None:
        spec["policies"] = {"ai": ai_policy}
    o.append(obj("AgentgatewayBackend", "agent-system", "anthropic", spec))
    cm = find(o, "ConfigMap", "agent-model-prices")
    catalog = json.loads(cm["data"]["catalog.json"])
    catalog["providers"]["anthropic"] = {"models": {"claude-opus-5-5": {"rates": {
        "input": "4.00", "output": "20.00", "cacheRead": "0.20", "cacheWrite": "5.00"}}}}
    cm["data"]["catalog.json"] = json.dumps(catalog)


expect("an anthropic backend without its cache_control fails", lambda o: anthropic_backend(o), "AG10")
v = violations_after(lambda o: anthropic_backend(
    o, {"finalTransformations": [{"field": "cache_control", "expression": '{"type": "ephemeral"}'}]}))
check("an anthropic backend with its cache_control passes", not any(x.startswith("AG10") for x in v), f"got {v}")
```

Task I.1's case "anthropic on internal with its /v1/models answer passes" builds an `anthropic`
backend without the policy, which AG10 now refuses: its spec becomes
`{"ai": {"provider": {"anthropic": {}}}, "policies": {"ai": {"finalTransformations": [{"field": "cache_control", "expression": '{"type": "ephemeral"}'}]}}}`.

Run: the test file. Expected: FAIL on the first.

- [ ] **Step 2: The gate.** After `CACHE_WRITE_PROVIDERS`, add:

```python
# Design D12: a provider that caches only when asked gets the mechanism from its
# backend, never from the harness. Implicit providers (Z.ai, OpenAI) need nothing.
CACHE_INTENT = {
    "anthropic": ("policies.ai.finalTransformations cache_control",
                  lambda s: any(t.get("field") == "cache_control"
                                for t in ((s.get("policies") or {}).get("ai") or {}).get("finalTransformations") or [])),
    "bedrock": ("policies.ai.promptCaching", lambda s: "promptCaching" in ((s.get("policies") or {}).get("ai") or {})),
}
```

In `check_prices`, right after the `CATALOG_PROVIDER` skip, add:

```python
            if provider in CACHE_INTENT and not CACHE_INTENT[provider][1](spec_of(b)):
                out.append(f"AG10: {ref(b)} ({provider}) lacks its caching intent "
                           f"({CACHE_INTENT[provider][0]}, design D12)")
```

and the AG10 docstring line gains ", and a backend whose provider caches only on request carries
that request".

- [ ] **Step 3: The backend.** In `agentgateway-anthropic.yaml`, `AgentgatewayBackend anthropic`'s
`spec.policies` gains, beside `auth`:

```yaml
    # Anthropic caches only when asked (design D12). Set after translation, so
    # the harness sends Z.ai's request shape unchanged: a top-level cache_control
    # is Anthropic's automatic caching, 5-minute TTL (D13). The OpenAI-to-Anthropic
    # translation drops a client's own cache_control markers.
    ai:
      finalTransformations:
        - field: cache_control
          expression: '{"type": "ephemeral"}'
```

- [ ] **Step 4: Gate and schema**

Run: Task J.1 Step 5's commands, then `mkdir -p /tmp/claude-agwj3 && kustomize build infrastructure/gcp-0/agent-router > /tmp/claude-agwj3/b.yaml && flux schema validate /tmp/claude-agwj3 --config .fluxschema.yml; echo "exit=$?"; rm -rf /tmp/claude-agwj3`
Expected: `all passed`; `10 checks, 0 violations`; `Invalid: 0`, `exit=0` (the field path is in the
pinned CRD: `AgentgatewayBackend.spec.policies.ai.finalTransformations`).

- [ ] **Step 5: Commit**

```bash
git add infrastructure/base/agent-router/agentgateway-anthropic.yaml scripts/ci/flux-schema/assert-agent-gateway.py \
  scripts/ci/tests/flux-schema/test-assert-agent-gateway.py
git commit -m "feat(agent-router): the gateway asks Anthropic to cache; the harness never does"
```

### Task J.4: One token-type contract, and the run page

**Files:**
- Modify: `infrastructure/base/agent-gateway/vmpodscrape.yaml`, `observability/base/agent-platform/grafana-dashboard-agent-run.yaml`,
  `scripts/ci/tests/test-agent-observability.py`

- [ ] **Step 1: Write the failing test.** In `test-agent-observability.py`, after Task E.3's run-page
checks (which define `raw_run`), add:

```python
    check('gen_ai_token_type=\\"cached_input\\"' in raw_run and '"Cache hit ratio"' in raw_run,
          "the run page shows cached input and its cache-hit ratio (design D9)")
    check("gen_ai_client_cost_usd_total" in raw_run,
          "the run page's cost is the gateway's, priced from agent-model-prices (design D10)")
    scrape = (ROOT / "infrastructure/base/agent-gateway/vmpodscrape.yaml").read_text()
    check("replacement: cached_input" in scrape and "replacement: cache_creation_input" in scrape,
          "agentgateway's cache token types join the shared contract at scrape (design D9)")
```

Run: `python3 scripts/ci/tests/test-agent-observability.py`
Expected: FAIL on all three.

- [ ] **Step 2: The relabel.** Append to `vmpodscrape.yaml`'s `metricRelabelConfigs`:

```yaml
        # One token-type contract across both gateways (design D9): Agent
        # Router's names, which ai-gateway still emits. `input` already means the
        # same on both: cache reads and writes included.
        - sourceLabels: [gen_ai_token_type]
          regex: input_cache_read
          targetLabel: gen_ai_token_type
          replacement: cached_input
        - sourceLabels: [gen_ai_token_type]
          regex: input_cache_write
          targetLabel: gen_ai_token_type
          replacement: cache_creation_input
```

The existing `agentgateway_gen_ai_(.+)` rule already turns the cost counter into
`gen_ai_client_cost_usd_total` (name UNVERIFIED until Task J.7 Step 2).

- [ ] **Step 3: The run page.** In `grafana-dashboard-agent-run.yaml`, with
`S` = `ar_agent=\"system:serviceaccount:agents:xplane-run-$${run}\"`:
- panel 3 "Tokens vs budget", target A becomes
  `(sum(increase(gen_ai_client_cost_usd_total{S}[$__range])) / 0.0000017) or sum(increase(gen_ai_client_token_usage_sum{S, gen_ai_token_type=~\"input|output\"}[$__range]))`,
  legend `gateway (reference tokens)`, so it compares with `maxTokens` in the meter's unit;
- panel 9 becomes "Tokens: uncached, cached, cache writes, output" with target A
  `sum by (gen_ai_token_type) (increase(gen_ai_client_token_usage_sum{S, gen_ai_token_type=~\"output|cached_input|cache_creation_input\"}[$__rate_interval]))`
  and target B, legend `uncached input`,
  `sum(increase(gen_ai_client_token_usage_sum{S, gen_ai_token_type=\"input\"}[$__rate_interval])) - (sum(increase(gen_ai_client_token_usage_sum{S, gen_ai_token_type=~\"cached_input|cache_creation_input\"}[$__rate_interval])) or vector(0))`;
- panel 10 "Cost (USD)", target A becomes `sum(increase(gen_ai_client_cost_usd_total{S}[$__range])) or (<its current expression>)`,
  so runs from before the switch keep a price;
- a new panel with the next free id (16 on `integration/agent-factory` at `24f05fab`, where panels
  1–15 exist), placed at `y` = the largest `y + h` in the file:

```json
{"id": <next free>, "type": "stat", "title": "Cache hit ratio",
 "gridPos": {"x": 0, "y": <bottom>, "w": 6, "h": 5},
 "datasource": {"type": "prometheus", "uid": "$${datasource}"},
 "fieldConfig": {"defaults": {"unit": "percentunit", "decimals": 1}, "overrides": []},
 "targets": [{"refId": "A", "instant": true, "expr": "sum(increase(gen_ai_client_token_usage_sum{ar_agent=\"system:serviceaccount:agents:xplane-run-$${run}\", gen_ai_token_type=\"cached_input\"}[$__range])) / sum(increase(gen_ai_client_token_usage_sum{ar_agent=\"system:serviceaccount:agents:xplane-run-$${run}\", gen_ai_token_type=\"input\"}[$__range]))"}]}
```

Expand `S` in the file; it is shorthand here only.

- [ ] **Step 4: Run the tests, commit**

Run: `python3 scripts/ci/tests/test-agent-observability.py && python3 scripts/ci/flux-schema/check-substitution.py`
Expected: pass; exit 0.

```bash
git add infrastructure/base/agent-gateway/vmpodscrape.yaml observability/base/agent-platform/grafana-dashboard-agent-run.yaml \
  scripts/ci/tests/test-agent-observability.py
git commit -m "feat(observability): the run page shows cached input, its hit ratio and the gateway's cost"
```

### Task J.5: Run tokens, alerts and the run meter in reference tokens

**Files:**
- Modify: `infrastructure/base/agent-model-routing/vmrule-agent-budgets.yaml` (Task I.5), `observability/base/agent-platform/vmrule.yaml`,
  `scripts/ci/flux-schema/assert-agent-gateway.py`, `scripts/ci/tests/flux-schema/test-assert-agent-gateway.py`,
  `container-images/agent-harness/agent_run.py`, `website/content/docs/decisions/0050-token-budgets-envoy-gateway-rate-limit.md`
- Modify, on SP3's stack: `tooling/base/agent-factory/helm-values-configmap.yaml`

- [ ] **Step 1: Write the failing test.** Before `print("main")`, add:

```python
print("AG8 run-token rule (design D11)")


def run_token_rule(expr):
    return {"apiVersion": "operator.victoriametrics.com/v1beta1", "kind": "VMRule",
            "metadata": {"namespace": "observability", "name": "agent-budgets"},
            "spec": {"groups": [{"name": "g", "rules": [{"record": "agent_router:run_tokens:total", "expr": expr}]}]}}


expect("a run-token rule on raw tokens fails", lambda o: o.append(run_token_rule(
    'sum by (ar_agent) (gen_ai_client_token_usage_sum{gen_ai_token_type=~"input|output"})')), "AG8")
v = violations_after(lambda o: o.append(run_token_rule(
    'sum by (ar_agent) (gen_ai_client_cost_usd_total) / 0.0000017 or sum by (ar_agent) (gen_ai_client_token_usage_sum)')))
check("a run-token rule in reference tokens passes", v == [], f"got {v}")
```

Run: the test file. Expected: FAIL on the first.

- [ ] **Step 2: The gate.** At the end of `check_budgets`, before `return out`, add:

```python
    # The run meter and the dashboards read this rule; it must count what B1 counts.
    for rule_set in kind(objs, "VMRule"):
        for group in spec_of(rule_set).get("groups") or []:
            for rule in group.get("rules") or []:
                if rule.get("record") == "agent_router:run_tokens:total" and f"/ {REF}" not in rule.get("expr", ""):
                    out.append(f"AG8: {ref(rule_set)} agent_router:run_tokens:total must divide the gateway's "
                               f"cost by {REF}, as the budgets do")
```

- [ ] **Step 3: The rule and the alerts.** In `vmrule-agent-budgets.yaml`, the token sum inside
`agent_router:run_tokens:total` becomes, keeping the rule's own labels and window:

```
(sum by (ar_agent) (gen_ai_client_cost_usd_total{ar_agent=~"system:serviceaccount:agents:.+"}) / 0.0000017)
  or sum by (ar_agent) (gen_ai_client_token_usage_sum{ar_agent=~"system:serviceaccount:agents:.+", gen_ai_token_type=~"input|output"})
```

with the comment `# Reference tokens (design D11); raw tokens for a run with no priced call
(Envoy-era runs, or an unpriced model: AgentModelUnpriced).` `AgentRunNearCeiling` and
`FleetBudgetNearCap` follow from the rule. `AnthropicFleetNearCap`'s expression becomes
`sum(increase(gen_ai_client_cost_usd_total{namespace="agent-gateway", gen_ai_system="anthropic"}[24h])) / 0.0000017 > 0.8 * 33e6`,
its summary "Agents spent more than 80 % of B6 (33M reference tokens, ≈ $56) in 24h". Append:

```yaml
        - alert: AgentModelUnpriced
          # A model the price table misses (often a dated ID in the response):
          # its requests charge raw tokens and show no cost (design D10).
          expr: sum by (gen_ai_request_model) (increase(agentgateway_cost_catalog_lookups_total{namespace="agent-gateway", status!="Exact"}[15m])) > 0
          for: 15m
          labels:
            severity: warning
          annotations:
            summary: "agent-router cannot price {{ $labels.gen_ai_request_model }}"
            description: "Add its row to infrastructure/base/agent-gateway/model-prices.yaml. Until then budgets count its raw tokens and the run page shows no cost for it."
            runbook_url: "https://github.com/Smana/cloud-native-ref/blob/integration/agent-factory/docs/runbooks/agent-factory/04-gateway-secrets-budgets.md"
            dashboard: "https://grafana.${private_domain_name}/d/agent-platform"
        - alert: AgentBudgetNotCounting
          # agentgateway skips a descriptor whose cost CEL fails, silently (design risks).
          expr: sum(increase(gen_ai_client_token_usage_sum{namespace="agent-gateway"}[15m])) > 0 unless sum(increase(ratelimit_service_rate_limit_total_hits{domain="agent-router", key1="agent"}[15m])) > 0
          for: 15m
          labels:
            severity: warning
          annotations:
            summary: "Agents spend tokens and B1 counts nothing"
            description: "The token descriptors' cost expression fails to evaluate, or agent-ratelimit is unreachable. Check infrastructure/base/agent-gateway/policy-budgets.yaml against BILLABLE_COST."
            runbook_url: "https://github.com/Smana/cloud-native-ref/blob/integration/agent-factory/docs/runbooks/agent-factory/04-gateway-secrets-budgets.md"
            dashboard: "https://grafana.${private_domain_name}/d/agent-platform"
```

Use the metric and label names Task J.7 Step 2 records if they differ. In
`observability/base/agent-platform/vmrule.yaml`, `AgentRunTokenSpendHigh` and
`AgentFleetTokenSpendHigh` replace their token sums with the same `cost / 0.0000017 or tokens`
form over their windows (`increase(…[8h])`, `increase(…[1h])`), and their summaries say
"reference tokens".

- [ ] **Step 4: Verify, commit**

Run: `python3 scripts/ci/tests/flux-schema/test-assert-agent-gateway.py && ./scripts/ci/validate-vmrules.sh && python3 scripts/ci/flux-schema/check-substitution.py`
Expected: 44 `ok` lines and `all passed`, the gate's own line `10 checks, 0 violations`; exit 0
twice. (Verified 2026-10-04: Tasks A.3, I.1 and J.1–J.5's Python assembled from this plan in a
scratch tree, and AG10 run on C.1's, I.2's and J.3's backend YAML.)

```bash
git add infrastructure/base/agent-model-routing observability/base/agent-platform/vmrule.yaml \
  scripts/ci/flux-schema/assert-agent-gateway.py scripts/ci/tests/flux-schema/test-assert-agent-gateway.py
git commit -m "feat(observability): run tokens, budget alerts and spend guards in reference tokens"
```

- [ ] **Step 5: The run meter (SP3 cross-edit).** In a separate `EnterWorktree` on SP3's stack head
(the branch that carries `tooling/base/agent-factory/helm-values-configmap.yaml`; `feat/factory-pair`
on 2026-10-04), `meter.query` becomes the rule's expression with the run selector:

```yaml
      # agent_router:run_tokens:total's expression (agentgateway design D11):
      # reference tokens; raw tokens for a run with no priced call.
      meter:
        url: http://vmsingle-victoria-metrics-k8s-stack.observability.svc:8428
        query: '(sum by (ar_agent) (gen_ai_client_cost_usd_total{ar_agent=~"system:serviceaccount:agents:xplane-run-.+"}) / 0.0000017) or sum by (ar_agent) (gen_ai_client_token_usage_sum{ar_agent=~"system:serviceaccount:agents:xplane-run-.+", gen_ai_token_type=~"input|output"})'
```

No agent-platform change: the meter accepts any query returning one series per `ar_agent`
(`Smana/agent-platform@ddb06e02 internal/factory/meter/vm.go#L53-L55`).
Run: `grep -c '0.0000017' tooling/base/agent-factory/helm-values-configmap.yaml` → `1`, then that
stack's evidence gates. Commit `feat(agent-factory): the run meter counts reference tokens` and push;
it rides SP3's PR (PR map).

- [ ] **Step 6: The harness comment.** In `container-images/agent-harness/agent_run.py`, the comment
above `DEFAULT_INPUT_USD_PER_MTOK` names `infrastructure/base/llm-gateway/vmrule-llm-gateway.yaml`
as the source of truth; it becomes `infrastructure/base/agent-gateway/model-prices.yaml: the gateway
prices every call, cached input included, and these figures only keep litellm quiet`. Nothing else
in the harness changes (design D12).
Run: `python3 -m py_compile container-images/agent-harness/agent_run.py` → exit 0.

- [ ] **Step 7: ADR-0050.** Its Implementation Notes gain one dated line: `2026-10-04 (agentgateway
plan phase J, design D11): token descriptors charge each request's price from
infrastructure/base/agent-gateway/model-prices.yaml in reference tokens (USD ÷ $1.70 per million);
caps keep their numbers.`
Run: `./scripts/ci/validate-links.sh && ./scripts/ci/verify-doc-paths.sh` → exit 0.

```bash
git add container-images/agent-harness/agent_run.py website/content/docs/decisions/0050-token-budgets-envoy-gateway-rate-limit.md
git commit -m "docs(agents): reference tokens in ADR-0050 and the harness price note"
```

### Task J.6: Prompt-prefix stability, pinned

**Files:**
- Modify: `container-images/agent-harness/tests/test_agent_run.py`

What caching relies on, at the harness pin (`OpenHands/software-agent-sdk@fcc102a697`, v1.49.6): the
static system block carries nothing per run; the dynamic block ends with the start time, after our
rules (`openhands-sdk/openhands/sdk/context/prompts/presets.py#L82-L91`). An SDK bump that moves a
volatile value earlier would silently end every within-run hit; this test fails the image build first.

- [ ] **Step 1: The test.** Append to `test_agent_run.py`:

```python
class PromptCacheStabilityTest(unittest.TestCase):
    """Prompt caching (agentgateway design, prompt-prefix stability): the system prompt is
    byte-stable within a run, and its one per-run value, the start time, follows the rules."""

    def test_volatile_data_stays_after_the_rules(self):
        from openhands.sdk import LLM, AgentContext
        from openhands.tools.preset.default import get_default_agent

        llm = LLM.model_validate(agent_run.build_request(ENV, "t", "r")["agent"]["llm"])
        base = get_default_agent(llm=llm, cli_mode=True)
        runs = [base.model_copy(update={"agent_context": AgentContext(system_message_suffix="RULES", current_datetime=t)})
                for t in ("2026-10-04T10:00", "2026-10-04T11:00")]
        self.assertEqual(runs[0].static_system_message, runs[1].static_system_message)
        self.assertNotIn("2026-10-04", runs[0].static_system_message)
        first, second = (r.dynamic_context for r in runs)
        self.assertLess(first.index("RULES"), first.index("2026-10-04T10:00"))
        self.assertEqual(first.split("2026-10-04T10:00")[0], second.split("2026-10-04T11:00")[0])
```

`static_system_message` and `dynamic_context` are `AgentBase` properties
(`openhands-sdk/openhands/sdk/agent/base.py#L336`, `#L500`); `AgentContext` is re-exported at
`openhands.sdk` (`openhands-sdk/openhands/sdk/__init__.py#L10`).

- [ ] **Step 2: Run it in the image build** (the Dockerfile runs the suite)

Run: `systemd-run --user --scope -q -p MemoryMax=6G -p MemorySwapMax=0 timeout 600 docker build -t agent-harness:prefix-test container-images/agent-harness`
Expected: the unittest step lists `test_volatile_data_stays_after_the_rules ... ok`; build exit 0.
Prove it is not vacuous: in a scratch copy, put the time inside the suffix
(`system_message_suffix="RULES 2026-10-04T10:00"`) and expect the last assertion to fail.
(Verified 2026-10-04 against `openhands-sdk==1.49.6` in a scratch venv: the test passes, the
variant fails on the last assertion.)

- [ ] **Step 3: Commit**

```bash
git add container-images/agent-harness/tests/test_agent_run.py
git commit -m "test(agent-harness): pin the prompt prefix that caching relies on"
```

### Task J.7: Gates, AGW-9, and the live checks

- [ ] **Step 1: Gates and draft.** Task A.4 Step 1's gates plus `./scripts/ci/validate-vmrules.sh`;
expect `assert-agent-gateway: 10 checks, 0 violations`. AGW-9 as a draft on
`feat/agent-frontier-tiers`, title `feat(agents): provider-agnostic prompt caching and cache-aware
budgets (ADR-0053 phase J)`, with the design's Prompt caching diagram, Task J.5 Step 5's commit link,
and the P33 hold line.

- [ ] **Step 2: [LIVE] The facts the names rest on.** Merge into integration (with SP3's cross-edit);
wait for `agent-gateway`, `agent-router` and `agent-observability` Ready. After one `public` probe
completion:

```bash
kubectl port-forward -n agent-gateway deploy/agent-router 15020:15020 &
curl -s localhost:15020/metrics | grep -E '^agentgateway_(gen_ai_client_cost|cost_catalog_lookups)' | sed 's/{.*//' | sort -u
curl -s localhost:15020/metrics | grep -E '^agentgateway_cost_catalog_lookups' | grep -o 'status="[^"]*"' | sort -u
curl -s localhost:15020/metrics | grep -E '^agentgateway_gen_ai_client_token_usage_sum' | grep -o 'gen_ai_token_type="[^"]*"' | sort -u
```

Assumptions (UNVERIFIED until here): `agentgateway_gen_ai_client_cost_usd_total` (the client library
appends the unit and `_total`), `agentgateway_cost_catalog_lookups_total` with `status="Exact"` for
`glm-5.3`, token types `input`, `output`, `input_cache_read`, `input_cache_write`
(`AGW crates/agentgateway/src/telemetry/{metrics.rs#L380-L393,log.rs#L860-L899}`). If any differs, fix
Tasks J.4 and J.5's names in one commit before going on.

- [ ] **Step 3: [LIVE] SC-14, caching on both providers.** From the probe, send the same request twice,
10 s apart, with a fixed system message of about 5 000 tokens (above every model's minimum: 512 on
Opus 5.5 and Sonnet 5.5, 4 096 on Haiku 4.5):

| Leg | Request | Expected |
|---|---|---|
| `public` (`:8080`) | `POST /v1/chat/completions`, model `agent-default` | the second response's `usage.prompt_tokens_details.cached_tokens` > 0, and `gen_ai_client_token_usage_sum{gen_ai_token_type="cached_input", ar_agent=~".*:agent-probe"}` rises. Z.ai publishes no minimum or TTL: if 0, record it and retry once at 10 000 tokens |
| `internal` (`:8081`) | the same body, model `agent-default` (Claude Opus 5.5) | the first call raises `cache_creation_input`, the second `cached_input` (`sum by (gen_ai_token_type) (increase(gen_ai_client_token_usage_sum{gen_ai_request_model="claude-opus-5-5"}[5m]))`) |
| `internal`, control | on integration only, delete the backend's `policies.ai` (commit `test(agent-router): caching intent off`), wait for Ready, repeat | neither series rises; revert the commit |

The request carries no `cache_control` and no provider-specific field: the gateway's
`finalTransformations` is the only thing that asks (design D12, UNVERIFIED until this step). If the
`internal` leg reads nothing, go to Task J.9.

- [ ] **Step 4: [LIVE] SC-15, budgets count price.** After Step 3, from Task D.3's port-forward:
`ratelimit_service_rate_limit_total_hits{domain="agent-router", key1="agent"}` rose by
`increase(gen_ai_client_cost_usd_total{ar_agent=~".*:agent-probe"}[15m]) / 0.0000017`, within one
unit per request; `key1="provider"` rose for the `internal` calls only. No rise at all means the
`cost` CEL failed and agentgateway skipped the descriptor: stop and fix it.

- [ ] **Step 5: [LIVE] SC-16, a real run.** One `public` run through `task agent:run`. Its run page
shows the cache-hit ratio, cached and uncached input and the cost ([OWNER] one look: Grafana is
SSO-gated); `AgentModelUnpriced` and `AgentBudgetNotCounting` are inactive; its
`agents.ogenki.io/usage-tokens` annotation equals `agent_router:run_tokens:total` for the run within
one scrape interval.

- [ ] **Step 6: [LIVE] Prefix stability in a real run.** From the same run's gateway access logs
(field names as Task E.1 Step 4 recorded):

```
kubernetes.pod_namespace:"agent-gateway" | unpack_json | log.x_ar_agent:"system:serviceaccount:agents:xplane-run-<id>"
  | fields _time, log.gen_ai.usage.input_tokens, log.gen_ai.usage.cache_read.input_tokens | sort by (_time)
```

Expected: cache reads grow call over call (each read ≈ the previous call's input), with a drop only
right after a condensation. A drop with none means a prefix changed mid-run: reproduce it locally with
the harness and a body-capturing fake server (as `test_reasoning_effort_reaches_the_wire` does) and
diff two consecutive bodies. Never turn on prompt capture in the cluster (O-1). Across runs, the
MCP tool list must not reorder: `AGENT_ROUTER_HOST=$H sh /tmp/mcp.sh public tools/list | sha256sum`
from two probe sessions prints the same hash.

Paste every output into AGW-9's "Live evidence".

### Task J.8: [LIVE] The same task twice, at the next gcp-0 rebuild

On the first gcp-0 rebuild with AGW-9 and SP3's cross-edit in integration. Every number comes from
the normalised series, so the procedure is the same on any provider.

- [ ] **Step 1: The runs.** A `triager` run (template `investigate`: it proposes issue text and never
writes) on `public`, with a fixed task text recorded in AGW-9's body, on a fixed base commit, through
`task agent:run`. When it ends, start the identical run at once, so its first calls can find the first
run's cache.
- [ ] **Step 2:** The same pair on `internal` once owner prerequisite P1 is done; otherwise record
"internal: skipped, no key".
- [ ] **Step 3: The table.** Per run, with `R` its `ar_agent` and every query evaluated at the run's
finish over a window equal to its duration:

| Column | Source |
|---|---|
| model calls | `sum(increase(gen_ai_server_request_duration_seconds_count{ar_agent="R"}[…]))` |
| input, cached, cache writes, output | `sum by (gen_ai_token_type) (increase(gen_ai_client_token_usage_sum{ar_agent="R"}[…]))` |
| cache-hit ratio | cached ÷ input |
| cost, gateway | `sum(increase(gen_ai_client_cost_usd_total{ar_agent="R"}[…]))` |
| cost at the old rule | input × input rate + output × output rate from `agent-model-prices`: what the run page showed before J.4 |
| reference tokens | gateway cost ÷ 0.0000017, beside the run's `agents.ogenki.io/usage-tokens` |
| latency | p50 and p95 of `gen_ai_server_request_duration_seconds_bucket{ar_agent="R"}`; wall-clock from `agentrun_started_timestamp_seconds` / `agentrun_finished_timestamp_seconds` |
| first-call cache reads | the run's first access-log line, `gen_ai.usage.cache_read.input_tokens` (reuse across runs) |
| condensations | condenser summaries in the step log, if it prints them; otherwise "not visible" |

- [ ] **Step 4:** Paste the table into AGW-9's "Live evidence" (SC-17). It is evidence, not a gate: no
threshold.

### Task J.9: Fallback, only if Task J.7 Step 3's `internal` leg reads nothing

Design D12's fallback. Skip it when J.7 Step 3 passes.

- [ ] **Step 1:** Record the failing leg (both responses' `usage`, the access-log lines) in AGW-9.
- [ ] **Step 2: Prove the Messages path first.** From the probe, `POST http://agent-router.agent-gateway.svc.cluster.local:8081/anthropic/v1/messages`
with an Anthropic-format body carrying `cache_control` on its system block, twice. Expected:
`200` with a Messages-shaped body, and `cached_input` rises on the second call (agentgateway forwards
a Messages body with its keys: `AGW crates/llm/src/types/messages.rs#L14-L30`, `llm/mod.rs#L405-L416`).
UNVERIFIED: that the `/anthropic` prefix route detects the Messages format by path. If it fails, stop
and report: no harness change can help.
- [ ] **Step 3: The switch lives in config, keyed on the route's provider.** In crossplane-configuration
(a CC-AGW3 PR on CC-AGW2), `apis/agentrun/kcl/main.k` gains one map from listener to API format,
`{"public" = "openai", "internal" = "anthropic"}`, which sets the run's `LLM_API` env and, for
`anthropic`, `LLM_BASE_URL` to the `/anthropic` path; `main_test.k` asserts both values.
`agent_run.py` then reads `LLM_API`: `anthropic` selects litellm's `anthropic/` provider and sets
`capability_overrides={"supports_prompt_cache": True}` (the alias matches no Claude name in the SDK's
list, `openhands-sdk/openhands/sdk/llm/utils/model_features.py#L123-L151`), with a test per value.
No `if class == "internal"` appears in the harness.
- [ ] **Step 4:** Re-run Task J.7 Step 3's `internal` leg with a real `internal` run: `cached_input`
rises. Keep J.3's backend policy: an explicit marker on the last block with the same TTL makes the
top-level one a no-op ([prompt caching](https://platform.claude.com/docs/en/build-with-claude/prompt-caching)).

---

## Appendix — optional backends, off by default

None of these is required, and none blocks a phase. Each lands only when someone asks for it, as its
own PR on top of AGW-8, with the P33 hold line.

### Task OB.1: OpenRouter on `public` (model breadth, experiments)

Never on `internal` (ADR-0054: a second data processor, and the upstream is not ours to pick). Gate
AG5 already refuses it there.

**Files:** Create `infrastructure/base/agent-router/optional/openrouter/{kustomization.yaml,externalsecret.yaml,backend.yaml,policy-budget.yaml}`.
Off by default means **no kustomization references this directory**; enabling it is adding
`- optional/openrouter` to `infrastructure/base/agent-router/kustomization.yaml` in a reviewed PR.

- [ ] **Step 1: Owner prerequisite.** `bao kv put -mount=agents openrouter api_key=-` (key on stdin),
and a credit limit on that key in OpenRouter's settings (the provider-side half of B7).
- [ ] **Step 2: Write the files.** `externalsecret.yaml` mirrors Task I.2's with `name: agents-openrouter-api-key`
and `remoteRef.key: openrouter`. `backend.yaml`:

```yaml
# Optional, public only (ADR-0054). OpenAI-compatible; OpenRouter picks the
# upstream that serves each request, which is why internal data never comes here.
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayBackend
metadata:
  name: openrouter
  namespace: agent-system
spec:
  ai:
    provider:
      openai: {}
      host: openrouter.ai
      port: 443
      pathPrefix: /api/v1
  policies:
    auth:
      secretRef:
        name: agents-openrouter-api-key
        key: apiKey
    tls:
      sni: openrouter.ai
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: agent-models-openrouter
  namespace: agent-system
spec:
  parentRefs:
    - group: gateway.networking.k8s.io
      kind: Gateway
      name: agent-router
      namespace: agent-gateway
      sectionName: public
  rules:
    # Opt-in per request: only an `x-agent-provider: openrouter` header reaches it.
    - matches:
        - path:
            type: PathPrefix
            value: /v1
          headers:
            - name: x-agent-provider
              value: openrouter
      backendRefs:
        - group: agentgateway.dev
          kind: AgentgatewayBackend
          name: openrouter
```

The identity-proxy forwards client headers, so a harness opts in per request. `policy-budget.yaml` is
a route-level `AgentgatewayPolicy` on `agent-models-openrouter` with descriptor `provider` =
`'"openrouter"'`, `unit: Tokens`; the ConfigMap gains `key: provider, value: openrouter`, 5 000 000/day,
`shadow_mode: true` (B7). Task I.4 Step 4's merge result decides whether that route policy must also
carry B1–B2. The data plane's egress gains `openrouter.ai:443`, in the same directory as a CNP patch.
- [ ] **Step 3: Verify.** `kustomize build infrastructure/base/agent-router/optional/openrouter` renders;
the default render has no `openrouter` (`kustomize build infrastructure/gcp-0/agent-router | grep -c openrouter` → `0`);
with the directory enabled in a scratch copy, the gate passes, and moving the route to `internal`
fails AG5.
- [ ] **Step 4: Commit** `feat(agent-router): optional OpenRouter backend for public work, off by default`.

### Task OB.2: Bedrock on `internal`, per cloud (aws-0)

For a team whose internal data must stay in its AWS account. Carries SP4 Task 10's
`xplane-agent-router-bedrock` EPI, re-pointed at the agentgateway proxies' ServiceAccount (B.6 Step 3
records its name) in `agent-gateway`, granting `bedrock:InvokeModel*` on the EU Claude profiles only.
An aws-0 overlay adds an `AgentgatewayBackend` with `spec.ai.provider.bedrock` (region `eu-west-3`,
default AWS credential chain = Pod Identity), egress to `bedrock-runtime.eu-west-3.amazonaws.com:443`
and the Pod Identity agent `169.254.170.23:80`, and swaps the internal route's backend. Gate AG5's
`PROVIDER_LISTENERS` gains `"bedrock": {"internal"}`. Live proof needs an aws-0 cluster.

### Task OB.3: Vertex on `internal`, per cloud (gcp-0)

Same shape for GCP: `spec.ai.provider.vertexai` (project and region from `gke-gcp-0-vars`), keyless
through Workload Identity on the proxies' ServiceAccount (an `AgentgatewayParameters.spec.serviceAccount`
annotation if the binding needs one), egress to `${region}-aiplatform.googleapis.com:443`.
`PROVIDER_LISTENERS` gains `"vertexai": {"internal"}`.
