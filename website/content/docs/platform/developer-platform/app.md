---
title: The App claim
weight: 10
description: Workers, cron jobs, config and secrets, sidecars, persistent storage, health probes, routing, autoscaling, and observability on the App claim.
lastVerified: 2026-08-20
---

This page covers everything on an `App` claim past the minimal web service in
[Get Started]({{< relref "/docs/get-started/first-app.md" >}}): the other two
workload shapes, and every capability orthogonal to shape. Databases, cache,
and object storage have their own page — [Data services]({{< relref "/docs/platform/developer-platform/data-services.md" >}}).
For the exhaustive `spec` field list — every field, type, and default — see
[App field reference]({{< relref "/docs/platform/developer-platform/app-field-reference.md" >}}).

## Background workers

A worker is a Deployment with no Service, no route, and no default HTTP
probes — for queue consumers and event processors whose health isn't an HTTP
endpoint. Set `type: worker` and give it a `command`/`args`:

```yaml
spec:
  type: worker
  image:
    repository: ghcr.io/example/orders-consumer
    tag: "v1.2.0"
  command: ["./consume"]
  args: ["--queue", "orders", "--concurrency", "4"]
  resources:
    requests: { cpu: "50m", memory: "64Mi" }
    limits: { cpu: "200m", memory: "128Mi" }
```

A worker gets **no liveness/readiness probes by default** — deliberate, so
it doesn't fail HTTP probes on a process that serves no HTTP. If it can
report health another way, add `healthProbes` explicitly (see
[Health probes](#health-probes)); an `exec` probe is usually the right
choice for a background process. Workers still support **autoscaling** and a
**PodDisruptionBudget** — see [Autoscaling and availability](#autoscaling-and-availability).

## Scheduled jobs (cron)

A cron App renders a `batch/v1` CronJob driven by `schedule` (cron format,
required), reusing the same image, env, secrets, volumes, and security
defaults as the other types:

```yaml
spec:
  type: cron
  schedule: "0 3 * * *"      # every day at 03:00 UTC
  image:
    repository: ghcr.io/example/maintenance
    tag: "v2.0.1"
  command: ["./cleanup"]
  args: ["--older-than", "30d"]
```

The optional `spec.cron` block tunes the CronJob and JobSpec — every value
below is the default:

| Field | Default | Meaning |
|-------|---------|---------|
| `concurrencyPolicy` | `Forbid` | Don't start a new run if the previous is still running (`Allow`\|`Forbid`\|`Replace`). |
| `backoffLimit` | `3` | Retries before a job is marked failed. |
| `restartPolicy` | `OnFailure` | Pod restart policy (`OnFailure`\|`Never`). |
| `successfulJobsHistoryLimit` | `3` | Successful finished jobs to retain. |
| `failedJobsHistoryLimit` | `3` | Failed finished jobs to retain. |
| `activeDeadlineSeconds` | *(unset)* | Hard cap in seconds; the job is killed if it runs longer. |

Because a CronJob isn't a long-running server, the API server rejects
several web/worker fields at apply time with a message naming the field:
`route`/`gateway` ("...only valid when type is 'web'"), `autoscaling`/`pdb`
("...not valid when type is 'cron'"), and `schedule` set without
`type: cron` or vice versa.

{{< callout type="warning" >}}
A `cron` App *can* provision its own database, but a cron that owns a
database is usually a design smell — the database's lifecycle shouldn't be
tied to a scheduled job. Prefer pointing the cron at a database owned by an
existing web/worker App (reference its Service and Secret) rather than
declaring `sqlInstance` on the cron itself.
{{< /callout >}}

## Configuration and secrets

Four mechanisms, picked by what you're setting:

| Need | Use |
|------|-----|
| A few inline env vars, or values from an existing ConfigMap/Secret key | `env` |
| Import *all* keys of a ConfigMap/Secret as env vars | `envFrom` |
| A config *file* mounted into the container | `configs` |
| Secret material from AWS Secrets Manager | `externalSecrets` (then reference via `env`/`envFrom`) |

`env` accepts static values or references to a ConfigMap key, a Secret key,
or the downward API:

```yaml
  env:
    - name: LOG_LEVEL
      value: "info"
    - name: DATABASE_HOST
      valueFrom:
        configMapKeyRef: { name: app-config, key: db_host }
    - name: POD_NAME
      valueFrom:
        fieldRef: { fieldPath: metadata.name }
```

The platform also injects `USER`, `POD_NAME`, `POD_NAMESPACE`, and `POD_IP`
automatically. `envFrom` imports a whole ConfigMap/Secret, optionally with a
`prefix:`; `configs` mounts a file from inline `content` at a given `path`.

`externalSecrets` creates a Kubernetes `Secret` synced from AWS Secrets
Manager — all keys under the given path are imported:

```yaml
  externalSecrets:
    - name: app-secrets           # the Kubernetes Secret name to create
      remoteRef: apps/myapp/secrets   # path in AWS Secrets Manager
      refreshInterval: 1h
  envFrom:
    - secretRef: { name: app-secrets }
```

Secret material lives in AWS, never in Git — the composition renders an
`ExternalSecret` per entry (`apis/app/kcl/main.k:1200` in
[`Smana/crossplane-configuration`](https://github.com/Smana/crossplane-configuration)).

## Sidecars and init containers

- **Init containers** run to completion *before* the main container starts —
  waiting for a dependency, running a migration, warming a cache.
- **Sidecars** run *alongside* the main container for the pod's lifetime —
  auth proxies, log shippers, metrics adapters.

Both use a reduced container schema (name, image, command, args, env,
envFrom, resources, volumeMounts, optional `securityContext` override).
**Sidecars may declare `ports`; init containers may not.** Every extra
container inherits the platform's security defaults (non-root, read-only
root filesystem, drop `ALL` capabilities, seccomp `RuntimeDefault`) unless
overridden. The name `main` is reserved for the primary container, and
container names must be unique within `sidecars` and within
`initContainers`.

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

A sidecar's `ports` are **not** automatically added to the Service — add
them under `service.extraPorts` if you want a sidecar port reachable through
the Service (see [Exposing your app](#exposing-your-app-and-network-security)).

## Persistent storage

The `persistence` block gives you a PVC mounted on the main container
without hand-writing volumes:

```yaml
  persistence:
    enabled: true
    size: 10Gi
    mountPath: /data
    # storageClass: gp3        # optional; defaults to the cluster default
    # accessModes: [ReadWriteOnce]   # the default
```

This renders a PVC named `<app>-data`. With the default `ReadWriteOnce`
(RWO) access mode, the deployment strategy switches to `Recreate`
automatically — a `RollingUpdate` would briefly run old and new pods
together, and an RWO volume can only attach to one node at a time, so the
new pod would stall with `Multi-Attach error`. Set
`deploymentStrategy: RollingUpdate` explicitly to override; an explicit
value always wins.

{{< callout type="warning" >}}
RWO persistence and autoscaling **cannot** be used together — multiple
replicas can't attach a single-attach volume. The API server rejects the
combination with `autoscaling is incompatible with ReadWriteOnce persistence
(multi-attach)`. If you genuinely need multiple pods sharing a volume, use
`ReadWriteMany` (needs a StorageClass that supports it) — that combination
is allowed alongside autoscaling.
{{< /callout >}}

## Health probes

`healthProbes` configures `liveness`, `readiness`, and an optional
`startup` probe, each with a `type`: `http` (default; `path`, `port`),
`tcp` (`port`), `grpc` (`port`), or `exec` (`command`). Common fields on
every probe: `initialDelaySeconds`, `periodSeconds`, `failureThreshold`.

- **web** gets HTTP liveness (`/healthz`) and readiness (`/readyz`) on the
  service port automatically (`apis/app/kcl/main.k:328-343` in
  [`Smana/crossplane-configuration`](https://github.com/Smana/crossplane-configuration)).
- **worker** and **cron** get **no** probes unless `healthProbes` is set
  explicitly.
- If you don't set an explicit probe `port`, it falls back to
  `service.port` (or `8080`) — so a web app usually only needs to override
  the path.

```yaml
  # gRPC service
  service: { port: 50051 }
  healthProbes:
    liveness: { type: grpc }
    readiness: { type: grpc }
```

For slow-boot apps, add a startup probe with a generous
`failureThreshold` rather than inflating `initialDelaySeconds`:

```yaml
  healthProbes:
    startup:
      type: http
      path: /healthz
      periodSeconds: 5
      failureThreshold: 30      # up to 5s * 30 = 150s to boot
```

## Exposing your app and network security

### `route` — HTTPRoute through a platform gateway

Web-only. `hostname` is a prefix; the domain is chosen by
`internetFacing`:

```yaml
  route:
    enabled: true
    hostname: myapp
    internetFacing: false     # false -> myapp.priv.aws.ogenki.io (private, Tailscale)
                               # true  -> myapp.cloud.ogenki.io (public)
    rules:
      - backendPort: 8080
        pathPrefix: /api
      - backendPort: 8080
        pathPrefix: /
```

`hostname` is required when `route.enabled` is true. Without `rules`, all
traffic routes to the service port at `/`. See
[Gateway API]({{< relref "/docs/platform/networking/gateway-api.md" >}}) for
how these routes attach, and
[Private Access]({{< relref "/docs/platform/networking/private-access.md" >}})
for the ACL model behind the private hostname.

### `gateway` — a dedicated gateway

For advanced cases, `gateway.enabled: true` renders a dedicated `Gateway`
(with its own listeners) instead of using a platform gateway — also
web-only (`apis/app/kcl/main.k:836` in
[`Smana/crossplane-configuration`](https://github.com/Smana/crossplane-configuration)):

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

### `service.extraPorts` and `networkPolicies`

The main Service port comes from `service.port`; add more (a metrics port,
a sidecar port) under `service.extraPorts`. `networkPolicies` is disabled
by default; enabled, it is default-deny — only what's listed under
`ingress`/`egress` gets through:

```yaml
  networkPolicies:
    enabled: true
    ingress:
      - fromEntities: [ingress]
        toPorts:
          - ports: [{ port: "8080", protocol: TCP }]
    egress:
      - toEndpoints:
          - matchLabels:
              io.kubernetes.pod.namespace: kube-system
              k8s-app: kube-dns
        toPorts:
          - ports: [{ port: "53", protocol: UDP }, { port: "53", protocol: TCP }]
```

Egress supports `toEndpoints`, `toEntities`, `toCIDR`, `toFQDNs`, and
`toPorts`; ingress supports `fromEndpoints`, `fromEntities`, and `toPorts`.
See [Policies]({{< relref "/docs/platform/security/policies.md" >}}) for the
default-deny model this sits on top of, and its common traps — DNS L7
inspection for `toFQDNs`, the EKS Pod Identity agent needing
`toEntities: [host]`.

## Autoscaling and availability

Available for `web` and `worker` (forbidden on `cron`).

- **`autoscaling`** — a CPU-based HorizontalPodAutoscaler. When enabled,
  `replicas` is ignored (the HPA owns replica count); `minReplicas` must be
  `<= maxReplicas`. RWO persistence is incompatible with autoscaling (above).

  ```yaml
    autoscaling:
      enabled: true
      minReplicas: 2
      maxReplicas: 5
      targetCPUUtilizationPercentage: 70
  ```

- **`replicas`** — fixed replica count when autoscaling is off (default 1).
- **`pdb`** — a PodDisruptionBudget to keep a minimum available during
  voluntary disruptions (node drains, upgrades):

  ```yaml
    pdb:
      enabled: true
      minAvailable: 1
      unhealthyPodEvictionPolicy: AlwaysAllow
  ```

- **`spreadAcrossZones`** (default `true`) spreads pods across
  availability zones; **`antiAffinityPreset`** (`soft` default, or `hard`)
  avoids co-locating pods on the same node; **`onDemand`** (default
  `false`) schedules only on on-demand EC2 instances via Karpenter, for
  workloads that must not run on spot.

## Observability

The `observability` block wires OpenTelemetry env vars and creates
monitoring resources:

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

- **`traces`** injects OTLP trace env vars (endpoint defaults to
  VictoriaTraces).
- **`metrics`**: for **web** apps this also creates a `VMServiceScrape` so
  VictoriaMetrics scrapes the Service's `http` port at `path`. Workers and
  cron have no Service, so they should *push* metrics via the OTLP metrics
  endpoint instead of being scraped.
- **`alertingRules`** creates a `VMRule` with your alerting/recording rules.

See [Observability]({{< relref "/docs/platform/observability/_index.md" >}})
for how these feed into VictoriaMetrics, VictoriaLogs, and Grafana more
broadly. Health checks (probes) are covered [above](#health-probes).
