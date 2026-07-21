# App KCL Module

> **Application developers:** for a task-oriented guide to deploying web apps,
> workers, cron jobs, sidecars, databases, and everything else, see
> [`docs/apps-user-guide.md`](../../../../../../docs/apps-user-guide.md). This
> README is maintainer-focused: module internals, testing, and validation.

A KCL composition function module (`function-kcl`) that renders a complete
application deployment from a single `App` claim. It is the platform's
developer-facing abstraction: one small claim expands into a Deployment or
CronJob, a Service, routes, autoscaling, persistence, network policies, and
optional managed infrastructure (PostgreSQL, Valkey, S3), with the
constitution's security defaults baked in.

The authoritative schema — every field, type, enum, default, and CEL rule — is
the XRD at
[`infrastructure/base/crossplane/configuration/app-definition.yaml`](../../app-definition.yaml).
The user guide's field reference is generated from it; keep both in sync when the
schema changes.

## Overview

Depending on `spec.type` and which optional blocks are set, the module renders:

- **Workload** (one of):
  - `web` (default): Deployment + Service (+ optional HTTPRoute/Gateway)
  - `worker`: Deployment only (no Service, route, or default probes)
  - `cron`: CronJob (`batch/v1`) driven by `spec.schedule`
- A dedicated **ServiceAccount** for every type (IAM / EKS Pod Identity).
- **Multi-container pods**: `sidecars[]` (ports allowed) and `initContainers[]`
  (no ports), each inheriting the security defaults unless overridden.
- **Persistence**: a PVC (`<name>-data`) mounted on the main container.
- **HorizontalPodAutoscaler** and **PodDisruptionBudget** (Deployment-backed
  types only).
- **CiliumNetworkPolicy** for micro-segmentation.
- **ExternalSecrets** (AWS Secrets Manager) and mounted config files.
- Managed infrastructure: **KVStore** (Valkey, SPEC-012), **SQLInstance**
  (PostgreSQL), **Bucket** + **EPI** (S3 with Pod Identity).
- Observability: **VMServiceScrape** (web) and **VMRule**.

## Features

- **Workload types** (`web` / `worker` / `cron`) from one `App` kind.
- **Container ergonomics**: top-level `command`/`args`, `sidecars[]`,
  `initContainers[]`, `imagePullSecrets`, `terminationGracePeriodSeconds`.
- **Flexible probes**: `http` / `tcp` / `grpc` / `exec` liveness, readiness, and
  an optional startup probe; port defaults to `service.port`.
- **Persistence**: `persistence` renders a PVC and flips the deployment strategy
  to `Recreate` (RWO multi-attach guard) unless overridden.
- **Multi-port Services**: `service.extraPorts[]`.
- **Auto-scaling**: CPU-based HorizontalPodAutoscaler.
- **High availability**: Pod Disruption Budgets, anti-affinity, zone spreading.
- **Gateway API**: HTTPRoute and optional dedicated Gateway (web only).
- **Config & secrets**: mounted config files and External Secrets.
- **Infrastructure integration**: Valkey, PostgreSQL, S3.
- **Security by default**: non-root, read-only rootfs, dropped capabilities,
  seccomp, EKS Pod Identity.
- **Observability**: OTLP env wiring, VMServiceScrape, VMRule.

## Module internals

Key behaviors implemented in [`main.k`](main.k):

- **Workload fork** — `_type` selects the rendered shape. `_isDeploymentType`
  (web + worker) shares the pod-builder and the `Available`-condition readiness
  check; `_isCron` renders a CronJob that is statically ready when created.
- **Shared pod-builder** — `_podSpec` is built once and reused by the Deployment
  and CronJob (`_cronPodSpec = _podSpec | {restartPolicy = ...}`), so security
  context, volumes, env, sidecars, and init containers are identical across
  types.
- **Effective deployment strategy** (FR-007) — computed in KCL, not the XRD:
  `Recreate` when `persistence.enabled`, else `RollingUpdate`; an explicit
  `spec.deploymentStrategy` always wins.
- **Probe builder** — `_buildProbe` emits `httpGet` / `tcpSocket` / `grpc` /
  `exec` from `type`. Port resolution: explicit probe port → named `http`
  container port (for http, preserving legacy web output) → numeric
  `service.port` → `8080`. Web gets default probes when a service port exists;
  worker/cron only when `healthProbes` is set (FR-002).
- **Extra containers** — `_buildExtraContainer` merges per-field security
  overrides onto the constitution defaults using key-presence (`in`) checks, so
  a partial override never silently drops un-overridden fields.
- **`main.k` never mutates a dict after creation** (function-kcl
  [#285](https://github.com/crossplane-contrib/function-kcl/issues/285)):
  conditional resources are built via intermediate list variables and
  `_items += ...`, and composite lists (volumes, ports, env) are assembled in a
  single expression.

## Security defaults

Enforced by the module (constitution-compliant); overridable via
`spec.securityContext` and per-container `securityContext`:

- Read-only root filesystem, non-root user (UID/fsGroup 1001), no privilege
  escalation, all Linux capabilities dropped, seccomp `RuntimeDefault`.
- ServiceAccount token not auto-mounted unless `automountServiceAccountToken:
  true`.
- Writable `/tmp` via an emptyDir (`enableWritableTmp`, default true).
- Sidecars and init containers inherit the same defaults.

## Created resources

Keyed by their `krm.kcl.dev/composition-resource-name` annotation
(`<name>-<suffix>`):

| Resource | Suffix | When |
|----------|--------|------|
| Deployment | `-deployment` | `type: web` or `worker` |
| CronJob | `-cronjob` | `type: cron` |
| Service | `-service` | `type: web` |
| ServiceAccount | `-serviceaccount` | always |
| PersistentVolumeClaim | `-pvc` (name `<name>-data`) | `persistence.enabled` |
| HorizontalPodAutoscaler | `-hpa` | `autoscaling.enabled` and Deployment-backed |
| PodDisruptionBudget | `-pdb` | `pdb.enabled` and Deployment-backed |
| Gateway | `-gateway` | `gateway.enabled` and `type: web` |
| HTTPRoute | `-httproute` | `route.enabled` and `type: web` |
| CiliumNetworkPolicy | `-cilium-netpol` | `networkPolicies.enabled` |
| KVStore XR (Valkey) | `-kvstore` | `kvStore.enabled` |
| SQLInstance | `-sqlinstance` | `sqlInstance.enabled` |
| Bucket (+ BucketVersioning) + EPI | `-s3-bucket`, `-s3-pod-identity` | `s3Bucket.enabled` |
| ExternalSecret | `-externalsecret-<name>` | per `externalSecrets[]` entry |
| VMServiceScrape | `-vmservicescrape` | `observability.metrics.enabled` and `type: web` |
| VMRule | `-vmrule` | `observability.alertingRules.groups` set |

### Readiness (`option("params").ocds`)

The module sets `krm.kcl.dev/ready = "True"` from observed cluster state:

- **Deployment**: `status.conditions[type=Available, status=True]`.
- **Service**: `spec.clusterIP` assigned.
- **HTTPRoute**: `status.parents[].conditions[type=Accepted, status=True]`.
- **Gateway**: `Programmed` or `Accepted` condition True.
- **HPA / PDB**: controller has reported status.
- **KVStore XR**: `Ready` condition True (function-auto-ready, like SQLInstance).
- **VMServiceScrape / VMRule**: a `*/Applied` condition True.
- **Statically ready when created**: CronJob, PVC, ServiceAccount,
  CiliumNetworkPolicy.

## Examples

The [`examples/`](../../examples/) directory (rendered by `crossplane render` in
CI) contains:

- **app-basic.yaml** — minimal claim (image + service port).
- **app-complete.yaml** — full web app: autoscaling, HA, sidecar + init
  container, persistence, startup probe, extraPorts, network policies,
  PostgreSQL + Atlas, Valkey, S3.
- **app-worker.yaml** — `type: worker` (Deployment only, `command`/`args`).
- **app-cron.yaml** — `type: cron` with a `schedule` and the `cron` tuning block.

### Minimal web app

```yaml
apiVersion: cloud.ogenki.io/v1alpha1
kind: App
metadata:
  name: basic-app
  namespace: demo
spec:
  image:
    repository: ghcr.io/example/basic-app
    tag: "v1.0.0"
  service:
    port: 8080
  route:
    enabled: true
    hostname: basic-app          # -> basic-app.priv.cloud.ogenki.io
```

Note the schema: the exposed port is `service.port`; per-rule ports are
`route.rules[].backendPort`; there is no `route.port`.

### Worker

```yaml
apiVersion: cloud.ogenki.io/v1alpha1
kind: App
metadata:
  name: orders-consumer
  namespace: demo
spec:
  type: worker
  image:
    repository: ghcr.io/example/orders-consumer
    tag: "v1.2.0"
  command: ["./consume"]
  args: ["--queue", "orders"]
```

### Cron

```yaml
apiVersion: cloud.ogenki.io/v1alpha1
kind: App
metadata:
  name: nightly-cleanup
  namespace: demo
spec:
  type: cron
  schedule: "0 3 * * *"
  image:
    repository: ghcr.io/example/maintenance
    tag: "v2.0.1"
  command: ["./cleanup"]
  cron:
    concurrencyPolicy: Forbid
    backoffLimit: 3
```

### Network policies

`networkPolicies` uses top-level `ingress` / `egress` arrays (there is **no**
`networkPolicies.policies` wrapper). Rules pass through to the
CiliumNetworkPolicy spec:

```yaml
spec:
  networkPolicies:
    enabled: true
    ingress:
      - fromEntities: [ingress]
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
```

See [`.claude/rules/cilium-network-policies.md`](../../../../../../.claude/rules/cilium-network-policies.md)
for the common `toFQDNs` / DNS-L7 / host-entity traps.

## Testing and validation

```bash
# Format (CI is strict)
kcl fmt kcl/app/

# Unit tests (resource counts, naming, security context, workload fork)
kcl test kcl/app/ -Y kcl/app/settings-example.yaml

# Full pipeline: format, syntax, render, security (Polaris/kube-linter/Datree)
./scripts/validate-kcl-compositions.sh

# Render a single example against the local module (see the render harness
# used during SPEC-007 for wiring local main.k into the composition)
cd infrastructure/base/crossplane/configuration
crossplane render examples/app-basic.yaml app-composition.yaml functions.yaml \
  --extra-resources examples/environmentconfig.yaml
```

`main_test.k` asserts container counts and naming (main + sidecars, init
containers, `main` reserved), the security context on every container, the
workload fork (Service present only for web; CronJob for cron), and that
`persistence.enabled` flips the strategy to `Recreate`.

## Troubleshooting

CEL rejections are self-describing (they name the offending field) — see the
[user guide troubleshooting section](../../../../../../docs/apps-user-guide.md#14-troubleshooting)
for the full list. Useful cluster commands:

```bash
# App status and the resources it owns
kubectl describe app <name> -n <ns>

# Workload health
kubectl get deployment,cronjob -l app.kubernetes.io/name=<name> -n <ns>
kubectl get pods -l app.kubernetes.io/name=<name> -n <ns>
kubectl logs deployment/<name> -n <ns>        # -c <container> for a sidecar/init

# Routing, secrets, network, infra
kubectl get httproute,gateway -n <ns>
kubectl get externalsecret -n <ns>
kubectl get ciliumnetworkpolicy -n <ns>
kubectl get sqlinstance,kvstore -n <ns>
```

Common issues: image pull errors (check `image.*` and `imagePullSecrets` in the
same namespace); pods not ready (default probe paths are `/healthz` and
`/readyz` on `service.port` — override `healthProbes` if your app differs);
connection timeouts (check the CiliumNetworkPolicy first).

## Version compatibility

- **KCL**: v0.11.3+
- **Crossplane**: v2 (`m.upbound.io` namespaced managed resources)
- **function-kcl**: pulls modules anonymously by OCI tag
- **Gateway API**: v1.0+
- **External Secrets**: v0.9+
- **Cilium**: v1.14+ (for network policies)
