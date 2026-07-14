# Apps user guide

A task-oriented guide for application developers deploying to this platform. You
only need to know basic `kubectl`. No Crossplane knowledge is required.

## Contents

1. [What is an App](#1-what-is-an-app)
2. [Quick start: deploy a web app](#2-quick-start-deploy-a-web-app)
3. [Background workers](#3-background-workers)
4. [Scheduled jobs (cron)](#4-scheduled-jobs-cron)
5. [Configuration and secrets](#5-configuration-and-secrets)
6. [Sidecars and init containers](#6-sidecars-and-init-containers)
7. [Persistent storage](#7-persistent-storage)
8. [Health probes](#8-health-probes)
9. [Databases, cache, and object storage](#9-databases-cache-and-object-storage)
10. [Exposing your app and network security](#10-exposing-your-app-and-network-security)
11. [Autoscaling and availability](#11-autoscaling-and-availability)
12. [Observability](#12-observability)
13. [Field reference](#13-field-reference)
14. [Troubleshooting](#14-troubleshooting)

---

## 1. What is an App

An `App` is a single small YAML document — a *claim* — that describes your
workload at a high level: which container image to run, whether it is a web
service, a background worker, or a scheduled job, and which extras it needs
(a database, a cache, object storage, routing, autoscaling, and so on).

You apply that one claim, and the platform expands it into all the underlying
Kubernetes objects for you — a Deployment (or CronJob), a Service, routes, a
database, network policies, a service account with cloud permissions — with
security hardening baked in (non-root, read-only root filesystem, dropped Linux
capabilities, seccomp). You do not hand-write Deployments, Services, PVCs,
HTTPRoutes, or IAM. You describe intent; the platform renders the details.

```
                       ┌─────────────────────────────┐
                       │   Your App claim (one YAML)  │
                       │                              │
                       │   kind: App                  │
                       │   spec:                      │
                       │     image: ...               │
                       │     type: web                │
                       │     route: {...}             │
                       │     sqlInstance: {...}       │
                       └──────────────┬───────────────┘
                                      │  kubectl apply
                                      ▼
                       ┌─────────────────────────────┐
                       │      Platform expands it     │
                       └──────────────┬───────────────┘
                                      │
        ┌───────────────┬────────────┼────────────┬───────────────┐
        ▼               ▼            ▼             ▼               ▼
  Deployment /      Service      HTTPRoute /   ServiceAccount   SQLInstance /
   CronJob         (web only)     Gateway      (+ Pod Identity)  Valkey / S3
        │                            │
        ▼                            ▼
   HPA, PDB, PVC              CiliumNetworkPolicy,
   (as requested)            VMServiceScrape, VMRule
```

The only required field is `image.repository`. Everything else has a safe
default. The claim is a namespaced resource, so you deploy it into your own
namespace and manage it with normal `kubectl` and GitOps.

### Workload types

An App has one of three shapes, set by `spec.type` (default `web`):

| `type`   | Renders            | Service? | Route? | Probes by default | Autoscaling / PDB |
|----------|--------------------|----------|--------|-------------------|-------------------|
| `web`    | Deployment         | yes      | yes    | HTTP liveness/readiness | yes |
| `worker` | Deployment         | no       | no     | none              | yes |
| `cron`   | CronJob            | no       | no     | none              | no (forbidden) |

Pick `web` for HTTP services, `worker` for queue consumers and background
processors, and `cron` for recurring scheduled tasks.

---

## 2. Quick start: deploy a web app

A web app needs an image and, if you want it reachable from outside the cluster,
a route. Here is a minimal claim that deploys a service and exposes it on a
private hostname:

```yaml
apiVersion: cloud.ogenki.io/v1alpha1
kind: App
metadata:
  name: hello
  namespace: demo
spec:
  image:
    repository: ghcr.io/example/hello
    tag: "v1.0.0"
  service:
    port: 8080
  route:
    enabled: true
    hostname: hello          # becomes hello.priv.cloud.ogenki.io
```

Apply it:

```bash
kubectl apply -f hello.yaml
```

Check its status. The App reports `Ready` once its underlying resources are
actually available (not just created):

```bash
kubectl get app hello -n demo
kubectl describe app hello -n demo
```

`kubectl describe` lists the resources the App created and any events. To see
those objects directly:

```bash
kubectl get deployment,service,httproute -l app.kubernetes.io/name=hello -n demo
```

What got created from that small claim:

- a **Deployment** running your container as non-root with a read-only root
  filesystem, a writable `/tmp`, and HTTP liveness (`/healthz`) and readiness
  (`/readyz`) probes on the service port;
- a **Service** (ClusterIP) exposing port 8080 as a named `http` port;
- a **ServiceAccount** dedicated to this app (used for cloud permissions);
- an **HTTPRoute** wiring `hello.priv.cloud.ogenki.io` through the platform's
  private (Tailscale) gateway.

If you omit `route`, you get the Deployment, Service, and ServiceAccount but no
external exposure — useful for internal-only services reached by their in-cluster
Service DNS name (`hello.demo.svc.cluster.local`).

---

## 3. Background workers

A worker is a Deployment with no Service, no route, and no default HTTP probes —
ideal for queue consumers and event processors whose health is not an HTTP
endpoint. Set `type: worker` and give it a `command`/`args`:

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
  args: ["--queue", "orders", "--concurrency", "4"]
  resources:
    requests:
      cpu: "50m"
      memory: "64Mi"
    limits:
      cpu: "200m"
      memory: "128Mi"
```

Because a worker has no Service, it gets **no liveness/readiness probes by
default** — that is deliberate, so you do not get failing HTTP probes on a
process that serves no HTTP. If your worker can report health another way, add
`healthProbes` explicitly (see [Health probes](#8-health-probes)); for a
background process, an `exec` probe is usually the right choice:

```yaml
  healthProbes:
    liveness:
      type: exec
      command: ["sh", "-c", "test -f /tmp/healthy"]
      periodSeconds: 30
```

Workers still support **autoscaling** (an HPA targeting the Deployment) and a
**PodDisruptionBudget**. See [Autoscaling and availability](#11-autoscaling-and-availability).

---

## 4. Scheduled jobs (cron)

A cron App renders a `batch/v1` CronJob driven by `schedule` (cron format,
required). It reuses the same image, env, secrets, volumes, and security
defaults as the other types:

```yaml
apiVersion: cloud.ogenki.io/v1alpha1
kind: App
metadata:
  name: nightly-cleanup
  namespace: demo
spec:
  type: cron
  schedule: "0 3 * * *"      # every day at 03:00 UTC
  image:
    repository: ghcr.io/example/maintenance
    tag: "v2.0.1"
  command: ["./cleanup"]
  args: ["--older-than", "30d"]
```

### Cron tuning

The optional `spec.cron` block tunes the CronJob and JobSpec. Every value below
is the default — you only set the ones you want to change:

| Field                         | Default     | Meaning |
|-------------------------------|-------------|---------|
| `concurrencyPolicy`           | `Forbid`    | Do not start a new run if the previous one is still running (`Allow`, `Forbid`, `Replace`). |
| `backoffLimit`                | `3`         | Retries before a job is marked failed. |
| `restartPolicy`               | `OnFailure` | Pod restart policy (`OnFailure` or `Never`). |
| `successfulJobsHistoryLimit`  | `3`         | Successful finished jobs to retain. |
| `failedJobsHistoryLimit`      | `3`         | Failed finished jobs to retain. |
| `activeDeadlineSeconds`       | *(unset)*   | Hard cap in seconds; the job is killed if it runs longer. |

```yaml
  cron:
    concurrencyPolicy: Forbid
    backoffLimit: 3
    activeDeadlineSeconds: 3600   # kill the job after 1h
```

### What cron forbids

Because a CronJob is not a long-running server, several web/worker features are
rejected at apply time with a clear message:

| You set…                              | The API server rejects with |
|---------------------------------------|-----------------------------|
| `route.enabled: true`                 | `route is only valid when type is 'web'` |
| `gateway.enabled: true`               | `gateway is only valid when type is 'web'` |
| `autoscaling.enabled: true`           | `autoscaling is not valid when type is 'cron'` |
| `pdb.enabled: true`                   | `pdb is not valid when type is 'cron'` |
| `type: cron` without `schedule`       | `schedule is required when type is 'cron'` |
| `schedule` on a non-cron type         | `schedule is only valid when type is 'cron'` |

---

## 5. Configuration and secrets

You have four mechanisms. Use this decision note to pick:

| Need                                                | Use |
|-----------------------------------------------------|-----|
| A few inline env vars, or values pulled from an existing ConfigMap/Secret key | `env` |
| Import *all* keys of a ConfigMap/Secret as env vars | `envFrom` |
| A config *file* mounted into the container          | `configs` |
| Secret material pulled from AWS Secrets Manager      | `externalSecrets` (then reference via `env`/`envFrom`) |

### `env` — individual variables

Static values or references to a ConfigMap key, a Secret key, or the downward
API:

```yaml
  env:
    - name: LOG_LEVEL
      value: "info"
    - name: DATABASE_HOST
      valueFrom:
        configMapKeyRef:
          name: app-config
          key: db_host
    - name: API_KEY
      valueFrom:
        secretKeyRef:
          name: app-secrets
          key: api_key
    - name: POD_NAME
      valueFrom:
        fieldRef:
          fieldPath: metadata.name
```

The platform also injects `USER`, `POD_NAME`, `POD_NAMESPACE`, and `POD_IP`
automatically, so you do not need to add those yourself.

### `envFrom` — import whole ConfigMaps/Secrets

```yaml
  envFrom:
    - configMapRef:
        name: app-config-all
    - secretRef:
        name: app-secrets-all
    - prefix: "DB_"          # every key becomes DB_<KEY>
      configMapRef:
        name: database-config
        optional: true
```

### `configs` — mounted config files

Each entry becomes a file mounted at `path` with the given `content`:

```yaml
  configs:
    app-config:
      path: /app/config/app.yaml
      content: |
        features:
          debug_mode: false
```

### `secrets` and `externalSecrets` — AWS Secrets Manager

`externalSecrets` creates a Kubernetes Secret synced from AWS Secrets Manager.
All keys under the given path are imported. Reference the resulting Secret from
`env`/`envFrom`:

```yaml
  externalSecrets:
    - name: app-secrets           # the Kubernetes Secret name to create
      remoteRef: apps/myapp/secrets   # path in AWS Secrets Manager
      refreshInterval: 1h
  envFrom:
    - secretRef:
        name: app-secrets
```

`secrets` is an alternative map form that names a Secrets Manager `path` and a
list of `keys` to fetch. In both cases the secret material lives in AWS, never in
Git.

---

## 6. Sidecars and init containers

- **Init containers** run to completion *before* the main container starts. Use
  them for one-off setup: waiting for a dependency, running a migration, warming
  a cache.
- **Sidecars** run *alongside* the main container for the pod's lifetime. Use
  them for auth proxies, log shippers, or metrics adapters.

Both use a reduced container schema (name, image string, command, args, env,
envFrom, resources, volumeMounts, optional securityContext override). **Sidecars
may declare `ports`; init containers may not.** Every extra container inherits
the platform's security defaults (non-root, read-only root filesystem, drop
`ALL` capabilities, seccomp `RuntimeDefault`) unless you override individual
fields.

Two rules the API server enforces:

- the name `main` is **reserved** for the primary container;
- container names must be **unique** within `sidecars` and within
  `initContainers`.

Example — a wait-for-dependency init container and a metrics-adapter sidecar:

```yaml
  initContainers:
    - name: wait-for-db
      image: "busybox:1.36"
      command: ["sh", "-c", "until nc -z myapp-rw 5432; do sleep 2; done"]
      resources:
        requests: { cpu: "10m", memory: "16Mi" }
        limits:   { cpu: "50m", memory: "32Mi" }
  sidecars:
    - name: metrics-adapter
      image: "nginx/nginx-prometheus-exporter:1.1.0"
      args: ["--nginx.scrape-uri=http://localhost:8080/stub_status"]
      ports:
        - name: sidecar-metrics
          containerPort: 9113
      resources:
        requests: { cpu: "10m", memory: "16Mi" }
        limits:   { cpu: "50m", memory: "32Mi" }
```

Note: a sidecar's `ports` are **not** automatically added to the Service. If you
want a sidecar port reachable through the Service, add it under
`service.extraPorts` (see [Exposing your app](#10-exposing-your-app-and-network-security)).

---

## 7. Persistent storage

The `persistence` block gives you a PVC mounted on the main container without
hand-writing volumes. Enable it and set a size and a mount path:

```yaml
  persistence:
    enabled: true
    size: 10Gi
    mountPath: /data
    # storageClass: gp3        # optional; defaults to the cluster default
    # accessModes: [ReadWriteOnce]   # the default
```

This renders a PVC named `<app>-data` mounted at `mountPath`.

**Automatic `Recreate` strategy.** With the default `ReadWriteOnce` (RWO) access
mode, the effective deployment strategy switches to `Recreate` automatically,
because a `RollingUpdate` would briefly run the old and new pods together and an
RWO volume can only attach to one node at a time — the new pod would stall with a
`Multi-Attach error`. `Recreate` stops the old pod before starting the new one.
You can override this by setting `deploymentStrategy: RollingUpdate` explicitly;
an explicit value always wins.

**Autoscaling incompatibility.** RWO persistence and autoscaling cannot be used
together — multiple replicas cannot attach a single-attach volume. The API
server rejects the combination:

```
autoscaling is incompatible with ReadWriteOnce persistence (multi-attach)
```

If you genuinely need multiple pods sharing a volume, use `ReadWriteMany`
(requires a StorageClass that supports it); that combination is allowed
alongside autoscaling.

---

## 8. Health probes

`healthProbes` configures `liveness`, `readiness`, and an optional `startup`
probe. Each probe has a `type`:

| `type` | What it checks | Key fields |
|--------|----------------|------------|
| `http` (default) | HTTP GET returns 2xx/3xx | `path`, `port` |
| `tcp`  | TCP connection opens | `port` |
| `grpc` | gRPC health service responds | `port` |
| `exec` | a command exits 0 | `command` |

Common fields on every probe: `initialDelaySeconds`, `periodSeconds`,
`failureThreshold`.

### Defaults per workload type

- **web**: gets HTTP liveness (`/healthz`) and readiness (`/readyz`) on the
  service port automatically.
- **worker** and **cron**: get **no** probes unless you set `healthProbes`
  explicitly.

### Port fallback

If you do not set an explicit probe `port`, it falls back to `service.port` (or
8080 if that is unset too). So for a web app you usually only override the path,
not the port.

### gRPC service example

```yaml
  service:
    port: 50051
  healthProbes:
    liveness:
      type: grpc
    readiness:
      type: grpc
```

### Startup probe for slow-boot apps

A startup probe holds off liveness and readiness until the app has finished
booting — useful for apps with a long warm-up. Give it a generous
`failureThreshold`:

```yaml
  healthProbes:
    startup:
      type: http
      path: /healthz
      periodSeconds: 5
      failureThreshold: 30      # up to 5s * 30 = 150s to boot
```

---

## 9. Databases, cache, and object storage

The infrastructure blocks are orthogonal to `type` — a web app, worker, or cron
can request any of them.

### `sqlInstance` — PostgreSQL

Provisions a highly-available PostgreSQL cluster (CloudNativePG):

```yaml
  sqlInstance:
    enabled: true
    size: small               # small | medium | large
    storageSize: 20Gi
    instances: 2              # replicas for HA
    databases:
      - name: myapp
        owner: myapp-app
    roles:
      - name: myapp-app
        superuser: false
    backup:
      schedule: "0 2 * * *"   # if set, bucketName is required
      bucketName: myapp-db-backups
      retentionPolicy: "30d"
```

You can also declare **schema migrations** via `atlasSchema` (Git URL, ref, and
path to migration files); Atlas applies them declaratively. A backup `schedule`
requires `backup.bucketName` — the API server enforces this.

### `kvStore` — Valkey / Redis

An in-cluster key-value store for caching, sessions, or queues:

```yaml
  kvStore:
    enabled: true
    type: valkey              # valkey (default) | redis
    size: small               # small | medium | large
```

### `s3Bucket` — object storage with Pod Identity

Creates an S3 bucket and an EKS **Pod Identity** so your pods get scoped AWS
credentials automatically — no static keys:

```yaml
  s3Bucket:
    enabled: true
    region: eu-west-3
    permissions: readwrite    # readwrite | readonly | custom
    versioning: true
    retentionDays: 90
```

With `permissions: custom`, supply your own IAM policy JSON in `customPolicy`.

> **Design note (CL-7):** a `cron` App *can* provision its own database, but a
> cron that owns a database is usually a design smell — the database's lifecycle
> should not be tied to a scheduled job. Prefer pointing the cron at a database
> owned by an existing web/worker App (reference its Service and Secret) rather
> than declaring `sqlInstance` on the cron itself.

---

## 10. Exposing your app and network security

### `route` — HTTPRoute through a platform gateway

Only valid for `type: web`. `hostname` is a prefix; the domain is chosen by
`internetFacing`:

```yaml
  route:
    enabled: true
    hostname: myapp
    internetFacing: false     # false -> myapp.priv.cloud.ogenki.io (private, Tailscale)
                              # true  -> myapp.cloud.ogenki.io (public)
    rules:
      - backendPort: 8080
        pathPrefix: /api
      - backendPort: 8080
        pathPrefix: /
```

`hostname` is required when `route.enabled` is true. Without `rules`, all traffic
is routed to the service port at `/`.

### `gateway` — a dedicated gateway

For advanced cases you can render a dedicated Gateway (with your own listeners)
instead of using a platform gateway. Also web-only:

```yaml
  gateway:
    enabled: true
    gatewayClassName: cilium
    listeners:
      - name: http
        protocol: HTTP
        port: 80
        hostname: myapp.example.com
```

### `service.extraPorts` — additional Service ports

The main Service port comes from `service.port`. To expose more ports (e.g. a
separate metrics port, including one served by a sidecar), add them here:

```yaml
  service:
    port: 8080
    extraPorts:
      - name: metrics
        port: 9113
        targetPort: 9113
```

### `networkPolicies` — Cilium micro-segmentation

Disabled by default. When enabled, it is default-deny: only what you explicitly
allow gets through. Rules live under `ingress` and `egress` (not a `policies`
wrapper). A minimal example allowing ingress from the platform's ingress and DNS
egress:

```yaml
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

Egress supports `toEndpoints`, `toEntities`, `toCIDR`, `toFQDNs`, and `toPorts`;
ingress supports `fromEndpoints`, `fromEntities`, and `toPorts`. See
[`.claude/rules/cilium-network-policies.md`](../.claude/rules/cilium-network-policies.md)
for the common traps (DNS L7 inspection for `toFQDNs`, the EKS Pod Identity agent
needing `toEntities: [host]`, and so on).

---

## 11. Autoscaling and availability

Available for `web` and `worker` (forbidden on `cron`).

- **`autoscaling`** — a CPU-based HorizontalPodAutoscaler:

  ```yaml
    autoscaling:
      enabled: true
      minReplicas: 2
      maxReplicas: 5
      targetCPUUtilizationPercentage: 70
  ```

  When autoscaling is enabled, `replicas` is ignored (the HPA owns replica
  count). `minReplicas` must be `<= maxReplicas`. Remember RWO persistence is
  incompatible with autoscaling.

- **`replicas`** — fixed replica count when autoscaling is off (default 1).

- **`pdb`** — a PodDisruptionBudget to keep a minimum available during voluntary
  disruptions (node drains, upgrades):

  ```yaml
    pdb:
      enabled: true
      minAvailable: 1
      unhealthyPodEvictionPolicy: AlwaysAllow
  ```

- **`spreadAcrossZones`** (default `true`) — spread pods across availability
  zones.
- **`antiAffinityPreset`** (`soft` default, or `hard`) — avoid co-locating pods
  on the same node; `hard` makes it a hard requirement.
- **`onDemand`** (default `false`) — schedule only on on-demand EC2 instances
  (via Karpenter), for workloads that must not run on spot.

---

## 12. Observability

The `observability` block wires OpenTelemetry env vars and creates monitoring
resources:

```yaml
  observability:
    traces:
      enabled: true
      samplingRate: 1.0        # 1.0 = 100% of traces
    metrics:
      enabled: true
      path: /metrics
      interval: 30s
    alertingRules:
      groups:
        - name: myapp
          rules:
            - alert: MyAppDown
              expr: up{job="myapp"} == 0
              for: 5m
```

- **`traces`** injects OTLP trace env vars (endpoint defaults to VictoriaTraces).
- **`metrics`**: for **web** apps this also creates a `VMServiceScrape` so
  VictoriaMetrics scrapes the Service's `http` port at `path`. Workers and cron
  have no Service, so they should *push* metrics via the OTLP metrics endpoint
  instead of being scraped.
- **`alertingRules`** creates a `VMRule` with your alerting/recording rules.

Health checks (probes) are covered in [section 8](#8-health-probes).

---

## 13. Field reference

Complete list of every `spec` field, generated against the App XRD
(`infrastructure/base/crossplane/configuration/app-definition.yaml`). **Required**
fields are marked. "Applies to" notes workload-type scoping where relevant; most
fields apply to all types.

### Top-level

| Field | Type | Default | Applies to | Description |
|-------|------|---------|------------|-------------|
| `image` | object | — (**required**) | all | Container image (see below). |
| `type` | enum `web`\|`worker`\|`cron` | `web` | all | Workload shape. |
| `schedule` | string (cron) | — | cron (**required for cron**) | CronJob schedule; only valid when `type: cron`. |
| `cron` | object | — | cron | CronJob tuning (see below). |
| `command` | []string | — | all | Entrypoint override for the main container. |
| `args` | []string | — | all | Arguments to the main container entrypoint. |
| `imagePullSecrets` | []string | — | all | Names of image pull Secrets in the namespace. |
| `terminationGracePeriodSeconds` | integer (≥0) | — | all | Grace period before force-kill. |
| `autoscaling` | object | — | web, worker | HPA config (see below). Forbidden on cron. |
| `replicas` | integer (≥1) | `1` | web, worker | Replica count when autoscaling is off. |
| `deploymentStrategy` | enum `RollingUpdate`\|`Recreate` | `RollingUpdate` (or `Recreate` if `persistence.enabled`) | web, worker | Update strategy; explicit value always wins. |
| `pdb` | object | — | web, worker | PodDisruptionBudget (see below). Forbidden on cron. |
| `persistence` | object | — | web, worker | PVC-backed storage (see below). |
| `resources` | object | requests 100m/128Mi, limits 200m/256Mi | all | Requests/limits for the main container. |
| `onDemand` | boolean | `false` | all | Schedule only on on-demand instances. |
| `runAsNonRoot` | boolean | `true` | all | Run pod as non-root (UID/fsGroup 1001). |
| `spreadAcrossZones` | boolean | `true` | all | Topology spread across zones. |
| `antiAffinityPreset` | enum `soft`\|`hard` | `soft` | all | Pod anti-affinity strength. |
| `automountServiceAccountToken` | boolean | `false` | all | Auto-mount the SA token. |
| `securityContext` | object | secure defaults | all | Container/pod security overrides (see below). |
| `env` | []object | — | all | Environment variables (value / valueFrom). |
| `envFrom` | []object | — | all | Import env from ConfigMap/Secret, optional prefix. |
| `initContainers` | []object (max 16) | — | all | Init containers, reduced schema (see below). |
| `sidecars` | []object (max 16) | — | all | Sidecar containers, reduced schema (see below). |
| `extraVolumes` | []object | — | all | Passthrough pod volumes (combined with `tmp`). |
| `extraVolumeMounts` | []object | — | all | Passthrough main-container volume mounts. |
| `configs` | map | — | all | Config files to mount (`path`, `content`). |
| `secrets` | map | — | all | Secrets Manager paths (`path`, `keys`). |
| `healthProbes` | object | web: HTTP defaults | all | liveness/readiness/startup (see below). |
| `service` | object | port `8080` | web (Service); port also used as probe fallback | Service config (see below). |
| `gateway` | object | — | web only | Dedicated Gateway (see below). |
| `route` | object | — | web only | HTTPRoute config (see below). |
| `networkPolicies` | object | disabled | all | Cilium policies (see below). |
| `kvStore` | object | disabled | all | Valkey/Redis (see below). |
| `sqlInstance` | object | disabled | all | PostgreSQL (see below). |
| `s3Bucket` | object | disabled | all | S3 + Pod Identity (see below). |
| `externalSecrets` | []object | — | all | AWS Secrets Manager sync (see below). |
| `observability` | object | disabled | all | Traces/metrics/alerting (see below). |

### `image`

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `repository` | string | — (**required**) | Container image repository. |
| `tag` | string | `latest` | Image tag. |
| `pullPolicy` | enum `Always`\|`Never`\|`IfNotPresent` | `IfNotPresent` | Image pull policy. |

### `cron` (type: cron)

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `concurrencyPolicy` | enum `Allow`\|`Forbid`\|`Replace` | `Forbid` | Concurrent execution handling. |
| `backoffLimit` | integer (≥0) | `3` | Retries before a job fails. |
| `activeDeadlineSeconds` | integer (≥1) | — | Hard time cap for the job. |
| `restartPolicy` | enum `OnFailure`\|`Never` | `OnFailure` | Job pod restart policy. |
| `successfulJobsHistoryLimit` | integer | `3` | Successful jobs to retain. |
| `failedJobsHistoryLimit` | integer | `3` | Failed jobs to retain. |

### `autoscaling`

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `enabled` | boolean | `false` | Enable the HPA. |
| `minReplicas` | integer (≥1) | `1` | Minimum replicas (must be ≤ maxReplicas). |
| `maxReplicas` | integer (≥1) | `5` | Maximum replicas. |
| `targetCPUUtilizationPercentage` | integer 1–100 | `70` | Target CPU utilization. |

### `pdb`

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `enabled` | boolean | `false` | Enable the PDB. |
| `minAvailable` | integer (≥1) | `1` | Minimum available pods. |
| `unhealthyPodEvictionPolicy` | enum `IfHealthyBudget`\|`AlwaysAllow` | `AlwaysAllow` | Unhealthy pod eviction policy. |

### `persistence`

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `enabled` | boolean | `false` | Render a PVC. |
| `size` | string (e.g. `10Gi`) | — (required when enabled) | Requested storage size. |
| `mountPath` | string | — (required when enabled) | Mount path on the main container. |
| `storageClass` | string | cluster default | StorageClass name. |
| `accessModes` | []enum `ReadWriteOnce`\|`ReadWriteMany`\|`ReadOnlyMany` | `[ReadWriteOnce]` | PVC access modes. RWO forces `Recreate` and forbids autoscaling. |

### `resources`

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `requests.cpu` | string | `100m` | CPU request. |
| `requests.memory` | string | `128Mi` | Memory request. |
| `limits.cpu` | string | `200m` | CPU limit. |
| `limits.memory` | string | `256Mi` | Memory limit. |

### `securityContext`

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `allowPrivilegeEscalation` | boolean | `false` | Allow privilege escalation. |
| `readOnlyRootFilesystem` | boolean | `true` | Read-only root filesystem. |
| `runAsNonRoot` | boolean | `true` | Require non-root. |
| `capabilities.drop` | []string | `[ALL]` | Capabilities to drop. |
| `enableWritableTmp` | boolean | `true` | Provide a writable `/tmp` emptyDir. |

### `initContainers[]` / `sidecars[]`

Reduced container schema. `ports` is **sidecars only**. Names must be unique;
`main` is reserved.

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `name` | string | yes | Container name (unique; not `main`). |
| `image` | string | yes | Image in plain `repo:tag` form. |
| `command` | []string | no | Entrypoint override. |
| `args` | []string | no | Arguments. |
| `env` | []object | no | Environment variables (same shape as top-level `env`). |
| `envFrom` | []object | no | Import env from ConfigMap/Secret. |
| `resources` | object | no | Requests/limits. |
| `volumeMounts` | []object | no | Passthrough volume mounts. |
| `securityContext` | object | no | Override for `allowPrivilegeEscalation`, `readOnlyRootFilesystem`, `runAsNonRoot`, `capabilities.drop` (defaults inherited). |
| `ports` | []object (`name`, `containerPort`, `protocol`=TCP) | no (**sidecars only**) | Ports exposed by the sidecar (not added to the Service automatically). |

### `healthProbes`

Blocks: `liveness`, `readiness`, `startup`. Each block:

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `type` | enum `http`\|`tcp`\|`grpc`\|`exec` | `http` | Probe type. |
| `path` | string | `/healthz` (liveness), `/readyz` (readiness) | HTTP path (http type). |
| `port` | integer 1–65535 | falls back to `service.port` (else 8080) | Probe port. |
| `command` | []string | — | Command for `exec` type. |
| `initialDelaySeconds` | integer | liveness `30`, readiness `5`, startup `0` | Initial delay. |
| `periodSeconds` | integer | liveness `10`, readiness `5`, startup `10` | Probe period. |
| `failureThreshold` | integer | liveness/readiness `3`, startup `30` | Failures before failed. |

### `service`

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `port` | integer 1–65535 | `8080` | Main container/Service port (named `http`). |
| `extraPorts[]` | []object | — | Extra Service ports: `name`, `port`, `targetPort` (defaults to `port`), `protocol` (`TCP` default). |

### `gateway` (web only)

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `enabled` | boolean | `false` | Create a dedicated Gateway. |
| `gatewayClassName` | string | `cilium` (when rendered) | Gateway class. |
| `name` | string | `<app>-gateway` | Gateway name. |
| `namespace` | string | app namespace | Gateway namespace. |
| `listeners[]` | []object | one HTTP:80 listener | `name`, `port`, `protocol` (`HTTP`\|`HTTPS`), `hostname`. |

### `route` (web only)

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `enabled` | boolean | `false` | Create an HTTPRoute. |
| `internetFacing` | boolean | `false` | `false` → `.priv.cloud.ogenki.io` (private), `true` → `.cloud.ogenki.io` (public). |
| `hostname` | string | — (required when enabled) | Hostname prefix (domain auto-added). |
| `rules[]` | []object | route all to service port at `/` | `backendPort` (**required**), `pathPrefix` (default `/`). |

### `networkPolicies`

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `enabled` | boolean | `false` | Enable Cilium policies (default-deny when on). |
| `ingress[]` | []object | — | `fromEndpoints`, `fromEntities`, `toPorts`. |
| `egress[]` | []object | — | `toEndpoints`, `toEntities`, `toCIDR`, `toFQDNs`, `toPorts`. |

### `kvStore`

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `enabled` | boolean | `false` | Enable the KV store. |
| `size` | enum `small`\|`medium`\|`large` | `small` | Store size. |
| `type` | enum `valkey`\|`redis` | `valkey` | Store type. |

### `sqlInstance`

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `enabled` | boolean | `false` | Enable the PostgreSQL instance. |
| `size` | enum `small`\|`medium`\|`large` | `small` | Instance size. |
| `storageSize` | string (e.g. `20Gi`) | — | Storage size. |
| `instances` | integer | `3` | Number of instances (HA). |
| `primaryUpdateStrategy` | string | `unsupervised` | Primary update strategy. |
| `createSuperuser` | boolean | `false` | Create a superuser. |
| `performanceInsights` | object | disabled | pg_stat_statements / auto_explain tuning. |
| `databases[]` | []object | — | `name` (**required**), `owner` (**required**). |
| `roles[]` | []object | — | `name` (**required**), `superuser` (**required**), `comment`, `inRoles`. |
| `atlasSchema` | object | — | Migration Git `url`, `ref`, `path`. |
| `postgresql` | object | — | `parameters` (map), `pg_hba` ([]string). |
| `backup` | object | — | `schedule`, `retentionPolicy` (default `15d`), `bucketName` (required if schedule set). |

### `s3Bucket`

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `enabled` | boolean | `false` | Enable the bucket. |
| `providerConfigRef` | object | `default` | `name` (**required**), `namespace` (**required**). |
| `region` | string | env region | AWS region. |
| `permissions` | enum `readwrite`\|`readonly`\|`custom` | `readwrite` | Access level. |
| `customPolicy` | string | — | IAM policy JSON (when `custom`). |
| `versioning` | boolean | `false` | Enable versioning. |
| `retentionDays` | integer 1–365 | — | Object retention days. |

### `externalSecrets[]`

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `name` | string | — (**required**) | Kubernetes Secret name to create. |
| `remoteRef` | string | — (**required**) | Path in AWS Secrets Manager. |
| `refreshInterval` | string (e.g. `1h`) | `1h` | Sync interval. |

### `observability`

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `traces.enabled` | boolean | `false` | Enable OTLP tracing. |
| `traces.endpoint` | string | VictoriaTraces | OTLP traces endpoint. |
| `traces.samplingRate` | number 0.0–1.0 | `1.0` | Trace sampling rate. |
| `metrics.enabled` | boolean | `false` | Enable metrics (VMServiceScrape for web). |
| `metrics.endpoint` | string | vmagent | OTLP metrics endpoint. |
| `metrics.path` | string | `/metrics` | Scrape path. |
| `metrics.interval` | string | `30s` | Scrape interval. |
| `alertingRules.groups[]` | []object | — | VMRule groups (`name` (**required**), `interval`, `rules` (**required**)). |

---

## 14. Troubleshooting

### CEL rejection messages

If the API server rejects your claim at apply time, the message names the field.
The common ones:

| Message | Meaning |
|---------|---------|
| `route.hostname is required when route is enabled` | Set `route.hostname`. |
| `schedule is required when type is 'cron'` | Add `spec.schedule`. |
| `schedule is only valid when type is 'cron'` | Remove `schedule`, or set `type: cron`. |
| `route is only valid when type is 'web'` | Routes are web-only; drop the route or change `type`. |
| `gateway is only valid when type is 'web'` | Gateways are web-only. |
| `autoscaling is not valid when type is 'cron'` | Cron cannot autoscale. |
| `pdb is not valid when type is 'cron'` | Cron cannot have a PDB. |
| `autoscaling.minReplicas must be <= maxReplicas` | Fix the min/max ordering. |
| `persistence.size and persistence.mountPath are required when persistence is enabled` | Set both. |
| `autoscaling is incompatible with ReadWriteOnce persistence (multi-attach)` | Use `ReadWriteMany`, or drop autoscaling. |
| `container name 'main' is reserved for the primary container` | Rename the sidecar/init container. |
| `sidecars names must be unique` / `initContainers names must be unique` | Give each a distinct name. |
| `sqlInstance.backup.bucketName is required when backup schedule is set` | Add `backup.bucketName`. |

### App stuck not-ready

The App reports `Ready` only when its underlying resources are truly available.
Work down the chain:

```bash
# 1. What does the App itself say?
kubectl describe app <name> -n <ns>

# 2. Is the Deployment/CronJob available? Any events?
kubectl get deployment,cronjob -l app.kubernetes.io/name=<name> -n <ns>
kubectl describe deployment <name> -n <ns>

# 3. Are the pods scheduling and passing probes?
kubectl get pods -l app.kubernetes.io/name=<name> -n <ns>
kubectl describe pod <pod> -n <ns>
kubectl logs <pod> -n <ns>            # add -c <container> for a specific sidecar/init
```

### Image pull errors

Pod events show `ImagePullBackOff` / `ErrImagePull`. Check:

- `image.repository` and `image.tag` are correct;
- for a private registry, `imagePullSecrets` names a docker-registry Secret that
  exists **in the same namespace**;
- `image.pullPolicy` — use `Always` for mutable tags like `:latest`,
  `IfNotPresent` for pinned versions.

### Probe failures (CrashLoopBackOff / not becoming ready)

- `readOnlyRootFilesystem` is on by default — if your app must write outside
  `/tmp`, add a volume via `persistence` or `extraVolumes`, or you will see
  permission errors on boot.
- The default probe port is `service.port`. If your app listens elsewhere, set
  the probe `port` or the correct `service.port`.
- The default HTTP paths are `/healthz` (liveness) and `/readyz` (readiness). If
  your app uses different paths, override `healthProbes.liveness.path` /
  `readiness.path`, or switch the probe `type` to `tcp`/`grpc`/`exec`.
- Slow-boot apps: add a `startup` probe rather than inflating
  `initialDelaySeconds`.

### Config, secrets, and infrastructure

```bash
# ExternalSecrets syncing from AWS?
kubectl get externalsecret -n <ns>
kubectl describe externalsecret <name> -n <ns>

# Routing accepted by the gateway?
kubectl get httproute,gateway -n <ns>

# Network policy in place (check first on any timeout)?
kubectl get ciliumnetworkpolicy -n <ns>

# Infrastructure components
kubectl get sqlinstance,helmrelease -n <ns>       # PostgreSQL, Valkey/Redis
```

On connection timeouts, always check the CiliumNetworkPolicy first — a
default-deny policy with a missing egress rule is the most common cause. See
[`.claude/rules/cilium-network-policies.md`](../.claude/rules/cilium-network-policies.md).

---

*Maintainers: module internals, testing, and validation live in
[`infrastructure/base/crossplane/configuration/kcl/app/README.md`](../infrastructure/base/crossplane/configuration/kcl/app/README.md).*
