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
| `agent-secrets` | `security/base/agent-secrets` | `SecretStore agents-secrets` → the `agents` mount |
| `agent-router` | `infrastructure/base/agent-router` | `agent-router` Gateway, JWT per listener, the agents' Z.ai backend |
| `octo-sts` | `security/base/octo-sts` | GitHub token exchange for the agents' App, reached only through agent-router's `sts` listener |
| `agent-mcp` | `infrastructure/base/agent-mcp` | Flux, VictoriaMetrics, VictoriaLogs MCP servers and their MCPRoutes |
| `room-broker` | `infrastructure/aws-0/room-broker` | Room CRD, broker, room log (CNPG), retention, and from phase 2 oauth2-proxy (SP2) |
| `agent-observability` | `observability/aws-0/agent-platform` | VMRules, the dashboards (`agent-platform`, `agent-run`, `agent-fleet`) and the agent trace collector |

## Resume

Only once the crossplane-configuration pin serves `AgentRun`. Before it, `agent-policies` installs
Kyverno policies against an API that does not exist, and Flux still reports it Ready.

On an **existing** cluster, first apply `opentofu/aws/openbao/management` then
`opentofu/aws/eks/configure` — they create the `agents-secrets` policy and JWT role, without which
`SecretStore agents-secrets` never goes Ready. On a feature-branch cluster, `eks/configure` needs
`TF_VAR_flux_git_ref=refs/heads/<branch>`.

The owner prerequisites come next, in this order (ADR-0043): the branch and tag rulesets
(`task ops:github:agent-branch-ruleset -- Smana/cloud-native-ref`), then the App installed and its
key written to `github-app` on the `agents` mount. Without the key, `octo-sts` sits in
`CreateContainerConfigError` and its child fails the health check.

From SP2 phase 3, the factory App `ogenki-agent-factory` (SP3's, created early) is installed on
`Smana/cloud-native-ref` with its key at `factory-app` on the `agents` mount. Without it, the room broker
still runs, and reviewers' verdicts stay in the room instead of reaching the pull request.

    flux resume kustomization ai-gateway -n flux-system
    flux resume kustomization agent-platform -n flux-system

`--class internal` runs have no model route until SP4 PR 2, so such a run 404s on every model call;
`agent-run.sh` still accepts it because the runbooks use it to test the internal listener.

## Teardown

Suspending leaves the children in place. To remove them:

    kubectl delete agentruns -n agents --all --wait
    flux suspend kustomization agent-platform -n flux-system
    kubectl kustomize clusters/aws-0-agent-platform | awk '/^  name:/{print $2}' | xargs flux delete kustomization -n flux-system --silent
