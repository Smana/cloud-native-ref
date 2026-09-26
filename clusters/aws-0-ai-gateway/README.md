# AI gateway — opt-in Flux umbrella

Aggregated by `../aws-0/ai-gateway.yaml`, which is **suspended by default** (programme OD-3, amended
2026-09-26). CPU only. It is what lets agents run on frontier models with no GPU node.

Resume it before `llm-platform` or `agent-platform`, which both depend on it:

```bash
flux resume kustomization ai-gateway -n flux-system
```

Nothing to seed first. The Z.ai key comes from `platform/runlore/credentials`, which OpenBao restores
from its snapshot lineage on every rebuild, and the rate-limit password is generated in-cluster.

| Child Kustomization | Path | Holds |
|---|---|---|
| `envoy-gateway` | `infrastructure/aws-0/envoy-gateway` | Envoy Gateway, its global rate limit, and the Valkey KVStore behind it |
| `envoy-ai-gateway` | `infrastructure/base/envoy-ai-gateway` | Agent Router, the human/system Gateway `ai-gateway`, API-key auth, and the Semantic Router `EnvoyPatchPolicy` |
| `vllm-semantic-router` | `infrastructure/base/vllm-semantic-router` | The Semantic Router (`MoM`) |
| `llm-gateway` | `infrastructure/base/llm-gateway` | Frontier routes and backends in namespace llm-gateway, token budgets B3–B5, price rules |

## Secrets this layer reads

None of these are in Git, so once the layer is resumed a missing one is silent until the pod that
needs it fails:

| Secret | Store | Read by | Without it |
|---|---|---|---|
| `platform-llm-api-keys` | AWS Secrets Manager, outside OpenTofu | `envoy-ai-gateway-system/ai-gateway-api-keys` ExternalSecret, consumed by the `apiKeyAuth` SecurityPolicy | The Gateway serves errors — no request authenticates |
| `platform/runlore/credentials`, property `GLM_API_KEY` | OpenBao `platform/` kv-v2 mount, restored on every rebuild | `llm-gateway/zai-api-key` ExternalSecret | `tier-frontier` requests to Z.ai fail. SP4 PR 6 moves the key to `platform/llm/zai` when RunLore goes behind this gateway |
| `ai-gateway-ratelimit-valkey`, key `REDIS_PASSWORD` | Generated in-cluster by an ESO `Password` generator (`CreatedOnce`) | The KVStore and the rate-limit Deployment's `REDIS_AUTH` | Nothing to provide: it exists as soon as ESO reconciles |

Check what's missing:

```bash
./scripts/provision/secret-store.sh check --cloud aws                    # platform-llm-api-keys (AWS SM)
./scripts/provision/secret-store.sh check --cloud aws --store openbao    # includes runlore/credentials, the Z.ai key's source
```

### One-time AWS Secrets Manager bootstrap

The AI Gateway's API keys live in AWS SM at `platform-llm-api-keys`,
**deliberately outside of OpenTofu** so they survive cluster teardown +
recreation (rotating keys would invalidate every coding-client config —
that pain is worse than the bootstrap step). Three ExternalSecrets
fan out from this single SM entry:

- `envoy-ai-gateway-system/ai-gateway-api-keys` (gateway-side compare)
- `apps/openwebui-llm-api-key` (OpenWebUI's `OPENAI_API_KEY`)
- `promptfoo/promptfoo-llm-api-key` (nightly eval CronJob)

If `aws secretsmanager describe-secret --secret-id platform-llm-api-keys`
returns `ResourceNotFoundException`, seed it once (idempotent — re-running
fails harmlessly with `ResourceExistsException`):

```bash
OPENWEBUI_KEY="sk-$(openssl rand -hex 24)"
PROMPTFOO_KEY="sk-$(openssl rand -hex 24)"
aws secretsmanager create-secret \
  --region eu-west-3 \
  --name platform-llm-api-keys \
  --description "AI Gateway client API keys (raw, no Bearer prefix). JSON: {openwebui_apikey, promptfoo_apikey}" \
  --secret-string "{\"openwebui_apikey\":\"${OPENWEBUI_KEY}\",\"promptfoo_apikey\":\"${PROMPTFOO_KEY}\"}"
```

To onboard a new client identity, add a property to the JSON
(e.g. `developer_apikey`) and append a matching key to the gateway-side
ESO template at `infrastructure/base/envoy-ai-gateway/api-keys-externalsecret.yaml`.

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

Deleting the umbrella orphans its children (`deletionPolicy: Orphan`). Suspend `ai-gateway` first —
it still reconciles them back otherwise — then delete the children in reverse dependency order:

```bash
flux suspend kustomization ai-gateway -n flux-system
flux delete kustomization llm-gateway vllm-semantic-router envoy-ai-gateway envoy-gateway \
  -n flux-system --silent
```
