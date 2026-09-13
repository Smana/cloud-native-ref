# image-gallery v2: the platform's OpenTelemetry demo app

- **Status:** design approved on 2026-09-11, through a brainstorm with the owner.
- **Scope:** sub-project **1 of 2**. This one is the application and its deployment. Sub-project 2, the *Victoria-native observability showcase*, covers the telemetry pipeline, the dashboards and the alerts. It gets its own spec, written after this one and validated live against it.
- **Repos:** [`Smana/image-gallery`](https://github.com/Smana/image-gallery) holds the app. [`Smana/crossplane-configuration`](https://github.com/Smana/crossplane-configuration) holds the App composition. This repo holds the claim, the pins and the in-cluster load generator.

## Context

image-gallery is a Go 1.25 application: Chi, HTMX, PostgreSQL through CNPG with Atlas migrations, a Valkey cache, and S3 object storage. It is the only "complete" App claim on the platform, at `apps/base/complete/app.yaml`, and it is also the platform's only real OpenTelemetry producer.

**Today it runs on aws-0 only.** It hardcodes its object storage in the container environment (`STORAGE_ENDPOINT=s3.eu-west-3.amazonaws.com` and the bucket and region with it), so `apps/gcp-0/kustomization.yaml` excludes it. The GCP-only platform therefore has no application producing OTel traffic at all.

What already works:
- HTTP spans and RED metrics.
- SQL spans through `otelsql`.
- Twelve domain metrics, as exponential histograms carrying exemplars.
- zerolog JSON logs carrying `trace_id` and `span_id`.
- OTLP/HTTP push to VictoriaTraces (`:10428/insert/opentelemetry/v1/traces`) and to vmsingle (`:8428/opentelemetry/v1/metrics`).
- Logs reaching VictoriaLogs through the Vector DaemonSet (ADR-0030).

What does not:
- **Metric names are inconsistent.** The claim's business alerts use underscored names (`image_uploads_total`) that the code never emits. VictoriaMetrics keeps OTel dot names on OTLP ingest, so those alerts are dead.
- **The app is a single service.** Traces and the service map show only app → Postgres, Valkey and S3.
- **Memory is fragile.** Versions 1.7.2 to 1.7.5 were all OOMKill fixes. Tracing runs at 20 % sampling "to reduce memory pressure", and the only load tool, `scripts/image-gallery-benchmark.sh` (bash and curl), warns about OOMKills.
- **`networkPolicies.enabled: false`.** The claim writes network rules that are never applied, which misses the constitution's default-deny requirement.
- **The claim's database settings are debug values.** `performanceInsights` is left at "MAX VALUES FOR DEBUGGING".

The App composition (`crossplane-configuration` v0.6.2) already provisions object storage on both clouds:
- **AWS.** An S3 bucket with an EKS Pod Identity.
- **GCP.** A GCS bucket named `<projectID>-ogenki-<name>`, plus a bucket-scoped `GCPWorkloadIdentity` on the App's own ServiceAccount: `readwrite` maps to `objectAdmin`.

It injects `OTEL_SERVICE_NAME` (the claim name), `OTEL_SERVICE_VERSION` (the image tag), the full per-signal OTLP endpoint URLs, and `OTEL_TRACES_SAMPLER=parentbased_traceidratio`, **into the main container only**. Sidecars exist (`spec.sidecars`) but have **no probe fields** and inherit **none** of the main container's environment.

## Goals

- image-gallery runs on **both clouds** from one shared claim.
- It becomes a convincing distributed-tracing subject: a web role and an asynchronous worker role joined by a queue, with one trace spanning client → web → queue → worker → data stores.
- Its telemetry is consistent and complete enough for sub-project 2 to build dashboards, recording rules and alerts on, without rework.
- It survives full (100 %) trace sampling at demo load.
- It ships a load generator and switchable fault injection, so every observability feature can be demonstrated on demand.

## Non-goals

- Dashboards, alerts, recording rules, datasource changes and VictoriaTraces configuration all belong to sub-project 2. That includes fixing the claim's dead business alerts, which sub-project 2 owns because it rewrites the alerts.
- Tail sampling. No component in the chosen stack provides it; see D5.
- Autoscaling the worker independently of the web pods (see D7).

## Decisions

| # | Decision | Chosen over | Why |
|---|---|---|---|
| D1 | Run on **both clouds**. The app gains a GCS backend next to S3. | aws-0 only | It matches the operating model (AWS primary, sometimes both, sometimes GCP-only). The composition already provisions GCS keylessly, so only the app changes. |
| D2 | The load generator is an **`image-gallery loadgen` subcommand** in the same image. | A k6 script; improving the bash script | One codebase with the app's own API knowledge. It emits client-side spans, and it runs from a laptop or in-cluster without a new toolchain. |
| D3 | Add an **async worker**, fed by a queue on the already-provisioned Valkey (streams). | Polish only; a split into full microservices | Cross-service traces, span links and queue lag are the core of a tracing demo. Full microservices cost far more for little extra signal. |
| D5 | The pipeline uses **Victoria components only, with no OTel Collector**. Sub-project 2 designs it; its ADR records it. | An OTel Collector with spanmetrics, servicegraph and tail sampling | This is the owner's call. Victoria-native replacements exist for span-derived RED metrics (vmalert LogsQL rules on VictoriaTraces), the service map (VictoriaTraces' dependency graph) and span exemplars (VictoriaTraces' Tempo API). What sub-project 1 inherits: direct OTLP push and head sampling only. |
| D6 | **The app goes first**, then the showcase. | Showcase first; one combined spec | The dashboards and rules must target the final signal names. The showcase is validated live against this app. |
| D7 | The worker is a **sidecar** in the web pod, plus a small, generic **composition fix** (per-sidecar probes and opt-in environment inheritance). | A second App claim; a new `workers:` composition field | The sidecar shares the pod's ServiceAccount, so storage identity (S3 Pod Identity, GCS Workload Identity) and secrets work unchanged on both clouds. The fix closes a constitution gap (sidecars without probes) for every App. A second claim would need hand-wired per-cloud identity grants and cross-claim secret references. A `workers:` field is the largest change. |

(D4, "story dashboard plus a reusable per-App drill-down", belongs to sub-project 2.)

## Design

### 1. Architecture

```text
loadgen ──HTTP──▶ web (main container) ──XADD job + traceparent──▶ Valkey stream
 (Job/CLI)          │  UI + API, uploads                                 │
                    │                                    XREADGROUP      ▼
                    ├──▶ Postgres (images, status)  ◀── worker (sidecar, same image)
                    └──▶ bucket (S3 on aws-0, GCS on gcp-0) ◀──┘  thumbnails + metadata
```

| Role | Command | Runs as | `service.name` |
|---|---|---|---|
| web | `image-gallery serve` | the App's main container | `xplane-image-gallery` |
| worker | `image-gallery worker` | a sidecar in the same pod | `xplane-image-gallery-worker` |
| load generator | `image-gallery loadgen` | a CLI, or an in-cluster Job/CronJob | `image-gallery-loadgen` |

**Upload flow.**
1. web stores the original object.
2. It writes the image row with `status = pending`.
3. It appends a job to the stream, carrying the W3C `traceparent`.
4. It returns. It does not wait for processing.

**Worker flow.** The worker consumes the stream in a consumer group. For each job it:
1. builds the thumbnails and extracts metadata (dimensions, EXIF);
2. writes the results;
3. sets `status = ready`;
4. acknowledges the message.

**Telemetry.**
- **Traces:** OTLP/HTTP to VictoriaTraces.
- **Metrics:** OTLP/HTTP to VictoriaMetrics. The endpoints are the composition-injected, full per-signal URLs, which also work with VictoriaTraces' non-standard ingest path.
- **Logs:** JSON on stdout, shipped by Vector.

### 2. App internals

**2.1 Storage.** The existing domain interface (`image.StorageService`) stays, with two implementations chosen by `STORAGE_PROVIDER`:

| Provider | Library | Configuration | Credentials |
|---|---|---|---|
| `s3` | `minio-go/v7` (current) | `STORAGE_BUCKET`, `STORAGE_REGION`, `STORAGE_ENDPOINT` | EKS Pod Identity |
| `gcs` | `cloud.google.com/go/storage` | `STORAGE_BUCKET` | ADC via GKE Workload Identity, with no HMAC keys |

- **Instrumentation.** It lives at the interface, so both backends emit identical `storage.*` spans and metrics, with a `storage.provider` attribute.
- **Streaming.** Uploads stream to the backend and are not buffered whole in memory.
- **Local development.** It keeps MinIO.

**2.2 Queue and worker.**
- **The stream.** `image-gallery:jobs`, with a consumer group `workers`. Each message holds `image_id`, the object key, the job type and a `traceparent`.
- **Tracing.** The producer span has kind `PRODUCER`. The consumer span has kind `CONSUMER`, is created as a child of the propagated context, and also records a span link to it. So one trace shows the whole journey, while the relationship stays explicit.
- **Reliability.**
  - `XAUTOCLAIM` reclaims messages stuck past a visibility timeout.
  - Failures retry with exponential backoff up to a maximum number of attempts.
  - Exhausted jobs move to the dead-letter stream `image-gallery:jobs:dead`.
  - Processing is idempotent (keyed by `image_id`).
  - On shutdown, the worker stops reading and finishes the job in flight.
- **Health.** The worker exposes liveness and readiness on a small local HTTP port. Readiness means the stream is reachable and the consumer group exists.
- **Metrics.**
  - Queue depth (`XLEN`) and pending count.
  - The oldest pending message's age (lag).
  - Jobs processed, failed and dead-lettered.
  - Job duration by type.

**2.3 Instrumentation.**
- **Upgrades.** Move to the current OTel Go SDK and to the current HTTP, database and messaging semantic conventions.
- **Naming.** One convention: OTel dot names end to end. VictoriaMetrics preserves them on OTLP ingest.
- **Resource attributes.**
  - `service.name` per role;
  - `service.version`;
  - `deployment.environment`;
  - `k8s.namespace.name` and `k8s.pod.name` (Downward API);
  - `cloud.provider` (`aws` or `gcp`), so dashboards can compare the clouds.
- **Spans.**
  - HTTP server (middleware) and handlers;
  - services;
  - database (`otelsql`, kept);
  - Valkey (`redisotel`);
  - storage calls;
  - queue produce and consume;
  - each image-processing step.
- **Runtime.** Go runtime metrics (memory, GC, goroutines) feed the saturation and OOM story.
- **Logs.** zerolog JSON with `trace_id`, `span_id` and `service.name`, plus job lifecycle events at the right levels.

**2.4 Reliability.** The OOM history is fixed at its causes, not worked around:
- Uploads stream to storage.
- Span queues are bounded, and dropped spans are exported as a metric.
- `GOMEMLIMIT` is derived from the container limit (`automemlimit` is already a dependency).
- The database pool limits are kept.

The target is 100 % sampling at the load generator's top rate (success criterion 5).

**2.5 Demo controls (fault injection).** A new **Demo** settings group, stored in the database and cached like the other settings. It can be changed from the Settings UI or through the API, so load-generator scenarios can flip it.

| Control | Effect |
|---|---|
| Latency | Adds a delay (ms), with a probability, to chosen endpoints |
| Errors | A 5xx response, with a probability |
| Slow DB | A slow list query |
| Worker failure | A job fails, with a probability: it retries, then dead-letters |
| Worker slowdown | A processing delay, so the queue grows |

- **Visibility.** Every injected fault is visible: the span attribute `demo.fault=<type>`, a log line, and the counter `demo.faults.injected`.
- **Defaults.** Every control is off by default. The app is reachable only on the tailnet.

### 3. Load generator

```bash
image-gallery loadgen --target https://image-gallery.priv.gcp.ogenki.io \
  --scenario mixed --rate 10 --duration 15m --concurrency 20
```

| Scenario | Traffic |
|---|---|
| `browse` | Gallery pages, image views and tag filters (cache hits and misses, DB reads) |
| `upload` | Images generated in memory, in varied sizes and formats (storage, queue, worker) |
| `mixed` (default) | Weighted browse, upload, delete and settings: the realistic baseline |
| `steady` | A low constant rate, so dashboards always have data (for in-cluster use) |
| `incident` | About 10 minutes: baseline, then latency on the gallery API, then an error burst, then a worker slowdown that backs up the queue, then recovery. It drives the demo controls through the API and prints a timeline for the presenter. |

- **Traffic model.** An open-loop constant arrival rate with a cap on requests in flight, so a slow server does not quietly reduce the load, plus optional ramps.
- **Output.** A live progress line, then a summary: requests, rate, error %, and client-side p50, p95 and p99.
- **Telemetry.** The HTTP client is instrumented and injects `traceparent`, so traces start at the client. When the `OTEL_*` variables are set, it exports spans and client-side metrics. Otherwise it prints the summary only.
- **Safety.**
  - `--target` is required.
  - The rate is capped unless `--force` is given.
  - Outside `incident`, a circuit breaker stops the run on a sustained error rate.
  - `incident` resets the demo controls on exit, including on interrupt.
- **In-cluster.**
  - A CronJob `image-gallery-loadgen` in this repo runs `steady` against the in-cluster Service. It is **suspended by default**.
  - On-demand runs use `kubectl create job --from=cronjob/image-gallery-loadgen` with a scenario override, wrapped as `scripts/demo-load.sh <scenario>` (this repo has no Taskfile).
  - The Job gets the same OTel settings.
- **Clean-up.** `scripts/image-gallery-benchmark.sh` is deleted.

### 4. Deployment and the composition fix

**4.1 Composition fix** (`crossplane-configuration`). Both fields are generic and opt-in:
- **`spec.sidecars[].livenessProbe` and `spec.sidecars[].readinessProbe`**, shaped like the top-level `healthProbes`.
- **`spec.sidecars[].inheritEnv: true`.** The sidecar receives the main container's combined environment: defaults, OTel, database, cache and `spec.env`. Its own `env` entries override by name.

It follows the package's usual gates: KCL tests, golden fixtures, `task check`, and the README and field reference, then a minor release.

If the App XRD ships in the core package, as the shared `apis/app/definition.yaml` suggests, adding a field means raising the cloud packages' `dependsOn` floor on core. Crossplane does not auto-upgrade an installed dependency, so a live cluster may need its core dependency patched by hand. In this repo, the `configuration-packages.yaml` pins (both clouds) and the App Wizard's clone tag move together.

**4.2 The claim** (this repo).
- **Shared base.** `apps/base/complete` becomes the shared base for both clusters. `apps/gcp-0/kustomization.yaml` includes it, and its exclusion comment is removed.
- **Storage per cluster.** A small per-cluster patch in `apps/aws-0/` and `apps/gcp-0/` sets `STORAGE_PROVIDER`, `STORAGE_BUCKET` and `STORAGE_REGION`. The values are explicit per cluster, not one substituted variable whose shape differs per cloud: CI renders both clusters with AWS-shaped fixtures and cannot catch that.
  - aws-0: `s3`, `eu-west-3-ogenki-xplane-image-gallery`
  - gcp-0: `gcs`, `ogenki-435905-ogenki-xplane-image-gallery`
- **Worker sidecar.** The same image and tag, `args: [worker]`, `inheritEnv: true`, `OTEL_SERVICE_NAME=xplane-image-gallery-worker`, probes, and resource requests and limits.
- **Observability.** Traces are enabled at `samplingRate: 1.0`, and metrics are enabled.
- **Network policies on.** `networkPolicies.enabled: true`.
  - **Egress, both clouds:**
    - DNS, with the L7 DNS rule that FQDN rules require;
    - CNPG and Valkey;
    - VictoriaTraces `:10428` and vmsingle `:8428`.
  - **Egress, per cloud** (in the cluster patch):
    - AWS: S3 FQDNs, plus the EKS Pod Identity agent through `toEntities: host` on TCP 80.
    - GCP: `storage.googleapis.com`, plus the GKE metadata server, which serves Workload Identity tokens.
  - **Ingress:** from the Gateway and from the load generator.
- **Clean-up.** The `performanceInsights` debug values revert to sane defaults.
- **Migrations.** New columns and tables for the job status, the thumbnail keys and the demo controls are Atlas migrations in the app repo. The claim's `atlasSchema` tag follows each app release.
- **Load generator.** A CronJob, suspended, with its own default-deny CiliumNetworkPolicy: DNS, the app Service and VictoriaTraces.

**4.3 Rollout order.**
1. Release `crossplane-configuration` with the sidecar fields.
2. A PR in this repo bumps the pin and the App Wizard's clone tag. It carries no behaviour change.
3. Release image-gallery 2.0.0 to `ghcr.io/smana/image-gallery`.
4. A PR in this repo changes the claim: both clouds, the worker, the network policies, the load generator and the migration tag.
5. Validate live on gcp-0, and on aws-0 when it is up.

### 5. Testing

- **image-gallery.**
  - Unit and integration tests for both storage backends: S3 against the existing MinIO testcontainer, GCS against a fake-gcs testcontainer.
  - The queue: produce, consume, retry, dead-letter and `XAUTOCLAIM`, against a Redis testcontainer.
  - The demo controls, made deterministic with a seeded random source.
  - Trace propagation through the queue, with an in-memory span exporter: the same trace ID and a span link.
  - **Instrument names**, with an in-memory metric reader, so names cannot drift again.
  - An end-to-end testcontainers run (upload → job → worker → `ready`), with an OTLP sink asserting that one trace covers load generator, web and worker.
  - Load-generator scenarios, the circuit breaker, and the `incident` reset.
  - A local soak at the top rate under a container memory limit.
- **crossplane-configuration.** KCL tests for sidecar probes and `inheritEnv`, including precedence and the default off. The golden fixtures for existing claims stay unchanged. Then `task check`.
- **This repo.**
  - `./scripts/validate-manifests.sh` (Invalid 0, Skipped 0);
  - both clusters' app overlays rendered;
  - `check-substitution`;
  - the doc gates after any doc change.
- **Live.**
  - The claim is Synced and Ready, and the pod is 2/2.
  - A load-generator run is inspected in VictoriaTraces, VictoriaMetrics and VictoriaLogs.
  - `hubble observe --verdict DROPPED` shows no dropped legitimate traffic for the namespace.

## Success criteria

1. One shared claim runs on both clouds: on gcp-0 with GCS through Workload Identity, and on aws-0 with S3 through Pod Identity. On both, an upload produces a thumbnail.
2. The worker sidecar processes jobs from the Valkey stream. Failed jobs retry, then dead-letter. Both containers have liveness and readiness probes.
3. One trace in VictoriaTraces spans load generator → web → queue producer → worker consumer, including the database, cache and storage child spans. That request's logs in VictoriaLogs carry its `trace_id`.
4. VictoriaMetrics holds, under OTel dot names:
   - HTTP RED per role;
   - storage operations;
   - queue depth and lag;
   - job outcomes;
   - Go runtime metrics.

   An app test asserts every instrument name.
5. At 100 % sampling, `loadgen --scenario mixed` at the top rate for 15 minutes causes no OOMKill, and dropped spans stay under 0.1 % of exported spans. The top rate is the load generator's default cap, **25 requests/s**.
6. Each demo control produces its fault and its telemetry marker (span attribute, log line and counter). `incident` runs end to end and resets the controls on exit.
7. `networkPolicies.enabled: true`, and no legitimate traffic is dropped during a load-generator run.
8. The new composition fields are opt-in: existing claims render byte-identically (the golden fixtures are unchanged).
9. `scripts/image-gallery-benchmark.sh` is removed. The load-generator CronJob exists, suspended.

If aws-0 is down during validation, criterion 1 is recorded as **pending for AWS**, not claimed.

## Risks and open items

- **An empty metrics scrape.** For web apps with `metrics.enabled`, the composition also creates a `VMServiceScrape` on `/metrics`. image-gallery only pushes OTLP, so that scrape may target a path that does not exist. The implementation plan confirms the behaviour, and then either disables the scrape through the claim or folds a switch into the composition fix.
- **Pod Identity for S3.** `minio-go` must keep reading EKS Pod Identity credentials. It does today on aws-0; keep that path under test.
- **The GKE metadata server.** The Workload Identity egress rule relies on link-local and host-entity semantics in Cilium. It is verified live, not assumed.
- **100 % sampling.** If the soak fails, fall back to a ratio below 1 and record the measured ceiling. Criterion 5 then states the achieved rate.
- **Three repositories.** This session's worktree isolation permits git operations only in its own worktree, so work in `image-gallery` and `crossplane-configuration` needs its own worktree or session. The plan sequences this.
- **A stale clone.** The local clone of `image-gallery` is at v1.7.5, and the deployed tag is 1.7.7. Implementation starts from the current default branch.
- **VictoriaTraces is pre-GA (0.x).** This matters to sub-project 2, which pins the version. This sub-project relies only on its stable OTLP/HTTP ingest.

## References

- ADR-0027 (primary cloud) and ADR-0033 (OpenBao store of record): the app's secrets come from the per-app `apps/` mount (`secret_owning_apps`).
- ADR-0030: Vector as the log shipper. Logs stay on Vector.
- The platform constitution: default-deny network policies, probes, resource limits and restricted security contexts.
- The App composition: `apis/app/kcl/main.k` in `crossplane-configuration`. The object-storage branches (S3 and GCS) and the OTel environment injection were read at v0.6.2.
