# SP1 — Agent runtime & identity Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Applying an `AgentRun` claim on aws-0 starts a gVisor-sandboxed OpenHands agent under its own
ServiceAccount. The agent reaches models and read-only MCP tools only through the `agent-router`
Gateway, and opens one PR with a ≤ 1 h, single-repo, role-scoped GitHub token. Deleting the claim
revokes everything, and a token copied out dies at the run's deadline (R2: under gVisor a rotated
token never reaches the proxy).

**Architecture:** A namespaced Crossplane XR, `AgentRun`, lives in `Smana/crossplane-configuration`'s
core package. It composes a ServiceAccount, a task ConfigMap, a CiliumNetworkPolicy and a bare
agent-sandbox `Sandbox` on a Karpenter AL2023 spot pool where runsc is installed. Inside the pod, an
Envoy native sidecar (`identity-proxy`) is the only holder of the two projected tokens, which live until the run's deadline (R2). It injects
them towards `agent-router` (Envoy Gateway JWT on one listener per data class) and a self-hosted
octo-sts. Everything outside the XR ships behind the suspended `agent-platform` Flux umbrella.

**Tech Stack:** Crossplane v2 + function-kcl (KCL 0.11.3), agent-sandbox v1.0.3, gVisor
`release-20260921.0` on EKS AL2023 (containerd 2.2, config v3), Karpenter 1.14.1, Cilium (ENI, KPR,
FQDN + DNS L7), Envoy Gateway 1.9.1 + Agent Router 1.1.0, Envoy 1.39.1 `credential_injector`,
Kyverno 1.19 `ValidatingPolicy`/`DeletingPolicy`, External Secrets + OpenBao JWT auth, octo-sts 0.10.0,
OpenHands agent-server 1.49.5, flux-operator-mcp 0.60.0, mcp-victoriametrics 1.20.2, mcp-victorialogs
1.9.0, OpenTofu + Terramate.

**Spec:** [`docs/superpowers/specs/2026-09-23-agent-runtime-identity-design.md`](../specs/2026-09-23-agent-runtime-identity-design.md)
(read §1–§6 and the success criteria before any task), its
[research](../specs/2026-09-23-agent-runtime-identity-research.md) (pitfalls 1–16 are load-bearing),
and the [programme design](../specs/2026-09-23-agent-factory-design.md) (contracts C1–C7 bind every
task; OD-1…OD-17 are accepted at their recommended defaults).

## Global Constraints

- **Target** aws-0 only. gcp-0 is the design's follow-up and is out of this plan.
- **Live clusters are spot and cheapest** (owner rule). A feature-branch cluster deploys with
  `TF_VAR_flux_git_ref=refs/heads/<branch>`, never by pointing Flux at a branch by hand.
- **Names.** `runId` matches `^[a-z2-7]{8}$`. Claim, ServiceAccount, Sandbox and CNP are
  `xplane-run-<runId>`, the ConfigMap `xplane-run-<runId>-task` (constitution §1). Labels
  `agents.ogenki.io/run-id`, `agents.ogenki.io/role`, plus `agents.ogenki.io/task` when the claim
  carries it. `spec.principal` is the annotation `agents.ogenki.io/principal`.
- **Namespaces.** `agents` holds runs only. `agent-system` holds the control plane. Both live in
  `namespaces/base/` and are always on (C1), with PSS `restricted`.
- **Umbrella.** Flux Kustomization `agent-platform` in `flux-system`, file
  `clusters/aws-0/agent-platform.yaml`, `spec.suspend: true`, path `./clusters/aws-0-agent-platform`.
  From phase 3 it `dependsOn` `ai-gateway`, never `llm-platform`.
- **Audiences (C2).** Gateway `agent-router.<role>.<dataClass>`; octo-sts
  `octo-sts/<owner>/<repo>/<role>`; room `room-broker` (SP2). The gateway and octo-sts tokens have
  `expirationSeconds: max(600, maxMinutes × 60)`, the run's deadline (R2, spike Q2).
- **Ports.** `agent-router` listeners `public` :8080 and `internal` :8081. identity-proxy
  `127.0.0.1:4000` → `public`, `:4002` → `internal`, `:4001` → octo-sts, health `0.0.0.0:9902` (`/ready`).
  Admin is the pathname socket `/tmp/envoy-admin.sock` in `proxy-tmp`, never on the pod network, and
  the proxy runs `--disable-hot-restart --concurrency 1` (P13). Harness :8000 on loopback only.
- **Stripped headers (C5).** `x-ar-agent`, `x-ar-human`, `x-ai-gateway-client-id`, `agent-session-id`,
  removed before authentication.
- **Secrets.** `agent-system` gets secrets only through the namespaced `SecretStore agents-secrets`, which
  reads `platform/agents/*` and nothing else. Paths: `platform/agents/zai` (`api_key`) and
  `platform/agents/github-app` (`app_id`, `private_key`). Nothing in `agents` holds a Secret.
- **Pins.**

  | Component | Pin |
  |---|---|
  | agent-sandbox | git tag `v1.0.3`, chart `./helm`, image `registry.k8s.io/agent-sandbox/agent-sandbox-controller:v1.0.3@sha256:8c8f5814c16bd68631af0496a5fa4eb9bedce4d032de88b956130a041d9f438e` |
  | gVisor | `release-20260921.0`, `gvisor-x86_64.tar.bz2` sha256 `3dd478770dd751d09c257ba14d739b179348a36c5f2d9e954b773f5f90bff646` |
  | Node AMI | Karpenter alias `al2023@v20260923` |
  | Identity proxy | `docker.io/envoyproxy/envoy:distroless-v1.39.1@sha256:eb2c01c13125d1629637cb4e4cce7207009fb7cc2c8027f9742758549d15b6f4` |
  | OpenHands | `ghcr.io/openhands/agent-server:1.49.5-python@sha256:1e7b08ffef732d6520e0b0048931b6ef425a7742c5fb80a82c9397a285c669eb` |
  | octo-sts | `ghcr.io/octo-sts/app:0.10.0@sha256:921cd6711ac2ed99f9b12efb2c55372baa0ec4c4facead1eac55dd871e50ffa6` |
  | MCP | chart `flux-operator-mcp` `0.60.0`; `ghcr.io/victoriametrics/mcp-victoriametrics:v1.20.2@sha256:bcbf84f945d6efb03fb8b2d2ccc3294420dccdc0b445752dce96f02619416dfe`; `ghcr.io/victoriametrics/mcp-victorialogs:v1.9.0@sha256:753bb4fbe402ca1a782842f44636830f9895736f11d7fe783b924f8a0daf083d` |
  | gh CLI (harness) | `2.101.0`, sha256 amd64 `9bca2d1c16825f109907a23307628a2f0698fbf99662b73a5cf0b020293072b8`, arm64 `b57e8063f18862647c9d22727c32e9da1b963f8bf9db648fe123a6975695640f` |
  | Composition package | `v0.8.0` (phase 1), `v0.8.1` (phase 6, harness digest) |

  Digests were resolved on 2026-09-25 with `skopeo inspect --raw docker://<ref> | sha256sum`.
  Re-run that before pinning if a task lands later than a week after this date.
- **Constitution on every workload.** Default-deny CNP; requests **and** limits; liveness and readiness
  probes (plus startup where the spec lists one); restricted securityContext with
  `seccompProfile.type: RuntimeDefault` on every container (`infrastructure/AGENTS.md` traps). Runs
  get **no RBAC**. Constitution §7.1: nothing permanent is applied with `kubectl`; the spike and the
  verification probes are temporary and are deleted in the same task.
- **Evidence.** No "done / passing" without a command run in the same response and its output cited
  (`.agents/skills/ship-it/references/evidence.md`). In this repo: `./scripts/ci/validate-manifests.sh`
  → exit 0 and `Invalid: 0, Skipped: 0`, `task check` → exit 0, `./scripts/ci/validate-links.sh` →
  exit 0. In `Smana/crossplane-configuration`: `task check` → exit 0.
- **Git.** Every PR starts from a fresh worktree off `origin/main` (`EnterWorktree`, never
  `git checkout -b` in place). Rebase with `sync-branch` before every push; ship with `ship-it`.
  Conventional commits in English, **no `Co-Authored-By` trailer**, no generated-with line.
- **ADRs** use `website/content/docs/decisions/template.md`, numbers 0041, 0042, 0043, and add a row
  to `website/content/docs/decisions/_index.md`.

**Markers used below.** **[LIVE]** needs a running aws-0 cluster. **[OWNER]** is an action only the
owner can take; the executor stops and asks for it.

---

## Interfaces with other sub-projects

**Consumed from SP4 PR 1** (must be merged before phase 3 starts):

| Name | What |
|---|---|
| Flux Kustomization `ai-gateway` (`flux-system`) | The gateway umbrella, `clusters/aws-0/ai-gateway.yaml` → `./clusters/aws-0-ai-gateway`. Suspended by default (OD-3, amended 2026-09-26): resume it before `agent-platform` |
| Flux Kustomization `envoy-ai-gateway` (`flux-system`) | Moved into `ai-gateway`, name unchanged. Its health check is the Agent Router HelmRelease |
| GatewayClass `envoy-ai-gateway` | Controller `gateway.envoyproxy.io/gatewayclass-controller` |
| Gateway `ai-gateway` in `envoy-ai-gateway-system` | The human/system Gateway. SP4 PR 1 narrows the `envoy-data-plane` CNP to it (`owning-gateway-name: ai-gateway`); Task 3.5 only checks that |
| `x-ar-agent` → `ar_agent` metrics attribute | Set on the Agent Router controller, so it covers every Gateway of the class |

**Produced for SP4 PR 2 and for SP2/SP3:**

| Name | Where | Consumer |
|---|---|---|
| Gateway `agent-router` (`agent-system`), listeners `public` :8080 / `internal` :8081, `allowedRoutes: Same` | `infrastructure/base/agent-router/gateway.yaml` | SP4 attaches `agent-models-internal` and B1–B2 |
| `AIGatewayRoute agent-models` seeded with `agent-default` → `glm-5.2` | `infrastructure/base/agent-router/aigatewayroute-agent-models.yaml` | SP4 owns the file from PR 2 |
| `AIServiceBackend zai` + `BackendSecurityPolicy zai-api-key` | `infrastructure/base/agent-router/backend-zai.yaml` | SP4 tiers |
| Data-plane CNP `agent-router-data-plane` (`envoy-gateway-system`) | `infrastructure/base/agent-router/network-policy-data-plane.yaml` | SP4 PR 2 adds the Bedrock (`bedrock-runtime.eu-west-3.amazonaws.com:443`) and rate-limit egress; SP2's broker :8090 allow is already there |
| Flux Kustomization `agent-router` (`flux-system`), path `./infrastructure/base/agent-router`, `dependsOn` `envoy-ai-gateway`, `agent-secrets` | `clusters/aws-0-agent-platform/infrastructure-agent-router.yaml` | SP4 PR 2's children depend on it |
| `EnvoyProxy agent-router-proxy` (`agent-system`), no `envoyServiceAccount` | `infrastructure/base/agent-router/envoyproxy.yaml` | SP4 PR 2 sets `envoyServiceAccount.name: xplane-agent-router-bedrock` |
| `ClientTrafficPolicy agent-router` (early removal of the four identity headers) | `infrastructure/base/agent-router/clienttrafficpolicy.yaml` | SP4 relies on it |
| `SecretStore agents-secrets` (`agent-system`) | `security/base/agent-secrets/` | SP3 factory App key, SP4 Jev key |
| `MCPRoute agent-mcp-public` / `agent-mcp-internal` | `infrastructure/base/agent-mcp/mcproute-*.yaml` | SP2 adds the `room-broker` backend and the `room_*` rules |
| `AgentRun` XRD (`cloud.ogenki.io/v1alpha1`) | crossplane-configuration `apis/agentrun/` | SP2, SP3 |
| Kyverno `agentrun-admission` | `security/base/agent-policies/` | SP3 adds its one-creator rule beside it |

## Where this plan departed from the design's first draft

The design was amended on 2026-09-25 to record each of these; the table keeps the reasoning in one
place. The owner should still see each one in the PR that carries it.

| # | Design says | Plan does | Why |
|---|---|---|---|
| P1 | The composition maps `openhands` to the harness digest (phase 1); the image is built in phase 5 | CC-1 maps `openhands` to the upstream agent-server digest; CC-2 (phase 6) swaps in `agent-harness` | The composition is released four phases before PR 5 publishes the image (CI pushes on `main` only). The claim still never carries an image |
| P2 | The proxy ConfigMap ships in phase 5 | It ships in phase 2 (Task 2.4) | No sandbox pod starts without it, and SC-01 is phase 2's gate |
| P3 | A new role **and** policy in `opentofu/aws/openbao/management` | Policy there; the JWT role in `opentofu/aws/eks/configure/openbao.tf` | The per-cluster `jwt/<cluster>` mount and all its roles live in `configure` (the issuer changes per rebuild) |
| P4 | `agent-system` gets secrets only through `agents-secrets` | Plus one ExternalSecret copying the public OpenBao CA chain from `clustersecretstore` | A namespaced SecretStore reads its CA from its own namespace only; the chain is certificates, no credential |
| P5 | `status.reason` is `DeadlineExceeded` or `PodFailed` | Always `PodFailed` | agent-sandbox's `Finished` condition carries a fixed message, not the pod's reason (checked in `controllers/sandbox_controller.go@v1.0.3`) |
| P6 | The name shape is a Kyverno rule | Also an XRD root CEL rule; Kyverno additionally pins the namespace | The composition derives every name and audience from the name; `task check` then proves it offline |
| P7 | — | The profile carries `args: [--host, 0.0.0.0, --port, 8000]` | agent-server binds 127.0.0.1 when no session key is set, and kubelet probes the pod IP |
| P8 | `room-bridge` rendered with `roomRef`; `room_*` tools on both MCPRoutes | `roomRef` opens broker egress only; no bridge container, no room backend | Both belong to SP2 (image and broker); the extension points are named in the files |
| P9 | — | Additions: `agents` default-deny CNP; `spec.model` enum; immutability CEL; revocation and terminal phases latch; the aws package's core floor raised on each release | Each closes a gap the design implies (constitution §3.1; C5 names; SP2 S9; the Crossplane dependency trap) |
| P10 | One MCP allow rule per role | One rule per role **and backend** | Agent Router 1.1.0 caps a rule's target at 16 tools |
| P11 | `agent-platform` depends on `ai-gateway` | From phase 3 on | SP4 PR 1 lands before phase 3, not before phase 2 |
| P12 | Router egress pins the Gateway name; the ServiceAccount stays until revocation; phases latch loosely | CC-1 (reviews, 2026-09-25): router egress also pins `owning-gateway-namespace: agent-system`; terminal phase **and** reason latch; any terminal phase withholds the ServiceAccount; Succeeded/Failed Sandboxes are `operatingMode: Suspended`, stay Ready, and carry `agents.ogenki.io/finished-phase` | App claims can name a Gateway `agent-router` anywhere; agent-sandbox v1.0.3 recreates a missing pod even after the run finished, so a finished run must be unable to start again |
| P13 | Probes on Envoy admin `:9901`; agent-server on `0.0.0.0` (P7); profile partly mutable | Proxy probes and host ingress on a health listener `:9902` (`/ready`); admin on a **pathname** unix socket in `proxy-tmp` (never an abstract socket); the proxy runs `--disable-hot-restart --concurrency 1`, since hot restart opens an abstract socket and a `/dev/shm` segment the harness shares; agent-server on loopback with `exec` probes, `:8000` out of the CNP (reverses P7); every spec field immutable except `budget.maxTokens` | The harness shares the pod netns and could raise the admin log level to leak injected tokens; agent-sandbox never patches a live pod, so profile edits would only reach a recreated one. Phase 2's proxy ConfigMap must serve `:9902/ready` before any run uses the package |

## PR map

| # | Repo · branch | Phase | Merges after | Carries |
|---|---|---|---|---|
| PR 1 | this · `docs/agent-factory-design` | 0 | — | programme design, the four SP designs + research, **this plan**, the spike notes |
| CC-1 | crossplane-configuration · `feat/agentrun` | 1 | PR 1 | `apis/agentrun/`, then tag `v0.8.0` |
| PR 2 | this · `feat/agent-runtime` | 2 | CC-1 released | ADR-0041, umbrella, controller, pool, RuntimeClass, Kyverno, proxy ConfigMap, Vector toleration, pin `v0.8.0` |
| PR 3 | this · `feat/agent-router` | 3 | PR 2 **and SP4 PR 1** | ADR-0042, OpenBao role, `agents-secrets`, `agent-router` and its data-plane CNP |
| PR 4 | this · `feat/agent-github` | 4 | PR 3 | ADR-0043, octo-sts, trust policies, ruleset script |
| PR 5 | this · `feat/agent-harness` | 5 | PR 4 | `container-images/agent-harness`, MCP servers, MCPRoutes, probe |
| CC-2 | crossplane-configuration · `feat/agentrun-harness` | 6 | PR 5 (image published) | harness digest, tag `v0.8.1` |
| PR 6 | this · `feat/agent-e2e` | 6 | CC-2 released | pin `v0.8.1`, `task agent:run`, VMRules, dashboard, verification |

The spike (phase 0) lives on branch `spike/agent-gvisor`, which is **never merged**. PR 2 carries its
three manifest directories over with `git checkout spike/agent-gvisor -- <paths>` (Task 2.4).

## File structure

**`Smana/crossplane-configuration`**

| Path | Responsibility |
|---|---|
| `apis/agentrun/definition.yaml` | XRD: C3 fields, CEL (name shape, task, reviewer URL, immutability), status |
| `apis/agentrun/kcl/{main.k,main_test.k,kcl.mod,kcl.mod.lock,settings-example.yaml,README.md}` | The composition source, its tests and docs |
| `apis/agentrun/composition.yaml` | Generated by `task generate` |
| `examples/agentrun-{basic,complete}.yaml` + `tests/golden/agentrun-{basic,complete}.yaml` | Constitution §8.1 examples and their render fixtures |
| `scripts/generate.py`, `scripts/assemble.sh`, `packages/core/crossplane.yaml`, `README.md`, `CLAUDE.md` | Register the API in the core package |

**This repo**

| Path | Phase | Responsibility |
|---|---|---|
| `docs/superpowers/specs/2026-09-23-agent-runtime-identity-spike.md` | 0 | Spike results, one row per Q, decision gate |
| `namespaces/base/{agents,agent-system}.yaml` | 2 | The two namespaces |
| `clusters/aws-0/agent-platform.yaml`, `clusters/aws-0-agent-platform/{kustomization.yaml,README.md,*.yaml}` | 2–6 | Umbrella and one child Kustomization per directory below |
| `flux/sources/gitrepo-agent-sandbox.yaml` | 2 | agent-sandbox chart source, tag `v1.0.3` |
| `infrastructure/base/agent-sandbox/` | 2 | Controller HelmRelease, CNP, Crossplane aggregate ClusterRole |
| `infrastructure/base/karpenter-nodepools-agents/` | 0→2 | `agents-gvisor` NodePool + EC2NodeClass with the runsc user-data |
| `infrastructure/base/runtimeclass-gvisor/` | 0→2 | RuntimeClass `gvisor` → handler `runsc` |
| `infrastructure/base/agent-runtime/` | 0→2 | `agent-identity-proxy` ConfigMap and the `agents` default-deny CNP |
| `security/base/agent-policies/` | 2 | Kyverno policies and the cleanup RBAC |
| `scripts/ci/flux-schema/gen-catalog.sh` | 2 | Sandbox CRDs into the schema catalog |
| `observability/base/victoria-logs/vl-common-helm-values-configmap.yaml` | 2 | Vector toleration for the `agents` taint |
| `infrastructure/base/crossplane/configuration-aws/configuration-packages.yaml`, `apps/platform/app-wizard/app.yaml` | 2, 6 | Package pin and App Wizard tag, in lockstep |
| `opentofu/aws/openbao/management/{policies.tf,policies/agents-secrets.hcl}`, `opentofu/aws/eks/configure/openbao.tf` | 3 | OpenBao policy and JWT role for `agents-secrets` |
| `security/base/agent-secrets/` | 3 | SA, SecretStore `agents-secrets`, `openbao-ca` in `agent-system` |
| `infrastructure/base/agent-router/` | 3 | Gateway, EnvoyProxy, SecurityPolicies, CTP, Z.ai backend, `agent-models`, data-plane CNP |
| `security/base/octo-sts/` | 4 | octo-sts Deployment, Service, ExternalSecret, CNP |
| `.github/chainguard/agent-{implementer,reviewer,tester,triager}.sts.yaml` | 4 | Trust policies (gate path) |
| `.github/rulesets/agent-branches.json`, `scripts/ops/github/agent-branch-ruleset.sh`, `scripts/ci/tests/test-agent-branch-ruleset.sh` | 4 | Branch ruleset source, its idempotent applier, its test |
| `container-images/agent-harness/` | 5 | Harness image: `agent-run`, `git-credential-agent`, `gh` wrapper, trailer hook, tests |
| `flux/sources/ocirepo-flux-operator-mcp.yaml`, `infrastructure/base/agent-mcp/` | 5 | Three MCP servers, RBAC, CNPs, two MCPRoutes |
| `scripts/ops/k8s/agent-probe.yaml`, `scripts/ops/k8s/agent-probe-mcp.sh` | 3, 5 | Throwaway Sandbox holding three audiences, and its MCP client, for SC-05/07/12/17 |
| `scripts/ops/k8s/agent-run.sh`, `scripts/ci/tests/test-agent-run.sh`, `taskfile.yaml` | 6 | `task agent:run` |
| `observability/base/agent-platform/` | 6 | VMRules and the Grafana dashboard |
| `website/content/docs/decisions/004{1,2,3}-*.md` | 2, 3, 4 | ADRs |
| `docs/superpowers/specs/2026-09-23-agent-runtime-identity-verification.md` | 6 | `/verify-spec` output |

## Success criteria → proving task

| SC | Proved in | How |
|---|---|---|
| SC-01 gVisor pod, node, `dmesg` | 0.3 (spike), **2.9** | exec `dmesg`, jsonpath |
| SC-02 runsc in the v3 CRI table | 0.2 (spike), **2.9** | node debug shell |
| SC-03 admission denies bad pods and branches | 1.1 (CEL, offline), **2.9** | `kubectl apply --dry-run=server` |
| SC-04 implementer run → PR in ≤ 30 min | **6.7** | `kubectl get agentrun`, `gh pr list` |
| SC-05 `agent-router` 401 matrix, forged header | **3.8** | probe Sandbox, access log |
| SC-06 no 401 in a 45-min run (R2) | 0.3 (failed → R2), **6.7** | access log |
| SC-07 revocation timings | **6.8** | timestamps |
| SC-08 no API token, no API route | **5.6** | exec |
| SC-09 egress allowlist | 0.4 (spike), **6.7** | exec, `hubble observe --type l7` |
| SC-10 no key in `agents`, store scope | **3.8** | `kubectl get`, dry-run, `bao token capabilities` |
| SC-11 implementer vs reviewer vs other repo | **4.7** | git + octo-sts output |
| SC-12 MCP role gating, MCP SA RBAC | **5.6** | MCP error, `kubectl auth can-i` |
| SC-13 revocation + projection | 1.3 (offline), **6.8** | `kubectl annotate` |
| SC-14 nothing left after deletion | **6.8** | `kubectl get … -l agents.ogenki.io/run-id` |
| SC-15 `task check` ≤ 5× runc under gVisor | **0.5** (spike), re-read in 6.9 | timed runs |
| SC-16 `validate-manifests.sh` + upstream `task check` | every PR; recorded in **6.9** | exit codes |
| SC-17 `internal` never reaches Z.ai | **3.8** (listener), **5.6** (MCP tool list) | access log, Hubble, `tools/list` |

## Owner actions and live steps

| Marker | Task | What |
|---|---|---|
| [LIVE] | 0.2–0.5 | Spike on a spot aws-0 deployed from `main` |
| [LIVE] | 2.9, 3.8, 4.7, 5.6, 6.6–6.9 | Feature-branch cluster (`TF_VAR_flux_git_ref=refs/heads/<branch>`), umbrella resumed |
| [LIVE] | 3.2 | `terramate script run deploy` of `aws/openbao/management` and `aws/eks/configure` |
| [OWNER] | 3.3 | Create a dedicated Z.ai key and write it: `bao kv put platform/agents/zai api_key=<key>` |
| [OWNER] | 4.2 | Create the agents' GitHub App `ogenki-agents` on the user account `Smana`, install it on `Smana/cloud-native-ref` only (OD-6), write `bao kv put platform/agents/github-app app_id=<id> private_key=@<pem>` |
| [OWNER] | 4.7 | Run `task ops:github:agent-branch-ruleset -- Smana/cloud-native-ref` after PR 4 merges |
| [OWNER] | 6.7 | Point at (or open) a trivial issue for the SC-04 run |
| [OWNER] | 1.5, 6.1 | Merge CC-1 / CC-2 and push the `v0.8.0` / `v0.8.1` tags (the release workflow publishes) |

---
## Phase 0 — Spike (branch `spike/agent-gvisor`, never merged)

Answers Q1–Q6, Q8, Q9 (research table), R7 and the harness's writable paths, against the **exact**
manifests phase 2 ships. Results land in the spike notes, which travel in PR 1. If a result forces a
design change, amend the design in PR 1 too; the decision gate in Task 0.6 names the fallbacks.

| Check | Answers | Task |
|---|---|---|
| runsc in the v3 CRI table, pinned version; `bzip2` on the AMI; node Ready → first gVisor pod | SC-02, Q6, Q1 | 0.2 |
| gVisor banner; agent-server healthy (Q5: `oci-seccomp` off, gVisor #14688) | SC-01, Q5 | 0.3 |
| 45 min through `identity-proxy` against a JWT-validating upstream | Q2 (SC-06 mechanism) | 0.3 |
| The harness has no channel into the proxy (admin port, admin socket, hot-restart socket) | Q8 | 0.3 |
| A deleted sandbox pod is recreated | R7 | 0.3 |
| FQDN allow, deny, L7 DNS refusal, search path | Q3, Q4, SC-09 | 0.4 |
| Clone + `task check`, gVisor vs runc on one node | Q9, SC-15 | 0.5 |

### Task 0.1: Spike kit — the phase-2 manifests, plus throwaway fixtures

**Files** (all on branch `spike/agent-gvisor`; the first four directories are carried into PR 2
unchanged unless the spike corrects them):

> **The code in this task is the first draft.** The files on `spike/agent-gvisor` are authoritative:
> they carry the review rulings (admin on a unix socket, the `:9902` health listener, fail-closed
> user-data) and the spike's fixes (Envoy `node` identity for file SDS, AMI alias, `oci-seccomp` off,
> Cilium `devices`). Task 2.4 copies them from the branch, never from this text.
- Create: `namespaces/base/agents.yaml`, `namespaces/base/agent-system.yaml`
- Create: `infrastructure/base/runtimeclass-gvisor/{kustomization.yaml,runtimeclass.yaml}`
- Create: `infrastructure/base/karpenter-nodepools-agents/{kustomization.yaml,agents-gvisor-ec2nc.yaml,agents-gvisor-nodepool.yaml}`
- Create: `infrastructure/base/agent-runtime/{kustomization.yaml,identity-proxy-configmap.yaml,network-policy-default-deny.yaml}`
- Create: `spike/agent-runtime/{README.md,jwt-echo.yaml,agentrun-settings.yaml,bench.yaml,rotation.py}`

**Interfaces:**
- Produces: namespaces `agents`, `agent-system`; RuntimeClass `gvisor` (handler `runsc`, node label and
  taint `agents.ogenki.io/runtime=gvisor`); NodePool/EC2NodeClass `agents-gvisor`; ConfigMap
  `agents/agent-identity-proxy` with keys `envoy.yaml`, `sds-gateway.yaml`, `sds-sts.yaml`; CNP
  `agents/default-deny`. Task 2.4 carries these paths into PR 2.

- [ ] **Step 1: Create the worktree**

`EnterWorktree` with branch `spike/agent-gvisor` (it branches from `origin/main`).

- [ ] **Step 2: Namespaces**

`namespaces/base/agents.yaml`:

```yaml
# AgentRun claims and their sandbox pods, nothing else (C1). Every pod here runs
# under RuntimeClass gvisor, enforced by Kyverno (security/base/agent-policies).
apiVersion: v1
kind: Namespace
metadata:
  name: agents
  labels:
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/audit: restricted
    pod-security.kubernetes.io/warn: restricted
```

`namespaces/base/agent-system.yaml`:

```yaml
# The agent control plane: sandbox controller, octo-sts, MCP servers, and later
# the room broker and factory (C1). Its secrets come only through the namespaced
# `agents-secrets` store (security/base/agent-secrets).
apiVersion: v1
kind: Namespace
metadata:
  name: agent-system
  labels:
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/audit: restricted
    pod-security.kubernetes.io/warn: restricted
```

Add both to `namespaces/base/kustomization.yaml` `resources:` (alphabetical position is not
enforced; append after `llm.yaml`):

```yaml
  - agents.yaml
  - agent-system.yaml
```

- [ ] **Step 3: RuntimeClass**

`infrastructure/base/runtimeclass-gvisor/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

# aws-0 only. GKE Sandbox ships its own `gvisor` RuntimeClass (design, gcp-0 follow-up).
resources:
  - runtimeclass.yaml
```

`infrastructure/base/runtimeclass-gvisor/runtimeclass.yaml`:

```yaml
---
# `runsc` is registered in containerd's v3 CRI table by the agents-gvisor
# EC2NodeClass user-data. `scheduling` pins every gVisor pod to that pool, so a
# composed pod spec carries no nodeSelector or toleration of its own.
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata:
  name: gvisor
handler: runsc
scheduling:
  nodeSelector:
    agents.ogenki.io/runtime: gvisor
  tolerations:
    - key: agents.ogenki.io/runtime
      operator: Equal
      value: gvisor
      effect: NoSchedule
```

- [ ] **Step 4: NodePool and EC2NodeClass**

`infrastructure/base/karpenter-nodepools-agents/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: karpenter

# Gated by the agent-platform umbrella: sandbox capacity exists only when agents do.
resources:
  - agents-gvisor-nodepool.yaml
  - agents-gvisor-ec2nc.yaml
```

`infrastructure/base/karpenter-nodepools-agents/agents-gvisor-ec2nc.yaml`:

```yaml
# AL2023, not Bottlerocket: the one deliberate exception to the Bottlerocket rule
# (ADR-0041). Bottlerocket ships no runsc (bottlerocket-os/bottlerocket#811).
apiVersion: karpenter.k8s.aws/v1
kind: EC2NodeClass
metadata:
  name: agents-gvisor
spec:
  amiSelectorTerms:
    # The date must exist for the cluster's Kubernetes version, or Karpenter logs
    # "failed to discover any AMIs for alias" and the pool never gets a node
    # (v20260909 does not exist for 1.36). Check before bumping:
    #   aws ssm get-parameter --name /aws/service/eks/optimized-ami/<k8s>/amazon-linux-2023/x86_64/standard/recommended/release_version
    - alias: al2023@v20260923
  role: Karpenter-${cluster_name}
  kubelet:
    maxPods: 100
  metadataOptions:
    httpEndpoint: enabled
    httpProtocolIPv6: disabled
    # One hop: a pod, sandboxed or escaped into the pod netns, cannot reach IMDS.
    httpPutResponseHopLimit: 1
    httpTokens: required
  blockDeviceMappings:
    - deviceName: /dev/xvda
      ebs:
        volumeType: gp3
        volumeSize: 50Gi
        encrypted: true
        deleteOnTermination: true
  subnetSelectorTerms:
    - tags:
        karpenter.sh/discovery: ${environment}
  securityGroupSelectorTerms:
    - tags:
        karpenter.sh/discovery: ${cluster_name}
  tags:
    karpenter.sh/discovery: ${cluster_name}
  # Karpenter merges its own NodeConfig part into this MIME document. It closes
  # research pitfalls 1-3: the v3 CRI plugin id (the v2 one is accepted, ignored,
  # and the node still reports Ready) and gvisor-bin/ next to runsc.
  # oci-seccomp stays OFF (pitfall 4 reversed by the spike): runsc ignores
  # errnoRet (google/gvisor#14688), so RuntimeDefault's clone3 -> ENOSYS becomes
  # EPERM and no glibc >= 2.34 process can start a thread.
  # No shell variables on purpose: Flux postBuild would rewrite ${...} to "".
  userData: |
    MIME-Version: 1.0
    Content-Type: multipart/mixed; boundary="//"

    --//
    Content-Type: text/x-shellscript; charset="us-ascii"

    #!/bin/bash
    set -euo pipefail
    command -v bzip2 >/dev/null || dnf install -y bzip2
    curl -fsSLo /tmp/gvisor.tar.bz2 https://github.com/google/gvisor/releases/download/release-20260921.0/gvisor-x86_64.tar.bz2
    echo "3dd478770dd751d09c257ba14d739b179348a36c5f2d9e954b773f5f90bff646  /tmp/gvisor.tar.bz2" | sha256sum -c -
    tar -xjf /tmp/gvisor.tar.bz2 -C /usr/local/bin
    rm -f /tmp/gvisor.tar.bz2
    printf '[runsc_config]\n  oci-seccomp = "false"\n' > /etc/containerd/runsc.toml
    --//
    Content-Type: application/node.eks.aws

    apiVersion: node.eks.aws/v1alpha1
    kind: NodeConfig
    spec:
      containerd:
        config: |
          [plugins."io.containerd.cri.v1.runtime".containerd.runtimes.runsc]
            runtime_type = "io.containerd.runsc.v1"
          [plugins."io.containerd.cri.v1.runtime".containerd.runtimes.runsc.options]
            TypeUrl = "io.containerd.runsc.v1.options"
            ConfigPath = "/etc/containerd/runsc.toml"
    --//--
```

The tarball layout was checked on 2026-09-25: `runsc`, `containerd-shim-runsc-v1` and `gvisor-bin/`
at its root, sha256 as above.

`infrastructure/base/karpenter-nodepools-agents/agents-gvisor-nodepool.yaml`:

```yaml
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: agents-gvisor
spec:
  template:
    metadata:
      labels:
        agents.ogenki.io/runtime: gvisor
    spec:
      nodeClassRef:
        group: karpenter.k8s.aws
        kind: EC2NodeClass
        name: agents-gvisor
      taints:
        - key: agents.ogenki.io/runtime
          value: gvisor
          effect: NoSchedule
      startupTaints:
        - key: node.cilium.io/agent-not-ready
          value: "true"
          effect: NoExecute
      # Daily replacement also rolls out gVisor and AMI bumps.
      expireAfter: 24h
      requirements:
        - key: kubernetes.io/arch
          operator: In
          values: ["amd64"]
        - key: karpenter.sh/capacity-type
          operator: In
          values: ["spot"]
        - key: karpenter.k8s.aws/instance-category
          operator: In
          values: ["c", "m"]
        - key: karpenter.k8s.aws/instance-generation
          operator: Gt
          values: ["5"]
        - key: karpenter.k8s.aws/instance-cpu
          operator: Gt
          values: ["3"]
        - key: karpenter.k8s.aws/instance-cpu
          operator: Lt
          values: ["17"]
        # Nitro only, as on the other pools: Cilium ENI prefix delegation needs it.
        - key: karpenter.k8s.aws/instance-hypervisor
          operator: In
          values: ["nitro"]
        # A label pods select on must also be a requirement, or Karpenter never
        # matches the pool (research pitfall 5).
        - key: agents.ogenki.io/runtime
          operator: In
          values: ["gvisor"]
  disruption:
    # Runs are do-not-disrupt; consolidation would only ever find empty nodes.
    consolidationPolicy: WhenEmpty
    consolidateAfter: 5m
  limits:
    cpu: "16"
    memory: 64Gi
```

- [ ] **Step 5: identity-proxy ConfigMap and the `agents` default deny**

`infrastructure/base/agent-runtime/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

# Shared by every AgentRun sandbox. The per-run objects are composed by the
# AgentRun XR (Smana/crossplane-configuration apis/agentrun).
resources:
  - identity-proxy-configmap.yaml
  - network-policy-default-deny.yaml
```

`infrastructure/base/agent-runtime/network-policy-default-deny.yaml`:

```yaml
---
# Every pod in `agents` starts from deny-all in both directions. Each run's own
# CNP (composed with the run) adds exactly its allows; a pod with no run CNP
# reaches nothing. `- {}` selects no peer: it switches enforcement on and allows
# nothing.
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: default-deny
  namespace: agents
spec:
  endpointSelector: {}
  ingress:
    - {}
  egress:
    - {}
```

`infrastructure/base/agent-runtime/identity-proxy-configmap.yaml`:

```yaml
---
# The identity-proxy bootstrap shared by every AgentRun sandbox (design §3, S5).
# Envoy is the ONLY container that mounts the gateway and octo-sts tokens. The
# harness sees three localhost ports:
#   127.0.0.1:4000  /v1, /anthropic, /mcp  -> agent-router `public`   :8080
#   127.0.0.1:4002  /v1, /anthropic, /mcp  -> agent-router `internal` :8081
#   127.0.0.1:4001  /sts/exchange          -> octo-sts :8080
# A run's audience names its data class, so the other class's port earns a 401,
# and the run's CNP does not open it anyway.
#
# Rotation (Q2, failed under gVisor): kubelet rotates a projected token by
# swapping the volume's ..data symlink on the HOST, and gVisor raises no inotify
# for host-side changes, so `watched_directory` never fires inside the sandbox.
# The composition therefore gives each token the run's deadline as its TTL (R2);
# the watch stays for runtimes where inotify does work.
apiVersion: v1
kind: ConfigMap
metadata:
  name: agent-identity-proxy
  namespace: agents
data:
  sds-gateway.yaml: |
    resources:
      - "@type": type.googleapis.com/envoy.extensions.transport_sockets.tls.v3.Secret
        name: gateway-token
        generic_secret:
          secret:
            filename: /var/run/secrets/agents/gateway/token
  sds-sts.yaml: |
    resources:
      - "@type": type.googleapis.com/envoy.extensions.transport_sockets.tls.v3.Secret
        name: sts-token
        generic_secret:
          secret:
            filename: /var/run/secrets/agents/sts/token
  envoy.yaml: |
    admin:
      address:
        socket_address: {address: 0.0.0.0, port_value: 9901}
    static_resources:
      listeners:
        - name: public
          address:
            socket_address: {address: 127.0.0.1, port_value: 4000}
          filter_chains:
            - filters:
                - name: envoy.filters.network.http_connection_manager
                  typed_config:
                    "@type": type.googleapis.com/envoy.extensions.filters.network.http_connection_manager.v3.HttpConnectionManager
                    stat_prefix: public
                    stream_idle_timeout: 300s
                    route_config:
                      virtual_hosts:
                        - name: agent-router
                          domains: ["*"]
                          routes:
                            - {match: {prefix: /v1/}, route: {cluster: agent_router_public, timeout: 0s}}
                            - {match: {prefix: /anthropic/}, route: {cluster: agent_router_public, timeout: 0s}}
                            - {match: {prefix: /mcp}, route: {cluster: agent_router_public, timeout: 0s}}
                            - {match: {prefix: /}, direct_response: {status: 404}}
                    http_filters:
                      - name: envoy.filters.http.credential_injector
                        typed_config:
                          "@type": type.googleapis.com/envoy.extensions.filters.http.credential_injector.v3.CredentialInjector
                          overwrite: true
                          credential:
                            name: envoy.http.injected_credentials.generic
                            typed_config:
                              "@type": type.googleapis.com/envoy.extensions.http.injected_credentials.generic.v3.Generic
                              credential:
                                name: gateway-token
                                sds_config:
                                  path_config_source:
                                    path: /etc/envoy/sds-gateway.yaml
                                    watched_directory: {path: /var/run/secrets/agents/gateway}
                              header: Authorization
                              header_value_prefix: "Bearer "
                      - name: envoy.filters.http.router
                        typed_config:
                          "@type": type.googleapis.com/envoy.extensions.filters.http.router.v3.Router
        - name: internal
          address:
            socket_address: {address: 127.0.0.1, port_value: 4002}
          filter_chains:
            - filters:
                - name: envoy.filters.network.http_connection_manager
                  typed_config:
                    "@type": type.googleapis.com/envoy.extensions.filters.network.http_connection_manager.v3.HttpConnectionManager
                    stat_prefix: internal
                    stream_idle_timeout: 300s
                    route_config:
                      virtual_hosts:
                        - name: agent-router
                          domains: ["*"]
                          routes:
                            - {match: {prefix: /v1/}, route: {cluster: agent_router_internal, timeout: 0s}}
                            - {match: {prefix: /anthropic/}, route: {cluster: agent_router_internal, timeout: 0s}}
                            - {match: {prefix: /mcp}, route: {cluster: agent_router_internal, timeout: 0s}}
                            - {match: {prefix: /}, direct_response: {status: 404}}
                    http_filters:
                      - name: envoy.filters.http.credential_injector
                        typed_config:
                          "@type": type.googleapis.com/envoy.extensions.filters.http.credential_injector.v3.CredentialInjector
                          overwrite: true
                          credential:
                            name: envoy.http.injected_credentials.generic
                            typed_config:
                              "@type": type.googleapis.com/envoy.extensions.http.injected_credentials.generic.v3.Generic
                              credential:
                                name: gateway-token
                                sds_config:
                                  path_config_source:
                                    path: /etc/envoy/sds-gateway.yaml
                                    watched_directory: {path: /var/run/secrets/agents/gateway}
                              header: Authorization
                              header_value_prefix: "Bearer "
                      - name: envoy.filters.http.router
                        typed_config:
                          "@type": type.googleapis.com/envoy.extensions.filters.http.router.v3.Router
        - name: sts
          address:
            socket_address: {address: 127.0.0.1, port_value: 4001}
          filter_chains:
            - filters:
                - name: envoy.filters.network.http_connection_manager
                  typed_config:
                    "@type": type.googleapis.com/envoy.extensions.filters.network.http_connection_manager.v3.HttpConnectionManager
                    stat_prefix: sts
                    route_config:
                      virtual_hosts:
                        - name: octo-sts
                          domains: ["*"]
                          routes:
                            - {match: {prefix: /sts/exchange}, route: {cluster: octo_sts, timeout: 30s}}
                            - {match: {prefix: /}, direct_response: {status: 404}}
                    http_filters:
                      - name: envoy.filters.http.credential_injector
                        typed_config:
                          "@type": type.googleapis.com/envoy.extensions.filters.http.credential_injector.v3.CredentialInjector
                          overwrite: true
                          credential:
                            name: envoy.http.injected_credentials.generic
                            typed_config:
                              "@type": type.googleapis.com/envoy.extensions.http.injected_credentials.generic.v3.Generic
                              credential:
                                name: sts-token
                                sds_config:
                                  path_config_source:
                                    path: /etc/envoy/sds-sts.yaml
                                    watched_directory: {path: /var/run/secrets/agents/sts}
                              header: Authorization
                              header_value_prefix: "Bearer "
                      - name: envoy.filters.http.router
                        typed_config:
                          "@type": type.googleapis.com/envoy.extensions.filters.http.router.v3.Router
      clusters:
        - name: agent_router_public
          type: STRICT_DNS
          connect_timeout: 5s
          dns_lookup_family: V4_ONLY
          load_assignment:
            cluster_name: agent_router_public
            endpoints:
              - lb_endpoints:
                  - endpoint:
                      address:
                        socket_address: {address: agent-router.envoy-gateway-system.svc.cluster.local, port_value: 8080}
        - name: agent_router_internal
          type: STRICT_DNS
          connect_timeout: 5s
          dns_lookup_family: V4_ONLY
          load_assignment:
            cluster_name: agent_router_internal
            endpoints:
              - lb_endpoints:
                  - endpoint:
                      address:
                        socket_address: {address: agent-router.envoy-gateway-system.svc.cluster.local, port_value: 8081}
        - name: octo_sts
          type: STRICT_DNS
          connect_timeout: 5s
          dns_lookup_family: V4_ONLY
          load_assignment:
            cluster_name: octo_sts
            endpoints:
              - lb_endpoints:
                  - endpoint:
                      address:
                        socket_address: {address: octo-sts.agent-system.svc.cluster.local, port_value: 8080}
```

- [ ] **Step 6: Throwaway fixtures**

`spike/agent-runtime/README.md`:

```markdown
# SP1 phase-0 spike — never merged

Applied by hand to a throwaway aws-0 (constitution §7.1 allows it for a spike).
The manifests under namespaces/, infrastructure/base/{runtimeclass-gvisor,
karpenter-nodepools-agents,agent-runtime}/ are the phase-2 files, tested as-is.
Results: docs/superpowers/specs/2026-09-23-agent-runtime-identity-spike.md.
```

`spike/agent-runtime/jwt-echo.yaml` stands in for `agent-router`. It lives where the real data plane
will, carries the label the composed CNP selects, and validates the token exactly as
`SecurityPolicy` will: remote JWKS, exact audience. `__ISSUER__` and `__ISSUER_HOST__` are replaced in
Task 0.3.

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: jwt-echo
  namespace: envoy-gateway-system
data:
  envoy.yaml: |
    admin:
      address:
        socket_address: {address: 127.0.0.1, port_value: 9901}
    static_resources:
      listeners:
        - name: http
          address:
            socket_address: {address: 0.0.0.0, port_value: 8080}
          filter_chains:
            - filters:
                - name: envoy.filters.network.http_connection_manager
                  typed_config:
                    "@type": type.googleapis.com/envoy.extensions.filters.network.http_connection_manager.v3.HttpConnectionManager
                    stat_prefix: echo
                    access_log:
                      - name: envoy.access_loggers.stdout
                        typed_config:
                          "@type": type.googleapis.com/envoy.extensions.access_loggers.stream.v3.StdoutAccessLog
                    route_config:
                      virtual_hosts:
                        - name: all
                          domains: ["*"]
                          routes:
                            - match: {prefix: /}
                              direct_response: {status: 200, body: {inline_string: "ok\n"}}
                    http_filters:
                      - name: envoy.filters.http.jwt_authn
                        typed_config:
                          "@type": type.googleapis.com/envoy.extensions.filters.http.jwt_authn.v3.JwtAuthentication
                          providers:
                            eks:
                              issuer: __ISSUER__
                              audiences: [agent-router.implementer.public]
                              remote_jwks:
                                http_uri: {uri: __ISSUER__/keys, cluster: eks_oidc, timeout: 5s}
                                cache_duration: 300s
                          rules:
                            - match: {prefix: /}
                              requires: {provider_name: eks}
                      - name: envoy.filters.http.router
                        typed_config:
                          "@type": type.googleapis.com/envoy.extensions.filters.http.router.v3.Router
      clusters:
        - name: eks_oidc
          type: LOGICAL_DNS
          connect_timeout: 5s
          dns_lookup_family: V4_ONLY
          load_assignment:
            cluster_name: eks_oidc
            endpoints:
              - lb_endpoints:
                  - endpoint:
                      address:
                        socket_address: {address: __ISSUER_HOST__, port_value: 443}
          transport_socket:
            name: envoy.transport_sockets.tls
            typed_config:
              "@type": type.googleapis.com/envoy.extensions.transport_sockets.tls.v3.UpstreamTlsContext
              sni: __ISSUER_HOST__
              common_tls_context:
                validation_context:
                  trusted_ca: {filename: /etc/ssl/certs/ca-certificates.crt}
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: jwt-echo
  namespace: envoy-gateway-system
spec:
  replicas: 1
  selector:
    matchLabels: {app.kubernetes.io/name: jwt-echo}
  template:
    metadata:
      labels:
        app.kubernetes.io/name: jwt-echo
        # The label the composed run CNP selects (R5).
        gateway.envoyproxy.io/owning-gateway-name: agent-router
    spec:
      securityContext: {runAsNonRoot: true, runAsUser: 65532, seccompProfile: {type: RuntimeDefault}}
      containers:
        - name: envoy
          image: docker.io/envoyproxy/envoy:distroless-v1.39.1@sha256:eb2c01c13125d1629637cb4e4cce7207009fb7cc2c8027f9742758549d15b6f4
          args: ["-c", "/etc/envoy/envoy.yaml"]
          ports: [{containerPort: 8080}]
          readinessProbe: {tcpSocket: {port: 8080}}
          livenessProbe: {tcpSocket: {port: 8080}}
          resources: {requests: {cpu: 50m, memory: 64Mi}, limits: {cpu: 200m, memory: 128Mi}}
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities: {drop: ["ALL"]}
          volumeMounts: [{name: config, mountPath: /etc/envoy}]
      volumes: [{name: config, configMap: {name: jwt-echo}}]
---
# Named like the Service Envoy Gateway will create, so the identity-proxy
# ConfigMap is tested unchanged.
apiVersion: v1
kind: Service
metadata:
  name: agent-router
  namespace: envoy-gateway-system
spec:
  selector: {app.kubernetes.io/name: jwt-echo}
  ports:
    - {name: public, port: 8080, targetPort: 8080}
```

`spike/agent-runtime/agentrun-settings.yaml` (input to the phase-1 KCL, rendered locally in Task 0.3):

```yaml
kcl_options:
  - key: params
    value:
      oxr:
        apiVersion: cloud.ogenki.io/v1alpha1
        kind: AgentRun
        metadata:
          name: xplane-run-spk2test
          namespace: agents
          uid: 5f0c2a7e-1b3d-4c8a-9e6f-0d2b4a6c8e10
        spec:
          role: implementer
          repository: Smana/cloud-native-ref
          principal: "human:spike"
          dataClass: public
          budget: {maxMinutes: 180}
          task: {text: "Spike: idle."}
      ocds: {}
      dxr:
        apiVersion: cloud.ogenki.io/v1alpha1
        kind: AgentRun
        metadata: {name: xplane-run-spk2test, namespace: agents}
```

`spike/agent-runtime/rotation.py` (runs inside the harness container, Q2):

```python
"""45 minutes of requests through identity-proxy :4000. Any non-200 after the
first 600 s means the rotated token never reached the injector."""
import time
import urllib.error
import urllib.request

start, sent, bad = time.time(), 0, 0
while time.time() - start < 45 * 60:
    try:
        code = urllib.request.urlopen("http://127.0.0.1:4000/v1/models", timeout=10).status
    except urllib.error.HTTPError as err:
        code = err.code
    sent, bad = sent + 1, bad + (code != 200)
    print(time.strftime("%H:%M:%S"), code, flush=True)
    time.sleep(30)
print(f"RESULT requests={sent} non200={bad}", flush=True)
```

`spike/agent-runtime/bench.yaml` (Q9, SC-15). The same image as the harness, the same node, one
runtime at a time. `__NODE__` and `__RUNTIME__` are replaced in Task 0.5; the `runtimeClassName` line is deleted for the runc run.

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: agent-bench
  labels:
    pod-security.kubernetes.io/enforce: restricted
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: bench
  namespace: agent-bench
data:
  bench.sh: |
    #!/bin/bash
    set -uo pipefail
    export HOME=/work PATH=/work/bin:$PATH MISE_DATA_DIR=/work/mise MISE_CACHE_DIR=/work/cache
    mkdir -p /work/bin && cd /work
    t0=$(date +%s)
    git clone --depth 1 https://github.com/Smana/cloud-native-ref repo
    t1=$(date +%s)
    python3 -c "import urllib.request; urllib.request.urlretrieve('https://mise.jdx.dev/mise-latest-linux-x64', '/work/bin/mise')"
    chmod +x /work/bin/mise
    cd repo && mise trust -q . && mise install -q && mise exec -- flux plugin install schema
    t2=$(date +%s)
    mise exec -- task check > /work/check.log 2>&1; rc=$?
    t3=$(date +%s)
    tail -5 /work/check.log
    echo "RESULT runtime=${RUNTIME} clone=$((t1-t0)) setup=$((t2-t1)) check=$((t3-t2)) check_exit=${rc}"
---
apiVersion: v1
kind: Pod
metadata:
  name: bench
  namespace: agent-bench
spec:
  restartPolicy: Never
  runtimeClassName: gvisor
  nodeSelector:
    kubernetes.io/hostname: __NODE__
  tolerations:
    - {key: agents.ogenki.io/runtime, operator: Equal, value: gvisor, effect: NoSchedule}
  securityContext: {runAsNonRoot: true, runAsUser: 10001, seccompProfile: {type: RuntimeDefault}}
  containers:
    - name: bench
      image: ghcr.io/openhands/agent-server:1.49.5-python@sha256:1e7b08ffef732d6520e0b0048931b6ef425a7742c5fb80a82c9397a285c669eb
      command: ["bash", "/bench/bench.sh"]
      env: [{name: RUNTIME, value: __RUNTIME__}]
      resources: {requests: {cpu: "2", memory: 4Gi}, limits: {cpu: "2", memory: 4Gi}}
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities: {drop: ["ALL"]}
      volumeMounts:
        - {name: work, mountPath: /work}
        - {name: tmp, mountPath: /tmp}
        - {name: bench, mountPath: /bench}
  volumes:
    - {name: work, emptyDir: {sizeLimit: 20Gi}}
    - {name: tmp, emptyDir: {}}
    - {name: bench, configMap: {name: bench}}
```

- [ ] **Step 7: Render check and commit**

Run: `kubectl kustomize infrastructure/base/karpenter-nodepools-agents >/dev/null && kubectl kustomize infrastructure/base/agent-runtime >/dev/null && kubectl kustomize infrastructure/base/runtimeclass-gvisor >/dev/null && echo ok`
Expected: `ok`.

```bash
git add namespaces/base infrastructure/base/runtimeclass-gvisor infrastructure/base/karpenter-nodepools-agents infrastructure/base/agent-runtime spike/agent-runtime
git commit -m "chore(spike): agent sandbox runtime spike kit"
```

### Task 0.2: [LIVE] Node bring-up — Q1, Q6, SC-02

**Files:** none (results go to the notes in Task 0.6).

**Interfaces:**
- Consumes: Task 0.1 manifests. A spot aws-0 deployed from `main`.

- [ ] **Step 1: Deploy a cluster**

Run (repo root, `main` checked out and pulled — deploys apply the checkout's disk):
`cd opentofu && terramate script run deploy`
Expected: exit 0; `kubectl get nodes` lists Ready nodes; `flux get kustomizations -A` all `Ready=True`.

The deploy must carry Cilium `devices: "eth+ enp+ ens+ pod-id-link+"` in
`opentofu/aws/eks/init/helm_values/cilium.yaml` (spike commit `309fc246`, carried by Task 2.4). `eth+`
is Bottlerocket's naming; AL2023 names its ENIs `enpXsY`/`ens5`, so on the gVisor node Cilium
matches no ENI and crashloops on `unable to change MTU of link enp40s0 to 65520: invalid argument`,
and no pod ever starts there. On a cluster that predates it: apply the `eks/configure` stack, then
delete the crashing agent pod.

- [ ] **Step 2: Namespaces, controller, RuntimeClass, pool**

```bash
kubectl apply -f namespaces/base/agents.yaml -f namespaces/base/agent-system.yaml
git clone --quiet --depth 1 --branch v1.0.3 https://github.com/kubernetes-sigs/agent-sandbox /tmp/agent-sandbox
# agent-system enforces PSS restricted and the chart ships both security contexts null,
# so a bare install is rejected at admission. Same values as phase 2's HelmRelease.
helm install agent-sandbox /tmp/agent-sandbox/helm -n agent-system \
  --set namespace.create=false --set namespace.name=agent-system \
  --set image.tag=v1.0.3 --set controller.extensions=false -f - <<'EOF'
podSecurityContext: {runAsNonRoot: true, runAsUser: 65532, seccompProfile: {type: RuntimeDefault}}
containerSecurityContext:
  allowPrivilegeEscalation: false
  readOnlyRootFilesystem: true
  runAsNonRoot: true
  runAsUser: 65532
  capabilities: {drop: ["ALL"]}
  seccompProfile: {type: RuntimeDefault}
EOF
kubectl apply -k infrastructure/base/runtimeclass-gvisor
CLUSTER=$(kubectl get cm -n flux-system eks-aws-0-vars -o jsonpath='{.data.cluster_name}')
ENVIRONMENT=$(kubectl get cm -n flux-system eks-aws-0-vars -o jsonpath='{.data.environment}')
kubectl kustomize infrastructure/base/karpenter-nodepools-agents \
  | sed -e "s/\${cluster_name}/$CLUSTER/g" -e "s/\${environment}/$ENVIRONMENT/g" | kubectl apply -f -
kubectl get ec2nodeclass agents-gvisor -o jsonpath='{.status.amis[*].name}{"\n"}'
```
Expected: the controller pod `Running`; the EC2NodeClass lists an `al2023` AMI name containing
`20260923` (else the alias is wrong — fix it before anything else). An alias date never published
for the cluster's Kubernetes version fails only in the Karpenter log (`failed to discover any AMIs
for alias`); `v20260909` did not exist for 1.36. Check the date before pinning it:
`aws ssm get-parameter --name /aws/service/eks/optimized-ami/<k8s>/amazon-linux-2023/x86_64/standard/recommended/release_version`.

- [ ] **Step 3: Provoke a node and time it (Q1)**

```bash
kubectl apply -k infrastructure/base/agent-runtime
kubectl -n agents run q1 --image=docker.io/envoyproxy/envoy:distroless-v1.39.1@sha256:eb2c01c13125d1629637cb4e4cce7207009fb7cc2c8027f9742758549d15b6f4 \
  --overrides='{"spec":{"runtimeClassName":"gvisor","automountServiceAccountToken":false,"securityContext":{"runAsNonRoot":true,"runAsUser":10001,"seccompProfile":{"type":"RuntimeDefault"}},"containers":[{"name":"q1","image":"docker.io/envoyproxy/envoy:distroless-v1.39.1@sha256:eb2c01c13125d1629637cb4e4cce7207009fb7cc2c8027f9742758549d15b6f4","args":["--version"],"resources":{"requests":{"cpu":"10m","memory":"32Mi"},"limits":{"cpu":"100m","memory":"64Mi"}},"securityContext":{"allowPrivilegeEscalation":false,"readOnlyRootFilesystem":true,"capabilities":{"drop":["ALL"]}}}]}}' \
  --restart=Never
kubectl wait -n agents pod/q1 --for=jsonpath='{.status.phase}'=Succeeded --timeout=15m
NODE=$(kubectl get pod -n agents q1 -o jsonpath='{.spec.nodeName}')
kubectl get node "$NODE" -o jsonpath='{range .status.conditions[?(@.type=="Ready")]}{.lastTransitionTime}{"\n"}{end}'
kubectl get pod -n agents q1 -o jsonpath='{.status.containerStatuses[0].state.terminated.startedAt}{"\n"}'
kubectl get events -n agents --field-selector involvedObject.name=q1,reason=FailedCreatePodSandBox -o name | wc -l
```
Record: node Ready time, container start time, their difference, and the `FailedCreatePodSandBox`
count (Q1: expected small and self-healing). Then `kubectl delete pod -n agents q1`.

- [ ] **Step 4: Inspect the node (SC-02, Q6)**

```bash
# Non-interactive, then read the logs. `general`, not `sysadmin`: sysadmin needs kubectl >= 1.30,
# and chroot /host only reads here. containerd 2 dumps plugin ids single-quoted.
kubectl debug node/"$NODE" -n default --profile=general --image=public.ecr.aws/amazonlinux/amazonlinux:2023 -- chroot /host bash -c '
  /usr/local/bin/runsc --version | head -1
  ls /usr/local/bin/containerd-shim-runsc-v1 /usr/local/bin/gvisor-bin
  containerd config dump | grep -A4 "runtimes.runsc"
  cat /etc/containerd/runsc.toml
  rpm -q bzip2; grep -c "dnf install -y bzip2" /var/log/cloud-init-output.log'
sleep 20; kubectl logs -n default "$(kubectl get pods -n default -o name | grep node-debugger | head -1)"
kubectl get pods -n default -o name | grep node-debugger | xargs -r kubectl delete -n default
```
Expected: `runsc version release-20260921.0`; the runsc runtime under the **v3** plugin id with
`ConfigPath = "/etc/containerd/runsc.toml"`; `oci-seccomp = "false"`. Record whether `bzip2` was
preinstalled (Q6: `rpm -q` succeeds and the `dnf` line count is 0) or installed by the script.

### Task 0.3: [LIVE] Sandbox, proxy and tokens — SC-01, Q5, Q2, Q8, R7

**Files:** none.

**Interfaces:**
- Consumes: the composition source from **Task 1.2 Step 2** (`kcl.mod`) and **Task 1.3 Step 1**
  (`main.k`), rendered locally; Task 0.1 fixtures.

- [ ] **Step 1: Render the run exactly as the composition will**

```bash
mkdir -p /tmp/agentrun-kcl
# Write kcl.mod (Task 1.2 Step 2) and main.k (Task 1.3 Step 1) into /tmp/agentrun-kcl first.
kcl run /tmp/agentrun-kcl -Y spike/agent-runtime/agentrun-settings.yaml -o /tmp/agentrun-render.yaml
python3 -c 'import yaml; d=yaml.safe_load(open("/tmp/agentrun-render.yaml")); print(yaml.safe_dump_all([i for i in d["items"] if i["kind"] != "AgentRun"]))' > /tmp/agentrun-spike.yaml
grep -c '^kind:' /tmp/agentrun-spike.yaml
```
Expected: `4` (ServiceAccount, ConfigMap, CiliumNetworkPolicy, Sandbox).

- [ ] **Step 2: Stand-in gateway, then the run**

```bash
ISSUER=$(kubectl get --raw /.well-known/openid-configuration | jq -r .issuer)
ISSUER_HOST=${ISSUER#https://}; ISSUER_HOST=${ISSUER_HOST%%/*}
sed -e "s#__ISSUER__#$ISSUER#g" -e "s#__ISSUER_HOST__#$ISSUER_HOST#g" spike/agent-runtime/jwt-echo.yaml | kubectl apply -f -
kubectl apply -f /tmp/agentrun-spike.yaml
kubectl wait -n agents sandbox/xplane-run-spk2test --for=condition=Ready --timeout=15m
POD=xplane-run-spk2test
```
Expected: the Sandbox is `Ready`. If it is not, read `kubectl describe pod -n agents $POD`: an
`identity-proxy` crash is a proxy-config defect (fix `identity-proxy-configmap.yaml` on the spike
branch, it ships in PR 2), a harness `CrashLoopBackOff` on a read-only path is the "writable paths"
finding below.

- [ ] **Step 3: SC-01 and Q5**

```bash
kubectl get pod -n agents $POD -o jsonpath='{.spec.runtimeClassName} {.spec.nodeName}{"\n"}'
kubectl get node "$(kubectl get pod -n agents $POD -o jsonpath='{.spec.nodeName}')" -o jsonpath='{.metadata.labels.agents\.ogenki\.io/runtime}{"\n"}'
kubectl exec -n agents $POD -c harness -- dmesg | head -3
kubectl exec -n agents $POD -c harness -- grep Seccomp /proc/self/status
```
Expected: `gvisor <node>`, `gvisor`, a `Starting gVisor...` banner line, and `Seccomp: 0`: `oci-seccomp` is off until gVisor honours
`errnoRet` (#14688; with it on, runsc answers `clone3` with EPERM and no glibc ≥ 2.34 process can start
a thread). Record all four lines.

- [ ] **Step 4: Writable paths and entrypoint facts**

```bash
kubectl logs -n agents $POD -c harness | grep -iE "read-only|permission denied" | head
kubectl exec -n agents $POD -c harness -- /usr/local/bin/python -c "import importlib.util as u; print(u.find_spec('openhands.sdk'))"
```
Expected: no read-only errors (the composition mounts `/workspace`, `/home/openhands`, `/tmp`), and
`None`: the published image is upstream's PyInstaller binary target, so its Python cannot import the
SDK and `/agent-server/.venv` does not exist (Task 5.1 installs it). Record any path that needed a
mount; Task 1.3 adds it before CC-1 merges.

- [ ] **Step 5: Q2 — 45 minutes across four rotations**

```bash
kubectl cp spike/agent-runtime/rotation.py agents/$POD:/tmp/rotation.py -c harness
kubectl exec -n agents $POD -c harness -- /usr/local/bin/python /tmp/rotation.py | tee /tmp/q2.log | tail -3
```
Expected: `RESULT requests=90 non200=0` (±1 request): the rendered run's tokens live until its
deadline (R2), longer than the test. The spike ran this at a 600 s TTL and got 401 `Jwt is expired`
from minute ~10: gVisor raises no inotify for kubelet's host-side rotation, so `watched_directory`
never reloads. The proxy's admin stats are deliberately unreachable from the harness (P13).

- [ ] **Step 6: Q8 — the harness has no channel into the proxy**

```bash
kubectl exec -n agents $POD -c harness -- /usr/local/bin/python -c "import socket,os; s=socket.socket(); r=s.connect_ex(('127.0.0.1',9901)); print('9901:', 'refused' if r else 'OPEN'); print('admin socket visible:', os.path.exists('/tmp/envoy-admin.sock')); print('hot-restart socket:', 'envoy_domain_socket' in open('/proc/net/unix').read())"
```
Expected: `9901: refused`, `admin socket visible: False`, `hot-restart socket: False`. Any other
answer means a control channel from the harness into the only token holder: stop and fix the
bootstrap or the composition's proxy args before Task 0.4.

- [ ] **Step 7: R7 — is a deleted pod recreated?**

```bash
kubectl delete pod -n agents $POD --wait=true
sleep 20; kubectl get pod -n agents $POD -o jsonpath='{.metadata.creationTimestamp}{"\n"}'
```
Record: recreated (timestamp printed) or not (`NotFound`). Either is acceptable; the notes say which,
and `agent-run` already resumes an existing branch (Task 5.1).

### Task 0.4: [LIVE] Egress — Q3, Q4, SC-09

**Files:** none.

- [ ] **Step 1: Allowed, denied, and refused names**

```bash
kubectl wait -n agents sandbox/xplane-run-spk2test --for=condition=Ready --timeout=10m
POD=xplane-run-spk2test
kubectl exec -n agents $POD -c harness -- git ls-remote https://github.com/Smana/cloud-native-ref HEAD
kubectl exec -n agents $POD -c harness -- /usr/local/bin/python -c "import urllib.request; urllib.request.urlopen('https://example.com', timeout=5)" ; echo "exit=$?"
kubectl exec -n agents $POD -c harness -- /usr/local/bin/python -c "import socket, secrets; socket.getaddrinfo(secrets.token_hex(6)+'.example.org', 443)" ; echo "exit=$?"
kubectl exec -n agents $POD -c harness -- /usr/local/bin/python -c "import socket; print(socket.getaddrinfo('api.github.com', 443)[0][4])"
```
Expected: a `HEAD` SHA; `exit=1` for example.com; `exit=1` for the random name; an IP for
`api.github.com` (Q4: a bare public name resolves with `ndots:1` despite the refused search-path
variants).

- [ ] **Step 2: Hubble verdicts (Q3)**

```bash
NODE=$(kubectl get pod -n agents $POD -o jsonpath='{.spec.nodeName}')
AGENT=$(kubectl get pods -n kube-system -l k8s-app=cilium --field-selector spec.nodeName=$NODE -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n kube-system $AGENT -- hubble observe --from-pod agents/$POD --type l7 --protocol dns --last 30
kubectl exec -n kube-system $AGENT -- hubble observe --from-pod agents/$POD --verdict DROPPED --last 30
```
Expected: DNS `REFUSED`/denied for `*.example.org` and `example.com`; forwarded answers for
`github.com` names; `DROPPED` TCP towards example.com's IPs. Record the lines. **Decision:** if an
allowed FQDN is dropped, Q3 failed → Task 0.6 fallback.

- [ ] **Step 3: Clean up the run**

```bash
kubectl delete -f /tmp/agentrun-spike.yaml
kubectl delete -f spike/agent-runtime/jwt-echo.yaml
```

### Task 0.5: [LIVE] File-I/O benchmark — Q9, SC-15; teardown

**Files:** none.

- [ ] **Step 1: gVisor run**

```bash
NODE=$(kubectl get nodes -l agents.ogenki.io/runtime=gvisor -o jsonpath='{.items[0].metadata.name}')
sed -e "s/__NODE__/$NODE/" -e "s/__RUNTIME__/gvisor/" spike/agent-runtime/bench.yaml | kubectl apply -f -
kubectl wait -n agent-bench pod/bench --for=jsonpath='{.status.phase}'=Succeeded --timeout=90m
kubectl logs -n agent-bench bench | grep RESULT
kubectl delete pod -n agent-bench bench
```

- [ ] **Step 2: runc run, same node, same image**

```bash
sed -e "s/__NODE__/$NODE/" -e "s/__RUNTIME__/runc/" -e "/runtimeClassName: gvisor/d" spike/agent-runtime/bench.yaml | kubectl apply -f -
kubectl wait -n agent-bench pod/bench --for=jsonpath='{.status.phase}'=Succeeded --timeout=90m
kubectl logs -n agent-bench bench | grep RESULT
```
Expected: two `RESULT` lines. SC-15 ratio = `(clone+check)` gVisor ÷ `(clone+check)` runc; pass is
≤ 5. `setup` is network-bound and recorded but not in the ratio. **Decision:** ratio > 5 → R1 fallback
(Task 0.6).

- [ ] **Step 3: Teardown**

```bash
kubectl delete ns agent-bench
kubectl delete -k infrastructure/base/agent-runtime
helm uninstall agent-sandbox -n agent-system
kubectl kustomize infrastructure/base/karpenter-nodepools-agents | kubectl delete -f -
kubectl delete -k infrastructure/base/runtimeclass-gvisor
kubectl delete ns agents agent-system
kubectl get nodes -l agents.ogenki.io/runtime=gvisor
```
Expected: `No resources found` for the last command within 10 minutes. Destroy the cluster if it is
not reused for PR 2 (`task ops:teardown`).

### Task 0.6: Spike notes, decision gate, and PR 1

**Files:**
- Create: `docs/superpowers/specs/2026-09-23-agent-runtime-identity-spike.md` (on branch
  `docs/agent-factory-design`, the PR-1 branch that already carries the designs and this plan)
- Modify (only if a check failed): `docs/superpowers/specs/2026-09-23-agent-runtime-identity-design.md`

- [ ] **Step 1: Write the notes**

```markdown
# SP1 spike — results

**Date:** <run date> · **Cluster:** aws-0, spot, deployed from `main` at <sha> · **Kit:** branch
`spike/agent-gvisor` at <sha> (never merged)

| # | Question | Result | Evidence (command → output) | Consequence |
|---|---|---|---|---|
| Q1 | kubelet vs user-data race | <Ready→start seconds>, <n> FailedCreatePodSandBox | Task 0.2 Step 3 | none / … |
| Q2 | rotation reaches the injector | <RESULT line>, update_success=<n> | Task 0.3 Step 5 | none / R2 |
| Q3 | FQDN + DNS proxy under gVisor, ENI, KPR | <verdicts> | Task 0.4 Step 2 | none / … |
| Q4 | refused search-path names | <api.github.com resolved?> | Task 0.4 Step 1 | none / … |
| Q5 | `oci-seccomp` accepted, harness healthy | `Seccomp: <n>` | Task 0.3 Step 3 | none / … |
| Q6 | `bzip2` on the AMI | preinstalled / installed by user-data | Task 0.2 Step 4 | none |
| Q8 | harness → proxy channels | 9901 / admin socket / hot-restart socket | Task 0.3 Step 6 | none — P13 already closes all three; a finding means the bootstrap or proxy args regressed |
| Q9 | gVisor ÷ runc (clone + check) | <ratio> (<gvisor>s / <runc>s), setup <g>s / <r>s | Task 0.5 | none / R1 |
| R7 | deleted pod recreated | yes / no | Task 0.3 Step 7 | — |
| — | writable paths the harness needed | <list or none> | Task 0.3 Step 4 | folded into Task 1.3 |
| SC-01 | gVisor banner, runtime class, node label | <lines> | Task 0.3 Step 3 | — |
| SC-02 | runsc in the v3 table at the pin | <lines> | Task 0.2 Step 4 | — |
| SC-09 | allow / deny / L7 refusal | <lines> | Task 0.4 | — |
| SC-15 | ≤ 5× | pass / fail | Task 0.5 | — |
```

- [ ] **Step 2: Apply the decision gate**

| Failed check | Change, made in PR 1 (design) and carried by the named task |
|---|---|
| Q2 | R2: `expirationSeconds` = the run deadline on **both** tokens (the octo-sts token rotates the same way). Amend design §3 and T8, and programme C3; Task 1.3 derives it from `maxMinutes` |
| Q5 | `oci-seccomp` off: runsc turns RuntimeDefault's `clone3` ENOSYS into EPERM (gVisor #14688), so no thread starts. Amend design S4, §1, T2 and ADR-0041 |
| harness SDK | The published agent-server image is the binary target with no importable SDK: Task 5.1 installs it into `/agent-server/.venv` |
| Q8 | Already applied up front (P13): admin on a pathname socket in `proxy-tmp`, probes on `:9902` with the `health_check` filter, `--disable-hot-restart`. If Step 6 still finds a channel, fix the bootstrap or the proxy args before PR 2 |
| Q3/Q4 | Stop and raise it with the owner: the egress design (S10) does not hold under gVisor |
| Q9 | R1: an in-memory `/workspace` (`medium: Memory`) for `small` runs. Amend design §2; Task 1.3 |
| writable path | Add an `emptyDir` in Task 1.3 before CC-1 merges |

**Applied 2026-09-26** ([spike notes](../specs/2026-09-23-agent-runtime-identity-spike.md)): Q2 → R2 on
both tokens (CC-1 `299eb6d`); Q5 → `oci-seccomp` off (`spike/agent-gvisor` `bf82940f`); harness SDK →
Task 5.1. Q1, Q3, Q4, Q6, Q8, Q9 and R7 passed; no writable path was missing.

- [ ] **Step 3: Validate and commit**

Run: `./scripts/ci/validate-links.sh`
Expected: exit 0.

```bash
git add docs/superpowers/specs/2026-09-23-agent-runtime-identity-spike.md docs/superpowers/specs/2026-09-23-agent-runtime-identity-design.md
git commit -m "docs(superpowers): SP1 spike results"
```

- [ ] **Step 4: Open PR 1**

Use `ship-it` on branch `docs/agent-factory-design`. The PR carries the programme design, the four
SP designs and research files, this plan and the spike notes. The body links the SP1 design and the
spike notes. Docs PRs wait for the owner's review.

---
## Phase 1 — `AgentRun` in `Smana/crossplane-configuration` (CC-1)

Runs in `/home/smana/Sources/crossplane-configuration`, in a fresh worktree off `origin/main`
(branch `feat/agentrun`). Gate: `task check` exit 0. Read that repo's `CLAUDE.md` and
`.claude/rules/kcl.md` first: `composition.yaml` is generated, never edit it; `kcl fmt` must leave the
tree clean; never mutate a dict after creation; single-line list comprehensions.

The KCL and XRD below were run on 2026-09-25 against KCL 0.11.3 and `flux schema validate` 2.9: 28/28
tests pass, `kcl fmt` is a no-op, the 22 existing examples plus the two new ones validate, and the
negative claims in Task 1.1 fail for the intended reasons. Only the golden renders need Docker.

### Task 1.1: XRD and examples

**Files:**
- Create: `apis/agentrun/definition.yaml`
- Create: `examples/agentrun-basic.yaml`, `examples/agentrun-complete.yaml`

**Interfaces:**
- Produces: `agentruns.cloud.ogenki.io/v1alpha1`, namespaced. Spec fields `role`, `repository`,
  `baseRef`, `branch`, `task.{text,url}`, `principal`, `model`, `dataClass`,
  `budget.{maxTokens,maxMinutes}`, `harness`, `size`, `egress.profiles`, `roomRef`, `queueName`. Status
  `phase`, `runId`, `branch`, `conversationId`, `startedAt`, `finishedAt`, `reason`, `pullRequest`,
  `usage.tokens`. Tasks 1.2–1.4 and phases 2–6 use exactly these names.

- [ ] **Step 1: Write the examples first**

`examples/agentrun-basic.yaml`:

```yaml
---
# Basic AgentRun: an implementer on public data, with task text.
#
# The owner creates runs directly until SP3's factory ships (C3); the runId is
# 8 characters of [a-z2-7], generated by the creator (`task agent:run`).
apiVersion: cloud.ogenki.io/v1alpha1
kind: AgentRun
metadata:
  name: xplane-run-7f3cq2xz
  namespace: agents
spec:
  role: implementer
  repository: Smana/cloud-native-ref
  principal: "human:312345678901234567"
  dataClass: public
  task:
    text: "Fix the broken relative link in docs/superpowers/README.md."
```

`examples/agentrun-complete.yaml`:

```yaml
---
# Complete AgentRun: every field, plus the annotations SP3's run meter and
# factory write, so the golden render proves they are projected into status.
apiVersion: cloud.ogenki.io/v1alpha1
kind: AgentRun
metadata:
  name: xplane-run-k2m4q7wa
  namespace: agents
  labels:
    agents.ogenki.io/task: t-9f2kq3ma
  annotations:
    agents.ogenki.io/usage-tokens: "184223"
    agents.ogenki.io/pull-request: "https://github.com/Smana/cloud-native-ref/pull/2090"
spec:
  role: tester
  repository: Smana/cloud-native-ref
  baseRef: agent/t-9f2kq3ma
  branch: agent/t-9f2kq3ma
  principal: "system:factory"
  model: tier-standard
  dataClass: internal
  task:
    url: "https://github.com/Smana/cloud-native-ref/pull/2090"
  budget:
    maxTokens: 3000000
    maxMinutes: 240
  harness: openhands
  size: medium
  egress:
    profiles: [pypi, golang]
  roomRef: r-3kq9x2ma
  queueName: agents-standard
```

- [ ] **Step 2: Run the schema gate to see it fail**

Run: `task schema`
Expected: FAIL — the two new claims have no schema (`skip-missing-schemas` is off), so
`flux schema validate` reports them.

- [ ] **Step 3: Write the XRD**

`apis/agentrun/definition.yaml`:

```yaml
apiVersion: apiextensions.crossplane.io/v2
kind: CompositeResourceDefinition
metadata:
  name: agentruns.cloud.ogenki.io
spec:
  group: cloud.ogenki.io
  scope: Namespaced
  names:
    kind: AgentRun
    plural: agentruns
  versions:
    - name: v1alpha1
      served: true
      referenceable: true
      additionalPrinterColumns:
        - name: Role
          type: string
          jsonPath: .spec.role
        - name: Class
          type: string
          jsonPath: .spec.dataClass
        - name: Phase
          type: string
          jsonPath: .status.phase
        - name: Branch
          type: string
          jsonPath: .status.branch
      schema:
        openAPIV3Schema:
          type: object
          x-kubernetes-validations:
            # The composition derives the runId from the name, and every composed
            # name, audience and octo-sts subject pattern depends on this shape (C2).
            - rule: "self.metadata.name.matches('^xplane-run-[a-z2-7]{8}$')"
              message: "an AgentRun is named xplane-run-<runId>, runId being 8 characters of [a-z2-7]"
          properties:
            spec:
              type: object
              required: [role, repository, principal, dataClass, task]
              x-kubernetes-validations:
                - rule: "self.role != 'reviewer' || (has(self.task.url) && self.task.url.matches('^https://github\\\\.com/[^/]+/[^/]+/pull/[0-9]+$'))"
                  message: "a reviewer run needs a pull request URL as its task"
                - rule: "!has(self.task.url) || self.task.url.startsWith('https://github.com/' + self.repository + '/')"
                  message: "task.url must point into spec.repository"
              properties:
                role:
                  description: The run's one role (C2). A policy input, not an identity.
                  type: string
                  enum: [implementer, reviewer, tester, triager]
                  x-kubernetes-validations:
                    - {rule: "self == oldSelf", message: "role is immutable"}
                repository:
                  description: The single GitHub repository this run may touch, as owner/name.
                  type: string
                  pattern: '^[A-Za-z0-9-]+/[A-Za-z0-9._-]+$'
                  x-kubernetes-validations:
                    - {rule: "self == oldSelf", message: "repository is immutable"}
                baseRef:
                  description: Branch or commit the harness clones.
                  type: string
                  default: main
                  maxLength: 255
                branch:
                  description: |
                    The one branch an implementer pushes. Derived by the factory, never
                    by a caller: agent/<taskId>, agent/<roomId>, else agent/<runId>.
                    Defaults to agent/<runId> in the composition.
                  type: string
                  pattern: '^agent/[a-z0-9][a-z0-9._/-]{0,100}$'
                  x-kubernetes-validations:
                    - {rule: "self == oldSelf", message: "branch is immutable"}
                task:
                  description: Exactly one of text or url.
                  type: object
                  x-kubernetes-validations:
                    - rule: "(has(self.text) ? 1 : 0) + (has(self.url) ? 1 : 0) == 1"
                      message: "set exactly one of task.text or task.url"
                    - {rule: "self == oldSelf", message: "task is immutable"}
                  properties:
                    text:
                      type: string
                      maxLength: 16384
                    url:
                      description: A GitHub issue or pull request.
                      type: string
                      pattern: '^https://github\.com/[A-Za-z0-9-]+/[A-Za-z0-9._-]+/(issues|pull)/[0-9]+$'
                principal:
                  description: Accountable principal, human:<zitadel sub> or system:<component> (C3).
                  type: string
                  pattern: '^(human:[A-Za-z0-9@._-]+|system:[a-z0-9-]+)$'
                  x-kubernetes-validations:
                    - {rule: "self == oldSelf", message: "principal is immutable"}
                model:
                  description: A logical model name (C5), resolved by the class's listener.
                  type: string
                  enum: [agent-default, tier-light, tier-standard, tier-frontier]
                  default: agent-default
                dataClass:
                  description: |
                    public or internal. Picks the gateway audience, proxy port and listener,
                    and which MCP tools the run sees. No default: classifying data is a decision.
                  type: string
                  enum: [public, internal]
                  x-kubernetes-validations:
                    - {rule: "self == oldSelf", message: "dataClass is immutable"}
                budget:
                  type: object
                  default: {}
                  properties:
                    maxTokens:
                      description: Per-run cap. The maximum equals the gateway's per-run ceiling (C3, C5).
                      type: integer
                      default: 2000000
                      minimum: 1
                      maximum: 5000000
                    maxMinutes:
                      description: Becomes activeDeadlineSeconds.
                      type: integer
                      default: 120
                      minimum: 1
                      maximum: 480
                harness:
                  description: A platform profile; the composition maps it to an image digest.
                  type: string
                  enum: [openhands]
                  default: openhands
                size:
                  description: small/medium/large = 1->2 / 2->4 / 4->8 CPU, 2 GiB per CPU, 10/20/40 Gi scratch.
                  type: string
                  enum: [small, medium, large]
                  default: small
                egress:
                  type: object
                  default: {}
                  properties:
                    profiles:
                      description: FQDN profiles on top of github, which is always on.
                      type: array
                      default: []
                      maxItems: 4
                      x-kubernetes-list-type: set
                      items:
                        type: string
                        enum: [pypi, npm, golang, crates]
                roomRef:
                  description: Optional room this run joins (SP2).
                  type: string
                  pattern: '^r-[a-z0-9]{8}$'
                queueName:
                  description: Kueue LocalQueue, set as the queue label on the sandbox pod (SP3).
                  type: string
                  maxLength: 63
            status:
              type: object
              properties:
                phase:
                  type: string
                  enum: [Pending, Running, Succeeded, Failed, BudgetExhausted, Revoked]
                runId:
                  type: string
                branch:
                  type: string
                conversationId:
                  type: string
                startedAt:
                  type: string
                finishedAt:
                  type: string
                reason:
                  type: string
                pullRequest:
                  type: string
                usage:
                  type: object
                  properties:
                    tokens:
                      type: integer
          required:
            - spec
```

- [ ] **Step 4: Run the schema gate to see it pass**

Run: `task schema`
Expected: `Valid: 22, Invalid: 0, Skipped: 0` and `22 example claim(s) valid against 7 shipped XRD(s)`.

- [ ] **Step 5: Prove the CEL rules reject what they must (SC-03, branch half)**

Write `/tmp/agentrun-bad.yaml`:

```yaml
apiVersion: cloud.ogenki.io/v1alpha1
kind: AgentRun
metadata: {name: xplane-run-7f3cq2xz, namespace: agents}
spec: {role: implementer, repository: Smana/cloud-native-ref, principal: "human:1", dataClass: public, branch: main, task: {text: x}}
---
apiVersion: cloud.ogenki.io/v1alpha1
kind: AgentRun
metadata: {name: run-1, namespace: agents}
spec: {role: reviewer, repository: Smana/cloud-native-ref, principal: "human:1", dataClass: public, task: {text: x, url: "https://github.com/Other/repo/issues/1"}}
---
apiVersion: cloud.ogenki.io/v1alpha1
kind: AgentRun
metadata: {name: xplane-run-abcdefgh, namespace: agents}
spec: {role: reviewer, repository: Smana/cloud-native-ref, principal: "system:factory", dataClass: public, task: {url: "https://github.com/Smana/cloud-native-ref/issues/12"}}
```

Run: `flux schema validate --schema-location build/schemas /tmp/agentrun-bad.yaml`
Expected: `Valid: 0, Invalid: 3`, with messages naming `/spec/branch` pattern, the `xplane-run-` name
rule, "a reviewer run needs a pull request URL as its task" (twice), "task.url must point into
spec.repository" and "set exactly one of task.text or task.url".

- [ ] **Step 6: Commit**

```bash
git add apis/agentrun/definition.yaml examples/agentrun-basic.yaml examples/agentrun-complete.yaml
git commit -m "feat(agentrun): AgentRun XRD and examples"
```

### Task 1.2: KCL module scaffold and failing tests

**Files:**
- Create: `apis/agentrun/kcl/kcl.mod`, `apis/agentrun/kcl/kcl.mod.lock` (empty),
  `apis/agentrun/kcl/settings-example.yaml`, `apis/agentrun/kcl/main_test.k`

**Interfaces:**
- Consumes: Task 1.1 field names.
- Produces: tests that call `_render(oxr, ocds, dxr) -> [any]`, returning ServiceAccount, ConfigMap,
  CiliumNetworkPolicy, Sandbox (the first and last omitted when revoked) and the XR carrying `status`.

- [ ] **Step 1: Settings**

`apis/agentrun/kcl/settings-example.yaml`:

```yaml
kcl_options:
  - key: params
    value:
      oxr:
        apiVersion: cloud.ogenki.io/v1alpha1
        kind: AgentRun
        metadata:
          name: xplane-run-7f3cq2xz
          namespace: agents
          uid: 0b3c6f0e-5d1a-4b8e-9f41-2a7c3e9d8b10
        spec:
          role: implementer
          repository: Smana/cloud-native-ref
          principal: "human:312345678901234567"
          dataClass: public
          task:
            text: "Fix the broken link in docs/README.md."
      ocds: {}
      dxr:
        apiVersion: cloud.ogenki.io/v1alpha1
        kind: AgentRun
        metadata:
          name: xplane-run-7f3cq2xz
          namespace: agents
```

- [ ] **Step 2: Module file**

`apis/agentrun/kcl/kcl.mod`:

```toml
[package]
name = "agentrun"
edition = "v0.11.3"
version = "0.1.0"
description = "AgentRun composition (Agent Factory SP1): one gVisor-sandboxed agent run - ServiceAccount, task ConfigMap, CiliumNetworkPolicy, Sandbox"
```

Create `apis/agentrun/kcl/kcl.mod.lock` empty, as `apis/kvstore/kcl/kcl.mod.lock` is.

- [ ] **Step 3: The tests**

`apis/agentrun/kcl/main_test.k`:

```kcl
# Tests for the AgentRun composition. Run: kcl test . -Y settings-example.yaml
#
# Every variant calls _render directly with a synthetic XR, so one run covers
# the phase table, revocation, projection and both data classes whatever
# settings-example.yaml holds.
_NAME = "xplane-run-7f3cq2xz"
_BASE_SPEC = {
    role = "implementer"
    repository = "Smana/cloud-native-ref"
    principal = "human:312345678901234567"
    dataClass = "public"
    task = {text = "Fix the broken link in docs/README.md."}
}
_DXR = {apiVersion = "cloud.ogenki.io/v1alpha1", kind = "AgentRun", metadata = {name = _NAME, namespace = "agents"}}

_xr = lambda spec: any, annotations: any, labels: any, status: any -> any {
    {
        metadata = {name = _NAME, namespace = "agents", uid = "0b3c6f0e-5d1a-4b8e-9f41-2a7c3e9d8b10", annotations = annotations, labels = labels}
        spec = _BASE_SPEC | spec
        status = status
    }
}

_run = lambda spec: any -> [any] {
    _render(_xr(spec, {}, {}, {}), {}, _DXR)
}

_tokenTTLs = lambda spec: any -> [int] {
    _vols = {v.name: v for v in _pod(_run(spec)).volumes}
    [_vols[n].projected.sources[0].serviceAccountToken.expirationSeconds for n in ["gateway-token", "sts-token"]]
}

_kind = lambda res: [any], kind: str -> [any] {
    [r for r in res if r.kind == kind]
}

_status = lambda res: [any] -> any {
    _kind(res, "AgentRun")[0].status
}

_pod = lambda res: [any] -> any {
    _kind(res, "Sandbox")[0].spec.podTemplate.spec
}

_sandboxWith = lambda conditions: [any] -> any {
    {
        "xplane-run-7f3cq2xz-sandbox" = {
            Resource = {metadata = {creationTimestamp = "2026-09-25T10:00:00Z"}, status = {conditions = conditions}}
        }
    }
}

_phaseFor = lambda annotations: any, status: any, observed: any -> str {
    _status(_render(_xr({}, annotations, {}, status), observed, _DXR)).phase
}

test_renders_four_resources_and_status = lambda {
    _res = _run({})
    assert [r.kind for r in _res] == ["ServiceAccount", "ConfigMap", "CiliumNetworkPolicy", "Sandbox", "AgentRun"]
}

test_names_labels_and_principal = lambda {
    _res = _run({})
    assert [r.metadata.name for r in _res if r.kind != "AgentRun"] == [_NAME, _NAME + "-task", _NAME, _NAME]
    _composed = [r for r in _res if r.kind != "AgentRun"]
    assert all r in _composed {
        r.metadata.labels["agents.ogenki.io/run-id"] == "7f3cq2xz" and r.metadata.labels["agents.ogenki.io/role"] == "implementer" and r.metadata.annotations["agents.ogenki.io/principal"] == "human:312345678901234567"
    }
}

test_task_label_propagates_from_the_claim = lambda {
    _res = _render(_xr({}, {}, {"agents.ogenki.io/task" = "t-9f2k"}, {}), {}, _DXR)
    assert _kind(_res, "Sandbox")[0].spec.podTemplate.metadata.labels["agents.ogenki.io/task"] == "t-9f2k"
    assert "agents.ogenki.io/task" not in _kind(_run({}), "Sandbox")[0].metadata.labels
}

test_service_account_has_no_token = lambda {
    assert _kind(_run({}), "ServiceAccount")[0].automountServiceAccountToken == False
}

test_pod_shape = lambda {
    _sbx = _kind(_run({}), "Sandbox")[0]
    _p = _sbx.spec.podTemplate.spec
    assert _sbx.spec.service == False, "nothing dials into a sandbox (C4)"
    assert _p.runtimeClassName == "gvisor"
    assert _p.automountServiceAccountToken == False
    assert _p.serviceAccountName == _NAME
    assert _p.restartPolicy == "Never"
    assert _p.activeDeadlineSeconds == 7200, "maxMinutes defaults to 120"
    assert _p.dnsConfig.options == [{name = "ndots", value = "1"}]
    assert _p.shareProcessNamespace == False
    assert _p.securityContext.runAsUser == 10001 and _p.securityContext.runAsNonRoot == True
    assert _sbx.spec.podTemplate.metadata.annotations["karpenter.sh/do-not-disrupt"] == "true"
    _all = _p.containers + _p.initContainers
    assert all c in _all {
        c.securityContext.allowPrivilegeEscalation == False and c.securityContext.readOnlyRootFilesystem == True and c.securityContext.capabilities.drop == ["ALL"] and c.securityContext.seccompProfile.type == "RuntimeDefault" and c.resources.limits.cpu and c.resources.limits.memory
    }
}

test_only_the_proxy_mounts_tokens = lambda {
    _p = _pod(_run({}))
    _proxy = _p.initContainers[0]
    assert _proxy.name == "identity-proxy" and _proxy.restartPolicy == "Always", "native sidecar"
    assert sorted([m.name for m in _proxy.volumeMounts if m.name.endswith("-token")]) == ["gateway-token", "sts-token"]
    _containers = _p.containers
    assert not any c in _containers {
        any m in c.volumeMounts {
            m.name.endswith("-token")
        }
    }, "the harness never holds a token (S5)"
}

test_token_audiences_and_ttl = lambda {
    _vols = {v.name: v for v in _pod(_run({})).volumes}
    _gw = _vols["gateway-token"].projected.sources[0].serviceAccountToken
    _sts = _vols["sts-token"].projected.sources[0].serviceAccountToken
    assert _gw.audience == "agent-router.implementer.public"
    assert _sts.audience == "octo-sts/Smana/cloud-native-ref/implementer"
}

# R2 (SP1 spike Q2): gVisor raises no inotify for kubelet's host-side rotation, so the
# proxy never reloads a rotated token. Both tokens outlive the run instead.
test_tokens_outlive_the_run = lambda {
    assert _tokenTTLs({}) == [7200, 7200], "maxMinutes defaults to 120"
    assert _tokenTTLs({budget = {maxMinutes = 480}}) == [28800, 28800], "the XRD's maximum"
    assert _tokenTTLs({budget = {maxMinutes = 5}}) == [600, 600], "the apiserver's floor"
}

test_data_class_picks_port_and_audience = lambda {
    _res = _run({role = "tester", dataClass = "internal", task = {url = "https://github.com/Smana/cloud-native-ref/pull/2081"}})
    _env = {e.name: e.value for e in _pod(_res).containers[0].env}
    assert _env.LLM_BASE_URL == "http://127.0.0.1:4002/v1"
    assert _env.MCP_URL == "http://127.0.0.1:4002/mcp"
    _router = [e for e in _kind(_res, "CiliumNetworkPolicy")[0].spec.egress if e.toEndpoints and e.toEndpoints[0].matchLabels["io.kubernetes.pod.namespace"] == "envoy-gateway-system"][0]
    assert _router.toPorts[0].ports == [{port = "8081", protocol = "TCP"}], "internal runs reach only the internal listener"
    assert {v.name: v for v in _pod(_res).volumes}["gateway-token"].projected.sources[0].serviceAccountToken.audience == "agent-router.tester.internal"
}

test_public_run_reaches_only_the_public_listener = lambda {
    _egress = _kind(_run({}), "CiliumNetworkPolicy")[0].spec.egress
    _ports = [p.port for e in _egress if e.toEndpoints and e.toEndpoints[0].matchLabels["io.kubernetes.pod.namespace"] == "envoy-gateway-system" for t in e.toPorts for p in t.ports]
    assert _ports == ["8080"]
}

test_cnp_is_default_deny_with_named_egress = lambda {
    _spec = _kind(_run({
        egress = {profiles = ["pypi"]}
    }), "CiliumNetworkPolicy")[0].spec
    assert _spec.ingress == [{fromEntities = ["host"], toPorts = [{ports = [{port = "8000", protocol = "TCP"}, {port = "9901", protocol = "TCP"}]}]}]
    _fqdn = [e for e in _spec.egress if e.toFQDNs][0]
    assert [f.matchName for f in _fqdn.toFQDNs] == ["github.com", "api.github.com", "codeload.github.com", "objects.githubusercontent.com", "raw.githubusercontent.com", "pypi.org", "files.pythonhosted.org"]
    _dns = [n.matchName for n in _spec.egress[0].toPorts[0].rules.dns]
    assert "agent-router.envoy-gateway-system.svc.cluster.local" in _dns and "pypi.org" in _dns
    _dnsRules = _spec.egress[0].toPorts[0].rules.dns
    _egressRules = _spec.egress
    assert not any n in _dnsRules {
        "matchPattern" in n
    }, "the DNS rule answers allowlisted names only"
    assert not any e in _egressRules {
        "toEntities" in e
    }, "no world, no kube-apiserver"
}

test_room_ref_adds_broker_egress = lambda {
    _egress = _kind(_run({roomRef = "r-3kq9x2ma"}), "CiliumNetworkPolicy")[0].spec.egress
    assert any e in _egress {
        e.toEndpoints and e.toEndpoints[0].matchLabels["app.kubernetes.io/name"] == "room-broker" and e.toPorts[0].ports[0].port == "8443"
    }
    _plain = _kind(_run({}), "CiliumNetworkPolicy")[0].spec.egress
    assert not any e in _plain {
        e.toEndpoints and e.toEndpoints[0].matchLabels["app.kubernetes.io/name"] == "room-broker"
    }
}

test_size_presets = lambda {
    _small = _pod(_run({})).containers[0].resources
    _large = _pod(_run({size = "large"})).containers[0].resources
    assert _small.requests.cpu == "1" and _small.limits.cpu == "2" and _small.limits.memory == "4Gi"
    assert _large.requests.cpu == "4" and _large.limits.cpu == "8" and _large.limits.memory == "16Gi" and _large.limits["ephemeral-storage"] == "40Gi"
}

test_branch_defaults_to_run_id = lambda {
    assert _status(_run({})).branch == "agent/7f3cq2xz"
    assert _status(_run({branch = "agent/t-9f2k"})).branch == "agent/t-9f2k"
    assert {e.name: e.value for e in _pod(_run({branch = "agent/t-9f2k"})).containers[0].env}.BRANCH == "agent/t-9f2k"
}

test_queue_label = lambda {
    assert _kind(_run({queueName = "agents-standard"}), "Sandbox")[0].spec.podTemplate.metadata.labels["kueue.x-k8s.io/queue-name"] == "agents-standard"
}

test_rules_depend_on_role = lambda {
    _impl = _kind(_run({}), "ConfigMap")[0].data["rules.md"]
    _rev = _kind(_run({role = "reviewer", task = {url = "https://github.com/Smana/cloud-native-ref/pull/1"}}), "ConfigMap")[0].data["rules.md"]
    assert "Push only to agent/7f3cq2xz" in _impl
    assert "read-only" in _rev and "Push only" not in _rev
}

# ---- Phase table, rows 1-6 (design §2) ----
test_phase_pending_without_sandbox = lambda {
    assert _phaseFor({}, {}, {}) == "Pending"
}

test_phase_running = lambda {
    assert _phaseFor({}, {}, _sandboxWith([{type = "Ready", status = "True"}])) == "Running"
}

test_phase_succeeded = lambda {
    assert _phaseFor({}, {}, _sandboxWith([{type = "Ready", status = "False"}, {type = "Finished", status = "True", reason = "PodSucceeded", lastTransitionTime = "2026-09-25T10:20:00Z"}])) == "Succeeded"
}

test_phase_failed_with_reason = lambda {
    _res = _render(_xr({}, {}, {}, {}), _sandboxWith([{type = "Finished", status = "True", reason = "PodFailed", lastTransitionTime = "2026-09-25T12:00:00Z"}]), _DXR)
    assert _status(_res).phase == "Failed"
    assert _status(_res).reason == "PodFailed"
    assert _status(_res).startedAt == "2026-09-25T10:00:00Z"
    assert _status(_res).finishedAt == "2026-09-25T12:00:00Z"
}

test_phase_revoked_budget_wins_over_manual_and_success = lambda {
    _done = _sandboxWith([{type = "Finished", status = "True", reason = "PodSucceeded"}])
    assert _phaseFor({"agents.ogenki.io/revoked" = "budget-run"}, {}, _done) == "BudgetExhausted"
    assert _phaseFor({"agents.ogenki.io/revoked" = "manual"}, {}, _done) == "Revoked"
}

test_unknown_revocation_reason_is_ignored = lambda {
    assert _phaseFor({"agents.ogenki.io/revoked" = "because"}, {}, {}) == "Pending"
}

test_revocation_latches = lambda {
    assert _phaseFor({}, {phase = "Revoked"}, {}) == "Revoked", "removing the annotation never resurrects a run"
    assert _phaseFor({}, {phase = "BudgetExhausted"}, {}) == "BudgetExhausted"
    assert _phaseFor({}, {phase = "Succeeded"}, {}) == "Succeeded", "a vanished Sandbox does not regress status"
}

# ---- SC-13 offline: revocation drops the identity and the sandbox ----
test_revoked_run_keeps_only_its_record = lambda {
    _res = _render(_xr({}, {"agents.ogenki.io/revoked" = "budget-run"}, {}, {}), {}, _DXR)
    assert [r.kind for r in _res] == ["ConfigMap", "CiliumNetworkPolicy", "AgentRun"]
    assert _status(_res).phase == "BudgetExhausted" and _status(_res).reason == "budget-run"
}

# ---- SC-13 offline: annotation projection ----
test_valid_annotations_are_projected = lambda {
    _res = _render(_xr({}, {"agents.ogenki.io/usage-tokens" = "123456", "agents.ogenki.io/pull-request" = "https://github.com/Smana/cloud-native-ref/pull/2090"}, {}, {}), {}, _DXR)
    assert _status(_res).usage.tokens == 123456
    assert _status(_res).pullRequest == "https://github.com/Smana/cloud-native-ref/pull/2090"
}

test_malformed_annotations_are_not_projected = lambda {
    _bad = {"agents.ogenki.io/usage-tokens" = "-5", "agents.ogenki.io/pull-request" = "https://github.com/Evil/cloud-native-ref/pull/1"}
    _fresh = _status(_render(_xr({}, _bad, {}, {}), {}, _DXR))
    assert "usage" not in _fresh and "pullRequest" not in _fresh
    _kept = _status(_render(_xr({}, _bad, {}, {usage = {tokens = 42}, pullRequest = "https://github.com/Smana/cloud-native-ref/pull/7"}), {}, _DXR))
    assert _kept.usage.tokens == 42 and _kept.pullRequest == "https://github.com/Smana/cloud-native-ref/pull/7", "the last valid value stays"
}

test_pull_request_regex_escapes_the_repository = lambda {
    _res = _render(_xr({repository = "Smana/a.b"}, {"agents.ogenki.io/pull-request" = "https://github.com/Smana/aXb/pull/1"}, {}, {}), {}, _DXR)
    assert "pullRequest" not in _status(_res)
}

test_readiness_follows_the_sandbox = lambda {
    _pending = _kind(_run({}), "Sandbox")[0].metadata.annotations
    assert "krm.kcl.dev/ready" not in _pending
    _done = _render(_xr({}, {}, {}, {}), _sandboxWith([{type = "Finished", status = "True", reason = "PodSucceeded"}]), _DXR)
    assert _kind(_done, "Sandbox")[0].metadata.annotations["krm.kcl.dev/ready"] == "True"
}

test_harness_binds_for_probes = lambda {
    assert _pod(_run({})).containers[0].args == ["--host", "0.0.0.0", "--port", "8000"]
}
```

- [ ] **Step 4: Run them to see them fail**

Run: `cd apis/agentrun/kcl && kcl test . -Y settings-example.yaml`
Expected: FAIL — `name '_render' is not defined` (there is no `main.k` yet).

### Task 1.3: The composition

**Files:**
- Create: `apis/agentrun/kcl/main.k`

**Interfaces:**
- Consumes: Task 1.2 tests; the identity-proxy ConfigMap name `agent-identity-proxy` and its ports
  (Task 0.1 Step 5); the Service FQDNs `agent-router.envoy-gateway-system.svc.cluster.local` (Task 3.4)
  and `octo-sts.agent-system.svc.cluster.local` (Task 4.3); pod label
  `app.kubernetes.io/name: octo-sts` (Task 4.3); Gateway label
  `gateway.envoyproxy.io/owning-gateway-name: agent-router` (R5, confirmed in Task 3.8).
- Produces: composition-resource names `<xr>-sa`, `<xr>-task`, `<xr>-cnp`, `<xr>-sandbox`; the
  harness env contract of design §5 (`RUN_ID ROLE REPOSITORY BASE_REF BRANCH MODEL DATA_CLASS
  CONVERSATION_ID LLM_BASE_URL MCP_URL STS_URL TASK_FILE RULES_FILE HOME`), consumed by Task 5.1.

- [ ] **Step 1: Write `main.k`**

Apply any writable-path finding from the spike notes (Task 0.6) as an extra `emptyDir` before
committing.

```kcl
# AgentRun composition: one sandboxed coding-agent run (SP1 of the Agent Factory
# programme, cloud-native-ref docs/superpowers/specs/2026-09-23-agent-runtime-identity-design.md).
#
# Renders, all named xplane-run-<runId>[-suffix] in the claim's namespace:
#   ServiceAccount       no RBAC anywhere, automount off      (not when revoked)
#   ConfigMap -task      task, platform rules, run metadata
#   CiliumNetworkPolicy  default-deny, class-scoped gateway port, FQDN profiles
#   Sandbox              agents.x-k8s.io/v1beta1 under gVisor (not when revoked)
# and patches the XR status.
#
# Status has ONE writer, this composition (C3). Controllers write annotations;
# they are validated here before anything reaches status.
#
# Conditional resources are single-element lists joined at the end. Nothing is
# mutated after creation (function-kcl #285).
import json
import regex

oxr = option("params").oxr
ocds = option("params").ocds

# The only place a harness profile becomes an image (S7): the claim never
# carries one, so bumping a digest is a release of this package.
_HARNESS_PROFILES = {
    openhands = {
        image = "ghcr.io/openhands/agent-server:1.49.5-python@sha256:1e7b08ffef732d6520e0b0048931b6ef425a7742c5fb80a82c9397a285c669eb"
        port = 8000
        # agent-server binds 127.0.0.1 unless told otherwise, and kubelet probes
        # the pod IP. The CNP admits only `host` on this port.
        args = ["--host", "0.0.0.0", "--port", "8000"]
    }
}
_IDENTITY_PROXY_IMAGE = "docker.io/envoyproxy/envoy:distroless-v1.39.1@sha256:eb2c01c13125d1629637cb4e4cce7207009fb7cc2c8027f9742758549d15b6f4"

# spec.size: CPU request -> limit, 2 GiB per CPU, scratch for /workspace.
_SIZES = {
    small = {cpu = ["1", "2"], memory = ["2Gi", "4Gi"], scratch = "10Gi"}
    medium = {cpu = ["2", "4"], memory = ["4Gi", "8Gi"], scratch = "20Gi"}
    large = {cpu = ["4", "8"], memory = ["8Gi", "16Gi"], scratch = "40Gi"}
}

_EGRESS_PROFILES = {
    github = ["github.com", "api.github.com", "codeload.github.com", "objects.githubusercontent.com", "raw.githubusercontent.com"]
    pypi = ["pypi.org", "files.pythonhosted.org"]
    npm = ["registry.npmjs.org"]
    golang = ["proxy.golang.org", "sum.golang.org"]
    crates = ["index.crates.io", "static.crates.io"]
}

# Fully qualified, so ndots:1 sends them to kube-dns as-is and the L7 DNS rule
# can answer exactly these names (Q4).
_ROUTER_FQDN = "agent-router.envoy-gateway-system.svc.cluster.local"
_STS_FQDN = "octo-sts.agent-system.svc.cluster.local"
_BROKER_FQDN = "room-broker.agent-system.svc.cluster.local"

# One agent-router listener per data class (S6): the port IS the class.
_ROUTER_PORT = {public = 8080, internal = 8081}
_PROXY_PORT = {public = 4000, internal = 4002}

_BUDGET_REASONS = ["budget-run", "budget-principal", "budget-fleet"]
_REVOKE_REASONS = _BUDGET_REASONS + ["manual"]

_CONTAINER_SECURITY = {
    allowPrivilegeEscalation = False
    readOnlyRootFilesystem = True
    runAsNonRoot = True
    capabilities = {drop = ["ALL"]}
    seccompProfile = {type = "RuntimeDefault"}
}

_get = lambda d: any, k: str -> any {
    d[k] if d and k in d else None
}

_condition = lambda obj: any, ctype: str -> any {
    _matches = [c for c in obj?.status?.conditions or [] if c?.type == ctype]
    _matches[0] if _matches else None
}

_observed = lambda state: any, key: str -> any {
    state[key]?.Resource if state and key in state else None
}

# Phase, top-down (design §2). Revocation and terminal phases latch on the
# previous status, so removing an annotation never resurrects a run.
_phaseOf = lambda annotations: any, previous: str, sandbox: any -> str {
    _revoked = _get(annotations, "agents.ogenki.io/revoked") or ""
    _finished = _condition(sandbox, "Finished")
    _ready = _condition(sandbox, "Ready")
    "BudgetExhausted" if _revoked in _BUDGET_REASONS or previous == "BudgetExhausted" else "Revoked" if _revoked == "manual" or previous == "Revoked" else previous if previous in ["Succeeded", "Failed"] else "Succeeded" if _finished?.status == "True" and _finished?.reason == "PodSucceeded" else "Failed" if _finished?.status == "True" and _finished?.reason == "PodFailed" else "Running" if _ready?.status == "True" else "Pending"
}

# A malformed annotation is never projected; the last valid value stays.
_usageTokens = lambda annotations: any, previous: any -> any {
    _v = _get(annotations, "agents.ogenki.io/usage-tokens")
    int(_v) if _v and regex.match(_v, "^[0-9]{1,12}$") else previous
}

_pullRequest = lambda annotations: any, repository: str, previous: any -> any {
    _v = _get(annotations, "agents.ogenki.io/pull-request")
    _v if _v and regex.match(_v, "^https://github\\.com/" + repository.replace(".", "\\.") + "/pull/[0-9]+$") else previous
}

_rulesFor = lambda role: str, runId: str, repository: str, branch: str, baseRef: str -> str {
    _write = "2. Push only to {}. Never push to any other branch, and never merge.\n3. Open at most one pull request, from {} into {}. If it already exists, update it.\n".format(branch, branch, baseRef)
    _read = "2. Your repository access is read-only. Do not push. Your final message is your report.\n"
    "Platform rules for run {} ({}) on {}. The platform enforces each of them independently of you.\n1. Work in /workspace/repo, cloned from {} at {}.\n".format(runId, role, repository, repository, baseRef) + (_write if role == "implementer" else _read) + "4. Every commit carries the trailer \"Agent-Run: {}\". The commit hook adds it.\n5. Never modify .github/workflows/ or .github/chainguard/.\n6. A 429 from the model gateway means the budget is spent: stop and exit.\n".format(runId)
}

_render = lambda _oxr: any, _ocds: any, _dxr: any -> [any] {
    _name = _oxr.metadata.name
    _ns = _oxr.metadata.namespace
    assert _ns == "agents", "an AgentRun must live in namespace agents, got {}".format(_ns)
    assert regex.match(_name, "^xplane-run-[a-z2-7]{8}$"), "an AgentRun name must match ^xplane-run-[a-z2-7]{8}$, got " + _name
    _runId = _name[11::]
    _spec = _oxr.spec
    _role = _spec.role
    _class = _spec.dataClass
    _repo = _spec.repository
    _baseRef = _spec.baseRef or "main"
    _branch = _spec.branch or "agent/" + _runId
    _model = _spec.model or "agent-default"
    _size = _SIZES[_spec.size or "small"]
    _profile = _HARNESS_PROFILES[_spec.harness or "openhands"]
    _maxMinutes = _spec.budget?.maxMinutes or 120
    # R2 (SP1 spike Q2): under gVisor, kubelet's host-side token rotation raises no inotify,
    # so the proxy's watched_directory never reloads. Each token outlives the run instead,
    # which widens T8 to the deadline. 600 s is the apiserver's floor.
    _tokenTTL = max([600, _maxMinutes * 60])
    _profiles = ["github"] + (_spec.egress?.profiles or [])
    _fqdns = [f for p in _profiles for f in _EGRESS_PROFILES[p]]
    _roomRef = _spec.roomRef
    _ann = _oxr.metadata?.annotations or {}
    _taskLabel = _get(_oxr.metadata?.labels or {}, "agents.ogenki.io/task")
    _sandbox = _observed(_ocds, _name + "-sandbox")
    _previous = _oxr.status or {}
    _phase = _phaseOf(_ann, _previous?.phase or "", _sandbox)
    _live = _phase not in ["Revoked", "BudgetExhausted"]
    _revoked = _get(_ann, "agents.ogenki.io/revoked")
    _finished = _condition(_sandbox, "Finished")
    _usage = _usageTokens(_ann, _previous?.usage?.tokens)
    _pr = _pullRequest(_ann, _repo, _previous?.pullRequest)
    _labels = {
        "agents.ogenki.io/run-id" = _runId
        "agents.ogenki.io/role" = _role
        if _taskLabel:
            "agents.ogenki.io/task" = _taskLabel
    }
    _meta = lambda suffix: str, name: str, ready: bool -> any {
        {
            name = name
            namespace = _ns
            labels = _labels
            annotations = {
                "krm.kcl.dev/composition-resource-name" = _name + "-" + suffix
                "agents.ogenki.io/principal" = _spec.principal
                if ready:
                    "krm.kcl.dev/ready" = "True"
            }
        }
    }
    _sandboxReady = _condition(_sandbox, "Ready")?.status == "True" or _finished?.status == "True"
    _serviceAccount = [{
        apiVersion = "v1"
        kind = "ServiceAccount"
        metadata = _meta("sa", _name, _observed(_ocds, _name + "-sa") != None)
        automountServiceAccountToken = False
    }] if _live else []
    _taskConfigMap = [{
        apiVersion = "v1"
        kind = "ConfigMap"
        metadata = _meta("task", _name + "-task", True)
        data = {
            "task.md" = _spec.task.text if _spec.task?.text else "Work on {}.\n".format(_spec.task.url)
            "rules.md" = _rulesFor(_role, _runId, _repo, _branch, _baseRef)
            "run.json" = json.encode({runId = _runId, role = _role, repository = _repo, baseRef = _baseRef, branch = _branch, dataClass = _class, model = _model, principal = _spec.principal})
        }
    }]
    _dnsNames = [_ROUTER_FQDN, _STS_FQDN] + ([_BROKER_FQDN] if _roomRef else []) + _fqdns
    _networkPolicy = [{
        apiVersion = "cilium.io/v2"
        kind = "CiliumNetworkPolicy"
        metadata = _meta("cnp", _name, True)
        spec = {
            endpointSelector.matchLabels = {"agents.ogenki.io/run-id" = _runId}
            # Probes only. Nothing ever dials into a sandbox (C4).
            ingress = [{
                fromEntities = ["host"]
                toPorts = [{ports = [{port = str(_profile.port), protocol = "TCP"}, {port = "9901", protocol = "TCP"}]}]
            }]
            egress = [
                {
                    toEndpoints = [{
                        matchLabels = {"io.kubernetes.pod.namespace" = "kube-system", "k8s-app" = "kube-dns"}
                    }]
                    toPorts = [{
                        ports = [{port = "53", protocol = "UDP"}, {port = "53", protocol = "TCP"}]
                        # Answers only these names (S10, T6): no wildcard.
                        rules.dns = [{matchName = n} for n in _dnsNames]
                    }]
                }
                {
                    toEndpoints = [{
                        matchLabels = {"io.kubernetes.pod.namespace" = "envoy-gateway-system", "gateway.envoyproxy.io/owning-gateway-name" = "agent-router"}
                    }]
                    toPorts = [{ports = [{port = str(_ROUTER_PORT[_class]), protocol = "TCP"}]}]
                }
                {
                    toEndpoints = [{
                        matchLabels = {"io.kubernetes.pod.namespace" = "agent-system", "app.kubernetes.io/name" = "octo-sts"}
                    }]
                    toPorts = [{ports = [{port = "8080", protocol = "TCP"}]}]
                }
                {
                    toFQDNs = [{matchName = f} for f in _fqdns]
                    toPorts = [{ports = [{port = "443", protocol = "TCP"}]}]
                }
            ] + ([{
                toEndpoints = [{
                    matchLabels = {"io.kubernetes.pod.namespace" = "agent-system", "app.kubernetes.io/name" = "room-broker"}
                }]
                toPorts = [{ports = [{port = "8443", protocol = "TCP"}]}]
            }] if _roomRef else [])
        }
    }]
    _podLabels = _labels | ({"kueue.x-k8s.io/queue-name" = _spec.queueName} if _spec.queueName else {})
    _sandboxResource = [{
        apiVersion = "agents.x-k8s.io/v1beta1"
        kind = "Sandbox"
        metadata = _meta("sandbox", _name, _sandboxReady)
        spec = {
            # Nothing ever dials into a sandbox (C4).
            service = False
            podTemplate = {
                metadata = {
                    labels = _podLabels
                    annotations = {"karpenter.sh/do-not-disrupt" = "true"}
                }
                spec = {
                    serviceAccountName = _name
                    automountServiceAccountToken = False
                    runtimeClassName = "gvisor"
                    restartPolicy = "Never"
                    activeDeadlineSeconds = _maxMinutes * 60
                    enableServiceLinks = False
                    shareProcessNamespace = False
                    terminationGracePeriodSeconds = 30
                    dnsConfig = {options = [{name = "ndots", value = "1"}]}
                    securityContext = {
                        runAsNonRoot = True
                        runAsUser = 10001
                        runAsGroup = 10001
                        fsGroup = 10001
                        seccompProfile = {type = "RuntimeDefault"}
                    }
                    # Native sidecar: the ONLY container that mounts the gateway and
                    # octo-sts tokens (S5). The harness reaches them as localhost ports.
                    initContainers = [{
                        name = "identity-proxy"
                        image = _IDENTITY_PROXY_IMAGE
                        restartPolicy = "Always"
                        args = ["-c", "/etc/envoy/envoy.yaml", "--log-level", "warn"]
                        ports = [{name = "admin", containerPort = 9901, protocol = "TCP"}]
                        readinessProbe = {httpGet = {path = "/ready", port = 9901}, periodSeconds = 5}
                        livenessProbe = {httpGet = {path = "/ready", port = 9901}, periodSeconds = 10, failureThreshold = 3}
                        resources = {requests = {cpu = "50m", memory = "64Mi"}, limits = {cpu = "200m", memory = "128Mi"}}
                        securityContext = _CONTAINER_SECURITY
                        volumeMounts = [
                            {name = "proxy-config", mountPath = "/etc/envoy", readOnly = True}
                            {name = "gateway-token", mountPath = "/var/run/secrets/agents/gateway", readOnly = True}
                            {name = "sts-token", mountPath = "/var/run/secrets/agents/sts", readOnly = True}
                            {name = "proxy-tmp", mountPath = "/tmp"}
                        ]
                    }]
                    containers = [{
                        name = "harness"
                        image = _profile.image
                        args = _profile.args
                        env = [
                            {name = "RUN_ID", value = _runId}
                            {name = "ROLE", value = _role}
                            {name = "REPOSITORY", value = _repo}
                            {name = "BASE_REF", value = _baseRef}
                            {name = "BRANCH", value = _branch}
                            {name = "MODEL", value = _model}
                            {name = "DATA_CLASS", value = _class}
                            {name = "CONVERSATION_ID", value = _oxr.metadata?.uid or ""}
                            {name = "LLM_BASE_URL", value = "http://127.0.0.1:{}/v1".format(_PROXY_PORT[_class])}
                            {name = "MCP_URL", value = "http://127.0.0.1:{}/mcp".format(_PROXY_PORT[_class])}
                            {name = "STS_URL", value = "http://127.0.0.1:4001/sts/exchange"}
                            {name = "TASK_FILE", value = "/run/agent/task/task.md"}
                            {name = "RULES_FILE", value = "/run/agent/task/rules.md"}
                            {name = "HOME", value = "/home/openhands"}
                        ]
                        ports = [{name = "http", containerPort = _profile.port, protocol = "TCP"}]
                        startupProbe = {httpGet = {path = "/ready", port = _profile.port}, periodSeconds = 5, failureThreshold = 60}
                        readinessProbe = {httpGet = {path = "/ready", port = _profile.port}, periodSeconds = 10}
                        livenessProbe = {httpGet = {path = "/health", port = _profile.port}, periodSeconds = 20, failureThreshold = 3}
                        lifecycle.preStop.exec.command = ["/usr/local/bin/git-credential-agent", "revoke"]
                        resources = {
                            requests = {cpu = _size.cpu[0], memory = _size.memory[0], "ephemeral-storage" = "1Gi"}
                            limits = {cpu = _size.cpu[1], memory = _size.memory[1], "ephemeral-storage" = _size.scratch}
                        }
                        securityContext = _CONTAINER_SECURITY
                        volumeMounts = [
                            {name = "workspace", mountPath = "/workspace"}
                            {name = "home", mountPath = "/home/openhands"}
                            {name = "tmp", mountPath = "/tmp"}
                            {name = "git-cache", mountPath = "/run/agent/git"}
                            {name = "task", mountPath = "/run/agent/task", readOnly = True}
                        ]
                    }]
                    volumes = [
                        {name = "gateway-token", projected = {defaultMode = 288, sources = [{
                            serviceAccountToken = {audience = "agent-router.{}.{}".format(_role, _class), expirationSeconds = _tokenTTL, path = "token"}
                        }]}}
                        {name = "sts-token", projected = {defaultMode = 288, sources = [{
                            serviceAccountToken = {audience = "octo-sts/{}/{}".format(_repo, _role), expirationSeconds = _tokenTTL, path = "token"}
                        }]}}
                        {name = "proxy-config", configMap = {name = "agent-identity-proxy"}}
                        {name = "proxy-tmp", emptyDir = {medium = "Memory", sizeLimit = "16Mi"}}
                        {name = "task", configMap = {name = _name + "-task"}}
                        {name = "workspace", emptyDir = {sizeLimit = _size.scratch}}
                        {name = "home", emptyDir = {sizeLimit = "2Gi"}}
                        {name = "tmp", emptyDir = {sizeLimit = "2Gi"}}
                        # The GitHub token cache lives in memory only (T3).
                        {name = "git-cache", emptyDir = {medium = "Memory", sizeLimit = "1Mi"}}
                    ]
                }
            }
        }
    }] if _live else []
    _status = [{
        **_dxr
        status: {
            phase = _phase
            runId = _runId
            branch = _branch
            conversationId = _oxr.metadata?.uid or ""
            if _sandbox?.metadata?.creationTimestamp:
                startedAt = _sandbox.metadata.creationTimestamp
            if _finished?.lastTransitionTime:
                finishedAt = _finished.lastTransitionTime
            if _phase == "Failed":
                reason = "PodFailed"
            if not _live:
                reason = _revoked if _revoked in _REVOKE_REASONS else _previous?.reason
            if _usage != None:
                usage = {tokens = _usage}
            if _pr:
                pullRequest = _pr
        }
    }]
    _serviceAccount + _taskConfigMap + _networkPolicy + _sandboxResource + _status
}

items = _render(oxr, ocds, option("params").dxr)
```

- [ ] **Step 2: Run the tests to see them pass**

Run: `cd apis/agentrun/kcl && kcl test . -Y settings-example.yaml`
Expected: `PASS: 28/28`. These include the offline half of SC-13 (`test_revoked_run_keeps_only_its_record`,
`test_valid_annotations_are_projected`, `test_malformed_annotations_are_not_projected`) and SC-08's
pod-shape half (`test_only_the_proxy_mounts_tokens`, `test_service_account_has_no_token`).

- [ ] **Step 3: Format check**

Run: `cd apis/agentrun/kcl && kcl fmt . >/dev/null && git diff --exit-code -- .`
Expected: exit 0.

- [ ] **Step 4: Commit**

```bash
git add apis/agentrun/kcl
git commit -m "feat(agentrun): KCL composition with phase table and annotation projection"
```

### Task 1.4: Composition, packaging, golden renders, docs

**Files:**
- Create: `apis/agentrun/composition.yaml` (skeleton, then generated), `apis/agentrun/kcl/README.md`,
  `tests/golden/agentrun-basic.yaml`, `tests/golden/agentrun-complete.yaml`
- Modify: `scripts/generate.py` (the `MODULE` dict), `scripts/assemble.sh` (three lines),
  `packages/core/crossplane.yaml` (description), `packages/aws/crossplane.yaml` (core floor),
  `README.md`, `CLAUDE.md`

**Interfaces:**
- Produces: Composition `xagentruns.cloud.ogenki.io` in the **core** package (S11); aws package
  depending on core `>=v0.8.0`.

- [ ] **Step 1: Composition skeleton**

`apis/agentrun/composition.yaml` (the empty `source` is filled by `task generate`):

```yaml
apiVersion: apiextensions.crossplane.io/v1
kind: Composition
metadata:
  name: xagentruns.cloud.ogenki.io
  labels:
    provider: kubernetes
spec:
  compositeTypeRef:
    apiVersion: cloud.ogenki.io/v1alpha1
    kind: AgentRun
  mode: Pipeline
  pipeline:
  - step: agentrun
    functionRef:
      name: function-kcl
    input:
      apiVersion: krm.kcl.dev/v1alpha1
      kind: KCLRun
      spec:
        target: Resources
        source: ""
  - step: ready
    functionRef:
      name: function-auto-ready
```

- [ ] **Step 2: Register the module and package it in core**

In `scripts/generate.py`, add to `MODULE` after the `gcpworkloadidentity` entry:

```python
    "agentrun": "agentrun",
```

In `scripts/assemble.sh`, core section:

```bash
for api in app sqlinstance kvstore inferenceservice agentrun; do
  cp "apis/$api/definition.yaml" "build/core/apis/$api-definition.yaml"
done
cp apis/kvstore/composition.yaml build/core/apis/kvstore-composition.yaml
cp apis/agentrun/composition.yaml build/core/apis/agentrun-composition.yaml
cp packages/core/crossplane.yaml build/core/crossplane.yaml
cp examples/kvstore-basic.yaml examples/kvstore-complete.yaml \
   examples/agentrun-basic.yaml examples/agentrun-complete.yaml build/core/examples/
```

In `packages/core/crossplane.yaml`, the description becomes:

```yaml
    meta.crossplane.io/description: |
      Cloud-neutral platform API contracts for the ogenki platform: App,
      SQLInstance, KVStore, InferenceService and AgentRun, plus the KVStore and
      AgentRun Compositions. Cloud-specific Compositions ship in a sibling package.
```

In `packages/aws/crossplane.yaml`, raise the core floor, because Crossplane never upgrades an
installed dependency on its own and cloud-native-ref's aws-0 would keep a core without `AgentRun`:

```yaml
  dependsOn:
    - configuration: ghcr.io/smana/crossplane-configuration-core
      version: ">=v0.8.0"
```

In `README.md`, the core package row reads `` `App`, `SQLInstance`, `KVStore`, `InferenceService`,
`AgentRun` + the `KVStore` and `AgentRun` Compositions ``, and the API table gains
`` | `AgentRun` | One gVisor-sandboxed coding-agent run: ServiceAccount, task ConfigMap, CNP, Sandbox | ``.
In `CLAUDE.md`, the APIs line lists `AgentRun` among the core APIs.

- [ ] **Step 3: Generate and check sync**

Run: `task generate && git diff --stat -- apis/agentrun/composition.yaml`
Expected: `apis/agentrun/composition.yaml <- apis/agentrun/kcl/main.k (module agentrun, …)` and a
non-empty diff (the inlined source).

- [ ] **Step 4: Capture the golden renders (needs Docker)**

```bash
for ex in agentrun-basic agentrun-complete; do
  crossplane render examples/$ex.yaml apis/agentrun/composition.yaml functions.yaml \
    --extra-resources examples/environmentconfig.yaml > tests/golden/$ex.yaml
done
grep -c '^kind: Sandbox' tests/golden/agentrun-basic.yaml
grep -A3 '^  usage:' tests/golden/agentrun-complete.yaml
```
Expected: `1`; `tokens: 184223` under `usage`, and `pullRequest:
https://github.com/Smana/cloud-native-ref/pull/2090` in the complete render's status. **Review both
files by hand** against the constitution (the repo's "known gap": no automated security audit of
composition output): runAsNonRoot, readOnlyRootFilesystem, `drop: [ALL]`, RuntimeDefault, requests and
limits on both containers, no `automountServiceAccountToken: true`, no `toEntities`.

- [ ] **Step 5: README of the module (constitution §8.1)**

`apis/agentrun/kcl/README.md`:

```markdown
# AgentRun Composition

One gVisor-sandboxed coding-agent run (cloud-native-ref Agent Factory, SP1). Renders, all named
`xplane-run-<runId>[-suffix]` in namespace `agents`:

| Resource | Rendered unless | Ready when |
|---|---|---|
| `ServiceAccount` (automount off, no RBAC) | revoked | observed |
| `ConfigMap -task` (`task.md`, `rules.md`, `run.json`) | — | always |
| `CiliumNetworkPolicy` (DNS L7 allowlist, the class's gateway port, octo-sts, FQDN profiles) | — | always |
| `Sandbox` (`agents.x-k8s.io/v1beta1`, RuntimeClass `gvisor`, identity-proxy native sidecar) | revoked | Sandbox `Ready` or `Finished` |

## API

See `examples/agentrun-basic.yaml` and `examples/agentrun-complete.yaml`.

## Status has one writer

Controllers never patch status. They write annotations; this composition validates and projects them.

| Annotation | Projected to | Accepted value |
|---|---|---|
| `agents.ogenki.io/usage-tokens` | `status.usage.tokens` | `^[0-9]{1,12}$` |
| `agents.ogenki.io/pull-request` | `status.pullRequest` | `https://github.com/<spec.repository>/pull/<n>` |
| `agents.ogenki.io/revoked` | `status.phase` | `budget-run`, `budget-principal`, `budget-fleet` → `BudgetExhausted`; `manual` → `Revoked` |

A malformed value is ignored and the last valid one stays. Revocation and terminal phases latch.

## Test

    kcl test . -Y settings-example.yaml
```

- [ ] **Step 6: The whole gate**

Run: `task check`
Expected: exit 0 — `generate-sync` clean, `kcl test` PASS for every API (agentrun 28/28), `Valid: 22,
Invalid: 0, Skipped: 0`, and render equivalence `22/22 match`.

- [ ] **Step 7: Commit**

```bash
git add apis/agentrun scripts/generate.py scripts/assemble.sh packages/core/crossplane.yaml packages/aws/crossplane.yaml README.md CLAUDE.md tests/golden/agentrun-basic.yaml tests/golden/agentrun-complete.yaml
git commit -m "feat(agentrun): ship AgentRun in the core package"
```

### Task 1.5: CC-1 and the `v0.8.0` release

**Files:** none.

- [ ] **Step 1: Build check and PR**

Run: `task build && ./scripts/check_packages.sh`
Expected: three `.xpkg` files, exit 0.

Rebase onto `origin/main`, push, open CC-1 with `ship-it` (body links this plan and the SP1 design).

- [ ] **Step 2: [OWNER] Merge and tag**

After CI is green and the owner merges: `git fetch origin && git tag v0.8.0 origin/main && git push origin v0.8.0` (run right after the merge, so `origin/main` is the merge commit).

- [ ] **Step 3: Confirm the release**

Run: `curl -fsSL https://github.com/Smana/crossplane-configuration/releases/download/v0.8.0/xrd-crds.yaml | grep -c 'name: agentruns.cloud.ogenki.io'`
Expected: `1`.

---
## Phase 2 — Runtime (PR 2, branch `feat/agent-runtime`)

Starts after CC-1 is released as `v0.8.0`. Does not depend on SP4. Gate: SC-01, SC-02, SC-03.

### Task 2.1: Worktree and ADR-0041

**Files:**
- Create: `website/content/docs/decisions/0041-agent-sandbox-gvisor-al2023.md`
- Modify: `website/content/docs/decisions/_index.md` (one table row)

- [ ] **Step 1: Worktree**

`EnterWorktree` with branch `feat/agent-runtime`.

- [ ] **Step 2: Write the ADR**

`website/content/docs/decisions/0041-agent-sandbox-gvisor-al2023.md` (set **Date** to the commit
day):

```markdown
---
title: Coding agents run in agent-sandbox Sandboxes under gVisor, on AL2023 spot nodes, with OpenHands as the harness profile
linkTitle: 0041 · Agent sandbox runtime
weight: 410
description: Every agent run is a bare agent-sandbox Sandbox on a dedicated Karpenter AL2023 spot pool where runsc is installed at boot, because Bottlerocket ships no runsc. The harness is OpenHands agent-server, selected by a platform profile the claim cannot override. Kata, OpenHands Enterprise, Coder and hosted sandboxes were rejected.
lastVerified: 2026-09-25
---

**Status**: Accepted
**Date**: 2026-09-25
**Deciders**: Smana (Platform Owner)
**Related Spec**: [SP1 — Agent runtime & identity](https://github.com/Smana/cloud-native-ref/blob/main/docs/superpowers/specs/2026-09-23-agent-runtime-identity-design.md)

---

## Context

Autonomous coding agents (Agent Factory programme) execute model-written code with a shell. A
container boundary alone is not enough for that: a kernel exploit from one run would reach the node,
its IAM role and every co-located run. The platform's nodes run Bottlerocket, which ships no gVisor
(`runsc`) and has no plan to ([bottlerocket#811](https://github.com/bottlerocket-os/bottlerocket/issues/811)).
AWS's own `ai-on-eks` blueprint runs agent-sandbox with gVisor on a Karpenter AL2023 pool.

---

## Decision Drivers

- A user-space kernel between agent code and the node kernel
- Open source first (programme D2), GitOps-managed like every other workload
- Identity per run, so the pod spec must be per run
- Test clusters are spot and cheapest
- No image choice in the claim: a claim must not be a supply-chain input

---

## Considered Options

### Option 1: agent-sandbox `Sandbox` + gVisor on a Karpenter AL2023 spot pool

The XR composes a bare `Sandbox` with `runtimeClassName: gvisor`. User-data installs a pinned,
sha256-checked gVisor tarball and registers `runsc` in containerd's v3 CRI table, on `systrap`. `oci-seccomp` stays off: runsc ignores
`errnoRet` ([gVisor #14688](https://github.com/google/gvisor/issues/14688)), which breaks glibc thread
creation under `RuntimeDefault`.

**Pros**:
- The same stack as AWS's blueprint; `Sandbox` reports `Ready` and `Finished`, so it fits a one-shot run
- No nested virtualisation
- Per-run pod spec: the ServiceAccount, audiences and CNP are composed with the run

**Cons**:
- An AL2023 pool is the one exception to the Bottlerocket rule
- `v1beta1` API, weekly releases: the tag is pinned and its CRDs enter the CI catalog
- gVisor costs file-I/O speed (measured by the phase-0 spike, SC-15)

### Option 2: Kata Containers / Firecracker

**Pros**:
- A hardware virtualisation boundary

**Cons**:
- Needs nested virtualisation or metal instances on EC2; AWS calls it the "future tier"

### Option 3: OpenHands Enterprise, Coder, or a hosted sandbox (E2B, Daytona)

**Pros**:
- Turnkey workspaces

**Cons**:
- Not open source, or SaaS: data and credentials leave the cluster (D2)
- OpenHands' own Kubernetes workspace is built on warm pools, whose pods already carry a
  ServiceAccount; claim-time identity is only *Planned* upstream

### Harness profile: OpenHands agent-server over headless Claude Code and kagent

agent-server is MIT, runs as UID 10001, speaks OpenAI-compatible HTTP to whatever base URL it is
given, and exposes the four local operations SP2's room bridge needs. Headless Claude Code is not
open source; kagent v1 is alpha. The claim names a **profile** (`openhands`), never an image; the
composition maps it to a digest.

---

## Decision Outcome

**Chosen option**: "agent-sandbox `Sandbox` + gVisor on a Karpenter AL2023 spot pool", with the
OpenHands agent-server profile.

**Rationale**: It is the only option that is open source, runs on EKS without nested
virtualisation, and lets identity be composed per run.

---

## Consequences

### Positive

- Kernel attack surface is gVisor's Sentry, not the node kernel
- Every run's identity, egress and resources are declared by one XR and die with it

### Negative

- A Sentry escape reaches the node's IAM role and co-located runs. Mitigations: dedicated tainted
  pool, IMDS hop limit 1, daily node replacement (`expireAfter: 24h`). Kata is the next tier
- `RuntimeDefault` seccomp is not enforced inside the sandbox until gVisor honours `errnoRet`, and
  NoNewPrivileges is not reliable under it. gVisor is the control
- Vector needs a toleration for the pool's taint to ship sandbox logs

### Neutral

- A harness bump is a release of the composition package, reviewed like any other

---

## Implementation Notes

`infrastructure/base/karpenter-nodepools-agents/`, `infrastructure/base/runtimeclass-gvisor/`,
`infrastructure/base/agent-sandbox/`, Kyverno `agents-pod-shape` in `security/base/agent-policies/`,
all behind the `agent-platform` umbrella. The XR is `AgentRun` in `Smana/crossplane-configuration`.
Spike results: `docs/superpowers/specs/2026-09-23-agent-runtime-identity-spike.md`.

---

## References

- [kubernetes-sigs/agent-sandbox v1.0.3](https://github.com/kubernetes-sigs/agent-sandbox/releases)
- [gVisor release-20260921.0](https://github.com/google/gvisor/releases/tag/release-20260921.0)
- [awslabs/ai-on-eks agent-sandbox](https://github.com/awslabs/ai-on-eks/tree/main/infra/agent-sandbox)
- [wso2/agent-manager#1891](https://github.com/wso2/agent-manager/issues/1891) (containerd v3 table)
- [OpenHands agent-server](https://docs.openhands.dev/sdk/arch/agent-server)
```

Append to the table in `website/content/docs/decisions/_index.md`, after the 0040 row:

```markdown
| [0041]({{< relref "/docs/decisions/0041-agent-sandbox-gvisor-al2023.md" >}}) | Coding agents run in agent-sandbox Sandboxes under gVisor, on AL2023 spot nodes, with OpenHands as the harness profile | Accepted | 2026-09-25 |
```

- [ ] **Step 3: Commit**

```bash
git add website/content/docs/decisions/0041-agent-sandbox-gvisor-al2023.md website/content/docs/decisions/_index.md
git commit -m "docs(adr): 0041 agent sandbox runtime"
```

### Task 2.2: The `agent-platform` umbrella

**Files:**
- Create: `clusters/aws-0/agent-platform.yaml`, `clusters/aws-0-agent-platform/kustomization.yaml`,
  `clusters/aws-0-agent-platform/README.md`
- Modify: `clusters/AGENTS.md` (a short gate section)

**Interfaces:**
- Produces: Flux Kustomization `agent-platform` (`flux-system`). Children are listed in
  `clusters/aws-0-agent-platform/kustomization.yaml`; every later task appends one line there.

- [ ] **Step 1: Umbrella**

`clusters/aws-0/agent-platform.yaml`:

```yaml
---
# Agent platform — opt-in Flux umbrella (Agent Factory programme, C1).
#
# Default: spec.suspend = true → none of the children under
# clusters/aws-0-agent-platform/ exist: no sandbox controller, no gVisor pool,
# no agent-router, no octo-sts. The AgentRun XRD ships in the always-on
# Crossplane package; without this umbrella a claim has no RuntimeClass to run on.
#
# Enable:   flux resume kustomization ai-gateway -n flux-system   (first: this depends on it)
#           flux resume kustomization agent-platform -n flux-system
# Teardown: see clusters/aws-0-agent-platform/README.md
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: agent-platform
  namespace: flux-system
spec:
  suspend: true
  prune: true
  interval: 1m0s
  timeout: 5m0s
  # A sibling of clusters/aws-0/, never a sub-path: flux-system syncs aws-0/
  # recursively and would apply the children around this suspend.
  path: ./clusters/aws-0-agent-platform
  sourceRef:
    kind: GitRepository
    name: flux-system
```

`clusters/aws-0-agent-platform/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

# Flat list of agent-platform children. The umbrella at
# clusters/aws-0/agent-platform.yaml applies this directory only when resumed.
resources:
  - infrastructure-agent-sandbox.yaml
  - infrastructure-agents-nodepool.yaml
  - infrastructure-runtimeclass-gvisor.yaml
  - infrastructure-agent-runtime.yaml
  - security-agent-policies.yaml
```

`clusters/aws-0-agent-platform/README.md`:

```markdown
# aws-0 agent platform (opt-in)

Children of the `agent-platform` umbrella (`../aws-0/agent-platform.yaml`, suspended by default).
Design: `docs/superpowers/specs/2026-09-23-agent-runtime-identity-design.md`.

| Child Kustomization | Path | Holds |
|---|---|---|
| `agent-sandbox` | `infrastructure/base/agent-sandbox` | Sandbox CRD and controller in `agent-system` |
| `agents-nodepool` | `infrastructure/base/karpenter-nodepools-agents` | `agents-gvisor` NodePool + EC2NodeClass |
| `runtimeclass-gvisor` | `infrastructure/base/runtimeclass-gvisor` | RuntimeClass `gvisor` → `runsc` |
| `agent-runtime` | `infrastructure/base/agent-runtime` | identity-proxy ConfigMap, `agents` default deny |
| `agent-policies` | `security/base/agent-policies` | Kyverno admission and GC for runs |

## Resume

    flux resume kustomization ai-gateway -n flux-system
    flux resume kustomization agent-platform -n flux-system

## Teardown

Suspending leaves the children in place. To remove them:

    kubectl delete agentruns -n agents --all --wait
    flux suspend kustomization agent-platform -n flux-system
    kubectl kustomize clusters/aws-0-agent-platform | awk '/^  name:/{print $2}' | xargs flux delete kustomization -n flux-system --silent
```

- [ ] **Step 2: Gate note**

In `clusters/AGENTS.md`, after the "self-hosted LLM platform" section, add:

```markdown
## The agent platform — one gate on AWS

`aws-0/agent-platform.yaml`, `spec.suspend: true`, children in `aws-0-agent-platform/` (a sibling, for
the same reason as `llm-platform`). Release with `flux resume kustomization agent-platform -n
flux-system`, after resuming `ai-gateway`, which is suspended by default too (OD-3, amended 2026-09-26). It
depends on `ai-gateway`, never on `llm-platform`: agents run on frontier models with
zero GPUs. The `AgentRun` XRD is always installed; this gate decides whether a run can start.
```

- [ ] **Step 3: Commit** (children arrive in the next tasks; `validate-manifests.sh` runs in Task 2.8)

```bash
git add clusters/aws-0/agent-platform.yaml clusters/aws-0-agent-platform/kustomization.yaml clusters/aws-0-agent-platform/README.md clusters/AGENTS.md
git commit -m "feat(clusters): agent-platform opt-in umbrella"
```

### Task 2.3: agent-sandbox controller and its schema

**Files:**
- Create: `flux/sources/gitrepo-agent-sandbox.yaml`
- Create: `infrastructure/base/agent-sandbox/{kustomization.yaml,helmrelease.yaml,network-policy.yaml,rbac-crossplane.yaml}`
- Create: `clusters/aws-0-agent-platform/infrastructure-agent-sandbox.yaml`
- Modify: `scripts/ci/flux-schema/gen-catalog.sh`

**Interfaces:**
- Produces: CRD `sandboxes.agents.x-k8s.io` (v1beta1), controller in `agent-system` (pod label
  `app.kubernetes.io/name: agent-sandbox`), Crossplane allowed to manage `sandboxes`. Schema
  `agents.x-k8s.io/sandbox_v1beta1.json` in `.schemas/`.

- [ ] **Step 1: Make the catalog require the Sandbox schema (fails first)**

In `scripts/ci/flux-schema/gen-catalog.sh`, add to the header's numbered source list:

```bash
#   5. agent-sandbox CRDs              -> agents.x-k8s.io/*
#      (the chart and its CRDs exist only in the git repository, SP1 S2)
```

After the Barman source variables:

```bash
AGENT_SANDBOX_SOURCE="flux/sources/gitrepo-agent-sandbox.yaml"
AGENT_SANDBOX_URL="$(sed -nE 's#^[[:space:]]*url:[[:space:]]*"?(https?://[^"[:space:]]+)"?[[:space:]]*$#\1#p' "${AGENT_SANDBOX_SOURCE}" | head -n1 || true)"
AGENT_SANDBOX_VERSION="$(sed -nE 's/^[[:space:]]*tag:[[:space:]]*"?(v?[0-9][^"[:space:]]*)"?[[:space:]]*$/\1/p' "${AGENT_SANDBOX_SOURCE}" | head -n1 || true)"
if [[ -z "${AGENT_SANDBOX_URL}" || -z "${AGENT_SANDBOX_VERSION}" ]]; then
  echo "error: could not read the agent-sandbox git url or tag from ${AGENT_SANDBOX_SOURCE}" >&2
  exit 1
fi
```

After the Barman clone:

```bash
echo "==> Fetching agent-sandbox CRDs (git ${AGENT_SANDBOX_VERSION})"
git clone --quiet --depth 1 --branch "${AGENT_SANDBOX_VERSION}" "${AGENT_SANDBOX_URL}" "${tmp}/agent-sandbox"
cat "${tmp}/agent-sandbox/helm/crds"/*.yaml > "${tmp}/agent-sandbox-crds.yaml"
```

With the other extracts:

```bash
"${FLUX_BIN}" schema extract crd "${tmp}/agent-sandbox-crds.yaml" -d "${build_dir}"
```

With the other assertions:

```bash
if [[ ! -s "${build_dir}/agents.x-k8s.io/sandbox_v1beta1.json" ]]; then
  echo "error: catalog build produced no agents.x-k8s.io/sandbox_v1beta1.json (agent-sandbox ${AGENT_SANDBOX_VERSION} shipped no Sandbox CRD in helm/crds?)" >&2
  exit 1
fi
```

Run: `./scripts/ci/flux-schema/gen-catalog.sh`
Expected: FAIL — `could not read the agent-sandbox git url or tag` (the source does not exist yet).

- [ ] **Step 2: The source**

`flux/sources/gitrepo-agent-sandbox.yaml`:

```yaml
# agent-sandbox publishes its Helm chart only in the git repository (helm/,
# chart 0.1.0), in no registry (SP1 S2). The controller image tag in
# infrastructure/base/agent-sandbox/helmrelease.yaml MUST equal this tag: chart
# and controller are cut from one release. gen-catalog.sh reads the CRDs from it.
#
# Here, not under the component: a source under an app directory inherits a
# shard label the default source-controller cannot see (clusters/AGENTS.md).
apiVersion: source.toolkit.fluxcd.io/v1
kind: GitRepository
metadata:
  name: agent-sandbox
  namespace: agent-system
spec:
  interval: 1h
  url: https://github.com/kubernetes-sigs/agent-sandbox
  ref:
    tag: v1.0.3
  ignore: |
    /*
    !/helm/
```

Run: `./scripts/ci/flux-schema/gen-catalog.sh | grep 'agents.x-k8s.io/sandbox_v1beta1.json'`
Expected: `.schemas/agents.x-k8s.io/sandbox_v1beta1.json`.

- [ ] **Step 3: Controller**

`infrastructure/base/agent-sandbox/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - helmrelease.yaml
  - network-policy.yaml
  - rbac-crossplane.yaml
```

`infrastructure/base/agent-sandbox/helmrelease.yaml`:

```yaml
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: agent-sandbox
  namespace: agent-system
spec:
  releaseName: agent-sandbox
  interval: 30m
  chart:
    spec:
      chart: helm
      sourceRef:
        kind: GitRepository
        name: agent-sandbox
        namespace: agent-system
      interval: 12h
      # The chart version never moves (0.1.0); only the git tag does. Revision
      # repackages on every new tag.
      reconcileStrategy: Revision
  install:
    crds: CreateReplace
    remediation:
      retries: 3
  upgrade:
    crds: CreateReplace
    remediation:
      retries: 3
  driftDetection:
    mode: enabled
  values:
    namespace:
      create: false
      name: agent-system
    image:
      # Lockstep with flux/sources/gitrepo-agent-sandbox.yaml `ref.tag`.
      tag: v1.0.3@sha256:8c8f5814c16bd68631af0496a5fa4eb9bedce4d032de88b956130a041d9f438e
    controller:
      # Bare Sandboxes only (S1): no SandboxTemplate, SandboxClaim or warm pool.
      extensions: false
    resources:
      requests:
        cpu: 20m
        memory: 64Mi
      limits:
        cpu: 500m
        memory: 256Mi
    podSecurityContext:
      runAsNonRoot: true
      seccompProfile:
        type: RuntimeDefault
    containerSecurityContext:
      runAsNonRoot: true
      allowPrivilegeEscalation: false
      readOnlyRootFilesystem: true
      capabilities:
        drop: ["ALL"]
      seccompProfile:
        type: RuntimeDefault
    metrics:
      serviceMonitor:
        enabled: true
```

`infrastructure/base/agent-sandbox/network-policy.yaml`:

```yaml
---
# agent-sandbox controller: talks to the API server only. No webhook with
# extensions off. The chart's probes are on healthz :8081, metrics on :8080.
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: agent-sandbox-controller
  namespace: agent-system
spec:
  endpointSelector:
    matchLabels:
      app.kubernetes.io/name: agent-sandbox
  ingress:
    - fromEntities:
        - host
      toPorts:
        - ports:
            - port: "8081"
              protocol: TCP
    - fromEndpoints:
        - matchLabels:
            io.kubernetes.pod.namespace: observability
      toPorts:
        - ports:
            - port: "8080"
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
    - toEntities:
        - kube-apiserver
      toPorts:
        - ports:
            - port: "443"
              protocol: TCP
```

`infrastructure/base/agent-sandbox/rbac-crossplane.yaml`:

```yaml
---
# The AgentRun composition writes Sandboxes; Crossplane's SA is granted only what
# its providers manage (infrastructure/AGENTS.md, trap 3). ServiceAccounts,
# ConfigMaps and CNPs are already covered by Crossplane's own role and
# infrastructure/base/crossplane/rbac/aggregate-rbac.yaml.
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: agent-sandbox:aggregate-to-crossplane
  labels:
    rbac.crossplane.io/aggregate-to-crossplane: "true"
rules:
  - apiGroups: ["agents.x-k8s.io"]
    resources: ["sandboxes", "sandboxes/status"]
    verbs: ["*"]
```

`clusters/aws-0-agent-platform/infrastructure-agent-sandbox.yaml`:

```yaml
---
# agent-sandbox controller and its Sandbox CRD (SP1 S1, S2).
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: agent-sandbox
  namespace: flux-system
spec:
  prune: true
  interval: 5m0s
  timeout: 5m0s
  path: ./infrastructure/base/agent-sandbox
  sourceRef:
    kind: ExternalArtifact
    name: infra-artifact
  # ServiceMonitor comes from the prometheus-operator CRDs in `crds`.
  dependsOn:
    - name: crds
  healthChecks:
    - apiVersion: helm.toolkit.fluxcd.io/v2
      kind: HelmRelease
      name: agent-sandbox
      namespace: agent-system
```

- [ ] **Step 4: Commit**

```bash
git add flux/sources/gitrepo-agent-sandbox.yaml infrastructure/base/agent-sandbox clusters/aws-0-agent-platform/infrastructure-agent-sandbox.yaml scripts/ci/flux-schema/gen-catalog.sh
git commit -m "feat(agents): agent-sandbox controller from its pinned git chart"
```

### Task 2.4: Carry the spike manifests over

**Files:**
- Create (from branch `spike/agent-gvisor`, Task 0.1): `namespaces/base/{agents,agent-system}.yaml`
  and the two lines in `namespaces/base/kustomization.yaml`;
  `infrastructure/base/runtimeclass-gvisor/`; `infrastructure/base/karpenter-nodepools-agents/`;
  `infrastructure/base/agent-runtime/`; `opentofu/aws/eks/init/helm_values/cilium.yaml` (Cilium
  `devices` for AL2023's `enp*`/`ens*` names, spike finding C; an existing cluster needs the
  `eks/configure` stack applied)
- Create: `clusters/aws-0-agent-platform/{infrastructure-agents-nodepool,infrastructure-runtimeclass-gvisor,infrastructure-agent-runtime}.yaml`

**Interfaces:**
- Consumes: Task 0.1 manifests as corrected by the spike notes.
- Produces: child Kustomizations `agents-nodepool`, `runtimeclass-gvisor`, `agent-runtime`.

- [ ] **Step 1: Bring the files in**

```bash
git checkout spike/agent-gvisor -- namespaces/base/agents.yaml namespaces/base/agent-system.yaml \
  infrastructure/base/runtimeclass-gvisor infrastructure/base/karpenter-nodepools-agents infrastructure/base/agent-runtime \
  opentofu/aws/eks/init/helm_values/cilium.yaml
git diff --cached --stat
```
Expected: exactly those paths. Then append to `resources:` in `namespaces/base/kustomization.yaml`
(edited here, not checked out, so a change on `main` since the spike is kept):

```yaml
  - agents.yaml
  - agent-system.yaml
```

- [ ] **Step 2: Child Kustomizations**

`clusters/aws-0-agent-platform/infrastructure-agents-nodepool.yaml`:

```yaml
---
# agents-gvisor: AL2023 spot nodes with runsc (ADR-0041). Tainted and labelled
# agents.ogenki.io/runtime=gvisor; RuntimeClass `gvisor` schedules onto it.
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: agents-nodepool
  namespace: flux-system
spec:
  prune: true
  interval: 1m0s
  timeout: 2m0s
  path: ./infrastructure/base/karpenter-nodepools-agents
  sourceRef:
    kind: ExternalArtifact
    name: infra-artifact
  postBuild:
    substituteFrom:
      - kind: ConfigMap
        name: eks-aws-0-vars
  dependsOn:
    - name: karpenter-nodepools
```

`clusters/aws-0-agent-platform/infrastructure-runtimeclass-gvisor.yaml`:

```yaml
---
# RuntimeClass gvisor -> containerd handler runsc, registered by the
# agents-gvisor user-data. aws-0 only: GKE ships its own.
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: runtimeclass-gvisor
  namespace: flux-system
spec:
  prune: true
  interval: 1m0s
  timeout: 2m0s
  path: ./infrastructure/base/runtimeclass-gvisor
  sourceRef:
    kind: ExternalArtifact
    name: infra-artifact
```

`clusters/aws-0-agent-platform/infrastructure-agent-runtime.yaml`:

```yaml
---
# What every sandbox shares: the identity-proxy bootstrap, and deny-all for any
# pod in `agents` that its run's own CNP does not open.
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: agent-runtime
  namespace: flux-system
spec:
  prune: true
  interval: 5m0s
  timeout: 2m0s
  path: ./infrastructure/base/agent-runtime
  sourceRef:
    kind: ExternalArtifact
    name: infra-artifact
```

- [ ] **Step 3: Substitution gate**

Run: `python3 scripts/ci/flux-schema/check-substitution.py`
Expected: exit 0 (`agents-nodepool` has `postBuild`; the user-data has no `${...}`).

- [ ] **Step 4: Commit**

```bash
git add namespaces/base infrastructure/base/runtimeclass-gvisor infrastructure/base/karpenter-nodepools-agents infrastructure/base/agent-runtime \
  clusters/aws-0-agent-platform/infrastructure-agents-nodepool.yaml clusters/aws-0-agent-platform/infrastructure-runtimeclass-gvisor.yaml clusters/aws-0-agent-platform/infrastructure-agent-runtime.yaml
git commit -m "feat(agents): gVisor pool, RuntimeClass and shared sandbox config"
```

### Task 2.5: Kyverno policies

**Files:**
- Create: `security/base/agent-policies/{kustomization.yaml,validatingpolicies.yaml,deletingpolicy.yaml,rbac-cleanup.yaml}`
- Create: `clusters/aws-0-agent-platform/security-agent-policies.yaml`

**Interfaces:**
- Produces: `ValidatingPolicy` `agents-pod-shape`, `agentrun-admission`, `agents-no-secret-import`,
  `agent-audience-reservation`; `DeletingPolicy` `agentrun-gc`. SP3 adds its creator rule as a separate
  policy file in this directory.

- [ ] **Step 1: Policies**

`security/base/agent-policies/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

# Validate only: a mutation would hide a composition bug (SP1 §1).
resources:
  - validatingpolicies.yaml
  - deletingpolicy.yaml
  - rbac-cleanup.yaml
```

`security/base/agent-policies/validatingpolicies.yaml`:

```yaml
---
# The admission control agent-sandbox's threat model asks for on bare Sandboxes:
# the gVisor boundary, no API token, and nothing but a Sandbox creating pods here.
apiVersion: policies.kyverno.io/v1
kind: ValidatingPolicy
metadata:
  name: agents-pod-shape
spec:
  validationActions: [Deny]
  failurePolicy: Fail
  matchConstraints:
    namespaceSelector:
      matchLabels:
        kubernetes.io/metadata.name: agents
    resourceRules:
      - apiGroups: [""]
        apiVersions: [v1]
        operations: [CREATE]
        resources: [pods]
  validations:
    - expression: "has(object.spec.runtimeClassName) && object.spec.runtimeClassName == 'gvisor'"
      message: "every pod in agents runs under RuntimeClass gvisor"
    - expression: "has(object.spec.automountServiceAccountToken) && object.spec.automountServiceAccountToken == false"
      message: "a pod in agents never mounts a Kubernetes API token"
    - expression: "has(object.metadata.ownerReferences) && object.metadata.ownerReferences.exists(o, o.kind == 'Sandbox' && o.apiVersion.startsWith('agents.x-k8s.io/'))"
      message: "pods in agents are created by a Sandbox"
---
# Every composed name, audience and octo-sts subject pattern depends on the name
# shape (C2). The XRD enforces it too; this also pins the namespace, which the
# XRD cannot see. SP3's one-creator rule lives beside this one, not in it.
apiVersion: policies.kyverno.io/v1
kind: ValidatingPolicy
metadata:
  name: agentrun-admission
spec:
  validationActions: [Deny]
  failurePolicy: Fail
  evaluation:
    background:
      enabled: false
  matchConstraints:
    resourceRules:
      - apiGroups: [cloud.ogenki.io]
        apiVersions: [v1alpha1]
        operations: [CREATE]
        resources: [agentruns]
  validations:
    - expression: "object.metadata.name.matches('^xplane-run-[a-z2-7]{8}$')"
      message: "an AgentRun is named xplane-run-<runId>, runId being 8 characters of [a-z2-7]"
    - expression: "object.metadata.namespace == 'agents'"
      message: "AgentRuns live in namespace agents"
---
# agents holds no secret (S9). Blocks the ESO objects that could pull one in.
apiVersion: policies.kyverno.io/v1
kind: ValidatingPolicy
metadata:
  name: agents-no-secret-import
spec:
  validationActions: [Deny]
  failurePolicy: Fail
  evaluation:
    background:
      enabled: false
  matchConstraints:
    namespaceSelector:
      matchLabels:
        kubernetes.io/metadata.name: agents
    resourceRules:
      - apiGroups: [external-secrets.io]
        apiVersions: ["*"]
        operations: [CREATE, UPDATE]
        resources: [externalsecrets, pushsecrets, secretstores]
  validations:
    - expression: "false"
      message: "namespace agents holds no secret: External Secrets objects are refused (SP1 S9)"
---
# Envoy Gateway can neither prefix-match `sub` nor read the kubernetes.io claim,
# so the audiences agents use are reserved. Cluster-wide, hence Ignore: an
# outage of this policy must not block every pod in the cluster.
apiVersion: policies.kyverno.io/v1
kind: ValidatingPolicy
metadata:
  name: agent-audience-reservation
spec:
  validationActions: [Deny]
  failurePolicy: Ignore
  matchConstraints:
    namespaceSelector:
      matchExpressions:
        - key: kubernetes.io/metadata.name
          operator: NotIn
          values: [agents, kube-system]
    resourceRules:
      - apiGroups: [""]
        apiVersions: [v1]
        operations: [CREATE]
        resources: [pods]
  validations:
    - expression: >-
        !has(object.spec.volumes) || object.spec.volumes.all(v,
          !has(v.projected) || !has(v.projected.sources) || v.projected.sources.all(s,
            !has(s.serviceAccountToken) || !has(s.serviceAccountToken.audience) ||
            !(s.serviceAccountToken.audience.startsWith('agent-router.') ||
              s.serviceAccountToken.audience.startsWith('octo-sts/') ||
              s.serviceAccountToken.audience.startsWith('room-broker'))))
      message: "audiences agent-router.*, octo-sts/* and room-broker* are reserved for namespace agents"
```

`security/base/agent-policies/deletingpolicy.yaml`:

```yaml
---
# Backstop GC behind SP3 deleting runs after harvest (S12). Terminal phases
# only; an age condition needs a CEL time function that is UNVERIFIED (R6).
apiVersion: policies.kyverno.io/v1
kind: DeletingPolicy
metadata:
  name: agentrun-gc
spec:
  schedule: "17 3 * * *"
  matchConstraints:
    resourceRules:
      - apiGroups: [cloud.ogenki.io]
        apiVersions: [v1alpha1]
        operations: ["*"]
        resources: [agentruns]
  conditions:
    - name: terminal-phase
      expression: "has(object.status) && has(object.status.phase) && object.status.phase in ['Succeeded', 'Failed', 'BudgetExhausted', 'Revoked']"
```

`security/base/agent-policies/rbac-cleanup.yaml`:

```yaml
---
# The Kyverno cleanup controller runs DeletingPolicies with its own identity and
# holds no grant on our XRs until this aggregates into it.
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: kyverno:agentrun-gc
  labels:
    rbac.kyverno.io/aggregate-to-cleanup-controller: "true"
rules:
  - apiGroups: [cloud.ogenki.io]
    resources: [agentruns]
    verbs: [get, list, watch, delete]
```

`clusters/aws-0-agent-platform/security-agent-policies.yaml`:

```yaml
---
# Kyverno admission and GC for agent runs. Needs Kyverno (in `security`) and the
# AgentRun XRD (in the crossplane-configuration package).
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: agent-policies
  namespace: flux-system
spec:
  prune: true
  interval: 5m0s
  timeout: 2m0s
  path: ./security/base/agent-policies
  sourceRef:
    kind: ExternalArtifact
    name: security-artifact
  dependsOn:
    - name: security
    - name: crossplane-configuration
```

- [ ] **Step 2: Commit**

```bash
git add security/base/agent-policies clusters/aws-0-agent-platform/security-agent-policies.yaml
git commit -m "feat(security): Kyverno admission and GC for agent runs"
```

### Task 2.6: Vector toleration

**Files:**
- Modify: `observability/base/victoria-logs/vl-common-helm-values-configmap.yaml`

- [ ] **Step 1: Add the toleration at the top of the `vector:` block**

```yaml
    vector:
      # Ship sandbox logs too: the agents-gvisor pool is tainted (SP1 §8).
      tolerations:
        - key: agents.ogenki.io/runtime
          operator: Equal
          value: gvisor
          effect: NoSchedule
```

(the existing `# ====…` pipeline comment and `customConfig` stay below it, unchanged).

- [ ] **Step 2: Render check**

Run: `./scripts/ci/validate-manifests.sh >/dev/null 2>&1; grep -l 'agents.ogenki.io/runtime' .bundle/*.yaml | head -3`
Expected: at least one bundle file containing the Vector DaemonSet with the toleration.

- [ ] **Step 3: Commit**

```bash
git add observability/base/victoria-logs/vl-common-helm-values-configmap.yaml
git commit -m "feat(observability): Vector tolerates the agents gVisor pool"
```

### Task 2.7: Composition pin `v0.8.0`, App Wizard tag, catalog assertion

**Files:**
- Modify: `infrastructure/base/crossplane/configuration-aws/configuration-packages.yaml`
- Modify: `apps/platform/app-wizard/app.yaml` (`--branch=`)
- Modify: `scripts/ci/flux-schema/gen-catalog.sh` (kind loop)

- [ ] **Step 1: Require the AgentRun schema (fails first)**

In `gen-catalog.sh`: `for kind in app sqlinstance inferenceservice epi agentrun; do`

Run: `./scripts/ci/flux-schema/gen-catalog.sh`
Expected: FAIL — `no (or an empty) schema at cloud.ogenki.io/agentrun_v1alpha1.json` (the pin is
still `v0.7.1`).

- [ ] **Step 2: Bump both pins together**

`configuration-packages.yaml`: `package: ghcr.io/smana/crossplane-configuration-aws:v0.8.0`.
`app.yaml`: `- --branch=v0.8.0`.

Run: `./scripts/ci/flux-schema/gen-catalog.sh | grep agentrun`
Expected: `.schemas/cloud.ogenki.io/agentrun_v1alpha1.json`.

- [ ] **Step 3: Commit**

```bash
git add infrastructure/base/crossplane/configuration-aws/configuration-packages.yaml apps/platform/app-wizard/app.yaml scripts/ci/flux-schema/gen-catalog.sh
git commit -m "chore(crossplane): crossplane-configuration v0.8.0 with AgentRun"
```

### Task 2.8: Validate and open PR 2

**Files:** none.

- [ ] **Step 1: Gates**

Run: `./scripts/ci/validate-manifests.sh`
Expected: exit 0, `Invalid: 0, Skipped: 0`. Polaris sees the agent-sandbox controller Deployment and
the Vector DaemonSet; no danger findings.

Run: `task check`
Expected: exit 0.

Run: `./scripts/ci/validate-links.sh && ./scripts/ci/verify-doc-paths.sh`
Expected: exit 0 (the ADR and README name paths that exist).

- [ ] **Step 2: Ship**

`ship-it` (rebase onto `origin/main`, simplify, prune, validate, review, PR). The PR body links the SP1
design and ADR-0041, and states: phase 2 of 6; `agent-platform` stays suspended; SC-01–03 are proven
in Task 2.9 on the branch cluster.

### Task 2.9: [LIVE] SC-01, SC-02, SC-03 on the branch cluster

**Files:** none.

- [ ] **Step 1: Deploy the branch and open the gate**

```bash
cd opentofu && TF_VAR_flux_git_ref=refs/heads/feat/agent-runtime terramate script run deploy
flux resume kustomization ai-gateway -n flux-system
flux resume kustomization agent-platform -n flux-system
flux get kustomizations -n flux-system agent-platform agent-sandbox agents-nodepool runtimeclass-gvisor agent-runtime agent-policies
kubectl get xrd agentruns.cloud.ogenki.io -o jsonpath='{.status.conditions[?(@.type=="Established")].status}{"\n"}'
kubectl auth can-i --as=system:serviceaccount:crossplane-system:crossplane create sandboxes.agents.x-k8s.io -n agents
```
Expected: every Kustomization `Ready=True`; `True`; `yes`.

- [ ] **Step 2: A run (SC-01)**

```bash
kubectl apply -f /home/smana/Sources/crossplane-configuration/examples/agentrun-basic.yaml
kubectl wait -n agents agentrun/xplane-run-7f3cq2xz --for=jsonpath='{.status.phase}'=Running --timeout=15m
POD=xplane-run-7f3cq2xz
kubectl get pod -n agents $POD -o jsonpath='{.spec.runtimeClassName} {.spec.nodeName}{"\n"}'
kubectl get node "$(kubectl get pod -n agents $POD -o jsonpath='{.spec.nodeName}')" -o jsonpath='{.metadata.labels.agents\.ogenki\.io/runtime}{"\n"}'
kubectl exec -n agents $POD -c harness -- dmesg | head -1
```
Expected: `Running`; `gvisor <node>`; `gvisor`; a `Starting gVisor` line.

- [ ] **Step 3: SC-02 on the Flux-provisioned node**

```bash
NODE=$(kubectl get pod -n agents $POD -o jsonpath='{.spec.nodeName}')
kubectl debug node/"$NODE" -n default --profile=general --image=public.ecr.aws/amazonlinux/amazonlinux:2023 -- chroot /host bash -c '
  /usr/local/bin/runsc --version | head -1
  containerd config dump | grep -A4 "runtimes.runsc"
  cat /etc/containerd/runsc.toml'
sleep 20; kubectl logs -n default "$(kubectl get pods -n default -o name | grep node-debugger | head -1)"
kubectl get pods -n default -o name | grep node-debugger | xargs -r kubectl delete -n default
```
Expected: `runsc version release-20260921.0`, the runsc runtime under the **v3** plugin id with
`ConfigPath = "/etc/containerd/runsc.toml"`, and `oci-seccomp = "false"`.

- [ ] **Step 4: SC-03 — admission**

Write `/tmp/agentrun-bad.yaml` with the Write tool:

```yaml
apiVersion: cloud.ogenki.io/v1alpha1
kind: AgentRun
metadata: {name: xplane-run-7f3cq2xz, namespace: agents}
spec: {role: implementer, repository: Smana/cloud-native-ref, principal: "human:1", dataClass: public, branch: main, task: {text: x}}
---
apiVersion: cloud.ogenki.io/v1alpha1
kind: AgentRun
metadata: {name: run-1, namespace: agents}
spec: {role: implementer, repository: Smana/cloud-native-ref, principal: "human:1", dataClass: public, task: {text: x}}
```

```bash
kubectl apply --dry-run=server -n agents -f - <<'YAML'
apiVersion: v1
kind: Pod
metadata: {name: sc03-runc}
spec:
  automountServiceAccountToken: false
  containers: [{name: c, image: busybox}]
YAML
kubectl apply --dry-run=server -n agents -f - <<'YAML'
apiVersion: v1
kind: Pod
metadata: {name: sc03-token}
spec:
  runtimeClassName: gvisor
  automountServiceAccountToken: true
  containers: [{name: c, image: busybox}]
YAML
kubectl apply --dry-run=server -f /tmp/agentrun-bad.yaml
```
Expected: the two pods are denied by `agents-pod-shape` (messages "runs under RuntimeClass gvisor"
and "never mounts a Kubernetes API token"); both claims are denied, the first for `spec.branch: main`
(XRD pattern), the second for its name (XRD CEL, and `agentrun-admission` behind it). Record each
denial message.

- [ ] **Step 5: Logs reach VictoriaLogs**

Run: `curl -s 'https://vl.priv.aws.ogenki.io/select/logsql/query' --data-urlencode 'query=kubernetes.pod_namespace:"agents" | limit 3'`
Expected: at least one line from `xplane-run-7f3cq2xz`.

- [ ] **Step 6: Clean up and record**

```bash
kubectl delete agentrun -n agents xplane-run-7f3cq2xz --wait
kubectl get sa,cm,cnp,sandbox,pod -n agents -l agents.ogenki.io/run-id=7f3cq2xz
```
Expected: `No resources found`. Paste the outputs of Steps 1–5 into the PR as the SC-01–03 evidence.

---
## Phase 3 — Gateway and secrets (PR 3, branch `feat/agent-router`)

**Precondition: SP4 PR 1 is merged.** Check in the fresh worktree:

```bash
test -f clusters/aws-0/ai-gateway.yaml && grep -l 'name: envoy-ai-gateway$' clusters/aws-0-ai-gateway/*.yaml
```
Expected: one path printed. If not, stop: this phase depends on the `ai-gateway` umbrella.

Gate: SC-05, SC-10, SC-17 (listener half).

### Task 3.1: Worktree and ADR-0042

**Files:**
- Create: `website/content/docs/decisions/0042-agent-router-identity-gateway.md`
- Modify: `website/content/docs/decisions/_index.md`

- [ ] **Step 1: Worktree**

`EnterWorktree` with branch `feat/agent-router`, then the precondition check above.

- [ ] **Step 2: Write the ADR**

`website/content/docs/decisions/0042-agent-router-identity-gateway.md` (set **Date** to the commit
day):

```markdown
---
title: Agent Router is the agents' identity gateway, with role and data class encoded in the token audience and an in-pod proxy holding the tokens
linkTitle: 0042 · Agent identity gateway
weight: 420
description: Agent runs reach models and MCP tools only through a dedicated agent-router Gateway, one listener per data class, validating the run's projected ServiceAccount token offline. Role and data class travel in the audience because Envoy Gateway matches claims exactly. An Envoy sidecar in each sandbox holds the run-long tokens (R2) and injects them, so the harness never does. agentgateway, per-route policies and a run-long harness key were rejected.
lastVerified: 2026-09-25
---

**Status**: Accepted
**Date**: 2026-09-25
**Deciders**: Smana (Platform Owner)
**Related Spec**: [SP1 — Agent runtime & identity](https://github.com/Smana/cloud-native-ref/blob/main/docs/superpowers/specs/2026-09-23-agent-runtime-identity-design.md)

---

## Context

An agent run must call models and read-only MCP tools under its own identity (programme D3), without
ever holding a provider key, and `internal` data must never reach a SaaS model (OD-13). Envoy Gateway
1.9.1 validates JWTs against a remote JWKS and copies claims into headers, but matches claims
**exactly** and cannot address the nested `kubernetes.io` claim. OpenHands reads its LLM key once per
conversation, and under gVisor a rotated projected token never reaches a reader inside the pod (SP1
spike Q2), so each token lives until its run's deadline (R2, C3).

---

## Decision Drivers

- A token copied out of a sandbox must die with its run, at the run's deadline (R2)
- "`internal` never reaches Z.ai" must hold by construction, not by a rule evaluated after routing
- No provider key in namespace `agents`
- One harness-neutral localhost contract

---

## Considered Options

### Option 1: Agent Router (Envoy AI Gateway) on its own `agent-router` Gateway, one listener per class

**Pros**:
- JWT validation, `claimToHeaders`, early header removal, MCPRoute `oauth` and per-tool authorization,
  and API-key injection are all in the pinned Agent Router 1.1.0 / Envoy Gateway 1.9.1 schemas
- The listener rejects the other class's token before routing; Z.ai routes attach to `public` only

**Cons**:
- Offline validation: a copied token is valid until `exp`, the run's deadline (R2)
- EG cannot prefix-match `sub`: a Kyverno audience reservation and a data-plane CNP admitting only
  `agents` pods close that gap

### Option 2: agentgateway at the agent boundary

**Pros**:
- CEL authorization might express the `sub` prefix (UNVERIFIED); an RFC 8693 client

**Cons**:
- A second gateway product beside the one the platform runs; its distinct OSS feature is unused by
  autonomous agents (programme D11)

### Option 3: One listener, per-route SecurityPolicies

**Cons**:
- Two routes on one listener both match `x-ai-eg-model`, and a route-level policy runs only after the
  route is chosen: the class boundary would depend on filter order

### Option 4: The run's token passed as the harness's API key

**Cons**:
- The harness, which the agent drives through a shell, would hold the token, so one prompt injection
  exfiltrates it. Tokens are run-long under R2 either way; the proxy keeps them out of the agent's reach

---

## Decision Outcome

**Chosen option**: "Agent Router on a dedicated `agent-router` Gateway, one listener per class", with
audiences `agent-router.<role>.<dataClass>` and an in-pod Envoy `identity-proxy` (`credential_injector`
fed by file SDS) as the only token holder.

**Rationale**: It is the only shape where the class boundary and the key boundary are both
structural, using controllers the platform already runs.

---

## Consequences

### Positive

- Agents and humans use separate Gateways and separate provider keys (C1)
- Every harness gets the same contract: `127.0.0.1:4000` (public), `:4002` (internal), `:4001`
  (octo-sts)

### Negative

- The harness can still *use* its credential through localhost; the boundary is what the credential
  can reach, not whether the agent can call it
- Whether identity reaches MCP backends is UNVERIFIED (C5); SP2 carries the fallback
- Tokens live until the run's deadline, not 600 s (R2): under gVisor kubelet's rotation raises no
  inotify, so the file watch never reloads. A Lua filter re-reading the token per request would keep
  600 s (a re-read does see the new file) and was not taken: more proxy code for a window that only
  matters after a sandbox compromise

### Neutral

- SP4 owns the model mapping behind each listener and the budget rules on this Gateway

---

## Implementation Notes

`infrastructure/base/agent-router/`, `infrastructure/base/agent-runtime/identity-proxy-configmap.yaml`,
Kyverno `agent-audience-reservation`. Secrets through `security/base/agent-secrets/` only.

---

## References

- [Agent Router v1.1 notes](https://theagentrouter.ai/release-notes/v1.1/)
- [Envoy credential_injector](https://www.envoyproxy.io/docs/envoy/latest/configuration/http/http_filters/credential_injector_filter)
- [Kubernetes projected ServiceAccount tokens](https://kubernetes.io/docs/concepts/storage/projected-volumes/)
```

Append to `_index.md` after the 0041 row:

```markdown
| [0042]({{< relref "/docs/decisions/0042-agent-router-identity-gateway.md" >}}) | Agent Router is the agents' identity gateway, with role and data class encoded in the token audience and an in-pod proxy holding the tokens | Accepted | 2026-09-25 |
```

- [ ] **Step 3: Commit**

```bash
git add website/content/docs/decisions/0042-agent-router-identity-gateway.md website/content/docs/decisions/_index.md
git commit -m "docs(adr): 0042 agent identity gateway"
```

### Task 3.2: OpenBao policy and JWT role for `agents-secrets`

**Files:**
- Create: `opentofu/aws/openbao/management/policies/agents-secrets.hcl`
- Modify: `opentofu/aws/openbao/management/policies.tf`
- Modify: `opentofu/aws/eks/configure/openbao.tf` (`local.openbao_roles`)

**Interfaces:**
- Produces: OpenBao policy `agents-secrets`; JWT role `agents-secrets` on `jwt/<cluster>` bound to
  `system:serviceaccount:agent-system:agents-secrets`, audience `openbao`. Task 3.3's SecretStore logs
  in with them.

- [ ] **Step 1: Policy**

`opentofu/aws/openbao/management/policies/agents-secrets.hcl`:

```hcl
# agent-system's namespaced SecretStore reads the agents' own prefix and nothing
# else (SP1 S9). Not `external-secrets`: that identity reads all of platform/ and
# apps/, through a ClusterSecretStore any namespace can use (T14).

path "platform/data/agents/*" {
  capabilities = ["read"]
}

path "platform/metadata/agents/*" {
  capabilities = ["read", "list"]
}

path "auth/token/lookup-self" {
  capabilities = ["read"]
}

path "auth/token/renew-self" {
  capabilities = ["update"]
}
```

Append to `opentofu/aws/openbao/management/policies.tf`:

```hcl
# agent-system's own store (SP1 S9): platform/agents/* only. Attached to the
# `agents-secrets` JWT role in eks/configure by NAME, like `external-secrets`.
resource "vault_policy" "agents_secrets" {
  name   = "agents-secrets"
  policy = file("policies/agents-secrets.hcl")
}
```

- [ ] **Step 2: Role**

In `opentofu/aws/eks/configure/openbao.tf`, add to `local.openbao_roles`:

```hcl
    agents-secrets = {
      service_account = "agents-secrets"
      namespace       = "agent-system"
      # SP1 S9: the agent-system SecretStore, platform/agents/* and nothing else.
      policies = ["default", "agents-secrets"]
    }
```

- [ ] **Step 3: Validate**

```bash
(cd opentofu/aws/openbao/management && tofu init -backend=false -input=false >/dev/null && tofu validate)
(cd opentofu/aws/eks/configure && tofu init -backend=false -input=false >/dev/null && tofu validate)
trivy config --exit-code=1 --ignorefile=./.trivyignore.yaml opentofu/aws/openbao/management opentofu/aws/eks/configure
```
Expected: `Success! The configuration is valid.` twice; trivy exit 0.

- [ ] **Step 4: Commit**

```bash
git add opentofu/aws/openbao/management/policies/agents-secrets.hcl opentofu/aws/openbao/management/policies.tf opentofu/aws/eks/configure/openbao.tf
git commit -m "feat(openbao): agents-secrets policy and JWT role scoped to platform/agents"
```

### Task 3.3: The `agents-secrets` SecretStore

**Files:**
- Create: `security/base/agent-secrets/{kustomization.yaml,serviceaccount.yaml,secretstore.yaml,externalsecret-openbao-ca.yaml}`
- Create: `clusters/aws-0-agent-platform/security-agent-secrets.yaml`
- Modify: `clusters/aws-0-agent-platform/kustomization.yaml` (add `security-agent-secrets.yaml`)

**Interfaces:**
- Consumes: Task 3.2 role.
- Produces: `SecretStore agents-secrets` in `agent-system` (kv-v2 mount `platform`, so a `remoteRef.key`
  is `agents/<name>`). Consumed by Tasks 3.4 and 4.3, and later by SP3/SP4.

- [ ] **Step 1: Manifests**

`security/base/agent-secrets/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - serviceaccount.yaml
  - externalsecret-openbao-ca.yaml
  - secretstore.yaml
```

`security/base/agent-secrets/serviceaccount.yaml`:

```yaml
---
# The identity External Secrets presents to OpenBao for agent-system's store.
# The JWT role binds exactly this subject (opentofu/aws/eks/configure/openbao.tf).
apiVersion: v1
kind: ServiceAccount
metadata:
  name: agents-secrets
  namespace: agent-system
automountServiceAccountToken: false
```

`security/base/agent-secrets/externalsecret-openbao-ca.yaml`:

```yaml
---
# A namespaced SecretStore can only read its CA from its own namespace, so the
# OpenBao chain is copied here. Certificates only (intermediate, then root): no
# credential crosses the agents-secrets boundary this way. Same source as
# security/aws-0/openbao/openbao-ca-externalsecret.yaml.
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: openbao-ca
  namespace: agent-system
spec:
  refreshInterval: 1h
  secretStoreRef:
    kind: ClusterSecretStore
    name: clustersecretstore
  target:
    name: openbao-ca
    creationPolicy: Owner
    deletionPolicy: Retain
  data:
    - secretKey: ca.crt  # pragma: allowlist secret
      remoteRef:
        key: certificates/${private_domain_name}/ca-chain
        property: ca
```

`security/base/agent-secrets/secretstore.yaml`:

```yaml
---
# agent-system's only way to secrets (C1, S9). Its OpenBao role reads
# platform/agents/* and nothing else, and only this namespace can use it: the
# cluster-wide openbao-platform store has no namespace conditions (T14).
apiVersion: external-secrets.io/v1
kind: SecretStore
metadata:
  name: agents-secrets
  namespace: agent-system
spec:
  provider:
    vault:
      server: "https://openbao.security.svc.cluster.local:8200"
      path: "platform"
      version: "v2"
      caProvider:
        type: Secret
        name: openbao-ca
        key: ca.crt
      auth:
        jwt:
          path: "jwt/${cluster_name}"
          role: "agents-secrets"
          kubernetesServiceAccountToken: # pragma: allowlist secret
            serviceAccountRef:
              name: agents-secrets
            audiences:
              - openbao
```

`clusters/aws-0-agent-platform/security-agent-secrets.yaml`:

```yaml
---
# agent-system's namespaced SecretStore (SP1 S9). After security-openbao, which
# installs the ESO webhook's stores and the openbao endpoint.
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: agent-secrets
  namespace: flux-system
spec:
  prune: true
  interval: 5m0s
  timeout: 3m0s
  path: ./security/base/agent-secrets
  sourceRef:
    kind: ExternalArtifact
    name: security-artifact
  postBuild:
    substituteFrom:
      - kind: ConfigMap
        name: eks-aws-0-vars
  dependsOn:
    - name: security-openbao
  healthCheckExprs:
    - apiVersion: external-secrets.io/v1
      kind: SecretStore
      current: status.conditions.filter(c, c.type == 'Ready').all(c, c.status == 'True')
      failed: status.conditions.filter(c, c.type == 'Ready').all(c, c.status == 'False')
```

Add `- security-agent-secrets.yaml` to `clusters/aws-0-agent-platform/kustomization.yaml`.

- [ ] **Step 2: Substitution gate and commit**

Run: `python3 scripts/ci/flux-schema/check-substitution.py`
Expected: exit 0 (`cluster_name` and `private_domain_name` are in `eks-aws-0-vars`).

```bash
git add security/base/agent-secrets clusters/aws-0-agent-platform/security-agent-secrets.yaml clusters/aws-0-agent-platform/kustomization.yaml
git commit -m "feat(security): agents-secrets store for agent-system"
```

- [ ] **Step 3: [OWNER] The agents' own Z.ai key**

Ask the owner to create a **dedicated** Z.ai API key for agents (not RunLore's, SP4 S12) and write it:
`bao kv put platform/agents/zai api_key=<key>`. The executor never handles the value.

### Task 3.4: The `agent-router` Gateway

**Files:**
- Create: `infrastructure/base/agent-router/{kustomization.yaml,gateway.yaml,envoyproxy.yaml,securitypolicy-public.yaml,securitypolicy-internal.yaml,clienttrafficpolicy.yaml,backend-zai.yaml,externalsecret-zai.yaml,aigatewayroute-agent-models.yaml,network-policy-data-plane.yaml}`
- Create: `clusters/aws-0-agent-platform/infrastructure-agent-router.yaml`
- Modify: `clusters/aws-0-agent-platform/kustomization.yaml`, `clusters/aws-0/agent-platform.yaml`
  (`dependsOn: ai-gateway`), `clusters/aws-0-agent-platform/README.md` (two rows)
- Not set here: `EnvoyProxy.spec.provider.kubernetes.envoyServiceAccount` (SP4 PR 2 adds
  `xplane-agent-router-bedrock` and owns its EPI)

**Interfaces:**
- Consumes: GatewayClass `envoy-ai-gateway`, Kustomization `envoy-ai-gateway` (SP4 PR 1);
  `SecretStore agents-secrets` (Task 3.3); `${oidc_issuer_url}`, `${oidc_issuer_host}`.
- Produces: Service `agent-router.envoy-gateway-system.svc.cluster.local` ports 8080/8081 (the
  identity-proxy clusters of Task 0.1); data-plane pods labelled
  `gateway.envoyproxy.io/owning-gateway-name: agent-router` (the run CNP of Task 1.3); access-log
  fields `x_ar_agent`, `listener_port`, `upstream_cluster`, `response_code` (Tasks 3.8, 6.4).

- [ ] **Step 1: Gateway, proxy shape, access log**

`infrastructure/base/agent-router/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

# The agents' Gateway (SP1 S6, C1). SP4 owns the model mapping behind each
# listener from its PR 2 (agent-models tiers, agent-models-internal, B1-B2).
resources:
  - envoyproxy.yaml
  - gateway.yaml
  - clienttrafficpolicy.yaml
  - securitypolicy-public.yaml
  - securitypolicy-internal.yaml
  - externalsecret-zai.yaml
  - backend-zai.yaml
  - aigatewayroute-agent-models.yaml
  # Lives in envoy-gateway-system, where Envoy Gateway runs the data plane.
  - network-policy-data-plane.yaml
```

`infrastructure/base/agent-router/gateway.yaml`:

```yaml
---
# One listener per data class (S6): "internal never reaches Z.ai" is structural.
# Each listener accepts only its class's audiences, and Z.ai routes attach to
# `public` only. Only routes from agent-system attach.
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: agent-router
  namespace: agent-system
spec:
  gatewayClassName: envoy-ai-gateway
  listeners:
    - name: public
      protocol: HTTP
      port: 8080
      allowedRoutes:
        namespaces:
          from: Same
    - name: internal
      protocol: HTTP
      port: 8081
      allowedRoutes:
        namespaces:
          from: Same
  infrastructure:
    parametersRef:
      group: gateway.envoyproxy.io
      kind: EnvoyProxy
      name: agent-router-proxy
```

`infrastructure/base/agent-router/envoyproxy.yaml`:

```yaml
---
# Data-plane shape of the agents' Gateway. The Service name is pinned because
# the identity-proxy bootstrap and every run CNP name it.
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: EnvoyProxy
metadata:
  name: agent-router-proxy
  namespace: agent-system
spec:
  provider:
    type: Kubernetes
    kubernetes:
      envoyService:
        name: agent-router
        type: ClusterIP
      envoyDeployment:
        replicas: 1
        container:
          resources:
            requests:
              cpu: 100m
              memory: 256Mi
            limits:
              cpu: "1"
              memory: 512Mi
          securityContext:
            runAsNonRoot: true
            readOnlyRootFilesystem: true
            allowPrivilegeEscalation: false
            capabilities:
              drop: ["ALL"]
            seccompProfile:
              type: RuntimeDefault
  # x_ar_agent is the VERIFIED sub (the client's copy is stripped first), so
  # every line attributes a request to the run that made it (SC-05, T8).
  telemetry:
    accessLog:
      settings:
        - format:
            type: JSON
            json:
              start_time: "%START_TIME%"
              method: "%REQ(:METHOD)%"
              path: "%REQ(X-ENVOY-ORIGINAL-PATH?:PATH)%"
              response_code: "%RESPONSE_CODE%"
              response_flags: "%RESPONSE_FLAGS%"
              listener_port: "%DOWNSTREAM_LOCAL_PORT%"
              upstream_cluster: "%UPSTREAM_CLUSTER%"
              upstream_host: "%UPSTREAM_HOST%"
              x_ar_agent: "%REQ(X-AR-AGENT)%"
              model: "%REQ(X-AI-EG-MODEL)%"
              duration_ms: "%DURATION%"
          sinks:
            - type: File
              file:
                path: /dev/stdout
```

- [ ] **Step 2: Authentication and header hygiene**

`infrastructure/base/agent-router/clienttrafficpolicy.yaml`:

```yaml
---
# Runs before authentication. claim_to_headers APPENDS, so a client-sent
# identity header would survive next to the verified one (C5). Whole-Gateway,
# same namespace, all four headers: the shape SP4's render gate A3 requires.
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: ClientTrafficPolicy
metadata:
  name: agent-router
  namespace: agent-system
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: Gateway
      name: agent-router
  headers:
    earlyRequestHeaders:
      remove:
        - x-ar-agent
        - x-ar-human
        - x-ai-gateway-client-id
        - agent-session-id
  connection:
    bufferLimit: 8Mi
```

`infrastructure/base/agent-router/securitypolicy-public.yaml`:

```yaml
---
# The `public` listener accepts exactly the four `.public` audiences (C2): an
# internal-class or octo-sts token is a 401 here. EKS JWKS is served at
# <issuer>/keys; validation is offline, so a copied token lives until exp (the run's deadline, R2).
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: SecurityPolicy
metadata:
  name: agent-router-public
  namespace: agent-system
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: Gateway
      name: agent-router
      sectionName: public
  jwt:
    providers:
      - name: eks-agents-public
        issuer: ${oidc_issuer_url}
        audiences:
          - agent-router.implementer.public
          - agent-router.reviewer.public
          - agent-router.tester.public
          - agent-router.triager.public
        remoteJWKS:
          uri: ${oidc_issuer_url}/keys
        claimToHeaders:
          - claim: sub
            header: x-ar-agent
```

`infrastructure/base/agent-router/securitypolicy-internal.yaml`:

```yaml
---
# The `internal` listener: the same four roles, class `.internal` (4 of EG's
# 8-audience maximum). Its routes (Bedrock EU, self-hosted) are SP4's.
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: SecurityPolicy
metadata:
  name: agent-router-internal
  namespace: agent-system
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: Gateway
      name: agent-router
      sectionName: internal
  jwt:
    providers:
      - name: eks-agents-internal
        issuer: ${oidc_issuer_url}
        audiences:
          - agent-router.implementer.internal
          - agent-router.reviewer.internal
          - agent-router.tester.internal
          - agent-router.triager.internal
        remoteJWKS:
          uri: ${oidc_issuer_url}/keys
        claimToHeaders:
          - claim: sub
            header: x-ar-agent
```

- [ ] **Step 3: The agents' Z.ai backend and the seed route**

`infrastructure/base/agent-router/externalsecret-zai.yaml`:

```yaml
---
# The agents' OWN Z.ai key (SP4 S12), never the platform one: revoking it never
# breaks RunLore or chat, and provider-side spend splits by key.
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: agents-zai-api-key
  namespace: agent-system
spec:
  refreshInterval: 1h
  secretStoreRef:
    kind: SecretStore
    name: agents-secrets
  target:
    name: agents-zai-api-key
    creationPolicy: Owner
    deletionPolicy: Retain
  data:
    # Agent Router reads the key under `apiKey`.
    - secretKey: apiKey  # pragma: allowlist secret
      remoteRef:
        key: agents/zai
        property: api_key  # pragma: allowlist secret
```

`infrastructure/base/agent-router/backend-zai.yaml`:

```yaml
---
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: Backend
metadata:
  name: zai
  namespace: agent-system
spec:
  endpoints:
    - fqdn:
        hostname: api.z.ai
        port: 443
---
apiVersion: gateway.networking.k8s.io/v1
kind: BackendTLSPolicy
metadata:
  name: zai
  namespace: agent-system
spec:
  targetRefs:
    - group: gateway.envoyproxy.io
      kind: Backend
      name: zai
  validation:
    wellKnownCACertificates: System
    hostname: api.z.ai
---
# RunLore's working base_url is https://api.z.ai/api/paas/v4/.
apiVersion: aigateway.envoyproxy.io/v1beta1
kind: AIServiceBackend
metadata:
  name: zai
  namespace: agent-system
spec:
  schema:
    name: OpenAI
    prefix: /api/paas/v4
  backendRef:
    group: gateway.envoyproxy.io
    kind: Backend
    name: zai
---
apiVersion: aigateway.envoyproxy.io/v1beta1
kind: BackendSecurityPolicy
metadata:
  name: zai-api-key
  namespace: agent-system
spec:
  type: APIKey
  apiKey:
    secretRef:
      name: agents-zai-api-key
  targetRefs:
    - group: aigateway.envoyproxy.io
      kind: AIServiceBackend
      name: zai
```

`infrastructure/base/agent-router/aigatewayroute-agent-models.yaml`:

```yaml
---
# C5 logical names on the `public` listener. SP1 seeds `agent-default` only;
# SP4 owns this file from its PR 2 and adds agent-models-internal on `internal`.
# One backendRef at weight 100 per rule: nothing re-routes a trajectory.
apiVersion: aigateway.envoyproxy.io/v1beta1
kind: AIGatewayRoute
metadata:
  name: agent-models
  namespace: agent-system
spec:
  parentRefs:
    - group: gateway.networking.k8s.io
      kind: Gateway
      name: agent-router
      sectionName: public
  rules:
    - matches:
        - headers:
            - type: Exact
              name: x-ai-eg-model
              value: agent-default
      backendRefs:
        - name: zai
          modelNameOverride: glm-5.2
          weight: 100
```

- [ ] **Step 4: Data-plane CNP**

`infrastructure/base/agent-router/network-policy-data-plane.yaml`:

```yaml
---
# Data plane of the agents' Gateway. Envoy Gateway runs it in its own namespace
# whatever the Gateway's, so this CNP lives there. Scoped by gateway name, as is
# envoy-data-plane (narrowed by SP4 PR 1), so neither Gateway inherits the
# other's allows (R5). SP4 PR 2 adds the Bedrock egress here.
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: agent-router-data-plane
  namespace: envoy-gateway-system
spec:
  endpointSelector:
    matchLabels:
      app.kubernetes.io/managed-by: envoy-gateway
      app.kubernetes.io/component: proxy
      gateway.envoyproxy.io/owning-gateway-name: agent-router
  ingress:
    # Sandbox pods only. EG cannot prefix-match `sub`; this and the Kyverno
    # audience reservation are what keep other namespaces' tokens out.
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
    - fromEntities:
        - host
      toPorts:
        - ports:
            - port: "8080"
              protocol: TCP
            - port: "8081"
              protocol: TCP
    - fromEndpoints:
        - matchLabels:
            io.kubernetes.pod.namespace: observability
      toPorts:
        - ports:
            - port: "19001"
              protocol: TCP
    - fromEndpoints:
        - matchLabels:
            io.kubernetes.pod.namespace: observability
            app.kubernetes.io/name: vmagent
      toPorts:
        - ports:
            - port: "1064"
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
            io.kubernetes.pod.namespace: envoy-gateway-system
            control-plane: envoy-gateway
      toPorts:
        - ports:
            - port: "18000"
              protocol: TCP
    # The agents' provider and the JWKS the listeners validate against.
    - toFQDNs:
        - matchName: api.z.ai
        - matchName: ${oidc_issuer_host}
      toPorts:
        - ports:
            - port: "443"
              protocol: TCP
    # Read-only MCP servers (phase 5) and SP2's room broker MCP port.
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

- [ ] **Step 5: Child Kustomization, umbrella dependency**

`clusters/aws-0-agent-platform/infrastructure-agent-router.yaml`:

```yaml
---
# The agents' Gateway on the ai-gateway umbrella's controllers (C1).
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: agent-router
  namespace: flux-system
spec:
  prune: true
  interval: 5m0s
  timeout: 5m0s
  path: ./infrastructure/base/agent-router
  sourceRef:
    kind: ExternalArtifact
    name: infra-artifact
  postBuild:
    substituteFrom:
      - kind: ConfigMap
        name: eks-aws-0-vars
  dependsOn:
    - name: envoy-ai-gateway
    - name: agent-secrets
  healthCheckExprs:
    - apiVersion: gateway.networking.k8s.io/v1
      kind: Gateway
      current: status.conditions.filter(c, c.type == 'Programmed').all(c, c.status == 'True')
      failed: status.conditions.filter(c, c.type == 'Programmed').all(c, c.status == 'False')
```

Add `- infrastructure-agent-router.yaml` to `clusters/aws-0-agent-platform/kustomization.yaml`. In
`clusters/aws-0/agent-platform.yaml`, under `spec`:

```yaml
  # Agents run on frontier models through the ai-gateway controllers, with zero
  # GPUs: never llm-platform (C1).
  dependsOn:
    - name: ai-gateway
```

Add to the README table:

```markdown
| `agent-secrets` | `security/base/agent-secrets` | `SecretStore agents-secrets` → `platform/agents/*` |
| `agent-router` | `infrastructure/base/agent-router` | `agent-router` Gateway, JWT per listener, the agents' Z.ai backend |
```

- [ ] **Step 6: Commit**

```bash
git add infrastructure/base/agent-router clusters/aws-0-agent-platform clusters/aws-0/agent-platform.yaml
git commit -m "feat(agents): agent-router Gateway with one JWT listener per data class"
```

### Task 3.5: Confirm `envoy-data-plane` is already scoped to `ai-gateway`

SP4 PR 1 narrows the existing `envoy-data-plane` CNP (it adds `api.z.ai` egress there, which must
not leak onto `agent-router`). This phase does **not** edit that file; it only checks the
precondition, because without it `agent-router` would inherit every `ai-gateway` allow (R5).

**Files:** none.

- [ ] **Step 1: Check**

Run: `python3 -c "import yaml; d=[x for x in yaml.safe_load_all(open('infrastructure/base/envoy-gateway/network-policy.yaml')) if x and x['metadata']['name']=='envoy-data-plane'][0]; print(d['spec']['endpointSelector']['matchLabels'].get('gateway.envoyproxy.io/owning-gateway-name'))"`
Expected: `ai-gateway`. Anything else: stop and raise it with the SP4 owner; do not narrow it here.

### Task 3.6: The identity probe

**Files:**
- Create: `scripts/ops/k8s/agent-probe.yaml`
- Modify: `scripts/README.md` (the `ops/aws/`, `ops/gcp/`, `ops/k8s/` row mentions it)

**Interfaces:**
- Produces: Sandbox `agents/agent-probe` (pod label `agents.ogenki.io/run-id: probe000`, container
  `probe`), tokens at `/var/run/secrets/probe/{public,internal,sts}/token`, SA `agent-probe`
  (sub `system:serviceaccount:agents:agent-probe`). Used by Tasks 3.8, 5.6 and `/verify-spec`.

- [ ] **Step 1: The manifest**

`scripts/ops/k8s/agent-probe.yaml`:

```yaml
# Throwaway identity probe for SP1 verification. A Sandbox in `agents` whose
# curl container holds three tokens a real run never shows its harness: the
# gateway audience of each class, and the octo-sts one. Apply, test, delete in
# the same session:
#   kubectl apply -f scripts/ops/k8s/agent-probe.yaml
#   kubectl delete -f scripts/ops/k8s/agent-probe.yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: agent-probe
  namespace: agents
automountServiceAccountToken: false
---
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: agent-probe
  namespace: agents
spec:
  endpointSelector:
    matchLabels:
      agents.ogenki.io/run-id: probe000
  egress:
    - toEndpoints:
        - matchLabels:
            io.kubernetes.pod.namespace: kube-system
            k8s-app: kube-dns
      toPorts:
        - ports:
            - port: "53"
              protocol: UDP
          rules:
            dns:
              - matchPattern: "*"
    - toEndpoints:
        - matchLabels:
            io.kubernetes.pod.namespace: envoy-gateway-system
            gateway.envoyproxy.io/owning-gateway-name: agent-router
      toPorts:
        - ports:
            - port: "8080"
              protocol: TCP
            - port: "8081"
              protocol: TCP
    - toEndpoints:
        - matchLabels:
            io.kubernetes.pod.namespace: agent-system
            app.kubernetes.io/name: octo-sts
      toPorts:
        - ports:
            - port: "8080"
              protocol: TCP
---
apiVersion: agents.x-k8s.io/v1beta1
kind: Sandbox
metadata:
  name: agent-probe
  namespace: agents
spec:
  service: false
  podTemplate:
    metadata:
      labels:
        agents.ogenki.io/run-id: probe000
        agents.ogenki.io/role: implementer
    spec:
      serviceAccountName: agent-probe
      automountServiceAccountToken: false
      runtimeClassName: gvisor
      restartPolicy: Never
      activeDeadlineSeconds: 3600
      securityContext:
        runAsNonRoot: true
        runAsUser: 10001
        runAsGroup: 10001
        fsGroup: 10001
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: probe
          image: docker.io/curlimages/curl:8.22.0@sha256:58adaa4e8dca9c988bae2aba4ab3434a0bb2da16bbe3f92dec39ec7785166777
          command: ["sleep", "3600"]
          resources:
            requests: {cpu: 10m, memory: 16Mi}
            limits: {cpu: 100m, memory: 64Mi}
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            runAsNonRoot: true
            capabilities:
              drop: ["ALL"]
            seccompProfile:
              type: RuntimeDefault
          volumeMounts:
            - {name: public, mountPath: /var/run/secrets/probe/public, readOnly: true}
            - {name: internal, mountPath: /var/run/secrets/probe/internal, readOnly: true}
            - {name: sts, mountPath: /var/run/secrets/probe/sts, readOnly: true}
            - {name: tmp, mountPath: /tmp}
      volumes:
        - name: tmp
          emptyDir: {medium: Memory, sizeLimit: 1Mi}
        - name: public
          projected:
            sources:
              - serviceAccountToken: {audience: agent-router.implementer.public, expirationSeconds: 600, path: token}
        - name: internal
          projected:
            sources:
              - serviceAccountToken: {audience: agent-router.implementer.internal, expirationSeconds: 600, path: token}
        - name: sts
          projected:
            sources:
              - serviceAccountToken: {audience: octo-sts/Smana/cloud-native-ref/implementer, expirationSeconds: 600, path: token}
```

In `scripts/README.md`, append to the `ops/aws/`, `ops/gcp/`, `ops/k8s/` row: "`ops/k8s/agent-probe.yaml`
is the throwaway identity probe for SP1 verification".

- [ ] **Step 2: Commit**

```bash
git add scripts/ops/k8s/agent-probe.yaml scripts/README.md
git commit -m "chore(scripts): throwaway identity probe for agent-router checks"
```

### Task 3.7: Validate and open PR 3

- [ ] **Step 1: Gates**

Run: `./scripts/ci/validate-manifests.sh`
Expected: exit 0, `Invalid: 0, Skipped: 0` (SecurityPolicy, ClientTrafficPolicy, Backend,
BackendTLSPolicy, the Agent Router kinds, SecretStore all validate).

Run: `task check && ./scripts/ci/validate-links.sh`
Expected: exit 0 both.

- [ ] **Step 2: Ship**

`ship-it`. PR body: phase 3 of 6; depends on SP4 PR 1 (link it); ADR-0042; the OpenBao stacks need a
`terramate script run deploy` of `aws/openbao/management` then `aws/eks/configure` after merge; the
owner's Z.ai key at `platform/agents/zai`.

### Task 3.8: [LIVE] SC-05, SC-10, SC-17 (listener half), R5

**Files:** none.

- [ ] **Step 1: Deploy the branch and the two OpenBao stacks**

```bash
cd opentofu && TF_VAR_flux_git_ref=refs/heads/feat/agent-router terramate script run deploy
flux resume kustomization ai-gateway -n flux-system
flux resume kustomization agent-platform -n flux-system
flux get kustomizations -n flux-system agent-secrets agent-router
kubectl get secretstore -n agent-system agents-secrets -o jsonpath='{.status.conditions[0].status}{"\n"}'
kubectl get externalsecret -n agent-system agents-zai-api-key -o jsonpath='{.status.conditions[0].reason}{"\n"}'
```
Expected: both Kustomizations `Ready=True`; `True`; `SecretSynced` (needs the owner's key, Task 3.3
Step 3).

- [ ] **Step 2: R5 — the gateway-name label exists**

```bash
kubectl get pods -n envoy-gateway-system -l gateway.envoyproxy.io/owning-gateway-name=agent-router -o name
kubectl get pods -n envoy-gateway-system -l gateway.envoyproxy.io/owning-gateway-name=ai-gateway -o name
```
Expected: one pod each. If either is empty, **stop**: both data-plane CNPs select nothing, and the
SP4 PR 1's narrowing has cut `ai-gateway` traffic. Fix the selector before continuing.

- [ ] **Step 3: SC-05 — the 401 matrix and the forged header**

```bash
kubectl apply -f scripts/ops/k8s/agent-probe.yaml
kubectl wait -n agents sandbox/agent-probe --for=condition=Ready --timeout=10m
R=http://agent-router.envoy-gateway-system.svc.cluster.local
p() { kubectl exec -n agents agent-probe -c probe -- sh -c "$1"; }
p "curl -s -o /dev/null -w 'none→public %{http_code}\n' $R:8080/v1/models"
p "curl -s -o /dev/null -w 'sts→public %{http_code}\n' -H \"Authorization: Bearer \$(cat /var/run/secrets/probe/sts/token)\" $R:8080/v1/models"
p "curl -s -o /dev/null -w 'internal→public %{http_code}\n' -H \"Authorization: Bearer \$(cat /var/run/secrets/probe/internal/token)\" $R:8080/v1/models"
p "curl -s -o /dev/null -w 'public→internal %{http_code}\n' -H \"Authorization: Bearer \$(cat /var/run/secrets/probe/public/token)\" $R:8081/v1/models"
p "curl -s -o /dev/null -w 'public→public %{http_code}\n' -H \"Authorization: Bearer \$(cat /var/run/secrets/probe/public/token)\" $R:8080/v1/models"
ISSUER=$(kubectl get --raw /.well-known/openid-configuration | jq -r .issuer)
FORGED=$(ISSUER="$ISSUER" python3 -c 'import base64,hashlib,hmac,json,os,time
enc=lambda d: base64.urlsafe_b64encode(json.dumps(d).encode()).rstrip(b"=").decode()
h=enc({"alg":"HS256","typ":"JWT"}); b=enc({"iss":os.environ["ISSUER"],"aud":"agent-router.implementer.public","sub":"system:serviceaccount:agents:forged","exp":int(time.time())+600})
print(h+"."+b+"."+base64.urlsafe_b64encode(hmac.new(b"not-the-issuer-key",(h+"."+b).encode(),hashlib.sha256).digest()).rstrip(b"=").decode())')
p "curl -s -o /dev/null -w 'self-signed→public %{http_code}\n' -H 'Authorization: Bearer $FORGED' $R:8080/v1/models"
p "curl -s -o /dev/null -w 'forged-header %{http_code}\n' -H 'x-ar-agent: agent:forged' -H \"Authorization: Bearer \$(cat /var/run/secrets/probe/public/token)\" -H 'content-type: application/json' -d '{\"model\":\"agent-default\",\"messages\":[{\"role\":\"user\",\"content\":\"Reply with OK.\"}]}' $R:8080/v1/chat/completions"
```
Expected: `none→public 401`, `sts→public 401`, `internal→public 401`, `public→internal 401`,
`public→public 200`, `self-signed→public 401`, `forged-header 200`.

Then the attribution:

```bash
curl -s https://vl.priv.aws.ogenki.io/select/logsql/query --data-urlencode \
  'query=kubernetes.pod_labels.gateway.envoyproxy.io/owning-gateway-name:"agent-router" _time:15m | unpack_json | log.path:"/v1/chat/completions" | fields log.x_ar_agent, log.response_code, log.upstream_cluster'
```
Expected: `log.x_ar_agent` is exactly `system:serviceaccount:agents:agent-probe` (not
`agent:forged`, not both); the upstream cluster names the `zai` backend.

- [ ] **Step 4: SC-17 (listener half) — `internal` has no path to Z.ai**

```bash
p "curl -s -o /dev/null -w 'internal chat %{http_code}\n' -H \"Authorization: Bearer \$(cat /var/run/secrets/probe/internal/token)\" -H 'content-type: application/json' -d '{\"model\":\"agent-default\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}' $R:8081/v1/chat/completions"
curl -s https://vl.priv.aws.ogenki.io/select/logsql/query --data-urlencode \
  'query=kubernetes.pod_labels.gateway.envoyproxy.io/owning-gateway-name:"agent-router" _time:15m | unpack_json | log.listener_port:8081 | stats by (log.upstream_cluster) count() hits'
```
Expected: `internal chat 404` (no `internal` route until SP4 PR 2), and no `upstream_cluster`
containing `zai` among the 8081 lines.

- [ ] **Step 5: SC-10 — no key in `agents`, and the store's reach**

```bash
kubectl get secrets -n agents -o name | wc -l
kubectl apply --dry-run=server -f - <<'YAML'
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata: {name: sc10, namespace: agents}
spec:
  secretStoreRef: {kind: ClusterSecretStore, name: openbao-platform}
  target: {name: sc10}
  data: [{secretKey: k, remoteRef: {key: llm/zai, property: api_key}}]
YAML
export VAULT_ADDR=https://bao.priv.aws.ogenki.io:8200 VAULT_CACERT=opentofu/aws/openbao/management/.tls/ca.pem
JWT=$(kubectl create token agents-secrets -n agent-system --audience openbao --duration 10m)
T=$(bao write -field=token auth/jwt/aws-0/login role=agents-secrets jwt="$JWT")
bao token capabilities "$T" platform/data/agents/zai
bao token capabilities "$T" platform/data/llm/zai
bao token capabilities "$T" apps/data/anything
bao token revoke "$T"
```
Expected: `0`; the ExternalSecret denied by `agents-no-secret-import`; `read`, `deny`, `deny`.

- [ ] **Step 6: Clean up and record**

`kubectl delete -f scripts/ops/k8s/agent-probe.yaml`. Paste Steps 2–5 into PR 3 as the SC-05, SC-10,
SC-17 and R5 evidence.

---
## Phase 4 — GitHub (PR 4, branch `feat/agent-github`)

Gate: SC-11. octo-sts reads trust policies **from the default branch only**, so SC-11 is proven after
PR 4 merges (Task 4.7), on a cluster running `main`.

### Task 4.1: Worktree and ADR-0043

**Files:**
- Create: `website/content/docs/decisions/0043-octo-sts-for-agent-github-tokens.md`
- Modify: `website/content/docs/decisions/_index.md`

- [ ] **Step 1: Worktree**

`EnterWorktree` with branch `feat/agent-github`.

- [ ] **Step 2: Write the ADR** (set **Date** to the commit day)

```markdown
---
title: Agents get GitHub tokens from a self-hosted octo-sts, scoped per repository and role, and a ruleset confines their App to agent branches
linkTitle: 0043 · GitHub credentials for agents
weight: 430
description: A run exchanges its projected ServiceAccount token at an in-cluster octo-sts for an installation token of the agents' GitHub App, valid at most one hour, for one repository, with permissions set by the run's role in a trust policy stored in that repository. A branch ruleset lets that App write only refs/heads/agent/**, so it cannot merge. PATs, the ESO GitHub generator, the OpenBao GitHub plugin and a git proxy were rejected.
lastVerified: 2026-09-25
---

**Status**: Accepted
**Date**: 2026-09-25
**Deciders**: Smana (Platform Owner)
**Related Spec**: [SP1 — Agent runtime & identity](https://github.com/Smana/cloud-native-ref/blob/main/docs/superpowers/specs/2026-09-23-agent-runtime-identity-design.md)

---

## Context

An implementer run pushes one branch and opens one PR; reviewer, tester and triager runs must never
write (C6). `main` requires zero approving reviews (programme D4), so nothing but policy stops a
token that can push to `main` from merging. Tokens must be short-lived, scoped to the run's repository,
and never a human's.

---

## Decision Drivers

- ≤ 1 h tokens, one repository, permissions by role
- Authorisation that lives in the target repository and is reviewed like code
- No long-lived credential in the sandbox
- Works for the user-owned `Smana` account

---

## Considered Options

### Option 1: Self-hosted octo-sts with the agents' GitHub App

The run presents a token that lives until its deadline (R2), with audience `octo-sts/<owner>/<repo>/<role>`; octo-sts checks it
against `.github/chainguard/agent-<role>.sts.yaml` on the default branch and returns an installation
token with that policy's permissions.

**Pros**:
- Trust policies are files in the repository, on a gate path
- Resolves installations by account login, so a user-owned installation works
- Records issuer, subject and the token's SHA-256 on every exchange

**Cons**:
- The EKS issuer changes on every rebuild, so policies match it by pattern (OD-5). That is safe only
  because octo-sts is not publicly reachable: a ClusterIP Service whose CNP admits only `agents` pods
- One more service in `agent-system`

### Option 2: Personal access tokens

**Cons**:
- A human's credential, long-lived, not scoped per run (D3)

### Option 3: External Secrets GitHub generator, or the OpenBao GitHub plugin

**Cons**:
- The token lands in a Kubernetes Secret or needs the run to authenticate to OpenBao; permissions are
  set in cluster config, not in the repository

### Option 4: A git proxy holding the credential

**Cons**:
- A programme non-goal: the target repositories are public, and a proxy is a new component to build

---

## Decision Outcome

**Chosen option**: "Self-hosted octo-sts with the agents' GitHub App", plus a branch ruleset
`agent-branches` that confines every non-bypass actor to `refs/heads/agent/**`, with the owner, Renovate
and the factory's App on the bypass list (OD-7).

**Rationale**: Short-lived, per-repository, per-role tokens whose authorisation is reviewed in the
repository it grants.

---

## Consequences

### Positive

- A stolen implementer token can push to `agent/**` of one repository for ≤ 1 h; a reviewer's cannot
  push at all
- The App has no `workflows` permission, so no agent PR can rewrite CI

### Negative

- All runs share one App and the ruleset is `agent/**`-wide: a run can push another task's agent
  branch (R9). SP3's gate checks the head commit's `Agent-Run` trailer
- A copied octo-sts audience token verifies until `exp`, the run's deadline (R2)

### Neutral

- A repository opts in twice: its trust policies, and the App's installation

---

## Implementation Notes

`security/base/octo-sts/`, `.github/chainguard/agent-*.sts.yaml`, `.github/rulesets/agent-branches.json`
applied by `task ops:github:agent-branch-ruleset`. The App key is at `platform/agents/github-app`.

---

## References

- [octo-sts/app](https://github.com/octo-sts/app)
- [GitHub rulesets REST API](https://docs.github.com/en/rest/repos/rules)
- [Choosing permissions for a GitHub App](https://docs.github.com/en/apps/creating-github-apps/registering-a-github-app/choosing-permissions-for-a-github-app)
```

Append to `_index.md` after the 0042 row:

```markdown
| [0043]({{< relref "/docs/decisions/0043-octo-sts-for-agent-github-tokens.md" >}}) | Agents get GitHub tokens from a self-hosted octo-sts, scoped per repository and role, and a ruleset confines their App to agent branches | Accepted | 2026-09-25 |
```

- [ ] **Step 3: Commit**

```bash
git add website/content/docs/decisions/0043-octo-sts-for-agent-github-tokens.md website/content/docs/decisions/_index.md
git commit -m "docs(adr): 0043 GitHub credentials for agents"
```

### Task 4.2: [OWNER] The agents' GitHub App

**Files:** none.

- [ ] **Step 1: Ask the owner to create and install the App**

On the user account `Smana` (Settings → Developer settings → GitHub Apps → New):

| Setting | Value |
|---|---|
| Name | `ogenki-agents` |
| Webhook | inactive (octo-sts runs without its webhook component) |
| Repository permissions | Metadata: read; Contents: read & write; Pull requests: read & write; Issues: read; Checks: read; Actions: read |
| Never granted | Workflows, Commit statuses, Checks: write, Administration |
| Install on | `Smana/cloud-native-ref` only (OD-6) |

Then generate a private key and store both values, deleting the local PEM afterwards:

`bao kv put platform/agents/github-app app_id=<numeric id> private_key=@<downloaded>.pem`

- [ ] **Step 2: Confirm without reading the key**

Run: `bao kv metadata get platform/agents/github-app | head -5`
Expected: a current version exists. The executor never prints the `private_key` value.

### Task 4.3: octo-sts

**Files:**
- Create: `security/base/octo-sts/{kustomization.yaml,serviceaccount.yaml,externalsecret.yaml,deployment.yaml,service.yaml,network-policy.yaml}`
- Create: `clusters/aws-0-agent-platform/security-octo-sts.yaml`
- Modify: `clusters/aws-0-agent-platform/kustomization.yaml`, `clusters/aws-0-agent-platform/README.md`

**Interfaces:**
- Consumes: `SecretStore agents-secrets` (Task 3.3); `platform/agents/github-app` (Task 4.2).
- Produces: `octo-sts.agent-system.svc.cluster.local:8080`, pod label `app.kubernetes.io/name:
  octo-sts` (the run CNP of Task 1.3, the identity-proxy cluster of Task 0.1).

- [ ] **Step 1: Manifests**

`security/base/octo-sts/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

# Self-hosted octo-sts (ADR-0043): exchanges a run's projected token for a <= 1 h
# installation token of the agents' App. No webhook component: it would need a
# public endpoint.
resources:
  - serviceaccount.yaml
  - externalsecret.yaml
  - deployment.yaml
  - service.yaml
  - network-policy.yaml
```

`security/base/octo-sts/serviceaccount.yaml`:

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: octo-sts
  namespace: agent-system
# octo-sts never calls the Kubernetes API: it validates tokens against the
# issuer's JWKS.
automountServiceAccountToken: false
```

`security/base/octo-sts/externalsecret.yaml`:

```yaml
---
# The agents' App (C6), through agent-system's own store only.
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: octo-sts-github-app
  namespace: agent-system
spec:
  refreshInterval: 1h
  secretStoreRef:
    kind: SecretStore
    name: agents-secrets
  target:
    name: octo-sts-github-app
    creationPolicy: Owner
    deletionPolicy: Retain
  data:
    - secretKey: app_id  # pragma: allowlist secret
      remoteRef:
        key: agents/github-app
        property: app_id
    - secretKey: private_key  # pragma: allowlist secret
      remoteRef:
        key: agents/github-app
        property: private_key  # pragma: allowlist secret
```

`security/base/octo-sts/deployment.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: octo-sts
  namespace: agent-system
spec:
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: octo-sts
  template:
    metadata:
      labels:
        app.kubernetes.io/name: octo-sts
    spec:
      serviceAccountName: octo-sts
      automountServiceAccountToken: false
      securityContext:
        runAsNonRoot: true
        runAsUser: 65532
        runAsGroup: 65532
        # The key file is group-readable by this group (defaultMode 0440 below).
        fsGroup: 65532
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: octo-sts
          image: ghcr.io/octo-sts/app:0.10.0@sha256:921cd6711ac2ed99f9b12efb2c55372baa0ec4c4facead1eac55dd871e50ffa6
          env:
            - name: PORT
              value: "8080"
            # The default audience. Every agent trust policy names its own exact
            # audience instead (octo-sts/<owner>/<repo>/<role>).
            - name: STS_DOMAIN
              value: octo-sts.agent-system.svc.cluster.local
            - name: GITHUB_APP_IDS
              valueFrom:
                secretKeyRef:
                  name: octo-sts-github-app
                  key: app_id
            - name: APP_SECRET_CERTIFICATE_FILE
              value: /var/run/secrets/octo-sts/private-key.pem
            - name: METRICS
              value: "false"
          ports:
            - name: http
              containerPort: 8080
              protocol: TCP
          # No HTTP health path is verified for 0.10.0 (design §6).
          startupProbe:
            tcpSocket:
              port: http
            periodSeconds: 2
            failureThreshold: 30
          readinessProbe:
            tcpSocket:
              port: http
            periodSeconds: 10
          livenessProbe:
            tcpSocket:
              port: http
            periodSeconds: 20
          resources:
            requests:
              cpu: 20m
              memory: 64Mi
            limits:
              cpu: 200m
              memory: 128Mi
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            runAsNonRoot: true
            capabilities:
              drop: ["ALL"]
            seccompProfile:
              type: RuntimeDefault
          volumeMounts:
            - name: app-key
              mountPath: /var/run/secrets/octo-sts
              readOnly: true
      volumes:
        - name: app-key
          secret:
            secretName: octo-sts-github-app
            defaultMode: 0440
            items:
              - key: private_key
                path: private-key.pem
```

`security/base/octo-sts/service.yaml`:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: octo-sts
  namespace: agent-system
spec:
  type: ClusterIP
  selector:
    app.kubernetes.io/name: octo-sts
  ports:
    - name: http
      port: 8080
      targetPort: http
      protocol: TCP
```

`security/base/octo-sts/network-policy.yaml`:

```yaml
---
# Ingress from sandbox pods only: that, not the trust policy's issuer pattern,
# is what keeps other EKS clusters' tokens out (ADR-0043). Egress to GitHub's
# API and the EKS issuer (discovery + JWKS).
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: octo-sts
  namespace: agent-system
spec:
  endpointSelector:
    matchLabels:
      app.kubernetes.io/name: octo-sts
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
    - fromEntities:
        - host
      toPorts:
        - ports:
            - port: "8080"
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
    - toFQDNs:
        - matchName: api.github.com
        - matchName: ${oidc_issuer_host}
      toPorts:
        - ports:
            - port: "443"
              protocol: TCP
```

`clusters/aws-0-agent-platform/security-octo-sts.yaml`:

```yaml
---
# octo-sts for the agents' GitHub App (ADR-0043).
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: octo-sts
  namespace: flux-system
spec:
  prune: true
  interval: 5m0s
  timeout: 3m0s
  path: ./security/base/octo-sts
  sourceRef:
    kind: ExternalArtifact
    name: security-artifact
  postBuild:
    substituteFrom:
      - kind: ConfigMap
        name: eks-aws-0-vars
  dependsOn:
    - name: agent-secrets
  healthChecks:
    - apiVersion: apps/v1
      kind: Deployment
      name: octo-sts
      namespace: agent-system
```

Add `- security-octo-sts.yaml` to the children list, and the README row
`` | `octo-sts` | `security/base/octo-sts` | GitHub token exchange for the agents' App | ``.

- [ ] **Step 2: Commit**

```bash
git add security/base/octo-sts clusters/aws-0-agent-platform
git commit -m "feat(security): self-hosted octo-sts for the agents' GitHub App"
```

### Task 4.4: Trust policies

**Files:**
- Create: `.github/chainguard/agent-implementer.sts.yaml`, `agent-reviewer.sts.yaml`,
  `agent-tester.sts.yaml`, `agent-triager.sts.yaml`

**Interfaces:**
- Produces: octo-sts identities `agent-<role>` for scope `Smana/cloud-native-ref`, consumed by
  `git-credential-agent` (Task 5.1: `identity=agent-${ROLE}`).

- [ ] **Step 1: The four policies**

`.github/chainguard/agent-implementer.sts.yaml`:

```yaml
# Agents' App, implementer runs (ADR-0043). A gate path (C6): octo-sts reads it
# from the default branch only. The issuer is a pattern because the EKS issuer
# ID changes on every rebuild (OD-5); octo-sts is reachable from sandbox pods
# only, which is what keeps other clusters' tokens out.
issuer_pattern: 'https://oidc\.eks\.eu-west-3\.amazonaws\.com/id/[0-9A-F]{32}'
subject_pattern: 'system:serviceaccount:agents:xplane-run-[a-z2-7]{8}'
audience: octo-sts/Smana/cloud-native-ref/implementer
permissions:
  contents: write
  pull_requests: write
  issues: read
  checks: read
  actions: read
```

`.github/chainguard/agent-reviewer.sts.yaml`:

```yaml
# Agents' App, reviewer runs (ADR-0043). Read-only: a reviewer's output goes to
# the room, and system components post it under their own identity. A gate path.
issuer_pattern: 'https://oidc\.eks\.eu-west-3\.amazonaws\.com/id/[0-9A-F]{32}'
subject_pattern: 'system:serviceaccount:agents:xplane-run-[a-z2-7]{8}'
audience: octo-sts/Smana/cloud-native-ref/reviewer
permissions:
  contents: read
  pull_requests: read
  issues: read
  checks: read
  actions: read
```

`.github/chainguard/agent-tester.sts.yaml`:

```yaml
# Agents' App, tester runs (ADR-0043). Read-only. A gate path.
issuer_pattern: 'https://oidc\.eks\.eu-west-3\.amazonaws\.com/id/[0-9A-F]{32}'
subject_pattern: 'system:serviceaccount:agents:xplane-run-[a-z2-7]{8}'
audience: octo-sts/Smana/cloud-native-ref/tester
permissions:
  contents: read
  pull_requests: read
  issues: read
  checks: read
  actions: read
```

`.github/chainguard/agent-triager.sts.yaml`:

```yaml
# Agents' App, triager runs (ADR-0043). Read-only. A gate path.
issuer_pattern: 'https://oidc\.eks\.eu-west-3\.amazonaws\.com/id/[0-9A-F]{32}'
subject_pattern: 'system:serviceaccount:agents:xplane-run-[a-z2-7]{8}'
audience: octo-sts/Smana/cloud-native-ref/triager
permissions:
  contents: read
  pull_requests: read
  issues: read
  checks: read
  actions: read
```

- [ ] **Step 2: The live issuer matches the pattern**

Run: `kubectl get --raw /.well-known/openid-configuration | jq -r .issuer | grep -cE '^https://oidc\.eks\.eu-west-3\.amazonaws\.com/id/[0-9A-F]{32}$'`
Expected: `1` (on any running aws-0; skip if none is up and note it in the PR).

- [ ] **Step 3: Commit**

```bash
git add .github/chainguard
git commit -m "feat(github): octo-sts trust policies for the four agent roles"
```

### Task 4.5: Branch ruleset source, its applier, and its test

**Files:**
- Create: `.github/rulesets/agent-branches.json`
- Create: `scripts/ops/github/agent-branch-ruleset.sh`
- Test: `scripts/ci/tests/test-agent-branch-ruleset.sh`
- Modify: `scripts/ops/tasks.yaml` (one task), `scripts/README.md` (one row)

**Interfaces:**
- Produces: `task ops:github:agent-branch-ruleset -- <owner/repo>`; ruleset `agent-branches`.

- [ ] **Step 1: Write the failing test**

`scripts/ci/tests/test-agent-branch-ruleset.sh`:

```bash
#!/usr/bin/env bash
# requires: jq
#
# scripts/ops/github/agent-branch-ruleset.sh against a PATH-stubbed gh: it
# creates the ruleset when absent, updates it in place when present, and sends
# the bypass list the design names (OD-7). No test contacts GitHub.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUBJECT="$HERE/../../ops/github/agent-branch-ruleset.sh"
fails=0
fail() { printf 'FAIL  %s\n' "$*" >&2; fails=$((fails + 1)); }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
cat >"$tmp/bin/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$STUB_LOG"
case "$*" in
  "api /apps/renovate --jq .id") echo 2740 ;;
  "api /apps/ogenki-factory --jq .id") echo 999 ;;
  "api repos/Smana/demo/rulesets --jq "*) if [ -n "$STUB_EXISTING" ]; then echo "$STUB_EXISTING"; fi ;;
  "api --method POST "*|"api --method PUT "*) cat >"$STUB_BODY" ;;
esac
STUB
chmod +x "$tmp/bin/gh"
export PATH="$tmp/bin:$PATH" STUB_LOG="$tmp/log" STUB_BODY="$tmp/body" STUB_EXISTING="" FACTORY_APP_SLUG=""

run() { : >"$STUB_LOG"; rm -f "$STUB_BODY"; bash "$SUBJECT" Smana/demo >/dev/null || fail "subject exited non-zero"; }

run
grep -q '^api --method POST repos/Smana/demo/rulesets ' "$STUB_LOG" || fail "creates the ruleset when absent"
jq -e '.bypass_actors == [{"actor_id":5,"actor_type":"RepositoryRole","bypass_mode":"always"},{"actor_id":2740,"actor_type":"Integration","bypass_mode":"always"}]' "$STUB_BODY" >/dev/null || fail "bypass is the owner and Renovate, always"
jq -e '.conditions.ref_name == {"include":["~ALL"],"exclude":["refs/heads/agent/**"]}' "$STUB_BODY" >/dev/null || fail "confines everyone else to agent/**"
jq -e '[.rules[].type] == ["creation","update","deletion"]' "$STUB_BODY" >/dev/null || fail "restricts creation, update and deletion"

export STUB_EXISTING=42
run
grep -q '^api --method PUT repos/Smana/demo/rulesets/42 ' "$STUB_LOG" || fail "updates in place when present"
if grep -q -- '--method POST' "$STUB_LOG"; then fail "never creates a second ruleset"; fi

export STUB_EXISTING="" FACTORY_APP_SLUG=ogenki-factory
run
jq -e '[.bypass_actors[].actor_id] == [5, 2740, 999]' "$STUB_BODY" >/dev/null || fail "adds the factory's App when named"

[ "$fails" -eq 0 ] || exit 1
echo "PASS"
```

Run: `bash scripts/ci/tests/test-agent-branch-ruleset.sh`
Expected: FAIL — `subject exited non-zero` (the script does not exist yet).

- [ ] **Step 2: Ruleset source and applier**

`.github/rulesets/agent-branches.json`:

```json
{
  "name": "agent-branches",
  "target": "branch",
  "enforcement": "active",
  "conditions": {
    "ref_name": {
      "include": ["~ALL"],
      "exclude": ["refs/heads/agent/**"]
    }
  },
  "rules": [
    {"type": "creation"},
    {"type": "update"},
    {"type": "deletion"}
  ],
  "bypass_actors": []
}
```

`scripts/ops/github/agent-branch-ruleset.sh` (mode 0755):

```bash
#!/usr/bin/env bash
# Applies the agents' branch ruleset (SP1 design §6, OD-7) to one repository.
#
# Every actor NOT on the bypass list may only create, update or delete
# refs/heads/agent/**. The bypass list is the owner (the repository admin role),
# Renovate and, once SP3 ships, the factory's App, all `always`. The agents' App
# is therefore the only confined actor, and since it cannot update main, it
# cannot merge. SP3's merge-gate ruleset is a separate ruleset.
#
# Idempotent: updates the ruleset named `agent-branches` when it exists.
# usage: agent-branch-ruleset.sh <owner/repo>
#        FACTORY_APP_SLUG=<slug> adds the factory's App to the bypass list.
set -euo pipefail

REPO="${1:?usage: agent-branch-ruleset.sh <owner/repo>}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE="$HERE/../../../.github/rulesets/agent-branches.json"

# RepositoryRole 5 is GitHub's built-in admin role: the owner of a user repo.
bypass='[{"actor_id":5,"actor_type":"RepositoryRole","bypass_mode":"always"}]'
for slug in renovate ${FACTORY_APP_SLUG:-}; do
  id="$(gh api "/apps/$slug" --jq .id)"
  bypass="$(jq -c --argjson id "$id" '. + [{"actor_id":$id,"actor_type":"Integration","bypass_mode":"always"}]' <<<"$bypass")"
done
body="$(jq --argjson b "$bypass" '.bypass_actors = $b' "$SOURCE")"

existing="$(gh api "repos/$REPO/rulesets" --jq '.[] | select(.name == "agent-branches") | .id')"
if [ -n "$existing" ]; then
  gh api --method PUT "repos/$REPO/rulesets/$existing" --input - <<<"$body" >/dev/null
  echo "updated ruleset agent-branches ($existing) on $REPO"
else
  gh api --method POST "repos/$REPO/rulesets" --input - <<<"$body" >/dev/null
  echo "created ruleset agent-branches on $REPO"
fi
```

In `scripts/ops/tasks.yaml`, add:

```yaml
  github:agent-branch-ruleset:
    desc: Apply the agents' branch ruleset (agent/** only for the agents' App) to one repository
    cmds: ["{{.TASKFILE_DIR}}/github/agent-branch-ruleset.sh {{.CLI_ARGS}}"]
```

In `scripts/README.md`, add the row
`` | `ops/github/` | GitHub-side configuration, run by the owner: `task ops:github:agent-branch-ruleset` | ``.

- [ ] **Step 3: Run the test, and prove it can fail**

Run: `bash scripts/ci/tests/test-agent-branch-ruleset.sh`
Expected: `PASS`.

Run: `sed -i 's/--method PUT/--method PATCH/' scripts/ops/github/agent-branch-ruleset.sh && bash scripts/ci/tests/test-agent-branch-ruleset.sh; git checkout scripts/ops/github/agent-branch-ruleset.sh`
Expected: `FAIL  updates in place when present`, then the file restored.

Run: `bash scripts/ci/tests/run.sh | grep -E 'agent-branch-ruleset|script-paths|no-secret-argv'`
Expected: three `PASS` lines.

- [ ] **Step 4: Commit**

```bash
git add .github/rulesets/agent-branches.json scripts/ops/github/agent-branch-ruleset.sh scripts/ci/tests/test-agent-branch-ruleset.sh scripts/ops/tasks.yaml scripts/README.md
git commit -m "feat(github): idempotent applier for the agents' branch ruleset"
```

### Task 4.6: Validate and open PR 4

- [ ] **Step 1: Gates**

Run: `./scripts/ci/validate-manifests.sh && task check && ./scripts/ci/validate-links.sh`
Expected: exit 0; `Invalid: 0, Skipped: 0`; Polaris clean on the octo-sts Deployment.

- [ ] **Step 2: Ship**

`ship-it`. PR body: phase 4 of 6; ADR-0043; `.github/chainguard/` and `.github/rulesets/` are gate
paths; owner actions (App, key, ruleset run after merge); SC-11 is proven after merge.

### Task 4.7: [LIVE, after PR 4 merges] SC-11

**Files:** none.

- [ ] **Step 1: [OWNER] Apply the ruleset**

Run by the owner: `task ops:github:agent-branch-ruleset -- Smana/cloud-native-ref`
Expected: `created ruleset agent-branches on Smana/cloud-native-ref`.
Check: `gh api repos/Smana/cloud-native-ref/rulesets --jq '.[] | select(.name=="agent-branches") | .enforcement'` → `active`.

- [ ] **Step 2: A cluster on `main`, with the umbrella open**

```bash
cd opentofu && terramate script run deploy
flux resume kustomization ai-gateway -n flux-system
flux resume kustomization agent-platform -n flux-system
flux get kustomizations -n flux-system octo-sts
```
Expected: `octo-sts` `Ready=True`.

- [ ] **Step 3: Two runs, one per role**

Write `/tmp/sc11.yaml` (with the Write tool):

```yaml
apiVersion: cloud.ogenki.io/v1alpha1
kind: AgentRun
metadata: {name: xplane-run-scimplaa, namespace: agents}
spec: {role: implementer, repository: Smana/cloud-native-ref, principal: "human:owner", dataClass: public, task: {text: "SC-11 probe, idle."}}
---
apiVersion: cloud.ogenki.io/v1alpha1
kind: AgentRun
metadata: {name: xplane-run-screvwaa, namespace: agents}
spec: {role: reviewer, repository: Smana/cloud-native-ref, principal: "human:owner", dataClass: public, task: {url: "https://github.com/Smana/cloud-native-ref/pull/1"}}
```

```bash
kubectl apply -f /tmp/sc11.yaml
kubectl wait -n agents agentrun/xplane-run-scimplaa agentrun/xplane-run-screvwaa --for=jsonpath='{.status.phase}'=Running --timeout=15m
```

- [ ] **Step 4: Implementer pushes `spec.branch`, not `main`, not another branch**

Write `/tmp/sc11.py` (runs inside the harness; the token never leaves the pod):

```python
import json, os, subprocess, sys, urllib.request
role, repo = sys.argv[1], sys.argv[2]
url = "http://127.0.0.1:4001/sts/exchange?scope=%s&identity=agent-%s" % (repo, role)
try:
    token = json.load(urllib.request.urlopen(url, timeout=15))["token"]
except Exception as err:
    print("exchange", repo, role, "->", err); sys.exit(0)
print("exchange", repo, role, "-> token", token[:4] + "…")
remote = "https://x-access-token:%s@github.com/Smana/cloud-native-ref" % token  # pragma: allowlist secret
subprocess.run(["git", "clone", "-q", "--depth", "1", "https://github.com/Smana/cloud-native-ref", "/workspace/sc11"], check=True)
g = lambda *a: subprocess.run(["git", "-C", "/workspace/sc11", "-c", "user.name=sc11", "-c", "user.email=sc11@example.invalid", *a], capture_output=True, text=True)
g("commit", "--allow-empty", "-q", "-m", "test: SC-11 probe")
for ref in ["HEAD:refs/heads/agent/" + os.environ["RUN_ID"], "HEAD:refs/heads/main", "HEAD:refs/heads/sc11-not-agent"]:
    r = g("push", remote, ref)
    print("push", ref, "->", "ok" if r.returncode == 0 else r.stderr.strip().splitlines()[-1])
```

```bash
for run in scimplaa screvwaa; do kubectl cp /tmp/sc11.py agents/xplane-run-$run:/tmp/sc11.py -c harness; done
kubectl exec -n agents xplane-run-scimplaa -c harness -- /usr/local/bin/python /tmp/sc11.py implementer Smana/cloud-native-ref
```
Expected: `-> token ghs_…`; `push HEAD:refs/heads/agent/scimplaa -> ok`; `push HEAD:refs/heads/main ->`
a rejection (`GH013`/protected branch); `push HEAD:refs/heads/sc11-not-agent ->` a rejection
(`GH013: Repository rule violations`).

- [ ] **Step 5: Reviewer cannot push; no token for another repository or role**

```bash
kubectl exec -n agents xplane-run-screvwaa -c harness -- /usr/local/bin/python /tmp/sc11.py reviewer Smana/cloud-native-ref
kubectl exec -n agents xplane-run-scimplaa -c harness -- /usr/local/bin/python /tmp/sc11.py implementer Smana/crossplane-configuration
kubectl exec -n agents xplane-run-screvwaa -c harness -- /usr/local/bin/python /tmp/sc11.py implementer Smana/cloud-native-ref
```
Expected: the reviewer gets a token but every push is rejected (`403`/permission); the other
repository's exchange fails (`HTTP Error 403`/PermissionDenied: no trust policy there, App not
installed); the reviewer asking for `agent-implementer` fails (audience mismatch).

- [ ] **Step 6: Clean up and record**

```bash
kubectl delete -f /tmp/sc11.yaml --wait
gh api --method DELETE repos/Smana/cloud-native-ref/git/refs/heads/agent/scimplaa
kubectl logs -n agent-system deploy/octo-sts | grep -iE 'exchange|subject' | tail -5
```
Expected: the branch deleted; octo-sts log lines naming the run subjects. Paste Steps 4–6 into a PR-4
follow-up comment as the SC-11 evidence.

---
## Phase 5 — Harness and MCP (PR 5, branch `feat/agent-harness`)

Gate: SC-08, SC-12, SC-17 (MCP half). The harness image is published only when PR 5 merges (the
build workflow pushes on `main`); the composition switches to it in phase 6 (CC-2). Until then runs
use the upstream agent-server image, which is enough for this phase's gate.

### Task 5.1: `container-images/agent-harness`

**Files:**
- Create: `container-images/agent-harness/{Dockerfile,requirements.in,requirements.txt,agent_run.py,git_credential_agent.py,gh,commit-msg,gitconfig,build.sh,README.md}`
- Test: `container-images/agent-harness/tests/{test_git_credential_agent.py,test_agent_run.py}`

**Interfaces:**
- Consumes: the env contract of Task 1.3 (`RUN_ID ROLE REPOSITORY BASE_REF BRANCH MODEL
  CONVERSATION_ID LLM_BASE_URL MCP_URL STS_URL TASK_FILE RULES_FILE HOME`); identity-proxy `:4001`
  (Task 0.1); octo-sts identities `agent-<role>` (Task 4.4).
- Produces: image `ghcr.io/smana/agent-harness:v0.1.0` (tag from `ARG AGENT_HARNESS_VERSION`),
  entrypoint `agent-run`, `/usr/local/bin/git-credential-agent {get,token,revoke}` (the composition's
  `preStop`), `gh` authenticated from that helper, commit hook adding `Agent-Run: $RUN_ID`.

- [ ] **Step 1: Worktree**

`EnterWorktree` with branch `feat/agent-harness`.

- [ ] **Step 2: Credential-helper tests first (stdlib only, run locally)**

`container-images/agent-harness/tests/test_git_credential_agent.py`:

```python
"""git-credential-agent against a stub octo-sts and a stub GitHub. Stdlib only."""
import http.server
import io
import json
import os
import sys
import tempfile
import threading
import unittest
from unittest import mock

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import git_credential_agent as helper  # noqa: E402


class Stub(http.server.BaseHTTPRequestHandler):
    calls = []

    def do_GET(self):  # octo-sts exchange
        Stub.calls.append(("GET", self.path, self.headers.get("Authorization")))
        body = json.dumps({"token": "ghs_stub%d" % len(Stub.calls)}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(body)

    def do_DELETE(self):  # GitHub revoke
        Stub.calls.append(("DELETE", self.path, self.headers.get("Authorization")))
        self.send_response(204)
        self.end_headers()

    def log_message(self, *args):
        pass


class HelperTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = http.server.HTTPServer(("127.0.0.1", 0), Stub)
        threading.Thread(target=cls.server.serve_forever, daemon=True).start()
        cls.base = "http://127.0.0.1:%d" % cls.server.server_port

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()

    def setUp(self):
        Stub.calls.clear()
        self.tmp = tempfile.mkdtemp()
        helper.CACHE = os.path.join(self.tmp, "token.json")
        helper.GITHUB_API = self.base
        self.env = mock.patch.dict(os.environ, {"STS_URL": self.base + "/sts/exchange", "REPOSITORY": "Smana/cloud-native-ref", "ROLE": "implementer"})
        self.env.start()

    def tearDown(self):
        self.env.stop()

    def get(self, host):
        out = io.StringIO()
        with mock.patch("sys.stdin", io.StringIO("protocol=https\nhost=%s\n" % host)), mock.patch("sys.stdout", out):
            helper.main(["git-credential-agent", "get"])
        return out.getvalue()

    def test_exchanges_for_the_run_repository_and_role(self):
        self.assertEqual(self.get("github.com"), "username=x-access-token\npassword=ghs_stub1\n")
        self.assertEqual(Stub.calls[0][1], "/sts/exchange?scope=Smana/cloud-native-ref&identity=agent-implementer")

    def test_caches_in_the_memory_volume(self):
        self.get("github.com")
        self.get("github.com")
        self.assertEqual(len(Stub.calls), 1, "the second get is served from the cache")
        self.assertEqual(os.stat(helper.CACHE).st_mode & 0o777, 0o600)

    def test_ignores_other_hosts(self):
        self.assertEqual(self.get("gitlab.com"), "")
        self.assertEqual(Stub.calls, [])

    def test_revoke_deletes_the_token_at_github_and_the_cache(self):
        self.get("github.com")
        helper.main(["git-credential-agent", "revoke"])
        self.assertEqual(Stub.calls[-1], ("DELETE", "/installation/token", "Bearer ghs_stub1"))
        self.assertFalse(os.path.exists(helper.CACHE))

    def test_revoke_without_a_token_is_a_no_op(self):
        helper.main(["git-credential-agent", "revoke"])
        self.assertEqual(Stub.calls, [])


if __name__ == "__main__":
    unittest.main()
```

Run: `python3 -m unittest container-images/agent-harness/tests/test_git_credential_agent.py`
Expected: FAIL — `ModuleNotFoundError: No module named 'git_credential_agent'`.

- [ ] **Step 3: The helper**

`container-images/agent-harness/git_credential_agent.py`:

```python
#!/agent-server/.venv/bin/python
"""git-credential-agent: git's credential helper inside an AgentRun sandbox.

`get` exchanges through identity-proxy :4001 for a <= 1 h installation token
scoped to $REPOSITORY and $ROLE (octo-sts, C6), and caches it in memory
(/run/agent/git is a Memory emptyDir, T3). `token` prints it for gh. `revoke`
deletes it at GitHub; preStop and agent-run both call it.
"""
import json
import os
import sys
import time
import urllib.request

CACHE = os.environ.get("GIT_TOKEN_CACHE", "/run/agent/git/token.json")
GITHUB_API = os.environ.get("GITHUB_API", "https://api.github.com")
# Installation tokens live 1 h. Refresh with 10 minutes to spare.
LIFETIME_S = 3600
REFRESH_MARGIN_S = 600


def _cached() -> str | None:
    try:
        with open(CACHE) as f:
            entry = json.load(f)
    except (OSError, ValueError):
        return None
    if entry.get("expires_at", 0) - time.time() > REFRESH_MARGIN_S:
        return entry.get("token")
    return None


def _exchange() -> str:
    url = "{}?scope={}&identity=agent-{}".format(os.environ["STS_URL"], os.environ["REPOSITORY"], os.environ["ROLE"])
    with urllib.request.urlopen(url, timeout=15) as resp:
        token = json.load(resp)["token"]
    fd = os.open(CACHE, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        json.dump({"token": token, "expires_at": time.time() + LIFETIME_S}, f)
    return token


def token() -> str:
    return _cached() or _exchange()


def revoke() -> None:
    try:
        with open(CACHE) as f:
            value = json.load(f)["token"]
    except (OSError, ValueError, KeyError):
        return
    req = urllib.request.Request(GITHUB_API + "/installation/token", method="DELETE", headers={"Authorization": "Bearer " + value})
    try:
        urllib.request.urlopen(req, timeout=10)
    finally:
        os.remove(CACHE)


def main(argv: list[str]) -> int:
    action = argv[1] if len(argv) > 1 else ""
    if action == "get":
        attrs = dict(line.split("=", 1) for line in sys.stdin.read().splitlines() if "=" in line)
        if attrs.get("host") != "github.com":
            return 0
        sys.stdout.write("username=x-access-token\npassword={}\n".format(token()))
    elif action == "token":
        sys.stdout.write(token() + "\n")
    elif action == "revoke":
        revoke()
    # `store` and `erase` are no-ops: the cache is ours, not git's.
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
```

Run: `python3 -m unittest container-images/agent-harness/tests/test_git_credential_agent.py`
Expected: `Ran 5 tests … OK`.

- [ ] **Step 4: Driver tests (need the OpenHands SDK, run in the image)**

`container-images/agent-harness/tests/test_agent_run.py`:

```python
"""agent-run's contract with agent-server 1.49.5, checked against the SDK's own models.

Needs the openhands SDK, so it runs inside the image: docker build --target test.
"""
import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import agent_run  # noqa: E402

ENV = {
    "MODEL": "agent-default",
    "LLM_BASE_URL": "http://127.0.0.1:4000/v1",
    "MCP_URL": "http://127.0.0.1:4000/mcp",
    "CONVERSATION_ID": "0b3c6f0e-5d1a-4b8e-9f41-2a7c3e9d8b10",
}


class BuildRequestTest(unittest.TestCase):
    def setUp(self):
        self.body = agent_run.build_request(ENV, "fix the link", "rules text")

    def test_model_goes_through_the_proxy_with_a_placeholder_key(self):
        llm = self.body["agent"]["llm"]
        self.assertEqual(llm["model"], "openai/agent-default")
        self.assertEqual(llm["base_url"], "http://127.0.0.1:4000/v1")
        self.assertEqual(llm["num_retries"], 0, "a budget 429 is terminal")

    def test_mcp_task_and_rules_are_wired(self):
        self.assertEqual(self.body["agent"]["mcp_config"]["platform"]["url"], "http://127.0.0.1:4000/mcp")
        self.assertEqual(self.body["initial_message"]["content"][0]["text"], "fix the link")
        self.assertTrue(self.body["initial_message"]["run"])
        self.assertEqual(self.body["agent_launch_additions"]["system_message_suffix_append"], "rules text")
        self.assertEqual(self.body["conversation_id"], ENV["CONVERSATION_ID"])
        self.assertEqual(self.body["workspace"]["working_dir"], "/workspace/repo")


class OutcomeTest(unittest.TestCase):
    def test_terminal_statuses(self):
        self.assertEqual(agent_run.outcome("finished"), 0)
        self.assertEqual(agent_run.outcome("error"), 1)
        self.assertEqual(agent_run.outcome("stuck"), 1)
        self.assertIsNone(agent_run.outcome("running"))
        self.assertIsNone(agent_run.outcome("waiting_for_confirmation"))


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 5: Image, wrapper, hook, config**

The published `agent-server:1.49.5-python` is upstream's PyInstaller **binary** target (SP1 spike): no
`/agent-server/.venv`, and its Python cannot import `openhands.*`. `agent-run` needs the SDK, so the
image installs the same release into the path upstream's `source` target uses.
`container-images/agent-harness/requirements.in` (moves in lockstep with the base image digest):

```text
openhands-sdk==1.49.5
openhands-tools==1.49.5
openhands-agent-server==1.49.5
```

Lock it with hashes for both architectures:
`uv pip compile --universal --generate-hashes --python-version 3.13 container-images/agent-harness/requirements.in -o container-images/agent-harness/requirements.txt`

`container-images/agent-harness/Dockerfile`:

```dockerfile
# syntax=docker/dockerfile:1
# The AgentRun harness (SP1 design §5, ADR-0041): OpenHands agent-server plus
# the driver, the git credential helper, gh, and the Agent-Run trailer hook.
# The AgentRun composition pins this image by digest; a claim never names one.
FROM ghcr.io/openhands/agent-server:1.49.5-python@sha256:1e7b08ffef732d6520e0b0048931b6ef425a7742c5fb80a82c9397a285c669eb AS harness

# `.github/workflows/build-container-images.yml` tags the image with this.
ARG AGENT_HARNESS_VERSION=v0.1.0
# renovate: datasource=github-releases depName=cli/cli
ARG GH_VERSION=2.101.0
ARG GH_SHA256_AMD64=9bca2d1c16825f109907a23307628a2f0698fbf99662b73a5cf0b020293072b8
ARG GH_SHA256_ARM64=b57e8063f18862647c9d22727c32e9da1b963f8bf9db648fe123a6975695640f
ARG TARGETARCH

USER root
# gh, checksum-pinned per architecture. The upstream image gives its user
# passwordless sudo; nothing here needs it and NoNewPrivileges is not reliable
# under gVisor (design §1), so sudo and every setuid bit go.
RUN set -eux; \
    case "${TARGETARCH}" in amd64) sum="${GH_SHA256_AMD64}" ;; arm64) sum="${GH_SHA256_ARM64}" ;; *) exit 1 ;; esac; \
    /usr/local/bin/python -c "import sys, urllib.request; urllib.request.urlretrieve(sys.argv[1], '/tmp/gh.tgz')" \
      "https://github.com/cli/cli/releases/download/v${GH_VERSION}/gh_${GH_VERSION}_linux_${TARGETARCH}.tar.gz"; \
    echo "${sum}  /tmp/gh.tgz" | sha256sum -c -; \
    tar -xzf /tmp/gh.tgz -C /tmp; \
    install -m 0755 "/tmp/gh_${GH_VERSION}_linux_${TARGETARCH}/bin/gh" /usr/local/lib/gh-real; \
    rm -rf /tmp/gh.tgz "/tmp/gh_${GH_VERSION}_linux_${TARGETARCH}"; \
    rm -f /etc/sudoers.d/*; \
    if [ -f /etc/sudoers ]; then sed -i '/NOPASSWD/d' /etc/sudoers; fi; \
    find / -xdev -perm -4000 -type f -exec chmod u-s {} +

# The SDK agent-run imports; see requirements.in for why it is not in the base image.
COPY requirements.txt /tmp/requirements.txt
RUN /usr/local/bin/python -m venv /agent-server/.venv \
 && /agent-server/.venv/bin/pip install --no-cache-dir --require-hashes -r /tmp/requirements.txt \
 && rm /tmp/requirements.txt

COPY --chmod=0755 agent_run.py git_credential_agent.py /opt/agent/
COPY --chmod=0755 gh /usr/local/bin/gh
COPY --chmod=0755 commit-msg /etc/agent/git-hooks/commit-msg
COPY gitconfig /etc/gitconfig
RUN ln -s /opt/agent/agent_run.py /usr/local/bin/agent-run \
 && ln -s /opt/agent/git_credential_agent.py /usr/local/bin/git-credential-agent

USER 10001
ENTRYPOINT ["tini", "--", "/usr/local/bin/agent-run"]

# `docker build --target test .` runs every suite against the SDK in the image.
FROM harness AS test
COPY --chown=10001:10001 tests /opt/agent/tests
RUN cd /opt/agent && /agent-server/.venv/bin/python -m unittest discover -s tests -v

# The default target, and what CI publishes.
FROM harness
```

`container-images/agent-harness/gh`:

```sh
#!/bin/sh
# gh with the run's installation token, minted through identity-proxy :4001 by
# git-credential-agent and held only in its in-memory cache (design §5).
GH_TOKEN="$(/usr/local/bin/git-credential-agent token)" || exit 1
export GH_TOKEN
exec /usr/local/lib/gh-real "$@"
```

`container-images/agent-harness/commit-msg`:

```sh
#!/bin/sh
# Adds the Agent-Run trailer SP3 re-verifies server-side (design §4). Guidance,
# not a control: an agent with a shell can skip a hook.
exec git interpret-trailers --in-place --if-exists doNothing --trailer "Agent-Run: ${RUN_ID:?RUN_ID is unset}" "$1"
```

`container-images/agent-harness/gitconfig`:

```ini
[core]
	hooksPath = /etc/agent/git-hooks
[credential "https://github.com"]
	helper = /usr/local/bin/git-credential-agent
[user]
	name = ogenki-agents[bot]
	email = ogenki-agents[bot]@users.noreply.github.com
[init]
	defaultBranch = main
```

- [ ] **Step 6: Run the driver tests to see them fail, then write the driver**

Run: `docker build --target test container-images/agent-harness`
Expected: FAIL at `COPY … agent_run.py` (file missing).

`container-images/agent-harness/agent_run.py`:

```python
#!/agent-server/.venv/bin/python
"""agent-run: the harness entrypoint of an AgentRun sandbox (SP1 design, section 5).

Five steps: start agent-server, POST the conversation, wait for it to end,
revoke the GitHub token, exit 0 or 1. Nothing here is a control (design
section 4): every rule it passes to the agent is enforced outside the sandbox.
"""
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request
import uuid

AGENT_SERVER = "http://127.0.0.1:8000"
REPO_DIR = "/workspace/repo"
TERMINAL_OK = {"finished"}
TERMINAL_FAIL = {"error", "stuck"}
# The model key is a placeholder: identity-proxy overwrites Authorization (S5).
PLACEHOLDER_KEY = "injected-by-identity-proxy"


def build_request(env: dict, task: str, rules: str) -> dict:
    """The StartConversationRequest body, as plain JSON."""
    from openhands.sdk import LLM
    from openhands.sdk.conversation.request import StartConversationRequest
    from openhands.tools.preset.default import get_default_agent

    llm = LLM(
        model="openai/" + env["MODEL"],
        base_url=env["LLM_BASE_URL"],
        api_key=PLACEHOLDER_KEY,
        usage_id="agent",
        # A budget 429 is terminal (design section 5); never retry it.
        num_retries=0,
    )
    agent = get_default_agent(llm=llm, cli_mode=True).model_dump(mode="json")
    agent["mcp_config"] = {"platform": {"url": env["MCP_URL"], "transport": "http"}}
    request = StartConversationRequest.model_validate({
        "conversation_id": env.get("CONVERSATION_ID") or str(uuid.uuid4()),
        "workspace": {"working_dir": REPO_DIR},
        "agent": agent,
        "initial_message": {"role": "user", "content": [{"type": "text", "text": task}], "run": True},
        "agent_launch_additions": {"system_message_suffix_append": rules},
        "max_iterations": 500,
    })
    return json.loads(request.model_dump_json(exclude_none=True))


def http(method: str, path: str, body: dict | None = None, timeout: int = 30) -> dict:
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(AGENT_SERVER + path, data=data, method=method, headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return json.loads(resp.read() or b"{}")


def wait_ready(deadline_s: int = 120) -> None:
    end = time.monotonic() + deadline_s
    while time.monotonic() < end:
        try:
            urllib.request.urlopen(AGENT_SERVER + "/ready", timeout=2)
            return
        except (urllib.error.URLError, OSError):
            time.sleep(1)
    raise TimeoutError("agent-server never became ready")


def outcome(status: str) -> int | None:
    """0 on success, 1 on failure, None while the conversation runs."""
    if status in TERMINAL_OK:
        return 0
    if status in TERMINAL_FAIL:
        return 1
    return None


def _verified(ref: str) -> bool:
    return subprocess.run(["git", "-C", REPO_DIR, "rev-parse", "--verify", "--quiet", ref], capture_output=True).returncode == 0


def clone(env: dict) -> None:
    subprocess.run(["git", "clone", "--no-tags", "https://github.com/" + env["REPOSITORY"] + ".git", REPO_DIR], check=True)
    # Resume the run's branch when an earlier run of the same task pushed it (R7).
    if _verified("origin/" + env["BRANCH"]):
        start = "origin/" + env["BRANCH"]
    elif _verified("origin/" + env["BASE_REF"]):
        start = "origin/" + env["BASE_REF"]
    else:
        start = env["BASE_REF"]  # a commit
    subprocess.run(["git", "-C", REPO_DIR, "checkout", "-B", env["BRANCH"], start], check=True)


def main() -> int:
    env = dict(os.environ)
    server = subprocess.Popen(["/agent-server/.venv/bin/python", "-m", "openhands.agent_server", "--host", "0.0.0.0", "--port", "8000"])
    try:
        wait_ready()
        clone(env)
        with open(env["TASK_FILE"]) as t, open(env["RULES_FILE"]) as r:
            request = build_request(env, t.read(), r.read())
        conversation = http("POST", "/api/conversations", request)
        cid = conversation["id"]
        while True:
            code = outcome(http("GET", "/api/conversations/" + cid).get("execution_status", ""))
            if code is not None:
                return code
            time.sleep(15)
    finally:
        subprocess.run(["/usr/local/bin/git-credential-agent", "revoke"], check=False)
        server.terminate()


if __name__ == "__main__":
    sys.exit(main())
```

Run: `docker build --target test container-images/agent-harness`
Expected: the build succeeds and the log shows `Ran 8 tests … OK` (5 helper + 3 driver). If an
`openhands.*` import fails, the SDK moved a symbol: find it with
`docker build --target harness -t agent-harness:dev container-images/agent-harness && docker run --rm --entrypoint /agent-server/.venv/bin/python agent-harness:dev -c "import openhands.sdk as s; print(dir(s))"`
and fix the import, not the test.

- [ ] **Step 7: build.sh and README**

`container-images/agent-harness/build.sh` (mode 0755):

```bash
#!/bin/bash
set -euo pipefail
# The version is READ from the Dockerfile's ARG, as CI does, so a local build
# can never tag itself differently from the registry.
cd "$(dirname "$0")"
VERSION="$(sed -n 's/^ARG AGENT_HARNESS_VERSION=\(.*\)$/\1/p' Dockerfile)"
[ -n "${VERSION}" ] || { echo "error: no 'ARG AGENT_HARNESS_VERSION=' in Dockerfile" >&2; exit 1; }
IMAGE="${CONTAINER_REGISTRY:-ghcr.io/smana}/agent-harness:${VERSION}"
docker build --target test .
docker build -t "${IMAGE}" .
echo "built ${IMAGE}"
```

`container-images/agent-harness/README.md`:

```markdown
# agent-harness

The AgentRun sandbox's harness (SP1 design §5): `ghcr.io/openhands/agent-server:1.49.5-python` plus

| File | Role |
|---|---|
| `agent_run.py` → `agent-run` | Entrypoint: start agent-server, clone and resume `$BRANCH`, POST the conversation, wait, revoke, exit 0/1 |
| `git_credential_agent.py` → `git-credential-agent` | git credential helper; exchanges through identity-proxy `:4001`, caches in memory, `revoke` on exit and in `preStop` |
| `gh` | gh with that token in `GH_TOKEN` |
| `commit-msg` | adds `Agent-Run: $RUN_ID` |

The harness never holds a gateway or octo-sts token: identity-proxy injects them. Test with
`docker build --target test .`; `./build.sh` tests then builds.
```

- [ ] **Step 8: Commit**

```bash
git add container-images/agent-harness
git commit -m "feat(agents): agent-harness image on OpenHands agent-server 1.49.5"
```

### Task 5.2: flux-operator-mcp, read-only, with its own RBAC

**Files:**
- Create: `flux/sources/ocirepo-flux-operator-mcp.yaml`
- Create: `infrastructure/base/agent-mcp/{kustomization.yaml,flux-operator-mcp-helmrelease.yaml,flux-operator-mcp-rbac.yaml,flux-operator-mcp-network-policy.yaml}`

**Interfaces:**
- Produces: Service `flux-operator-mcp.agent-system:9090`, pod label `app.kubernetes.io/name:
  flux-operator-mcp`, SA `flux-operator-mcp` bound to `agent-mcp-flux-read` only.

- [ ] **Step 1: Source and release**

`flux/sources/ocirepo-flux-operator-mcp.yaml`:

```yaml
apiVersion: source.toolkit.fluxcd.io/v1
kind: OCIRepository
metadata:
  name: flux-operator-mcp
  namespace: agent-system
spec:
  interval: 12h
  url: oci://ghcr.io/controlplaneio-fluxcd/charts/flux-operator-mcp
  ref:
    tag: "0.60.0"
  verify:
    provider: cosign
    matchOIDCIdentity:
      - issuer: "https://token.actions.githubusercontent.com"
        subject: "https://github.com/controlplaneio-fluxcd/charts/*"
```

`infrastructure/base/agent-mcp/flux-operator-mcp-helmrelease.yaml`:

```yaml
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: flux-operator-mcp
  namespace: agent-system
spec:
  releaseName: flux-operator-mcp
  interval: 30m
  chartRef:
    kind: OCIRepository
    name: flux-operator-mcp
    namespace: agent-system
  install:
    remediation:
      retries: 3
  upgrade:
    remediation:
      retries: 3
  driftDetection:
    mode: enabled
  values:
    fullnameOverride: flux-operator-mcp
    # --read-only removes the mutating tools, not the RBAC (research pitfall 11).
    readonly: true
    # The chart binds cluster-admin by default. agent-mcp-flux-read replaces it.
    rbac:
      create: false
    # Replaced by flux-operator-mcp-network-policy.yaml.
    networkPolicy:
      create: false
    serviceAccount:
      create: true
      automount: true
      name: flux-operator-mcp
    resources:
      requests:
        cpu: 10m
        memory: 64Mi
      limits:
        cpu: 500m
        memory: 256Mi
    podSecurityContext:
      runAsNonRoot: true
      fsGroup: 1337
      seccompProfile:
        type: RuntimeDefault
```

- [ ] **Step 2: RBAC — reads, no `secrets`**

`infrastructure/base/agent-mcp/flux-operator-mcp-rbac.yaml`:

```yaml
---
# What an agent may read through the Flux MCP server (SP1 §6): Flux objects,
# platform claims, workloads, events and pod logs. Never `secrets` (T12), never a
# write verb. Logs and ConfigMaps may still carry what a process printed; the
# MCPRoutes keep logs away from implementers and from every `public` run.
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: agent-mcp-flux-read
rules:
  - apiGroups:
      - source.toolkit.fluxcd.io
      - source.extensions.fluxcd.io
      - kustomize.toolkit.fluxcd.io
      - helm.toolkit.fluxcd.io
      - notification.toolkit.fluxcd.io
      - image.toolkit.fluxcd.io
      - fluxcd.controlplane.io
      - cloud.ogenki.io
    resources: ["*"]
    verbs: [get, list, watch]
  - apiGroups: [""]
    resources: [pods, pods/log, services, endpoints, events, namespaces, configmaps, persistentvolumeclaims, serviceaccounts, nodes]
    verbs: [get, list, watch]
  - apiGroups: [apps]
    resources: [deployments, statefulsets, daemonsets, replicasets]
    verbs: [get, list, watch]
  - apiGroups: [batch]
    resources: [jobs, cronjobs]
    verbs: [get, list, watch]
  - apiGroups: [events.k8s.io]
    resources: [events]
    verbs: [get, list, watch]
  - apiGroups: [apiextensions.k8s.io]
    resources: [customresourcedefinitions]
    verbs: [get, list, watch]
  - apiGroups: [metrics.k8s.io]
    resources: [pods, nodes]
    verbs: [get, list]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: agent-mcp-flux-read
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: agent-mcp-flux-read
subjects:
  - kind: ServiceAccount
    name: flux-operator-mcp
    namespace: agent-system
```

- [ ] **Step 3: CNP**

`infrastructure/base/agent-mcp/flux-operator-mcp-network-policy.yaml`:

```yaml
---
# Reachable only from the agent-router data plane (SP1 §6).
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: flux-operator-mcp
  namespace: agent-system
spec:
  endpointSelector:
    matchLabels:
      app.kubernetes.io/name: flux-operator-mcp
  ingress:
    - fromEndpoints:
        - matchLabels:
            io.kubernetes.pod.namespace: envoy-gateway-system
            gateway.envoyproxy.io/owning-gateway-name: agent-router
      toPorts:
        - ports:
            - port: "9090"
              protocol: TCP
    - fromEntities:
        - host
      toPorts:
        - ports:
            - port: "9090"
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
    - toEntities:
        - kube-apiserver
      toPorts:
        - ports:
            - port: "443"
              protocol: TCP
```

- [ ] **Step 4: Commit** (the kustomization lands in Task 5.4 with the routes)

```bash
git add flux/sources/ocirepo-flux-operator-mcp.yaml infrastructure/base/agent-mcp
git commit -m "feat(agents): read-only flux-operator-mcp with a narrow ClusterRole"
```

### Task 5.3: VictoriaMetrics and VictoriaLogs MCP servers

**Files:**
- Create: `infrastructure/base/agent-mcp/{mcp-victoriametrics.yaml,mcp-victorialogs.yaml}`

**Interfaces:**
- Produces: Services `mcp-victoriametrics.agent-system:8081`, `mcp-victorialogs.agent-system:8081`,
  pod labels `app.kubernetes.io/name: mcp-victoriametrics|mcp-victorialogs`.

- [ ] **Step 1: The two servers**

`infrastructure/base/agent-mcp/mcp-victoriametrics.yaml`:

```yaml
---
# No Kubernetes identity at all: it reads vmsingle over HTTP (SP1 §6).
apiVersion: v1
kind: ServiceAccount
metadata:
  name: mcp-victoriametrics
  namespace: agent-system
automountServiceAccountToken: false
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: mcp-victoriametrics
  namespace: agent-system
spec:
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: mcp-victoriametrics
  template:
    metadata:
      labels:
        app.kubernetes.io/name: mcp-victoriametrics
    spec:
      serviceAccountName: mcp-victoriametrics
      automountServiceAccountToken: false
      securityContext:
        runAsNonRoot: true
        runAsUser: 65532
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: mcp
          image: ghcr.io/victoriametrics/mcp-victoriametrics:v1.20.2@sha256:bcbf84f945d6efb03fb8b2d2ccc3294420dccdc0b445752dce96f02619416dfe
          env:
            - name: VM_INSTANCE_ENTRYPOINT
              value: http://vmsingle-victoria-metrics-k8s-stack.observability.svc:8428
            - name: VM_INSTANCE_TYPE
              value: single
            - name: MCP_SERVER_MODE
              value: http
            - name: MCP_LISTEN_ADDR
              value: ":8081"
          ports:
            - name: mcp
              containerPort: 8081
              protocol: TCP
          readinessProbe:
            tcpSocket:
              port: mcp
          livenessProbe:
            tcpSocket:
              port: mcp
            periodSeconds: 20
          resources:
            requests:
              cpu: 10m
              memory: 32Mi
            limits:
              cpu: 200m
              memory: 128Mi
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            runAsNonRoot: true
            capabilities:
              drop: ["ALL"]
            seccompProfile:
              type: RuntimeDefault
---
apiVersion: v1
kind: Service
metadata:
  name: mcp-victoriametrics
  namespace: agent-system
spec:
  selector:
    app.kubernetes.io/name: mcp-victoriametrics
  ports:
    - name: mcp
      port: 8081
      targetPort: mcp
---
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: mcp-victoriametrics
  namespace: agent-system
spec:
  endpointSelector:
    matchLabels:
      app.kubernetes.io/name: mcp-victoriametrics
  ingress:
    - fromEndpoints:
        - matchLabels:
            io.kubernetes.pod.namespace: envoy-gateway-system
            gateway.envoyproxy.io/owning-gateway-name: agent-router
      toPorts:
        - ports:
            - port: "8081"
              protocol: TCP
    - fromEntities:
        - host
      toPorts:
        - ports:
            - port: "8081"
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
            io.kubernetes.pod.namespace: observability
      toPorts:
        - ports:
            - port: "8428"
              protocol: TCP
```

`infrastructure/base/agent-mcp/mcp-victorialogs.yaml`:

```yaml
---
# No Kubernetes identity: it reads VictoriaLogs over HTTP (SP1 §6). Logs tools
# reach reviewers, testers and triagers on `internal` only (MCPRoute).
apiVersion: v1
kind: ServiceAccount
metadata:
  name: mcp-victorialogs
  namespace: agent-system
automountServiceAccountToken: false
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: mcp-victorialogs
  namespace: agent-system
spec:
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: mcp-victorialogs
  template:
    metadata:
      labels:
        app.kubernetes.io/name: mcp-victorialogs
    spec:
      serviceAccountName: mcp-victorialogs
      automountServiceAccountToken: false
      securityContext:
        runAsNonRoot: true
        runAsUser: 65532
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: mcp
          image: ghcr.io/victoriametrics/mcp-victorialogs:v1.9.0@sha256:753bb4fbe402ca1a782842f44636830f9895736f11d7fe783b924f8a0daf083d
          env:
            - name: VL_INSTANCE_ENTRYPOINT
              value: http://victoria-logs-victoria-logs-single-server.observability.svc:9428
            - name: MCP_SERVER_MODE
              value: http
            - name: MCP_LISTEN_ADDR
              value: ":8081"
          ports:
            - name: mcp
              containerPort: 8081
              protocol: TCP
          readinessProbe:
            tcpSocket:
              port: mcp
          livenessProbe:
            tcpSocket:
              port: mcp
            periodSeconds: 20
          resources:
            requests:
              cpu: 10m
              memory: 32Mi
            limits:
              cpu: 200m
              memory: 128Mi
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            runAsNonRoot: true
            capabilities:
              drop: ["ALL"]
            seccompProfile:
              type: RuntimeDefault
---
apiVersion: v1
kind: Service
metadata:
  name: mcp-victorialogs
  namespace: agent-system
spec:
  selector:
    app.kubernetes.io/name: mcp-victorialogs
  ports:
    - name: mcp
      port: 8081
      targetPort: mcp
---
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: mcp-victorialogs
  namespace: agent-system
spec:
  endpointSelector:
    matchLabels:
      app.kubernetes.io/name: mcp-victorialogs
  ingress:
    - fromEndpoints:
        - matchLabels:
            io.kubernetes.pod.namespace: envoy-gateway-system
            gateway.envoyproxy.io/owning-gateway-name: agent-router
      toPorts:
        - ports:
            - port: "8081"
              protocol: TCP
    - fromEntities:
        - host
      toPorts:
        - ports:
            - port: "8081"
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
            io.kubernetes.pod.namespace: observability
      toPorts:
        - ports:
            - port: "9428"
              protocol: TCP
```

- [ ] **Step 2: Commit**

```bash
git add infrastructure/base/agent-mcp/mcp-victoriametrics.yaml infrastructure/base/agent-mcp/mcp-victorialogs.yaml
git commit -m "feat(agents): VictoriaMetrics and VictoriaLogs MCP servers for agents"
```

### Task 5.4: MCPRoutes, the child Kustomization, the MCP probe script

**Files:**
- Create: `infrastructure/base/agent-mcp/{mcproutes.yaml,kustomization.yaml}`
- Create: `clusters/aws-0-agent-platform/infrastructure-agent-mcp.yaml`
- Create: `scripts/ops/k8s/agent-probe-mcp.sh`
- Modify: `clusters/aws-0-agent-platform/{kustomization.yaml,README.md}`

**Interfaces:**
- Produces: `MCPRoute agent-mcp-public` (documentation tools only, every role) and
  `agent-mcp-internal` (implementer: Flux reads without logs, metrics, VictoriaLogs docs; reviewer,
  tester, triager: everything). SP2 adds its `room-broker` backend and `room_*` rules to both files.

- [ ] **Step 1: Routes**

Cluster reads are internal data (OD-13), so `public` is documentation only. Each authorization
rule's target holds at most 16 tools (Agent Router 1.1.0 schema), hence one rule per role and
backend. These two routes were validated against the pinned `ai-gateway-crds-helm` 1.1.0 schema.

`infrastructure/base/agent-mcp/mcproutes.yaml`:

```yaml
# Two MCPRoutes, one per agent-router listener (SP1 §6). Both reuse that
# listener's issuer and audiences for `oauth`, deny by default, and allow each
# role its tools on `aud`. toolSelector hides every other tool, including all
# mutating ones. SP2 adds the room-broker backend (:8090) and its room_* rules.
---
apiVersion: aigateway.envoyproxy.io/v1beta1
kind: MCPRoute
metadata: {name: agent-mcp-public, namespace: agent-system}
spec:
  parentRefs:
  - {group: gateway.networking.k8s.io, kind: Gateway, name: agent-router, sectionName: public}
  path: /mcp
  backendRefs:
  - name: flux-operator-mcp
    port: 9090
    path: /mcp
    toolSelector:
      include: [search_flux_docs]
  - name: mcp-victoriametrics
    port: 8081
    path: /mcp
    toolSelector:
      include: [documentation]
  - name: mcp-victorialogs
    port: 8081
    path: /mcp
    toolSelector:
      include: [documentation]
  securityPolicy:
    oauth:
      issuer: ${oidc_issuer_url}
      audiences: [agent-router.implementer.public, agent-router.reviewer.public, agent-router.tester.public, agent-router.triager.public]
      jwks:
        remoteJWKS: {uri: '${oidc_issuer_url}/keys'}
      claimToHeaders:
      - {claim: sub, header: x-ar-agent}
      protectedResourceMetadata: {resource: 'http://agent-router.envoy-gateway-system.svc.cluster.local:8080/mcp'}
    authorization:
      defaultAction: Deny
      rules:
      - action: Allow
        source:
          jwt:
            claims:
            - name: aud
              valueType: StringArray
              values: [agent-router.implementer.public]
        target:
          tools:
          - {backend: flux-operator-mcp, tool: search_flux_docs}
      - action: Allow
        source:
          jwt:
            claims:
            - name: aud
              valueType: StringArray
              values: [agent-router.implementer.public]
        target:
          tools:
          - {backend: mcp-victoriametrics, tool: documentation}
      - action: Allow
        source:
          jwt:
            claims:
            - name: aud
              valueType: StringArray
              values: [agent-router.implementer.public]
        target:
          tools:
          - {backend: mcp-victorialogs, tool: documentation}
      - action: Allow
        source:
          jwt:
            claims:
            - name: aud
              valueType: StringArray
              values: [agent-router.reviewer.public]
        target:
          tools:
          - {backend: flux-operator-mcp, tool: search_flux_docs}
      - action: Allow
        source:
          jwt:
            claims:
            - name: aud
              valueType: StringArray
              values: [agent-router.reviewer.public]
        target:
          tools:
          - {backend: mcp-victoriametrics, tool: documentation}
      - action: Allow
        source:
          jwt:
            claims:
            - name: aud
              valueType: StringArray
              values: [agent-router.reviewer.public]
        target:
          tools:
          - {backend: mcp-victorialogs, tool: documentation}
      - action: Allow
        source:
          jwt:
            claims:
            - name: aud
              valueType: StringArray
              values: [agent-router.tester.public]
        target:
          tools:
          - {backend: flux-operator-mcp, tool: search_flux_docs}
      - action: Allow
        source:
          jwt:
            claims:
            - name: aud
              valueType: StringArray
              values: [agent-router.tester.public]
        target:
          tools:
          - {backend: mcp-victoriametrics, tool: documentation}
      - action: Allow
        source:
          jwt:
            claims:
            - name: aud
              valueType: StringArray
              values: [agent-router.tester.public]
        target:
          tools:
          - {backend: mcp-victorialogs, tool: documentation}
      - action: Allow
        source:
          jwt:
            claims:
            - name: aud
              valueType: StringArray
              values: [agent-router.triager.public]
        target:
          tools:
          - {backend: flux-operator-mcp, tool: search_flux_docs}
      - action: Allow
        source:
          jwt:
            claims:
            - name: aud
              valueType: StringArray
              values: [agent-router.triager.public]
        target:
          tools:
          - {backend: mcp-victoriametrics, tool: documentation}
      - action: Allow
        source:
          jwt:
            claims:
            - name: aud
              valueType: StringArray
              values: [agent-router.triager.public]
        target:
          tools:
          - {backend: mcp-victorialogs, tool: documentation}
---
apiVersion: aigateway.envoyproxy.io/v1beta1
kind: MCPRoute
metadata: {name: agent-mcp-internal, namespace: agent-system}
spec:
  parentRefs:
  - {group: gateway.networking.k8s.io, kind: Gateway, name: agent-router, sectionName: internal}
  path: /mcp
  backendRefs:
  - name: flux-operator-mcp
    port: 9090
    path: /mcp
    toolSelector:
      include: [search_flux_docs, get_flux_instance, get_kubernetes_api_versions, get_kubernetes_resources, get_kubernetes_metrics, get_kubernetes_logs]
  - name: mcp-victoriametrics
    port: 8081
    path: /mcp
    toolSelector:
      include: [documentation, query, query_range, metrics, metrics_metadata, labels, label_values, series, alerts, rules, explain_query, prettify_query, metric_statistics,
        tsdb_status, active_queries, top_queries]
  - name: mcp-victorialogs
    port: 8081
    path: /mcp
    toolSelector:
      include: [documentation, query, hits, facets, field_names, field_values, stats_query, stats_query_range, streams, stream_ids, stream_field_names, stream_field_values,
        flags]
  securityPolicy:
    oauth:
      issuer: ${oidc_issuer_url}
      audiences: [agent-router.implementer.internal, agent-router.reviewer.internal, agent-router.tester.internal, agent-router.triager.internal]
      jwks:
        remoteJWKS: {uri: '${oidc_issuer_url}/keys'}
      claimToHeaders:
      - {claim: sub, header: x-ar-agent}
      protectedResourceMetadata: {resource: 'http://agent-router.envoy-gateway-system.svc.cluster.local:8081/mcp'}
    authorization:
      defaultAction: Deny
      rules:
      - action: Allow
        source:
          jwt:
            claims:
            - name: aud
              valueType: StringArray
              values: [agent-router.implementer.internal]
        target:
          tools:
          - {backend: flux-operator-mcp, tool: search_flux_docs}
          - {backend: flux-operator-mcp, tool: get_flux_instance}
          - {backend: flux-operator-mcp, tool: get_kubernetes_api_versions}
          - {backend: flux-operator-mcp, tool: get_kubernetes_resources}
          - {backend: flux-operator-mcp, tool: get_kubernetes_metrics}
      - action: Allow
        source:
          jwt:
            claims:
            - name: aud
              valueType: StringArray
              values: [agent-router.implementer.internal]
        target:
          tools:
          - {backend: mcp-victoriametrics, tool: documentation}
          - {backend: mcp-victoriametrics, tool: query}
          - {backend: mcp-victoriametrics, tool: query_range}
          - {backend: mcp-victoriametrics, tool: metrics}
          - {backend: mcp-victoriametrics, tool: metrics_metadata}
          - {backend: mcp-victoriametrics, tool: labels}
          - {backend: mcp-victoriametrics, tool: label_values}
          - {backend: mcp-victoriametrics, tool: series}
          - {backend: mcp-victoriametrics, tool: alerts}
          - {backend: mcp-victoriametrics, tool: rules}
          - {backend: mcp-victoriametrics, tool: explain_query}
          - {backend: mcp-victoriametrics, tool: prettify_query}
          - {backend: mcp-victoriametrics, tool: metric_statistics}
          - {backend: mcp-victoriametrics, tool: tsdb_status}
          - {backend: mcp-victoriametrics, tool: active_queries}
          - {backend: mcp-victoriametrics, tool: top_queries}
      - action: Allow
        source:
          jwt:
            claims:
            - name: aud
              valueType: StringArray
              values: [agent-router.implementer.internal]
        target:
          tools:
          - {backend: mcp-victorialogs, tool: documentation}
      - action: Allow
        source:
          jwt:
            claims:
            - name: aud
              valueType: StringArray
              values: [agent-router.reviewer.internal]
        target:
          tools:
          - {backend: flux-operator-mcp, tool: search_flux_docs}
          - {backend: flux-operator-mcp, tool: get_flux_instance}
          - {backend: flux-operator-mcp, tool: get_kubernetes_api_versions}
          - {backend: flux-operator-mcp, tool: get_kubernetes_resources}
          - {backend: flux-operator-mcp, tool: get_kubernetes_metrics}
          - {backend: flux-operator-mcp, tool: get_kubernetes_logs}
      - action: Allow
        source:
          jwt:
            claims:
            - name: aud
              valueType: StringArray
              values: [agent-router.reviewer.internal]
        target:
          tools:
          - {backend: mcp-victoriametrics, tool: documentation}
          - {backend: mcp-victoriametrics, tool: query}
          - {backend: mcp-victoriametrics, tool: query_range}
          - {backend: mcp-victoriametrics, tool: metrics}
          - {backend: mcp-victoriametrics, tool: metrics_metadata}
          - {backend: mcp-victoriametrics, tool: labels}
          - {backend: mcp-victoriametrics, tool: label_values}
          - {backend: mcp-victoriametrics, tool: series}
          - {backend: mcp-victoriametrics, tool: alerts}
          - {backend: mcp-victoriametrics, tool: rules}
          - {backend: mcp-victoriametrics, tool: explain_query}
          - {backend: mcp-victoriametrics, tool: prettify_query}
          - {backend: mcp-victoriametrics, tool: metric_statistics}
          - {backend: mcp-victoriametrics, tool: tsdb_status}
          - {backend: mcp-victoriametrics, tool: active_queries}
          - {backend: mcp-victoriametrics, tool: top_queries}
      - action: Allow
        source:
          jwt:
            claims:
            - name: aud
              valueType: StringArray
              values: [agent-router.reviewer.internal]
        target:
          tools:
          - {backend: mcp-victorialogs, tool: documentation}
          - {backend: mcp-victorialogs, tool: query}
          - {backend: mcp-victorialogs, tool: hits}
          - {backend: mcp-victorialogs, tool: facets}
          - {backend: mcp-victorialogs, tool: field_names}
          - {backend: mcp-victorialogs, tool: field_values}
          - {backend: mcp-victorialogs, tool: stats_query}
          - {backend: mcp-victorialogs, tool: stats_query_range}
          - {backend: mcp-victorialogs, tool: streams}
          - {backend: mcp-victorialogs, tool: stream_ids}
          - {backend: mcp-victorialogs, tool: stream_field_names}
          - {backend: mcp-victorialogs, tool: stream_field_values}
          - {backend: mcp-victorialogs, tool: flags}
      - action: Allow
        source:
          jwt:
            claims:
            - name: aud
              valueType: StringArray
              values: [agent-router.tester.internal]
        target:
          tools:
          - {backend: flux-operator-mcp, tool: search_flux_docs}
          - {backend: flux-operator-mcp, tool: get_flux_instance}
          - {backend: flux-operator-mcp, tool: get_kubernetes_api_versions}
          - {backend: flux-operator-mcp, tool: get_kubernetes_resources}
          - {backend: flux-operator-mcp, tool: get_kubernetes_metrics}
          - {backend: flux-operator-mcp, tool: get_kubernetes_logs}
      - action: Allow
        source:
          jwt:
            claims:
            - name: aud
              valueType: StringArray
              values: [agent-router.tester.internal]
        target:
          tools:
          - {backend: mcp-victoriametrics, tool: documentation}
          - {backend: mcp-victoriametrics, tool: query}
          - {backend: mcp-victoriametrics, tool: query_range}
          - {backend: mcp-victoriametrics, tool: metrics}
          - {backend: mcp-victoriametrics, tool: metrics_metadata}
          - {backend: mcp-victoriametrics, tool: labels}
          - {backend: mcp-victoriametrics, tool: label_values}
          - {backend: mcp-victoriametrics, tool: series}
          - {backend: mcp-victoriametrics, tool: alerts}
          - {backend: mcp-victoriametrics, tool: rules}
          - {backend: mcp-victoriametrics, tool: explain_query}
          - {backend: mcp-victoriametrics, tool: prettify_query}
          - {backend: mcp-victoriametrics, tool: metric_statistics}
          - {backend: mcp-victoriametrics, tool: tsdb_status}
          - {backend: mcp-victoriametrics, tool: active_queries}
          - {backend: mcp-victoriametrics, tool: top_queries}
      - action: Allow
        source:
          jwt:
            claims:
            - name: aud
              valueType: StringArray
              values: [agent-router.tester.internal]
        target:
          tools:
          - {backend: mcp-victorialogs, tool: documentation}
          - {backend: mcp-victorialogs, tool: query}
          - {backend: mcp-victorialogs, tool: hits}
          - {backend: mcp-victorialogs, tool: facets}
          - {backend: mcp-victorialogs, tool: field_names}
          - {backend: mcp-victorialogs, tool: field_values}
          - {backend: mcp-victorialogs, tool: stats_query}
          - {backend: mcp-victorialogs, tool: stats_query_range}
          - {backend: mcp-victorialogs, tool: streams}
          - {backend: mcp-victorialogs, tool: stream_ids}
          - {backend: mcp-victorialogs, tool: stream_field_names}
          - {backend: mcp-victorialogs, tool: stream_field_values}
          - {backend: mcp-victorialogs, tool: flags}
      - action: Allow
        source:
          jwt:
            claims:
            - name: aud
              valueType: StringArray
              values: [agent-router.triager.internal]
        target:
          tools:
          - {backend: flux-operator-mcp, tool: search_flux_docs}
          - {backend: flux-operator-mcp, tool: get_flux_instance}
          - {backend: flux-operator-mcp, tool: get_kubernetes_api_versions}
          - {backend: flux-operator-mcp, tool: get_kubernetes_resources}
          - {backend: flux-operator-mcp, tool: get_kubernetes_metrics}
          - {backend: flux-operator-mcp, tool: get_kubernetes_logs}
      - action: Allow
        source:
          jwt:
            claims:
            - name: aud
              valueType: StringArray
              values: [agent-router.triager.internal]
        target:
          tools:
          - {backend: mcp-victoriametrics, tool: documentation}
          - {backend: mcp-victoriametrics, tool: query}
          - {backend: mcp-victoriametrics, tool: query_range}
          - {backend: mcp-victoriametrics, tool: metrics}
          - {backend: mcp-victoriametrics, tool: metrics_metadata}
          - {backend: mcp-victoriametrics, tool: labels}
          - {backend: mcp-victoriametrics, tool: label_values}
          - {backend: mcp-victoriametrics, tool: series}
          - {backend: mcp-victoriametrics, tool: alerts}
          - {backend: mcp-victoriametrics, tool: rules}
          - {backend: mcp-victoriametrics, tool: explain_query}
          - {backend: mcp-victoriametrics, tool: prettify_query}
          - {backend: mcp-victoriametrics, tool: metric_statistics}
          - {backend: mcp-victoriametrics, tool: tsdb_status}
          - {backend: mcp-victoriametrics, tool: active_queries}
          - {backend: mcp-victoriametrics, tool: top_queries}
      - action: Allow
        source:
          jwt:
            claims:
            - name: aud
              valueType: StringArray
              values: [agent-router.triager.internal]
        target:
          tools:
          - {backend: mcp-victorialogs, tool: documentation}
          - {backend: mcp-victorialogs, tool: query}
          - {backend: mcp-victorialogs, tool: hits}
          - {backend: mcp-victorialogs, tool: facets}
          - {backend: mcp-victorialogs, tool: field_names}
          - {backend: mcp-victorialogs, tool: field_values}
          - {backend: mcp-victorialogs, tool: stats_query}
          - {backend: mcp-victorialogs, tool: stats_query_range}
          - {backend: mcp-victorialogs, tool: streams}
          - {backend: mcp-victorialogs, tool: stream_ids}
          - {backend: mcp-victorialogs, tool: stream_field_names}
          - {backend: mcp-victorialogs, tool: stream_field_values}
          - {backend: mcp-victorialogs, tool: flags}
```

`infrastructure/base/agent-mcp/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

# Read-only MCP servers, reachable only from the agent-router data plane.
resources:
  - flux-operator-mcp-helmrelease.yaml
  - flux-operator-mcp-rbac.yaml
  - flux-operator-mcp-network-policy.yaml
  - mcp-victoriametrics.yaml
  - mcp-victorialogs.yaml
  - mcproutes.yaml
```

`clusters/aws-0-agent-platform/infrastructure-agent-mcp.yaml`:

```yaml
---
# Read-only MCP servers and the two MCPRoutes on agent-router (SP1 §6).
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: agent-mcp
  namespace: flux-system
spec:
  prune: true
  interval: 5m0s
  timeout: 5m0s
  path: ./infrastructure/base/agent-mcp
  sourceRef:
    kind: ExternalArtifact
    name: infra-artifact
  postBuild:
    substituteFrom:
      - kind: ConfigMap
        name: eks-aws-0-vars
  dependsOn:
    - name: agent-router
  healthChecks:
    - apiVersion: helm.toolkit.fluxcd.io/v2
      kind: HelmRelease
      name: flux-operator-mcp
      namespace: agent-system
    - apiVersion: apps/v1
      kind: Deployment
      name: mcp-victoriametrics
      namespace: agent-system
    - apiVersion: apps/v1
      kind: Deployment
      name: mcp-victorialogs
      namespace: agent-system
```

Add `- infrastructure-agent-mcp.yaml` to the children and the README row
`` | `agent-mcp` | `infrastructure/base/agent-mcp` | Flux, VictoriaMetrics, VictoriaLogs MCP servers and their MCPRoutes | ``.

- [ ] **Step 2: MCP client for the probe**

`scripts/ops/k8s/agent-probe-mcp.sh` (mode 0755; copied into the probe and run there):

```sh
#!/bin/sh
# MCP over streamable HTTP from the agent probe, with its token of one class.
# usage: agent-probe-mcp.sh <public|internal> <method> [params-json]
set -eu
CLASS=$1 METHOD=$2 PARAMS=${3:-"{}"}
PORT=8080
[ "$CLASS" = internal ] && PORT=8081
URL=http://agent-router.envoy-gateway-system.svc.cluster.local:$PORT/mcp
AUTH="Authorization: Bearer $(cat /var/run/secrets/probe/$CLASS/token)"
ACCEPT='accept: application/json, text/event-stream'
curl -s -D /tmp/h -o /dev/null -H "$AUTH" -H "$ACCEPT" -H 'content-type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"agent-probe","version":"1"}}}' "$URL"
SID=$(grep -i '^mcp-session-id:' /tmp/h | cut -d' ' -f2 | tr -d '\r' || true)
curl -s -o /dev/null -H "$AUTH" -H "$ACCEPT" -H "mcp-session-id: $SID" -H 'content-type: application/json' \
  -d '{"jsonrpc":"2.0","method":"notifications/initialized"}' "$URL"
curl -s -w '\nHTTP %{http_code}\n' -H "$AUTH" -H "$ACCEPT" -H "mcp-session-id: $SID" -H 'content-type: application/json' \
  -d "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"$METHOD\",\"params\":$PARAMS}" "$URL"
```

- [ ] **Step 3: Commit**

```bash
git add infrastructure/base/agent-mcp/mcproutes.yaml infrastructure/base/agent-mcp/kustomization.yaml clusters/aws-0-agent-platform scripts/ops/k8s/agent-probe-mcp.sh
git commit -m "feat(agents): per-class MCPRoutes with role-scoped tools"
```

### Task 5.5: Validate and open PR 5

- [ ] **Step 1: Gates**

Run: `./scripts/ci/validate-manifests.sh && task check && ./scripts/ci/validate-links.sh`
Expected: exit 0; `Invalid: 0, Skipped: 0`; Polaris clean on the three MCP Deployments. The image is
built by CI on this PR (not pushed); the Trivy scan runs on `main` after merge.

- [ ] **Step 2: Ship**

`ship-it`. PR body: phase 5 of 6; the harness image publishes on merge as `v0.1.0`, and the
composition switches to it in CC-2 (phase 6).

### Task 5.6: [LIVE] SC-08, SC-12, SC-17 (MCP half)

**Files:** none.

- [ ] **Step 1: Deploy and open the gate**

```bash
cd opentofu && TF_VAR_flux_git_ref=refs/heads/feat/agent-harness terramate script run deploy
flux resume kustomization ai-gateway -n flux-system
flux resume kustomization agent-platform -n flux-system
flux get kustomizations -n flux-system agent-mcp
kubectl get mcproute -n agent-system -o custom-columns=NAME:.metadata.name,ACCEPTED:'.status.conditions[?(@.type=="Accepted")].status'
```
Expected: `agent-mcp` `Ready=True`; both MCPRoutes `True`. If one is not accepted, read its
condition message and fix the route before going on.

- [ ] **Step 2: SC-08 — no API token, no API route**

```bash
kubectl apply -f /home/smana/Sources/crossplane-configuration/examples/agentrun-basic.yaml
kubectl wait -n agents agentrun/xplane-run-7f3cq2xz --for=jsonpath='{.status.phase}'=Running --timeout=15m
kubectl exec -n agents xplane-run-7f3cq2xz -c harness -- ls /var/run/secrets/kubernetes.io ; echo "exit=$?"
kubectl exec -n agents xplane-run-7f3cq2xz -c harness -- /usr/local/bin/python -c "import urllib.request; urllib.request.urlopen('https://kubernetes.default.svc', timeout=5)" ; echo "exit=$?"
kubectl delete agentrun -n agents xplane-run-7f3cq2xz --wait
```
Expected: `No such file or directory` with `exit=2`; a name-resolution or timeout error with
`exit=1`.

- [ ] **Step 3: SC-12 and SC-17 (MCP half) through the probe**

```bash
kubectl apply -f scripts/ops/k8s/agent-probe.yaml
kubectl wait -n agents sandbox/agent-probe --for=condition=Ready --timeout=10m
kubectl cp scripts/ops/k8s/agent-probe-mcp.sh agents/agent-probe:/tmp/mcp.sh -c probe
kubectl exec -n agents agent-probe -c probe -- sh /tmp/mcp.sh public tools/list | grep -o '"name":"[^"]*"'
kubectl exec -n agents agent-probe -c probe -- sh /tmp/mcp.sh internal tools/list | grep -o '"name":"[^"]*logs[^"]*"'
```
Expected: the `public` list holds exactly three tools, the Flux `search_flux_docs` and the two
`documentation` tools (SC-17). The `internal` list shows the Flux logs tool under its routed name,
which the next command reuses:

```bash
LOGS=$(kubectl exec -n agents agent-probe -c probe -- sh /tmp/mcp.sh internal tools/list | grep -o '"name":"[^"]*get_kubernetes_logs[^"]*"' | head -1 | cut -d'"' -f4)
echo "$LOGS"
kubectl exec -n agents agent-probe -c probe -- sh /tmp/mcp.sh internal tools/call "{\"name\":\"$LOGS\",\"arguments\":{\"name\":\"octo-sts\",\"namespace\":\"agent-system\"}}"
kubectl auth can-i get secrets --as=system:serviceaccount:agent-system:flux-operator-mcp -A
kubectl auth can-i get pods/log --as=system:serviceaccount:agent-system:flux-operator-mcp -A
kubectl delete -f scripts/ops/k8s/agent-probe.yaml
```
Expected: the call is refused (HTTP 403 or a JSON-RPC error naming authorization) because the probe
is an `implementer`; `no`; `yes`. Paste the outputs into PR 5 as the SC-08, SC-12 and SC-17
evidence.

---
## Phase 6 — End to end (CC-2, then PR 6, branch `feat/agent-e2e`)

Starts after PR 5 merged and `ghcr.io/smana/agent-harness:v0.1.0` exists. Gate: SC-04, SC-06 (live),
SC-07, SC-09 (composed), SC-13, SC-14, SC-16; SC-15 read back from the spike.

### Task 6.1: CC-2 — the `openhands` profile becomes the platform harness (crossplane-configuration)

Runs in `Smana/crossplane-configuration`, fresh worktree `feat/agentrun-harness` off `origin/main`.

**Files:**
- Modify: `apis/agentrun/kcl/main.k` (`_HARNESS_PROFILES`), `apis/agentrun/kcl/main_test.k` (one
  test replaced), `apis/agentrun/composition.yaml` (regenerated), `tests/golden/agentrun-*.yaml`
  (re-captured), `packages/aws/crossplane.yaml` (core floor)

**Interfaces:**
- Consumes: `ghcr.io/smana/agent-harness:v0.1.0` (Task 5.1), whose entrypoint `agent-run` starts
  agent-server on `0.0.0.0:8000` itself.
- Produces: release `v0.8.1`.

- [ ] **Step 1: Replace the test first**

In `main_test.k`, replace `test_harness_binds_for_probes` with:

```kcl
test_harness_profile_is_the_platform_image = lambda {
    _c = _pod(_run({})).containers[0]
    assert _c.image.startswith("ghcr.io/smana/agent-harness:v0.1.0@sha256:"), "the openhands profile is the repo-built harness (S7)"
    assert _c.args == [], "agent-run starts agent-server on 0.0.0.0 itself"
}
```

Run: `cd apis/agentrun/kcl && kcl test . -Y settings-example.yaml`
Expected: FAIL on `test_harness_profile_is_the_platform_image` only (27/28 pass).

- [ ] **Step 2: Pin the harness by digest**

```bash
DIGEST=$(skopeo inspect --raw docker://ghcr.io/smana/agent-harness:v0.1.0 | sha256sum | cut -d' ' -f1)
sed -i "s|ghcr.io/openhands/agent-server:1.49.5-python@sha256:[0-9a-f]*|ghcr.io/smana/agent-harness:v0.1.0@sha256:${DIGEST}|" apis/agentrun/kcl/main.k
python3 - apis/agentrun/kcl/main.k <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
old = """        # agent-server binds 127.0.0.1 unless told otherwise, and kubelet probes
        # the pod IP. The CNP admits only `host` on this port.
        args = ["--host", "0.0.0.0", "--port", "8000"]"""
new = """        # agent-run, the image's entrypoint, starts agent-server on 0.0.0.0:8000
        # itself; the CNP admits only `host` on this port.
        args = []"""
assert old in s, "profile block moved; edit by hand"
open(p, "w").write(s.replace(old, new))
PY
grep -c 'ghcr.io/smana/agent-harness:v0.1.0@sha256:[0-9a-f]\{64\}' apis/agentrun/kcl/main.k
```
Expected: `1`.

Run: `cd apis/agentrun/kcl && kcl fmt . && kcl test . -Y settings-example.yaml`
Expected: `PASS: 28/28`.

- [ ] **Step 3: Raise the core floor, regenerate, re-capture**

`packages/aws/crossplane.yaml`: `version: ">=v0.8.1"` (the Composition is in core; an installed
`v0.8.0` core would otherwise stay).

```bash
task generate
for ex in agentrun-basic agentrun-complete; do
  crossplane render examples/$ex.yaml apis/agentrun/composition.yaml functions.yaml \
    --extra-resources examples/environmentconfig.yaml > tests/golden/$ex.yaml
done
git diff --stat tests/golden
git diff tests/golden | grep '^[-+] ' | grep -v -E 'image:|args|--host|0\.0\.0\.0|--port|"8000"' | head
task check
```
Expected: the golden diff touches only the harness `image` and `args` lines (the last `grep` prints
nothing); `task check` exit 0.

- [ ] **Step 4: Commit, PR, release**

```bash
git add apis/agentrun packages/aws/crossplane.yaml tests/golden/agentrun-basic.yaml tests/golden/agentrun-complete.yaml
git commit -m "feat(agentrun): run the platform agent-harness image"
```

`ship-it` for CC-2. **[OWNER]** merge, then `git fetch origin && git tag v0.8.1 origin/main && git push origin v0.8.1`.
Confirm: `curl -fsSL https://github.com/Smana/crossplane-configuration/releases/download/v0.8.1/xrd-crds.yaml | grep -c agentruns.cloud.ogenki.io` → `1`.

### Task 6.2: Pin `v0.8.1` in this repo

**Files:**
- Modify: `infrastructure/base/crossplane/configuration-aws/configuration-packages.yaml`,
  `apps/platform/app-wizard/app.yaml`

- [ ] **Step 1: Worktree and bump**

`EnterWorktree` with branch `feat/agent-e2e`. Set `package: ghcr.io/smana/crossplane-configuration-aws:v0.8.1`
and `- --branch=v0.8.1`.

Run: `./scripts/ci/flux-schema/gen-catalog.sh | grep agentrun`
Expected: `.schemas/cloud.ogenki.io/agentrun_v1alpha1.json`.

- [ ] **Step 2: Commit**

```bash
git add infrastructure/base/crossplane/configuration-aws/configuration-packages.yaml apps/platform/app-wizard/app.yaml
git commit -m "chore(crossplane): crossplane-configuration v0.8.1 with the agent harness"
```

### Task 6.3: `task agent:run`

**Files:**
- Create: `scripts/ops/k8s/agent-run.sh`
- Test: `scripts/ci/tests/test-agent-run.sh`
- Modify: `taskfile.yaml` (one task), `scripts/README.md` (the `ops/k8s/` mention)

**Interfaces:**
- Produces: `task agent:run -- --role <role> --class <class> (--task <text> | --task-url <url>) […]`,
  printing `xplane-run-<runId>`. Used by Tasks 6.7 and 6.8.

- [ ] **Step 1: The failing test**

`scripts/ci/tests/test-agent-run.sh`:

```bash
#!/usr/bin/env bash
# requires: jq python3
#
# scripts/ops/k8s/agent-run.sh against a PATH-stubbed kubectl: the claim it
# applies has a valid runId and the fields asked for, and it refuses to guess a
# data class or a task. No test contacts a cluster.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUBJECT="$HERE/../../ops/k8s/agent-run.sh"
fails=0
fail() { printf 'FAIL  %s\n' "$*" >&2; fails=$((fails + 1)); }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
cat >"$tmp/bin/kubectl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >"$STUB_ARGS"
cat >"$STUB_CLAIM"
STUB
chmod +x "$tmp/bin/kubectl"
export PATH="$tmp/bin:$PATH" STUB_ARGS="$tmp/args" STUB_CLAIM="$tmp/claim" AGENT_PRINCIPAL="human:312345678901234567"

out="$(bash "$SUBJECT" --role implementer --class public --task 'Fix "the" link' --profiles pypi,npm)" || fail "a valid call exits 0"
jq -e '.metadata.name | test("^xplane-run-[a-z2-7]{8}$")' "$STUB_CLAIM" >/dev/null || fail "runId is 8 characters of [a-z2-7]"
[ "$out" = "$(jq -r .metadata.name "$STUB_CLAIM")" ] || fail "prints the run's name"
jq -e '.metadata.namespace == "agents" and .spec.role == "implementer" and .spec.dataClass == "public"' "$STUB_CLAIM" >/dev/null || fail "namespace, role, class"
jq -e '.spec.task == {"text":"Fix \"the\" link"} and .spec.egress.profiles == ["pypi","npm"]' "$STUB_CLAIM" >/dev/null || fail "task text survives quoting; profiles split"
jq -e '.spec.principal == "human:312345678901234567" and .spec.budget.maxMinutes == 120 and (.spec | has("branch") | not)' "$STUB_CLAIM" >/dev/null || fail "principal, default minutes, no branch unless asked"
grep -qx 'apply -f -' "$STUB_ARGS" || fail "applies from stdin without dry-run by default"

bash "$SUBJECT" --role reviewer --class internal --task-url https://github.com/Smana/cloud-native-ref/pull/1 --dry-run >/dev/null || fail "task-url call exits 0"
jq -e '.spec.task == {"url":"https://github.com/Smana/cloud-native-ref/pull/1"}' "$STUB_CLAIM" >/dev/null || fail "task url"
grep -qx 'apply --dry-run=server -f -' "$STUB_ARGS" || fail "--dry-run is server-side"

bash "$SUBJECT" --role implementer --task x >/dev/null 2>&1; [ $? -eq 2 ] || fail "refuses a missing data class"
bash "$SUBJECT" --role implementer --class public >/dev/null 2>&1; [ $? -eq 2 ] || fail "refuses a missing task"
bash "$SUBJECT" --role implementer --class public --task x --task-url y >/dev/null 2>&1; [ $? -eq 2 ] || fail "refuses both task forms"

[ "$fails" -eq 0 ] || exit 1
echo "PASS"
```

Run: `bash scripts/ci/tests/test-agent-run.sh`
Expected: FAIL — `a valid call exits 0` (no script yet).

- [ ] **Step 2: The script**

`scripts/ops/k8s/agent-run.sh` (mode 0755):

```bash
#!/usr/bin/env bash
# Creates one AgentRun (SP1). Until SP3's factory ships, the owner creates runs
# directly (C3), so this script is the creator: it generates the runId (C2).
#
# usage: agent-run.sh --role <implementer|reviewer|tester|triager> --class <public|internal>
#                     (--task "<text>" | --task-url <issue or PR URL>)
#                     [--repo <owner/name>] [--branch agent/<id>] [--size small|medium|large]
#                     [--minutes <1-480>] [--profiles pypi,npm,golang,crates] [--dry-run]
# AGENT_PRINCIPAL overrides the principal (default: human:<git user.email>).
set -euo pipefail

repo=Smana/cloud-native-ref role="" class="" task="" url="" branch="" size=small minutes=120 profiles="" dry=""
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) repo=$2; shift 2 ;;
    --role) role=$2; shift 2 ;;
    --class) class=$2; shift 2 ;;
    --task) task=$2; shift 2 ;;
    --task-url) url=$2; shift 2 ;;
    --branch) branch=$2; shift 2 ;;
    --size) size=$2; shift 2 ;;
    --minutes) minutes=$2; shift 2 ;;
    --profiles) profiles=$2; shift 2 ;;
    --dry-run) dry="--dry-run=server"; shift ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
# No default data class: classifying data is a decision (design §2).
if [ -z "$role" ] || [ -z "$class" ]; then
  echo "--role and --class are required" >&2; exit 2
fi
if { [ -n "$task" ] && [ -n "$url" ]; } || { [ -z "$task" ] && [ -z "$url" ]; }; then
  echo "give exactly one of --task or --task-url" >&2; exit 2
fi
principal="${AGENT_PRINCIPAL:-human:$(git config user.email)}"
run_id="$(python3 -c 'import secrets; print("".join(secrets.choice("abcdefghijklmnopqrstuvwxyz234567") for _ in range(8)))')"

# JSON, not YAML: task text passes through unescaped by the shell.
claim="$(RUN_ID="$run_id" REPO="$repo" ROLE="$role" CLASS="$class" TASK="$task" URL="$url" \
  BRANCH="$branch" SIZE="$size" MINUTES="$minutes" PROFILES="$profiles" PRINCIPAL="$principal" python3 -c '
import json, os
e = os.environ
spec = {"role": e["ROLE"], "repository": e["REPO"], "principal": e["PRINCIPAL"], "dataClass": e["CLASS"],
        "size": e["SIZE"], "budget": {"maxMinutes": int(e["MINUTES"])},
        "task": {"text": e["TASK"]} if e["TASK"] else {"url": e["URL"]}}
if e["BRANCH"]:
    spec["branch"] = e["BRANCH"]
if e["PROFILES"]:
    spec["egress"] = {"profiles": e["PROFILES"].split(",")}
print(json.dumps({"apiVersion": "cloud.ogenki.io/v1alpha1", "kind": "AgentRun",
                  "metadata": {"name": "xplane-run-" + e["RUN_ID"], "namespace": "agents"}, "spec": spec}))')"

# $dry is empty or one flag; unquoted on purpose.
# shellcheck disable=SC2086
printf '%s\n' "$claim" | kubectl apply $dry -f -
echo "xplane-run-$run_id"
```

In `taskfile.yaml`, under `tasks:` after `check`:

```yaml
  # The design names this `task agent:run` (SP1 §Implementation outline): the
  # owner's way to start a run until SP3's factory is the only creator (C3).
  agent:run:
    desc: Create one AgentRun on the current cluster (owner only until SP3)
    cmds: ["{{.ROOT_DIR}}/scripts/ops/k8s/agent-run.sh {{.CLI_ARGS}}"]
```

In `scripts/README.md`, the `ops/k8s/` mention gains "`agent-run.sh` (`task agent:run`) creates one
AgentRun".

- [ ] **Step 3: Pass, and the suites around it**

Run: `bash scripts/ci/tests/test-agent-run.sh && bash scripts/ci/tests/run.sh | grep -E 'agent-run|script-paths|no-secret-argv'`
Expected: `PASS`, then three `PASS` lines.

- [ ] **Step 4: Commit**

```bash
git add scripts/ops/k8s/agent-run.sh scripts/ci/tests/test-agent-run.sh taskfile.yaml scripts/README.md
git commit -m "feat(scripts): task agent:run creates one AgentRun"
```

### Task 6.4: VMRules and the dashboard

**Files:**
- Create: `observability/base/agent-platform/{kustomization.yaml,vmrule.yaml,vmrule-logs.yaml,grafana-folder.yaml,grafana-dashboard.yaml}`
- Create: `clusters/aws-0-agent-platform/observability-agent-platform.yaml`
- Modify: `clusters/aws-0-agent-platform/{kustomization.yaml,README.md}`,
  `observability/AGENTS.md` and `scripts/ci/validate-vmrules.sh` (the "skips exactly one group" sentences)

**Interfaces:**
- Consumes: access-log fields from Task 3.4; `gen_ai_client_token_usage_sum{ar_agent}` from SP4 PR 1's
  metrics attribute; Karpenter `karpenter_nodepool_{usage,limit}`.

- [ ] **Step 1: Metric rules**

`observability/base/agent-platform/vmrule.yaml`:

```yaml
---
# Agent platform health (SP1 §8). Lives in the umbrella: on a cluster with the
# platform suspended these would only ever be silent.
apiVersion: operator.victoriametrics.com/v1beta1
kind: VMRule
metadata:
  name: agent-platform
  namespace: observability
spec:
  groups:
    - name: agent-platform
      rules:
        - alert: AgentSandboxPodPending
          expr: max by (pod) (kube_pod_status_phase{namespace="agents", phase="Pending"}) > 0
          for: 15m
          labels:
            severity: warning
          annotations:
            summary: "Agent sandbox pod {{ $labels.pod }} has been Pending for 15 minutes"
            description: "Check the agents-gvisor NodePool (limit, spot capacity) and runsc on the node: kubectl describe pod -n agents {{ $labels.pod }}"
        - alert: AgentGvisorPoolNearLimit
          expr: sum by (resource_type) (karpenter_nodepool_usage{nodepool="agents-gvisor"}) / sum by (resource_type) (karpenter_nodepool_limit{nodepool="agents-gvisor"}) * 100 > 90
          for: 10m
          labels:
            severity: warning
          annotations:
            summary: "agents-gvisor is above 90 % of its {{ $labels.resource_type }} limit"
            description: "New runs will stay Pending. Raise the NodePool limit or wait for runs to finish."
```

`observability/base/agent-platform/vmrule-logs.yaml`:

```yaml
---
# LogsQL rules: promtool cannot parse them, so validate-vmrules.sh skips this
# group by its `type` and says so on every run.
apiVersion: operator.victoriametrics.com/v1beta1
kind: VMRule
metadata:
  name: agent-platform-logs
  namespace: observability
  labels:
    vmlog: "true"
spec:
  groups:
    - name: agent-platform-logs
      type: vlogs
      interval: 5m
      rules:
        - alert: AgentRouterUnauthorizedBurst
          expr: 'kubernetes.pod_labels.gateway.envoyproxy.io/owning-gateway-name:"agent-router" | unpack_json | log.response_code:401 | stats count() as unauthorized | filter unauthorized:>20'
          labels:
            severity: warning
          annotations:
            summary: "agent-router rejected {{ $value }} requests in 5 minutes"
            description: "Replayed or foreign tokens (T8), or identity-proxy rotation broken (R2)."
        - alert: OctoStsExchangeFailures
          expr: 'kubernetes.pod_labels.app.kubernetes.io/name:"octo-sts" AND _msg:~"(?i)(error|denied|failed)" | stats count() as failures | filter failures:>5'
          labels:
            severity: warning
          annotations:
            summary: "octo-sts logged {{ $value }} failed exchanges in 5 minutes"
            description: "A run is asking for a repository or role its trust policy does not grant, or the App key is wrong."
```

- [ ] **Step 2: Dashboard**

`observability/base/agent-platform/grafana-folder.yaml`:

```yaml
apiVersion: grafana.integreatly.org/v1beta1
kind: GrafanaFolder
metadata:
  name: agents
  namespace: observability
spec:
  allowCrossNamespaceImport: true
  instanceSelector:
    matchLabels:
      dashboards: "grafana"
```

`observability/base/agent-platform/grafana-dashboard.yaml` (`$${…}` survives Flux substitution):

```yaml
apiVersion: grafana.integreatly.org/v1beta1
kind: GrafanaDashboard
metadata:
  name: agent-platform
  namespace: observability
spec:
  allowCrossNamespaceImport: true
  folderRef: "agents"
  instanceSelector:
    matchLabels:
      dashboards: "grafana"
  json: |
    {
      "title": "Agent platform",
      "uid": "agent-platform",
      "schemaVersion": 39,
      "time": {"from": "now-24h", "to": "now"},
      "templating": {"list": [
        {"name": "datasource", "type": "datasource", "query": "prometheus"},
        {"name": "logs_datasource", "type": "datasource", "query": "victoriametrics-logs-datasource"}
      ]},
      "panels": [
        {"id": 1, "type": "timeseries", "title": "Sandbox pods by phase",
         "gridPos": {"x": 0, "y": 0, "w": 12, "h": 8},
         "datasource": {"type": "prometheus", "uid": "$${datasource}"},
         "targets": [{"refId": "A", "expr": "sum by (phase) (kube_pod_status_phase{namespace=\"agents\"})", "legendFormat": "{{phase}}"}]},
        {"id": 2, "type": "timeseries", "title": "Tokens per run through agent-router",
         "gridPos": {"x": 12, "y": 0, "w": 12, "h": 8},
         "datasource": {"type": "prometheus", "uid": "$${datasource}"},
         "targets": [{"refId": "A", "expr": "sum by (ar_agent) (rate(gen_ai_client_token_usage_sum{ar_agent=~\"system:serviceaccount:agents:.*\"}[5m]))", "legendFormat": "{{ar_agent}}"}]},
        {"id": 3, "type": "timeseries", "title": "agents-gvisor usage / limit",
         "gridPos": {"x": 0, "y": 8, "w": 12, "h": 8},
         "fieldConfig": {"defaults": {"unit": "percentunit"}, "overrides": []},
         "datasource": {"type": "prometheus", "uid": "$${datasource}"},
         "targets": [{"refId": "A", "expr": "sum by (resource_type) (karpenter_nodepool_usage{nodepool=\"agents-gvisor\"}) / sum by (resource_type) (karpenter_nodepool_limit{nodepool=\"agents-gvisor\"})", "legendFormat": "{{resource_type}}"}]},
        {"id": 4, "type": "logs", "title": "agent-router 4xx",
         "gridPos": {"x": 12, "y": 8, "w": 12, "h": 8},
         "datasource": {"type": "victoriametrics-logs-datasource", "uid": "$${logs_datasource}"},
         "targets": [{"refId": "A", "expr": "kubernetes.pod_labels.gateway.envoyproxy.io/owning-gateway-name:\"agent-router\" | unpack_json | log.response_code:4*", "queryType": "instant"}]}
      ]
    }
```

`observability/base/agent-platform/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - vmrule.yaml
  - vmrule-logs.yaml
  - grafana-folder.yaml
  - grafana-dashboard.yaml
```

`clusters/aws-0-agent-platform/observability-agent-platform.yaml`:

```yaml
---
# Alerts and the dashboard for the agent platform, gated with it.
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: agent-observability
  namespace: flux-system
spec:
  prune: true
  interval: 10m0s
  timeout: 2m0s
  path: ./observability/base/agent-platform
  sourceRef:
    kind: ExternalArtifact
    name: observability-artifact
  dependsOn:
    - name: observability
```

Add `- observability-agent-platform.yaml` to the children and the README row
`` | `agent-observability` | `observability/base/agent-platform` | VMRules and the Grafana dashboard | ``.

- [ ] **Step 3: Keep the skip documentation true**

In `observability/AGENTS.md` ("Alerting rules") and in the header of
`scripts/ci/validate-vmrules.sh`, the sentence saying the script skips exactly one group (`loggen`)
becomes: it skips two `type: vlogs` groups, `loggen` in `base/loggen/demo-vmrule.yaml` and
`agent-platform-logs` in `base/agent-platform/vmrule-logs.yaml`, and they must not be made to pass.

Run: `./scripts/ci/validate-vmrules.sh`
Expected: exit 0; `agent-platform` checked (2 rules); `skip … agent-platform-logs 2 (type vlogs)`
printed next to `loggen`.

- [ ] **Step 4: Commit**

```bash
git add observability/base/agent-platform clusters/aws-0-agent-platform observability/AGENTS.md scripts/ci/validate-vmrules.sh
git commit -m "feat(observability): agent platform alerts and dashboard"
```

### Task 6.5: Validate and open PR 6

- [ ] **Step 1: Gates (SC-16, this repo's half)**

Run: `./scripts/ci/validate-manifests.sh`
Expected: exit 0, `Invalid: 0, Skipped: 0`.

Run: `task check && ./scripts/ci/validate-links.sh && ./scripts/ci/validate-doc-claims.sh`
Expected: exit 0 each.

- [ ] **Step 2: Ship**

`ship-it`. PR body: phase 6 of 6; composition `v0.8.1`; `task agent:run`; alerts; SC evidence from
Tasks 6.6–6.8 pasted in.

### Task 6.6: [LIVE] Branch cluster with everything on

**Files:** none.

- [ ] **Step 1: Deploy and check the whole tree**

```bash
cd opentofu && TF_VAR_flux_git_ref=refs/heads/feat/agent-e2e terramate script run deploy
flux resume kustomization ai-gateway -n flux-system
flux resume kustomization agent-platform -n flux-system
flux get kustomizations -n flux-system | grep -E 'agent-|octo-sts|runtimeclass-gvisor|agents-nodepool'
kubectl get composition xagentruns.cloud.ogenki.io -o yaml | grep -c 'ghcr.io/smana/agent-harness:v0.1.0@sha256'
```
Expected: every listed Kustomization `Ready=True`; `1` (the embedded KCL names the harness once).

### Task 6.7: [LIVE] SC-04, SC-06, SC-09

**Files:** none.

- [ ] **Step 1: [OWNER] A trivial issue**

The owner points at, or opens, a trivial `cloud-native-ref` issue (for example one broken relative
link) and gives its URL. Export it as `ISSUE_URL`.

- [ ] **Step 2: SC-04 — an implementer run ends in a PR within 30 minutes**

```bash
RUN=$(task agent:run -- --role implementer --class public --task-url "$ISSUE_URL" | tail -1); echo "$RUN"
date -u +%FT%TZ
kubectl wait -n agents agentrun/$RUN --for=jsonpath='{.status.phase}'=Succeeded --timeout=30m
kubectl get agentrun -n agents $RUN -o jsonpath='{.status.startedAt} {.status.finishedAt} {.status.branch}{"\n"}'
BRANCH=$(kubectl get agentrun -n agents $RUN -o jsonpath='{.status.branch}')
gh pr list --repo Smana/cloud-native-ref --head "$BRANCH" --json number,author,headRefName
gh pr view --repo Smana/cloud-native-ref "$(gh pr list --repo Smana/cloud-native-ref --head "$BRANCH" --json number --jq '.[0].number')" --json commits --jq '.commits[].messageBody' | grep -c "Agent-Run: ${RUN#xplane-run-}"
```
Expected: `Succeeded` within 30 minutes of the printed start; one PR from `agent/<runId>` whose
author login is `app/ogenki-agents`; at least one commit carrying `Agent-Run: <runId>`. If it
fails, read `kubectl logs -n agents $RUN -c harness` and the agent-router access log for the run's
`x_ar_agent` before changing anything.

- [ ] **Step 3: SC-06 and SC-09 on a long, read-only run**

```bash
LONG=$(task agent:run -- --role implementer --class public --minutes 60 \
  --task "Read every Markdown file under docs/superpowers/specs one at a time. For each, list the relative links it contains. Do not change, commit or push anything. Finish with the full list." | tail -1)
kubectl wait -n agents agentrun/$LONG --for=jsonpath='{.status.phase}'=Running --timeout=15m
# SC-09 on the composed CNP, while it runs:
kubectl exec -n agents $LONG -c harness -- git ls-remote https://github.com/Smana/cloud-native-ref HEAD
kubectl exec -n agents $LONG -c harness -- /usr/local/bin/python -c "import urllib.request; urllib.request.urlopen('https://example.com', timeout=5)" ; echo "exit=$?"
kubectl exec -n agents $LONG -c harness -- /usr/local/bin/python -c "import socket, secrets; socket.getaddrinfo(secrets.token_hex(6)+'.example.org', 443)" ; echo "exit=$?"
NODE=$(kubectl get pod -n agents $LONG -o jsonpath='{.spec.nodeName}')
AGENT=$(kubectl get pods -n kube-system -l k8s-app=cilium --field-selector spec.nodeName=$NODE -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n kube-system $AGENT -- hubble observe --from-pod agents/$LONG --type l7 --protocol dns --last 20
```
Expected: a SHA; `exit=1`; `exit=1`; DNS refusals for the `example.*` names (SC-09).

At minute 45 or later (or at the run's end if it finishes sooner — record its duration then):

```bash
curl -s https://vl.priv.aws.ogenki.io/select/logsql/query --data-urlencode \
  "query=kubernetes.pod_labels.gateway.envoyproxy.io/owning-gateway-name:\"agent-router\" _time:1h | unpack_json | log.x_ar_agent:\"system:serviceaccount:agents:$LONG\" | stats by (log.response_code) count() n"
```
Expected: no `401` bucket for the run (SC-06). Its tokens live until its 60-minute deadline (R2), so
none has to rotate: the spike showed a rotated token never reaches the proxy under gVisor. A run
shorter than 45 minutes still counts; record its duration in the PR.

- [ ] **Step 4: Clean up**

`kubectl delete agentrun -n agents $LONG --wait`. Keep `$RUN`'s PR open for the owner's review.

### Task 6.8: [LIVE] SC-07, SC-13, SC-14

**Files:** none.

- [ ] **Step 1: SC-07 — revocation timings**

```bash
REV=$(task agent:run -- --role implementer --class public --minutes 10 --task "Wait: list the files under docs/ slowly, one per minute. Change nothing." | tail -1)
kubectl wait -n agents agentrun/$REV --for=jsonpath='{.status.phase}'=Running --timeout=15m
GHT=$(kubectl exec -n agents $REV -c harness -- /usr/local/bin/git-credential-agent token)
GWT=$(kubectl create token $REV -n agents --audience agent-router.implementer.public --duration 10m); ISSUED=$(date +%s)
kubectl apply -f scripts/ops/k8s/agent-probe.yaml && kubectl wait -n agents sandbox/agent-probe --for=condition=Ready --timeout=10m
T0=$(date +%s); kubectl delete agentrun -n agents $REV --wait=false
until ! kubectl get pod -n agents $REV >/dev/null 2>&1; do sleep 2; done; echo "pod gone after $(( $(date +%s) - T0 )) s"
until [ "$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $GHT" https://api.github.com/installation/repositories)" = 401 ]; do sleep 5; done; echo "GitHub token dead after $(( $(date +%s) - T0 )) s"
until [ "$(kubectl exec -n agents agent-probe -c probe -- curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $GWT" http://agent-router.envoy-gateway-system.svc.cluster.local:8080/v1/models)" = 401 ]; do sleep 15; done; echo "copied gateway token dead $(( $(date +%s) - ISSUED )) s after issue"
unset GHT GWT
```
Expected: pod gone ≤ 60 s; GitHub token 401 ≤ 60 s (the `preStop` revoke); copied gateway token
rejected ≤ 600 s after issue: a 10-minute run's tokens live 600 s, because R2 sets the TTL to the
deadline (a default 120-minute run's copied token would verify for 7200 s).

- [ ] **Step 2: SC-13 — revocation by annotation, and projection**

```bash
B=$(task agent:run -- --role implementer --class public --task "Idle until told otherwise." | tail -1)
kubectl wait -n agents agentrun/$B --for=jsonpath='{.status.phase}'=Running --timeout=15m
kubectl annotate agentrun -n agents $B agents.ogenki.io/usage-tokens=-5
sleep 30; kubectl get agentrun -n agents $B -o jsonpath='{.status.usage}{"\n"}'
kubectl annotate agentrun -n agents $B --overwrite agents.ogenki.io/usage-tokens=1234
sleep 30; kubectl get agentrun -n agents $B -o jsonpath='{.status.usage.tokens}{"\n"}'
T0=$(date +%s); kubectl annotate agentrun -n agents $B agents.ogenki.io/revoked=budget-run
kubectl wait -n agents agentrun/$B --for=jsonpath='{.status.phase}'=BudgetExhausted --timeout=2m
until ! kubectl get pod -n agents $B >/dev/null 2>&1; do sleep 2; done; echo "BudgetExhausted, pod gone after $(( $(date +%s) - T0 )) s"
```
Expected: empty `status.usage` after `-5`; `1234`; `BudgetExhausted` with the pod gone ≤ 60 s.

- [ ] **Step 3: SC-14 — nothing left**

```bash
kubectl delete agentrun -n agents $B --wait
kubectl delete -f scripts/ops/k8s/agent-probe.yaml
for r in $REV $B; do kubectl get sa,cm,cnp,sandbox,pod -A -l agents.ogenki.io/run-id=${r#xplane-run-}; done
```
Expected: `No resources found` for both.

### Task 6.9: SC-15, SC-16, and `/verify-spec`

**Files:**
- Create (after PR 6 merges): `docs/superpowers/specs/2026-09-23-agent-runtime-identity-verification.md`

- [ ] **Step 1: SC-15 and SC-16 into PR 6**

SC-15: quote the ratio from the spike notes (Task 0.6). SC-16: the `validate-manifests.sh` summary of
Task 6.5 and CC-2's `task check` exit code.

- [ ] **Step 2: After merge, verify the design against the live cluster**

On a cluster running `main` with `agent-platform` resumed: `/verify-spec docs/superpowers/specs/2026-09-23-agent-runtime-identity-design.md`.
Expected: the verification file, one row per SC-01…SC-17 with fresh evidence. Open it as a docs PR
from a fresh worktree; it waits for the owner's review.

---

## Out of this plan, owned elsewhere

| Item | Owner |
|---|---|
| `room-bridge` container, `room-broker` audience, the `room_*` MCP rules | SP2 (the composition and MCPRoutes have the extension points) |
| One-creator Kyverno rule, run meter writing `usage-tokens`/`revoked`, factory writing `pull-request` | SP3 |
| `agent-models` tiers, `agent-models-internal`, budgets B1–B2, the `ar_agent` metric attribute | SP4 |
| gcp-0 (GKE Sandbox pool, second issuer) | the design's gcp-0 follow-up |
| Namespace `conditions` on `openbao-platform` (T14) | O1, outside the programme |
