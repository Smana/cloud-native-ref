---
title: App field reference
weight: 15
description: Complete spec field reference for the App claim — every field, type, and default, reconciled against the pinned XRD.
lastVerified: 2026-08-27
---

Complete list of every `App` `spec` field. **Required** fields are marked.
"Applies to" notes workload-type scoping where relevant; most fields apply to
all types. For task-oriented usage see
[The App claim]({{< relref "/docs/platform/developer-platform/app.md" >}}) and
[Data services]({{< relref "/docs/platform/developer-platform/data-services.md" >}}).

{{< callout type="info" >}}
**Provenance.** The `App` XRD and composition are not in this repository —
they live in
[`Smana/crossplane-configuration`](https://github.com/Smana/crossplane-configuration),
which this repo pins as a `Configuration` package
(`infrastructure/base/crossplane/configuration-aws/configuration-packages.yaml`,
currently `ghcr.io/smana/crossplane-configuration-aws:v0.4.6`). This table was
reconciled by hand against that repository's `apis/app/definition.yaml` (the
CRD schema — types, enums, CEL rules) and `apis/app/kcl/main.k` (composition
defaults that never appear in the schema, such as resource requests/limits or
the gateway/route fallback names) at the commit tagged `v0.4.6`.

**To regenerate:** check out `Smana/crossplane-configuration` at the tag
currently pinned above, and read `apis/app/definition.yaml` +
`apis/app/kcl/main.k` in that checkout — there is no automated extractor, so
this page drifts from the schema the same way any hand-maintained reference
does. Re-verify after every pin bump.
{{< /callout >}}

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
| `replicas` | integer (≥1) | `1` | web, worker | Replica count when autoscaling is off; CronJob has no replica concept. |
| `deploymentStrategy` | enum `RollingUpdate`\|`Recreate` | `RollingUpdate` (or `Recreate` if `persistence.enabled`) | web, worker | Update strategy; explicit value always wins. Meaningless for cron (no `strategy` on a CronJob). |
| `pdb` | object | — | web, worker | PodDisruptionBudget (see below). Forbidden on cron. |
| `persistence` | object | — | all | PVC-backed storage (see below). |
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
| `kvStore` | object | disabled | all | Valkey (see below). |
| `sqlInstance` | object | disabled | all | PostgreSQL (see below). |
| `objectStore` | object | disabled | all | Object storage + workload identity, per cloud (see below). |
| `externalSecrets` | []object | — | all | AWS Secrets Manager sync (see below). |
| `observability` | object | disabled | all | Traces/metrics/alerting (see below). |

{{< callout type="warning" >}}
**Correction from the old field reference:** `persistence` was previously
marked "Applies to: web, worker". That's wrong — the Deployment and the
CronJob share the same pod-builder (`_podSpec`, `apis/app/kcl/main.k:465`,
reused by the CronJob's job template at `main.k:630`), and the persistence
volume/mount are added to that shared spec unconditionally
(`main.k:357-366`). A `cron` App **can** mount a PVC. `deploymentStrategy`
still doesn't apply to cron — that field only ever sets `Deployment.spec.strategy`,
which a CronJob doesn't have.
{{< /callout >}}

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
| `minAvailable` | integer (≥1) | `1` | Minimum available pods. Not a schema default — applied by the composition when unset (`main.k:127,829`). |
| `unhealthyPodEvictionPolicy` | enum `IfHealthyBudget`\|`AlwaysAllow` | `AlwaysAllow` | Unhealthy pod eviction policy. |

### `persistence`

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `enabled` | boolean | `false` | Render a PVC. |
| `size` | string (e.g. `10Gi`) | — (required when enabled) | Requested storage size. |
| `mountPath` | string | — (required when enabled) | Mount path on the main container. |
| `storageClass` | string | cluster default | StorageClass name. |
| `accessModes` | []enum `ReadWriteOnce`\|`ReadWriteMany`\|`ReadOnlyMany` | `[ReadWriteOnce]` | PVC access modes. RWO forces `Recreate` on a Deployment and forbids autoscaling. |

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
the app's own name is reserved (rejected by an admission CEL rule on the
XRD, not the composition).

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `name` | string | yes | Container name (unique; not the app's own name). |
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
| `port` | integer 1–65535 | falls back to the `http` service port, else `service.port`/`8080` | Probe port. |
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
| `gatewayClassName` | string | `cilium` | Gateway class. Composition default (`main.k:857`) — not a schema default. |
| `name` | string | `<app>-gateway` | Gateway name. Composition default (`main.k:842`). |
| `namespace` | string | app namespace | Gateway namespace. Composition default. |
| `listeners[]` | []object | one HTTP:80 listener | `name`, `port`, `protocol` (`HTTP`\|`HTTPS`), `hostname`. Composition default when omitted (`main.k:869-878`). |

### `route` (web only)

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `enabled` | boolean | `false` | Create an HTTPRoute. |
| `internetFacing` | boolean | `false` | `false` → private, `true` → public. Domains are per-cluster, read from the EnvironmentConfig: `aws-0` uses `.priv.aws.ogenki.io` / `.cloud.ogenki.io`, `gcp-0` uses `.priv.gcp.ogenki.io` / `.gcp.cloud.ogenki.io`. |
| `hostname` | string | — (required when enabled) | Hostname prefix (domain auto-added). |
| `rules[]` | []object | route all to `service.port` at `/` | `backendPort` (**required**), `pathPrefix` (default `/`). Composition default when omitted (`main.k:923-927`). |

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
| `type` | enum `valkey`\|`redis` | `valkey` | **Accepted but ignored.** The backend is Valkey-only (SPEC-012 CL-5, `main.k:1009`); the field is kept for API compatibility. |

### `sqlInstance`

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `enabled` | boolean | `false` | Enable the PostgreSQL instance. |
| `size` | enum `small`\|`medium`\|`large` | `small` | Instance size. |
| `storageSize` | string (e.g. `20Gi`) | — | Storage size. |
| `instances` | integer | `3` | Number of instances (HA). |
| `primaryUpdateStrategy` | string | `unsupervised` | Primary update strategy. |
| `createSuperuser` | boolean | `false` | Create a superuser. |
| `performanceInsights` | object | disabled | `pg_stat_statements` / `auto_explain` tuning (see below). |
| `databases[]` | []object | — | `name` (**required**), `owner` (**required**). |
| `roles[]` | []object | — | `name` (**required**), `superuser` (**required**), `comment`, `inRoles`. |
| `atlasSchema` | object | — | Migration Git `url`, `ref`, `path`. |
| `postgresql` | object | — | `parameters` (map), `pg_hba` ([]string). |
| `backup` | object | — | `schedule`, `retentionPolicy` (default `15d`), `bucketName` (required if schedule set). |

#### `sqlInstance.performanceInsights`

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `enabled` | boolean | `false` | Enable `pg_stat_statements`. |
| `explain.sampleRate` | number 0.0–1.0 | `0.2` | Fraction of slow queries `auto_explain` captures. |
| `explain.minDuration` | integer (ms, ≥-1) | `1000` | Minimum query duration to trigger `auto_explain`; `0` logs everything, `-1` disables it. |
| `logStatement` | enum `none`\|`ddl`\|`mod`\|`all` | `none` | Which SQL statements Postgres logs via `log_statement`. |

### `objectStore`

An object-storage bucket, implemented per cloud: **S3 on `aws-0`, GCS on `gcp-0`**, from the
same claim. The bucket's name and location are owned by the platform — a claim states what it
needs, not where it lands.

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `enabled` | boolean | `false` | Enable the bucket. |
| `permissions` | enum `readwrite`\|`readonly`\|`custom` | `readwrite` | Access the workload receives on the bucket. |
| `versioning` | boolean | `false` | Keep non-current object versions. |
| `retentionDays` | integer 1–365 | — | Object retention in days. **GCP only** — see below. |

There is no top-level `region`: the composition reads it from the cluster's own
EnvironmentConfig, so the same claim is portable. There is no `providerConfigRef` either — the
composition knows its own provider.

{{< callout type="warning" >}}
**`retentionDays` currently takes effect on GCP only.** It renders a GCS lifecycle rule that
deletes objects past that age. On AWS it is accepted and stored but does nothing — no S3
lifecycle configuration renders yet, so the same claim's uploads never expire on `aws-0`. This
is a known asymmetry in a field meant to be cloud-neutral, tracked for an S3 implementation;
until then, do not rely on `retentionDays` for AWS data retention.
{{< /callout >}}

#### Cloud-specific knobs

Anything with no honest cloud-neutral meaning is quarantined in an optional per-cloud block,
per [ADR-0007](../../decisions/0007-cloud-abstraction-boundaries.md). Both are ignored on the
other cloud.

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `aws.customPolicy` | string | — | IAM policy JSON. **Required** when `permissions: custom`. |
| `aws.region` | string | cluster region | Overrides where the bucket lands. Rarely needed. |
| `gcp.location` | string | cluster region | Overrides where the bucket lands. Rarely needed. |
| `gcp.storageClass` | enum `STANDARD`\|`NEARLINE`\|`COLDLINE`\|`ARCHIVE` | `STANDARD` | GCS storage class. |

{{< callout type="warning" >}}
**`permissions: custom` is AWS-only.** A custom policy is IAM JSON, which has no GCP
equivalent, so the XRD enforces `aws.customPolicy` whenever `permissions: custom` — a claim
setting `custom` without it is rejected at admission. On GCP the composition degrades `custom`
to read-only rather than silently granting write.
{{< /callout >}}

{{< callout type="info" >}}
**Renamed from `s3Bucket`.** The old field named an AWS service in a cloud-neutral contract,
and its `region` pattern could not express a GCP region at all. `spec.s3Bucket` no longer
exists; `customPolicy` moved under `aws`.
{{< /callout >}}

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
| `traces.endpoint` | string | VictoriaTraces in `observability` | OTLP traces endpoint; falls back to the in-cluster VictoriaTraces service (`main.k:130,159`). |
| `traces.samplingRate` | number 0.0–1.0 | `1.0` | Trace sampling rate. |
| `metrics.enabled` | boolean | `false` | Enable metrics (VMServiceScrape for web). |
| `metrics.endpoint` | string | vmagent in `observability` | OTLP metrics endpoint; falls back to the in-cluster vmsingle service (`main.k:131,178`). |
| `metrics.path` | string | `/metrics` | Scrape path. |
| `metrics.interval` | string | `30s` | Scrape interval. |
| `alertingRules.groups[]` | []object | — | VMRule groups (`name` (**required**), `interval`, `rules` (**required**)). |
