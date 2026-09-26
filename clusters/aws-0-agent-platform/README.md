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
| `agent-secrets` | `security/base/agent-secrets` | `SecretStore agents-secrets` → `platform/agents/*` |
| `agent-router` | `infrastructure/base/agent-router` | `agent-router` Gateway, JWT per listener, the agents' Z.ai backend |

## Resume

    flux resume kustomization ai-gateway -n flux-system
    flux resume kustomization agent-platform -n flux-system

## Teardown

Suspending leaves the children in place. To remove them:

    kubectl delete agentruns -n agents --all --wait
    flux suspend kustomization agent-platform -n flux-system
    kubectl kustomize clusters/aws-0-agent-platform | awk '/^  name:/{print $2}' | xargs flux delete kustomization -n flux-system --silent
