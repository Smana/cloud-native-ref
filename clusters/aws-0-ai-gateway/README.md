# AI gateway — always-on Flux umbrella

Aggregated by `../aws-0/ai-gateway.yaml`, which is **never suspended** (programme OD-3). CPU only. It
is what lets agents run on frontier models with no GPU node.

| Child Kustomization | Path | Holds |
|---|---|---|
| `envoy-gateway` | `infrastructure/aws-0/envoy-gateway` | Envoy Gateway, its global rate limit, and the Valkey KVStore behind it |
| `envoy-ai-gateway` | `infrastructure/base/envoy-ai-gateway` | Agent Router, the human/system Gateway `ai-gateway`, API-key auth, and the Semantic Router `EnvoyPatchPolicy` |
| `vllm-semantic-router` | `infrastructure/base/vllm-semantic-router` | The Semantic Router (`MoM`) |
| `llm-gateway` | `infrastructure/base/llm-gateway` | Frontier routes and backends in namespace llm-gateway, token budgets B3–B5, price rules |

## Secrets this layer reads

None of these are in Git, and this layer is always-on, so a missing one is silent until the pod
that needs it fails:

| Secret | Store | Read by | Without it |
|---|---|---|---|
| `platform-llm-api-keys` | AWS Secrets Manager, outside OpenTofu | `envoy-ai-gateway-system/ai-gateway-api-keys` ExternalSecret, consumed by the `apiKeyAuth` SecurityPolicy | The Gateway serves errors — no request authenticates |
| `platform/llm/zai`, property `api_key` | OpenBao `platform/` kv-v2 mount | `llm-gateway/zai-api-key` ExternalSecret | `tier-frontier` requests to Z.ai fail |
| `platform/ai-gateway/ratelimit-valkey`, property `REDIS_PASSWORD` | OpenBao `platform/` kv-v2 mount | `envoy-gateway-system/ai-gateway-ratelimit-valkey` ExternalSecret | The rate-limit pod stays `CreateContainerConfigError`; Valkey never starts |

Check what's missing:

```bash
./scripts/provision/secret-store.sh check --cloud aws                    # platform-llm-api-keys (AWS SM)
./scripts/provision/secret-store.sh check --cloud aws --store openbao    # the two OpenBao-backed secrets
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
