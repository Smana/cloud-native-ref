# gcp-0 agent platform (opt-in)

Children of the `agent-platform` umbrella (`../gcp-0/agent-platform.yaml`, suspended by default).
GCP parity with `aws-0-agent-platform/`: the sandbox pool is OpenTofu (`gke/init` `sandbox.tf`,
`agents-gvisor`) and GKE ships the `gvisor` RuntimeClass itself, so there is no
`agents-nodepool` or `runtimeclass-gvisor` child here (GP-9).

| Child Kustomization | Path | Holds |
|---|---|---|
| `agent-sandbox` | `infrastructure/base/agent-sandbox` | Sandbox CRD and controller in `agent-system` |
| `agent-runtime` | `infrastructure/base/agent-runtime` | identity-proxy ConfigMap, `agents` default deny |
| `agent-policies` | `security/base/agent-policies` | Kyverno admission and GC for runs |
| `agent-secrets` | `security/gcp-0/agent-secrets` | `SecretStore agents-secrets` -> the `agents` mount |
| `agent-router` | `infrastructure/gcp-0/agent-router` | `agent-router` Gateway, JWT per listener, the agents' Z.ai backend |
| `octo-sts` | `security/gcp-0/octo-sts` | GitHub token exchange for the agents' App, reached only through agent-router's `sts` listener |
| `agent-mcp` | `infrastructure/gcp-0/agent-mcp` | Flux, VictoriaMetrics, VictoriaLogs MCP servers and their MCPRoutes |
| `agent-observability` | `observability/gcp-0/agent-platform` | VMRules and the Grafana dashboard |

## Resume

Not before the owner's UX sign-off (G-5) and never from `main` alone: this umbrella `dependsOn`
`ai-gateway`, itself suspended by default, and both stay suspended on this branch. Only the
integration branch's test-only commit unsuspends it (Phase 7).

    flux resume kustomization ai-gateway -n flux-system
    flux resume kustomization agent-platform -n flux-system

## Teardown

Suspending leaves the children in place. To remove them:

    kubectl delete agentruns -n agents --all --wait
    flux suspend kustomization agent-platform -n flux-system
    kubectl kustomize clusters/gcp-0-agent-platform | awk '/^  name:/{print $2}' | xargs flux delete kustomization -n flux-system --silent
