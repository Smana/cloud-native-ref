# AI gateway — always-on Flux umbrella

Aggregated by `../aws-0/ai-gateway.yaml`, which is **never suspended** (programme OD-3). CPU only. It
is what lets agents run on frontier models with no GPU node.

| Child Kustomization | Path | Holds |
|---|---|---|
| `envoy-gateway` | `infrastructure/aws-0/envoy-gateway` | Envoy Gateway, its global rate limit, and the Valkey KVStore behind it |
| `envoy-ai-gateway` | `infrastructure/base/envoy-ai-gateway` | Agent Router, the human/system Gateway `ai-gateway`, API-key auth, and the Semantic Router `EnvoyPatchPolicy` |
| `vllm-semantic-router` | `infrastructure/base/vllm-semantic-router` | The Semantic Router (`MoM`) |
| `llm-gateway` | `infrastructure/base/llm-gateway` | Frontier routes and backends in namespace llm-gateway, token budgets B3–B5, price rules |

## The ownership invariant

The first three children used to belong to `llm-platform`. Its garbage collection deletes an object
only while that object's `kustomize.toolkit.fluxcd.io/name` label still names `llm-platform`, and
`ai-gateway` rewrites the label when it applies the child. Before ever resuming `llm-platform` on a
cluster that ran it before this umbrella existed, check:

```bash
kubectl get kustomization -n flux-system envoy-gateway envoy-ai-gateway vllm-semantic-router \
  -o jsonpath='{range .items[*]}{.metadata.name}={.metadata.labels.kustomize\.toolkit\.fluxcd\.io/name}{"\n"}{end}'
# every line must end in =ai-gateway
```

## Teardown

Deleting the umbrella orphans its children (`deletionPolicy: Orphan`). To remove the layer itself,
delete the children in reverse dependency order:

```bash
flux delete kustomization llm-gateway vllm-semantic-router envoy-ai-gateway envoy-gateway \
  -n flux-system --silent
```
