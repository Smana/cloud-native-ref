# Research: How can humans and role-bound agent runs share one ordered, live agent session on this platform?

**Topic**: agent-collaboration-rooms · **Conducted**: 2026-09-23 · **Researcher**: Claude (subagent)

Every claim below was re-checked against a primary source on 2026-09-23 (a spec, source at a tag, a release API or
vendor docs). Anything not re-checked is marked **UNVERIFIED**. The earlier raw scan's product landscape (Claude Tag,
Devin, Conductor, Zed Delta and others) and its adoption statistics were **not** re-verified. No design decision here
rests on them.

## TL;DR

- **No protocol covers the whole problem.**
  - AHP (Microsoft, MIT, v0.9.0) is the only spec for N clients on one agent session, but it leaves transport auth
    and agent-to-agent communication explicitly out of scope.
  - ACP v2 is 1:1 and defers queueing, steering and sender identity.
  - A2A v1.0 covers agent↔agent tasks with no human participant.
  - MCP dropped sessions in 2026-07-28.
- **AHP's semantics are directly reusable.** Server-assigned sequence numbers; snapshot plus replay; queued vs steering
  messages; one active turn; "the first `chat/toolCallConfirmed` wins"; notifications that are never replayed.
- **The OpenHands agent-server (SP1's default harness) has everything needed below a broker.** v1.49.5 provides:
  - a lossless `/sockets/session/{id}?after_seq=` stream with byte-budget admission;
  - message injection that the running agent consumes at its next step;
  - confirmation mode (`AlwaysConfirm`, `NeverConfirm`, `ConfirmRisky`) with a response endpoint;
  - interrupt;
  - fork within one server.

  It has **no identity** (one shared API key) and an open multi-client bug. It should see exactly one client.
- **The platform already has every building block.**
  - The `SQLInstance` claim is CloudNativePG on **both** clouds, not RDS on AWS.
  - The `KVStore` claim is Valkey with cache semantics.
  - An oauth2-proxy + ZITADEL pattern with `groups` exists.
  - The private Tailscale Gateway already upgrades WebSockets.
- **agentgateway's A2A support** is proxying, agent-card URL rewriting and policy. It adds value only if A2A is in use.
- **Envoy defaults matter for long WebSockets**: a 15 s route timeout and a 5 min stream idle timeout. Cilium sets
  neither to infinity unless the HTTPRoute asks for it.

## Standard stack

| Component | Pick (candidate) | Version | Source |
|---|---|---|---|
| Multi-client session semantics | Agent Host Protocol (mirror semantics; its Go `ahptypes` for a later facade) | spec v0.9.0, 2026-08-28, MIT | `gh api repos/microsoft/agent-host-protocol/releases`; [guide/ahp-and-acp.md](https://github.com/microsoft/agent-host-protocol/blob/main/docs/guide/ahp-and-acp.md) |
| Harness API under the bridge | OpenHands agent-server | v1.49.5, 2026-09-23, MIT | `gh api repos/OpenHands/software-agent-sdk/releases`; `openhands-agent-server/openhands/agent_server/{session_socket,event_router,conversation_router,conversation_registry}.py` at the tag |
| Agent↔agent protocol (considered) | A2A | v1.0.0, 2026-03-12; v1.0.1, 2026-05-28 | `gh api repos/a2aproject/A2A/releases`; [what's new in v1](https://a2a-protocol.org/latest/whats-new-v1/) |
| Agent proxy (considered) | agentgateway | v1.6.0-alpha.2, 2026-09-22, Apache-2.0 | `gh api repos/agentgateway/agentgateway/releases`; [A2A docs](https://agentgateway.dev/docs/standalone/latest/agent/a2a/) |
| Client↔agent protocol (considered) | ACP | v1.9.1, 2026-09-18; v2 RFDs in progress | [docs/rfds/v2/prompt.mdx](https://github.com/agentclientprotocol/agent-client-protocol/blob/main/docs/rfds/v2/prompt.mdx) |
| Event log store | CloudNativePG through the `SQLInstance` claim | CNPG v1.30.1 upstream (2026-09-23); composition v0.7.1 pinned | `crossplane-configuration` `apis/sqlinstance/composition-aws.yaml` at v0.7.1; `gh api repos/cloudnative-pg/cloudnative-pg/releases/latest` |
| Fan-out and presence | Valkey through the `KVStore` claim | Valkey 9.1.2 upstream, BSD-3-Clause | `crossplane-configuration` `apis/kvstore/definition.yaml` |
| Schema migrations | Atlas through `SQLInstance.spec.atlasSchema` | Atlas v1.3.0, Apache-2.0 | `apis/sqlinstance/definition.yaml`; `apps/AGENTS.md` |
| Human login in front of the broker | oauth2-proxy | v7.15.4, 2026-08-20, MIT; chart 10.7.0 in repo | [flag reference](https://oauth2-proxy.github.io/oauth2-proxy/configuration/overview); `tooling/gcp-0/headlamp/oauth2-proxy.yaml` |
| OIDC token validation (Go) | `coreos/go-oidc` | v3.21.0, Apache-2.0 | `gh api repos/coreos/go-oidc/releases/latest` |
| WebSocket (Go) | `coder/websocket` | v1.8.15, ISC | `gh api repos/coder/websocket/releases/latest` |
| Secret detection | gitleaks `detect` package (rules `github-app-token`, `github-pat`, `jwt`, `private-key`) | v8.30.1, MIT | `gitleaks/gitleaks` `detect/`, `config/gitleaks.toml` |
| Agent token validation | Kubernetes TokenReview (client-go) | — | [SA admin docs](https://kubernetes.io/docs/reference/access-authn-authz/service-accounts-admin/) |
| Markdown in the UI | markdown-it with `html: false` | MIT; version UNVERIFIED | `markdown-it/markdown-it` |

## Protocol and client options compared

| Option | Multi-client | Human identity per message | Agent↔agent | Status | Fit for rooms |
|---|---|---|---|---|---|
| AHP | Yes: N clients, `serverSeq`, snapshots, replay; queued and steering; first `toolCallConfirmed` wins | `origin.clientId` only; auth "outside the scope" | Explicitly not ("coordinates clients, not agents") | Spec v0.9.0, MIT, pre-1.0 | Semantics to mirror; a wire facade later |
| ACP v2 | No: 1:1 | No; "Queueing, steering, sender identity … remain outside" | No | v1.9.1; v2 RFDs in progress | Harness-side protocol only |
| OpenHands agent-server | In practice (pub/sub, `after_seq`), with an open multi-client bug | No: one shared API key | No | v1.49.5, MIT | The harness under a bridge, one client |
| A2A v1.0 | Yes, per task ("Multiple concurrent subscriptions") | No | Yes | v1.0.0 (2026-03-12) | No human participant |
| MCP 2026-07-28 | Sessions and resumability removed | No | No | Final | Tools only |

| Client option | Strength | Cost or risk |
|---|---|---|
| Web UI served by the broker | Carries every room semantic; no install; phone approvals; good screenshots | 2–3k LoC of UI; XSS surface (LLM output) needs CSP and HTML-free markdown |
| `roomctl` CLI | Deterministic, terminal-native, shares client code with the bridge | Hides presence and approvals from non-terminal users |
| Headlamp plugin (ADR-0035 pipeline) | Rooms and runs as Kubernetes objects | Chat UX in a plugin; toolkit lags Headlamp (0.14 vs 0.45); plugin access to the user's token **UNVERIFIED** |
| AHP facade for VS Code or AHPX | Real interoperability | Facade code plus pre-1.0 churn; third-party host attach from VS Code **UNVERIFIED** |
| Claude Code (MCP or Channels) | The owner's daily tool | Pipes untrusted room content into an LLM holding the owner's local credentials |

OpenHands SDK event classes at v1.49.5 (`openhands/sdk/event/__init__.py`): `MessageEvent`, `ActionEvent`,
`ObservationEvent`, `UserRejectObservation`, `ConversationStateUpdateEvent`, `AgentErrorEvent`, `PauseEvent`,
`InterruptEvent`, `StreamingDeltaEvent`, `SystemPromptEvent`, `LLMCompletionLogEvent`, `CondensationSummaryEvent`,
`TokenEvent`, `HookExecutionEvent`, `ACPToolCallEvent`.

## Local patterns worth reusing

| Path | Why |
|---|---|
| `tooling/gcp-0/headlamp/oauth2-proxy.yaml`, `httproute-oauth2-proxy.yaml`, `externalsecret-oauth2-proxy.yaml` | ZITADEL in front of a service. `oidc-issuer-url: ${identity_provider_url}`, `pass-authorization-header`, `allowed-group`, `oidc-groups-claim: groups`; secrets from the store; the route points at the proxy |
| `scripts/provision/zitadel-oidc-clients.sh` (`CONSUMERS`, `ZITADEL_PROJECT_ROLES` at line 98) | Registering a new OIDC client and project roles (`admin backend frontend data` today). All clients use `OIDC_TOKEN_TYPE_BEARER`, so access tokens are opaque and the ID token is the JWT to validate |
| `scripts/provision/zitadel-actions/groups-from-roles.js`, ADR-0034 | Flattens project roles into the `groups` claim that every consumer reads |
| `infrastructure/base/gapi/platform-tailscale-general-gateway.yaml` | Private `*.${private_domain_name}` listener. **`allowedRoutes` is a namespace allowlist**; a new namespace must be added or its route is `NotAllowedByListeners` |
| `tooling/base/headlamp/httproute.yaml` | Minimal private HTTPRoute shape |
| `tooling/aws-0/harbor/sqlinstance.yaml`, `security/base/zitadel/sqlinstance.yaml` | `SQLInstance` with `objectStoreRecovery`, `backup` to `${region}-ogenki-cnpg-backups`, and the six-field CNPG cron gotcha |
| `tooling/base/harbor/kvstore.yaml` | `KVStore` with `auth.existingSecret` |
| `security/base/zitadel/network-policy.yaml` | Egress to a CNPG cluster by `k8s:cnpg.io/cluster`; ingress from the `ingress` entity (Gateway) |
| `apps/base/openwebui/app.yaml`, `apps/platform/app-wizard/app.yaml` | Platform components deployed as `App` claims. The App XRD takes custom CNP ingress/egress (including `toFQDNs`), extra Service ports, sidecars, `sqlInstance`, `kvStore` |
| `container-images/token-exchange-proxy/` | A small Go service built by `build-container-images.yml` |
| `observability/base/victoria-metrics-k8s-stack/` (Alertmanager Slack app, ADR-0037) | Route "approval pending" alerts to Slack without new integration code |
| `security/aws-0/openbao/openbao-clusterissuer.yaml` | A cert-manager issuer for in-cluster TLS where WireGuard is absent (gcp-0) |
| `docs/superpowers/specs/2026-09-09-headlamp-app-view-design.md`, ADR-0035 | Headlamp plugin pipeline, if a Rooms view is ever added there |

## Don't hand-roll

| Problem | Use | Evidence |
|---|---|---|
| History/live interleave on reconnect | OpenHands' algorithm: subscribe buffering → read the high-water mark → paged replay → flush, deduplicating by seq. "The replay boundary needs no lock" | [software-agent-sdk#4681](https://github.com/OpenHands/software-agent-sdk/issues/4681); `session_socket.py` |
| Slow consumer back-pressure | Byte-bounded admission with a single writer per connection. "Overflow drops the connection, never a frame" | `session_socket.py` `_ConnectionWriter` |
| Multi-client arbitration rules | AHP: one active turn, first confirmation wins, server-wins on conflict, notifications not replayed | ahp-and-acp.md; `docs/guide/reconciliation.md`; `docs/specification/subscriptions.md` |
| OIDC login, cookie session, WebSocket proxying | oauth2-proxy (`proxy-websockets` defaults to `true`) | flag reference |
| Revocable agent authentication | TokenReview. Bound tokens stop authenticating once their object is deleted, and only the API server knows that | SA admin docs |
| Secret detection | gitleaks `detect` with its default rules | `gitleaks/gitleaks` |
| Schema migrations | Atlas through `SQLInstance.atlasSchema` | `apps/AGENTS.md` |
| Harness-internal fork (same sandbox) | `POST /api/conversations/{id}/fork` with `from_event_id` | `conversation_router.py` v1.49.5 |

## Common pitfalls

1. **`SQLInstance` is not RDS on AWS.** v0.7.1's AWS composition runs `environment`, `cloudnativepg`, `ready`. Its
   own comment: "exactly three things are cloud-specific — where backups are written, what identity writes them, and
   how a secret-store key is spelled". The line in `apps/AGENTS.md` ("RDS on AWS, in-cluster CNPG on GCP") is stale.
2. **Only the standalone `SQLInstance` exposes `objectStoreRecovery`.** The `App.spec.sqlInstance` sub-block has
   `backup` but no recovery, so a log created through it does not survive a cluster rebuild.
3. **CNPG's restore needed an empty archive**: #1963, fixed by #1969 with a per-generation WAL-archive prefix. Keep the
   fix in mind when naming the recovery `path`.
4. **No manifest selects CNPG pods with a CNP.** A grep for `cnpg.io/cluster` in selectors under `security/`,
   `tooling/` and `apps/` finds none, and the `SQLInstance` composition renders no CNP. A new CNPG cluster starts
   outside default-deny unless its policy is authored.
5. **The `KVStore` CNP admits every pod in the namespace** on 6379 (`fromEndpoints: [{}]`). Its XRD says "No automatic
   failover — cache semantics". Use `auth`, and never make it the system of record.
6. **Envoy timeouts on WebSockets.** Route timeout defaults to 15 s; stream idle to 5 min
   ([Envoy FAQ](https://www.envoyproxy.io/docs/envoy/latest/faq/configuration/timeouts)).
   - Cilium enables the `websocket` upgrade and `MaxStreamDuration: 0`
     (`operator/pkg/model/translation/envoy_http_connection_manager.go`).
   - It sets a route `Timeout` only when the HTTPRoute declares one, and translates an explicit `0s` to disabled
     (`envoy_virtual_host.go`, `timeoutMutation`).
   - Use `timeouts.request: 0s` plus an application ping under 5 min.
   - Whether 15 s actually cuts an idle upgraded stream through our Gateway: **UNVERIFIED**. Test it.
7. **oauth2-proxy `cookie-samesite` defaults to empty.** Set it explicitly. `pass-authorization-header` forwards the
   **ID** token, not an access token.
8. **ZITADEL access tokens are opaque here** (`OIDC_TOKEN_TYPE_BEARER` for every consumer). A service validating JWTs
   must take the ID token, or its client must be configured for JWT access tokens.
9. **gcp-0 has no Cilium WireGuard.** aws-0 keeps `encryption.type: wireguard` as a workaround for cilium#43493;
   gcp-0's values remove it (`opentofu/gcp/gke/init/helm_values/cilium.yaml`). Bearer tokens between pods on gcp-0 need
   TLS.
10. **OpenHands multi-client is not hardened.** The shared bash-events socket cross-matches clients' outputs
    ([OpenHands#17485](https://github.com/OpenHands/OpenHands/issues/17485), open). Give the harness a single client.
11. **The OpenHands session API key is all-powerful** (conversations, files, commands). Anything holding it has a shell
    in the sandbox. The docs warn: "Do not expose an unauthenticated Agent Server on a public network"
    ([agent-server](https://docs.openhands.dev/sdk/arch/agent-server.md)).
12. **An agent with a shell can reach its own harness API** in the same pod, including `respond_to_confirmation`, if
    it can read the key.
    - SP1 reaches the same conclusion: harness-level confirmation is "advice to the model, not a boundary"
      ([SP1 design](2026-09-23-agent-runtime-identity-design.md)).
    - SP1 keeps the *SA tokens* out of the harness container (an in-pod `identity-proxy`). Whether the agent-server's
      own session key is readable by the agent's shell is **UNVERIFIED**.
13. **One GitHub App for every run** means GitHub cannot distinguish a reviewer run from an implementer run. Role
    separation therefore needs per-role token scopes (octo-sts, programme C3/C6), not the ruleset.
14. **ADR numbers are reserved per sub-project** by the programme (SP2: 0044 and 0049), because 0038–0040 already exist
    on `origin/main` and four drafts were numbering in parallel.
15. **A2A v1.0 dates from 2026-03-12** (GitHub release). A docs page summary suggested August; the release API is
    authoritative.
16. **The `openbao-platform` ClusterSecretStore has no namespace `conditions`**, so any namespace can read any
    `platform/` path (SP1 threat T14). Agent-platform components use only the namespaced `agents-secrets` store,
    scoped to `platform/agents/*` (programme C1).

## Open questions surfaced

| Question | Why it matters | How to settle |
|---|---|---|
| Does the `x-ar-agent` projection (programme C5, from Envoy Gateway's `SecurityPolicy` claim→header) reach **MCP** backends behind `MCPRoute`? | Room tools behind the gateway depend on it. The v1.1 release notes mention `credentialOverride` header stripping but not MCP claim projection | Read Agent Router `MCPRoute` docs/source at the pinned version (SP1) |
| Does OpenHands' `respond_to_confirmation` accept or reject **all** pending actions at once? | One human-class action could hold back auto-allowed siblings | `event_service.respond_to_confirmation` at v1.49.5 |
| Can the agent's shell read `OH_SESSION_API_KEYS_*` in SP1's pod layout? | Decides whether self-confirmation (pitfall 12) is possible or merely theoretical | SP1 pod spec |
| Can a harness conversation be **imported** into a new agent-server? | A fork across sandboxes could carry harness memory instead of a brief | OpenHands API; none found at v1.49.5 |
| Can a third-party AHP host be attached from VS Code or AHPX today? | The value of an AHP facade | AHPX README; VS Code agent host docs (**UNVERIFIED**) |
| Does Headlamp expose the user's OIDC token to plugins? | A Headlamp Rooms view calling the broker directly | Headlamp plugin API (**UNVERIFIED**) |
| Is a room log an audit record that must outlive the 15 d CNPG backup retention? | Retention and legal expectations | Owner (programme OD-17) |

## References

- AHP repository and release: https://github.com/microsoft/agent-host-protocol (MIT; spec/v0.9.0 2026-08-28)
- AHP guide, AHP and ACP ("AHP is a mutex over ACP"; first `chat/toolCallConfirmed` wins; "AHP coordinates clients,
  not agents"): https://github.com/microsoft/agent-host-protocol/blob/main/docs/guide/ahp-and-acp.md
- AHP chat channel (queued vs steering consumption; fork; `MessageChatAttachment`):
  https://github.com/microsoft/agent-host-protocol/blob/main/docs/specification/chat-channel.md
- AHP subscriptions (snapshot + `fromSeq`; notifications not replayed):
  https://github.com/microsoft/agent-host-protocol/blob/main/docs/specification/subscriptions.md
- AHP transport (auth outside the protocol; one JSON-RPC message per WebSocket text frame):
  https://github.com/microsoft/agent-host-protocol/blob/main/docs/specification/transport.md
- AHP reconciliation (reconnect with `lastSeenServerSeq`; server-wins):
  https://github.com/microsoft/agent-host-protocol/blob/main/docs/guide/reconciliation.md
- AHP doctrine (anti-goal: "Agent-to-agent coordination semantics"):
  https://microsoft.github.io/agent-host-protocol/guide/doctrine.html
- AHP implementations (AHPX CLI; `pi-ahp`; VS Code agent host):
  https://github.com/microsoft/agent-host-protocol/blob/main/docs/guide/implementations.md
- ACP v2 prompt RFD ("Queueing, steering, sender identity … remain outside this change"):
  https://github.com/agentclientprotocol/agent-client-protocol/blob/main/docs/rfds/v2/prompt.mdx
- OpenHands agent-server session socket design and algorithm:
  https://github.com/OpenHands/software-agent-sdk/issues/4681
- OpenHands agent-server source at v1.49.5: https://github.com/OpenHands/software-agent-sdk/tree/v1.49.5/openhands-agent-server
- OpenHands mid-run messages example:
  https://github.com/OpenHands/software-agent-sdk/blob/main/examples/01_standalone_sdk/18_send_message_while_processing.py
- OpenHands confirmation policies:
  https://github.com/OpenHands/software-agent-sdk/blob/main/openhands-sdk/openhands/sdk/security/confirmation_policy.py
- OpenHands agent-server auth: https://docs.openhands.dev/sdk/arch/agent-server.md
- OpenHands multi-client bug: https://github.com/OpenHands/OpenHands/issues/17485
- A2A v1 changes: https://a2a-protocol.org/latest/whats-new-v1/; releases: https://github.com/a2aproject/A2A/releases
- agentgateway A2A: https://agentgateway.dev/docs/standalone/latest/agent/a2a/
- Agent Router v1.1 release notes: https://theagentrouter.ai/release-notes/v1.1/
- Kubernetes bound SA tokens: https://kubernetes.io/docs/reference/access-authn-authz/service-accounts-admin/
- Envoy timeouts FAQ: https://www.envoyproxy.io/docs/envoy/latest/faq/configuration/timeouts
- Cilium Gateway translation source: https://github.com/cilium/cilium/tree/main/operator/pkg/model/translation
- oauth2-proxy flags: https://oauth2-proxy.github.io/oauth2-proxy/configuration/overview
- gitleaks: https://github.com/gitleaks/gitleaks
- crossplane-configuration (SQLInstance, KVStore, App XRDs and compositions, v0.7.1):
  https://github.com/Smana/crossplane-configuration
- Programme design (D1–D11, C1–C7): [2026-09-23-agent-factory-design.md](2026-09-23-agent-factory-design.md)
