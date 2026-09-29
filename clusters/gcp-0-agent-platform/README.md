# gcp-0 agent platform (opt-in)

Children of the `agent-platform` umbrella (`../gcp-0/agent-platform.yaml`, suspended by default).
GCP parity with `aws-0-agent-platform/`: the sandbox pool is OpenTofu (`gke/init` `sandbox.tf`,
`agents-gvisor`) and GKE ships the `gvisor` RuntimeClass itself, so there is no node-pool child and
no gVisor RuntimeClass child here (GKE provides it, GP-9).

| Child Kustomization | Path | Holds |
|---|---|---|
| `agent-sandbox` | `infrastructure/base/agent-sandbox` | Sandbox CRD and controller in `agent-system` |
| `agent-runtime` | `infrastructure/base/agent-runtime` | identity-proxy ConfigMap, `agents` default deny |
| `agent-policies` | `security/base/agent-policies` | Kyverno admission and GC for runs |
| `agent-secrets` | `security/gcp-0/agent-secrets` | `SecretStore agents-secrets` -> the `agents` mount |
| `agent-router` | `infrastructure/gcp-0/agent-router` | `agent-router` Gateway, JWT per listener, the agents' Z.ai backend |
| `octo-sts` | `security/gcp-0/octo-sts` | GitHub token exchange for the agents' App, reached only through agent-router's `sts` listener |
| `agent-mcp` | `infrastructure/gcp-0/agent-mcp` | Flux, VictoriaMetrics, VictoriaLogs MCP servers and their MCPRoutes |
| `agent-observability` | `observability/gcp-0/agent-platform` | VMRules, the dashboards (`agent-platform`, `agent-run`, `agent-fleet`) and the agent trace collector |

`AgentGvisorPoolNearLimit` and the dashboard's pool-usage panel read Karpenter metrics, so they stay
silent here. A full `agents-gvisor` pool, or the cluster ceiling in `gke/init/variables.tfvars`,
shows up as `AgentSandboxPodPending`.

## Resume

Not before the owner's UX sign-off (G-5) and never from `main` alone: this umbrella `dependsOn`
`ai-gateway`, itself suspended by default, and both stay suspended on this branch. Only the
integration branch's test-only commit unsuspends it (Phase 7).

Only once the crossplane-configuration pin serves `AgentRun`. Before it, `agent-policies` installs
Kyverno policies against an API that does not exist, and Flux still reports it Ready.

On an **existing** cluster, first apply `opentofu/gcp/openbao/management` then
`opentofu/gcp/gke/configure` — they create the `agents-secrets` policy and JWT role, without which
`SecretStore agents-secrets` never goes Ready. On a feature-branch cluster, `gke/configure` needs
`TF_VAR_flux_git_ref=refs/heads/<branch>`.

The owner prerequisites come next, in this order (ADR-0043): the branch ruleset
(`task ops:github:agent-branch-ruleset -- Smana/cloud-native-ref`), then the GitHub App installed
and its key written to `github-app` on gcp-0's `agents` mount:

    bao kv put -mount=agents github-app app_id=<id> private_key=@<pem file>

Without the key, `octo-sts` sits in `CreateContainerConfigError` and its child fails the health
check. The GCP lineage's raft snapshot cannot be restored across the AWS lineage's KMS seal, so the
other two agent keys are written the same way, once per GCP lineage:

    bao kv put -mount=agents zai api_key=-
    bao kv put -mount=agents factory-app app_id=<App ID> private_key=@<pem file>

`factory-app` has no consumer on gcp-0 until SP2/SP3; write it now so their gates find it.

    flux resume kustomization ai-gateway -n flux-system
    flux resume kustomization agent-platform -n flux-system

`--class internal` runs have no model route until SP4 PR 2, so such a run 404s on every model call;
`agent-run.sh` still accepts it because the runbooks use it to test the internal listener.

## Teardown

Suspending leaves the children in place. To remove them:

    kubectl delete agentruns -n agents --all --wait
    flux suspend kustomization agent-platform -n flux-system
    kubectl kustomize clusters/gcp-0-agent-platform | awk '/^  name:/{print $2}' | xargs flux delete kustomization -n flux-system --silent
