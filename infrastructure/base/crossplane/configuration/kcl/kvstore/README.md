# KVStore Composition

Namespaced Valkey cache instances backed by the official
[valkey-helm](https://github.com/valkey-io/valkey-helm) chart (SPEC-012).
Replaces the frozen Bitnami/`bitnamilegacy` delivery path.

Each `KVStore` XR renders exactly two resources:

| Resource | Purpose |
|----------|---------|
| `HelmRelease <name>-valkey` | Official `valkey` chart 0.10.0 (image `docker.io/valkey/valkey`, appVersion 9.1.0) |
| `CiliumNetworkPolicy <name>-valkey` | Default-deny: 6379 from same-namespace pods, 9121 from `observability` (vmagent); egress only in replica mode |

Consumers connect to **`<name>-valkey:6379`** (namespace-local). With
`replicas > 0` a `<name>-valkey-read` Service load-balances reads and
`<name>-valkey-metrics:9121` exposes the Prometheus exporter.

## API

```yaml
apiVersion: cloud.ogenki.io/v1alpha1
kind: KVStore
metadata:
  name: xplane-mycache
  namespace: apps
spec:
  size: small            # nano|small|medium|large (default small)
  replicas: 0            # 0 = standalone (default); N = read replicas, NO auto-failover (CL-2)
  auth:                  # optional; omitted = auth disabled
    existingSecret: mycache-valkey-password
    passwordKey: password  # default
  persistence:           # optional; omitted = ephemeral in standalone (CL-4)
    size: 4Gi            # replica mode always persists (defaults 4Gi)
  metrics: true          # default
```

- **Auth** creates the mandatory `default` ACL user (`~* &* +@all`) with its
  password read from `existingSecret` — classic `AUTH <password>` works, so
  Redis-client consumers need no username configuration.
- **Cache semantics**: no Sentinel/failover — a rescheduled primary means a
  cold cache. Durable data belongs in `SQLInstance`, not here.
- **Sizes**: nano 100m/128Mi → large 1000m/1Gi requests (limits ×1.5).

## Examples

- [`examples/kvstore-basic.yaml`](../../examples/kvstore-basic.yaml) — standalone ephemeral cache
- [`examples/kvstore-complete.yaml`](../../examples/kvstore-complete.yaml) — replicas + auth + persistence

## Validation

```bash
kcl fmt . && kcl test . -Y settings-example.yaml   # 15 tests
../../../../../../scripts/validate-kcl-compositions.sh  # full 4-stage gate
```

## Design decisions

See [SPEC-012](../../../../../../docs/specs/012-kvstore-composition-replace-bitnami/spec.md)
and its clarifications log: CL-1 in-cluster (CNPG precedent), CL-2 cache
semantics, CL-3 official chart behind this XRD (operator swap stays possible
without touching consumers), CL-4 ephemeral default, CL-5 App `kvStore.type`
ignored (Valkey-only).
