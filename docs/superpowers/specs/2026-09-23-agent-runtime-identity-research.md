# Research: what gives each coding agent a gVisor sandbox, its own identity, gateway-mediated model/MCP access and a repo-scoped GitHub token on EKS?

**Topic**: agent-runtime-identity · **Conducted**: 2026-09-23 (checks re-run 2026-09-24) · **Researcher**: Claude (subagent)

Every fact below was re-read from a primary source during this pass; the raw notes in the session
scratchpad were used only as leads. Anything not confirmed is marked **UNVERIFIED**. Where this
file and the programme's *Verified during design* table overlap, they agree.

## TL;DR

- **Sandbox**: `kubernetes-sigs/agent-sandbox` v1.0.3 ships its Helm chart **in the git repo**
  (`helm/`, chart version `0.1.0`, CRDs in `helm/crds/`), not in a chart registry. The core
  `Sandbox` (`agents.x-k8s.io/v1beta1`) takes a full `PodSpec`, and reports `Ready` and `Finished`
  (`PodSucceeded`/`PodFailed`) conditions, so it can run a one-shot job. It does not isolate
  anything itself: isolation comes from `runtimeClassName`.
- **gVisor on AL2023**: the release tarball now carries `runsc`, `containerd-shim-runsc-v1` **and a
  `gvisor-bin/` directory** that must sit next to `runsc`. AL2023 nodes run containerd 2.2.7 with
  config `version = 3`, which silently ignores the v2 CRI table. **The nodeadm docs' own containerd
  example still uses the v2 table name.** `runsc` does **not** apply OCI seccomp filters unless
  `--oci-seccomp` is set.
- **Identity**: projected SA tokens are audience-bound. The minimum TTL is 600 s, the default is 1 h,
  and a recipient must reject a token whose audience is not its own. Envoy Gateway 1.9.1 validates
  JWTs against a remote JWKS and copies claims into headers. Its authorization matches claims
  **exactly** (no prefix) and addresses nested claims by dot path, which cannot express the
  `kubernetes.io` key.
- **OpenHands**: `ghcr.io/openhands/agent-server:1.49.5-python` exists and runs as UID 10001. The
  LLM `api_key` is a static field read once per conversation, so a rotating token needs something
  outside the harness.
- **octo-sts** v0.10.0 self-hosts from `ghcr.io/octo-sts/app:0.10.0`. It reads the GitHub App key
  from a PEM file (`APP_SECRET_CERTIFICATE_FILE`) or AWS KMS. Trust policies support
  `issuer_pattern`, `subject_pattern`, `audience`/`audience_pattern` and `claim_pattern`, and it
  resolves the installation by account login, so a **user**-owned installation works.
- **Agent Router** v1.1.0 (the repo's pin): `v1beta1` is the storage version for `MCPRoute`,
  `AIGatewayRoute`, `AIServiceBackend` and `BackendSecurityPolicy`. `QuotaPolicy` is
  `v1alpha1`-only. The controller can map request headers onto metric and log attributes
  (`metricsRequestHeaderAttributes`).

## Standard stack

| Component | Pick | Version | Source |
|---|---|---|---|
| Sandbox controller | kubernetes-sigs/agent-sandbox | v1.0.3 (2026-09-17); chart `helm/` in repo; image `registry.k8s.io/agent-sandbox/agent-sandbox-controller` | [releases](https://github.com/kubernetes-sigs/agent-sandbox/releases), [helm/README.md@v1.0.3](https://github.com/kubernetes-sigs/agent-sandbox/blob/v1.0.3/helm/README.md), [sandbox_types.go@v1.0.3](https://github.com/kubernetes-sigs/agent-sandbox/blob/v1.0.3/api/v1beta1/sandbox_types.go) |
| Runtime | gVisor `runsc` | `release-20260921.0` (published 2026-09-23); `gvisor-x86_64.tar.bz2` sha256 `3dd478770dd751d09c257ba14d739b179348a36c5f2d9e954b773f5f90bff646` | [releases](https://github.com/google/gvisor/releases/tag/release-20260921.0), tarball listed locally |
| Sandbox node OS | EKS-optimised AL2023 via Karpenter alias `al2023@v<date>` | containerd 2.2.7, config v3 (observed on AMI `2023.12.20260909`) | [wso2/agent-manager#1891](https://github.com/wso2/agent-manager/issues/1891), [EC2NodeClass schema (Karpenter 1.14.1)](https://github.com/aws/karpenter-provider-aws) |
| Node autoscaler | Karpenter | 1.14.1 (repo pin) | `flux/sources/ocirepo-karpenter.yaml` |
| Identity gateway | Agent Router (ex Envoy AI Gateway) on Envoy Gateway | 1.1.0 / EG 1.9.1 (repo pins) | [agent-router@v1.1.0 api/](https://github.com/theagentrouter/agent-router/tree/v1.1.0/api), `flux/sources/ocirepo-envoy-*.yaml` |
| In-pod credential injection | Envoy `credential_injector`, generic credential | current Envoy (`header_value_prefix` field) | [filter docs](https://www.envoyproxy.io/docs/envoy/latest/configuration/http/http_filters/credential_injector_filter), [generic.proto](https://www.envoyproxy.io/docs/envoy/latest/api-v3/extensions/http/injected_credentials/generic/v3/generic.proto) |
| Harness | OpenHands agent-server (MIT) | SDK v1.49.5; image `ghcr.io/openhands/agent-server:1.49.5-python` (HTTP 200) | [software-agent-sdk](https://github.com/OpenHands/software-agent-sdk), [agent-server docs](https://docs.openhands.dev/sdk/arch/agent-server) |
| GitHub STS | octo-sts (Apache-2.0) | v0.10.0 (2026-09-15); image `ghcr.io/octo-sts/app:0.10.0` (HTTP 200) | [octo-sts/app](https://github.com/octo-sts/app), [envconfig.go](https://github.com/octo-sts/app/blob/main/pkg/envconfig/envconfig.go), [trust_policy.go](https://github.com/octo-sts/app/blob/main/pkg/octosts/trust_policy.go) |
| Flux MCP | flux-operator-mcp chart | 0.60.0 | [chart values](https://github.com/controlplaneio-fluxcd/charts/tree/main/charts/flux-operator-mcp), [mcp-config.md](https://github.com/controlplaneio-fluxcd/flux-operator/blob/main/docs/mcp/mcp-config.md) |
| Metrics MCP | VictoriaMetrics/mcp-victoriametrics (Apache-2.0) | v1.20.2 (image HTTP 200) | [README](https://github.com/VictoriaMetrics/mcp-victoriametrics) |
| Logs MCP | VictoriaMetrics/mcp-victorialogs (Apache-2.0) | v1.9.0 (image HTTP 200) | [README](https://github.com/VictoriaMetrics/mcp-victorialogs) |
| XR status from HTTP | crossplane-contrib/provider-http, namespaced `http.m.crossplane.io/v1alpha2` | v1.0.15 (2026-08-24) | [disposablerequest_types.go@v1.0.15](https://github.com/crossplane-contrib/provider-http/blob/v1.0.15/apis/namespaced/disposablerequest/v1alpha2/disposablerequest_types.go) |
| Admission and GC | Kyverno `ValidatingPolicy`, `DeletingPolicy` (`policies.kyverno.io/v1`) | 1.19.1 (repo pin) | flux-schema catalog (kyverno v1.19.1), [cleanup docs](https://kyverno.io/docs/policy-types/cleanup-policy/) |

## Local patterns worth reusing

| Path | Why |
|---|---|
| `clusters/aws-0/llm-platform.yaml` + `clusters/aws-0-llm-platform/` | The opt-in umbrella shape C1 mandates, including the sibling-directory trick that stops `flux-system` from auto-applying the children |
| `infrastructure/base/karpenter-nodepools/*.yaml` | Pinned AMI alias, Nitro-only requirement (prefix delegation), Cilium `startupTaints`, spot-first |
| `infrastructure/base/envoy-ai-gateway/{envoyproxy,security-policy,clienttrafficpolicy}.yaml` | Pinned data-plane Service name, restricted securityContext on the proxy, header sanitising, buffer limits |
| `infrastructure/base/envoy-gateway/network-policy.yaml` | The data-plane CNP. **It selects every Envoy Gateway proxy pod**, so a second Gateway inherits its allows unless both are scoped by gateway name |
| `crossplane-configuration/apis/inferenceservice/kcl/main.k` | `_observed` via `ocds`, the latch pattern (`_aiGatewayRouteShouldRender`), dxr status patch, `_dnsEgress` with the L7 DNS rule, the one-shot vs long-lived CNP split |
| `observability/base/runlore/` | GLM-5.2 via Z.ai (`provider: openai`, `base_url: https://api.z.ai/api/paas/v4/`), a GitHub App minting 1 h tokens, and a read-only RBAC grant that writes down why it stops where it does |
| `security/base/cert-manager-token-creator/` | Precedent for audience-bound projected tokens against the cluster issuer |
| `scripts/ci/flux-schema/gen-catalog.sh` | Where third-party CRD schemas enter the validation catalog. Needed for `Sandbox` and `DisposableRequest` because `skipMissingSchemas: false` fails on unknown kinds |
| `container-images/` + `build-container-images.yml` | Precedent for repo-built images (`token-exchange-proxy`, `openbao-snapshot`) |
| `opentofu/aws/eks/configure/kubernetes.tf` (`flux_cluster_vars`) | Already exports `oidc_issuer_url`/`oidc_issuer_host`, so the gateway's JWT issuer needs no new variable |

## Don't hand-roll

| Need | Use | Not |
|---|---|---|
| GitHub token per run | octo-sts trust policies | A custom STS, PATs, the ESO GitHub generator |
| JWT validation and claim→header | EG `SecurityPolicy.jwt`, `MCPRoute.securityPolicy.oauth` | Lua or ext_authz code |
| Provider key injection | `BackendSecurityPolicy` `type: APIKey` | Keys in the sandbox |
| Rotating-token injection in the pod | Envoy `credential_injector` + file-backed SDS | Patching the harness to re-read a file |
| Sandbox pod lifecycle | agent-sandbox `Sandbox` | A raw Pod from the composition (no `Finished` condition, no suspend) |
| External observations into XR status | provider-http `DisposableRequest` with `shouldLoopInfinitely`. Programme r3: controllers write annotations and the composition projects them into status instead | A bespoke status controller |
| Claim garbage collection | Kyverno `DeletingPolicy` | A CronJob with `kubectl delete` |
| Cluster read tools | Flux, VictoriaMetrics and VictoriaLogs MCP servers | A bespoke MCP server |

## Common pitfalls

1. **containerd v3 table.** On AL2023 the runsc runtime must be registered under
   `plugins."io.containerd.cri.v1.runtime"`. The v2 name (`io.containerd.grpc.v1.cri`) is accepted
   and ignored, and every gVisor pod then fails with `no runtime for "runsc" is configured` while
   the node reports `Ready` ([#1891](https://github.com/wso2/agent-manager/issues/1891)). The nodeadm
   example for `spec.containerd.config` uses the v2 name
   ([nodeadm examples](https://awslabs.github.io/amazon-eks-ami/nodeadm/doc/examples/)).
2. **`gvisor-bin/` sidecars.** Since `release-20260831`, runsc resolves `gvisor-bin/` relative to its
   own path. `DEFAULT` and `STRICT` sidecar policies do not fall back to embedded copies. A
   two-binary install loses the metric server, checkpoint gofer and sentry prewarmer
   ([#1883](https://github.com/wso2/agent-manager/issues/1883)).
3. **The AWS blueprint's install recipe is stale.** It downloads `release/latest` from
   `storage.googleapis.com` and sets `platform = "ptrace"`. Releases now ship as GitHub tarballs,
   and runsc defaults to `systrap` (`runsc/config/flags.go`).
4. **runsc ignores OCI seccomp by default** (`oci-seccomp=false`, "Enables loading OCI seccomp
   filters inside the sandbox"). PSS `restricted` admission passes on the field alone, so a
   `RuntimeDefault` profile looks enforced when it is not. GKE Sandbox documents the same for
   seccomp and NoNewPrivileges. **Spike (2026-09-26): turning it on is worse.** runsc answers every
   errno rule with EPERM, ignoring `errnoRet` ([#14688](https://github.com/google/gvisor/issues/14688)), so RuntimeDefault's `clone3` → ENOSYS becomes
   EPERM and glibc ≥ 2.34 cannot start a thread. The platform keeps `oci-seccomp` off.
   A reference user-data that avoids pitfalls 1–4. Karpenter merges its own NodeConfig part into
   it. The `runsc.toml` key syntax and `bzip2` on the AMI are still open (Q5, Q6):

   ```yaml
   --//
   Content-Type: text/x-shellscript; charset="us-ascii"

   #!/bin/bash
   set -euo pipefail
   REL=release-20260921.0
   SHA=3dd478770dd751d09c257ba14d739b179348a36c5f2d9e954b773f5f90bff646
   curl -fsSLo /tmp/gvisor.tar.bz2 "https://github.com/google/gvisor/releases/download/${REL}/gvisor-x86_64.tar.bz2"
   echo "${SHA}  /tmp/gvisor.tar.bz2" | sha256sum -c -
   tar -xjf /tmp/gvisor.tar.bz2 -C /usr/local/bin   # runsc, containerd-shim-runsc-v1, gvisor-bin/
   printf '[runsc_config]\n  oci-seccomp = "true"\n' > /etc/containerd/runsc.toml
   --//
   Content-Type: application/node.eks.aws

   apiVersion: node.eks.aws/v1alpha1
   kind: NodeConfig
   spec:
     containerd:
       config: |   # v3 plugin id; the v2 "io.containerd.grpc.v1.cri" is silently ignored
         [plugins."io.containerd.cri.v1.runtime".containerd.runtimes.runsc]
           runtime_type = "io.containerd.runsc.v1"
         [plugins."io.containerd.cri.v1.runtime".containerd.runtimes.runsc.options]
           TypeUrl = "io.containerd.runsc.v1.options"
           ConfigPath = "/etc/containerd/runsc.toml"
   --//
   ```
5. **Karpenter label matching.** A label a pod selects on must also appear in the NodePool
   `requirements`, not only in `template.metadata.labels` (comment in the
   [ai-on-eks manifest](https://github.com/awslabs/ai-on-eks/tree/main/infra/agent-sandbox)).
6. **Static LLM key in OpenHands.** `LLM.api_key` is a `SecretStr` returned verbatim by
   `_get_api_key_value()` (`openhands-sdk/openhands/sdk/llm/llm.py`). A 10-minute projected token
   expires under a long conversation unless something outside the harness rotates it.
7. **Offline validators don't see SA deletion.** Envoy's JWT filter and octo-sts verify the
   signature against JWKS and never call TokenReview. A token from a deleted ServiceAccount stays
   valid there until `exp`.
8. **EG claim matching.** `authorization.rules[].principal.jwt.claims[].values` is exact match, and
   a nested claim is a dot path. Neither `sub` prefixes nor the `kubernetes.io` key can be matched.
   `claimToHeaders` does not support array claims.
9. **The EKS issuer changes on every rebuild.** The URL embeds the cluster ID. Flux substitutes
   `${oidc_issuer_url}` for in-cluster consumers, but an exact `issuer:` in an octo-sts trust
   policy in the target repo goes stale.
10. **octo-sts org allowlist.** With no `.github/chainguard/trusted-token-issuers.yaml` in
    `ORG_POLICY_REPO`, all issuers are permitted and only trust policies gate. Policies are read
    from the **default branch** (`GetContents` with empty options).
    Example trust policy. The issuer is matched by pattern because the EKS issuer ID changes on
    every rebuild (programme OD-5). The audience binds the repository and the role:

    ```yaml
    # Smana/cloud-native-ref: .github/chainguard/agent-implementer.sts.yaml
    issuer_pattern: https://oidc\.eks\.eu-west-3\.amazonaws\.com/id/[0-9A-F]{32}
    subject_pattern: system:serviceaccount:agents:xplane-run-[a-z2-7]{8}
    audience: octo-sts/Smana/cloud-native-ref/implementer
    permissions: {contents: write, pull_requests: write, issues: read, checks: read, actions: read}
    ```
11. **`flux-operator-mcp` chart defaults to `cluster-admin`** (`rbac.create: true`). `--read-only`
    removes the mutating tools, not the RBAC.
12. **The repo's `openbao-platform` ClusterSecretStore has no namespace `conditions`.** An
    ExternalSecret in any namespace can read any `platform/` path.
13. **A GitHub App cannot change `.github/workflows/**` without the `workflows` permission**
    ([choosing permissions](https://docs.github.com/en/apps/creating-github-apps/registering-a-github-app/choosing-permissions-for-a-github-app),
    [community #35410](https://github.com/orgs/community/discussions/35410)).
14. **Kyverno 1.19 deprecates `CleanupPolicy`/`ClusterCleanupPolicy`** ahead of removal in 1.20;
    `DeletingPolicy` replaces them. The docs show no time function in `DeletingPolicy` conditions
    (**UNVERIFIED** whether `time.now()` exists there).
15. **OpenHands' own K8s workspace uses `SandboxWarmPool`** (`AgentSandboxWorkspace`). A pre-warmed
    pod already carries its ServiceAccount, and claim-time identity is only *Planned* on the
    agent-sandbox roadmap.
16. **Vector has no tolerations here.** A tainted sandbox pool gets no log shipping unless its
    taint is tolerated.

## Open questions surfaced

| # | Question | Why it matters | How to settle |
|---|---|---|---|
| Q1 | Does the kubelet start before the user-data script finishes installing runsc? | If it does, the first pods race and hit `RunPodSandbox` errors. The kubelet retries, so this is expected to self-heal | Spike: time from node `Ready` to the first successful gVisor pod |
| Q2 | Does `credential_injector` pick up a rotated token from a file-backed generic SDS secret (`watched_directory`)? | The in-pod identity proxy depends on it | Spike with 600 s tokens and a 30-minute conversation |
| Q3 | Do Cilium `toFQDNs` and the DNS proxy behave for gVisor pods in ENI mode + KPR + `socketLB.hostNamespaceOnly`? | The egress allowlist relies on it. The AWS blueprint proved it only in **chained** mode | Spike: allowed and denied FQDN, Hubble L7 verdicts |
| Q4 | Does the Cilium DNS proxy's refusal of non-allowlisted names break search-path resolution? | A `REFUSED` on `github.com.agents.svc.cluster.local` can stop resolution before the bare name is tried | Set `dnsConfig.options ndots: 1`, then test |
| Q5 | Does `runsc.toml` accept `oci-seccomp = "true"`, and does `RuntimeDefault` break the harness under it? | Seccomp defence in depth inside the sandbox | Spike |
| Q6 | Is `bzip2` (or `zstd`) on the AL2023 EKS AMI? | Needed to unpack the gVisor tarball | Spike, first boot |
| Q7 | Can a GKE ComputeClass create GKE Sandbox pools (`nodePoolConfig.sandbox`)? | The gcp-0 follow-up. The vendored ComputeClass CRD in `scripts/ci/flux-schema/vendored-crds/` has no `sandbox` field | **UNVERIFIED**. The Google page cited in the raw notes does not show it |
| Q8 | Does the Envoy admin `config_dump` redact generic SDS secrets? | The harness shares the pod network namespace with the proxy's admin port | Spike |
| Q9 | What is the file-I/O overhead of `git` and the test toolchain under gVisor on `systrap`? | Anthropic's guide warns that open/close-heavy workloads suffer. Not re-measured here | Spike SC in the design |

## Later evaluation: Agent Substrate and google/ax (2026-09-26)

**Rejected for now, watched.** [google/ax](https://github.com/google/ax) (Apache-2.0, "Google's
open agentic orchestration runtime") is a thin task orchestrator. It runs every task as an actor on
[Agent Substrate](https://github.com/agent-substrate/substrate). Substrate is pre-1.0, and 16 of its
19 maintainers are Google. It multiplexes gVisor actors onto shared worker pods, with suspend and
resume from memory and filesystem snapshots. kagent now builds on it. Everything below was read at
`google/ax@d0bc38b` and `substrate@c7b5469`.

| Finding | Evidence |
|---|---|
| The ax control plane has no authentication and no authorization. Google's OSS VRP triaged it as a **critical** vulnerability | [ax#376](https://github.com/google/ax/issues/376), open, 0 comments |
| Remote code execution through an unvalidated branch (`--upload-pack=…`) during workspace setup | [ax#363](https://github.com/google/ax/issues/363), open |
| Only Gemini is implemented (`unsupported provider %q`). The controller copies `GEMINI_API_KEY` into every task's environment | `internal/model/client.go` L487–495; `internal/controller/reconciler.go` L154 |
| v0.3.0 (2026-09-20) deleted the durable event log and the Python harness the May launch described | commit [`dc4f36c`](https://github.com/google/ax/commit/dc4f36c): 151 files, −19,988 lines |
| Substrate needs `certificates.k8s.io/v1beta1` PodCertificateRequest and ClusterTrustBundle, and says "do not use spot or preemptible nodes" for workers | Substrate `tools/setup-gcp/README.md` |
| Substrate's sandbox egress blocks WebSocket | Substrate `docs/egress-traffic.md` |
| Actors share worker pods, so there is no per-run ServiceAccount, CNP or admission | Inference from the actor/worker model |

**Why it stays out.** ax/Substrate would replace this design wholesale. The blockers are upstream,
not in our code:
- the unauthenticated control plane;
- a key in every sandbox;
- APIs that are GKE-first;
- no spot nodes;
- no per-pod policy for our constitution's rules to attach to.

**What we kept open (programme r5).** Consumers validate issuer-agnostically (C2), and the room
bridge avoids WebSocket (C4). A Substrate backend would then be a new composition behind
`AgentRun`, not a contract change.

**Re-check at SP2 planning or on 2026-12-15, whichever comes first.** Move to a pilot if any of
these hold:
- ax closes #376 and #363 and stops putting provider keys in sandboxes;
- Substrate documents an EKS profile, with v1 ClusterTrustBundle, ECR pulls and a spot story;
- two minor releases ship without an architectural rewrite;
- parking a run with `operatingMode: Suspended` plus a PVC workspace proves too lossy for rooms.

## References

- agent-sandbox: [releases](https://github.com/kubernetes-sigs/agent-sandbox/releases) ·
  [threat model](https://github.com/kubernetes-sigs/agent-sandbox/blob/v1.0.3/docs/security/threat_model.md)
  ("Agent Sandbox itself does not implement isolation"; for bare `Sandbox`, enforce
  `automountServiceAccountToken` with admission control) ·
  [roadmap](https://github.com/kubernetes-sigs/agent-sandbox/blob/main/roadmap.md) (claim-time
  identity and claim-time network policy are *Planned*)
- gVisor: [release-20260921.0](https://github.com/google/gvisor/releases/tag/release-20260921.0) ·
  [flags.go](https://github.com/google/gvisor/blob/master/runsc/config/flags.go) (`systrap`
  default, `oci-seccomp`) · [#1883](https://github.com/wso2/agent-manager/issues/1883) ·
  [#1891](https://github.com/wso2/agent-manager/issues/1891)
- AWS: [ai-on-eks agent-sandbox](https://github.com/awslabs/ai-on-eks/tree/main/infra/agent-sandbox) ·
  [nodeadm API](https://awslabs.github.io/amazon-eks-ami/nodeadm/doc/api/) (`containerd.config`
  is merged into the defaults) ·
  [containers-roadmap#2234](https://github.com/aws/containers-roadmap/issues/2234) (EKS JWKS at
  `<issuer>/keys`) · [bottlerocket#811](https://github.com/bottlerocket-os/bottlerocket/issues/811)
- Kubernetes: [projected volumes](https://kubernetes.io/docs/concepts/storage/projected-volumes/)
  (audience semantics, 600 s minimum, 1 h default) ·
  [ServiceAccountTokenProjection](https://kubernetes.io/docs/reference/kubernetes-api/workload-resources/pod-v1/)
  (rotation at 80 % of TTL)
- Cilium: [kube-proxy-free, socket LB](https://docs.cilium.io/en/stable/network/kubernetes/kubeproxy-free/)
- Envoy Gateway 1.9.1 schemas (flux-schema): `SecurityPolicy.jwt`, `authorization`,
  `ClientTrafficPolicy.headers.earlyRequestHeaders`, `Backend.tls.wellKnownCACertificates`
- Agent Router: [v1.1 notes](https://theagentrouter.ai/release-notes/v1.1/) ·
  [mcp_route.go@v1.1.0](https://github.com/theagentrouter/agent-router/blob/v1.1.0/api/v1beta1/mcp_route.go) ·
  [quota_policy.go@v1.1.0](https://github.com/theagentrouter/agent-router/blob/v1.1.0/api/v1alpha1/quota_policy.go) ·
  [chart values@v1.1.0](https://github.com/theagentrouter/agent-router/blob/v1.1.0/manifests/charts/ai-gateway-helm/values.yaml)
- OpenHands: [agent-server](https://docs.openhands.dev/sdk/arch/agent-server) (`/health`,
  `/ready`, `X-Session-API-Key`) · [request.py](https://github.com/OpenHands/software-agent-sdk/blob/main/openhands-sdk/openhands/sdk/conversation/request.py)
  (`conversation_id`, `initial_message`, `max_iterations`, `agent_launch_additions`) ·
  Dockerfile (`UID=10001`). SP2 owns the event-socket details it consumes
- octo-sts: [README](https://github.com/octo-sts/app) (self-host images, exchange endpoint, org
  allowlist) · [ghinstall.go](https://github.com/octo-sts/app/blob/main/pkg/ghinstall/ghinstall.go)
  (installation matched on `Account.GetLogin()`) ·
  [revoke.go](https://github.com/octo-sts/app/blob/main/pkg/octosts/revoke.go)
  (`DELETE /installation/token`)
- GitHub: [rulesets REST](https://docs.github.com/en/rest/repos/rules) (`~ALL`, `creation`,
  `update`, `deletion`, bypass actor types) · repo settings read 2026-09-24:
  `default_workflow_permissions=read`, no rulesets, PR authors `Smana` and `renovate[bot]`
- Coder: [Coder Agents](https://coder.com/docs/ai-coder/agents) ("The agent loop runs inside the
  control plane"; "LLM provider credentials never enter the workspace")
- GKE: [sandbox pods](https://docs.cloud.google.com/kubernetes-engine/docs/how-to/sandbox-pods)
  (`runtimeClassName: gvisor`, label and taint `sandbox.gke.io/runtime=gvisor`, metadata server
  blocked)
