# image-gallery v2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** image-gallery becomes the platform's OpenTelemetry demo app. It runs on aws-0 and gcp-0 from one shared claim, with a web role, a queue-fed worker sidecar, a load generator and switchable faults, and it survives 100 % trace sampling at 25 req/s.

**Architecture:** One Go binary with three subcommands (`serve`, `worker`, `loadgen`).
- The web role stores the original upload in S3 or GCS, writes a `pending` row, and appends a job carrying a W3C `traceparent` to a Valkey stream.
- The worker sidecar consumes the stream in a consumer group, builds the thumbnail and metadata, and marks the row `ready`.
- A small, opt-in App-composition change adds per-sidecar probes, environment inheritance and a scrape switch. The claim in this repo then deploys both roles on both clouds.

**Tech Stack:** Go 1.25; OTel Go SDK v1.46.0 with semconv v1.43.0; go-redis v9.22.0 with redisotel; minio-go v7 (S3) and cloud.google.com/go/storage v1.67.1 (GCS); PostgreSQL through CNPG, with Atlas migrations; testcontainers-go v0.44.0; KCL with Crossplane function-kcl; Flux and Kustomize; CiliumNetworkPolicy.

**Spec:** [`docs/superpowers/specs/2026-09-11-image-gallery-v2-design.md`](../specs/2026-09-11-image-gallery-v2-design.md), approved on 2026-09-11. The spec is the binding authority, and this plan argues from it.

## Where each task runs

The work spans three repositories. A session started in the cloud-native-ref worktree may run git **only** in that worktree. So every image-gallery or crossplane-configuration task runs in a session opened in a worktree of **that** repository, created with `EnterWorktree` from its clone. Never use `git worktree add`, and never `git checkout -b` in a shared clone.

| Tasks | Repo | Local clone | Branch |
|---|---|---|---|
| 1–3 | `Smana/crossplane-configuration` | `~/Sources/crossplane-configuration` | `feat/app-sidecar-probes-inherit-env` |
| 4 | `Smana/cloud-native-ref` | this worktree | `chore/crossplane-configuration-v0.7.0` (new worktree from `origin/main`) |
| 5–17 | `Smana/image-gallery` | `~/Sources/image-gallery` (stale at v1.7.5: the worktree branches from `origin/main`, which is v1.7.7) | `feat/v2-otel-demo` |
| 18–20 | `Smana/cloud-native-ref` | `.claude/worktrees/image-gallery-v2` (this worktree, branch `worktree-image-gallery-v2`) | same |

Order: 1 → 2 → 3 (owner-gated release) → 4 → 5 … 17 (owner-gated release) → 18 → 19 → 20. Tasks 5–16 need no crossplane release and can start before Task 3 finishes. Task 18 depends on both releases.

## Global Constraints

Every task's requirements implicitly include this section.

**Owner rules (verbatim):**
- "Never co-author commits". No `Co-Authored-By` trailer and no `Claude-Session` trailer, in any repo, overriding any session reminder.
- "Never add 'Generated with Claude Code' or similar attribution lines to PRs".
- "Write PR titles and descriptions in English". Commit messages are English too, and use Conventional Commits: image-gallery CI runs commitlint on PRs.
- Always work in a worktree (see the table above).
- `main` is CI-gated in every repo. Merges, tag pushes and pushes to `test/gcp-only-live` are the **owner's call**. They are marked **OWNER GATE**: stop and ask.
- Never print tokens or passwords. Pass secrets by stdin, and shred temp files.
- Never tear down gcp-0, and never set `TM_LINEAGE_DESTROY`. `test/gcp-only-live` is never merged.
- If the permission classifier denies an action, stop and let the owner decide. Do not work around it.

**Names (copied from the spec):**
- `service.name`: web `xplane-image-gallery`, worker `xplane-image-gallery-worker`, load generator `image-gallery-loadgen`.
- Stream `image-gallery:jobs`, consumer group `workers`, dead-letter stream `image-gallery:jobs:dead`.
- Buckets: aws-0 uses `s3` with `eu-west-3-ogenki-xplane-image-gallery`; gcp-0 uses `gcs` with `ogenki-435905-ogenki-xplane-image-gallery`.
- Load-generator default rate cap: **25 requests/s**. The sampling target is 100 %, with dropped spans under 0.1 % of exported spans.
- CronJob `image-gallery-loadgen`, **suspended by default**. Wrapper: `scripts/demo-load.sh <scenario>`.
- Every demo control is off by default.

**Versions (resolved 2026-09-11 with `go list -m <mod>@latest`):**
- `go.opentelemetry.io/otel`, `otel/sdk`, `otel/sdk/metric`, `otel/metric`, `otel/trace`, and the OTLP HTTP exporters: `v1.46.0`.
- semconv import path: `go.opentelemetry.io/otel/semconv/v1.43.0`.
- `go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp` and `.../instrumentation/runtime`: `v0.71.0`.
- `github.com/redis/go-redis/v9` and `github.com/redis/go-redis/extra/redisotel/v9`: `v9.22.0`.
- `cloud.google.com/go/storage`: `v1.67.1`. `github.com/XSAM/otelsql`: `v0.44.0`.
- `github.com/testcontainers/testcontainers-go` and its modules: `v0.44.0`. `github.com/KimMachineGun/automemlimit`: `v1.0.0`.
- minio-go **stays at its current version**, because its EKS Pod Identity path works on aws-0 today (spec risk "Pod Identity for S3").
- If `go mod tidy` raises the `go` directive above `1.25`, raise `GO_VERSION` in `.github/workflows/*.yml` and the `golang:` builder image in the Dockerfile to match, in the same commit.

**Platform (constitution):**
- Every container gets liveness and readiness probes and resource requests and limits.
- The restricted securityContext applies: non-root, read-only root filesystem, no privilege escalation, `drop: [ALL]`, seccomp `RuntimeDefault`.
- Every pod-running workload gets a default-deny CiliumNetworkPolicy.

**KCL:**
- Never mutate a dict after creation (function-kcl #285).
- List comprehensions stay on one line.
- Run `kcl fmt` before every commit, and `task check` as the gate.

**Evidence (from `.claude/rules/process.md`):**

| Claim | Evidence |
|---|---|
| Manifests valid | `./scripts/validate-manifests.sh` exits 0 with `Invalid: 0, Skipped: 0` |
| Composition valid | `task check` exits 0 |
| Docs | `./scripts/validate-links.sh` and `./scripts/validate-doc-claims.sh` exit 0 after any doc change |
| Go | `go build ./... && go vet ./... && go test ./...` passes, and `golangci-lint run` is clean |

## Telemetry contract

This table is the interface sub-project 2 builds on. Metric names are OTel dot names, which VictoriaMetrics keeps on OTLP ingest. Every name here is created from a constant in `internal/observability/names.go` (Task 5). `TestInstrumentNamesContract` (Task 16) fails if a name drifts.

**Resource attributes, on every role:**
- `service.name` and `service.version`;
- `deployment.environment.name` (from `OTEL_DEPLOYMENT_ENVIRONMENT`);
- `k8s.namespace.name` and `k8s.pod.name` (from the `POD_NAMESPACE` and `POD_NAME` environment variables, which the composition injects through the Downward API);
- `cloud.provider`, from `OTEL_RESOURCE_ATTRIBUTES=cloud.provider=aws|gcp`, set by the per-cluster patch.

| Constant | Name | Kind | Unit | Attributes | Role |
|---|---|---|---|---|---|
| `MetricHTTPServerDuration` | `http.server.request.duration` | Float64Histogram | `s` | `http.request.method`, `http.route`, `http.response.status_code` | web |
| `MetricHTTPServerActive` | `http.server.active_requests` | Int64UpDownCounter | `{request}` | `http.request.method` | web |
| `MetricHTTPServerRespSize` | `http.server.response.body.size` | Int64Histogram | `By` | as duration | web |
| (otelhttp) | `http.client.request.duration` | histogram | `s` | otelhttp defaults | loadgen |
| `MetricImageUploads` | `image.uploads` | Int64Counter | `{upload}` | `image.content_type`, `outcome` | web |
| `MetricImageDeletions` | `image.deletions` | Int64Counter | `{deletion}` | `outcome` | web |
| `MetricCacheLookups` | `cache.lookups` | Int64Counter | `{lookup}` | `cache.name` (`image`, `list`, `settings`, `demo`), `cache.result` (`hit`, `miss`) | web, worker |
| `MetricSettingsOps` | `settings.operations` | Int64Counter | `{operation}` | `settings.operation` (`read`, `write`), `settings.source` (`cache`, `database`) | web |
| `MetricStorageOps` | `storage.operations` | Int64Counter | `{operation}` | `storage.provider`, `storage.operation` (`put`, `get`, `stat`, `delete`, `list`), `outcome` | web, worker |
| `MetricStorageDuration` | `storage.operation.duration` | Float64Histogram | `s` | as `storage.operations` | web, worker |
| `MetricStorageTransferred` | `storage.transferred` | Int64Counter | `By` | `storage.provider`, `storage.direction` (`read`, `write`) | web, worker |
| `MetricMessagingSent` | `messaging.client.sent.messages` | Int64Counter | `{message}` | `messaging.system`=`valkey`, `messaging.destination.name`, `error.type` (on failure) | web |
| `MetricMessagingProcess` | `messaging.process.duration` | Float64Histogram | `s` | `messaging.system`, `messaging.destination.name`, `job.type`, `outcome` | worker |
| `MetricWorkerJobs` | `worker.jobs` | Int64Counter | `{job}` | `job.type`, `outcome` (`success`, `retry`, `dead_letter`, `skipped`) | worker |
| `MetricQueueDepth` | `queue.depth` | Int64ObservableGauge | `{message}` | `messaging.destination.name`, `messaging.consumer.group.name` | worker |
| `MetricQueuePending` | `queue.pending` | Int64ObservableGauge | `{message}` | same | worker |
| `MetricQueueLag` | `queue.lag` | Float64ObservableGauge | `s` | same | worker |
| `MetricImageProcessing` | `image.processing.duration` | Float64Histogram | `s` | `image.processing.step` (`fetch`, `decode`, `thumbnail`, `store`) | worker |
| `MetricDemoFaults` | `demo.faults.injected` | Int64Counter | `{fault}` | `demo.fault` (`latency`, `error`, `slow_db`, `worker_failure`, `worker_slowdown`) | web, worker |
| `MetricSpansEnded` | `telemetry.spans.ended` | Int64Counter | `{span}` | (none) | all |
| `MetricSpansExported` | `telemetry.spans.exported` | Int64Counter | `{span}` | `outcome` (`success`, `failure`) | all |
| (runtime contrib) | `go.memory.used`, `go.memory.limit`, `go.memory.gc.goal`, `go.goroutine.count`, `go.processor.limit`, `go.schedule.duration`, … | | | | all |

The dropped-span ratio is `1 - telemetry.spans.exported{outcome="success"} / telemetry.spans.ended`.

**Spans:**

| Span | Kind | Where | Key attributes |
|---|---|---|---|
| `<METHOD> <route>` (e.g. `GET /api/images/{id}`) | SERVER | web middleware | `http.request.method`, `http.route`, `http.response.status_code` |
| `send image-gallery:jobs` | PRODUCER | web queue producer | `messaging.system`, `messaging.destination.name`, `messaging.operation.type=send`, `messaging.message.id`, `image.id`, `job.type` |
| `process image-gallery:jobs` | CONSUMER; child of the propagated context **and** a link to it | worker | the above plus `messaging.consumer.group.name`, `messaging.operation.type=process` |
| `job.attempt` | INTERNAL | worker, one per attempt | `job.attempt`, `error.type` |
| `image.fetch`, `image.decode`, `image.thumbnail`, `image.store` | INTERNAL | worker | `image.id` |
| `storage.put`, `.get`, `.stat`, `.delete`, `.list` | CLIENT | both roles | `storage.provider`, `storage.key` |
| `loadgen <op>` | INTERNAL root | loadgen | `loadgen.scenario`, `loadgen.op` |
| redisotel and otelsql spans | CLIENT | both roles | library defaults |

**Faults:** every injected fault sets the span attribute `demo.fault=<type>`, writes a `warn` log line `demo fault injected` with field `demo.fault`, and adds 1 to `demo.faults.injected`.

**Logs:** zerolog JSON on stdout with `trace_id`, `span_id` and `service.name` (the key was `service`; it is renamed to the OTel key).

## Rulings

These are decisions this plan makes where the spec leaves room. Executors follow them; the owner can overturn any.

1. **Egress rules come mostly from the composition.**
   - v0.6.2 already emits DNS (with the L7 DNS rule), CNPG, Valkey, and object-store egress (`host:80` + `world:443`) whenever those backends are enabled (`apis/app/kcl/main.k`, the `_npDns` … `_npObjectStore` block).
   - So the shared claim adds only VictoriaTraces and vmsingle, whose labels were verified live on gcp-0: `app.kubernetes.io/name=vt-single` and `vmsingle`, in namespace `observability`.
   - The gcp-0 patch adds `toCIDR: 169.254.169.254/32` on TCP 80. That is the rule runlore runs live on gcp-0, and `observability/gcp-0/runlore/helmrelease.yaml` records that `toEntities: host` does not match the GKE metadata server there.
   - FQDN-narrowed storage rules are **not** added: the composition's `world:443` makes them redundant. Narrowing it is a composition follow-up.
   - The claim's old `world:80/443` rule is dropped.
2. **Scrape switch.** For web Apps with metrics enabled, the composition renders a `VMServiceScrape` on `/metrics`. image-gallery only pushes OTLP, so that scrape could never succeed. Task 2 adds `observability.metrics.scrape` to the composition (unset means true, so golden fixtures are unchanged), and the claim sets `scrape: false`.
3. **Queue depth uses the consumer group's lag.** `XLEN` also counts acknowledged entries, so it is not a backlog. `queue.depth` is `XINFO GROUPS … lag` (undelivered entries), `queue.pending` is the group's pending count, and `queue.lag` is the age of the oldest pending entry. The stream is capped with `XADD MAXLEN ~ 10000`.
4. **Retries run in-process with exponential backoff:** 4 attempts, sleeping 500 ms, 1 s and 2 s between them, each attempt a `job.attempt` span. Exhausted jobs go to `image-gallery:jobs:dead`, and the original entry is acknowledged. Anything left unacknowledged when a worker dies is reclaimed by `XAUTOCLAIM` after 60 s. Processing is idempotent by `image_id`: a job whose image is already `ready` is acknowledged as `skipped`. An error wrapped with `queue.Permanent` skips the retries.
5. **HTTP metrics follow semconv.**
   - The non-standard `http.server.request.count` goes away; the request count is the duration histogram's count.
   - The claim's working `HighHTTPErrorRate` alert is rewritten to `http.server.request.duration_count` in Task 18, so the rename does not silently disable it.
   - Every other alert and recording rule stays for sub-project 2, as the spec says.
6. **No presigned URLs.** Signing GCS URLs needs `iam.serviceAccounts.signBlob`, which the workload identity does not hold. Every image URL is the app's own proxy: `/api/images/{id}/view` for the original and `/api/images/{id}/thumbnail` for the thumbnail. `GenerateURL` and `GenerateImageURL` are removed.
7. **EXIF is deferred.** The metadata step records width, height, format and colour model into `images.metadata`. No EXIF reader is added: no maintained pure-Go one was evaluated, and the trace shows the same processing steps either way.
8. **GCS uploads use `Writer.ChunkSize = 0`.** That means a single request without a buffer (library docs, `writer.go` in v1.67.1). It trades transport retries for bounded memory, which is the OOM story. Files are at most 10 MB.
9. **Demo controls get their own table and endpoints:** a `demo_controls` table, one row, and `GET` and `PUT /api/settings/demo`, `POST /api/settings/demo/reset`. They are cached in Valkey for 5 s, so the worker sees a change within 5 s. The demo endpoints and `/healthz` and `/readyz` are never faulted, so a fault can always be switched off.
10. **Validate live before merging.** The claim PR is deployed to gcp-0 through `test/gcp-only-live` (OWNER GATE) and validated there, then handed to the owner to merge. gcp-0 tracks that branch, not `main`.
11. **The worker health port is `:8081`** (`WORKER_HEALTH_ADDR`), declared as a sidecar port. Sidecar probes need an explicit port, or else the sidecar's first declared port. A named port would resolve against the wrong container.

## File map

**crossplane-configuration:**
- modify `apis/app/definition.yaml`, `apis/app/kcl/main.k`, `apis/app/kcl/main_test.k`, `apis/app/kcl/settings-example.yaml` and `apis/app/kcl/README.md`;
- regenerate `apis/app/composition-aws.yaml` and `composition-gcp.yaml`;
- modify `packages/aws/crossplane.yaml` and `packages/gcp/crossplane.yaml`;
- create `examples/app-sidecar-worker.yaml` and `tests/golden/app-sidecar-worker.yaml`.

**image-gallery.** New packages, one responsibility each:

| Path | Responsibility |
|---|---|
| `cmd/image-gallery/main.go` | subcommand dispatch (replaces `cmd/server/main.go`) |
| `internal/app/bootstrap.go` | the dependencies every role builds: config, logger, OTel, DB, object store, Valkey |
| `internal/app/serve.go`, `internal/app/worker.go` | role entrypoints |
| `internal/observability/names.go` | the telemetry-contract constants |
| `internal/observability/spancount.go` | the ended and exported span counters |
| `internal/platform/storage/objectstore.go`, `s3store.go`, `gcsstore.go`, `storetest/contract.go` | the object-store interface, its two backends and a shared contract test |
| `internal/platform/queue/{job.go,producer.go,consumer.go,metrics.go}` | the Valkey stream queue |
| `internal/worker/{processor.go,health.go}` | job processing and the health server |
| `internal/domain/demo/controls.go`, `internal/faults/{service.go,injector.go}`, `internal/services/implementations/demo_repository.go` | demo controls (`faults`, so the import does not collide with the domain package `demo`) |
| `internal/loadgen/{options.go,engine.go,ops.go,imagegen.go,scenarios.go,incident.go,breaker.go,summary.go,main.go}` | the load generator |
| `internal/platform/database/migrations/004_async_processing_and_demo.sql` | migration |
| `internal/e2e/e2e_test.go` | the end-to-end trace and instrument contract test |
| `scripts/soak.sh` | the local soak |

Deleted: `internal/platform/storage/minio.go` and `cmd/server/`.

**cloud-native-ref:**
- modify `apps/base/complete/app.yaml`, `apps/base/complete/kustomization.yaml`, `apps/aws-0/kustomization.yaml` and `apps/gcp-0/kustomization.yaml`;
- modify the comment in `clusters/gcp-0/apps.yaml`;
- modify both `configuration-packages.yaml` pins and `apps/platform/app-wizard/app.yaml`;
- create `apps/base/complete/loadgen.yaml` and `scripts/demo-load.sh`;
- delete `scripts/image-gallery-benchmark.sh`;
- update the docs pages listed in Task 19;
- create `docs/superpowers/specs/2026-09-11-image-gallery-v2-verification.md`.

---

## Phase A — crossplane-configuration (Tasks 1–3)

Session: a worktree of `~/Sources/crossplane-configuration` (created with `EnterWorktree`), branch `feat/app-sidecar-probes-inherit-env`. Tools come from `mise install`: `kcl`, `crossplane`, `task`, python with pyyaml.

### Task 1: Per-sidecar probes and opt-in environment inheritance

**Files:**
- Modify: `apis/app/kcl/main.k`. Replace the `_sidecarContainers` line, which sits just after `_mainContainer`.
- Modify: `apis/app/kcl/main_test.k` (append two tests).
- Modify: `apis/app/kcl/settings-example.yaml`. Add a second sidecar after `log-shipper`.
- Modify: `apis/app/definition.yaml`. Add three keys under `sidecars.items.properties`.
- Modify: `apis/app/kcl/README.md`.
- Regenerate: `apis/app/composition-aws.yaml` and `apis/app/composition-gcp.yaml` (`task generate`).

**Interfaces:**
- Consumes: `_buildExtraContainer(c, withPorts)`, `_buildProbe(p, defaults)`, `_livenessProbeDefaults`, `_readinessProbeDefaults` and `_mainCombinedEnv` from `main.k`. All of them already exist.
- Produces: the claim fields `spec.sidecars[].inheritEnv` (bool), `spec.sidecars[].livenessProbe` and `spec.sidecars[].readinessProbe`. The probes take the fields `type`, `path`, `port`, `command`, `initialDelaySeconds`, `periodSeconds`, `timeoutSeconds` and `failureThreshold`. Task 18's claim uses these fields verbatim.

- [ ] **Step 1: Add the test sidecar to `apis/app/kcl/settings-example.yaml`.** Put it directly after the `log-shipper` entry, at the same indentation:

```yaml
            - name: worker
              image: "myrepo/myapp:latest"
              args: ["worker"]
              # Opt-in: inherit the main container's combined env; own entries win by name.
              inheritEnv: true
              env:
                - name: USER
                  value: "worker"
              ports:
                - name: worker-health
                  containerPort: 8081
              livenessProbe:
                path: /healthz
                port: 8081
              readinessProbe:
                path: /readyz
                port: 8081
```

- [ ] **Step 2: Append the failing tests to `apis/app/kcl/main_test.k`.**

```python
# ---- Test: sidecar inheritEnv (opt-in, own entries win) and per-sidecar probes ----
test_sidecar_inherit_env_and_probes = lambda {
    dep = [r for r in items if r.kind == "Deployment"][0]
    containers = dep.spec.template.spec.containers
    main = containers[0]
    worker = [c for c in containers if c.name == "worker"][0]
    shipper = [c for c in containers if c.name == "log-shipper"][0]
    _workerNames = [e.name for e in worker.env]
    _missing = [e.name for e in main.env if e.name not in _workerNames]
    assert len(_missing) == 0, "worker should inherit every main env var, missing: {}".format(_missing)
    _users = [e for e in worker.env if e.name == "USER"]
    assert len(_users) == 1 and _users[0].value == "worker", "the sidecar's own USER must win, exactly once, got {}".format(_users)
    assert not any_true([e.name == "POD_NAME" for e in (shipper?.env or [])]), "inheritEnv must default to off"
    assert worker.livenessProbe.httpGet.path == "/healthz" and worker.livenessProbe.httpGet.port == 8081, "worker liveness probe"
    assert worker.readinessProbe.httpGet.path == "/readyz" and worker.readinessProbe.httpGet.port == 8081, "worker readiness probe"
    assert not shipper?.livenessProbe and not shipper?.readinessProbe, "sidecar probes are opt-in"
}

# ---- Test: a sidecar probe never borrows the main container's named port ----
test_sidecar_probe_port_fallback = lambda {
    _tcp = _buildProbe(_sidecarProbeSpec({type = "tcp"}, 3101), _readinessProbeDefaults)
    assert _tcp.tcpSocket.port == 3101, "tcp probe falls back to the sidecar's first port"
    _http = _buildProbe(_sidecarProbeSpec({path = "/x"}, 3101), _livenessProbeDefaults)
    assert _http.httpGet.port == 3101, "http probe falls back to a NUMERIC sidecar port, never the named 'http'"
    _explicit = _buildProbe(_sidecarProbeSpec({path = "/x", port = 9000}, 3101), _livenessProbeDefaults)
    assert _explicit.httpGet.port == 9000, "an explicit probe port wins"
    _exec = _buildProbe(_sidecarProbeSpec({type = "exec", command = ["true"]}, None), _livenessProbeDefaults)
    assert _exec.exec.command == ["true"], "exec needs no port"
}
```

- [ ] **Step 3: Run the tests and confirm they fail.**

Run: `cd apis/app/kcl && kcl test . -Y settings-example.yaml`
Expected: FAIL. `test_sidecar_inherit_env_and_probes` fails with "worker should inherit every main env var", and `test_sidecar_probe_port_fallback` fails with an undefined `_sidecarProbeSpec`.

- [ ] **Step 4: Implement it in `main.k`.** Replace the line

```python
_sidecarContainers = [_buildExtraContainer(c, True) for c in (oxr.spec.sidecars or [])]
```

with:

```python
# A sidecar probe needs a port of its own: a named port such as "http" resolves
# against the SAME container, so the main container's port can never be
# borrowed. Explicit port wins, else the sidecar's first declared port; exec
# needs none. A probe with neither is a render error, not a silent bad probe.
_sidecarProbeSpec = lambda p: any, fallbackPort: any -> any {
    _port = p?.port or fallbackPort
    assert _port or p?.type == "exec", "sidecar probe needs `port` or a declared sidecar port"
    p | {port = _port} if _port else p
}

# Sidecar = the reduced extra-container build plus two OPT-IN additions:
# `inheritEnv` (the main container's combined env and envFrom; the sidecar's own
# env entries override by name) and per-sidecar probes. With neither set, the
# union below is empty, so every existing sidecar renders byte-identically and
# the golden fixtures do not move. Built in one expression (function-kcl #285).
_buildSidecar = lambda c: any -> any {
    _inherit = c?.inheritEnv or False
    _ownNames = [e.name for e in (c?.env or [])]
    _env = [e for e in _mainCombinedEnv if e.name not in _ownNames] + (c?.env or [])
    _envFrom = (oxr.spec.envFrom or []) + (c?.envFrom or [])
    _fallbackPort = c.ports[0].containerPort if c?.ports else None
    _buildExtraContainer(c, True) | {
        if _inherit and _env:
            env = _env
        if _inherit and _envFrom:
            envFrom = _envFrom
        if c?.livenessProbe:
            livenessProbe = _buildProbe(_sidecarProbeSpec(c.livenessProbe, _fallbackPort), _livenessProbeDefaults)
        if c?.readinessProbe:
            readinessProbe = _buildProbe(_sidecarProbeSpec(c.readinessProbe, _fallbackPort), _readinessProbeDefaults)
    }
}

# Sidecar + init container lists (SPEC-007 T007). Sidecars keep ports.
_sidecarContainers = [_buildSidecar(c) for c in (oxr.spec.sidecars or [])]
```

Keep the `_initContainerList` line unchanged. If the comment `# Sidecar + init container lists (SPEC-007 T007). Sidecars keep ports.` already sits above the replaced line, don't duplicate it.

- [ ] **Step 5: Format and run the tests; confirm they pass.**

Run: `cd apis/app/kcl && kcl fmt . && kcl test . -Y settings-example.yaml`
Expected: PASS, every test including the two new ones. `git diff --stat` shows no reformat noise outside the lines you touched.

- [ ] **Step 6: Extend the XRD.** In `apis/app/definition.yaml`, under `sidecars:` → `items:` → `properties:`, add these keys at the same indentation as `ports:`:

```yaml
                      inheritEnv:
                        type: boolean
                        description: >-
                          Give this sidecar the main container's combined environment (composition
                          defaults, OpenTelemetry, auto-wired DATABASE_URL/REDIS_URL and spec.env)
                          and spec.envFrom. The sidecar's own env entries override inherited ones
                          by name. Off by default.
                      livenessProbe:
                        type: object
                        description: >-
                          Liveness probe for this sidecar, shaped like healthProbes.liveness. The
                          port defaults to the sidecar's first declared port; it never borrows the
                          main container's.
                        properties:
                          type:
                            type: string
                            enum: ["http", "tcp", "grpc", "exec"]
                          path:
                            type: string
                          port:
                            type: integer
                            minimum: 1
                            maximum: 65535
                          command:
                            type: array
                            items:
                              type: string
                          initialDelaySeconds:
                            type: integer
                            minimum: 0
                          periodSeconds:
                            type: integer
                            minimum: 1
                          timeoutSeconds:
                            type: integer
                            minimum: 1
                          failureThreshold:
                            type: integer
                            minimum: 1
                      readinessProbe:
                        type: object
                        description: Readiness probe for this sidecar. Same shape and port rule as livenessProbe.
                        properties:
                          type:
                            type: string
                            enum: ["http", "tcp", "grpc", "exec"]
                          path:
                            type: string
                          port:
                            type: integer
                            minimum: 1
                            maximum: 65535
                          command:
                            type: array
                            items:
                              type: string
                          initialDelaySeconds:
                            type: integer
                            minimum: 0
                          periodSeconds:
                            type: integer
                            minimum: 1
                          timeoutSeconds:
                            type: integer
                            minimum: 1
                          failureThreshold:
                            type: integer
                            minimum: 1
```

Add no `default:` keys. The KCL defaults (`_livenessProbeDefaults` and `_readinessProbeDefaults`) own them, so rendering stays under the module's control.

- [ ] **Step 7: Document it in `apis/app/kcl/README.md`.**
  1. In the Features list, change the multi-container bullet to: `**Multi-container pods**: sidecars[] (ports allowed, optional per-sidecar liveness/readiness probes, opt-in inheritEnv) and initContainers[] (no ports), each inheriting the security defaults unless overridden.`
  2. Add this section after "Security defaults":

````markdown
## Sidecars: probes and environment inheritance

Both are opt-in, per sidecar.

```yaml
sidecars:
  - name: worker
    image: ghcr.io/example/app:1.0.0
    args: ["worker"]
    inheritEnv: true          # main container's env + envFrom; own entries win by name
    env:
      - name: OTEL_SERVICE_NAME
        value: my-app-worker
    ports:
      - name: worker-health
        containerPort: 8081
    livenessProbe:  { path: /healthz }   # port falls back to 8081, the first sidecar port
    readinessProbe: { path: /readyz }
```

- A sidecar probe never uses the main container's port. A named port resolves against the container that owns the probe. With no `port` and no declared sidecar port, the render fails.
- `inheritEnv` carries the composition defaults (`POD_NAME`, …), the `OTEL_*` variables, the auto-wired `DATABASE_URL`/`REDIS_URL`, `spec.env` and `spec.envFrom`.
````

- [ ] **Step 8: Regenerate and run the full gate.**

Run: `task generate && task check`
Expected: exit 0. `render` prints `MATCH` for every existing example (for example `18/18 match`), so the golden fixtures are unchanged and success criterion 8 holds.

- [ ] **Step 9: Commit.**

```bash
git add apis/app/definition.yaml apis/app/kcl/main.k apis/app/kcl/main_test.k \
        apis/app/kcl/settings-example.yaml apis/app/kcl/README.md \
        apis/app/composition-aws.yaml apis/app/composition-gcp.yaml
git commit -m "feat(app): per-sidecar probes and opt-in environment inheritance" \
  -m "Sidecars had no probe fields and inherited none of the main container's environment. Both are now opt-in per sidecar; existing claims render byte-identically."
```

### Task 2: Metrics-scrape switch, a sidecar example, and the core floor

**Files:**
- Modify: `apis/app/kcl/main.k` (the `VMServiceScrape` condition).
- Modify: `apis/app/definition.yaml` (`observability.metrics.scrape`).
- Create: `examples/app-sidecar-worker.yaml` and `tests/golden/app-sidecar-worker.yaml`.
- Modify: `scripts/assemble.sh` (the AWS examples list).
- Modify: `packages/aws/crossplane.yaml` and `packages/gcp/crossplane.yaml` (the core `dependsOn` floor).
- Modify: `apis/app/kcl/README.md`.
- Regenerate the compositions.

**Interfaces:**
- Consumes: the Task 1 fields.
- Produces: the claim field `spec.observability.metrics.scrape` (bool; unset means true). Task 18 sets `scrape: false`.

- [ ] **Step 1: Write the example, which serves as the test input.** Create `examples/app-sidecar-worker.yaml`:

```yaml
# Web app plus a worker sidecar sharing its pod. The sidecar inherits the main
# container's environment (OTel, DB, spec.env, envFrom), overrides its own
# service name, and carries its own probes, whose port falls back to the
# sidecar's first declared port. The app pushes OTLP metrics only, so the
# /metrics scrape is switched off.
apiVersion: cloud.ogenki.io/v1alpha1
kind: App
metadata:
  name: xplane-gallery-demo
  namespace: apps
spec:
  image:
    repository: ghcr.io/example/gallery
    tag: "2.0.0"
  service:
    port: 8080
  env:
    - name: LOG_LEVEL
      value: info
  envFrom:
    - secretRef:
        name: gallery-config
        optional: true
  observability:
    traces:
      enabled: true
      samplingRate: 1.0
    metrics:
      enabled: true
      scrape: false
  sidecars:
    - name: worker
      image: ghcr.io/example/gallery:2.0.0
      args: ["worker"]
      inheritEnv: true
      env:
        - name: OTEL_SERVICE_NAME
          value: xplane-gallery-demo-worker
      ports:
        - name: worker-health
          containerPort: 8081
      livenessProbe:
        path: /healthz
      readinessProbe:
        path: /readyz
      resources:
        requests:
          cpu: 50m
          memory: 64Mi
        limits:
          cpu: 200m
          memory: 128Mi
```

- [ ] **Step 2: Confirm the gate fails.**

Run: `task check`
Expected: FAIL in two places. `schema` reports `observability.metrics.scrape` not declared in schema, and `render` says `no golden fixture for: app-sidecar-worker.yaml`.

- [ ] **Step 3: Add the XRD field.** In `apis/app/definition.yaml`, under `observability:` → `properties:` → `metrics:` → `properties:`, next to `path` and `interval`:

```yaml
                        scrape:
                          type: boolean
                          description: >-
                            Render a VMServiceScrape for the metrics path (web apps only). Unset
                            means true. Set false for apps that only push OTLP metrics, whose
                            /metrics path does not exist.
```

- [ ] **Step 4: Gate the scrape in `main.k`.** Replace

```python
if oxr.spec.observability?.metrics?.enabled and _isWeb:
    _vmServiceScrapeResource = [{
```

with

```python
# `scrape: false` skips the VMServiceScrape for OTLP-push-only apps (their
# /metrics would 404 forever). Unset keeps the historical behavior, so the
# existing golden fixtures do not move.
if oxr.spec.observability?.metrics?.enabled and _isWeb and oxr.spec.observability?.metrics?.scrape != False:
    _vmServiceScrapeResource = [{
```

- [ ] **Step 5: Regenerate, capture the new golden fixture, and check what it says.**

```bash
task generate
crossplane render examples/app-sidecar-worker.yaml apis/app/composition-aws.yaml functions.yaml \
  --extra-resources examples/environmentconfig.yaml > tests/golden/app-sidecar-worker.yaml
python3 - <<'EOF'
import yaml
docs = [d for d in yaml.safe_load_all(open("tests/golden/app-sidecar-worker.yaml")) if d]
assert not [d for d in docs if d.get("kind") == "VMServiceScrape"], "scrape:false must skip the VMServiceScrape"
dep = [d for d in docs if d.get("kind") == "Deployment"][0]
main, worker = dep["spec"]["template"]["spec"]["containers"]
names = [e["name"] for e in worker["env"]]
assert names.count("OTEL_SERVICE_NAME") == 1, names
assert [e["value"] for e in worker["env"] if e["name"] == "OTEL_SERVICE_NAME"] == ["xplane-gallery-demo-worker"]
assert "OTEL_EXPORTER_OTLP_TRACES_ENDPOINT" in names and "LOG_LEVEL" in names and "POD_NAME" in names
assert worker["envFrom"][0]["secretRef"]["name"] == "gallery-config"
assert worker["livenessProbe"]["httpGet"] == {"path": "/healthz", "port": 8081}
assert worker["readinessProbe"]["httpGet"] == {"path": "/readyz", "port": 8081}
print("golden OK")
EOF
```

Expected: `golden OK`. If an assertion fails, fix `main.k` rather than the fixture.

- [ ] **Step 6: Ship the example in the AWS package.** In `scripts/assemble.sh`, append `examples/app-sidecar-worker.yaml \` to the explicit AWS `cp examples/app-basic.yaml …` list, on the line after `examples/app-worker.yaml \`.

- [ ] **Step 7: Raise the core floor in both cloud packages.** The App XRD lives in core, and the cloud Compositions now read fields only core v0.7.0 defines. In `packages/aws/crossplane.yaml` and `packages/gcp/crossplane.yaml`, change the core dependency `version: ">=v0.6.1"` to `version: ">=v0.7.0"`. In the history comment above it, add the line:

```yaml
    #   >=v0.6.1 -> v0.7.0  sidecars[].inheritEnv/livenessProbe/readinessProbe and
    #                       observability.metrics.scrape, read by the App Compositions.
```

(If `packages/gcp/crossplane.yaml` carries a different floor, set it to `>=v0.7.0` all the same, and add the same history line.)

- [ ] **Step 8: Add a README note.** Under "Observability" in `apis/app/kcl/README.md`, add: "`observability.metrics.scrape: false` skips the `VMServiceScrape` for apps that only push OTLP."

- [ ] **Step 9: Run the full gate.**

Run: `task check`
Expected: exit 0, with `render` reporting every example `MATCH`, including `app-sidecar-worker.yaml`, and the count one higher than in Task 1.

- [ ] **Step 10: Commit, push and open the PR.**

```bash
git add apis/app/kcl/main.k apis/app/definition.yaml apis/app/composition-aws.yaml apis/app/composition-gcp.yaml \
        apis/app/kcl/README.md examples/app-sidecar-worker.yaml tests/golden/app-sidecar-worker.yaml \
        scripts/assemble.sh packages/aws/crossplane.yaml packages/gcp/crossplane.yaml
git commit -m "feat(app): let OTLP-only apps skip the metrics scrape" \
  -m "Adds observability.metrics.scrape (unset = true), an example exercising sidecar probes and inheritEnv, and raises the core dependsOn floor to v0.7.0 in both cloud packages."
git push -u origin feat/app-sidecar-probes-inherit-env
gh pr create --repo Smana/crossplane-configuration --base main \
  --title "feat(app): sidecar probes, opt-in env inheritance, metrics-scrape switch" \
  --body-file <scratch file: summary, the three fields, "existing golden fixtures unchanged", task check output>
```

The PR body is English, with no attribution line. Wait for CI to go green: `gh pr checks <n> --repo Smana/crossplane-configuration --watch`.

### Task 3: Release crossplane-configuration v0.7.0 (OWNER GATE)

**Files:** none. This task is a release.

**Interfaces:**
- Produces: the OCI packages `ghcr.io/smana/crossplane-configuration-{core,aws,gcp}:v0.7.0` and the release asset `xrd-crds.yaml`, which Task 4 consumes.

- [ ] **Step 1: OWNER GATE.** Ask the owner to merge the Task 2 PR and approve the tag. Nothing publishes from `main`, and a pushed tag publishes immutably.
- [ ] **Step 2: Once the owner approves, tag the merge commit.**

```bash
git fetch origin main
git tag v0.7.0 origin/main
git push origin v0.7.0
```

- [ ] **Step 3: Verify the release.**

Run: `gh run watch --repo Smana/crossplane-configuration "$(gh run list --repo Smana/crossplane-configuration --workflow release.yaml --limit 1 --json databaseId --jq '.[0].databaseId')"`, then `gh release view v0.7.0 --repo Smana/crossplane-configuration --json assets --jq '.assets[].name'`.
Expected: the run concludes `success`, and the assets list `xrd-crds.yaml`.


## Phase B — Pin bump in cloud-native-ref (Task 4)

### Task 4: Bump the crossplane-configuration pin and the App Wizard clone tag

Session: a new cloud-native-ref worktree from `origin/main` (`EnterWorktree`), branch `chore/crossplane-configuration-v0.7.0`. This PR changes no behaviour: no claim uses the new fields yet.

**Files:**
- Modify: `infrastructure/base/crossplane/configuration-aws/configuration-packages.yaml` (`package: ghcr.io/smana/crossplane-configuration-aws:v0.6.2` becomes `:v0.7.0`).
- Modify: `infrastructure/base/crossplane/configuration-gcp/configuration-packages.yaml` (`...-gcp:v0.6.2` becomes `:v0.7.0`).
- Modify: `apps/platform/app-wizard/app.yaml` (`- --branch=v0.6.2` becomes `- --branch=v0.7.0`).

**Interfaces:**
- Consumes: the v0.7.0 packages and release asset from Task 3.
- Produces: a cluster that serves the App XRD with `sidecars[].inheritEnv/livenessProbe/readinessProbe` and `observability.metrics.scrape`. Task 18 relies on it.

- [ ] **Step 1: Confirm the wizard's file paths still exist at the new tag.**

Run: `gh api 'repos/Smana/crossplane-configuration/contents/apis/app?ref=v0.7.0' --jq '.[].name'`
Expected: the list includes `definition.yaml`, `composition-aws.yaml` and `composition-gcp.yaml`, the same names as at v0.6.2. (No rename means `wizard.yaml`'s paths still resolve.)

- [ ] **Step 2: Edit the three version strings above.** Change nothing else.
- [ ] **Step 3: Validate.**

Run: `./scripts/validate-manifests.sh`
Expected: exit 0 with `Invalid: 0, Skipped: 0`. The catalog is rebuilt from the v0.7.0 `xrd-crds.yaml`.

- [ ] **Step 4: Commit and open the PR.**

```bash
git add infrastructure/base/crossplane/configuration-aws/configuration-packages.yaml \
        infrastructure/base/crossplane/configuration-gcp/configuration-packages.yaml \
        apps/platform/app-wizard/app.yaml
git commit -m "chore(crossplane): bump crossplane-configuration to v0.7.0" \
  -m "Adds per-sidecar probes, opt-in sidecar env inheritance and observability.metrics.scrape. No claim uses them yet. The App Wizard clone tag moves with the pin."
git push -u origin chore/crossplane-configuration-v0.7.0
gh pr create --base main --title "chore(crossplane): bump crossplane-configuration to v0.7.0" --body-file <scratch body>
```

The body must say that an existing cluster keeps core at v0.6.2 until `smana-crossplane-configuration-core` is patched. Crossplane does not auto-upgrade an installed dependency; Task 20 does it on gcp-0.

- [ ] **Step 5: OWNER GATE.** The owner merges once CI is green.

## Phase C — image-gallery v2 (Tasks 5–17)

Session: a worktree of `~/Sources/image-gallery` (`EnterWorktree`, from `origin/main` = v1.7.7), branch `feat/v2-otel-demo`. Docker is required for the testcontainers tests, and the `atlas` CLI is required for migrations in tests (`internal/testutils/containers.go` runs `atlas migrate apply`). Integration tests are skipped under `-short`, as today; run them without `-short` locally.

### Task 5: SDK upgrade, telemetry contract constants, span-drop counters and runtime metrics

**Files:**
- Modify: `go.mod` and `go.sum`.
- Create: `internal/observability/names.go` and `internal/observability/spancount.go`.
- Modify: `internal/observability/provider.go`, `internal/observability/config.go`, `internal/observability/logger.go` and `internal/config/config.go` (`ObservabilityConfig`).
- Modify: `cmd/server/main.go` (pass the new config fields).
- Modify: every file importing `go.opentelemetry.io/otel/semconv/v1.26.0`.
- Test: `internal/observability/provider_test.go` and `internal/observability/logger_test.go`.

**Interfaces:**
- Produces:
  - the constants in `names.go` (the full contract table above), which every later task uses instead of string literals;
  - `observability.Config` gains `PodName` and `PodNamespace string`;
  - `func NewProviderWith(ctx context.Context, config Config, logger *Logger, traceExp sdktrace.SpanExporter, reader sdkmetric.Reader) (*Provider, error)`, a test seam; `NewProvider` keeps its signature;
  - `func NewLoggerTo(w io.Writer, config Config) *Logger`.

- [ ] **Step 1: Upgrade the dependencies.**

```bash
go get go.opentelemetry.io/otel@v1.46.0 go.opentelemetry.io/otel/sdk@v1.46.0 \
  go.opentelemetry.io/otel/sdk/metric@v1.46.0 go.opentelemetry.io/otel/metric@v1.46.0 \
  go.opentelemetry.io/otel/trace@v1.46.0 \
  go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracehttp@v1.46.0 \
  go.opentelemetry.io/otel/exporters/otlp/otlpmetric/otlpmetrichttp@v1.46.0 \
  go.opentelemetry.io/contrib/instrumentation/runtime@v0.71.0 \
  go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp@v0.71.0 \
  github.com/XSAM/otelsql@v0.44.0 \
  github.com/redis/go-redis/v9@v9.22.0 github.com/redis/go-redis/extra/redisotel/v9@v9.22.0 \
  github.com/testcontainers/testcontainers-go@v0.44.0 \
  github.com/testcontainers/testcontainers-go/modules/postgres@v0.44.0 \
  github.com/testcontainers/testcontainers-go/modules/minio@v0.44.0 \
  github.com/testcontainers/testcontainers-go/modules/redis@v0.44.0 \
  github.com/KimMachineGun/automemlimit@v1.0.0
grep -rl 'semconv/v1.26.0' --include='*.go' . | xargs sed -i 's#semconv/v1.26.0#semconv/v1.43.0#'
go mod tidy && go build ./...
```

Fix compile errors minimally:
- `semconv.DeploymentEnvironment(x)` becomes `semconv.DeploymentEnvironmentNameKey.String(x)`.
- If `automemlimit` v1.0.0 changed its option names, keep the ratio at 0.9 and the cgroup provider.

Task 6 rewrites the HTTP middleware, so here only make it compile. If the `go` directive rose above 1.25, apply the Global Constraints rule.

- [ ] **Step 2: Create `internal/observability/names.go`.**

```go
package observability

// Telemetry contract. Every metric name the application emits is one of these
// constants; sub-project 2 builds its dashboards and rules on them, and
// internal/e2e.TestInstrumentNamesContract fails when one drifts. Keep in step
// with the table in OBSERVABILITY.md.
const (
	MetricHTTPServerDuration = "http.server.request.duration"
	MetricHTTPServerActive   = "http.server.active_requests"
	MetricHTTPServerRespSize = "http.server.response.body.size"
	MetricImageUploads       = "image.uploads"
	MetricImageDeletions     = "image.deletions"
	MetricCacheLookups       = "cache.lookups"
	MetricSettingsOps        = "settings.operations"
	MetricStorageOps         = "storage.operations"
	MetricStorageDuration    = "storage.operation.duration"
	MetricStorageTransferred = "storage.transferred"
	MetricMessagingSent      = "messaging.client.sent.messages"
	MetricMessagingProcess   = "messaging.process.duration"
	MetricWorkerJobs         = "worker.jobs"
	MetricQueueDepth         = "queue.depth"
	MetricQueuePending       = "queue.pending"
	MetricQueueLag           = "queue.lag"
	MetricImageProcessing    = "image.processing.duration"
	MetricDemoFaults         = "demo.faults.injected"
	MetricSpansEnded         = "telemetry.spans.ended"
	MetricSpansExported      = "telemetry.spans.exported"
)

// Attribute keys the app defines (semconv keys come from the semconv package).
const (
	AttrOutcome          = "outcome"
	AttrCacheName        = "cache.name"
	AttrCacheResult      = "cache.result"
	AttrSettingsOp       = "settings.operation"
	AttrSettingsSource   = "settings.source"
	AttrStorageProvider  = "storage.provider"
	AttrStorageOperation = "storage.operation"
	AttrStorageDirection = "storage.direction"
	AttrStorageKey       = "storage.key"
	AttrImageID          = "image.id"
	AttrImageContentType = "image.content_type"
	AttrProcessingStep   = "image.processing.step"
	AttrJobType          = "job.type"
	AttrJobAttempt       = "job.attempt"
	AttrDemoFault        = "demo.fault"
)

// Outcome values used across counters.
const (
	OutcomeSuccess    = "success"
	OutcomeError      = "error"
	OutcomeFailure    = "failure"
	OutcomeRetry      = "retry"
	OutcomeDeadLetter = "dead_letter"
	OutcomeSkipped    = "skipped"
)

// ExpectedInstruments is the per-role contract asserted end to end (Go runtime
// metrics from the contrib package are asserted separately).
var ExpectedInstruments = map[string][]string{
	"web": {
		MetricHTTPServerDuration, MetricHTTPServerActive, MetricHTTPServerRespSize,
		MetricImageUploads, MetricImageDeletions, MetricCacheLookups, MetricSettingsOps,
		MetricStorageOps, MetricStorageDuration, MetricStorageTransferred,
		MetricMessagingSent, MetricDemoFaults, MetricSpansEnded, MetricSpansExported,
	},
	"worker": {
		MetricStorageOps, MetricStorageDuration, MetricStorageTransferred,
		MetricMessagingProcess, MetricWorkerJobs, MetricQueueDepth, MetricQueuePending,
		MetricQueueLag, MetricImageProcessing, MetricDemoFaults, MetricSpansEnded, MetricSpansExported,
	},
}

// RuntimeInstruments are emitted by go.opentelemetry.io/contrib/instrumentation/runtime.
var RuntimeInstruments = []string{"go.memory.used", "go.memory.limit", "go.goroutine.count"}
```

- [ ] **Step 3: Write the failing tests.** Create `internal/observability/provider_test.go`:

```go
package observability

import (
	"context"
	"testing"

	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	sdkmetric "go.opentelemetry.io/otel/sdk/metric"
	"go.opentelemetry.io/otel/sdk/metric/metricdata"
	"go.opentelemetry.io/otel/sdk/trace/tracetest"
)

func testConfig() Config {
	return Config{
		ServiceName: "xplane-image-gallery", ServiceVersion: "2.0.0", Environment: "test",
		PodName: "web-0", PodNamespace: "apps",
		TracesEnabled: true, TracesEndpoint: "http://unused", TracesSampler: SamplerAlwaysOn, TracesSamplerArg: "1.0",
		MetricsEnabled: true, MetricsEndpoint: "http://unused",
	}
}

func sumCounter(t *testing.T, rm metricdata.ResourceMetrics, name string, match attribute.KeyValue) int64 {
	t.Helper()
	var total int64
	for _, sm := range rm.ScopeMetrics {
		for _, m := range sm.Metrics {
			if m.Name != name {
				continue
			}
			for _, dp := range m.Data.(metricdata.Sum[int64]).DataPoints {
				if match.Key == "" || dp.Attributes.HasValue(match.Key) && dp.Attributes.Equivalent() == attribute.NewSet(match).Equivalent() {
					total += dp.Value
				}
			}
		}
	}
	return total
}

func metricNames(rm metricdata.ResourceMetrics) map[string]bool {
	names := map[string]bool{}
	for _, sm := range rm.ScopeMetrics {
		for _, m := range sm.Metrics {
			names[m.Name] = true
		}
	}
	return names
}

func TestProviderCountsEndedAndExportedSpans(t *testing.T) {
	ctx := context.Background()
	exp := tracetest.NewInMemoryExporter()
	reader := sdkmetric.NewManualReader()
	p, err := NewProviderWith(ctx, testConfig(), nil, exp, reader)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = p.Shutdown(ctx) }()

	tr := otel.Tracer("test")
	for i := 0; i < 3; i++ {
		_, span := tr.Start(ctx, "op")
		span.End()
	}
	if err := p.ForceFlush(ctx); err != nil {
		t.Fatal(err)
	}

	var rm metricdata.ResourceMetrics
	if err := reader.Collect(ctx, &rm); err != nil {
		t.Fatal(err)
	}
	if got := sumCounter(t, rm, MetricSpansEnded, attribute.KeyValue{}); got != 3 {
		t.Fatalf("%s = %d, want 3", MetricSpansEnded, got)
	}
	if got := sumCounter(t, rm, MetricSpansExported, attribute.String(AttrOutcome, OutcomeSuccess)); got != 3 {
		t.Fatalf("%s{outcome=success} = %d, want 3", MetricSpansExported, got)
	}
	if n := len(exp.GetSpans()); n != 3 {
		t.Fatalf("exported spans = %d, want 3", n)
	}
	for _, name := range RuntimeInstruments {
		if !metricNames(rm)[name] {
			t.Errorf("runtime metric %q missing", name)
		}
	}
	res := exp.GetSpans()[0].Resource
	for _, want := range []attribute.KeyValue{
		attribute.String("k8s.pod.name", "web-0"),
		attribute.String("k8s.namespace.name", "apps"),
		attribute.String("deployment.environment.name", "test"),
	} {
		if v, ok := res.Set().Value(want.Key); !ok || v != want.Value {
			t.Errorf("resource %s = %v, want %v", want.Key, v, want.Value)
		}
	}
}
```

Create `internal/observability/logger_test.go`:

```go
package observability

import (
	"bytes"
	"context"
	"encoding/json"
	"testing"

	sdktrace "go.opentelemetry.io/otel/sdk/trace"
)

func TestLoggerCarriesServiceNameAndTraceIDs(t *testing.T) {
	var buf bytes.Buffer
	l := NewLoggerTo(&buf, Config{ServiceName: "xplane-image-gallery-worker", LogLevel: "info", LogFormat: "json"})
	tp := sdktrace.NewTracerProvider()
	ctx, span := tp.Tracer("t").Start(context.Background(), "op")
	l.Info(ctx).Msg("hello")
	span.End()

	var line map[string]any
	if err := json.Unmarshal(buf.Bytes(), &line); err != nil {
		t.Fatalf("not JSON: %q", buf.String())
	}
	if line["service.name"] != "xplane-image-gallery-worker" {
		t.Errorf("service.name = %v", line["service.name"])
	}
	if line["trace_id"] != span.SpanContext().TraceID().String() || line["span_id"] == nil {
		t.Errorf("trace correlation missing: %v", line)
	}
}
```

- [ ] **Step 4: Confirm the tests fail.**

Run: `go test ./internal/observability/ -run 'TestProviderCounts|TestLoggerCarries' -v`
Expected: FAIL to compile, with `undefined: NewProviderWith`, unknown fields `PodName`/`PodNamespace`, and `undefined: NewLoggerTo`.

- [ ] **Step 5: Create `internal/observability/spancount.go`.**

```go
package observability

import (
	"context"

	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/metric"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
)

// spanEndCounter counts every recording span that ends. With countingExporter
// it turns the BatchSpanProcessor's silent queue-full drops into a metric:
//
//	dropped ratio = 1 - telemetry.spans.exported{outcome="success"} / telemetry.spans.ended
type spanEndCounter struct{ ended metric.Int64Counter }

func (c spanEndCounter) OnStart(context.Context, sdktrace.ReadWriteSpan) {}
func (c spanEndCounter) OnEnd(s sdktrace.ReadOnlySpan) {
	if s.SpanContext().IsSampled() {
		// Background, not the span's context: counting must not attach exemplars.
		c.ended.Add(context.Background(), 1)
	}
}
func (c spanEndCounter) Shutdown(context.Context) error   { return nil }
func (c spanEndCounter) ForceFlush(context.Context) error { return nil }

// countingExporter counts the spans handed to the real exporter, by outcome.
type countingExporter struct {
	sdktrace.SpanExporter
	exported metric.Int64Counter
}

func (e countingExporter) ExportSpans(ctx context.Context, spans []sdktrace.ReadOnlySpan) error {
	err := e.SpanExporter.ExportSpans(ctx, spans)
	outcome := OutcomeSuccess
	if err != nil {
		outcome = OutcomeFailure
	}
	e.exported.Add(context.Background(), int64(len(spans)), metric.WithAttributes(attribute.String(AttrOutcome, outcome)))
	return err
}
```

- [ ] **Step 6: Rewrite the construction in `provider.go`.** Replace `NewProvider`, `initTracerProvider` and `initMeterProvider` with the code below. Keep `createSampler`, `createExponentialHistogramView`, `Tracer`, `Meter`, `Shutdown` and `ForceFlush` as they are. Add the imports `go.opentelemetry.io/contrib/instrumentation/runtime`, `go.opentelemetry.io/otel/attribute` and `semconv "go.opentelemetry.io/otel/semconv/v1.43.0"`.

```go
// telemetryScope is the meter scope for the SDK self-observation counters.
const telemetryScope = "image-gallery/telemetry"

// NewProvider builds OTLP/HTTP exporters from config and wires the SDK.
func NewProvider(ctx context.Context, config Config, logger *Logger) (*Provider, error) {
	if err := config.Validate(); err != nil {
		return nil, fmt.Errorf("invalid config: %w", err)
	}
	var traceExp sdktrace.SpanExporter
	if config.TracesEnabled {
		exp, err := otlptracehttp.New(ctx, otlptracehttp.WithEndpointURL(config.TracesEndpoint))
		if err != nil {
			return nil, fmt.Errorf("failed to create trace exporter: %w", err)
		}
		traceExp = exp
	}
	var reader sdkmetric.Reader
	if config.MetricsEnabled {
		exp, err := otlpmetrichttp.New(ctx, otlpmetrichttp.WithEndpointURL(config.MetricsEndpoint))
		if err != nil {
			return nil, fmt.Errorf("failed to create metric exporter: %w", err)
		}
		reader = sdkmetric.NewPeriodicReader(exp, sdkmetric.WithInterval(15*time.Second))
	}
	return NewProviderWith(ctx, config, logger, traceExp, reader)
}

// NewProviderWith wires the SDK around a span exporter and a metric reader; a nil
// one disables that signal. Metrics come first so the span counters exist
// before the first span ends.
func NewProviderWith(ctx context.Context, config Config, logger *Logger, traceExp sdktrace.SpanExporter, reader sdkmetric.Reader) (*Provider, error) {
	if logger != nil {
		otel.SetErrorHandler(otel.ErrorHandlerFunc(logger.OTELErrorHandler()))
	}
	res, err := buildResource(ctx, config)
	if err != nil {
		return nil, fmt.Errorf("failed to create resource: %w", err)
	}
	p := &Provider{config: config}

	if reader != nil {
		p.meterProvider = sdkmetric.NewMeterProvider(
			sdkmetric.WithResource(res),
			sdkmetric.WithReader(reader),
			sdkmetric.WithExemplarFilter(exemplar.TraceBasedFilter),
			sdkmetric.WithView(createExponentialHistogramView()),
		)
		otel.SetMeterProvider(p.meterProvider)
		// Go runtime metrics (go.memory.used, go.memory.limit, go.goroutine.count, …): the saturation/OOM story.
		if err := runtime.Start(runtime.WithMeterProvider(p.meterProvider), runtime.WithMinimumReadMemStatsInterval(15*time.Second)); err != nil {
			return nil, fmt.Errorf("failed to start runtime metrics: %w", err)
		}
	}

	if traceExp != nil {
		meter := otel.Meter(telemetryScope) // no-op when metrics are disabled
		ended, err := meter.Int64Counter(MetricSpansEnded, metric.WithUnit("{span}"), metric.WithDescription("Sampled spans that ended"))
		if err != nil {
			return nil, err
		}
		exported, err := meter.Int64Counter(MetricSpansExported, metric.WithUnit("{span}"), metric.WithDescription("Spans handed to the exporter, by outcome"))
		if err != nil {
			return nil, err
		}
		sampler, err := createSampler(config)
		if err != nil {
			return nil, fmt.Errorf("failed to create sampler: %w", err)
		}
		// Queue sized for 100 % sampling at 25 req/s (~20 spans/request => ~500 spans/s):
		// 8192 spans is ~16 s of headroom, a bounded few MiB; overflow is counted, not hidden.
		p.tracerProvider = sdktrace.NewTracerProvider(
			sdktrace.WithResource(res),
			sdktrace.WithSampler(sampler),
			sdktrace.WithSpanProcessor(spanEndCounter{ended: ended}),
			sdktrace.WithBatcher(countingExporter{SpanExporter: traceExp, exported: exported},
				sdktrace.WithBatchTimeout(time.Second),
				sdktrace.WithMaxExportBatchSize(1024),
				sdktrace.WithMaxQueueSize(8192),
				sdktrace.WithExportTimeout(10*time.Second),
			),
		)
		otel.SetTracerProvider(p.tracerProvider)
	}

	otel.SetTextMapPropagator(propagation.NewCompositeTextMapPropagator(propagation.TraceContext{}, propagation.Baggage{}))
	return p, nil
}

func buildResource(ctx context.Context, c Config) (*resource.Resource, error) {
	attrs := []attribute.KeyValue{
		semconv.ServiceName(c.ServiceName),
		semconv.ServiceVersion(c.ServiceVersion),
		semconv.DeploymentEnvironmentNameKey.String(c.Environment),
	}
	if c.PodName != "" {
		attrs = append(attrs, semconv.K8SPodName(c.PodName))
	}
	if c.PodNamespace != "" {
		attrs = append(attrs, semconv.K8SNamespaceName(c.PodNamespace))
	}
	return resource.New(ctx,
		resource.WithAttributes(attrs...),
		resource.WithFromEnv(), // OTEL_RESOURCE_ATTRIBUTES, e.g. cloud.provider=gcp from the cluster patch
		resource.WithTelemetrySDK(),
		resource.WithHost(),
		resource.WithProcess(),
	)
}
```

- [ ] **Step 7: Add the config fields and the logger seam.**
  - `internal/observability/config.go`: add `PodName string` and `PodNamespace string` to `Config` under "Service identification". In `LoadConfig`, add `PodName: os.Getenv("POD_NAME"), PodNamespace: os.Getenv("POD_NAMESPACE")`, and make `Environment` read `getEnv("OTEL_DEPLOYMENT_ENVIRONMENT", getEnv("GO_ENV", "development"))`.
  - `internal/config/config.go`: add `Environment`, `PodName` and `PodNamespace string` to `ObservabilityConfig`. In `Load()`'s `Observability: ObservabilityConfig{…}` literal, set them from `OTEL_DEPLOYMENT_ENVIRONMENT` (default: the `GO_ENV` value), `POD_NAME` and `POD_NAMESPACE`.
  - `cmd/server/main.go`: in the `observability.Config{…}` literal, set `Environment: cfg.Observability.Environment, PodName: cfg.Observability.PodName, PodNamespace: cfg.Observability.PodNamespace`.
  - `internal/observability/logger.go`: split `NewLogger` so the writer is injectable, and rename the base fields to the OTel keys.

```go
// NewLogger writes JSON (or console) logs to stdout.
func NewLogger(config Config) *Logger { return NewLoggerTo(os.Stdout, config) }

// NewLoggerTo writes to w; tests pass a buffer.
func NewLoggerTo(w io.Writer, config Config) *Logger {
	var output io.Writer = w
	if config.LogFormat == "console" {
		output = zerolog.ConsoleWriter{Out: w, TimeFormat: time.RFC3339}
	}
	baseLogger := zerolog.New(output).
		Level(parseLogLevel(config.LogLevel)).
		With().
		Timestamp().
		Str("service.name", config.ServiceName).
		Str("service.version", config.ServiceVersion).
		Str("deployment.environment.name", config.Environment).
		Logger()
	return &Logger{logger: baseLogger}
}
```

- [ ] **Step 8: Run the tests and the whole suite.**

Run: `go test ./internal/observability/ -v -run 'TestProviderCounts|TestLoggerCarries' && go build ./... && go vet ./... && go test -short ./...`
Expected: both new tests PASS, and every existing short test passes. Fix `config_test.go` expectations only where they asserted the old logger field names.

- [ ] **Step 9: Commit.**

```bash
git add go.mod go.sum internal/observability internal/config cmd/server/main.go $(git diff --name-only -- '*.go')
git commit -m "feat(observability): current OTel SDK, span-drop counters and Go runtime metrics" \
  -m "OTel Go SDK v1.46.0 / semconv v1.43.0. telemetry.spans.ended and telemetry.spans.exported make BatchSpanProcessor drops measurable; the queue is sized for 100 % sampling. Resources carry k8s.pod.name, k8s.namespace.name and deployment.environment.name; logs use service.name."
```


### Task 6: HTTP server instrumentation that continues the caller's trace

The current `TracingMiddleware` never extracts `traceparent`, so a load-generator trace breaks at the web tier. It also uses the raw URL path as `http.route`: every image ID mints a new span name and a new exponential-histogram series, which is a memory cost at load. The fix is one middleware.

**Files:**
- Modify (full rewrite): `internal/observability/middleware.go`.
- Modify: `internal/web/handlers/handlers.go` (`Routes()`) and `internal/web/handlers/upload.go` (the span kind).
- Test: `internal/observability/middleware_test.go`.

**Interfaces:**
- Consumes: `MetricHTTPServerDuration`, `MetricHTTPServerActive` and `MetricHTTPServerRespSize` (Task 5).
- Produces:
  - `func Middleware(tracer trace.Tracer, metrics *HTTPMetrics) func(http.Handler) http.Handler`;
  - `func NewHTTPMetrics(meter metric.Meter) (*HTTPMetrics, error)`, the same signature;
  - `GetTracer()` and `GetMeter()`, unchanged.
  - `TracingMiddleware` and `MetricsMiddleware` are removed.

- [ ] **Step 1: Write the failing test.** Create `internal/observability/middleware_test.go`:

```go
package observability

import (
	"context"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/go-chi/chi/v5"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/propagation"
	sdkmetric "go.opentelemetry.io/otel/sdk/metric"
	"go.opentelemetry.io/otel/sdk/metric/metricdata"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
	"go.opentelemetry.io/otel/sdk/trace/tracetest"
	"go.opentelemetry.io/otel/trace"
)

func newTestRouter(t *testing.T) (http.Handler, *tracetest.InMemoryExporter, *sdkmetric.ManualReader) {
	t.Helper()
	otel.SetTextMapPropagator(propagation.TraceContext{})
	exp := tracetest.NewInMemoryExporter()
	tp := sdktrace.NewTracerProvider(sdktrace.WithSyncer(exp))
	reader := sdkmetric.NewManualReader()
	mp := sdkmetric.NewMeterProvider(sdkmetric.WithReader(reader))
	metrics, err := NewHTTPMetrics(mp.Meter("test"))
	if err != nil {
		t.Fatal(err)
	}
	r := chi.NewRouter()
	r.Use(Middleware(tp.Tracer("test"), metrics))
	r.Route("/api", func(r chi.Router) {
		r.Get("/images/{id}", func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(http.StatusOK) })
	})
	return r, exp, reader
}

func TestMiddlewareContinuesIncomingTrace(t *testing.T) {
	h, exp, _ := newTestRouter(t)
	req := httptest.NewRequest(http.MethodGet, "/api/images/42", nil)
	req.Header.Set("traceparent", "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01") // pragma: allowlist secret
	h.ServeHTTP(httptest.NewRecorder(), req)

	spans := exp.GetSpans()
	if len(spans) != 1 {
		t.Fatalf("spans = %d, want 1", len(spans))
	}
	s := spans[0]
	if s.SpanContext.TraceID().String() != "4bf92f3577b34da6a3ce929d0e0e4736" { // pragma: allowlist secret
		t.Errorf("trace not continued: %s", s.SpanContext.TraceID())
	}
	if s.Parent.SpanID().String() != "00f067aa0ba902b7" {
		t.Errorf("parent = %s", s.Parent.SpanID())
	}
	if s.Name != "GET /api/images/{id}" || s.SpanKind != trace.SpanKindServer {
		t.Errorf("name=%q kind=%v", s.Name, s.SpanKind)
	}
}

func TestMiddlewareMetricsUseRoutePatternNotPath(t *testing.T) {
	h, _, reader := newTestRouter(t)
	for _, p := range []string{"/api/images/1", "/api/images/2", "/nope"} {
		h.ServeHTTP(httptest.NewRecorder(), httptest.NewRequest(http.MethodGet, p, nil))
	}
	var rm metricdata.ResourceMetrics
	if err := reader.Collect(context.Background(), &rm); err != nil {
		t.Fatal(err)
	}
	routes := map[string]uint64{}
	for _, sm := range rm.ScopeMetrics {
		for _, m := range sm.Metrics {
			if m.Name == "http.server.request.count" {
				t.Errorf("non-semconv http.server.request.count must be gone")
			}
			if m.Name != MetricHTTPServerDuration {
				continue
			}
			for _, dp := range m.Data.(metricdata.Histogram[float64]).DataPoints {
				v, _ := dp.Attributes.Value("http.route")
				routes[v.AsString()] += dp.Count
			}
		}
	}
	if routes["/api/images/{id}"] != 2 || routes["unmatched"] != 1 || len(routes) != 2 {
		t.Errorf("routes = %v, want {/api/images/{id}:2, unmatched:1}", routes)
	}
}
```

- [ ] **Step 2: Run it and confirm it fails.**

Run: `go test ./internal/observability/ -run TestMiddleware -v`
Expected: FAIL to compile with `undefined: Middleware`.

- [ ] **Step 3: Rewrite `internal/observability/middleware.go`.** If `instrumentationName`, `healthzPath` or `readyzPath` are declared in another file of the package, delete those declarations below instead of redeclaring them.

```go
package observability

import (
	"net/http"
	"time"

	"github.com/go-chi/chi/v5"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/codes"
	"go.opentelemetry.io/otel/metric"
	"go.opentelemetry.io/otel/propagation"
	semconv "go.opentelemetry.io/otel/semconv/v1.43.0"
	"go.opentelemetry.io/otel/trace"
)

const (
	instrumentationName = "image-gallery/http"
	healthzPath         = "/healthz"
	readyzPath          = "/readyz"
	unmatchedRoute      = "unmatched"
)

// HTTPMetrics holds the semconv HTTP server instruments.
type HTTPMetrics struct {
	duration metric.Float64Histogram
	active   metric.Int64UpDownCounter
	respSize metric.Int64Histogram
}

// NewHTTPMetrics registers the HTTP server instruments on meter.
func NewHTTPMetrics(meter metric.Meter) (*HTTPMetrics, error) {
	duration, err := meter.Float64Histogram(MetricHTTPServerDuration,
		metric.WithDescription("Duration of HTTP server requests"), metric.WithUnit("s"))
	if err != nil {
		return nil, err
	}
	active, err := meter.Int64UpDownCounter(MetricHTTPServerActive,
		metric.WithDescription("Number of in-flight HTTP server requests"), metric.WithUnit("{request}"))
	if err != nil {
		return nil, err
	}
	respSize, err := meter.Int64Histogram(MetricHTTPServerRespSize,
		metric.WithDescription("Size of HTTP server response bodies"), metric.WithUnit("By"))
	if err != nil {
		return nil, err
	}
	return &HTTPMetrics{duration: duration, active: active, respSize: respSize}, nil
}

// responseWriter captures the status code and body size.
type responseWriter struct {
	http.ResponseWriter
	statusCode   int
	bytesWritten int64
}

func (rw *responseWriter) WriteHeader(statusCode int) {
	rw.statusCode = statusCode
	rw.ResponseWriter.WriteHeader(statusCode)
}

func (rw *responseWriter) Write(b []byte) (int, error) {
	n, err := rw.ResponseWriter.Write(b)
	rw.bytesWritten += int64(n)
	return n, err
}

// Middleware is the only HTTP server instrumentation. It continues the caller's
// trace (W3C traceparent), names the span after the chi route pattern once
// routing is done, and records RED metrics keyed by that pattern. It never keys
// by the raw path: per-image IDs made every URL its own span name and series.
// metrics may be nil (metrics disabled).
func Middleware(tracer trace.Tracer, metrics *HTTPMetrics) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if r.URL.Path == healthzPath || r.URL.Path == readyzPath {
				next.ServeHTTP(w, r)
				return
			}
			ctx := otel.GetTextMapPropagator().Extract(r.Context(), propagation.HeaderCarrier(r.Header))
			method := semconv.HTTPRequestMethodKey.String(r.Method)
			ctx, span := tracer.Start(ctx, r.Method,
				trace.WithSpanKind(trace.SpanKindServer),
				trace.WithAttributes(method,
					semconv.URLPath(r.URL.Path),
					semconv.UserAgentOriginal(r.UserAgent()),
					semconv.ClientAddress(r.RemoteAddr)),
			)
			defer span.End()
			if metrics != nil {
				metrics.active.Add(ctx, 1, metric.WithAttributes(method))
				defer metrics.active.Add(ctx, -1, metric.WithAttributes(method))
			}

			rw := &responseWriter{ResponseWriter: w, statusCode: http.StatusOK}
			start := time.Now()
			next.ServeHTTP(rw, r.WithContext(ctx))

			route := routePattern(r)
			attrs := []attribute.KeyValue{method, semconv.HTTPRoute(route), semconv.HTTPResponseStatusCode(rw.statusCode)}
			span.SetName(r.Method + " " + route)
			span.SetAttributes(semconv.HTTPRoute(route), semconv.HTTPResponseStatusCode(rw.statusCode),
				semconv.HTTPResponseBodySize(int(rw.bytesWritten)))
			if rw.statusCode >= http.StatusInternalServerError {
				span.SetStatus(codes.Error, http.StatusText(rw.statusCode))
			}
			if metrics != nil {
				metrics.duration.Record(ctx, time.Since(start).Seconds(), metric.WithAttributes(attrs...))
				metrics.respSize.Record(ctx, rw.bytesWritten, metric.WithAttributes(attrs...))
			}
		})
	}
}

// routePattern is the matched chi pattern (complete once routing returned), or
// "unmatched" so that 404s cannot mint one series per path. The route context
// is shared by pointer with the request chi routed, so it is filled here.
func routePattern(r *http.Request) string {
	if rc := chi.RouteContext(r.Context()); rc != nil {
		if p := rc.RoutePattern(); p != "" {
			return p
		}
	}
	return unmatchedRoute
}

// GetTracer returns the HTTP instrumentation tracer.
func GetTracer() trace.Tracer { return otel.Tracer(instrumentationName) }

// GetMeter returns the HTTP instrumentation meter.
func GetMeter() metric.Meter { return otel.Meter(instrumentationName) }
```

If one of the `semconv` helpers (`URLPath`, `UserAgentOriginal`, `ClientAddress` or `HTTPResponseBodySize`) does not exist in v1.43.0, fall back to `attribute.String` or `attribute.Int` with the same semconv key (`url.path`, `user_agent.original`, `client.address`, `http.response.body.size`).

- [ ] **Step 4: Wire it into the router.** In `internal/web/handlers/handlers.go` `Routes()`, replace the two `if h.tracer != nil { r.Use(observability.TracingMiddleware(...)) }` / `if h.httpMetrics != nil { r.Use(observability.MetricsMiddleware(...)) }` blocks with:

```go
	// One middleware: trace continuation, route-pattern span names, semconv RED metrics.
	r.Use(observability.Middleware(h.tracer, h.httpMetrics))
```

In `internal/web/handlers/upload.go`, change `h.tracer.Start(ctx, "UploadImages", trace.WithSpanKind(trace.SpanKindServer))` to `h.tracer.Start(ctx, "UploadImages")`. It is a child of the server span now, not a second server span.

- [ ] **Step 5: Run the tests and confirm they pass.**

Run: `go test ./internal/observability/ ./internal/web/... -short -v -run 'TestMiddleware|Upload'`
Expected: PASS.

- [ ] **Step 6: Commit.**

```bash
git add internal/observability/middleware.go internal/observability/middleware_test.go internal/web/handlers/handlers.go internal/web/handlers/upload.go
git commit -m "fix(observability): continue incoming traces and key HTTP telemetry by route pattern" \
  -m "The server middleware never extracted traceparent, so client traces broke at the web tier, and it used the raw path as http.route, minting a series per image ID. Metrics follow semconv: http.server.request.count is gone (use the duration histogram's count)." \
  -m "BREAKING CHANGE: http.server.request.count and http.server.response.size are replaced by the semconv http.server.request.duration count and http.server.response.body.size."
```

### Task 7: Object stores for S3 and GCS behind one interface

**Files:**
- Create: `internal/platform/storage/objectstore.go`, `s3store.go` and `gcsstore.go`.
- Create: `internal/platform/storage/storetest/contract.go`.
- Test: `internal/platform/storage/s3store_test.go` and `internal/platform/storage/gcsstore_test.go`.
- Modify: `internal/config/config.go` (`StorageConfig.Provider`, `STORAGE_PROVIDER`), `internal/config/validation_methods.go` and `internal/config/config_test.go`.
- Modify: `go.mod` (add `cloud.google.com/go/storage@v1.67.1`).

**Interfaces:**
- Consumes: `storage.ObjectInfo` (already in `service.go`: `Key`, `Size`, `ContentType`, `LastModified time.Time`, `ETag`, `UserMetadata map[string]string`) and the `noSuchKeyError` constant (already in `service.go`).
- Produces (Task 8 relies on all of these):

```go
type ObjectStore interface {
	Provider() string
	Put(ctx context.Context, key, contentType string, r io.Reader, size int64, metadata map[string]string) error
	Get(ctx context.Context, key string) (io.ReadCloser, error) // ErrNotFound if missing
	Stat(ctx context.Context, key string) (ObjectInfo, error)   // ErrNotFound if missing
	Delete(ctx context.Context, key string) error               // idempotent: missing => nil
	List(ctx context.Context, prefix string, max int) ([]ObjectInfo, error)
	Health(ctx context.Context) error
}
var ErrNotFound error
const ProviderS3, ProviderGCS = "s3", "gcs"
func NewObjectStore(ctx context.Context, cfg config.StorageConfig) (ObjectStore, error)
func NewS3Store(ctx context.Context, cfg config.StorageConfig) (*S3Store, error)
func NewGCSStore(ctx context.Context, bucket string, opts ...option.ClientOption) (*GCSStore, error)
```

In `config.StorageConfig`: `Provider string // STORAGE_PROVIDER: "s3" (default) or "gcs"`. User-metadata keys are lower-cased by both backends.

- [ ] **Step 1: Write the contract.** Create `internal/platform/storage/storetest/contract.go`:

```go
// Package storetest is the behavioural contract every storage.ObjectStore
// backend must pass, so S3 and GCS cannot drift apart.
package storetest

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"testing"
	"time"

	"image-gallery/internal/platform/storage"
)

// Run exercises Put/Stat/Get/List/Delete/Health against s.
func Run(t *testing.T, s storage.ObjectStore) {
	t.Helper()
	ctx := context.Background()
	key := fmt.Sprintf("contract/%d.txt", time.Now().UnixNano())
	body := []byte("hello object store")

	if err := s.Put(ctx, key, "text/plain", bytes.NewReader(body), int64(len(body)),
		map[string]string{"original-filename": "a b.txt"}); err != nil {
		t.Fatalf("Put: %v", err)
	}
	info, err := s.Stat(ctx, key)
	if err != nil {
		t.Fatalf("Stat: %v", err)
	}
	if info.Size != int64(len(body)) || info.ContentType != "text/plain" {
		t.Errorf("Stat = size %d type %q", info.Size, info.ContentType)
	}
	if got := info.UserMetadata["original-filename"]; got != "a b.txt" {
		t.Errorf("metadata original-filename = %q (keys must be lower-cased)", got)
	}
	rc, err := s.Get(ctx, key)
	if err != nil {
		t.Fatalf("Get: %v", err)
	}
	got, _ := io.ReadAll(rc)
	_ = rc.Close()
	if !bytes.Equal(got, body) {
		t.Errorf("Get body = %q", got)
	}
	list, err := s.List(ctx, "contract/", 100)
	if err != nil {
		t.Fatalf("List: %v", err)
	}
	found := false
	for _, o := range list {
		found = found || o.Key == key
	}
	if !found {
		t.Errorf("List did not return %s", key)
	}
	if _, err := s.Stat(ctx, "contract/missing"); !errors.Is(err, storage.ErrNotFound) {
		t.Errorf("Stat(missing) = %v, want ErrNotFound", err)
	}
	if _, err := s.Get(ctx, "contract/missing"); !errors.Is(err, storage.ErrNotFound) {
		t.Errorf("Get(missing) = %v, want ErrNotFound", err)
	}
	if err := s.Delete(ctx, key); err != nil {
		t.Fatalf("Delete: %v", err)
	}
	if _, err := s.Stat(ctx, key); !errors.Is(err, storage.ErrNotFound) {
		t.Errorf("Stat after Delete = %v, want ErrNotFound", err)
	}
	if err := s.Delete(ctx, key); err != nil {
		t.Errorf("Delete must be idempotent, got %v", err)
	}
	if err := s.Health(ctx); err != nil {
		t.Errorf("Health: %v", err)
	}
}
```

- [ ] **Step 2: Write the backend tests.** They are integration tests, skipped under `-short`.

`internal/platform/storage/s3store_test.go`:

```go
package storage_test

import (
	"context"
	"testing"

	tcminio "github.com/testcontainers/testcontainers-go/modules/minio"
	"github.com/testcontainers/testcontainers-go"

	"image-gallery/internal/config"
	"image-gallery/internal/platform/storage"
	"image-gallery/internal/platform/storage/storetest"
)

func TestS3StoreContract(t *testing.T) {
	if testing.Short() {
		t.Skip("integration test")
	}
	ctx := context.Background()
	c, err := tcminio.Run(ctx, "minio/minio:latest", tcminio.WithUsername("testuser"), tcminio.WithPassword("testpass123")) // pragma: allowlist secret
	testcontainers.CleanupContainer(t, c)
	if err != nil {
		t.Fatal(err)
	}
	endpoint, err := c.ConnectionString(ctx)
	if err != nil {
		t.Fatal(err)
	}
	s, err := storage.NewS3Store(ctx, config.StorageConfig{
		Provider: storage.ProviderS3, Endpoint: endpoint, AccessKeyID: "testuser", SecretAccessKey: "testpass123", // pragma: allowlist secret
		BucketName: "contract", Region: "us-east-1",
	})
	if err != nil {
		t.Fatal(err)
	}
	if s.Provider() != storage.ProviderS3 {
		t.Fatalf("provider = %s", s.Provider())
	}
	storetest.Run(t, s)
}
```

`internal/platform/storage/gcsstore_test.go`. Pin the fake-gcs-server image to the newest release tag: run `gh api repos/fsouza/fake-gcs-server/releases/latest --jq .tag_name`, strip the leading `v`, and put it in `fakeGCSImage`.

```go
package storage_test

import (
	"context"
	"strings"
	"testing"

	gcs "cloud.google.com/go/storage"
	"github.com/testcontainers/testcontainers-go"
	"github.com/testcontainers/testcontainers-go/wait"

	"image-gallery/internal/platform/storage"
	"image-gallery/internal/platform/storage/storetest"
)

const fakeGCSImage = "fsouza/fake-gcs-server:1.52.2"

func TestGCSStoreContract(t *testing.T) {
	if testing.Short() {
		t.Skip("integration test")
	}
	ctx := context.Background()
	c, err := testcontainers.GenericContainer(ctx, testcontainers.GenericContainerRequest{
		ContainerRequest: testcontainers.ContainerRequest{
			Image:        fakeGCSImage,
			ExposedPorts: []string{"4443/tcp"},
			Cmd:          []string{"-scheme", "http", "-port", "4443", "-backend", "memory"},
			WaitingFor:   wait.ForHTTP("/storage/v1/b").WithPort("4443/tcp"),
		},
		Started: true,
	})
	testcontainers.CleanupContainer(t, c)
	if err != nil {
		t.Fatal(err)
	}
	endpoint, err := c.PortEndpoint(ctx, "4443/tcp", "http")
	if err != nil {
		t.Fatal(err)
	}
	// The Go client routes every call to the emulator, unauthenticated, when this is set.
	t.Setenv("STORAGE_EMULATOR_HOST", strings.TrimPrefix(endpoint, "http://"))

	admin, err := gcs.NewClient(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer admin.Close()
	if err := admin.Bucket("contract").Create(ctx, "test-project", nil); err != nil {
		t.Fatal(err)
	}
	s, err := storage.NewGCSStore(ctx, "contract", gcs.WithJSONReads())
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	if s.Provider() != storage.ProviderGCS {
		t.Fatalf("provider = %s", s.Provider())
	}
	storetest.Run(t, s)
}
```

- [ ] **Step 3: Run them and confirm they fail.**

Run: `go get cloud.google.com/go/storage@v1.67.1 && go test ./internal/platform/storage/ -run 'StoreContract' -v`
Expected: FAIL to compile with `undefined: storage.NewS3Store`, `storage.NewGCSStore`, `storage.ProviderS3` and the unknown field `Provider`.

- [ ] **Step 4: Add the config field.** In `internal/config/config.go`:
  - add `Provider string // STORAGE_PROVIDER: "s3" (default) or "gcs"` as the first field of `StorageConfig`;
  - in `Load()`, set `Provider: getEnv("STORAGE_PROVIDER", "s3")` in the `Storage: StorageConfig{…}` literal.

  In `internal/config/validation_methods.go`, where the storage config is validated:
  - reject anything other than `s3` and `gcs`;
  - for `gcs`, require `BucketName` and skip the endpoint, SSL and region checks.

  Add these table cases to `config_test.go`: `STORAGE_PROVIDER=gcs` with `STORAGE_BUCKET=b` loads and validates; `STORAGE_PROVIDER=azure` fails validation with a message naming `STORAGE_PROVIDER`.

- [ ] **Step 5: Create `internal/platform/storage/objectstore.go`.**

```go
package storage

import (
	"context"
	"errors"
	"fmt"
	"io"
	"strings"

	"image-gallery/internal/config"
)

// Provider names, also the storage.provider telemetry attribute.
const (
	ProviderS3  = "s3"
	ProviderGCS = "gcs"
)

// ErrNotFound is returned by Get and Stat for a missing key.
var ErrNotFound = errors.New("object not found")

// ObjectStore is the minimal surface both backends implement. Instrumentation
// lives one layer up (implementations.StorageServiceImpl) so S3 and GCS emit
// identical storage.* telemetry, distinguished only by storage.provider.
type ObjectStore interface {
	Provider() string
	Put(ctx context.Context, key, contentType string, r io.Reader, size int64, metadata map[string]string) error
	Get(ctx context.Context, key string) (io.ReadCloser, error)
	Stat(ctx context.Context, key string) (ObjectInfo, error)
	Delete(ctx context.Context, key string) error
	List(ctx context.Context, prefix string, max int) ([]ObjectInfo, error)
	Health(ctx context.Context) error
}

// NewObjectStore picks the backend from STORAGE_PROVIDER.
func NewObjectStore(ctx context.Context, cfg config.StorageConfig) (ObjectStore, error) {
	switch cfg.Provider {
	case "", ProviderS3:
		return NewS3Store(ctx, cfg)
	case ProviderGCS:
		return NewGCSStore(ctx, cfg.BucketName)
	default:
		return nil, fmt.Errorf("unknown STORAGE_PROVIDER %q (want %s or %s)", cfg.Provider, ProviderS3, ProviderGCS)
	}
}

// lowerKeys normalises user-metadata keys: S3 canonicalises them
// (Original-Filename), GCS keeps them verbatim.
func lowerKeys(m map[string]string) map[string]string {
	if len(m) == 0 {
		return nil
	}
	out := make(map[string]string, len(m))
	for k, v := range m {
		out[strings.ToLower(k)] = v
	}
	return out
}
```

- [ ] **Step 6: Create `internal/platform/storage/s3store.go`.**

```go
package storage

import (
	"context"
	"fmt"
	"io"

	"github.com/minio/minio-go/v7"
	"github.com/minio/minio-go/v7/pkg/credentials"

	"image-gallery/internal/config"
)

// S3Store is the S3 backend (AWS S3, or MinIO locally).
type S3Store struct {
	client *minio.Client
	bucket string
}

// NewS3Store connects with static keys when both are set (local MinIO), else
// the IAM chain: EKS Pod Identity on aws-0, unchanged from v1.
func NewS3Store(ctx context.Context, cfg config.StorageConfig) (*S3Store, error) {
	creds := credentials.NewIAM("")
	if cfg.AccessKeyID != "" || cfg.SecretAccessKey != "" {
		creds = credentials.NewStaticV4(cfg.AccessKeyID, cfg.SecretAccessKey, "")
	}
	client, err := minio.New(cfg.Endpoint, &minio.Options{Creds: creds, Secure: cfg.UseSSL, Region: cfg.Region})
	if err != nil {
		return nil, fmt.Errorf("s3 client: %w", err)
	}
	s := &S3Store{client: client, bucket: cfg.BucketName}
	exists, err := client.BucketExists(ctx, s.bucket)
	if err != nil {
		return nil, fmt.Errorf("s3 bucket %s: %w", s.bucket, err)
	}
	if !exists {
		if err := client.MakeBucket(ctx, s.bucket, minio.MakeBucketOptions{Region: cfg.Region}); err != nil {
			return nil, fmt.Errorf("s3 make bucket %s: %w", s.bucket, err)
		}
	}
	return s, nil
}

func (s *S3Store) Provider() string { return ProviderS3 }

func (s *S3Store) Put(ctx context.Context, key, contentType string, r io.Reader, size int64, metadata map[string]string) error {
	// A known size lets minio-go stream instead of buffering a multipart part.
	_, err := s.client.PutObject(ctx, s.bucket, key, r, size, minio.PutObjectOptions{ContentType: contentType, UserMetadata: metadata})
	return err
}

func (s *S3Store) Get(ctx context.Context, key string) (io.ReadCloser, error) {
	obj, err := s.client.GetObject(ctx, s.bucket, key, minio.GetObjectOptions{})
	if err != nil {
		return nil, mapS3Err(err)
	}
	if _, err := obj.Stat(); err != nil { // GetObject is lazy; surface a missing key now
		_ = obj.Close()
		return nil, mapS3Err(err)
	}
	return obj, nil
}

func (s *S3Store) Stat(ctx context.Context, key string) (ObjectInfo, error) {
	st, err := s.client.StatObject(ctx, s.bucket, key, minio.StatObjectOptions{})
	if err != nil {
		return ObjectInfo{}, mapS3Err(err)
	}
	return ObjectInfo{Key: key, Size: st.Size, ContentType: st.ContentType, LastModified: st.LastModified,
		ETag: st.ETag, UserMetadata: lowerKeys(st.UserMetadata)}, nil
}

func (s *S3Store) Delete(ctx context.Context, key string) error {
	return s.client.RemoveObject(ctx, s.bucket, key, minio.RemoveObjectOptions{}) // S3 delete is idempotent
}

func (s *S3Store) List(ctx context.Context, prefix string, max int) ([]ObjectInfo, error) {
	if max <= 0 {
		max = 1000
	}
	out := make([]ObjectInfo, 0)
	for o := range s.client.ListObjects(ctx, s.bucket, minio.ListObjectsOptions{Prefix: prefix, MaxKeys: max, Recursive: true, WithMetadata: true}) {
		if o.Err != nil {
			return nil, fmt.Errorf("s3 list: %w", o.Err)
		}
		out = append(out, ObjectInfo{Key: o.Key, Size: o.Size, ContentType: o.ContentType, LastModified: o.LastModified,
			ETag: o.ETag, UserMetadata: lowerKeys(o.UserMetadata)})
		if len(out) == max {
			break
		}
	}
	return out, nil
}

func (s *S3Store) Health(ctx context.Context) error {
	_, err := s.List(ctx, "", 1)
	return err
}

func mapS3Err(err error) error {
	if minio.ToErrorResponse(err).Code == noSuchKeyError {
		return fmt.Errorf("%w: %v", ErrNotFound, err)
	}
	return err
}
```

- [ ] **Step 7: Create `internal/platform/storage/gcsstore.go`.**

```go
package storage

import (
	"context"
	"errors"
	"fmt"
	"io"

	gcs "cloud.google.com/go/storage"
	"google.golang.org/api/iterator"
	"google.golang.org/api/option"
)

// GCSStore is the Cloud Storage backend. Credentials are Application Default
// Credentials: on GKE, the pod's Workload Identity. No HMAC or JSON keys.
type GCSStore struct {
	client *gcs.Client
	bucket *gcs.BucketHandle
}

// NewGCSStore opens bucket; opts exist for tests (emulator, JSON reads).
func NewGCSStore(ctx context.Context, bucket string, opts ...option.ClientOption) (*GCSStore, error) {
	if bucket == "" {
		return nil, errors.New("STORAGE_BUCKET is required for gcs")
	}
	c, err := gcs.NewClient(ctx, opts...)
	if err != nil {
		return nil, fmt.Errorf("gcs client: %w", err)
	}
	return &GCSStore{client: c, bucket: c.Bucket(bucket)}, nil
}

func (s *GCSStore) Provider() string { return ProviderGCS }

// Put streams r in ONE request with no buffer (ChunkSize 0): bounded memory at
// the cost of transport retries. Files are at most 10 MiB (plan ruling 8).
func (s *GCSStore) Put(ctx context.Context, key, contentType string, r io.Reader, _ int64, metadata map[string]string) error {
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	w := s.bucket.Object(key).NewWriter(ctx)
	w.ContentType = contentType
	w.Metadata = metadata
	w.ChunkSize = 0
	if _, err := io.Copy(w, r); err != nil {
		cancel() // abort: closing after a short read would commit a truncated object
		_ = w.Close()
		return fmt.Errorf("gcs put %s: %w", key, err)
	}
	return w.Close()
}

func (s *GCSStore) Get(ctx context.Context, key string) (io.ReadCloser, error) {
	r, err := s.bucket.Object(key).NewReader(ctx)
	if errors.Is(err, gcs.ErrObjectNotExist) {
		return nil, fmt.Errorf("%w: %s", ErrNotFound, key)
	}
	return r, err
}

func (s *GCSStore) Stat(ctx context.Context, key string) (ObjectInfo, error) {
	a, err := s.bucket.Object(key).Attrs(ctx)
	if errors.Is(err, gcs.ErrObjectNotExist) {
		return ObjectInfo{}, fmt.Errorf("%w: %s", ErrNotFound, key)
	}
	if err != nil {
		return ObjectInfo{}, err
	}
	return attrsToInfo(a), nil
}

func (s *GCSStore) Delete(ctx context.Context, key string) error {
	if err := s.bucket.Object(key).Delete(ctx); err != nil && !errors.Is(err, gcs.ErrObjectNotExist) {
		return err
	}
	return nil
}

func (s *GCSStore) List(ctx context.Context, prefix string, max int) ([]ObjectInfo, error) {
	if max <= 0 {
		max = 1000
	}
	out := make([]ObjectInfo, 0)
	it := s.bucket.Objects(ctx, &gcs.Query{Prefix: prefix})
	for len(out) < max {
		a, err := it.Next()
		if errors.Is(err, iterator.Done) {
			break
		}
		if err != nil {
			return nil, fmt.Errorf("gcs list: %w", err)
		}
		out = append(out, attrsToInfo(a))
	}
	return out, nil
}

// Health lists one object: storage.objects.list is in the bucket-scoped
// objectAdmin grant; storage.buckets.get is not, so no bucket Attrs call here.
func (s *GCSStore) Health(ctx context.Context) error {
	_, err := s.List(ctx, "", 1)
	return err
}

// Close releases the client.
func (s *GCSStore) Close() error { return s.client.Close() }

func attrsToInfo(a *gcs.ObjectAttrs) ObjectInfo {
	return ObjectInfo{Key: a.Name, Size: a.Size, ContentType: a.ContentType, LastModified: a.Updated,
		ETag: a.Etag, UserMetadata: lowerKeys(a.Metadata)}
}
```

- [ ] **Step 8: Run the tests and confirm they pass.**

Run: `go mod tidy && go test ./internal/platform/storage/ ./internal/config/ -run 'StoreContract|Provider' -v`
Expected: PASS for `TestS3StoreContract` and `TestGCSStoreContract`, plus the new config cases. If the GCS read fails against the emulator, keep `gcs.WithJSONReads()` in the test options, as written.

- [ ] **Step 9: Commit.**

```bash
git add go.mod go.sum internal/platform/storage/objectstore.go internal/platform/storage/s3store.go \
        internal/platform/storage/gcsstore.go internal/platform/storage/storetest \
        internal/platform/storage/s3store_test.go internal/platform/storage/gcsstore_test.go internal/config
git commit -m "feat(storage): S3 and GCS object stores behind one interface" \
  -m "STORAGE_PROVIDER=s3|gcs. GCS uses Application Default Credentials (GKE Workload Identity, no HMAC keys) and streams uploads without a buffer. A shared contract test runs against MinIO and fake-gcs-server."
```


### Task 8: Run the storage service on `ObjectStore`, with uniform `storage.*` telemetry

Today the app builds two minio clients (`MinIOClient` and `storage.Service`). `main.go` calls `NewMinIOClient`, which runs `MakeBucket` in `us-east-1` and could never work on GCS. Both go. `storage.Service` keeps its validation and delegates I/O to an `ObjectStore`. `StorageServiceImpl` becomes the single instrumentation point, so both backends emit identical spans and metrics.

**Files:**
- Create: `internal/platform/storage/storetest/memstore.go` (an in-memory `ObjectStore` for unit tests) and `internal/platform/storage/memstore_test.go`.
- Modify: `internal/platform/storage/service.go`.
- Delete: `internal/platform/storage/minio.go`.
- Modify: `internal/domain/image/interfaces.go` (`StorageService`: remove `GenerateURL`, add `StoreAt`; `ImageService`: remove `GenerateImageURL`).
- Modify (rewrite): `internal/services/implementations/storage_service.go`.
- Modify: `internal/services/implementations/image_service.go` (remove `GenerateImageURL`), `internal/services/container.go`, `internal/web/handlers/handlers.go`, `internal/web/handlers/upload.go` and `internal/web/handlers/api.go`.
- Modify: `cmd/server/main.go`, `internal/testutils/containers.go`, and every test that no longer compiles.
- Test: `internal/services/implementations/storage_service_test.go` (new) and `internal/platform/storage/service_test.go` (adapt).

**Interfaces:**
- Consumes: `storage.ObjectStore`, `storage.ErrNotFound` and `storage.NewObjectStore` (Task 7), plus the Task 5 constants.
- Produces:
  - `func storage.NewService(cfg *config.StorageConfig, store ObjectStore) (*Service, error)`;
  - `(*Service).StoreAt(ctx, key, contentType string, data io.Reader, size int64) error`;
  - `(*Service).Provider() string`;
  - `image.StorageService.StoreAt(ctx context.Context, path string, contentType string, data io.Reader, size int64) error`, which Task 13 uses for thumbnails at `thumbnails/<id>.<ext>`;
  - `func implementations.NewStorageService(svc *storage.Service) image.StorageService`, replacing both old constructors;
  - `func services.NewContainerWithObservability(cfg *config.Config, db *sql.DB, store storage.ObjectStore, logger *observability.Logger) (*Container, error)`, the same shape for `NewContainer`/`NewContainerForTest`, and `(*Container).ObjectStore() storage.ObjectStore`, replacing `StorageClient()`;
  - `func storetest.NewMemStore() storage.ObjectStore`, whose provider is `"memory"`.

- [ ] **Step 1: Create the in-memory store.** Create `internal/platform/storage/storetest/memstore.go`:

```go
package storetest

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"sort"
	"strings"
	"sync"
	"time"

	"image-gallery/internal/platform/storage"
)

type memObject struct {
	data []byte
	info storage.ObjectInfo
}

// MemStore is an in-memory storage.ObjectStore for unit tests.
type MemStore struct {
	mu   sync.Mutex
	objs map[string]memObject
}

// NewMemStore returns an empty store whose provider is "memory".
func NewMemStore() *MemStore { return &MemStore{objs: map[string]memObject{}} }

func (m *MemStore) Provider() string { return "memory" }

func (m *MemStore) Put(_ context.Context, key, contentType string, r io.Reader, _ int64, md map[string]string) error {
	b, err := io.ReadAll(r)
	if err != nil {
		return err
	}
	lower := map[string]string{}
	for k, v := range md {
		lower[strings.ToLower(k)] = v
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	m.objs[key] = memObject{data: b, info: storage.ObjectInfo{Key: key, Size: int64(len(b)), ContentType: contentType, LastModified: time.Now(), UserMetadata: lower}}
	return nil
}

func (m *MemStore) Get(_ context.Context, key string) (io.ReadCloser, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	o, ok := m.objs[key]
	if !ok {
		return nil, fmt.Errorf("%w: %s", storage.ErrNotFound, key)
	}
	return io.NopCloser(bytes.NewReader(o.data)), nil
}

func (m *MemStore) Stat(_ context.Context, key string) (storage.ObjectInfo, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	o, ok := m.objs[key]
	if !ok {
		return storage.ObjectInfo{}, fmt.Errorf("%w: %s", storage.ErrNotFound, key)
	}
	return o.info, nil
}

func (m *MemStore) Delete(_ context.Context, key string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	delete(m.objs, key)
	return nil
}

func (m *MemStore) List(_ context.Context, prefix string, max int) ([]storage.ObjectInfo, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	keys := make([]string, 0, len(m.objs))
	for k := range m.objs {
		if strings.HasPrefix(k, prefix) {
			keys = append(keys, k)
		}
	}
	sort.Strings(keys)
	out := make([]storage.ObjectInfo, 0, len(keys))
	for _, k := range keys {
		if max > 0 && len(out) == max {
			break
		}
		out = append(out, m.objs[k].info)
	}
	return out, nil
}

func (m *MemStore) Health(context.Context) error { return nil }
```

And `internal/platform/storage/memstore_test.go`, so the fake itself honours the contract:

```go
package storage_test

import (
	"testing"

	"image-gallery/internal/platform/storage/storetest"
)

func TestMemStoreContract(t *testing.T) { storetest.Run(t, storetest.NewMemStore()) }
```

- [ ] **Step 2: Write the failing instrumentation test.** Create `internal/services/implementations/storage_service_test.go`:

```go
package implementations

import (
	"bytes"
	"context"
	"image"
	"image/color"
	"image/png"
	"io"
	"testing"

	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	sdkmetric "go.opentelemetry.io/otel/sdk/metric"
	"go.opentelemetry.io/otel/sdk/metric/metricdata"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
	"go.opentelemetry.io/otel/sdk/trace/tracetest"
	"go.opentelemetry.io/otel/trace"

	"image-gallery/internal/config"
	"image-gallery/internal/observability"
	"image-gallery/internal/platform/storage"
	"image-gallery/internal/platform/storage/storetest"
)

func tinyPNG(t *testing.T) []byte {
	t.Helper()
	img := image.NewRGBA(image.Rect(0, 0, 4, 4))
	img.Set(1, 1, color.RGBA{R: 255, A: 255})
	var buf bytes.Buffer
	if err := png.Encode(&buf, img); err != nil {
		t.Fatal(err)
	}
	return buf.Bytes()
}

func TestStorageServiceEmitsUniformTelemetry(t *testing.T) {
	ctx := context.Background()
	exp := tracetest.NewInMemoryExporter()
	otel.SetTracerProvider(sdktrace.NewTracerProvider(sdktrace.WithSyncer(exp)))
	reader := sdkmetric.NewManualReader()
	otel.SetMeterProvider(sdkmetric.NewMeterProvider(sdkmetric.WithReader(reader)))

	svc, err := storage.NewService(&config.StorageConfig{BucketName: "b", MaxUploadSize: 10 << 20}, storetest.NewMemStore())
	if err != nil {
		t.Fatal(err)
	}
	s := NewStorageService(svc)
	data := tinyPNG(t)
	path, err := s.Store(ctx, "cat.png", "image/png", bytes.NewReader(data), int64(len(data)))
	if err != nil {
		t.Fatal(err)
	}
	rc, err := s.Retrieve(ctx, path)
	if err != nil {
		t.Fatal(err)
	}
	_, _ = io.Copy(io.Discard, rc)
	_ = rc.Close()
	if ok, err := s.Exists(ctx, "missing.png"); ok || err != nil {
		t.Fatalf("Exists(missing) = %v, %v", ok, err)
	}

	var rm metricdata.ResourceMetrics
	if err := reader.Collect(ctx, &rm); err != nil {
		t.Fatal(err)
	}
	ops := map[string]int64{}
	bytesByDir := map[string]int64{}
	for _, sm := range rm.ScopeMetrics {
		for _, m := range sm.Metrics {
			switch m.Name {
			case observability.MetricStorageOps:
				for _, dp := range m.Data.(metricdata.Sum[int64]).DataPoints {
					op, _ := dp.Attributes.Value(observability.AttrStorageOperation)
					prov, _ := dp.Attributes.Value(observability.AttrStorageProvider)
					if prov.AsString() != "memory" {
						t.Errorf("storage.provider = %q", prov.AsString())
					}
					ops[op.AsString()] += dp.Value
				}
			case observability.MetricStorageTransferred:
				for _, dp := range m.Data.(metricdata.Sum[int64]).DataPoints {
					d, _ := dp.Attributes.Value(observability.AttrStorageDirection)
					bytesByDir[d.AsString()] += dp.Value
				}
			}
		}
	}
	if ops["put"] != 1 || ops["get"] != 1 || ops["stat"] != 1 {
		t.Errorf("storage.operations by op = %v", ops)
	}
	if bytesByDir["write"] != int64(len(data)) || bytesByDir["read"] != int64(len(data)) {
		t.Errorf("storage.transferred = %v, want %d each way", bytesByDir, len(data))
	}
	var put bool
	for _, sp := range exp.GetSpans() {
		if sp.Name == "storage.put" {
			put = sp.SpanKind == trace.SpanKindClient &&
				attribute.NewSet(sp.Attributes...).HasValue(observability.AttrStorageProvider)
		}
	}
	if !put {
		t.Error("want a CLIENT span storage.put carrying storage.provider")
	}
}
```

- [ ] **Step 3: Run it and confirm it fails.**

Run: `go test ./internal/services/implementations/ -run TestStorageServiceEmitsUniformTelemetry -v`
Expected: FAIL to compile. `storage.NewService` has the wrong number of arguments, and `NewStorageService` wants `*storage.MinIOClient`.

- [ ] **Step 4: Delegate `storage.Service` to the store.** In `internal/platform/storage/service.go`:
  1. Replace the struct and constructor:

```go
type Service struct {
	store  ObjectStore
	config *config.StorageConfig
}

// NewService wraps an ObjectStore with the upload validation rules. The store
// owns connectivity and bucket setup.
func NewService(cfg *config.StorageConfig, store ObjectStore) (*Service, error) {
	if cfg == nil || store == nil {
		return nil, errors.New("storage config and store are required")
	}
	return &Service{store: store, config: cfg}, nil
}

// Provider is the backend name (s3, gcs, memory).
func (s *Service) Provider() string { return s.store.Provider() }
```

  2. In `Store`, replace the `s.client.PutObject(…)` call and the `info.Size == 0` check with:

```go
	err = s.store.Put(ctx, storagePath, contentType, hashReader, size, map[string]string{
		"original-filename": filename,
		"upload-time":       time.Now().UTC().Format(time.RFC3339),
	})
	if err != nil {
		return "", fmt.Errorf("failed to upload file: %w", err)
	}
	if sizeReader.size == 0 {
		_ = s.store.Delete(ctx, storagePath) //nolint:errcheck // cleanup in error path
		return "", errors.New("uploaded file has zero size")
	}
	return storagePath, nil
```

  3. Add `StoreAt`:

```go
// StoreAt writes to a caller-chosen key (worker thumbnails:
// thumbnails/<id>.<ext>). Rewriting the same key is how reprocessing stays idempotent.
func (s *Service) StoreAt(ctx context.Context, key, contentType string, data io.Reader, size int64) error {
	if key == "" || data == nil {
		return errors.New("key and data are required")
	}
	if !s.isValidContentType(contentType) {
		return fmt.Errorf("unsupported content type: %s", contentType)
	}
	return s.store.Put(ctx, key, contentType, data, size, nil)
}
```

  4. Rewrite the bodies:
     - `Retrieve` becomes `rc, err := s.store.Get(ctx, path); if errors.Is(err, ErrNotFound) { return nil, fmt.Errorf("file not found: %s: %w", path, err) }; return rc, err`.
     - `Exists` becomes `_, err := s.store.Stat(ctx, path); if errors.Is(err, ErrNotFound) { return false, nil }; return err == nil, err`.
     - `GetFileInfo` maps `s.store.Stat` onto `FileInfo`, with `LastModified: info.LastModified.Unix()`.
     - `Delete` keeps its existence check, then calls `s.store.Delete`.
     - `Health` becomes `return s.store.Health(ctx)`.
     - `ListObjects` becomes `return s.store.List(ctx, prefix, maxKeys)`.
  5. Delete `GenerateURL`, `Copy`, `GetObjectURL`, `ensureBucket` and the four "Legacy" methods (`UploadFile`, `GetFile`, `DeleteFile`, `GetFileURL`). Remove the `minio` import. Keep `noSuchKeyError`, which `s3store.go` uses.
  6. Delete `internal/platform/storage/minio.go`.

- [ ] **Step 5: Change the domain interfaces.** In `internal/domain/image/interfaces.go`:
  - in `StorageService`, delete `GenerateURL` and add:

```go
	// StoreAt saves data under an exact path (used for derived objects such as thumbnails).
	StoreAt(ctx context.Context, path string, contentType string, data io.Reader, size int64) error
```

  - in `ImageService`, delete `GenerateImageURL` (presigned URLs are gone: plan ruling 6).

- [ ] **Step 6: Rewrite `internal/services/implementations/storage_service.go`.**

```go
package implementations

import (
	"context"
	"io"
	"time"

	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/codes"
	"go.opentelemetry.io/otel/metric"
	"go.opentelemetry.io/otel/trace"

	"image-gallery/internal/domain/image"
	obs "image-gallery/internal/observability"
	"image-gallery/internal/platform/storage"
)

// StorageServiceImpl is the single instrumentation point for object storage:
// both backends emit the same storage.* spans and metrics, told apart by
// storage.provider.
type StorageServiceImpl struct {
	service     *storage.Service
	provider    string
	tracer      trace.Tracer
	ops         metric.Int64Counter
	duration    metric.Float64Histogram
	transferred metric.Int64Counter
}

// NewStorageService instruments svc.
func NewStorageService(svc *storage.Service) image.StorageService {
	meter := otel.Meter("image-gallery/storage")
	ops, _ := meter.Int64Counter(obs.MetricStorageOps, metric.WithUnit("{operation}"), metric.WithDescription("Object storage operations"))
	duration, _ := meter.Float64Histogram(obs.MetricStorageDuration, metric.WithUnit("s"), metric.WithDescription("Object storage operation duration"))
	transferred, _ := meter.Int64Counter(obs.MetricStorageTransferred, metric.WithUnit("By"), metric.WithDescription("Bytes written to and read from object storage"))
	return &StorageServiceImpl{service: svc, provider: svc.Provider(), tracer: otel.Tracer("image-gallery/storage"),
		ops: ops, duration: duration, transferred: transferred}
}

// observe starts a CLIENT span storage.<op> and returns its finisher, which
// records the span status and the operation metrics.
func (s *StorageServiceImpl) observe(ctx context.Context, op, key string) (context.Context, func(error)) {
	start := time.Now()
	ctx, span := s.tracer.Start(ctx, "storage."+op, trace.WithSpanKind(trace.SpanKindClient), trace.WithAttributes(
		attribute.String(obs.AttrStorageProvider, s.provider), attribute.String(obs.AttrStorageKey, key)))
	return ctx, func(err error) {
		outcome := obs.OutcomeSuccess
		if err != nil {
			outcome = obs.OutcomeError
			span.RecordError(err)
			span.SetStatus(codes.Error, op+" failed")
		}
		attrs := metric.WithAttributes(attribute.String(obs.AttrStorageProvider, s.provider),
			attribute.String(obs.AttrStorageOperation, op), attribute.String(obs.AttrOutcome, outcome))
		s.ops.Add(ctx, 1, attrs)
		s.duration.Record(ctx, time.Since(start).Seconds(), attrs)
		span.End()
	}
}

func (s *StorageServiceImpl) addBytes(ctx context.Context, dir string, n int64) {
	if n > 0 {
		s.transferred.Add(ctx, n, metric.WithAttributes(attribute.String(obs.AttrStorageProvider, s.provider), attribute.String(obs.AttrStorageDirection, dir)))
	}
}

func (s *StorageServiceImpl) Store(ctx context.Context, filename, contentType string, data io.Reader, size int64) (string, error) {
	ctx, done := s.observe(ctx, "put", filename)
	path, err := s.service.Store(ctx, filename, contentType, data, size)
	done(err)
	if err == nil {
		s.addBytes(ctx, "write", size)
	}
	return path, err
}

func (s *StorageServiceImpl) StoreAt(ctx context.Context, path, contentType string, data io.Reader, size int64) error {
	ctx, done := s.observe(ctx, "put", path)
	err := s.service.StoreAt(ctx, path, contentType, data, size)
	done(err)
	if err == nil {
		s.addBytes(ctx, "write", size)
	}
	return err
}

// countingReadCloser reports the bytes actually read on Close.
type countingReadCloser struct {
	io.ReadCloser
	n      int64
	onDone func(int64)
}

func (c *countingReadCloser) Read(p []byte) (int, error) {
	n, err := c.ReadCloser.Read(p)
	c.n += int64(n)
	return n, err
}

func (c *countingReadCloser) Close() error {
	c.onDone(c.n)
	return c.ReadCloser.Close()
}

func (s *StorageServiceImpl) Retrieve(ctx context.Context, path string) (io.ReadCloser, error) {
	ctx, done := s.observe(ctx, "get", path)
	rc, err := s.service.Retrieve(ctx, path)
	done(err)
	if err != nil {
		return nil, err
	}
	return &countingReadCloser{ReadCloser: rc, onDone: func(n int64) { s.addBytes(ctx, "read", n) }}, nil
}

func (s *StorageServiceImpl) Delete(ctx context.Context, path string) error {
	ctx, done := s.observe(ctx, "delete", path)
	err := s.service.Delete(ctx, path)
	done(err)
	return err
}

// Exists records a missing object as a successful stat, not an error.
func (s *StorageServiceImpl) Exists(ctx context.Context, path string) (bool, error) {
	ctx, done := s.observe(ctx, "stat", path)
	ok, err := s.service.Exists(ctx, path)
	done(err)
	return ok, err
}

func (s *StorageServiceImpl) GetFileInfo(ctx context.Context, path string) (*image.FileInfo, error) {
	ctx, done := s.observe(ctx, "stat", path)
	info, err := s.service.GetFileInfo(ctx, path)
	done(err)
	if err != nil {
		return nil, err
	}
	return &image.FileInfo{Path: info.Path, Size: info.Size, ContentType: info.ContentType, LastModified: info.LastModified, ETag: info.ETag}, nil
}

// ListObjects lists objects (gallery fallback and the startup sync).
func (s *StorageServiceImpl) ListObjects(ctx context.Context, prefix string, maxKeys int) ([]ObjectInfo, error) {
	ctx, done := s.observe(ctx, "list", prefix)
	objects, err := s.service.ListObjects(ctx, prefix, maxKeys)
	done(err)
	if err != nil {
		return nil, err
	}
	result := make([]ObjectInfo, len(objects))
	for i, o := range objects {
		result[i] = ObjectInfo{Key: o.Key, Size: o.Size, ContentType: o.ContentType, LastModified: o.LastModified, ETag: o.ETag, UserMetadata: o.UserMetadata}
	}
	return result, nil
}

// ObjectInfo represents information about a stored object (for compatibility).
type ObjectInfo struct {
	Key          string            `json:"key"`
	Size         int64             `json:"size"`
	ContentType  string            `json:"content_type"`
	LastModified time.Time         `json:"last_modified"`
	ETag         string            `json:"etag"`
	UserMetadata map[string]string `json:"user_metadata,omitempty"`
}
```

- [ ] **Step 7: Rewire the callers.**
  - **`internal/services/container.go`:**
    - Replace the field `storageClient *storage.MinIOClient` with `objectStore storage.ObjectStore`, and change the three constructors' `storageClient *storage.MinIOClient` parameter to `store storage.ObjectStore`.
    - In `initializeServices`, replace the "Try to create full storage service, fallback" block with:

```go
	svc, err := storage.NewService(&c.config.Storage, c.objectStore)
	if err != nil {
		return fmt.Errorf("storage service: %w", err)
	}
	c.storageService = implementations.NewStorageService(svc)
```

    - Rename the getter `StorageClient()` to `ObjectStore() storage.ObjectStore`.
  - **`internal/web/handlers/handlers.go`:**
    - Remove the legacy `storage *storage.MinIOClient` field and its assignment.
    - Delete the legacy `New(db, storage, config)` constructor when nothing references it. If `upload_test.go` uses it, move the test to `NewWithContainer`.
  - **`internal/web/handlers/upload.go`:** replace the presigned-URL block with `imageURL := fmt.Sprintf("/api/images/%d/view", img.ID)`.
  - **`internal/services/implementations/image_service.go`:** delete `GenerateImageURL`.
  - **`cmd/server/main.go`:**
    - Replace `storage.NewMinIOClient(cfg.Storage)` with `store, err := storage.NewObjectStore(context.Background(), cfg.Storage)` and pass `store` to `NewContainerWithObservability`.
    - In `syncExistingImages`, build the service with `storage.NewService(&container.Config().Storage, container.ObjectStore())`.
  - **`internal/testutils/containers.go`:**
    - Rename `MinioClient *storage.MinIOClient` to `ObjectStore storage.ObjectStore`.
    - In `setupMinio`, create it with `storage.NewS3Store(ctx, storageConfig)` (same config values, `Provider: storage.ProviderS3`) instead of `storage.NewMinIOClient`.
    - Update every integration test that passed `tc.MinioClient`.
  - **`internal/platform/storage/service_test.go`:** construct the service with `NewService(cfg, storetest.NewMemStore())`. Delete the cases that exercised the removed methods (`GenerateURL`, `Copy`, `GetObjectURL`, legacy).

  Run `go build ./... && go vet ./...` until it is clean; remove anything the compiler reports as unused.

- [ ] **Step 8: Run the tests and confirm they pass.**

Run: `go test ./internal/services/implementations/ -run TestStorageServiceEmitsUniformTelemetry -v && go test -short ./... && go test ./internal/platform/storage/ ./internal/services/integrationtests/ -v`
Expected: PASS, including the MinIO-backed upload integration tests. They still run against `STORAGE_PROVIDER=s3` semantics, which keeps the Pod-Identity-era S3 path under test.

- [ ] **Step 9: Commit.**

```bash
git add -A internal cmd
git commit -m "refactor(storage): one storage service over ObjectStore, uniform storage telemetry" \
  -m "Removes the second minio client (MinIOClient) and presigned URLs, which GCS workload identity cannot sign; images are served through the app's own proxy. storage.operations, storage.operation.duration and storage.transferred carry storage.provider." \
  -m "BREAKING CHANGE: the storage.operations.total, storage.bytes.transferred and image-gallery/service/storage span names are replaced by storage.operations, storage.transferred and storage.<op> CLIENT spans."
```

### Task 9: Migration 004 and the image processing status

**Files:**
- Create: `internal/platform/database/migrations/004_async_processing_and_demo.sql`.
- Modify: `internal/platform/database/migrations/kustomization.yaml` and `atlas.sum` (regenerated).
- Modify: `internal/platform/database/models.go` (`Image`), `repository.go` (the interface and `scanImages`) and `image_repository.go`.
- Modify: `internal/domain/image/models.go` (`Image`, the status constants, `ProcessingResult`) and `internal/domain/image/interfaces.go` (`Repository`).
- Modify: `internal/services/implementations/image_repository_adapter.go` and its test mocks.
- Test: `internal/platform/database/status_integration_test.go` (package `database_test`).

**Interfaces:**
- Consumes: nothing new.
- Produces:
  - Domain status constants: `const (StatusPending = "pending"; StatusProcessing = "processing"; StatusReady = "ready"; StatusFailed = "failed")`.
  - `image.Image` gains `Status string` (json `status`), `ProcessingError *string` (json `processing_error,omitempty`) and `ProcessedAt *time.Time` (json `processed_at,omitempty`).
  - `type image.ProcessingResult struct { ThumbnailPath string; Width, Height int; Format, ColorSpace string; HasAlpha bool }`.
  - `image.Repository` gains `UpdateStatus(ctx context.Context, id int, status string, processingError *string) error` and `CompleteProcessing(ctx context.Context, id int, res ProcessingResult) error`.
  - `database.ImageRepository` gains the same two methods, with `database.ProcessingResult{ThumbnailPath string; Width, Height int; Metadata Metadata}`.
  - Table `demo_controls`, one row with `id=1` (Task 14).

- [ ] **Step 1: Write the migration.** Create `internal/platform/database/migrations/004_async_processing_and_demo.sql`:

```sql
-- 004: asynchronous image processing (worker) and the demo controls row.
--
-- Existing rows become 'ready': they are served as originals, and a NULL
-- thumbnail_path falls back to the original. New uploads insert 'pending'.
ALTER TABLE images ADD COLUMN IF NOT EXISTS status VARCHAR(20) NOT NULL DEFAULT 'ready';
ALTER TABLE images ADD CONSTRAINT images_status_check CHECK (status IN ('pending', 'processing', 'ready', 'failed'));
ALTER TABLE images ADD COLUMN IF NOT EXISTS processing_error TEXT;
ALTER TABLE images ADD COLUMN IF NOT EXISTS processed_at TIMESTAMP WITH TIME ZONE;
CREATE INDEX IF NOT EXISTS idx_images_status_not_ready ON images(status) WHERE status <> 'ready';

-- Fault injection for the observability demo. One row; every control off.
CREATE TABLE IF NOT EXISTS demo_controls (
    id SMALLINT PRIMARY KEY DEFAULT 1 CHECK (id = 1),
    latency_ms INTEGER NOT NULL DEFAULT 0 CHECK (latency_ms BETWEEN 0 AND 30000),
    latency_probability NUMERIC(4,3) NOT NULL DEFAULT 0 CHECK (latency_probability BETWEEN 0 AND 1),
    latency_routes TEXT[] NOT NULL DEFAULT '{}',
    error_probability NUMERIC(4,3) NOT NULL DEFAULT 0 CHECK (error_probability BETWEEN 0 AND 1),
    slow_db_ms INTEGER NOT NULL DEFAULT 0 CHECK (slow_db_ms BETWEEN 0 AND 30000),
    worker_failure_probability NUMERIC(4,3) NOT NULL DEFAULT 0 CHECK (worker_failure_probability BETWEEN 0 AND 1),
    worker_delay_ms INTEGER NOT NULL DEFAULT 0 CHECK (worker_delay_ms BETWEEN 0 AND 60000),
    updated_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW()
);
INSERT INTO demo_controls (id) VALUES (1) ON CONFLICT (id) DO NOTHING;
```

- [ ] **Step 2: Register it and rehash.** Add `      - ./004_async_processing_and_demo.sql` after the `003` line in `migrations/kustomization.yaml`, then run `atlas migrate hash --dir file://internal/platform/database/migrations`.
Expected: `atlas.sum` changes, and `git diff --stat` shows `atlas.sum` plus the two files.

- [ ] **Step 3: Write the failing integration test.** Create `internal/platform/database/status_integration_test.go`:

```go
package database_test

import (
	"context"
	"testing"

	"image-gallery/internal/platform/database"
	"image-gallery/internal/testutils"
)

func TestImageProcessingStatusRoundTrip(t *testing.T) {
	if testing.Short() {
		t.Skip("integration test")
	}
	ctx := context.Background()
	tc, err := testutils.SetupTestContainers(ctx) // applies every migration, 004 included
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = tc.Cleanup(ctx) }()
	repo := database.NewImageRepository(tc.DB)

	img := &database.Image{Filename: "a.png", OriginalFilename: "a.png", ContentType: "image/png",
		FileSize: 10, StoragePath: "aa/bb/a.png", Status: "pending", Metadata: database.Metadata{}}
	if err := repo.Create(ctx, img); err != nil {
		t.Fatal(err)
	}
	got, err := repo.GetByID(ctx, img.ID)
	if err != nil || got.Status != "pending" {
		t.Fatalf("after Create: status %q err %v", got.Status, err)
	}
	if err := repo.UpdateStatus(ctx, img.ID, "processing", nil); err != nil {
		t.Fatal(err)
	}
	if err := repo.CompleteProcessing(ctx, img.ID, database.ProcessingResult{
		ThumbnailPath: "thumbnails/1.png", Width: 640, Height: 480, Metadata: database.Metadata{"format": "png"},
	}); err != nil {
		t.Fatal(err)
	}
	got, err = repo.GetByID(ctx, img.ID)
	if err != nil {
		t.Fatal(err)
	}
	if got.Status != "ready" || got.ThumbnailPath == nil || *got.ThumbnailPath != "thumbnails/1.png" ||
		got.Width == nil || *got.Width != 640 || got.ProcessedAt == nil || got.ProcessingError != nil {
		t.Fatalf("after CompleteProcessing: %+v", got)
	}
	list, err := repo.List(ctx, database.PaginationParams{Limit: 10}, database.SortParams{})
	if err != nil || len(list) != 1 || list[0].Status != "ready" {
		t.Fatalf("List status: %v %v", list, err)
	}
	var rows int
	if err := tc.DB.QueryRowContext(ctx, "SELECT count(*) FROM demo_controls").Scan(&rows); err != nil || rows != 1 {
		t.Fatalf("demo_controls rows = %d err %v", rows, err)
	}
}
```

If `database.Metadata` is not a map type, or `PaginationParams` and `SortParams` use other field names, adjust the literals to the definitions in `models.go`. The assertions stay as they are.

- [ ] **Step 4: Run it and confirm it fails.**

Run: `go test ./internal/platform/database/ -run TestImageProcessingStatusRoundTrip -v`
Expected: FAIL to compile, with unknown field `Status` and `undefined: UpdateStatus`/`CompleteProcessing`.

- [ ] **Step 5: Implement the database layer.**
  - **`models.go`:** add to `database.Image`, after `ThumbnailPath`:

```go
	Status          string     `json:"status" db:"status"`
	ProcessingError *string    `json:"processing_error,omitempty" db:"processing_error"`
	ProcessedAt     *time.Time `json:"processed_at,omitempty" db:"processed_at"`
```

    and add:

```go
// ProcessingResult is what the worker writes back for one image.
type ProcessingResult struct {
	ThumbnailPath string
	Width, Height int
	Metadata      Metadata // merged into images.metadata (jsonb ||)
}
```

  - **`image_repository.go` and `repository.go`:**
    - Every column list that contains `thumbnail_path` (SELECT lists, including aliased `i.thumbnail_path`, and any GROUP BY listing it) gains `, status, processing_error, processed_at` directly after it, with the same alias.
    - Every `Scan(` that contains `&image.ThumbnailPath` (or `&img.ThumbnailPath`) gains `&image.Status, &image.ProcessingError, &image.ProcessedAt` directly after it.
    - Check with `grep -c 'thumbnail_path' image_repository.go` before and after: every occurrence outside `INSERT` and `UpdateThumbnail` must now be followed by `status`.
  - **In `Create`:** add `status` to the column list and `$10` to `VALUES`, and pass `statusOrPending(image.Status)`:

```go
func statusOrPending(s string) string {
	if s == "" {
		return "pending"
	}
	return s
}
```

    Also scan the `RETURNING` values as before.
  - **Add to `imageRepository`** (and to the `ImageRepository` interface in `repository.go`):

```go
// UpdateStatus moves an image through pending -> processing -> ready|failed.
func (r *imageRepository) UpdateStatus(ctx context.Context, id int, status string, processingError *string) error {
	res, err := r.db.ExecContext(ctx,
		`UPDATE images SET status = $2, processing_error = $3, updated_at = NOW() WHERE id = $1`, id, status, processingError)
	if err != nil {
		return err
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return fmt.Errorf("image with ID %d not found", id)
	}
	return nil
}

// CompleteProcessing records the worker's result and marks the image ready.
func (r *imageRepository) CompleteProcessing(ctx context.Context, id int, p ProcessingResult) error {
	res, err := r.db.ExecContext(ctx, `
		UPDATE images
		   SET status = 'ready', thumbnail_path = $2, width = $3, height = $4,
		       metadata = COALESCE(metadata, '{}'::jsonb) || $5::jsonb,
		       processing_error = NULL, processed_at = NOW(), updated_at = NOW()
		 WHERE id = $1`, id, p.ThumbnailPath, p.Width, p.Height, p.Metadata)
	if err != nil {
		return err
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return fmt.Errorf("image with ID %d not found", id)
	}
	return nil
}
```

- [ ] **Step 6: Implement the domain layer.**
  - **`internal/domain/image/models.go`:** add the three fields to `Image` (json `status`, `processing_error,omitempty`, `processed_at,omitempty`), the four `Status*` constants, and:

```go
// ProcessingResult is the worker's output for one image.
type ProcessingResult struct {
	ThumbnailPath string
	Width, Height int
	Format        string
	ColorSpace    string
	HasAlpha      bool
}
```

  - **`internal/domain/image/interfaces.go`:** add to `Repository`:

```go
	// UpdateStatus sets the processing status (and error text when failed).
	UpdateStatus(ctx context.Context, id int, status string, processingError *string) error

	// CompleteProcessing stores the worker's result and marks the image ready.
	CompleteProcessing(ctx context.Context, id int, res ProcessingResult) error
```

  - **`image_repository_adapter.go`:**
    - Map `Status`, `ProcessingError` and `ProcessedAt` at every site where `ThumbnailPath` is mapped (three sites).
    - Add:

```go
func (a *ImageRepositoryAdapter) UpdateStatus(ctx context.Context, id int, status string, processingError *string) error {
	return a.dbRepo.UpdateStatus(ctx, id, status, processingError)
}

func (a *ImageRepositoryAdapter) CompleteProcessing(ctx context.Context, id int, r image.ProcessingResult) error {
	return a.dbRepo.CompleteProcessing(ctx, id, database.ProcessingResult{
		ThumbnailPath: r.ThumbnailPath, Width: r.Width, Height: r.Height,
		Metadata: database.Metadata{"format": r.Format, "color_space": r.ColorSpace, "has_alpha": r.HasAlpha},
	})
}
```

    - Add no-op implementations of the two methods to every mock of `database.ImageRepository` or `image.Repository` that the compiler reports, in `*_test.go` files.

- [ ] **Step 7: Run the tests and confirm they pass.**

Run: `go build ./... && go test -short ./... && go test ./internal/platform/database/ -run TestImageProcessingStatusRoundTrip -v`
Expected: PASS.

- [ ] **Step 8: Commit.**

```bash
git add internal/platform/database internal/domain/image internal/services/implementations
git commit -m "feat(db): processing status for asynchronous thumbnails, and the demo_controls table" \
  -m "Migration 004 adds images.status/processing_error/processed_at (existing rows are ready) and a single-row demo_controls table with every fault off."
```


### Task 10: The Valkey stream queue

**Files:**
- Create: `internal/platform/queue/job.go`, `options.go`, `producer.go`, `consumer.go` and `metrics.go`.
- Test: `internal/platform/queue/queue_test.go` (integration) and `internal/platform/queue/job_test.go` (unit).
- Modify: `internal/platform/cache/redis.go` (add an instrumented client constructor, used by `NewRedisClient`).

**Interfaces:**
- Consumes: the Task 5 constants and go-redis v9.22.0.
- Produces (Tasks 11, 13 and 16 use these exact names):

```go
const DefaultStream = "image-gallery:jobs"; DefaultGroup = "workers"; DefaultDeadLetter = "image-gallery:jobs:dead"
const JobTypeProcessImage = "process_image"
type Job struct { ID, Type string; ImageID int; ObjectKey string; Carrier map[string]string }
var ErrSkip error                              // handler: "already done", ack without retry
func Permanent(err error) error; func IsPermanent(err error) bool
type Option func(*options)
func WithTracerProvider(trace.TracerProvider) Option; func WithMeterProvider(metric.MeterProvider) Option
func WithPropagator(propagation.TextMapPropagator) Option; func WithStream(string) Option
func WithGroup(string) Option; func WithDeadLetter(string) Option; func WithConsumerName(string) Option
func WithClaimIdle(time.Duration) Option; func WithMaxAttempts(int) Option
func WithBackoff(func(attempt int) time.Duration) Option; func WithConcurrency(int) Option
func WithBlock(time.Duration) Option; func WithDeadLetterHook(func(context.Context, Job, error)) Option
func NewProducer(rdb redis.UniversalClient, opts ...Option) (*Producer, error)
func (*Producer) Publish(ctx context.Context, job Job) (string, error)
type Handler func(ctx context.Context, job Job) error
func NewConsumer(rdb redis.UniversalClient, opts ...Option) (*Consumer, error)
func (*Consumer) EnsureGroup(ctx context.Context) error
func (*Consumer) Ready(ctx context.Context) error
func (*Consumer) Run(ctx context.Context, h Handler) error // returns after in-flight jobs finish
func RegisterGauges(rdb redis.UniversalClient, meter metric.Meter, stream, group string) error
func cache.NewInstrumentedClient(cfg config.CacheConfig) (*redis.Client, error)
```

Defaults: 4 attempts; backoff 500 ms × 2^(n-1); claim idle 60 s; concurrency 2; block 2 s; `MAXLEN ~ 10000`; consumer name = hostname (the pod name).

- [ ] **Step 1: Write the failing unit test.** Create `internal/platform/queue/job_test.go`:

```go
package queue

import (
	"errors"
	"testing"
	"time"

	"github.com/redis/go-redis/v9"
)

func TestJobRoundTripAndPermanent(t *testing.T) {
	j := Job{Type: JobTypeProcessImage, ImageID: 42, ObjectKey: "aa/bb/x.png",
		Carrier: map[string]string{"traceparent": "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"}} // pragma: allowlist secret
	vals := map[string]any{}
	for k, v := range j.values() {
		vals[k] = v
	}
	got, err := jobFromMessage(redis.XMessage{ID: "1-0", Values: vals})
	if err != nil || got.ImageID != 42 || got.ObjectKey != j.ObjectKey || got.Carrier["traceparent"] != j.Carrier["traceparent"] || got.ID != "1-0" {
		t.Fatalf("round trip = %+v, %v", got, err)
	}
	if _, err := jobFromMessage(redis.XMessage{ID: "2-0", Values: map[string]any{"image_id": "x"}}); !IsPermanent(err) {
		t.Fatalf("a malformed image_id must be permanent, got %v", err)
	}
	if IsPermanent(errors.New("plain")) || !IsPermanent(Permanent(errors.New("p"))) {
		t.Fatal("IsPermanent")
	}
}

func TestEntryAge(t *testing.T) {
	now := time.UnixMilli(10_000)
	if got := entryAge("7000-3", now); got != 3 {
		t.Fatalf("entryAge = %v, want 3", got)
	}
	if got := entryAge("garbage", now); got != 0 {
		t.Fatalf("entryAge(garbage) = %v, want 0", got)
	}
}
```

- [ ] **Step 2: Write the failing integration tests.** Create `internal/platform/queue/queue_test.go`:

```go
package queue

import (
	"context"
	"errors"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/redis/go-redis/v9"
	"github.com/testcontainers/testcontainers-go"
	tcredis "github.com/testcontainers/testcontainers-go/modules/redis"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/propagation"
	sdkmetric "go.opentelemetry.io/otel/sdk/metric"
	"go.opentelemetry.io/otel/sdk/metric/metricdata"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
	"go.opentelemetry.io/otel/sdk/trace/tracetest"
	"go.opentelemetry.io/otel/trace"

	obs "image-gallery/internal/observability"
)

type harness struct {
	rdb    *redis.Client
	spans  *tracetest.InMemoryExporter
	reader *sdkmetric.ManualReader
	opts   []Option
}

func newHarness(t *testing.T) *harness {
	t.Helper()
	if testing.Short() {
		t.Skip("integration test")
	}
	ctx := context.Background()
	c, err := tcredis.Run(ctx, "valkey/valkey:7-alpine")
	testcontainers.CleanupContainer(t, c)
	if err != nil {
		t.Fatal(err)
	}
	uri, err := c.ConnectionString(ctx)
	if err != nil {
		t.Fatal(err)
	}
	rdb := redis.NewClient(&redis.Options{Addr: strings.TrimPrefix(uri, "redis://")})
	t.Cleanup(func() { _ = rdb.Close() })
	exp := tracetest.NewInMemoryExporter()
	reader := sdkmetric.NewManualReader()
	stream := "t:" + strings.ReplaceAll(t.Name(), "/", "_")
	return &harness{rdb: rdb, spans: exp, reader: reader, opts: []Option{
		WithTracerProvider(sdktrace.NewTracerProvider(sdktrace.WithSyncer(exp))),
		WithMeterProvider(sdkmetric.NewMeterProvider(sdkmetric.WithReader(reader))),
		WithPropagator(propagation.TraceContext{}),
		WithStream(stream), WithDeadLetter(stream + ":dead"), WithGroup("workers"),
		WithConsumerName("test-worker"), WithBlock(100 * time.Millisecond),
		WithBackoff(func(int) time.Duration { return time.Millisecond }),
	}}
}

func waitFor(t *testing.T, what string, cond func() bool) {
	t.Helper()
	deadline := time.Now().Add(15 * time.Second)
	for !cond() {
		if time.Now().After(deadline) {
			t.Fatalf("timed out waiting for %s", what)
		}
		time.Sleep(20 * time.Millisecond)
	}
}

func runConsumer(t *testing.T, h *harness, handler Handler, extra ...Option) (stop func()) {
	t.Helper()
	c, err := NewConsumer(h.rdb, append(h.opts, extra...)...)
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() { _ = c.Run(ctx, handler); close(done) }()
	return func() { cancel(); <-done }
}

func spansNamed(h *harness, name string) []tracetest.SpanStub {
	var out []tracetest.SpanStub
	for _, s := range h.spans.GetSpans() {
		if s.Name == name {
			out = append(out, s)
		}
	}
	return out
}

func counterByOutcome(t *testing.T, h *harness, name string) map[string]int64 {
	t.Helper()
	var rm metricdata.ResourceMetrics
	if err := h.reader.Collect(context.Background(), &rm); err != nil {
		t.Fatal(err)
	}
	out := map[string]int64{}
	for _, sm := range rm.ScopeMetrics {
		for _, m := range sm.Metrics {
			if m.Name != name {
				continue
			}
			for _, dp := range m.Data.(metricdata.Sum[int64]).DataPoints {
				v, _ := dp.Attributes.Value(obs.AttrOutcome)
				out[v.AsString()] += dp.Value
			}
		}
	}
	return out
}

func TestTraceContinuesThroughQueueWithLink(t *testing.T) {
	h := newHarness(t)
	p, err := NewProducer(h.rdb, h.opts...)
	if err != nil {
		t.Fatal(err)
	}
	tp := sdktrace.NewTracerProvider(sdktrace.WithSyncer(h.spans))
	ctx, root := tp.Tracer("t").Start(context.Background(), "upload")
	if _, err := p.Publish(ctx, Job{Type: JobTypeProcessImage, ImageID: 7, ObjectKey: "k"}); err != nil {
		t.Fatal(err)
	}
	root.End()

	var handled atomic.Int32
	stop := runConsumer(t, h, func(context.Context, Job) error { handled.Add(1); return nil })
	waitFor(t, "job handled", func() bool { return handled.Load() == 1 })
	stop()

	prod := spansNamed(h, "send "+h.streamName())
	cons := spansNamed(h, "process "+h.streamName())
	if len(prod) != 1 || len(cons) != 1 {
		t.Fatalf("producer spans %d, consumer spans %d", len(prod), len(cons))
	}
	if prod[0].SpanKind != trace.SpanKindProducer || cons[0].SpanKind != trace.SpanKindConsumer {
		t.Errorf("kinds: %v / %v", prod[0].SpanKind, cons[0].SpanKind)
	}
	if cons[0].SpanContext.TraceID() != root.SpanContext().TraceID() {
		t.Errorf("consumer is not in the upload's trace")
	}
	if cons[0].Parent.SpanID() != prod[0].SpanContext.SpanID() {
		t.Errorf("consumer parent = %s, want producer %s", cons[0].Parent.SpanID(), prod[0].SpanContext.SpanID())
	}
	if len(cons[0].Links) != 1 || cons[0].Links[0].SpanContext.SpanID() != prod[0].SpanContext.SpanID() {
		t.Errorf("consumer must link the producer span, links = %+v", cons[0].Links)
	}
}

func TestRetryThenDeadLetter(t *testing.T) {
	h := newHarness(t)
	p, _ := NewProducer(h.rdb, h.opts...)
	if _, err := p.Publish(context.Background(), Job{Type: JobTypeProcessImage, ImageID: 9, ObjectKey: "k"}); err != nil {
		t.Fatal(err)
	}
	var hooked atomic.Int32
	stop := runConsumer(t, h, func(context.Context, Job) error { return errors.New("boom") },
		WithMaxAttempts(3), WithDeadLetterHook(func(_ context.Context, j Job, _ error) {
			if j.ImageID == 9 {
				hooked.Add(1)
			}
		}))
	waitFor(t, "dead-letter hook", func() bool { return hooked.Load() == 1 })
	stop()

	ctx := context.Background()
	dead, err := h.rdb.XRange(ctx, h.streamName()+":dead", "-", "+").Result()
	if err != nil || len(dead) != 1 || dead[0].Values["error"] != "boom" || dead[0].Values["original_id"] == nil {
		t.Fatalf("dead-letter stream = %+v, %v", dead, err)
	}
	pend, _ := h.rdb.XPending(ctx, h.streamName(), "workers").Result()
	if pend.Count != 0 {
		t.Fatalf("original must be acked, pending = %d", pend.Count)
	}
	if n := len(spansNamed(h, "job.attempt")); n != 3 {
		t.Errorf("job.attempt spans = %d, want 3", n)
	}
	if got := counterByOutcome(t, h, obs.MetricWorkerJobs); got[obs.OutcomeRetry] != 2 || got[obs.OutcomeDeadLetter] != 1 {
		t.Errorf("worker.jobs = %v, want retry:2 dead_letter:1", got)
	}
}

func TestPermanentAndSkip(t *testing.T) {
	h := newHarness(t)
	p, _ := NewProducer(h.rdb, h.opts...)
	ctx := context.Background()
	_, _ = p.Publish(ctx, Job{Type: JobTypeProcessImage, ImageID: 1, ObjectKey: "perm"})
	_, _ = p.Publish(ctx, Job{Type: JobTypeProcessImage, ImageID: 2, ObjectKey: "skip"})
	var calls atomic.Int32
	stop := runConsumer(t, h, func(_ context.Context, j Job) error {
		calls.Add(1)
		if j.ObjectKey == "perm" {
			return Permanent(errors.New("corrupt image"))
		}
		return ErrSkip
	})
	waitFor(t, "both handled", func() bool {
		pend, _ := h.rdb.XPending(ctx, h.streamName(), "workers").Result()
		n, _ := h.rdb.XLen(ctx, h.streamName()+":dead").Result()
		return calls.Load() == 2 && pend.Count == 0 && n == 1
	})
	stop()
	if got := counterByOutcome(t, h, obs.MetricWorkerJobs); got[obs.OutcomeSkipped] != 1 || got[obs.OutcomeDeadLetter] != 1 || got[obs.OutcomeRetry] != 0 {
		t.Errorf("worker.jobs = %v", got)
	}
}

func TestAutoClaimRecoversAbandonedEntry(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()
	c0, _ := NewConsumer(h.rdb, h.opts...)
	if err := c0.EnsureGroup(ctx); err != nil {
		t.Fatal(err)
	}
	p, _ := NewProducer(h.rdb, h.opts...)
	_, _ = p.Publish(ctx, Job{Type: JobTypeProcessImage, ImageID: 5, ObjectKey: "k"})
	// A worker that read the entry and died before acking it.
	if _, err := h.rdb.XReadGroup(ctx, &redis.XReadGroupArgs{Group: "workers", Consumer: "dead-worker",
		Streams: []string{h.streamName(), ">"}, Count: 1}).Result(); err != nil {
		t.Fatal(err)
	}
	var got atomic.Int32
	stop := runConsumer(t, h, func(_ context.Context, j Job) error { got.Store(int32(j.ImageID)); return nil },
		WithClaimIdle(100*time.Millisecond))
	waitFor(t, "reclaimed job", func() bool { return got.Load() == 5 })
	stop()
}

func TestShutdownFinishesInFlightJob(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()
	p, _ := NewProducer(h.rdb, h.opts...)
	_, _ = p.Publish(ctx, Job{Type: JobTypeProcessImage, ImageID: 3, ObjectKey: "k"})
	started, release := make(chan struct{}), make(chan struct{})
	var finished atomic.Bool
	stop := runConsumer(t, h, func(context.Context, Job) error {
		close(started)
		<-release
		finished.Store(true)
		return nil
	})
	<-started
	go func() { time.Sleep(200 * time.Millisecond); close(release) }()
	stop() // cancels, then must wait for the in-flight job
	if !finished.Load() {
		t.Fatal("Run returned before the in-flight job finished")
	}
	pend, _ := h.rdb.XPending(ctx, h.streamName(), "workers").Result()
	if pend.Count != 0 {
		t.Fatalf("in-flight job must be acked on shutdown, pending = %d", pend.Count)
	}
}

func TestGaugesAndReady(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()
	c, _ := NewConsumer(h.rdb, h.opts...)
	if err := c.Ready(ctx); err == nil {
		t.Fatal("Ready must fail before the group exists")
	}
	if err := c.EnsureGroup(ctx); err != nil {
		t.Fatal(err)
	}
	if err := c.Ready(ctx); err != nil {
		t.Fatal(err)
	}
	gaugeReader := sdkmetric.NewManualReader() // a reader registers with ONE provider; the harness's is taken
	mp := sdkmetric.NewMeterProvider(sdkmetric.WithReader(gaugeReader))
	if err := RegisterGauges(h.rdb, mp.Meter("q"), h.streamName(), "workers"); err != nil {
		t.Fatal(err)
	}
	p, _ := NewProducer(h.rdb, h.opts...)
	for i := 0; i < 3; i++ {
		_, _ = p.Publish(ctx, Job{Type: JobTypeProcessImage, ImageID: i, ObjectKey: "k"})
	}
	_, _ = h.rdb.XReadGroup(ctx, &redis.XReadGroupArgs{Group: "workers", Consumer: "x", Streams: []string{h.streamName(), ">"}, Count: 1}).Result()
	time.Sleep(20 * time.Millisecond)

	var rm metricdata.ResourceMetrics
	if err := gaugeReader.Collect(ctx, &rm); err != nil {
		t.Fatal(err)
	}
	vals := map[string]float64{}
	for _, sm := range rm.ScopeMetrics {
		for _, m := range sm.Metrics {
			switch d := m.Data.(type) {
			case metricdata.Gauge[int64]:
				for _, dp := range d.DataPoints {
					vals[m.Name] = float64(dp.Value)
				}
			case metricdata.Gauge[float64]:
				for _, dp := range d.DataPoints {
					vals[m.Name] = dp.Value
				}
			}
		}
	}
	if vals[obs.MetricQueueDepth] != 2 || vals[obs.MetricQueuePending] != 1 || vals[obs.MetricQueueLag] <= 0 {
		t.Fatalf("gauges = %v, want depth 2, pending 1, lag > 0", vals)
	}
	_ = attribute.Key("unused") // keep the import list stable if assertions change
}
```

Add this helper to the test file:

```go
func (h *harness) streamName() string {
	for _, o := range h.opts {
		var x options
		o(&x)
		if x.stream != "" {
			return x.stream
		}
	}
	return DefaultStream
}
```

- [ ] **Step 3: Run the tests and confirm they fail.**

Run: `go test ./internal/platform/queue/ -v`
Expected: FAIL to compile with `undefined: Job`, `NewProducer` and the rest.

- [ ] **Step 4: Create `internal/platform/queue/job.go`.**

```go
// Package queue is a job queue on a Valkey stream with a consumer group:
// trace context rides in each entry, failures retry with exponential backoff
// and then dead-letter, and XAUTOCLAIM recovers entries a dead worker held.
package queue

import (
	"errors"
	"fmt"
	"strconv"
	"strings"
	"time"

	"github.com/redis/go-redis/v9"
)

// Stream, group and job-type names (the spec's contract).
const (
	DefaultStream       = "image-gallery:jobs"
	DefaultGroup        = "workers"
	DefaultDeadLetter   = "image-gallery:jobs:dead"
	JobTypeProcessImage = "process_image"
	messagingSystem     = "valkey"
)

// ErrSkip tells the consumer the job needs no work (already done): ack it,
// count it as skipped, and do not retry.
var ErrSkip = errors.New("job skipped")

// Job is one stream entry.
type Job struct {
	ID        string // stream entry ID; set by the consumer
	Type      string
	ImageID   int
	ObjectKey string
	Carrier   map[string]string // W3C traceparent/tracestate of the producer span
}

func (j Job) values() map[string]any {
	v := map[string]any{"type": j.Type, "image_id": strconv.Itoa(j.ImageID), "object_key": j.ObjectKey}
	for k, val := range j.Carrier {
		v[k] = val
	}
	return v
}

func jobFromMessage(m redis.XMessage) (Job, error) {
	get := func(k string) string { s, _ := m.Values[k].(string); return s }
	carrier := map[string]string{}
	for _, k := range []string{"traceparent", "tracestate"} {
		if v := get(k); v != "" {
			carrier[k] = v
		}
	}
	job := Job{ID: m.ID, Type: get("type"), ObjectKey: get("object_key"), Carrier: carrier}
	id, err := strconv.Atoi(get("image_id"))
	if err != nil {
		return job, Permanent(fmt.Errorf("malformed image_id %q: %w", get("image_id"), err))
	}
	job.ImageID = id
	return job, nil
}

type permanentError struct{ err error }

func (p permanentError) Error() string { return p.err.Error() }
func (p permanentError) Unwrap() error { return p.err }

// Permanent marks a failure retrying cannot fix: dead-letter immediately.
func Permanent(err error) error {
	if err == nil {
		return nil
	}
	return permanentError{err: err}
}

// IsPermanent reports whether err (or anything it wraps) is Permanent.
func IsPermanent(err error) bool {
	var p permanentError
	return errors.As(err, &p)
}

// entryAge is now minus the millisecond timestamp encoded in a stream ID ("<ms>-<seq>").
func entryAge(id string, now time.Time) float64 {
	ms, err := strconv.ParseInt(strings.SplitN(id, "-", 2)[0], 10, 64)
	if err != nil {
		return 0
	}
	return now.Sub(time.UnixMilli(ms)).Seconds()
}
```

- [ ] **Step 5: Create `internal/platform/queue/options.go`.**

```go
package queue

import (
	"context"
	"os"
	"time"

	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/metric"
	"go.opentelemetry.io/otel/propagation"
	"go.opentelemetry.io/otel/trace"
)

type options struct {
	tp           trace.TracerProvider
	mp           metric.MeterProvider
	prop         propagation.TextMapPropagator
	stream       string
	group        string
	deadLetter   string
	consumer     string
	maxLen       int64
	claimIdle    time.Duration
	maxAttempts  int
	backoff      func(attempt int) time.Duration
	concurrency  int
	block        time.Duration
	onDeadLetter func(context.Context, Job, error)
}

// Option configures a Producer or Consumer.
type Option func(*options)

func defaultOptions() options {
	host, _ := os.Hostname() // the pod name in Kubernetes: one consumer per pod
	return options{
		tp: otel.GetTracerProvider(), mp: otel.GetMeterProvider(), prop: otel.GetTextMapPropagator(),
		stream: DefaultStream, group: DefaultGroup, deadLetter: DefaultDeadLetter, consumer: host,
		maxLen: 10000, claimIdle: 60 * time.Second, maxAttempts: 4, concurrency: 2, block: 2 * time.Second,
		backoff: func(attempt int) time.Duration { return 500 * time.Millisecond << (attempt - 1) },
	}
}

func build(opts []Option) options {
	o := defaultOptions()
	for _, fn := range opts {
		fn(&o)
	}
	return o
}

func WithTracerProvider(tp trace.TracerProvider) Option          { return func(o *options) { o.tp = tp } }
func WithMeterProvider(mp metric.MeterProvider) Option           { return func(o *options) { o.mp = mp } }
func WithPropagator(p propagation.TextMapPropagator) Option      { return func(o *options) { o.prop = p } }
func WithStream(s string) Option                                 { return func(o *options) { o.stream = s } }
func WithGroup(g string) Option                                  { return func(o *options) { o.group = g } }
func WithDeadLetter(s string) Option                             { return func(o *options) { o.deadLetter = s } }
func WithConsumerName(n string) Option                           { return func(o *options) { o.consumer = n } }
func WithClaimIdle(d time.Duration) Option                       { return func(o *options) { o.claimIdle = d } }
func WithMaxAttempts(n int) Option                               { return func(o *options) { o.maxAttempts = n } }
func WithBackoff(f func(attempt int) time.Duration) Option       { return func(o *options) { o.backoff = f } }
func WithConcurrency(n int) Option                               { return func(o *options) { o.concurrency = n } }
func WithBlock(d time.Duration) Option                           { return func(o *options) { o.block = d } }
func WithDeadLetterHook(f func(context.Context, Job, error)) Option { return func(o *options) { o.onDeadLetter = f } }
```

- [ ] **Step 6: Create `internal/platform/queue/producer.go`.**

```go
package queue

import (
	"context"

	"github.com/redis/go-redis/v9"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/codes"
	"go.opentelemetry.io/otel/metric"
	"go.opentelemetry.io/otel/propagation"
	semconv "go.opentelemetry.io/otel/semconv/v1.43.0"
	"go.opentelemetry.io/otel/trace"

	obs "image-gallery/internal/observability"
)

// Producer appends jobs to the stream.
type Producer struct {
	rdb    redis.UniversalClient
	o      options
	tracer trace.Tracer
	sent   metric.Int64Counter
}

// NewProducer builds a producer on rdb.
func NewProducer(rdb redis.UniversalClient, opts ...Option) (*Producer, error) {
	o := build(opts)
	sent, err := o.mp.Meter("image-gallery/queue").Int64Counter(obs.MetricMessagingSent,
		metric.WithUnit("{message}"), metric.WithDescription("Jobs appended to the stream"))
	if err != nil {
		return nil, err
	}
	return &Producer{rdb: rdb, o: o, tracer: o.tp.Tracer("image-gallery/queue"), sent: sent}, nil
}

// Publish appends job under a PRODUCER span whose context travels in the entry,
// so the consumer continues the same trace. Returns the stream entry ID.
func (p *Producer) Publish(ctx context.Context, job Job) (string, error) {
	ctx, span := p.tracer.Start(ctx, "send "+p.o.stream, trace.WithSpanKind(trace.SpanKindProducer), trace.WithAttributes(
		semconv.MessagingSystemKey.String(messagingSystem),
		semconv.MessagingDestinationName(p.o.stream),
		semconv.MessagingOperationTypeKey.String("send"),
		attribute.Int(obs.AttrImageID, job.ImageID),
		attribute.String(obs.AttrJobType, job.Type)))
	defer span.End()

	carrier := propagation.MapCarrier{}
	p.o.prop.Inject(ctx, carrier)
	job.Carrier = carrier

	attrs := []attribute.KeyValue{semconv.MessagingSystemKey.String(messagingSystem), semconv.MessagingDestinationName(p.o.stream)}
	id, err := p.rdb.XAdd(ctx, &redis.XAddArgs{Stream: p.o.stream, MaxLen: p.o.maxLen, Approx: true, Values: job.values()}).Result()
	if err != nil {
		span.RecordError(err)
		span.SetStatus(codes.Error, "xadd failed")
		p.sent.Add(ctx, 1, metric.WithAttributes(append(attrs, semconv.ErrorTypeKey.String("xadd"))...))
		return "", err
	}
	span.SetAttributes(semconv.MessagingMessageID(id))
	p.sent.Add(ctx, 1, metric.WithAttributes(attrs...))
	return id, nil
}
```

- [ ] **Step 7: Create `internal/platform/queue/consumer.go`.**

```go
package queue

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"sync"
	"time"

	"github.com/redis/go-redis/v9"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/codes"
	"go.opentelemetry.io/otel/metric"
	"go.opentelemetry.io/otel/propagation"
	semconv "go.opentelemetry.io/otel/semconv/v1.43.0"
	"go.opentelemetry.io/otel/trace"

	obs "image-gallery/internal/observability"
)

// Handler processes one job. Return nil (done), ErrSkip (nothing to do),
// Permanent(err) (dead-letter now) or any other error (retry).
type Handler func(ctx context.Context, job Job) error

// Consumer reads the stream in a consumer group.
type Consumer struct {
	rdb        redis.UniversalClient
	o          options
	tracer     trace.Tracer
	jobs       metric.Int64Counter
	processDur metric.Float64Histogram
}

// NewConsumer builds a consumer on rdb.
func NewConsumer(rdb redis.UniversalClient, opts ...Option) (*Consumer, error) {
	o := build(opts)
	m := o.mp.Meter("image-gallery/queue")
	jobs, err := m.Int64Counter(obs.MetricWorkerJobs, metric.WithUnit("{job}"), metric.WithDescription("Job outcomes: success, retry, dead_letter, skipped"))
	if err != nil {
		return nil, err
	}
	dur, err := m.Float64Histogram(obs.MetricMessagingProcess, metric.WithUnit("s"), metric.WithDescription("Time from delivery to ack, all attempts included"))
	if err != nil {
		return nil, err
	}
	return &Consumer{rdb: rdb, o: o, tracer: o.tp.Tracer("image-gallery/queue"), jobs: jobs, processDur: dur}, nil
}

// EnsureGroup creates the stream and the consumer group if missing.
func (c *Consumer) EnsureGroup(ctx context.Context) error {
	err := c.rdb.XGroupCreateMkStream(ctx, c.o.stream, c.o.group, "0").Err()
	if err != nil && !strings.Contains(err.Error(), "BUSYGROUP") {
		return err
	}
	return nil
}

// Ready is the worker's readiness: the stream answers and the group exists.
func (c *Consumer) Ready(ctx context.Context) error {
	groups, err := c.rdb.XInfoGroups(ctx, c.o.stream).Result()
	if err != nil {
		return err
	}
	for _, g := range groups {
		if g.Name == c.o.group {
			return nil
		}
	}
	return fmt.Errorf("consumer group %s missing on %s", c.o.group, c.o.stream)
}

// Run consumes until ctx is cancelled, then returns once in-flight jobs are
// acked: it stops reading, it does not abandon work.
func (c *Consumer) Run(ctx context.Context, h Handler) error {
	if err := c.EnsureGroup(ctx); err != nil {
		return err
	}
	sem := make(chan struct{}, c.o.concurrency)
	var wg sync.WaitGroup
	defer wg.Wait()
	for ctx.Err() == nil {
		free := c.o.concurrency - len(sem)
		if free <= 0 {
			pause(ctx, 20*time.Millisecond)
			continue
		}
		msgs, err := c.fetch(ctx, int64(free))
		if err != nil {
			if ctx.Err() != nil {
				break
			}
			pause(ctx, time.Second) // Valkey unavailable: readiness reports it; retry the read
			continue
		}
		for _, m := range msgs {
			sem <- struct{}{}
			wg.Add(1)
			go func(m redis.XMessage) {
				defer wg.Done()
				defer func() { <-sem }()
				c.handle(context.WithoutCancel(ctx), m, h) // shutdown must not cut a job in half
			}(m)
		}
	}
	return nil
}

// fetch reclaims entries idle past claimIdle first, then reads new ones.
func (c *Consumer) fetch(ctx context.Context, n int64) ([]redis.XMessage, error) {
	claimed, _, err := c.rdb.XAutoClaim(ctx, &redis.XAutoClaimArgs{
		Stream: c.o.stream, Group: c.o.group, Consumer: c.o.consumer, MinIdle: c.o.claimIdle, Start: "0-0", Count: n,
	}).Result()
	if err != nil {
		return nil, err
	}
	if len(claimed) > 0 {
		return claimed, nil
	}
	streams, err := c.rdb.XReadGroup(ctx, &redis.XReadGroupArgs{
		Group: c.o.group, Consumer: c.o.consumer, Streams: []string{c.o.stream, ">"}, Count: n, Block: c.o.block,
	}).Result()
	if errors.Is(err, redis.Nil) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	var out []redis.XMessage
	for _, s := range streams {
		out = append(out, s.Messages...)
	}
	return out, nil
}

func (c *Consumer) handle(ctx context.Context, m redis.XMessage, h Handler) {
	start := time.Now()
	job, parseErr := jobFromMessage(m)
	parent := c.o.prop.Extract(ctx, propagation.MapCarrier(job.Carrier))
	ctx, span := c.tracer.Start(parent, "process "+c.o.stream,
		trace.WithSpanKind(trace.SpanKindConsumer),
		trace.WithLinks(trace.LinkFromContext(parent)), // explicit producer relationship, in addition to parenthood
		trace.WithAttributes(
			semconv.MessagingSystemKey.String(messagingSystem),
			semconv.MessagingDestinationName(c.o.stream),
			semconv.MessagingConsumerGroupName(c.o.group),
			semconv.MessagingOperationTypeKey.String("process"),
			semconv.MessagingMessageID(m.ID),
			attribute.Int(obs.AttrImageID, job.ImageID),
			attribute.String(obs.AttrJobType, job.Type)))
	defer span.End()

	outcome, err := obs.OutcomeDeadLetter, parseErr
	if parseErr == nil {
		outcome, err = c.attempts(ctx, job, h)
	}
	if outcome == obs.OutcomeDeadLetter {
		span.RecordError(err)
		span.SetStatus(codes.Error, "dead-lettered")
		c.deadLetter(ctx, m, job, err)
	}
	if ackErr := c.rdb.XAck(ctx, c.o.stream, c.o.group, m.ID).Err(); ackErr != nil {
		span.RecordError(ackErr)
	}
	attrs := metric.WithAttributes(attribute.String(obs.AttrJobType, job.Type), attribute.String(obs.AttrOutcome, outcome))
	c.jobs.Add(ctx, 1, attrs)
	c.processDur.Record(ctx, time.Since(start).Seconds(), metric.WithAttributes(
		semconv.MessagingSystemKey.String(messagingSystem), semconv.MessagingDestinationName(c.o.stream),
		attribute.String(obs.AttrJobType, job.Type), attribute.String(obs.AttrOutcome, outcome)))
}

// attempts runs h up to maxAttempts times with exponential backoff.
func (c *Consumer) attempts(ctx context.Context, job Job, h Handler) (string, error) {
	var err error
	for n := 1; n <= c.o.maxAttempts; n++ {
		err = c.attempt(ctx, job, h, n)
		switch {
		case err == nil:
			return obs.OutcomeSuccess, nil
		case errors.Is(err, ErrSkip):
			return obs.OutcomeSkipped, nil
		case IsPermanent(err) || n == c.o.maxAttempts:
			return obs.OutcomeDeadLetter, err
		}
		c.jobs.Add(ctx, 1, metric.WithAttributes(attribute.String(obs.AttrJobType, job.Type), attribute.String(obs.AttrOutcome, obs.OutcomeRetry)))
		pause(ctx, c.o.backoff(n))
	}
	return obs.OutcomeDeadLetter, err
}

func (c *Consumer) attempt(ctx context.Context, job Job, h Handler, n int) (err error) {
	ctx, span := c.tracer.Start(ctx, "job.attempt", trace.WithAttributes(attribute.Int(obs.AttrJobAttempt, n)))
	defer func() {
		if r := recover(); r != nil {
			err = fmt.Errorf("panic in handler: %v", r)
		}
		if err != nil && !errors.Is(err, ErrSkip) {
			kind := "transient"
			if IsPermanent(err) {
				kind = "permanent"
			}
			span.RecordError(err)
			span.SetStatus(codes.Error, "attempt failed")
			span.SetAttributes(semconv.ErrorTypeKey.String(kind))
		}
		span.End()
	}()
	return h(ctx, job)
}

func (c *Consumer) deadLetter(ctx context.Context, m redis.XMessage, job Job, cause error) {
	vals := map[string]any{"original_id": m.ID, "error": fmt.Sprint(cause), "failed_at": time.Now().UTC().Format(time.RFC3339Nano)}
	for k, v := range m.Values {
		vals[k] = v
	}
	if err := c.rdb.XAdd(ctx, &redis.XAddArgs{Stream: c.o.deadLetter, MaxLen: c.o.maxLen, Approx: true, Values: vals}).Err(); err != nil {
		trace.SpanFromContext(ctx).RecordError(err)
	}
	if c.o.onDeadLetter != nil {
		c.o.onDeadLetter(ctx, job, cause)
	}
}

// pause sleeps for d or until ctx is done.
func pause(ctx context.Context, d time.Duration) {
	t := time.NewTimer(d)
	defer t.Stop()
	select {
	case <-ctx.Done():
	case <-t.C:
	}
}
```

- [ ] **Step 8: Create `internal/platform/queue/metrics.go`.**

```go
package queue

import (
	"context"
	"time"

	"github.com/redis/go-redis/v9"
	"go.opentelemetry.io/otel/metric"
	semconv "go.opentelemetry.io/otel/semconv/v1.43.0"

	obs "image-gallery/internal/observability"
)

// RegisterGauges reports the consumer group's backlog on each collection.
// Pass an UNINSTRUMENTED client: these polls must not show up as traces.
//
//	queue.depth   entries not yet delivered to the group (XINFO GROUPS lag; XLEN also counts acked entries)
//	queue.pending delivered but not acked
//	queue.lag     age of the oldest pending entry, in seconds
func RegisterGauges(rdb redis.UniversalClient, meter metric.Meter, stream, group string) error {
	depth, err := meter.Int64ObservableGauge(obs.MetricQueueDepth, metric.WithUnit("{message}"), metric.WithDescription("Entries not yet delivered to the consumer group"))
	if err != nil {
		return err
	}
	pending, err := meter.Int64ObservableGauge(obs.MetricQueuePending, metric.WithUnit("{message}"), metric.WithDescription("Entries delivered but not acknowledged"))
	if err != nil {
		return err
	}
	lag, err := meter.Float64ObservableGauge(obs.MetricQueueLag, metric.WithUnit("s"), metric.WithDescription("Age of the oldest pending entry"))
	if err != nil {
		return err
	}
	attrs := metric.WithAttributes(semconv.MessagingDestinationName(stream), semconv.MessagingConsumerGroupName(group))
	_, err = meter.RegisterCallback(func(ctx context.Context, o metric.Observer) error {
		ctx, cancel := context.WithTimeout(ctx, 2*time.Second)
		defer cancel()
		groups, err := rdb.XInfoGroups(ctx, stream).Result()
		if err != nil {
			return err
		}
		for _, g := range groups {
			if g.Name != group {
				continue
			}
			if g.Lag >= 0 {
				o.ObserveInt64(depth, g.Lag, attrs)
			}
			o.ObserveInt64(pending, g.Pending, attrs)
		}
		sum, err := rdb.XPending(ctx, stream, group).Result()
		if err != nil {
			return err
		}
		age := 0.0
		if sum.Count > 0 {
			age = entryAge(sum.Lower, time.Now())
		}
		o.ObserveFloat64(lag, age, attrs)
		return nil
	}, depth, pending, lag)
	return err
}
```

- [ ] **Step 9: Instrument the cache client with redisotel.** In `internal/platform/cache/redis.go`, add the function below, and make `NewRedisClient` call it instead of `redis.NewClient` plus its own ping:

```go
// NewInstrumentedClient returns a Valkey client with redisotel tracing and
// metrics (db.client.* spans and connection-pool metrics), after a ping.
func NewInstrumentedClient(cfg config.CacheConfig) (*redis.Client, error) {
	rdb := redis.NewClient(&redis.Options{
		Addr: cfg.Address, Password: cfg.Password, DB: cfg.Database,
		MaxRetries: cfg.MaxRetries, MinRetryBackoff: cfg.MinRetryBackoff, MaxRetryBackoff: cfg.MaxRetryBackoff,
		DialTimeout: cfg.DialTimeout, ReadTimeout: cfg.ReadTimeout, WriteTimeout: cfg.WriteTimeout,
		PoolSize: cfg.PoolSize, MinIdleConns: cfg.MinIdleConns, PoolTimeout: cfg.PoolTimeout,
	})
	if err := redisotel.InstrumentTracing(rdb); err != nil {
		return nil, fmt.Errorf("redisotel tracing: %w", err)
	}
	if err := redisotel.InstrumentMetrics(rdb); err != nil {
		return nil, fmt.Errorf("redisotel metrics: %w", err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := rdb.Ping(ctx).Err(); err != nil {
		return nil, fmt.Errorf("failed to connect to Redis/Valkey: %w", err)
	}
	return rdb, nil
}
```

Import `github.com/redis/go-redis/extra/redisotel/v9`. `NewRedisClient` keeps its signature and its `if !cfg.Enabled` guard.

A blocking `XREADGROUP` longer than `ReadTimeout` (3 s by default) would time out. The queue's `Block` is 2 s, below it; keep it that way.

- [ ] **Step 10: Run the tests and confirm they pass.**

Run: `go mod tidy && go test ./internal/platform/queue/ ./internal/platform/cache/ -v`
Expected: PASS for all eight queue tests and the existing cache tests.

- [ ] **Step 11: Commit.**

```bash
git add go.mod go.sum internal/platform/queue internal/platform/cache/redis.go
git commit -m "feat(queue): Valkey stream jobs with trace propagation, retries and dead-lettering" \
  -m "The producer and consumer spans share one trace, and the consumer also links the producer. Failures retry with exponential backoff and then move to image-gallery:jobs:dead; XAUTOCLAIM recovers entries a dead worker held; shutdown finishes the in-flight job. queue.depth, queue.pending and queue.lag gauges; redisotel on the cache client."
```


### Task 11: Asynchronous upload, the thumbnail endpoint, and the web instruments

**Files:**
- Modify: `internal/domain/image/interfaces.go` (add `JobPublisher`).
- Create: `internal/services/implementations/job_publisher.go`.
- Modify: `internal/services/implementations/image_service.go` (status, enqueue, instrument names) and `settings_service.go` (instrument names).
- Modify: `internal/services/container.go` (`UseJobPublisher`).
- Modify: `internal/web/handlers/handlers.go` (route and `thumbnailImageHandler`), `api.go` (`ImageResponse`, card) and `upload.go` (drop the dimension stub).
- Modify: `cmd/server/main.go` (create the producer).
- Test: `internal/services/implementations/image_service_async_test.go` and `internal/web/handlers/thumbnail_test.go`.

**Interfaces:**
- Consumes: `queue.NewProducer`, `queue.Job`, `queue.JobTypeProcessImage` and `cache.NewInstrumentedClient` (Task 10); `image.StatusPending`/`StatusFailed` and `Repository.UpdateStatus` (Task 9); the Task 5 constants.
- Produces:
  - `type image.JobPublisher interface { PublishProcessImage(ctx context.Context, imageID int, objectKey string) error }`;
  - `func implementations.NewQueueJobPublisher(p *queue.Producer) image.JobPublisher`;
  - `(*ImageServiceImpl).SetJobPublisher(p image.JobPublisher)`;
  - `(*services.Container).UseJobPublisher(p image.JobPublisher)`;
  - the route `GET /api/images/{id}/thumbnail`;
  - `ImageResponse` gains `ThumbnailURL string` (json `thumbnail_url`) and `Status string` (json `status`).

- [ ] **Step 1: Write the failing service test.** Create `internal/services/implementations/image_service_async_test.go`:

```go
package implementations

import (
	"bytes"
	"context"
	"errors"
	"testing"

	"image-gallery/internal/config"
	"image-gallery/internal/domain/image"
	"image-gallery/internal/platform/storage"
	"image-gallery/internal/platform/storage/storetest"
)

type fakeRepo struct {
	byID   map[int]*image.Image
	nextID int
}

func newFakeRepo() *fakeRepo { return &fakeRepo{byID: map[int]*image.Image{}} }

func (f *fakeRepo) Create(_ context.Context, img *image.Image) error {
	f.nextID++
	img.ID = f.nextID
	cp := *img
	f.byID[img.ID] = &cp
	return nil
}
func (f *fakeRepo) GetByID(_ context.Context, id int) (*image.Image, error) {
	if img, ok := f.byID[id]; ok {
		cp := *img
		return &cp, nil
	}
	return nil, errors.New("not found")
}
func (f *fakeRepo) UpdateStatus(_ context.Context, id int, status string, msg *string) error {
	f.byID[id].Status, f.byID[id].ProcessingError = status, msg
	return nil
}
func (f *fakeRepo) CompleteProcessing(context.Context, int, image.ProcessingResult) error { return nil }
func (f *fakeRepo) List(context.Context, *image.ListImagesRequest) (*image.ListImagesResponse, error) {
	return &image.ListImagesResponse{}, nil
}
func (f *fakeRepo) Update(context.Context, *image.Image) error                      { return nil }
func (f *fakeRepo) Delete(context.Context, int) error                               { return nil }
func (f *fakeRepo) GetByFilename(context.Context, string) (*image.Image, error)     { return nil, errors.New("nf") }
func (f *fakeRepo) ExistsByFilename(context.Context, string) (bool, error)          { return false, nil }
func (f *fakeRepo) CountByTag(context.Context, string) (int, error)                 { return 0, nil }

type fakePublisher struct {
	err    error
	gotID  int
	gotKey string
}

func (p *fakePublisher) PublishProcessImage(_ context.Context, id int, key string) error {
	p.gotID, p.gotKey = id, key
	return p.err
}

func newAsyncService(t *testing.T, repo *fakeRepo, pub image.JobPublisher) image.ImageService {
	t.Helper()
	svc, err := storage.NewService(&config.StorageConfig{BucketName: "b", MaxUploadSize: 10 << 20}, storetest.NewMemStore())
	if err != nil {
		t.Fatal(err)
	}
	s := NewImageService(repo, nil, NewStorageService(svc), NewImageProcessor(), NewValidationService(), nil, nil)
	s.(*ImageServiceImpl).SetJobPublisher(pub)
	return s
}

func createReq(data []byte) *image.CreateImageRequest {
	return &image.CreateImageRequest{OriginalFilename: "cat.png", ContentType: "image/png", FileSize: int64(len(data))}
}

func TestCreateImageIsPendingAndEnqueued(t *testing.T) {
	repo, pub := newFakeRepo(), &fakePublisher{}
	data := tinyPNG(t)
	img, err := newAsyncService(t, repo, pub).CreateImage(context.Background(), createReq(data), bytes.NewReader(data))
	if err != nil {
		t.Fatal(err)
	}
	if img.Status != image.StatusPending || repo.byID[img.ID].Status != image.StatusPending {
		t.Fatalf("status = %q (stored %q), want pending", img.Status, repo.byID[img.ID].Status)
	}
	if pub.gotID != img.ID || pub.gotKey != img.StoragePath {
		t.Fatalf("published (%d, %q), want (%d, %q)", pub.gotID, pub.gotKey, img.ID, img.StoragePath)
	}
}

func TestCreateImageMarksFailedWhenEnqueueFails(t *testing.T) {
	repo, pub := newFakeRepo(), &fakePublisher{err: errors.New("valkey down")}
	data := tinyPNG(t)
	img, err := newAsyncService(t, repo, pub).CreateImage(context.Background(), createReq(data), bytes.NewReader(data))
	if err != nil {
		t.Fatalf("the upload itself succeeded, got %v", err)
	}
	stored := repo.byID[img.ID]
	if img.Status != image.StatusFailed || stored.Status != image.StatusFailed || stored.ProcessingError == nil {
		t.Fatalf("want failed with an error message, got %+v", stored)
	}
}
```

- [ ] **Step 2: Write the failing handler test.** Create `internal/web/handlers/thumbnail_test.go`:

```go
package handlers

import (
	"bytes"
	"context"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/go-chi/chi/v5"

	"image-gallery/internal/domain/image"
)

type stubImages struct{ img *image.Image }

func (s stubImages) GetImage(context.Context, int) (*image.Image, error) {
	if s.img == nil {
		return nil, errors.New("not found")
	}
	return s.img, nil
}
func (stubImages) CreateImage(context.Context, *image.CreateImageRequest, io.Reader) (*image.Image, error) {
	return nil, errors.New("unused")
}
func (stubImages) ListImages(context.Context, *image.ListImagesRequest) (*image.ListImagesResponse, error) {
	return nil, errors.New("unused")
}
func (stubImages) UpdateImage(context.Context, int, *image.UpdateImageRequest) (*image.Image, error) {
	return nil, errors.New("unused")
}
func (stubImages) DeleteImage(context.Context, int) error { return errors.New("unused") }
func (stubImages) DownloadImage(context.Context, int) (io.ReadCloser, string, error) {
	return nil, "", errors.New("unused")
}
func (stubImages) GetImageStats(context.Context) (*image.ImageStats, error) { return nil, errors.New("unused") }

type stubStorage struct{ objs map[string][]byte }

func (s stubStorage) Retrieve(_ context.Context, p string) (io.ReadCloser, error) {
	b, ok := s.objs[p]
	if !ok {
		return nil, errors.New("missing")
	}
	return io.NopCloser(bytes.NewReader(b)), nil
}
func (stubStorage) Store(context.Context, string, string, io.Reader, int64) (string, error) { return "", nil }
func (stubStorage) StoreAt(context.Context, string, string, io.Reader, int64) error        { return nil }
func (stubStorage) Delete(context.Context, string) error                                   { return nil }
func (stubStorage) Exists(context.Context, string) (bool, error)                           { return true, nil }
func (stubStorage) GetFileInfo(context.Context, string) (*image.FileInfo, error)           { return nil, nil }

func serveThumb(t *testing.T, img *image.Image) *httptest.ResponseRecorder {
	t.Helper()
	h := &Handler{imageService: stubImages{img: img}, storageService: stubStorage{objs: map[string][]byte{
		"orig.png": []byte("ORIGINAL"), "thumbnails/1.jpg": []byte("THUMB"),
	}}}
	r := chi.NewRouter()
	r.Get("/api/images/{id}/thumbnail", h.thumbnailImageHandler)
	rec := httptest.NewRecorder()
	r.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/api/images/1/thumbnail", nil))
	return rec
}

func TestThumbnailServesThumbnailWhenReady(t *testing.T) {
	thumb := "thumbnails/1.jpg"
	rec := serveThumb(t, &image.Image{ID: 1, StoragePath: "orig.png", ContentType: "image/png", ThumbnailPath: &thumb, Status: image.StatusReady})
	if rec.Code != 200 || rec.Body.String() != "THUMB" || rec.Header().Get("Content-Type") != "image/jpeg" {
		t.Fatalf("got %d %q %q", rec.Code, rec.Body.String(), rec.Header().Get("Content-Type"))
	}
}

func TestThumbnailFallsBackToOriginalWhilePending(t *testing.T) {
	rec := serveThumb(t, &image.Image{ID: 1, StoragePath: "orig.png", ContentType: "image/png", Status: image.StatusPending})
	if rec.Code != 200 || rec.Body.String() != "ORIGINAL" || rec.Header().Get("Content-Type") != "image/png" {
		t.Fatalf("got %d %q %q", rec.Code, rec.Body.String(), rec.Header().Get("Content-Type"))
	}
}
```

If `image.ImageService` has methods other than the ones stubbed after Task 8, add stubs until it compiles. The two test functions stay as they are.

- [ ] **Step 3: Run the tests and confirm they fail.**

Run: `go test ./internal/services/implementations/ ./internal/web/handlers/ -short -run 'TestCreateImage|TestThumbnail' -v`
Expected: FAIL to compile with `SetJobPublisher undefined`, `thumbnailImageHandler undefined` and unknown fields.

- [ ] **Step 4: Add the publisher and the service changes.**
  - **`interfaces.go`:** add

```go
// JobPublisher hands an uploaded image to the asynchronous worker.
type JobPublisher interface {
	PublishProcessImage(ctx context.Context, imageID int, objectKey string) error
}
```

  - **Create `internal/services/implementations/job_publisher.go`:**

```go
package implementations

import (
	"context"

	"image-gallery/internal/domain/image"
	"image-gallery/internal/platform/queue"
)

type queueJobPublisher struct{ p *queue.Producer }

// NewQueueJobPublisher publishes processing jobs on the Valkey stream.
func NewQueueJobPublisher(p *queue.Producer) image.JobPublisher { return queueJobPublisher{p: p} }

func (q queueJobPublisher) PublishProcessImage(ctx context.Context, imageID int, objectKey string) error {
	_, err := q.p.Publish(ctx, queue.Job{Type: queue.JobTypeProcessImage, ImageID: imageID, ObjectKey: objectKey})
	return err
}
```

  - **`image_service.go`:**
    - Add the field `jobs image.JobPublisher` and:

```go
// SetJobPublisher wires the asynchronous processing queue.
func (s *ImageServiceImpl) SetJobPublisher(p image.JobPublisher) { s.jobs = p }

// enqueueProcessing hands the image to the worker. The upload has already
// succeeded, so an enqueue failure marks the image failed rather than failing the request.
func (s *ImageServiceImpl) enqueueProcessing(ctx context.Context, img *image.Image) {
	if s.jobs == nil {
		return // no queue configured (local run without Valkey): the image stays pending
	}
	if err := s.jobs.PublishProcessImage(ctx, img.ID, img.StoragePath); err != nil {
		trace.SpanFromContext(ctx).RecordError(err)
		msg := "enqueue failed: " + err.Error()
		if uErr := s.imageRepo.UpdateStatus(ctx, img.ID, image.StatusFailed, &msg); uErr == nil {
			img.Status, img.ProcessingError = image.StatusFailed, &msg
		}
	}
}
```

    - In `buildImageObject`, set `Status: image.StatusPending`.
    - In `CreateImage`, call `s.enqueueProcessing(ctx, img)` right after `s.handlePostCreation(ctx, img)`.
    - Replace the instruments. Delete `imageProcessingTime`, `imageDeletionTime`, `cacheHitCounter`, `cacheMissCounter`, `imageUploadCounter` and `imageDeletionCounter`, and create:

```go
	uploads, _ := meter.Int64Counter(obs.MetricImageUploads, metric.WithUnit("{upload}"), metric.WithDescription("Image uploads by outcome"))
	deletions, _ := meter.Int64Counter(obs.MetricImageDeletions, metric.WithUnit("{deletion}"), metric.WithDescription("Image deletions by outcome"))
	cacheLookups, _ := meter.Int64Counter(obs.MetricCacheLookups, metric.WithUnit("{lookup}"), metric.WithDescription("Cache lookups by cache and result"))
```

    - Give `CreateImage` the named results `(img *image.Image, err error)` and add, right after the span starts:

```go
	defer func() {
		outcome := obs.OutcomeSuccess
		if err != nil {
			outcome = obs.OutcomeError
		}
		s.uploads.Add(ctx, 1, metric.WithAttributes(attribute.String(obs.AttrImageContentType, req.ContentType), attribute.String(obs.AttrOutcome, outcome)))
	}()
```

      Delete `recordImageCreationMetrics`, and in `DeleteImage` do the same with `s.deletions` and the outcome attribute only.
    - Replace each cache-hit or cache-miss `.Add(...)` in `GetImage` with `s.cacheLookups.Add(ctx, 1, metric.WithAttributes(attribute.String(obs.AttrCacheName, "image"), attribute.String(obs.AttrCacheResult, "hit")))` (or `"miss"`). In `ListImages`, do the same with `"list"`.
  - **`settings_service.go`:** replace the four counters with `settingsOps` (`obs.MetricSettingsOps`) and `cacheLookups` (`obs.MetricCacheLookups`):
    - `recordReadMetric(ctx, source, _)` becomes `settingsOps.Add(ctx, 1, attrs(settings.operation=read, settings.source=<source>))`;
    - the write metric becomes `settings.operation=write, settings.source=database`;
    - hit and miss become `cache.lookups{cache.name=settings, cache.result=hit|miss}`.

    Drop the `user_id` metric attribute: it has unbounded cardinality, and it stays on the span.
  - **`container.go`:**

```go
// UseJobPublisher wires the asynchronous processing queue into the image service.
func (c *Container) UseJobPublisher(p image.JobPublisher) {
	if s, ok := c.imageService.(interface{ SetJobPublisher(image.JobPublisher) }); ok {
		s.SetJobPublisher(p)
	}
}
```

- [ ] **Step 5: Handler changes.**
  - **`handlers.go`:** in the `/images` route block, add `r.Get("/{id}/thumbnail", h.thumbnailImageHandler) // Thumbnail, or the original until the worker is done`. Then add:

```go
// thumbnailImageHandler serves the worker's thumbnail, or the original while
// the image is pending, processing or failed.
func (h *Handler) thumbnailImageHandler(w http.ResponseWriter, r *http.Request) {
	id, err := strconv.Atoi(chi.URLParam(r, "id"))
	if err != nil {
		http.Error(w, "invalid image id", http.StatusBadRequest)
		return
	}
	img, err := h.imageService.GetImage(r.Context(), id)
	if err != nil {
		http.Error(w, "image not found", http.StatusNotFound)
		return
	}
	path, contentType := img.StoragePath, img.ContentType
	if img.ThumbnailPath != nil && *img.ThumbnailPath != "" {
		path, contentType = *img.ThumbnailPath, thumbnailContentType(*img.ThumbnailPath)
	}
	rc, err := h.storageService.Retrieve(r.Context(), path)
	if err != nil {
		http.Error(w, "image unavailable", http.StatusBadGateway)
		return
	}
	defer func() { _ = rc.Close() }()
	w.Header().Set("Content-Type", contentType)
	w.Header().Set("Cache-Control", "public, max-age=300")
	_, _ = io.Copy(w, rc)
}

func thumbnailContentType(path string) string {
	switch strings.ToLower(filepath.Ext(path)) {
	case ".png":
		return "image/png"
	case ".gif":
		return "image/gif"
	default:
		return "image/jpeg"
	}
}
```

  - **`api.go`:**
    - Add `Status string `json:"status"`` and `ThumbnailURL string `json:"thumbnail_url"`` to `ImageResponse`.
    - In `convertDomainImagesToResponse`, set `ThumbnailURL: fmt.Sprintf("/api/images/%d/thumbnail", img.ID), Status: img.Status`.
    - In `renderImageCard`, the gallery `<img src="%s"` takes `img.ThumbnailURL`; the modal keeps `img.URL`. In the argument list `img.URL, img.Name, img.URL, img.Name, img.Size`, change the FIRST `img.URL` to `img.ThumbnailURL`, and add `loading="lazy"` to that `<img>`.
  - **`upload.go`:** delete the `extractImageDimensions` call and the function (the worker extracts dimensions now), and leave `Width`/`Height` nil in `createReq`. Drop the `bytes` import if it becomes unused.
  - **`cmd/server/main.go`:** after the container is built, wire the queue:

```go
	if cfg.Cache.Address != "" {
		rdb, err := cache.NewInstrumentedClient(cfg.Cache)
		if err != nil {
			logger.GetZerolog().Fatal().Err(err).Msg("Failed to connect to Valkey for the job queue")
		}
		producer, err := queue.NewProducer(rdb)
		if err != nil {
			logger.GetZerolog().Fatal().Err(err).Msg("Failed to create the job producer")
		}
		container.UseJobPublisher(implementations.NewQueueJobPublisher(producer))
	}
```

- [ ] **Step 6: Run the tests and confirm they pass.**

Run: `go build ./... && go test -short ./... && go test ./internal/services/implementations/ ./internal/web/handlers/ -run 'TestCreateImage|TestThumbnail' -v`
Expected: PASS.

- [ ] **Step 7: Commit.**

```bash
git add -A internal cmd
git commit -m "feat(upload): hand images to the worker queue and serve thumbnails" \
  -m "An upload stores the original, writes a pending row, publishes a process_image job and returns. /api/images/{id}/thumbnail serves the worker's thumbnail, falling back to the original. Web instruments follow the telemetry contract: image.uploads, image.deletions, cache.lookups, settings.operations." \
  -m "BREAKING CHANGE: image.uploads.total, image.deletions.total, image.cache.hits/misses, settings.read/write.total and settings.cache.hits/misses are replaced by image.uploads, image.deletions, cache.lookups and settings.operations."
```

### Task 12: One binary with subcommands, a shared bootstrap, and the image entrypoint

**Files:**
- Create: `cmd/image-gallery/main.go`, `cmd/image-gallery/main_test.go`, `internal/app/bootstrap.go` and `internal/app/serve.go`.
- Delete: `cmd/server/main.go`.
- Modify: `Dockerfile`, `Dockerfile.goreleaser`, `.goreleaser.yml`, `.github/workflows/ci.yml` (`build-test`'s `--pkg`), `Makefile` (`build` and `run`) and `.air.toml`.

**Interfaces:**
- Consumes: everything built so far.
- Produces:
  - `type app.Deps struct { Cfg *config.Config; Logger *observability.Logger; OTel *observability.Provider; DB *sql.DB; Store storage.ObjectStore; Redis *redis.Client }`;
  - `func app.Bootstrap(ctx context.Context, defaultService string) (*Deps, error)`;
  - `func (*Deps) Close(ctx context.Context)`;
  - `func app.RunServe(ctx context.Context) error`;
  - `func run(args []string) int` in `cmd/image-gallery`.
- Tasks 13 and 15 add their own `case` to `run`.
- The image entrypoint is `ENTRYPOINT ["/app/image-gallery"]` with `CMD ["serve"]`. The App's main container runs it without args (`serve`); the sidecar passes `args: ["worker"]`, which replaces only `CMD`.

- [ ] **Step 1: Write the failing test.** Create `cmd/image-gallery/main_test.go`:

```go
package main

import "testing"

func TestRunDispatch(t *testing.T) {
	if code := run([]string{"help"}); code != 0 {
		t.Errorf("help exit = %d, want 0", code)
	}
	if code := run([]string{"no-such-command"}); code != 2 {
		t.Errorf("unknown command exit = %d, want 2", code)
	}
}
```

- [ ] **Step 2: Run it and confirm it fails.**

Run: `go test ./cmd/image-gallery/ -v`
Expected: FAIL with `no non-test Go files` or `undefined: run`.

- [ ] **Step 3: Create `internal/app/bootstrap.go`.**

```go
// Package app holds what the long-running roles (serve, worker) share.
package app

import (
	"context"
	"database/sql"
	"fmt"
	"os"
	"time"

	"github.com/joho/godotenv"
	"github.com/redis/go-redis/v9"

	"image-gallery/internal/config"
	"image-gallery/internal/observability"
	"image-gallery/internal/platform/cache"
	"image-gallery/internal/platform/database"
	"image-gallery/internal/platform/storage"
)

// Deps are the connections every role needs.
type Deps struct {
	Cfg    *config.Config
	Logger *observability.Logger
	OTel   *observability.Provider
	DB     *sql.DB
	Store  storage.ObjectStore
	Redis  *redis.Client // instrumented; nil when CACHE_ADDRESS is empty
}

// Bootstrap loads configuration and connects telemetry, Postgres, object
// storage and Valkey. defaultService names the role when OTEL_SERVICE_NAME is
// unset (local runs); in the cluster the composition or the sidecar env sets it.
func Bootstrap(ctx context.Context, defaultService string) (*Deps, error) {
	_ = godotenv.Load() //nolint:errcheck // .env is optional
	cfg, err := config.Load()
	if err != nil {
		return nil, fmt.Errorf("config: %w", err)
	}
	if os.Getenv("OTEL_SERVICE_NAME") == "" {
		cfg.Observability.ServiceName = defaultService
	}
	oc := observability.Config{
		ServiceName: cfg.Observability.ServiceName, ServiceVersion: cfg.Observability.ServiceVersion,
		Environment: cfg.Observability.Environment, PodName: cfg.Observability.PodName, PodNamespace: cfg.Observability.PodNamespace,
		TracesEndpoint: cfg.Observability.TracesEndpoint, TracesEnabled: cfg.Observability.TracesEnabled,
		TracesSampler: cfg.Observability.TracesSampler, TracesSamplerArg: cfg.Observability.TracesSamplerArg,
		MetricsEndpoint: cfg.Observability.MetricsEndpoint, MetricsEnabled: cfg.Observability.MetricsEnabled,
		LogLevel: cfg.Logging.Level, LogFormat: cfg.Logging.Format,
	}
	d := &Deps{Cfg: cfg, Logger: observability.NewLogger(oc)}
	if d.OTel, err = observability.NewProvider(ctx, oc, d.Logger); err != nil {
		return nil, fmt.Errorf("opentelemetry: %w", err)
	}
	if d.DB, err = database.NewConnection(cfg.DatabaseURL); err != nil {
		d.Close(ctx)
		return nil, fmt.Errorf("database: %w", err)
	}
	if d.Store, err = storage.NewObjectStore(ctx, cfg.Storage); err != nil {
		d.Close(ctx)
		return nil, fmt.Errorf("object storage (%s): %w", cfg.Storage.Provider, err)
	}
	if cfg.Cache.Address != "" {
		if d.Redis, err = cache.NewInstrumentedClient(cfg.Cache); err != nil {
			d.Close(ctx)
			return nil, fmt.Errorf("valkey: %w", err)
		}
	}
	d.Logger.GetZerolog().Info().Str("storage.provider", d.Store.Provider()).Msg("bootstrap complete")
	return d, nil
}

// Close flushes telemetry and releases connections, whatever was opened.
func (d *Deps) Close(ctx context.Context) {
	ctx, cancel := context.WithTimeout(context.WithoutCancel(ctx), 10*time.Second)
	defer cancel()
	if d.Redis != nil {
		_ = d.Redis.Close()
	}
	if d.DB != nil {
		_ = d.DB.Close()
	}
	if d.OTel != nil {
		_ = d.OTel.ForceFlush(ctx)
		_ = d.OTel.Shutdown(ctx)
	}
}
```

- [ ] **Step 4: Create `internal/app/serve.go`.** Move `main()`'s logic here, minus what `Bootstrap` now does. Keep `syncExistingImages` verbatim, moved as an unexported function.

```go
package app

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"time"

	"image-gallery/internal/platform/queue"
	"image-gallery/internal/platform/server"
	"image-gallery/internal/services"
	"image-gallery/internal/services/implementations"
	"image-gallery/internal/web/handlers"
)

// RunServe runs the web role until ctx is cancelled.
func RunServe(ctx context.Context) error {
	d, err := Bootstrap(ctx, "image-gallery")
	if err != nil {
		return err
	}
	defer d.Close(ctx)
	log := d.Logger.GetZerolog()

	container, err := services.NewContainerWithObservability(d.Cfg, d.DB, d.Store, d.Logger)
	if err != nil {
		return fmt.Errorf("services: %w", err)
	}
	if d.Redis != nil {
		producer, err := queue.NewProducer(d.Redis)
		if err != nil {
			return fmt.Errorf("job producer: %w", err)
		}
		container.UseJobPublisher(implementations.NewQueueJobPublisher(producer))
	}
	if d.Cfg.Storage.SyncOnStartup {
		if err := syncExistingImages(ctx, container, d.Logger); err != nil {
			log.Error().Err(err).Msg("Failed to sync existing images, continuing startup")
		}
	}

	srv := server.New(d.Cfg.Port, handlers.NewWithContainer(container).Routes())
	errCh := make(chan error, 1)
	go func() {
		log.Info().Str("port", d.Cfg.Port).Msg("web role listening")
		if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			errCh <- err
		}
		close(errCh)
	}()
	select {
	case <-ctx.Done():
	case err := <-errCh:
		return err
	}
	log.Info().Msg("web role shutting down")
	shutdownCtx, cancel := context.WithTimeout(context.WithoutCancel(ctx), 30*time.Second)
	defer cancel()
	return srv.Shutdown(shutdownCtx)
}
```

- [ ] **Step 5: Create `cmd/image-gallery/main.go`.**

```go
// Command image-gallery runs one role of the application:
//
//	image-gallery serve     web UI and API (default)
//	image-gallery worker    asynchronous image processing (queue consumer)
//	image-gallery loadgen   load generator
package main

import (
	"context"
	"fmt"
	"io"
	"log/slog"
	"os"
	"os/signal"
	"syscall"

	"github.com/KimMachineGun/automemlimit/memlimit"

	"image-gallery/internal/app"
)

func init() {
	// GOMEMLIMIT = 90 % of this container's cgroup limit: the GC works harder
	// before the kernel OOM-kills. Each container has its own cgroup, so the
	// web and worker containers each get their own limit.
	if _, err := memlimit.SetGoMemLimitWithOpts(
		memlimit.WithRatio(0.9),
		memlimit.WithProvider(memlimit.FromCgroup),
		memlimit.WithLogger(slog.Default()),
	); err != nil {
		slog.Warn("Failed to set automatic memory limit", "error", err)
	}
}

func main() { os.Exit(run(os.Args[1:])) }

func run(args []string) int {
	cmd := "serve"
	if len(args) > 0 {
		cmd, args = args[0], args[1:]
	}
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()
	switch cmd {
	case "serve":
		return exitCode(app.RunServe(ctx))
	case "help", "-h", "--help":
		usage(os.Stdout)
		return 0
	default:
		fmt.Fprintf(os.Stderr, "unknown command %q\n\n", cmd)
		usage(os.Stderr)
		return 2
	}
}

func exitCode(err error) int {
	if err != nil {
		fmt.Fprintln(os.Stderr, "error:", err)
		return 1
	}
	return 0
}

func usage(w io.Writer) {
	fmt.Fprint(w, `Usage: image-gallery <command> [flags]

Commands:
  serve     web UI and API (default)
  worker    asynchronous image processing
  loadgen   load generator (image-gallery loadgen -h)
`)
}
```

If automemlimit v1.0.0 renamed any option, keep the ratio at 0.9 and the cgroup provider (the same rule as Task 5).

- [ ] **Step 6: Delete `cmd/server/` and rename the binary everywhere.**
  - **`Dockerfile`:** the build line becomes `-o image-gallery ./cmd/image-gallery`; `ls -la /app/image-gallery`; `COPY --from=builder /app/image-gallery /app/image-gallery`; `chmod +x /app/image-gallery`; and replace `CMD ["/app/server"]` with:

```dockerfile
# ENTRYPOINT + CMD: a Kubernetes `args` (the worker sidecar's ["worker"]) replaces CMD only.
ENTRYPOINT ["/app/image-gallery"]
CMD ["serve"]
```

  - **`Dockerfile.goreleaser`:** make the same binary rename and the same `ENTRYPOINT`/`CMD`.
  - **`.goreleaser.yml`:** `binary: image-gallery`, `main: ./cmd/image-gallery`.
  - **`.github/workflows/ci.yml`:** `build --pkg=./cmd/image-gallery`, and `binary_name=image-gallery-$OS-$ARCH`.
  - **`Makefile`:** `go build -o ./bin/image-gallery ./cmd/image-gallery`; `run: build` → `./bin/image-gallery serve`; `rm -rf ./bin` is unchanged.
  - **`.air.toml`:** point `cmd`/`bin` at `./cmd/image-gallery` and `./bin/image-gallery serve`.
  - Run `grep -rn 'cmd/server\|/app/server\|bin/server' --exclude-dir=.git .`. Expected: no matches, other than historical lines in `CHANGELOG.md`.

- [ ] **Step 7: Run the tests and confirm they pass; build the image.**

Run: `go test ./cmd/image-gallery/ -v && go build ./... && go test -short ./... && docker build -t image-gallery:dev . && docker run --rm image-gallery:dev help`
Expected: PASS, and the container prints the usage text, which proves `args` reach the entrypoint.

- [ ] **Step 8: Commit.**

```bash
git add -A cmd internal/app Dockerfile Dockerfile.goreleaser .goreleaser.yml .github/workflows/ci.yml Makefile .air.toml
git commit -m "feat(cli): one image-gallery binary with serve as the default command" \
  -m "A shared Bootstrap builds telemetry, Postgres, object storage and Valkey for every role. The image uses ENTRYPOINT image-gallery with CMD serve, so a sidecar's args select another role." \
  -m "BREAKING CHANGE: the binary is /app/image-gallery (was /app/server) and cmd/server is removed."
```


### Task 13: The worker role

**Files:**
- Create: `internal/worker/processor.go`, `internal/worker/health.go` and `internal/app/worker.go`.
- Modify: `cmd/image-gallery/main.go` (add `case "worker"`).
- Test: `internal/worker/processor_test.go` and `internal/worker/health_test.go`.

**Interfaces:**
- Consumes:
  - `queue.Job`, `queue.ErrSkip`, `queue.Permanent`, `queue.NewConsumer`, `queue.WithConcurrency`, `queue.WithDeadLetterHook`, `queue.RegisterGauges`, `queue.DefaultStream` and `queue.DefaultGroup` (Task 10);
  - `image.Repository.UpdateStatus` and `CompleteProcessing`, and `image.StorageService.StoreAt` (Tasks 8–9);
  - `storage.NewImageProcessor` (existing: `GenerateThumbnail`, `GetImageInfo`);
  - `app.Bootstrap` (Task 12).
- Produces:
  - `type worker.Faults interface { WorkerFault(ctx context.Context) error }` (Task 14 implements it; nil means no faults);
  - `func worker.NewProcessor(images image.Repository, store image.StorageService, faults Faults, log *observability.Logger) *Processor`;
  - `(*Processor).Handle(ctx context.Context, job queue.Job) error` and `(*Processor).OnDeadLetter(ctx context.Context, job queue.Job, cause error)`;
  - `func worker.NewHealthHandler(ready func(context.Context) error) http.Handler`;
  - `func app.RunWorker(ctx context.Context) error`.
  - Environment: `WORKER_HEALTH_ADDR` (default `:8081`) and `WORKER_CONCURRENCY` (default `2`).

- [ ] **Step 1: Write the failing tests.** Create `internal/worker/processor_test.go`:

```go
package worker

import (
	"bytes"
	"context"
	"errors"
	"image"
	"image/color"
	"image/png"
	"testing"

	"go.opentelemetry.io/otel"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
	"go.opentelemetry.io/otel/sdk/trace/tracetest"

	"image-gallery/internal/config"
	domain "image-gallery/internal/domain/image"
	"image-gallery/internal/platform/queue"
	"image-gallery/internal/platform/storage"
	"image-gallery/internal/platform/storage/storetest"
	"image-gallery/internal/services/implementations"
)

type fakeImages struct {
	img    domain.Image
	result *domain.ProcessingResult
	errMsg *string
}

func (f *fakeImages) GetByID(context.Context, int) (*domain.Image, error) { cp := f.img; return &cp, nil }
func (f *fakeImages) UpdateStatus(_ context.Context, _ int, s string, msg *string) error {
	f.img.Status, f.errMsg = s, msg
	return nil
}
func (f *fakeImages) CompleteProcessing(_ context.Context, _ int, r domain.ProcessingResult) error {
	f.img.Status, f.result = domain.StatusReady, &r
	return nil
}
func (f *fakeImages) Create(context.Context, *domain.Image) error { return nil }
func (f *fakeImages) List(context.Context, *domain.ListImagesRequest) (*domain.ListImagesResponse, error) {
	return nil, nil
}
func (f *fakeImages) Update(context.Context, *domain.Image) error                 { return nil }
func (f *fakeImages) Delete(context.Context, int) error                           { return nil }
func (f *fakeImages) GetByFilename(context.Context, string) (*domain.Image, error) { return nil, nil }
func (f *fakeImages) ExistsByFilename(context.Context, string) (bool, error)      { return false, nil }
func (f *fakeImages) CountByTag(context.Context, string) (int, error)             { return 0, nil }

type faultFn func(context.Context) error

func (f faultFn) WorkerFault(ctx context.Context) error { return f(ctx) }

func pngBytes(t *testing.T, w, h int) []byte {
	t.Helper()
	img := image.NewRGBA(image.Rect(0, 0, w, h))
	img.Set(0, 0, color.RGBA{G: 255, A: 255})
	var buf bytes.Buffer
	if err := png.Encode(&buf, img); err != nil {
		t.Fatal(err)
	}
	return buf.Bytes()
}

func setup(t *testing.T, status string, faults Faults) (*Processor, *fakeImages, *storetest.MemStore, *tracetest.InMemoryExporter) {
	t.Helper()
	exp := tracetest.NewInMemoryExporter()
	otel.SetTracerProvider(sdktrace.NewTracerProvider(sdktrace.WithSyncer(exp)))
	mem := storetest.NewMemStore()
	data := pngBytes(t, 64, 48)
	if err := mem.Put(context.Background(), "aa/bb/cat.png", "image/png", bytes.NewReader(data), int64(len(data)), nil); err != nil {
		t.Fatal(err)
	}
	svc, err := storage.NewService(&config.StorageConfig{BucketName: "b", MaxUploadSize: 10 << 20}, mem)
	if err != nil {
		t.Fatal(err)
	}
	imgs := &fakeImages{img: domain.Image{ID: 1, StoragePath: "aa/bb/cat.png", ContentType: "image/png", Status: status}}
	return NewProcessor(imgs, implementations.NewStorageService(svc), faults, nil), imgs, mem, exp
}

func job() queue.Job { return queue.Job{Type: queue.JobTypeProcessImage, ImageID: 1, ObjectKey: "aa/bb/cat.png"} }

func TestHandleBuildsThumbnailAndMarksReady(t *testing.T) {
	p, imgs, mem, exp := setup(t, domain.StatusPending, nil)
	if err := p.Handle(context.Background(), job()); err != nil {
		t.Fatal(err)
	}
	r := imgs.result
	if r == nil || r.Width != 64 || r.Height != 48 || r.ThumbnailPath != "thumbnails/1.png" || r.Format != "png" {
		t.Fatalf("result = %+v", r)
	}
	if _, err := mem.Stat(context.Background(), "thumbnails/1.png"); err != nil {
		t.Fatalf("thumbnail not stored: %v", err)
	}
	steps := map[string]bool{}
	for _, s := range exp.GetSpans() {
		steps[s.Name] = true
	}
	for _, want := range []string{"image.fetch", "image.decode", "image.thumbnail", "image.store"} {
		if !steps[want] {
			t.Errorf("missing span %s (have %v)", want, steps)
		}
	}
}

func TestHandleSkipsReadyImage(t *testing.T) {
	p, _, _, _ := setup(t, domain.StatusReady, nil)
	if err := p.Handle(context.Background(), job()); !errors.Is(err, queue.ErrSkip) {
		t.Fatalf("want ErrSkip, got %v", err)
	}
}

func TestHandleRejectsOversizedImageAsPermanent(t *testing.T) {
	p, _, _, _ := setup(t, domain.StatusPending, nil)
	p.maxPixels = 100 // 64x48 = 3072 pixels
	if err := p.Handle(context.Background(), job()); !queue.IsPermanent(err) {
		t.Fatalf("want a permanent error, got %v", err)
	}
}

func TestInjectedFaultIsRetryable(t *testing.T) {
	boom := errors.New("demo fault: injected worker failure")
	p, _, _, _ := setup(t, domain.StatusPending, faultFn(func(context.Context) error { return boom }))
	err := p.Handle(context.Background(), job())
	if !errors.Is(err, boom) || queue.IsPermanent(err) {
		t.Fatalf("want the retryable fault, got %v", err)
	}
}

func TestOnDeadLetterMarksFailed(t *testing.T) {
	p, imgs, _, _ := setup(t, domain.StatusProcessing, nil)
	p.OnDeadLetter(context.Background(), job(), errors.New("gave up"))
	if imgs.img.Status != domain.StatusFailed || imgs.errMsg == nil || *imgs.errMsg != "gave up" {
		t.Fatalf("status %q msg %v", imgs.img.Status, imgs.errMsg)
	}
}
```

Create `internal/worker/health_test.go`:

```go
package worker

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestHealthEndpoints(t *testing.T) {
	var readyErr error
	h := NewHealthHandler(func(context.Context) error { return readyErr })
	get := func(p string) int {
		rec := httptest.NewRecorder()
		h.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, p, nil))
		return rec.Code
	}
	if get("/healthz") != 200 || get("/readyz") != 200 {
		t.Fatal("healthy worker must answer 200 on both probes")
	}
	readyErr = errors.New("consumer group missing")
	if get("/readyz") != 503 || get("/healthz") != 200 {
		t.Fatal("readiness must fail alone when the queue is not ready")
	}
}
```

- [ ] **Step 2: Run the tests and confirm they fail.**

Run: `go test ./internal/worker/ -v`
Expected: FAIL to compile with `undefined: NewProcessor` and `NewHealthHandler`.

- [ ] **Step 3: Create `internal/worker/processor.go`.**

```go
// Package worker turns process_image jobs into thumbnails and metadata.
package worker

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"time"

	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/codes"
	"go.opentelemetry.io/otel/metric"
	"go.opentelemetry.io/otel/trace"

	domain "image-gallery/internal/domain/image"
	obs "image-gallery/internal/observability"
	"image-gallery/internal/platform/queue"
	"image-gallery/internal/platform/storage"
)

// Faults injects demo faults into job processing (nil = none).
type Faults interface {
	WorkerFault(ctx context.Context) error
}

// Processor handles process_image jobs. Processing is idempotent by image ID:
// the thumbnail key is deterministic and a ready image is skipped.
type Processor struct {
	images    domain.Repository
	store     domain.StorageService
	decoder   *storage.ImageProcessor
	faults    Faults
	log       *obs.Logger
	tracer    trace.Tracer
	stepDur   metric.Float64Histogram
	maxBytes  int64 // upload cap: 10 MiB
	maxPixels int   // decode guard: bounds worker memory per job
	thumbSize int
}

// NewProcessor builds a Processor; faults and log may be nil.
func NewProcessor(images domain.Repository, store domain.StorageService, faults Faults, log *obs.Logger) *Processor {
	stepDur, _ := otel.Meter("image-gallery/worker").Float64Histogram(obs.MetricImageProcessing,
		metric.WithUnit("s"), metric.WithDescription("Duration of each image-processing step"))
	return &Processor{images: images, store: store, decoder: storage.NewImageProcessor(0, 0, 85), faults: faults, log: log,
		tracer: otel.Tracer("image-gallery/worker"), stepDur: stepDur, maxBytes: 10 << 20, maxPixels: 40_000_000, thumbSize: 320}
}

// Handle is the queue.Handler for process_image jobs.
func (p *Processor) Handle(ctx context.Context, job queue.Job) (err error) {
	start := time.Now()
	defer func() {
		switch {
		case err == nil:
			p.logInfo(ctx, job, "job processed", time.Since(start))
		case err != queue.ErrSkip:
			p.logWarn(ctx, job, err)
		}
	}()
	if job.Type != queue.JobTypeProcessImage {
		return queue.Permanent(fmt.Errorf("unknown job type %q", job.Type))
	}
	img, err := p.images.GetByID(ctx, job.ImageID)
	if err != nil {
		return fmt.Errorf("load image %d: %w", job.ImageID, err)
	}
	if img.Status == domain.StatusReady {
		return queue.ErrSkip
	}
	if err := p.images.UpdateStatus(ctx, img.ID, domain.StatusProcessing, nil); err != nil {
		return err
	}
	if p.faults != nil {
		if err := p.faults.WorkerFault(ctx); err != nil {
			return err // retryable: the demo shows retries, then the dead letter
		}
	}

	var data []byte
	var info *storage.ImageInfo
	var thumb []byte
	var key string
	if err := p.step(ctx, img.ID, "fetch", func(ctx context.Context) error {
		data, err = p.fetch(ctx, img.StoragePath)
		return err
	}); err != nil {
		return err
	}
	if err := p.step(ctx, img.ID, "decode", func(ctx context.Context) error {
		info, err = p.decoder.GetImageInfo(ctx, bytes.NewReader(data))
		if err != nil {
			return queue.Permanent(fmt.Errorf("decode: %w", err))
		}
		if info.Width*info.Height > p.maxPixels {
			return queue.Permanent(fmt.Errorf("image too large to process: %dx%d", info.Width, info.Height))
		}
		return nil
	}); err != nil {
		return err
	}
	if err := p.step(ctx, img.ID, "thumbnail", func(ctx context.Context) error {
		r, err := p.decoder.GenerateThumbnail(ctx, bytes.NewReader(data), p.thumbSize, p.thumbSize)
		if err != nil {
			return queue.Permanent(fmt.Errorf("thumbnail: %w", err))
		}
		thumb, err = io.ReadAll(r)
		return err
	}); err != nil {
		return err
	}
	if err := p.step(ctx, img.ID, "store", func(ctx context.Context) error {
		ext, contentType := thumbnailFormat(info.Format)
		key = fmt.Sprintf("thumbnails/%d%s", img.ID, ext)
		return p.store.StoreAt(ctx, key, contentType, bytes.NewReader(thumb), int64(len(thumb)))
	}); err != nil {
		return err
	}
	return p.images.CompleteProcessing(ctx, img.ID, domain.ProcessingResult{ThumbnailPath: key, Width: info.Width, Height: info.Height,
		Format: info.Format, ColorSpace: info.ColorSpace, HasAlpha: info.HasAlpha})
}

// OnDeadLetter marks the image failed once retries are exhausted.
func (p *Processor) OnDeadLetter(ctx context.Context, job queue.Job, cause error) {
	msg := cause.Error()
	if err := p.images.UpdateStatus(ctx, job.ImageID, domain.StatusFailed, &msg); err != nil {
		trace.SpanFromContext(ctx).RecordError(err)
	}
	if p.log != nil {
		p.log.Error(ctx).Int(obs.AttrImageID, job.ImageID).Str("job.id", job.ID).Err(cause).Msg("job dead-lettered")
	}
}

func (p *Processor) fetch(ctx context.Context, path string) ([]byte, error) {
	rc, err := p.store.Retrieve(ctx, path)
	if err != nil {
		return nil, err
	}
	defer func() { _ = rc.Close() }()
	data, err := io.ReadAll(io.LimitReader(rc, p.maxBytes+1))
	if err != nil {
		return nil, err
	}
	if int64(len(data)) > p.maxBytes {
		return nil, queue.Permanent(fmt.Errorf("object larger than %d bytes", p.maxBytes))
	}
	return data, nil
}

// step runs fn under an image.<name> span and records its duration.
func (p *Processor) step(ctx context.Context, imageID int, name string, fn func(context.Context) error) error {
	start := time.Now()
	ctx, span := p.tracer.Start(ctx, "image."+name, trace.WithAttributes(attribute.Int(obs.AttrImageID, imageID)))
	err := fn(ctx)
	if err != nil {
		span.RecordError(err)
		span.SetStatus(codes.Error, name+" failed")
	}
	span.End()
	p.stepDur.Record(ctx, time.Since(start).Seconds(), metric.WithAttributes(attribute.String(obs.AttrProcessingStep, name)))
	return err
}

// thumbnailFormat mirrors ImageProcessor.GenerateThumbnail's encoder choice.
func thumbnailFormat(format string) (ext, contentType string) {
	switch format {
	case "png":
		return ".png", "image/png"
	case "gif":
		return ".gif", "image/gif"
	default:
		return ".jpg", "image/jpeg"
	}
}

func (p *Processor) logInfo(ctx context.Context, job queue.Job, msg string, d time.Duration) {
	if p.log != nil {
		p.log.Info(ctx).Int(obs.AttrImageID, job.ImageID).Str("job.id", job.ID).Dur("duration", d).Msg(msg)
	}
}

func (p *Processor) logWarn(ctx context.Context, job queue.Job, err error) {
	if p.log != nil {
		p.log.Warn(ctx).Int(obs.AttrImageID, job.ImageID).Str("job.id", job.ID).Bool("permanent", queue.IsPermanent(err)).Err(err).Msg("job attempt failed")
	}
}
```

- [ ] **Step 4: Create `internal/worker/health.go`.**

```go
package worker

import (
	"context"
	"net/http"
	"strconv"
	"time"
)

// NewHealthHandler serves the worker's probes: /healthz while the process is
// alive, /readyz while ready() (stream reachable, consumer group present) succeeds.
func NewHealthHandler(ready func(context.Context) error) http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"status":"ok"}`))
	})
	mux.HandleFunc("/readyz", func(w http.ResponseWriter, r *http.Request) {
		ctx, cancel := context.WithTimeout(r.Context(), 2*time.Second)
		defer cancel()
		w.Header().Set("Content-Type", "application/json")
		if err := ready(ctx); err != nil {
			w.WriteHeader(http.StatusServiceUnavailable)
			_, _ = w.Write([]byte(`{"status":"unhealthy","error":` + strconv.Quote(err.Error()) + `}`))
			return
		}
		_, _ = w.Write([]byte(`{"status":"ok"}`))
	})
	return mux
}
```

- [ ] **Step 5: Create `internal/app/worker.go`, and add the command.**

```go
package app

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"os"
	"strconv"
	"time"

	"github.com/redis/go-redis/v9"
	"go.opentelemetry.io/otel"

	"image-gallery/internal/platform/queue"
	"image-gallery/internal/services"
	"image-gallery/internal/worker"
)

// RunWorker consumes image-gallery:jobs until ctx is cancelled, finishing the
// jobs in flight before it returns.
func RunWorker(ctx context.Context) error {
	d, err := Bootstrap(ctx, "image-gallery-worker")
	if err != nil {
		return err
	}
	defer d.Close(ctx)
	if d.Redis == nil {
		return errors.New("the worker needs Valkey: set CACHE_ADDRESS")
	}
	log := d.Logger.GetZerolog()
	container, err := services.NewContainerWithObservability(d.Cfg, d.DB, d.Store, d.Logger)
	if err != nil {
		return fmt.Errorf("services: %w", err)
	}
	proc := worker.NewProcessor(container.ImageRepository(), container.StorageService(), workerFaults(container), d.Logger)
	consumer, err := queue.NewConsumer(d.Redis,
		queue.WithConcurrency(envInt("WORKER_CONCURRENCY", 2)),
		queue.WithDeadLetterHook(proc.OnDeadLetter))
	if err != nil {
		return err
	}
	if err := consumer.EnsureGroup(ctx); err != nil {
		return fmt.Errorf("consumer group: %w", err)
	}
	// A separate, UNINSTRUMENTED client for the gauge polls: they must not become traces.
	gaugeClient := redis.NewClient(&redis.Options{Addr: d.Cfg.Cache.Address, Password: d.Cfg.Cache.Password, DB: d.Cfg.Cache.Database})
	defer func() { _ = gaugeClient.Close() }()
	if err := queue.RegisterGauges(gaugeClient, otel.Meter("image-gallery/queue"), queue.DefaultStream, queue.DefaultGroup); err != nil {
		return fmt.Errorf("queue gauges: %w", err)
	}

	hs := &http.Server{Addr: envOr("WORKER_HEALTH_ADDR", ":8081"), Handler: worker.NewHealthHandler(consumer.Ready), ReadHeaderTimeout: 5 * time.Second}
	go func() {
		if err := hs.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			log.Error().Err(err).Msg("worker health server failed")
		}
	}()
	log.Info().Str("stream", queue.DefaultStream).Str("group", queue.DefaultGroup).Msg("worker consuming")
	runErr := consumer.Run(ctx, proc.Handle)
	shutdownCtx, cancel := context.WithTimeout(context.WithoutCancel(ctx), 5*time.Second)
	defer cancel()
	_ = hs.Shutdown(shutdownCtx)
	log.Info().Msg("worker stopped")
	return runErr
}

// workerFaults is replaced by the demo-controls injector in the next task.
func workerFaults(*services.Container) worker.Faults { return nil }

func envOr(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

func envInt(key string, def int) int {
	if n, err := strconv.Atoi(os.Getenv(key)); err == nil && n > 0 {
		return n
	}
	return def
}
```

In `cmd/image-gallery/main.go`, add this line to `run` after the `serve` case:

```go
	case "worker":
		return exitCode(app.RunWorker(ctx))
```

- [ ] **Step 6: Run the tests and confirm they pass.**

Run: `go build ./... && go test ./internal/worker/ -v && go test -short ./...`
Expected: PASS.

- [ ] **Step 7: Smoke-test the two roles locally.** Start `docker compose up -d postgres minio valkey` and apply the migrations (`atlas migrate apply --env local`). Then run `./bin/image-gallery serve` and `WORKER_HEALTH_ADDR=:8081 ./bin/image-gallery worker` in two terminals, after `make build`, with the `.env.example` values plus `STORAGE_PROVIDER=s3`.
  - Upload: `curl -s -F files=@test.png http://localhost:8080/api/images`.
  - Check: `curl -s http://localhost:8080/api/images | jq '.images[0] | {status, thumbnail_url}'` shows `"status": "ready"` within 5 s, and `curl -s -o /dev/null -w '%{http_code} %{content_type}\n' http://localhost:8080/api/images/<id>/thumbnail` prints `200 image/png`.
  - Check: `curl -s localhost:8081/readyz` prints `{"status":"ok"}`.

- [ ] **Step 8: Commit.**

```bash
git add internal/worker internal/app/worker.go cmd/image-gallery/main.go
git commit -m "feat(worker): process images from the queue into thumbnails and metadata" \
  -m "image-gallery worker consumes image-gallery:jobs in the workers group: fetch, decode, thumbnail and store each get a span and an image.processing.duration sample; a ready image is skipped; retries exhaust into the dead letter, which marks the image failed. /healthz and /readyz on WORKER_HEALTH_ADDR (:8081); queue.depth, queue.pending and queue.lag gauges."
```


### Task 14: Demo controls (fault injection)

**Files:**
- Create: `internal/domain/demo/controls.go`.
- Create: `internal/services/implementations/demo_repository.go`.
- Create: `internal/faults/service.go` and `internal/faults/injector.go`.
- Create: `internal/web/handlers/demo.go`.
- Modify:
  - `internal/services/container.go` (build the service and the injector; wire slow DB into the image service);
  - `internal/services/implementations/image_service.go` (`SetSlowDB`);
  - `internal/web/handlers/handlers.go` (routes, middleware, the Settings UI panel);
  - `internal/app/worker.go` (replace `workerFaults`).
- Test:
  - `internal/faults/injector_test.go` and `internal/faults/service_test.go`;
  - `internal/web/handlers/demo_test.go`;
  - `internal/services/implementations/demo_repository_integration_test.go`.

**Interfaces:**
- Consumes: the `demo_controls` table (Task 9), `worker.Faults` (Task 13), `cache.RedisClient`'s `Get`, `Set` and `Delete` (existing), and the Task 5 constants.
- Produces. Task 15's `incident` scenario speaks this JSON over the API; the field names are the contract.

```go
// package demo (internal/domain/demo)
type Controls struct {
	LatencyMS                int       `json:"latency_ms"`
	LatencyProbability       float64   `json:"latency_probability"`
	LatencyRoutes            []string  `json:"latency_routes"` // path prefixes; empty = every /api route
	ErrorProbability         float64   `json:"error_probability"`
	SlowDBMS                 int       `json:"slow_db_ms"`
	WorkerFailureProbability float64   `json:"worker_failure_probability"`
	WorkerDelayMS            int       `json:"worker_delay_ms"`
	UpdatedAt                time.Time `json:"updated_at"`
}
const FaultLatency, FaultError, FaultSlowDB, FaultWorkerFailure, FaultWorkerSlowdown = "latency", "error", "slow_db", "worker_failure", "worker_slowdown"
var ErrInvalidControls error
type Repository interface { Get(ctx) (Controls, error); Save(ctx, Controls) (Controls, error) }
// package faults (internal/faults)
func NewService(repo demo.Repository, cache Cache) *Service  // cache may be nil
func (*Service) Get(ctx) (demo.Controls, error); Update(ctx, demo.Controls) (demo.Controls, error); Reset(ctx) (demo.Controls, error)
func NewInjector(src Source, log *observability.Logger, opts ...InjectorOption) *Injector
func WithRand(func() float64) InjectorOption; func WithSleep(func(context.Context, time.Duration) error) InjectorOption
func (*Injector) Middleware(http.Handler) http.Handler; SlowDB(ctx) time.Duration; WorkerFault(ctx) error
```

The API: `GET /api/settings/demo` returns `Controls`; `PUT /api/settings/demo` takes a full `Controls` and returns 200 with the saved value, or 400 when invalid; `POST /api/settings/demo/reset` sets every control off and returns 200 with the reset value.

- [ ] **Step 1: Write the failing injector tests, with a seeded random source.** Create `internal/faults/injector_test.go`:

```go
package faults

import (
	"bytes"
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"go.opentelemetry.io/otel/attribute"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
	"go.opentelemetry.io/otel/sdk/trace/tracetest"

	"image-gallery/internal/domain/demo"
	"image-gallery/internal/observability"
)

type staticSource struct{ c demo.Controls }

func (s staticSource) Get(context.Context) (demo.Controls, error) { return s.c, nil }

type harness struct {
	inj    *Injector
	slept  []time.Duration
	logs   *bytes.Buffer
	spans  *tracetest.InMemoryExporter
	tracer *sdktrace.TracerProvider
}

func newHarness(c demo.Controls, roll float64) *harness {
	h := &harness{logs: &bytes.Buffer{}, spans: tracetest.NewInMemoryExporter()}
	h.tracer = sdktrace.NewTracerProvider(sdktrace.WithSyncer(h.spans))
	log := observability.NewLoggerTo(h.logs, observability.Config{ServiceName: "t", LogLevel: "info", LogFormat: "json"})
	h.inj = NewInjector(staticSource{c: c}, log,
		WithRand(func() float64 { return roll }), // deterministic: every draw returns roll
		WithSleep(func(_ context.Context, d time.Duration) error { h.slept = append(h.slept, d); return nil }))
	return h
}

func (h *harness) do(path string) *httptest.ResponseRecorder {
	ctx, span := h.tracer.Tracer("t").Start(context.Background(), "server")
	defer span.End()
	rec := httptest.NewRecorder()
	h.inj.Middleware(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(200) })).
		ServeHTTP(rec, httptest.NewRequest(http.MethodGet, path, nil).WithContext(ctx))
	return rec
}

func (h *harness) faultAttrs() []string {
	var out []string
	for _, s := range h.spans.GetSpans() {
		if v, ok := attribute.NewSet(s.Attributes...).Value("demo.fault"); ok {
			out = append(out, v.AsString())
		}
	}
	return out
}

func TestLatencyThenErrorCarryAllThreeMarkers(t *testing.T) {
	h := newHarness(demo.Controls{LatencyMS: 800, LatencyProbability: 0.5, LatencyRoutes: []string{"/api/images"}, ErrorProbability: 0.5}, 0.3)
	rec := h.do("/api/images/7")
	if rec.Code != http.StatusServiceUnavailable {
		t.Fatalf("code = %d, want 503", rec.Code)
	}
	if len(h.slept) != 1 || h.slept[0] != 800*time.Millisecond {
		t.Fatalf("slept = %v", h.slept)
	}
	if got := h.faultAttrs(); len(got) != 1 || got[0] != demo.FaultError { // the last fault wins on the span
		t.Fatalf("span demo.fault = %v", got)
	}
	if c := strings.Count(h.logs.String(), "demo fault injected"); c != 2 {
		t.Fatalf("log lines = %d, want 2:\n%s", c, h.logs.String())
	}
}

func TestProbabilityIsRespected(t *testing.T) {
	h := newHarness(demo.Controls{ErrorProbability: 0.2}, 0.3) // 0.3 >= 0.2: no fault
	if rec := h.do("/api/images"); rec.Code != 200 {
		t.Fatalf("code = %d, want 200", rec.Code)
	}
}

func TestLatencyRouteFilterAndExemptPaths(t *testing.T) {
	h := newHarness(demo.Controls{LatencyMS: 100, LatencyProbability: 1, LatencyRoutes: []string{"/api/images"}, ErrorProbability: 1}, 0)
	for _, p := range []string{"/api/settings/demo", "/api/settings/demo/reset", "/healthz", "/readyz", "/gallery"} {
		if rec := h.do(p); rec.Code != 200 {
			t.Errorf("%s must never be faulted, got %d", p, rec.Code)
		}
	}
	h.do("/api/settings")
	if len(h.slept) != 0 {
		t.Fatalf("latency outside latency_routes: %v", h.slept)
	}
}

func TestSlowDBAndWorkerFaults(t *testing.T) {
	h := newHarness(demo.Controls{SlowDBMS: 250, WorkerDelayMS: 100, WorkerFailureProbability: 1}, 0)
	if d := h.inj.SlowDB(context.Background()); d != 250*time.Millisecond {
		t.Fatalf("SlowDB = %v", d)
	}
	err := h.inj.WorkerFault(context.Background())
	if err == nil || len(h.slept) != 1 || h.slept[0] != 100*time.Millisecond {
		t.Fatalf("WorkerFault err=%v slept=%v", err, h.slept)
	}
	off := newHarness(demo.Controls{}, 0)
	if off.inj.SlowDB(context.Background()) != 0 || off.inj.WorkerFault(context.Background()) != nil || off.logs.Len() != 0 {
		t.Fatal("controls off must inject nothing")
	}
}
```

Create `internal/faults/service_test.go`:

```go
package faults

import (
	"context"
	"encoding/json"
	"errors"
	"testing"
	"time"

	"image-gallery/internal/domain/demo"
)

type memRepo struct {
	c    demo.Controls
	gets int
}

func (m *memRepo) Get(context.Context) (demo.Controls, error) { m.gets++; return m.c, nil }
func (m *memRepo) Save(_ context.Context, c demo.Controls) (demo.Controls, error) {
	m.c = c
	return c, nil
}

type memCache map[string][]byte

func (m memCache) Get(_ context.Context, k string, out interface{}) error {
	b, ok := m[k]
	if !ok {
		return errors.New("miss")
	}
	return json.Unmarshal(b, out)
}
func (m memCache) Set(_ context.Context, k string, v interface{}, _ time.Duration) error {
	b, err := json.Marshal(v)
	m[k] = b
	return err
}
func (m memCache) Delete(_ context.Context, k string) error { delete(m, k); return nil }

func TestServiceCachesValidatesAndInvalidates(t *testing.T) {
	ctx := context.Background()
	repo := &memRepo{}
	s := NewService(repo, memCache{})
	_, _ = s.Get(ctx)
	_, _ = s.Get(ctx)
	if repo.gets != 1 {
		t.Fatalf("repo reads = %d, want 1 (second read from cache)", repo.gets)
	}
	if _, err := s.Update(ctx, demo.Controls{ErrorProbability: 1.5}); !errors.Is(err, demo.ErrInvalidControls) {
		t.Fatalf("want ErrInvalidControls, got %v", err)
	}
	if _, err := s.Update(ctx, demo.Controls{ErrorProbability: 0.2}); err != nil {
		t.Fatal(err)
	}
	if c, _ := s.Get(ctx); c.ErrorProbability != 0.2 {
		t.Fatalf("Update must invalidate the cache, read %v", c.ErrorProbability)
	}
	if c, _ := s.Reset(ctx); c.Active() {
		t.Fatalf("Reset left controls on: %+v", c)
	}
}
```

- [ ] **Step 2: Run the tests and confirm they fail.**

Run: `go test ./internal/faults/ -v`
Expected: FAIL to compile, because the packages do not exist yet.

- [ ] **Step 3: Create `internal/domain/demo/controls.go`.**

```go
// Package demo holds the fault-injection controls of the observability demo.
package demo

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"time"
)

// Fault types: the demo.fault attribute and counter label.
const (
	FaultLatency        = "latency"
	FaultError          = "error"
	FaultSlowDB         = "slow_db"
	FaultWorkerFailure  = "worker_failure"
	FaultWorkerSlowdown = "worker_slowdown"
)

// ErrInvalidControls wraps every validation failure.
var ErrInvalidControls = errors.New("invalid demo controls")

// Controls is the single demo_controls row. The zero value is "everything off".
type Controls struct {
	LatencyMS                int       `json:"latency_ms"`
	LatencyProbability       float64   `json:"latency_probability"`
	LatencyRoutes            []string  `json:"latency_routes"`
	ErrorProbability         float64   `json:"error_probability"`
	SlowDBMS                 int       `json:"slow_db_ms"`
	WorkerFailureProbability float64   `json:"worker_failure_probability"`
	WorkerDelayMS            int       `json:"worker_delay_ms"`
	UpdatedAt                time.Time `json:"updated_at"`
}

// Validate mirrors the table's CHECK constraints.
func (c Controls) Validate() error {
	prob := func(name string, p float64) error {
		if p < 0 || p > 1 {
			return fmt.Errorf("%w: %s must be within [0,1], got %v", ErrInvalidControls, name, p)
		}
		return nil
	}
	ms := func(name string, v, max int) error {
		if v < 0 || v > max {
			return fmt.Errorf("%w: %s must be within [0,%d], got %d", ErrInvalidControls, name, max, v)
		}
		return nil
	}
	return errors.Join(
		ms("latency_ms", c.LatencyMS, 30000), prob("latency_probability", c.LatencyProbability),
		prob("error_probability", c.ErrorProbability), ms("slow_db_ms", c.SlowDBMS, 30000),
		prob("worker_failure_probability", c.WorkerFailureProbability), ms("worker_delay_ms", c.WorkerDelayMS, 60000))
}

// Active reports whether any control can inject a fault.
func (c Controls) Active() bool {
	return (c.LatencyMS > 0 && c.LatencyProbability > 0) || c.ErrorProbability > 0 || c.SlowDBMS > 0 ||
		c.WorkerFailureProbability > 0 || c.WorkerDelayMS > 0
}

// MatchesLatencyRoute reports whether path is subject to injected latency.
func (c Controls) MatchesLatencyRoute(path string) bool {
	if len(c.LatencyRoutes) == 0 {
		return true
	}
	for _, p := range c.LatencyRoutes {
		if strings.HasPrefix(path, p) {
			return true
		}
	}
	return false
}

// Repository persists the controls row.
type Repository interface {
	Get(ctx context.Context) (Controls, error)
	Save(ctx context.Context, c Controls) (Controls, error)
}
```

- [ ] **Step 4: Create `internal/faults/service.go`.**

```go
// Package faults applies the demo controls: a cached controls service and an
// injector for the web middleware, the slow list query and the worker.
package faults

import (
	"context"
	"time"

	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/metric"

	"image-gallery/internal/domain/demo"
	obs "image-gallery/internal/observability"
)

const (
	cacheKey = "demo:controls"
	cacheTTL = 5 * time.Second // the worker sees a change within 5 s
)

// Cache is the subset of *cache.RedisClient the service uses. Pass a nil
// interface, never a nil *RedisClient, when there is no cache.
type Cache interface {
	Get(ctx context.Context, key string, result interface{}) error
	Set(ctx context.Context, key string, value interface{}, ttl time.Duration) error
	Delete(ctx context.Context, key string) error
}

// Service reads and writes the controls through a short-lived cache.
type Service struct {
	repo    demo.Repository
	cache   Cache
	lookups metric.Int64Counter
}

// NewService builds a Service; cache may be nil.
func NewService(repo demo.Repository, cache Cache) *Service {
	lookups, _ := otel.Meter("image-gallery/demo").Int64Counter(obs.MetricCacheLookups, metric.WithUnit("{lookup}"))
	return &Service{repo: repo, cache: cache, lookups: lookups}
}

// Get returns the current controls.
func (s *Service) Get(ctx context.Context) (demo.Controls, error) {
	if s.cache != nil {
		var c demo.Controls
		if err := s.cache.Get(ctx, cacheKey, &c); err == nil {
			s.lookup(ctx, "hit")
			return c, nil
		}
		s.lookup(ctx, "miss")
	}
	c, err := s.repo.Get(ctx)
	if err == nil && s.cache != nil {
		_ = s.cache.Set(ctx, cacheKey, c, cacheTTL)
	}
	return c, err
}

// Update validates and saves c, then invalidates the cache.
func (s *Service) Update(ctx context.Context, c demo.Controls) (demo.Controls, error) {
	if err := c.Validate(); err != nil {
		return demo.Controls{}, err
	}
	if c.LatencyRoutes == nil {
		c.LatencyRoutes = []string{} // the column is NOT NULL
	}
	saved, err := s.repo.Save(ctx, c)
	if err == nil && s.cache != nil {
		_ = s.cache.Delete(ctx, cacheKey)
	}
	return saved, err
}

// Reset switches every control off.
func (s *Service) Reset(ctx context.Context) (demo.Controls, error) {
	return s.Update(ctx, demo.Controls{LatencyRoutes: []string{}})
}

func (s *Service) lookup(ctx context.Context, result string) {
	s.lookups.Add(ctx, 1, metric.WithAttributes(attribute.String(obs.AttrCacheName, "demo"), attribute.String(obs.AttrCacheResult, result)))
}
```

- [ ] **Step 5: Create `internal/faults/injector.go`.**

```go
package faults

import (
	"context"
	"errors"
	"math/rand/v2"
	"net/http"
	"strings"
	"time"

	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/metric"
	"go.opentelemetry.io/otel/trace"

	"image-gallery/internal/domain/demo"
	obs "image-gallery/internal/observability"
)

// Source provides the current controls (the cached Service in production).
type Source interface {
	Get(ctx context.Context) (demo.Controls, error)
}

// Injector turns the controls into faults. Every fault it injects is visible
// three ways: the span attribute demo.fault, a warn log line, and the counter
// demo.faults.injected.
type Injector struct {
	src    Source
	rnd    func() float64
	sleep  func(context.Context, time.Duration) error
	faults metric.Int64Counter
	log    *obs.Logger
}

// InjectorOption customises an Injector (tests make it deterministic).
type InjectorOption func(*Injector)

// WithRand replaces the random source.
func WithRand(f func() float64) InjectorOption { return func(i *Injector) { i.rnd = f } }

// WithSleep replaces the sleep function.
func WithSleep(f func(context.Context, time.Duration) error) InjectorOption {
	return func(i *Injector) { i.sleep = f }
}

// NewInjector builds an Injector; log may be nil.
func NewInjector(src Source, log *obs.Logger, opts ...InjectorOption) *Injector {
	faults, _ := otel.Meter("image-gallery/demo").Int64Counter(obs.MetricDemoFaults, metric.WithUnit("{fault}"),
		metric.WithDescription("Faults injected by the demo controls"))
	i := &Injector{src: src, rnd: rand.Float64, sleep: sleepCtx, faults: faults, log: log}
	for _, o := range opts {
		o(i)
	}
	return i
}

func sleepCtx(ctx context.Context, d time.Duration) error {
	t := time.NewTimer(d)
	defer t.Stop()
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-t.C:
		return nil
	}
}

func (i *Injector) record(ctx context.Context, fault string) {
	trace.SpanFromContext(ctx).SetAttributes(attribute.String(obs.AttrDemoFault, fault))
	i.faults.Add(ctx, 1, metric.WithAttributes(attribute.String(obs.AttrDemoFault, fault)))
	if i.log != nil {
		i.log.Warn(ctx).Str(obs.AttrDemoFault, fault).Msg("demo fault injected")
	}
}

// exempt: only /api is faulted, never the demo endpoints themselves, so a
// fault can always be switched off. Probes and pages are not under /api.
func exempt(path string) bool {
	return !strings.HasPrefix(path, "/api/") || strings.HasPrefix(path, "/api/settings/demo")
}

// Middleware injects latency and 5xx errors into /api requests. Mount it
// inside the observability middleware so the fault lands on the server span.
func (i *Injector) Middleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if exempt(r.URL.Path) {
			next.ServeHTTP(w, r)
			return
		}
		ctx := r.Context()
		c, err := i.src.Get(ctx)
		if err != nil || !c.Active() {
			next.ServeHTTP(w, r)
			return
		}
		if c.LatencyMS > 0 && c.MatchesLatencyRoute(r.URL.Path) && i.rnd() < c.LatencyProbability {
			i.record(ctx, demo.FaultLatency)
			if err := i.sleep(ctx, time.Duration(c.LatencyMS)*time.Millisecond); err != nil {
				return // client went away
			}
		}
		if c.ErrorProbability > 0 && i.rnd() < c.ErrorProbability {
			i.record(ctx, demo.FaultError)
			http.Error(w, "demo fault: injected error", http.StatusServiceUnavailable)
			return
		}
		next.ServeHTTP(w, r)
	})
}

// SlowDB returns how long the list query should sleep in the database (0 = no fault).
func (i *Injector) SlowDB(ctx context.Context) time.Duration {
	c, err := i.src.Get(ctx)
	if err != nil || c.SlowDBMS <= 0 {
		return 0
	}
	i.record(ctx, demo.FaultSlowDB)
	return time.Duration(c.SlowDBMS) * time.Millisecond
}

// WorkerFault delays the job and/or fails it (retryable), per the controls.
func (i *Injector) WorkerFault(ctx context.Context) error {
	c, err := i.src.Get(ctx)
	if err != nil {
		return nil // the demo must not break processing when its own row is unreadable
	}
	if c.WorkerDelayMS > 0 {
		i.record(ctx, demo.FaultWorkerSlowdown)
		if err := i.sleep(ctx, time.Duration(c.WorkerDelayMS)*time.Millisecond); err != nil {
			return err
		}
	}
	if c.WorkerFailureProbability > 0 && i.rnd() < c.WorkerFailureProbability {
		i.record(ctx, demo.FaultWorkerFailure)
		return errors.New("demo fault: injected worker failure")
	}
	return nil
}
```

- [ ] **Step 6: Run the tests and confirm they pass.**

Run: `go test ./internal/faults/ -v`
Expected: PASS for all five tests.

- [ ] **Step 7: Write the repository, with its integration test.** Create `internal/services/implementations/demo_repository.go`:

```go
package implementations

import (
	"context"
	"database/sql"

	"github.com/lib/pq"

	"image-gallery/internal/domain/demo"
)

// DemoRepository persists the single demo_controls row (id = 1).
type DemoRepository struct{ db *sql.DB }

// NewDemoRepository builds a repository on db.
func NewDemoRepository(db *sql.DB) *DemoRepository { return &DemoRepository{db: db} }

func (r *DemoRepository) Get(ctx context.Context) (demo.Controls, error) {
	var c demo.Controls
	err := r.db.QueryRowContext(ctx, `
		SELECT latency_ms, latency_probability, latency_routes, error_probability, slow_db_ms,
		       worker_failure_probability, worker_delay_ms, updated_at
		  FROM demo_controls WHERE id = 1`).Scan(&c.LatencyMS, &c.LatencyProbability, pq.Array(&c.LatencyRoutes),
		&c.ErrorProbability, &c.SlowDBMS, &c.WorkerFailureProbability, &c.WorkerDelayMS, &c.UpdatedAt)
	return c, err
}

func (r *DemoRepository) Save(ctx context.Context, c demo.Controls) (demo.Controls, error) {
	if c.LatencyRoutes == nil {
		c.LatencyRoutes = []string{}
	}
	err := r.db.QueryRowContext(ctx, `
		UPDATE demo_controls SET latency_ms = $1, latency_probability = $2, latency_routes = $3,
		       error_probability = $4, slow_db_ms = $5, worker_failure_probability = $6,
		       worker_delay_ms = $7, updated_at = NOW()
		 WHERE id = 1 RETURNING updated_at`,
		c.LatencyMS, c.LatencyProbability, pq.Array(c.LatencyRoutes), c.ErrorProbability, c.SlowDBMS,
		c.WorkerFailureProbability, c.WorkerDelayMS).Scan(&c.UpdatedAt)
	return c, err
}

// SleepInDB runs pg_sleep so an injected slow query shows up as a real, slow DB span.
func SleepInDB(ctx context.Context, db *sql.DB, seconds float64) error {
	_, err := db.ExecContext(ctx, "SELECT pg_sleep($1)", seconds)
	return err
}
```

Create `internal/services/implementations/demo_repository_integration_test.go`:

```go
package implementations_test

import (
	"context"
	"testing"

	"image-gallery/internal/domain/demo"
	"image-gallery/internal/services/implementations"
	"image-gallery/internal/testutils"
)

func TestDemoRepositoryRoundTrip(t *testing.T) {
	if testing.Short() {
		t.Skip("integration test")
	}
	ctx := context.Background()
	tc, err := testutils.SetupTestContainers(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = tc.Cleanup(ctx) }()
	r := implementations.NewDemoRepository(tc.DB)
	c, err := r.Get(ctx)
	if err != nil || c.Active() {
		t.Fatalf("defaults must be off: %+v %v", c, err)
	}
	want := demo.Controls{LatencyMS: 800, LatencyProbability: 0.5, LatencyRoutes: []string{"/api/images"}, WorkerDelayMS: 4000}
	if _, err := r.Save(ctx, want); err != nil {
		t.Fatal(err)
	}
	got, err := r.Get(ctx)
	if err != nil || got.LatencyMS != 800 || got.LatencyProbability != 0.5 || len(got.LatencyRoutes) != 1 || got.WorkerDelayMS != 4000 {
		t.Fatalf("round trip = %+v, %v", got, err)
	}
	if err := implementations.SleepInDB(ctx, tc.DB, 0.01); err != nil {
		t.Fatal(err)
	}
}
```

Run: `go test ./internal/services/implementations/ -run TestDemoRepositoryRoundTrip -v`. Expected: PASS.

- [ ] **Step 8: Wire it into the container, the image service and the worker.**
  - **`image_service.go`:**

```go
// SetSlowDB installs the demo "slow DB" hook, called before each list query.
func (s *ImageServiceImpl) SetSlowDB(f func(ctx context.Context)) { s.slowDB = f }
```

    Add the `slowDB func(context.Context)` field, and put `if s.slowDB != nil { s.slowDB(ctx) }` as the first statement after `ListImages` starts its span.
  - **`container.go`:** add the fields `demoService *faults.Service` and `demoInjector *faults.Injector`. At the end of `initializeServices`:

```go
	var demoCache faults.Cache // a nil *RedisClient inside a non-nil interface would panic
	if c.redisClient != nil {
		demoCache = c.redisClient
	}
	c.demoService = faults.NewService(implementations.NewDemoRepository(c.db), demoCache)
	c.demoInjector = faults.NewInjector(c.demoService, c.logger)
	if s, ok := c.imageService.(interface{ SetSlowDB(func(context.Context)) }); ok {
		s.SetSlowDB(func(ctx context.Context) {
			if d := c.demoInjector.SlowDB(ctx); d > 0 {
				_ = implementations.SleepInDB(ctx, c.db, d.Seconds())
			}
		})
	}
```

    Add the getters `DemoService() *faults.Service` and `DemoInjector() *faults.Injector`.
  - **`internal/app/worker.go`:** replace the `workerFaults` body with `return c.DemoInjector()`, renaming the parameter to `c`.

- [ ] **Step 9: Add the endpoints and the Settings UI.**
  - **Create `internal/web/handlers/demo.go`:**

```go
package handlers

import (
	"encoding/json"
	"errors"
	"net/http"

	"image-gallery/internal/domain/demo"
)

func (h *Handler) writeDemo(w http.ResponseWriter, c demo.Controls, err error) {
	switch {
	case errors.Is(err, demo.ErrInvalidControls):
		http.Error(w, err.Error(), http.StatusBadRequest)
	case err != nil:
		http.Error(w, "demo controls unavailable", http.StatusInternalServerError)
	default:
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(c)
	}
}

// getDemoHandler: GET /api/settings/demo
func (h *Handler) getDemoHandler(w http.ResponseWriter, r *http.Request) {
	c, err := h.demo.Get(r.Context())
	h.writeDemo(w, c, err)
}

// updateDemoHandler: PUT /api/settings/demo (a full Controls document)
func (h *Handler) updateDemoHandler(w http.ResponseWriter, r *http.Request) {
	var c demo.Controls
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 16<<10)).Decode(&c); err != nil {
		http.Error(w, "invalid JSON: "+err.Error(), http.StatusBadRequest)
		return
	}
	saved, err := h.demo.Update(r.Context(), c)
	h.writeDemo(w, saved, err)
}

// resetDemoHandler: POST /api/settings/demo/reset
func (h *Handler) resetDemoHandler(w http.ResponseWriter, r *http.Request) {
	c, err := h.demo.Reset(r.Context())
	h.writeDemo(w, c, err)
}
```

  - **`handlers.go`:**
    - Add the fields `demo *faults.Service` and `demoInjector *faults.Injector` to `Handler`, set in `NewWithContainer` from `container.DemoService()` and `container.DemoInjector()`.
    - In `Routes()`, right after `r.Use(observability.Middleware(...))`:

```go
	if h.demoInjector != nil {
		r.Use(h.demoInjector.Middleware) // inside the server span, so faults are recorded on it
	}
```

    - Inside `r.Route("/settings", …)`, add:

```go
			r.Get("/demo", h.getDemoHandler)
			r.Put("/demo", h.updateDemoHandler)
			r.Post("/demo/reset", h.resetDemoHandler)
```

    - **Settings UI.** Append this fieldset at the end of `<div id="settingsForm">` in the settings modal:

```html
                    <fieldset class="border border-amber-300 rounded-lg p-4 mt-6">
                        <legend class="px-2 text-sm font-semibold text-amber-700">Demo controls (fault injection)</legend>
                        <div class="grid grid-cols-2 gap-3 text-sm">
                            <label>Latency (ms)<input id="demoLatencyMs" type="number" min="0" max="30000" class="w-full border rounded px-2 py-1"></label>
                            <label>Latency probability<input id="demoLatencyProb" type="number" min="0" max="1" step="0.05" class="w-full border rounded px-2 py-1"></label>
                            <label class="col-span-2">Latency routes (comma-separated path prefixes, empty = all /api)<input id="demoLatencyRoutes" type="text" class="w-full border rounded px-2 py-1"></label>
                            <label>Error probability (5xx)<input id="demoErrorProb" type="number" min="0" max="1" step="0.05" class="w-full border rounded px-2 py-1"></label>
                            <label>Slow DB list query (ms)<input id="demoSlowDbMs" type="number" min="0" max="30000" class="w-full border rounded px-2 py-1"></label>
                            <label>Worker failure probability<input id="demoWorkerFailProb" type="number" min="0" max="1" step="0.05" class="w-full border rounded px-2 py-1"></label>
                            <label>Worker delay (ms)<input id="demoWorkerDelayMs" type="number" min="0" max="60000" class="w-full border rounded px-2 py-1"></label>
                        </div>
                        <div class="flex gap-2 mt-3">
                            <button onclick="saveDemoControls()" class="bg-amber-600 hover:bg-amber-700 text-white py-1 px-3 rounded">Apply</button>
                            <button onclick="resetDemoControls()" class="bg-gray-500 hover:bg-gray-600 text-white py-1 px-3 rounded">All off</button>
                            <span id="demoStatus" class="text-xs text-gray-500 self-center"></span>
                        </div>
                    </fieldset>
```

    - **Settings JS.** Add these functions to the page's `<script>` block, and call `loadDemoControls();` as the first line of `openSettingsModal()`:

```javascript
        const demoFields = {
            latency_ms: ['demoLatencyMs', Number], latency_probability: ['demoLatencyProb', Number],
            error_probability: ['demoErrorProb', Number], slow_db_ms: ['demoSlowDbMs', Number],
            worker_failure_probability: ['demoWorkerFailProb', Number], worker_delay_ms: ['demoWorkerDelayMs', Number],
        };
        function fillDemoControls(c) {
            for (const [key, [id]] of Object.entries(demoFields)) document.getElementById(id).value = c[key] ?? 0;
            document.getElementById('demoLatencyRoutes').value = (c.latency_routes || []).join(', ');
        }
        async function loadDemoControls() {
            const r = await fetch('/api/settings/demo');
            if (r.ok) fillDemoControls(await r.json());
        }
        async function saveDemoControls() {
            const body = { latency_routes: document.getElementById('demoLatencyRoutes').value.split(',').map(s => s.trim()).filter(Boolean) };
            for (const [key, [id, cast]] of Object.entries(demoFields)) body[key] = cast(document.getElementById(id).value || 0);
            const r = await fetch('/api/settings/demo', { method: 'PUT', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) });
            document.getElementById('demoStatus').textContent = r.ok ? 'Applied' : 'Rejected: ' + await r.text();
            if (r.ok) fillDemoControls(await r.json());
        }
        async function resetDemoControls() {
            const r = await fetch('/api/settings/demo/reset', { method: 'POST' });
            document.getElementById('demoStatus').textContent = r.ok ? 'All off' : 'Reset failed';
            if (r.ok) fillDemoControls(await r.json());
        }
```

  - **Create `internal/web/handlers/demo_test.go`:**

```go
package handlers

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/go-chi/chi/v5"

	"image-gallery/internal/domain/demo"
	"image-gallery/internal/faults"
)

type memDemoRepo struct{ c demo.Controls }

func (m *memDemoRepo) Get(context.Context) (demo.Controls, error) { return m.c, nil }
func (m *memDemoRepo) Save(_ context.Context, c demo.Controls) (demo.Controls, error) {
	m.c = c
	return c, nil
}

func TestDemoEndpoints(t *testing.T) {
	h := &Handler{demo: faults.NewService(&memDemoRepo{}, nil)}
	r := chi.NewRouter()
	r.Get("/api/settings/demo", h.getDemoHandler)
	r.Put("/api/settings/demo", h.updateDemoHandler)
	r.Post("/api/settings/demo/reset", h.resetDemoHandler)
	call := func(method, body string) *httptest.ResponseRecorder {
		rec := httptest.NewRecorder()
		path := "/api/settings/demo"
		if method == http.MethodPost {
			path += "/reset"
		}
		r.ServeHTTP(rec, httptest.NewRequest(method, path, strings.NewReader(body)))
		return rec
	}
	if rec := call(http.MethodPut, `{"error_probability": 2}`); rec.Code != http.StatusBadRequest {
		t.Fatalf("invalid PUT = %d, want 400", rec.Code)
	}
	if rec := call(http.MethodPut, `{"error_probability": 0.25, "latency_routes": ["/api/images"]}`); rec.Code != 200 {
		t.Fatalf("valid PUT = %d", rec.Code)
	}
	var c demo.Controls
	_ = json.NewDecoder(call(http.MethodGet, "").Body).Decode(&c)
	if c.ErrorProbability != 0.25 || len(c.LatencyRoutes) != 1 {
		t.Fatalf("GET after PUT = %+v", c)
	}
	_ = json.NewDecoder(call(http.MethodPost, "").Body).Decode(&c)
	if c.Active() {
		t.Fatalf("reset left controls on: %+v", c)
	}
}
```

- [ ] **Step 10: Run the tests and confirm they pass.**

Run: `go build ./... && go test -short ./... && go test ./internal/faults/ ./internal/web/handlers/ -run 'Demo|Latency|Probability|SlowDB|Service' -v`
Expected: PASS.

- [ ] **Step 11: Commit.**

```bash
git add -A internal
git commit -m "feat(demo): switchable fault injection for the observability demo" \
  -m "Latency and 5xx errors on /api, a slow list query (a real pg_sleep DB span), and worker failure and slowdown, all off by default. Controls live in demo_controls, cached for 5 s, and can be set from the Settings UI or /api/settings/demo. Every fault sets demo.fault on the span, logs a warn line and increments demo.faults.injected."
```


### Task 15: `image-gallery loadgen`

**Files:**
- Create in `internal/loadgen/`: `options.go`, `ops.go`, `imagegen.go`, `scenarios.go`, `engine.go`, `breaker.go`, `summary.go`, `incident.go` and `main.go`.
- Modify: `cmd/image-gallery/main.go` (add `case "loadgen"`).
- Test: `internal/loadgen/loadgen_test.go`.

**Interfaces:**
- Consumes:
  - the app's HTTP API: `GET /api/images` returns `{"images":[{"id":"<n>",…}]}`; `POST /api/images` (multipart `files`, `tags`) returns `{"images":[{"id":<n>,…}]}`; `GET /api/images/{id}/view`, `GET /api/images/{id}/thumbnail`, `DELETE /api/images/{id}` and `GET /api/settings`;
  - the demo API (Task 14): `PUT /api/settings/demo` with the `Controls` JSON, and `POST /api/settings/demo/reset`;
  - `observability.LoadConfig` and `observability.NewProvider` (Task 5).
- Produces:
  - `type loadgen.Options struct { Target, Scenario string; Rate float64; Duration time.Duration; Concurrency int; Force bool; Seed int64; PhaseScale float64 }`;
  - `const loadgen.MaxRate = 25`;
  - `func loadgen.Run(ctx context.Context, o Options, out io.Writer) (Summary, error)`, which validates `o` itself;
  - `type Summary struct { Requests, Errors, Shed int; Elapsed time.Duration; Rate, ErrorPct float64; P50, P95, P99 time.Duration }`;
  - `func loadgen.Main(ctx context.Context, args []string, stdout, stderr io.Writer) int`;
  - `var ErrBreakerTripped error`.
- Task 16 calls `Run`; Task 19's CronJob runs `image-gallery loadgen --target … --scenario steady …`.

- [ ] **Step 1: Write the failing tests.** Create `internal/loadgen/loadgen_test.go`:

```go
package loadgen

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/propagation"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
)

// fakeApp mimics the image-gallery API surface the load generator uses.
type fakeApp struct {
	mu          sync.Mutex
	hits        map[string]int
	demoPuts    []map[string]any
	resets      atomic.Int32
	fail        atomic.Bool
	traceparent atomic.Int32
	nextID      atomic.Int32
}

func newFakeApp(t *testing.T) (*fakeApp, *httptest.Server) {
	f := &fakeApp{hits: map[string]int{}}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("traceparent") != "" {
			f.traceparent.Add(1)
		}
		key := r.Method + " " + route(r.URL.Path)
		f.mu.Lock()
		f.hits[key]++
		f.mu.Unlock()
		if f.fail.Load() && !strings.HasPrefix(r.URL.Path, "/api/settings/demo") {
			http.Error(w, "boom", http.StatusInternalServerError)
			return
		}
		switch key {
		case "GET /api/images":
			_, _ = io.WriteString(w, `{"images":[{"id":"1"},{"id":"2"}],"total_count":2}`)
		case "POST /api/images":
			_ = r.ParseMultipartForm(32 << 20)
			w.WriteHeader(http.StatusCreated)
			fmt.Fprintf(w, `{"images":[{"id":%d}],"count":1}`, 100+f.nextID.Add(1))
		case "PUT /api/settings/demo":
			var body map[string]any
			_ = json.NewDecoder(r.Body).Decode(&body)
			f.mu.Lock()
			f.demoPuts = append(f.demoPuts, body)
			f.mu.Unlock()
			_, _ = io.WriteString(w, `{}`)
		case "POST /api/settings/demo/reset":
			f.resets.Add(1)
			_, _ = io.WriteString(w, `{}`)
		case "DELETE /api/images/{id}":
			w.WriteHeader(http.StatusNoContent)
		default:
			_, _ = io.WriteString(w, "ok")
		}
	}))
	t.Cleanup(srv.Close)
	return f, srv
}

func route(p string) string {
	parts := strings.Split(p, "/")
	if len(parts) >= 4 && parts[1] == "api" && parts[2] == "images" {
		parts[3] = "{id}"
	}
	return strings.Join(parts, "/")
}

func TestOptionsValidation(t *testing.T) {
	cases := []struct {
		args    []string
		wantErr string
	}{
		{[]string{}, "--target is required"},
		{[]string{"--target", "http://x", "--rate", "30"}, "--force"},
		{[]string{"--target", "http://x", "--scenario", "nope"}, "unknown scenario"},
	}
	for _, c := range cases {
		if _, err := parseOptions(c.args, io.Discard); err == nil || !strings.Contains(err.Error(), c.wantErr) {
			t.Errorf("%v: err = %v, want %q", c.args, err, c.wantErr)
		}
	}
	o, err := parseOptions([]string{"--target", "http://x/", "--rate", "30", "--force"}, io.Discard)
	if err != nil || o.Rate != 30 || o.Target != "http://x" {
		t.Fatalf("forced rate: %+v %v", o, err)
	}
	o, _ = parseOptions([]string{"--target", "http://x", "--scenario", "steady"}, io.Discard)
	if o.Rate != 1 {
		t.Fatalf("steady default rate = %v, want 1", o.Rate)
	}
}

func TestMixedScenarioIsOpenLoopAndCoversOps(t *testing.T) {
	f, srv := newFakeApp(t)
	sum, err := Run(context.Background(), Options{Target: srv.URL, Scenario: "mixed", Rate: 25, Duration: 2 * time.Second, Concurrency: 10, Seed: 7}, io.Discard)
	if err != nil {
		t.Fatal(err)
	}
	if sum.Requests < 35 || sum.Errors != 0 || sum.Shed != 0 {
		t.Fatalf("summary = %+v", sum)
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	for _, k := range []string{"GET /api/images", "POST /api/images", "GET /api/images/{id}/thumbnail"} {
		if f.hits[k] == 0 {
			t.Errorf("never called %s (hits %v)", k, f.hits)
		}
	}
}

func TestClientInjectsTraceparent(t *testing.T) {
	otel.SetTextMapPropagator(propagation.TraceContext{})
	otel.SetTracerProvider(sdktrace.NewTracerProvider())
	f, srv := newFakeApp(t)
	if _, err := Run(context.Background(), Options{Target: srv.URL, Scenario: "browse", Rate: 10, Duration: 500 * time.Millisecond, Concurrency: 2, Seed: 1}, io.Discard); err != nil {
		t.Fatal(err)
	}
	if f.traceparent.Load() == 0 {
		t.Fatal("requests carried no traceparent: traces would not start at the client")
	}
}

func TestBreakerStopsASustainedErrorRate(t *testing.T) {
	f, srv := newFakeApp(t)
	f.fail.Store(true)
	start := time.Now()
	_, err := Run(context.Background(), Options{Target: srv.URL, Scenario: "browse", Rate: 25, Duration: time.Minute, Concurrency: 10, Seed: 1}, io.Discard)
	if !errors.Is(err, ErrBreakerTripped) || time.Since(start) > 15*time.Second {
		t.Fatalf("err = %v after %s", err, time.Since(start))
	}
}

func TestIncidentRunsEveryPhaseThenResets(t *testing.T) {
	f, srv := newFakeApp(t)
	var out strings.Builder
	if _, err := Run(context.Background(), Options{Target: srv.URL, Scenario: "incident", Rate: 20, Concurrency: 5, Seed: 1, PhaseScale: 0.002}, &out); err != nil {
		t.Fatal(err)
	}
	if f.resets.Load() != 1 {
		t.Fatalf("resets = %d, want 1", f.resets.Load())
	}
	var sawLatency, sawErrors, sawSlowWorker bool
	for _, p := range f.demoPuts {
		sawLatency = sawLatency || p["latency_ms"] == float64(800)
		sawErrors = sawErrors || p["error_probability"] == 0.2
		sawSlowWorker = sawSlowWorker || p["worker_delay_ms"] == float64(4000)
	}
	if !sawLatency || !sawErrors || !sawSlowWorker || !strings.Contains(out.String(), "phase recovery") {
		t.Fatalf("puts = %v\noutput:\n%s", f.demoPuts, out.String())
	}
}

func TestIncidentResetsOnInterrupt(t *testing.T) {
	f, srv := newFakeApp(t)
	ctx, cancel := context.WithTimeout(context.Background(), 300*time.Millisecond)
	defer cancel()
	_, _ = Run(ctx, Options{Target: srv.URL, Scenario: "incident", Rate: 10, Concurrency: 2, Seed: 1, PhaseScale: 1}, io.Discard)
	if f.resets.Load() != 1 {
		t.Fatalf("an interrupted incident must still reset the controls, resets = %d", f.resets.Load())
	}
}

func TestPercentile(t *testing.T) {
	d := []time.Duration{1, 2, 3, 4, 5, 6, 7, 8, 9, 10}
	if p := percentile(d, 0.5); p != 5 {
		t.Errorf("p50 = %v", p)
	}
	if p := percentile(d, 0.99); p != 10 {
		t.Errorf("p99 = %v", p)
	}
}
```

- [ ] **Step 2: Run the tests and confirm they fail.**

Run: `go test ./internal/loadgen/ -v`
Expected: FAIL to compile, because the package does not exist yet.

- [ ] **Step 3: Create `internal/loadgen/options.go`.**

```go
// Package loadgen drives the image-gallery API with open-loop scenarios, from
// a laptop or in-cluster, instrumented so that traces start at the client.
package loadgen

import (
	"errors"
	"flag"
	"fmt"
	"io"
	"net/url"
	"strings"
	"time"
)

// MaxRate is the default cap (req/s); --force lifts it. It is also the soak
// target of success criterion 5.
const MaxRate = 25

// Options configures one run.
type Options struct {
	Target      string
	Scenario    string
	Rate        float64
	Duration    time.Duration
	Concurrency int
	Force       bool
	Seed        int64
	PhaseScale  float64 // incident phase-length multiplier (tests shrink it)
}

func parseOptions(args []string, stderr io.Writer) (Options, error) {
	fs := flag.NewFlagSet("loadgen", flag.ContinueOnError)
	fs.SetOutput(stderr)
	var o Options
	fs.StringVar(&o.Target, "target", "", "base URL of the app (required), e.g. https://image-gallery.priv.gcp.ogenki.io")
	fs.StringVar(&o.Scenario, "scenario", "mixed", "browse | upload | mixed | steady | incident")
	fs.Float64Var(&o.Rate, "rate", 0, "arrival rate in req/s (default 10; 1 for steady)")
	fs.DurationVar(&o.Duration, "duration", 5*time.Minute, "run length (incident follows its own ~10 min timeline)")
	fs.IntVar(&o.Concurrency, "concurrency", 20, "cap on requests in flight; arrivals beyond it are shed, not delayed")
	fs.BoolVar(&o.Force, "force", false, fmt.Sprintf("allow --rate above %d req/s", MaxRate))
	fs.Int64Var(&o.Seed, "seed", 0, "random seed (0 = time-based)")
	fs.Float64Var(&o.PhaseScale, "phase-scale", 1, "incident phase-length multiplier")
	if err := fs.Parse(args); err != nil {
		return o, err
	}
	return o, o.validate()
}

func (o *Options) validate() error {
	if o.Target == "" {
		return errors.New("--target is required")
	}
	if u, err := url.Parse(o.Target); err != nil || u.Scheme == "" || u.Host == "" {
		return fmt.Errorf("--target %q is not an absolute URL", o.Target)
	}
	o.Target = strings.TrimRight(o.Target, "/")
	if _, ok := scenarios[o.Scenario]; !ok && o.Scenario != scenarioIncident {
		return fmt.Errorf("unknown scenario %q (browse, upload, mixed, steady, incident)", o.Scenario)
	}
	if o.Rate == 0 {
		o.Rate = 10
		if o.Scenario == "steady" {
			o.Rate = 1
		}
	}
	if o.Rate < 0 {
		return errors.New("--rate must be positive")
	}
	if o.Rate > MaxRate && !o.Force {
		return fmt.Errorf("--rate %v exceeds the %d req/s cap; pass --force to exceed it", o.Rate, MaxRate)
	}
	if o.Concurrency < 1 {
		return errors.New("--concurrency must be at least 1")
	}
	if o.Duration <= 0 {
		o.Duration = 5 * time.Minute
	}
	if o.PhaseScale <= 0 {
		o.PhaseScale = 1
	}
	if o.Seed == 0 {
		o.Seed = time.Now().UnixNano()
	}
	return nil
}
```

- [ ] **Step 4: Create `internal/loadgen/imagegen.go`.**

```go
package loadgen

import (
	"bytes"
	"fmt"
	"image"
	"image/color"
	"image/jpeg"
	"image/png"
	"math/rand/v2"
	"sync"
)

// lockedRand is a goroutine-safe, seedable random source.
type lockedRand struct {
	mu sync.Mutex
	r  *rand.Rand
}

func newLockedRand(seed int64) *lockedRand {
	return &lockedRand{r: rand.New(rand.NewPCG(uint64(seed), uint64(seed)^0x9e3779b97f4a7c15))}
}

func (l *lockedRand) IntN(n int) int { l.mu.Lock(); defer l.mu.Unlock(); return l.r.IntN(n) }
func (l *lockedRand) Float64() float64 {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.r.Float64()
}

// generateImage returns an in-memory gradient of a random size (320-1920 px
// wide), as PNG or JPEG: varied sizes and formats exercise storage and the
// worker's decode and resize. Every generated file stays under the 10 MiB cap.
func generateImage(rnd *lockedRand) (data []byte, name, contentType string, err error) {
	w, h := 320+rnd.IntN(1601), 240+rnd.IntN(1201)
	from := color.RGBA{uint8(rnd.IntN(256)), uint8(rnd.IntN(256)), uint8(rnd.IntN(256)), 255}
	to := color.RGBA{uint8(rnd.IntN(256)), uint8(rnd.IntN(256)), uint8(rnd.IntN(256)), 255}
	img := image.NewRGBA(image.Rect(0, 0, w, h))
	for y := 0; y < h; y++ {
		t := float64(y) / float64(h)
		c := color.RGBA{lerp(from.R, to.R, t), lerp(from.G, to.G, t), lerp(from.B, to.B, t), 255}
		row := img.Pix[y*img.Stride : y*img.Stride+w*4]
		for x := 0; x < w*4; x += 4 {
			row[x], row[x+1], row[x+2], row[x+3] = c.R, c.G, c.B, c.A
		}
	}
	var buf bytes.Buffer
	ext := "png"
	contentType = "image/png"
	if rnd.IntN(2) == 0 {
		err = png.Encode(&buf, img)
	} else {
		ext, contentType = "jpg", "image/jpeg"
		err = jpeg.Encode(&buf, img, &jpeg.Options{Quality: 80})
	}
	return buf.Bytes(), fmt.Sprintf("loadgen-%d.%s", rnd.IntN(1_000_000_000), ext), contentType, err
}

func lerp(a, b uint8, t float64) uint8 { return uint8(float64(a) + (float64(b)-float64(a))*t) }
```

- [ ] **Step 5: Create `internal/loadgen/ops.go`.**

```go
package loadgen

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"mime/multipart"
	"net/http"
	"net/textproto"
	"strconv"
	"strings"
	"sync"
	"time"

	"go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/codes"
	"go.opentelemetry.io/otel/trace"
)

// Op is one kind of request.
type Op string

const (
	OpList      Op = "list"
	OpView      Op = "view"
	OpThumbnail Op = "thumbnail"
	OpUpload    Op = "upload"
	OpDelete    Op = "delete"
	OpSettings  Op = "settings"
)

var browseTags = []string{"loadgen", "nature", "travel"}

type client struct {
	base     string
	scenario string
	http     *http.Client
	rnd      *lockedRand
	tracer   trace.Tracer

	mu   sync.Mutex
	ids  []int // IDs seen in listings
	mine []int // IDs this run uploaded: the only delete targets
}

func newClient(base, scenario string, rnd *lockedRand) *client {
	return &client{base: base, scenario: scenario, rnd: rnd, tracer: otel.Tracer("image-gallery/loadgen"),
		http: &http.Client{Timeout: 30 * time.Second, Transport: otelhttp.NewTransport(http.DefaultTransport)}}
}

// do runs op under a root span "loadgen <op>"; otelhttp adds the CLIENT span
// and injects traceparent, so the trace starts here. Returns the HTTP status.
func (c *client) do(ctx context.Context, op Op) (status int, err error) {
	ctx, span := c.tracer.Start(ctx, "loadgen "+string(op), trace.WithAttributes(
		attribute.String("loadgen.scenario", c.scenario), attribute.String("loadgen.op", string(op))))
	defer func() {
		if err != nil {
			span.RecordError(err)
			span.SetStatus(codes.Error, err.Error())
		}
		span.End()
	}()
	switch op {
	case OpList:
		return c.list(ctx)
	case OpView, OpThumbnail:
		id, ok := c.pick(false)
		if !ok {
			return c.list(ctx)
		}
		suffix := "/view"
		if op == OpThumbnail {
			suffix = "/thumbnail"
		}
		return c.get(ctx, fmt.Sprintf("/api/images/%d%s", id, suffix))
	case OpUpload:
		return c.upload(ctx)
	case OpDelete:
		id, ok := c.pick(true)
		if !ok {
			return c.upload(ctx) // nothing of ours to delete yet
		}
		return c.send(ctx, http.MethodDelete, fmt.Sprintf("/api/images/%d", id), nil, "")
	case OpSettings:
		return c.get(ctx, "/api/settings")
	}
	return 0, fmt.Errorf("unknown op %q", op)
}

func (c *client) list(ctx context.Context) (int, error) {
	path := "/api/images"
	if c.rnd.IntN(10) < 3 {
		path += "?tags=" + browseTags[c.rnd.IntN(len(browseTags))]
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, c.base+path, nil)
	if err != nil {
		return 0, err
	}
	resp, err := c.http.Do(req)
	if err != nil {
		return 0, err
	}
	defer func() { _ = resp.Body.Close() }()
	var body struct {
		Images []struct {
			ID json.RawMessage `json:"id"`
		} `json:"images"`
	}
	if resp.StatusCode < 300 && json.NewDecoder(resp.Body).Decode(&body) == nil {
		c.mu.Lock()
		for _, im := range body.Images {
			if id, err := strconv.Atoi(strings.Trim(string(im.ID), `"`)); err == nil && len(c.ids) < 500 {
				c.ids = append(c.ids, id)
			}
		}
		c.mu.Unlock()
	}
	return resp.StatusCode, statusErr(resp.StatusCode)
}

func (c *client) upload(ctx context.Context) (int, error) {
	data, name, contentType, err := generateImage(c.rnd)
	if err != nil {
		return 0, err
	}
	var buf bytes.Buffer
	mw := multipart.NewWriter(&buf)
	hdr := textproto.MIMEHeader{}
	hdr.Set("Content-Disposition", fmt.Sprintf(`form-data; name="files"; filename="%s"`, name))
	hdr.Set("Content-Type", contentType)
	part, err := mw.CreatePart(hdr)
	if err != nil {
		return 0, err
	}
	_, _ = part.Write(data)
	_ = mw.WriteField("tags", "loadgen")
	_ = mw.Close()
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, c.base+"/api/images", &buf)
	if err != nil {
		return 0, err
	}
	req.Header.Set("Content-Type", mw.FormDataContentType())
	resp, err := c.http.Do(req)
	if err != nil {
		return 0, err
	}
	defer func() { _ = resp.Body.Close() }()
	var body struct {
		Images []struct {
			ID json.RawMessage `json:"id"`
		} `json:"images"`
	}
	if resp.StatusCode < 300 && json.NewDecoder(resp.Body).Decode(&body) == nil {
		c.mu.Lock()
		for _, im := range body.Images {
			if id, err := strconv.Atoi(strings.Trim(string(im.ID), `"`)); err == nil {
				c.mine = append(c.mine, id)
			}
		}
		c.mu.Unlock()
	}
	return resp.StatusCode, statusErr(resp.StatusCode)
}

func (c *client) get(ctx context.Context, path string) (int, error) {
	return c.send(ctx, http.MethodGet, path, nil, "")
}

func (c *client) send(ctx context.Context, method, path string, body []byte, contentType string) (int, error) {
	req, err := http.NewRequestWithContext(ctx, method, c.base+path, bytes.NewReader(body))
	if err != nil {
		return 0, err
	}
	if contentType != "" {
		req.Header.Set("Content-Type", contentType)
	}
	resp, err := c.http.Do(req)
	if err != nil {
		return 0, err
	}
	_, _ = io.Copy(io.Discard, resp.Body)
	_ = resp.Body.Close()
	return resp.StatusCode, statusErr(resp.StatusCode)
}

// pick returns a known image ID; own=true pops one this run uploaded.
func (c *client) pick(own bool) (int, bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if own {
		if len(c.mine) == 0 {
			return 0, false
		}
		id := c.mine[len(c.mine)-1]
		c.mine = c.mine[:len(c.mine)-1]
		return id, true
	}
	if len(c.ids) == 0 {
		return 0, false
	}
	return c.ids[c.rnd.IntN(len(c.ids))], true
}

// statusErr counts 5xx as failures; a 4xx (e.g. an image another client deleted) is not the server failing.
func statusErr(code int) error {
	if code >= 500 {
		return fmt.Errorf("server error %d", code)
	}
	return nil
}
```

- [ ] **Step 6: Create `scenarios.go`, `breaker.go` and `summary.go`.**

`internal/loadgen/scenarios.go`:

```go
package loadgen

type weighted struct {
	op     Op
	weight int
}

const scenarioIncident = "incident"

var mixedOps = []weighted{{OpList, 35}, {OpView, 20}, {OpThumbnail, 20}, {OpUpload, 15}, {OpDelete, 5}, {OpSettings, 5}}

// scenarios maps each open-loop scenario to its weighted operation mix.
var scenarios = map[string][]weighted{
	"browse": {{OpList, 50}, {OpView, 30}, {OpThumbnail, 20}},   // cache hits/misses, DB reads
	"upload": {{OpUpload, 100}},                                 // storage, queue, worker
	"mixed":  mixedOps,                                          // the realistic baseline
	"steady": mixedOps,                                          // same mix at a low rate (in-cluster)
}

func picker(ws []weighted, rnd *lockedRand) func() Op {
	total := 0
	for _, w := range ws {
		total += w.weight
	}
	return func() Op {
		n := rnd.IntN(total)
		for _, w := range ws {
			if n < w.weight {
				return w.op
			}
			n -= w.weight
		}
		return ws[len(ws)-1].op
	}
}
```

`internal/loadgen/breaker.go`:

```go
package loadgen

import (
	"errors"
	"sync"
)

// ErrBreakerTripped ends a run whose error rate stayed above the threshold.
var ErrBreakerTripped = errors.New("circuit breaker tripped: sustained error rate above 50 % — stopping so the load does not pile onto a failing app")

// breaker trips when more than threshold of the last `size` results failed,
// once at least `size/2` results are in.
type breaker struct {
	mu        sync.Mutex
	ring      []bool
	next      int
	filled    int
	failures  int
	threshold float64
}

func newBreaker(size int, threshold float64) *breaker {
	return &breaker{ring: make([]bool, size), threshold: threshold}
}

func (b *breaker) record(failed bool) (tripped bool) {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.filled == len(b.ring) && b.ring[b.next] {
		b.failures--
	}
	b.ring[b.next] = failed
	if failed {
		b.failures++
	}
	b.next = (b.next + 1) % len(b.ring)
	if b.filled < len(b.ring) {
		b.filled++
	}
	return b.filled >= len(b.ring)/2 && float64(b.failures)/float64(b.filled) > b.threshold
}
```

`internal/loadgen/summary.go`:

```go
package loadgen

import (
	"fmt"
	"math"
	"sort"
	"strings"
	"sync"
	"time"
)

// Summary is printed at the end of a run.
type Summary struct {
	Requests, Errors, Shed int
	Elapsed                time.Duration
	Rate, ErrorPct         float64
	P50, P95, P99          time.Duration
	ByOp                   map[Op]int
}

func (s Summary) String() string {
	var b strings.Builder
	fmt.Fprintf(&b, "\n== loadgen summary ==\nrequests %d in %s (%.1f req/s)  errors %d (%.2f %%)  shed %d\n",
		s.Requests, s.Elapsed.Round(time.Second), s.Rate, s.Errors, s.ErrorPct, s.Shed)
	fmt.Fprintf(&b, "client latency  p50 %s  p95 %s  p99 %s\n", s.P50.Round(time.Millisecond), s.P95.Round(time.Millisecond), s.P99.Round(time.Millisecond))
	ops := make([]string, 0, len(s.ByOp))
	for op, n := range s.ByOp {
		ops = append(ops, fmt.Sprintf("%s=%d", op, n))
	}
	sort.Strings(ops)
	fmt.Fprintf(&b, "by op  %s\n", strings.Join(ops, "  "))
	return b.String()
}

type stats struct {
	mu     sync.Mutex
	start  time.Time
	durs   []time.Duration
	errors int
	shed   int
	byOp   map[Op]int
}

func newStats() *stats { return &stats{start: time.Now(), byOp: map[Op]int{}} }

func (s *stats) add(op Op, d time.Duration, failed bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.durs = append(s.durs, d)
	s.byOp[op]++
	if failed {
		s.errors++
	}
}

func (s *stats) addShed() { s.mu.Lock(); s.shed++; s.mu.Unlock() }

func (s *stats) summary() Summary {
	s.mu.Lock()
	defer s.mu.Unlock()
	sorted := append([]time.Duration(nil), s.durs...)
	sort.Slice(sorted, func(i, j int) bool { return sorted[i] < sorted[j] })
	el := time.Since(s.start)
	sum := Summary{Requests: len(sorted), Errors: s.errors, Shed: s.shed, Elapsed: el, ByOp: map[Op]int{},
		P50: percentile(sorted, 0.50), P95: percentile(sorted, 0.95), P99: percentile(sorted, 0.99)}
	for k, v := range s.byOp {
		sum.ByOp[k] = v
	}
	if el > 0 {
		sum.Rate = float64(len(sorted)) / el.Seconds()
	}
	if len(sorted) > 0 {
		sum.ErrorPct = 100 * float64(s.errors) / float64(len(sorted))
	}
	return sum
}

func (s *stats) progressLine() string {
	sum := s.summary()
	return fmt.Sprintf("t=%-6s req=%-6d rate=%5.1f/s err=%5.2f%% p95=%-8s shed=%d",
		sum.Elapsed.Round(time.Second), sum.Requests, sum.Rate, sum.ErrorPct, sum.P95.Round(time.Millisecond), sum.Shed)
}

// percentile of an ascending slice (nearest-rank).
func percentile(sorted []time.Duration, q float64) time.Duration {
	if len(sorted) == 0 {
		return 0
	}
	i := int(math.Ceil(q*float64(len(sorted)))) - 1
	return sorted[max(0, min(i, len(sorted)-1))]
}
```

- [ ] **Step 7: Create `engine.go`, `incident.go` and `main.go`.**

`internal/loadgen/engine.go`:

```go
package loadgen

import (
	"context"
	"errors"
	"fmt"
	"io"
	"sync"
	"sync/atomic"
	"time"
)

// engine issues operations at a constant arrival rate (open loop). An arrival
// that finds `concurrency` requests in flight is SHED and counted, never
// delayed, so a slow server cannot quietly lower the offered load.
type engine struct {
	next        func() Op
	do          func(context.Context, Op) (int, error)
	rate        float64
	concurrency int
	stats       *stats
	breaker     *breaker // nil: no breaker (incident)
	out         io.Writer
}

func (e *engine) run(ctx context.Context, d time.Duration) error {
	tick := time.NewTicker(time.Duration(float64(time.Second) / e.rate))
	defer tick.Stop()
	progress := time.NewTicker(5 * time.Second)
	defer progress.Stop()
	deadline := time.NewTimer(d)
	defer deadline.Stop()
	sem := make(chan struct{}, e.concurrency)
	var wg sync.WaitGroup
	defer wg.Wait()
	var tripped atomic.Bool
	for {
		select {
		case <-ctx.Done():
			return nil // interrupted: the summary still prints
		case <-deadline.C:
			return nil
		case <-progress.C:
			fmt.Fprintln(e.out, e.stats.progressLine())
		case <-tick.C:
			if tripped.Load() {
				return ErrBreakerTripped
			}
			select {
			case sem <- struct{}{}:
				wg.Add(1)
				go func() {
					defer wg.Done()
					defer func() { <-sem }()
					op := e.next()
					start := time.Now()
					_, err := e.do(ctx, op)
					if err != nil && ctx.Err() != nil && (errors.Is(err, context.Canceled) || errors.Is(err, context.DeadlineExceeded)) {
						return // cut by the interrupt, not a server failure
					}
					e.stats.add(op, time.Since(start), err != nil)
					if e.breaker != nil && e.breaker.record(err != nil) {
						tripped.Store(true)
					}
				}()
			default:
				e.stats.addShed()
			}
		}
	}
}
```

`internal/loadgen/incident.go`:

```go
package loadgen

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"time"
)

// demoControls mirrors the app's /api/settings/demo document (internal/domain/demo.Controls).
type demoControls struct {
	LatencyMS                int      `json:"latency_ms"`
	LatencyProbability       float64  `json:"latency_probability"`
	LatencyRoutes            []string `json:"latency_routes"`
	ErrorProbability         float64  `json:"error_probability"`
	SlowDBMS                 int      `json:"slow_db_ms"`
	WorkerFailureProbability float64  `json:"worker_failure_probability"`
	WorkerDelayMS            int      `json:"worker_delay_ms"`
}

type phase struct {
	name     string
	length   time.Duration
	controls demoControls
	ops      []weighted
	note     string
}

var uploadHeavy = []weighted{{OpUpload, 60}, {OpList, 20}, {OpThumbnail, 20}}

// incidentPhases is the scripted ~10 minute story told on the dashboards.
var incidentPhases = []phase{
	{"baseline", 2 * time.Minute, demoControls{}, mixedOps, "healthy traffic — note p95, error rate and queue depth"},
	{"latency", 2 * time.Minute, demoControls{LatencyMS: 800, LatencyProbability: 0.5, LatencyRoutes: []string{"/api/images"}}, mixedOps,
		"p95 on the gallery API climbs; exemplars lead to slow traces tagged demo.fault=latency"},
	{"errors", 2 * time.Minute, demoControls{ErrorProbability: 0.2}, mixedOps, "a 5xx burst — error ratio, error spans, logs by trace_id"},
	{"worker-slowdown", 3 * time.Minute, demoControls{WorkerDelayMS: 4000}, uploadHeavy,
		"uploads outpace the worker — queue.depth and queue.lag grow, thumbnails lag"},
	{"recovery", time.Minute, demoControls{}, mixedOps, "controls off — the queue drains, latency and errors return to baseline"},
}

func (c *client) setControls(ctx context.Context, dc demoControls) error {
	if dc.LatencyRoutes == nil {
		dc.LatencyRoutes = []string{}
	}
	body, _ := json.Marshal(dc)
	status, err := c.send(ctx, http.MethodPut, "/api/settings/demo", body, "application/json")
	if err == nil && status >= 300 {
		err = fmt.Errorf("PUT /api/settings/demo: HTTP %d", status)
	}
	return err
}

func (c *client) resetControls(ctx context.Context) error {
	status, err := c.send(ctx, http.MethodPost, "/api/settings/demo/reset", nil, "")
	if err == nil && status >= 300 {
		err = fmt.Errorf("POST /api/settings/demo/reset: HTTP %d", status)
	}
	return err
}

// runIncident plays the phases and ALWAYS resets the controls on the way out,
// including on Ctrl-C, so a presenter can never leave the app broken.
func runIncident(ctx context.Context, o Options, c *client, st *stats, rnd *lockedRand, out io.Writer) (err error) {
	defer func() {
		rctx, cancel := context.WithTimeout(context.WithoutCancel(ctx), 10*time.Second)
		defer cancel()
		if rerr := c.resetControls(rctx); rerr != nil {
			fmt.Fprintf(out, "WARNING: demo controls NOT reset: %v — run: curl -X POST %s/api/settings/demo/reset\n", rerr, o.Target)
			if err == nil {
				err = rerr
			}
			return
		}
		fmt.Fprintln(out, "demo controls reset (all off)")
	}()
	start := time.Now()
	for _, p := range incidentPhases {
		if ctx.Err() != nil {
			return nil
		}
		if err := c.setControls(ctx, p.controls); err != nil {
			return fmt.Errorf("phase %s: %w", p.name, err)
		}
		fmt.Fprintf(out, "[%s +%-5s] phase %-16s %s\n", time.Now().Format("15:04:05"), time.Since(start).Round(time.Second), p.name, p.note)
		e := &engine{next: picker(p.ops, rnd), do: c.do, rate: o.Rate, concurrency: o.Concurrency, stats: st, out: out}
		if err := e.run(ctx, time.Duration(float64(p.length)*o.PhaseScale)); err != nil {
			return err
		}
	}
	return nil
}
```

`internal/loadgen/main.go`:

```go
package loadgen

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"time"

	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/propagation"

	"image-gallery/internal/observability"
)

// Main is `image-gallery loadgen`; it returns the exit code.
func Main(ctx context.Context, args []string, stdout, stderr io.Writer) int {
	o, err := parseOptions(args, stderr)
	if errors.Is(err, flag.ErrHelp) {
		return 0
	}
	if err != nil {
		fmt.Fprintln(stderr, "loadgen:", err)
		return 2
	}
	defer setupTelemetry(ctx, stderr)()
	fmt.Fprintf(stdout, "loadgen: %s -> %s at %.1f req/s (concurrency %d, seed %d)\n", o.Scenario, o.Target, o.Rate, o.Concurrency, o.Seed)
	sum, err := Run(ctx, o, stdout)
	fmt.Fprint(stdout, sum)
	if err != nil {
		fmt.Fprintln(stderr, "loadgen:", err)
		return 1
	}
	return 0
}

// Run executes one scenario and returns its summary.
func Run(ctx context.Context, o Options, out io.Writer) (Summary, error) {
	if err := o.validate(); err != nil {
		return Summary{}, err
	}
	rnd := newLockedRand(o.Seed)
	c := newClient(o.Target, o.Scenario, rnd)
	st := newStats()
	var err error
	if o.Scenario == scenarioIncident {
		err = runIncident(ctx, o, c, st, rnd, out)
	} else {
		e := &engine{next: picker(scenarios[o.Scenario], rnd), do: c.do, rate: o.Rate, concurrency: o.Concurrency,
			stats: st, breaker: newBreaker(100, 0.5), out: out}
		err = e.run(ctx, o.Duration)
	}
	return st.summary(), err
}

// setupTelemetry exports spans and client metrics when OTEL_* endpoints are
// set; otherwise it only installs the W3C propagator (summary-only mode).
func setupTelemetry(ctx context.Context, stderr io.Writer) func() {
	otel.SetTextMapPropagator(propagation.TraceContext{})
	tracesEP, metricsEP := os.Getenv("OTEL_EXPORTER_OTLP_TRACES_ENDPOINT"), os.Getenv("OTEL_EXPORTER_OTLP_METRICS_ENDPOINT")
	if tracesEP == "" && metricsEP == "" {
		return func() {}
	}
	cfg := observability.LoadConfig()
	if os.Getenv("OTEL_SERVICE_NAME") == "" {
		cfg.ServiceName = "image-gallery-loadgen"
	}
	cfg.TracesEnabled, cfg.MetricsEnabled = tracesEP != "", metricsEP != ""
	p, err := observability.NewProvider(ctx, cfg, nil)
	if err != nil {
		fmt.Fprintln(stderr, "loadgen: telemetry disabled:", err)
		return func() {}
	}
	return func() {
		fctx, cancel := context.WithTimeout(context.WithoutCancel(ctx), 10*time.Second)
		defer cancel()
		_ = p.ForceFlush(fctx)
		_ = p.Shutdown(fctx)
	}
}
```

Add to `run` in `cmd/image-gallery/main.go`, with the import `image-gallery/internal/loadgen`:

```go
	case "loadgen":
		return loadgen.Main(ctx, args, os.Stdout, os.Stderr)
```

- [ ] **Step 8: Run the tests and confirm they pass.**

Run: `go test ./internal/loadgen/ -v -race && go build ./... && go test -short ./...`
Expected: PASS for all seven tests, with no race reports.

- [ ] **Step 9: Commit.**

```bash
git add internal/loadgen cmd/image-gallery/main.go
git commit -m "feat(loadgen): open-loop load generator with demo scenarios" \
  -m "image-gallery loadgen --target URL --scenario browse|upload|mixed|steady|incident: constant arrival rate with an in-flight cap (arrivals beyond it are shed and counted), a 25 req/s cap unless --force, a circuit breaker outside incident, and a p50/p95/p99 summary. The client is otelhttp-instrumented: traces start at loadgen. incident drives the demo controls through a ~10 min timeline and resets them on exit, Ctrl-C included."
```


### Task 16: End-to-end trace, the instrument contract, and the local soak

**Files:**
- Create: `internal/e2e/e2e_test.go`, `scripts/soak.sh` and `docker-compose.soak.yml`.
- Modify: `Makefile` (a `soak` target).

**Interfaces:**
- Consumes:
  - `observability.NewProviderWith`, `ExpectedInstruments` and `RuntimeInstruments` (Task 5);
  - `services.NewContainerWithObservability`, `UseJobPublisher`, `DemoInjector`, `ImageRepository` and `StorageService`;
  - `implementations.NewQueueJobPublisher`, `queue.*`, `worker.NewProcessor`, `handlers.NewWithContainer` and `loadgen.Run`;
  - `testutils.SetupTestContainers`, `GetDatabaseURL` and the `RedisEndpoint`/`ObjectStore` fields;
  - `database.NewConnection` and `cache.NewInstrumentedClient`.
- Produces: `TestEndToEndTraceAndInstrumentContract`, which is success criteria 3 and 4 in-process, and `scripts/soak.sh`, which is criterion 5 locally.

- [ ] **Step 1: Write the end-to-end test.** It doubles as the instrument-name contract. Create `internal/e2e/e2e_test.go`:

```go
// Package e2e runs web, worker and loadgen in one process against real
// Postgres, MinIO and Valkey containers and asserts the telemetry contract.
package e2e

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/propagation"
	sdkmetric "go.opentelemetry.io/otel/sdk/metric"
	"go.opentelemetry.io/otel/sdk/metric/metricdata"
	"go.opentelemetry.io/otel/sdk/trace/tracetest"
	"go.opentelemetry.io/otel/trace"
	"github.com/redis/go-redis/v9"

	"image-gallery/internal/config"
	"image-gallery/internal/loadgen"
	"image-gallery/internal/observability"
	"image-gallery/internal/platform/cache"
	"image-gallery/internal/platform/database"
	"image-gallery/internal/platform/queue"
	"image-gallery/internal/services"
	"image-gallery/internal/services/implementations"
	"image-gallery/internal/testutils"
	"image-gallery/internal/web/handlers"
	"image-gallery/internal/worker"
)

func TestEndToEndTraceAndInstrumentContract(t *testing.T) {
	if testing.Short() {
		t.Skip("integration test")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Minute)
	defer cancel()

	// Telemetry first: the instruments are created at construction.
	spans := tracetest.NewInMemoryExporter()
	reader := sdkmetric.NewManualReader()
	var logs bytes.Buffer
	ocfg := observability.Config{ServiceName: "image-gallery-e2e", ServiceVersion: "test", Environment: "test",
		TracesEnabled: true, TracesEndpoint: "http://unused", TracesSampler: observability.SamplerAlwaysOn, TracesSamplerArg: "1",
		MetricsEnabled: true, MetricsEndpoint: "http://unused", LogLevel: "info", LogFormat: "json"}
	logger := observability.NewLoggerTo(&logs, ocfg)
	prov, err := observability.NewProviderWith(ctx, ocfg, logger, spans, reader)
	if err != nil {
		t.Fatal(err)
	}
	otel.SetTextMapPropagator(propagation.TraceContext{})

	tc, err := testutils.SetupTestContainers(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = tc.Cleanup(ctx) }()
	db, err := database.NewConnection(tc.GetDatabaseURL()) // otelsql-instrumented, like production
	if err != nil {
		t.Fatal(err)
	}
	cfg := &config.Config{Environment: "test", DatabaseURL: tc.GetDatabaseURL(),
		Storage: config.StorageConfig{Provider: "s3", BucketName: "test-images", MaxUploadSize: 10 << 20},
		Cache:   config.CacheConfig{Enabled: true, Address: tc.RedisEndpoint, DefaultTTL: time.Hour, DialTimeout: 5 * time.Second, ReadTimeout: 3 * time.Second}}
	rdb, err := cache.NewInstrumentedClient(cfg.Cache)
	if err != nil {
		t.Fatal(err)
	}

	// Web role.
	container, err := services.NewContainerWithObservability(cfg, db, tc.ObjectStore, logger)
	if err != nil {
		t.Fatal(err)
	}
	producer, err := queue.NewProducer(rdb)
	if err != nil {
		t.Fatal(err)
	}
	container.UseJobPublisher(implementations.NewQueueJobPublisher(producer))
	srv := httptest.NewServer(handlers.NewWithContainer(container).Routes())
	defer srv.Close()

	// Worker role.
	proc := worker.NewProcessor(container.ImageRepository(), container.StorageService(), container.DemoInjector(), logger)
	consumer, err := queue.NewConsumer(rdb, queue.WithDeadLetterHook(proc.OnDeadLetter), queue.WithBlock(200*time.Millisecond))
	if err != nil {
		t.Fatal(err)
	}
	gauges := redis.NewClient(&redis.Options{Addr: tc.RedisEndpoint})
	defer func() { _ = gauges.Close() }()
	if err := queue.RegisterGauges(gauges, otel.Meter("image-gallery/queue"), queue.DefaultStream, queue.DefaultGroup); err != nil {
		t.Fatal(err)
	}
	wctx, stopWorker := context.WithCancel(ctx)
	workerDone := make(chan struct{})
	go func() { _ = consumer.Run(wctx, proc.Handle); close(workerDone) }()

	// Loadgen drives the traffic: uploads, then the mix (list/view/thumbnail/delete/settings).
	if _, err := loadgen.Run(ctx, loadgen.Options{Target: srv.URL, Scenario: "upload", Rate: 2, Duration: 2 * time.Second, Concurrency: 2, Seed: 1}, io.Discard); err != nil {
		t.Fatal(err)
	}
	waitAllReady(t, srv.URL)
	if _, err := loadgen.Run(ctx, loadgen.Options{Target: srv.URL, Scenario: "mixed", Rate: 10, Duration: 3 * time.Second, Concurrency: 4, Seed: 2}, io.Discard); err != nil {
		t.Fatal(err)
	}
	// One fault, so demo.faults.injected exists: a slow list query.
	put(t, srv.URL+"/api/settings/demo", `{"slow_db_ms": 20}`)
	get(t, srv.URL+"/api/images")
	post(t, srv.URL+"/api/settings/demo/reset")

	stopWorker()
	<-workerDone
	if err := prov.ForceFlush(ctx); err != nil {
		t.Fatal(err)
	}

	// Criterion 3: one trace spans loadgen -> web -> producer -> consumer, with DB, cache and storage children.
	byTrace := map[trace.TraceID][]tracetest.SpanStub{}
	for _, s := range spans.GetSpans() {
		byTrace[s.SpanContext.TraceID()] = append(byTrace[s.SpanContext.TraceID()], s)
	}
	var found trace.TraceID
	for id, ss := range byTrace {
		if has(ss, func(s tracetest.SpanStub) bool { return s.Name == "loadgen upload" && !s.Parent.IsValid() }) &&
			has(ss, func(s tracetest.SpanStub) bool { return s.Name == "POST /api/images" && s.SpanKind == trace.SpanKindServer }) &&
			has(ss, func(s tracetest.SpanStub) bool { return strings.HasPrefix(s.Name, "send ") && s.SpanKind == trace.SpanKindProducer }) &&
			has(ss, func(s tracetest.SpanStub) bool {
				return strings.HasPrefix(s.Name, "process ") && s.SpanKind == trace.SpanKindConsumer && len(s.Links) == 1
			}) &&
			has(ss, func(s tracetest.SpanStub) bool { return s.Name == "storage.put" }) &&
			has(ss, func(s tracetest.SpanStub) bool { return s.Name == "image.thumbnail" }) &&
			has(ss, func(s tracetest.SpanStub) bool { return strings.Contains(s.InstrumentationScope.Name, "otelsql") }) &&
			has(ss, func(s tracetest.SpanStub) bool { return strings.Contains(s.InstrumentationScope.Name, "redisotel") }) {
			found = id
			break
		}
	}
	if !found.IsValid() {
		t.Fatalf("no trace spans loadgen -> web -> queue -> worker with DB, Valkey and storage children (%d traces)", len(byTrace))
	}
	if !strings.Contains(logs.String(), found.String()) {
		t.Errorf("no log line carries trace_id %s", found)
	}

	// Criterion 4: every contract instrument exists under its dot name.
	var rm metricdata.ResourceMetrics
	if err := reader.Collect(ctx, &rm); err != nil {
		t.Fatal(err)
	}
	have := map[string]bool{}
	for _, sm := range rm.ScopeMetrics {
		for _, m := range sm.Metrics {
			have[m.Name] = true
		}
	}
	want := append(append(append([]string{}, observability.ExpectedInstruments["web"]...), observability.ExpectedInstruments["worker"]...), observability.RuntimeInstruments...)
	for _, name := range want {
		if !have[name] {
			t.Errorf("instrument %q missing (contract drift)", name)
		}
	}
}

func has(ss []tracetest.SpanStub, pred func(tracetest.SpanStub) bool) bool {
	for _, s := range ss {
		if pred(s) {
			return true
		}
	}
	return false
}

func waitAllReady(t *testing.T, base string) {
	t.Helper()
	deadline := time.Now().Add(60 * time.Second)
	for time.Now().Before(deadline) {
		var body struct {
			Images []struct {
				Status string `json:"status"`
			} `json:"images"`
		}
		resp, err := http.Get(base + "/api/images")
		if err == nil {
			_ = json.NewDecoder(resp.Body).Decode(&body)
			_ = resp.Body.Close()
			ready := len(body.Images) > 0
			for _, im := range body.Images {
				ready = ready && im.Status == "ready"
			}
			if ready {
				return
			}
		}
		time.Sleep(250 * time.Millisecond)
	}
	t.Fatal("uploaded images never reached status ready")
}

func get(t *testing.T, url string) { t.Helper(); do(t, http.MethodGet, url, "") }
func post(t *testing.T, url string) { t.Helper(); do(t, http.MethodPost, url, "") }
func put(t *testing.T, url, body string) { t.Helper(); do(t, http.MethodPut, url, body) }

func do(t *testing.T, method, url, body string) {
	t.Helper()
	req, _ := http.NewRequest(method, url, strings.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	resp, err := http.DefaultClient.Do(req)
	if err != nil || resp.StatusCode >= 300 {
		t.Fatalf("%s %s: %v %v", method, url, err, resp)
	}
	_ = resp.Body.Close()
}
```

If the `testutils` field and getter names differ from `RedisEndpoint`, `ObjectStore` and `GetDatabaseURL()` (Task 8 renamed `MinioClient`), use the real names; the assertions stay the same. If the `tracetest.SpanStub` scope field is named `InstrumentationLibrary` in SDK v1.46.0, use it.

- [ ] **Step 2: Run it.**

Run: `go test ./internal/e2e/ -v -count=1`
Expected: PASS. A failure here is a real integration gap. Fix it in the task that owns the component; the test does not change.

- [ ] **Step 3: Add the local soak (criterion 5, locally).** Create `docker-compose.soak.yml`, an overlay on `docker-compose.yml`. Pin both Victoria images to the versions running on the platform:
  - `kubectl get vmsingle -n observability -o jsonpath='{.items[0].spec.image.tag}'` gives the vmsingle tag;
  - `kubectl get pod -n observability victoria-traces-vt-single-server-0 -o jsonpath='{.spec.containers[0].image}'` gives the full VictoriaTraces image.

  Copy the two values into the file.

```yaml
# Soak overlay: app and worker under container memory limits, exporting at
# 100 % sampling to local VictoriaMetrics + VictoriaTraces.
#   docker compose -f docker-compose.yml -f docker-compose.soak.yml up -d --build
services:
  victoria-metrics:
    image: victoriametrics/victoria-metrics:<tag from vmsingle on gcp-0>
    container_name: image-gallery-vm
    ports: ["8428:8428"]
  victoria-traces:
    image: <image from vt-single on gcp-0>
    container_name: image-gallery-vt
    ports: ["10428:10428"]
  app:
    mem_limit: 1g
    environment: &otel
      - STORAGE_PROVIDER=s3
      - OTEL_TRACES_ENABLED=true
      - OTEL_TRACES_SAMPLER=parentbased_always_on
      - OTEL_EXPORTER_OTLP_TRACES_ENDPOINT=http://victoria-traces:10428/insert/opentelemetry/v1/traces
      - OTEL_METRICS_ENABLED=true
      - OTEL_EXPORTER_OTLP_METRICS_ENDPOINT=http://victoria-metrics:8428/opentelemetry/v1/metrics
    depends_on: [victoria-metrics, victoria-traces]
  worker:
    build: { context: ., dockerfile: Dockerfile }
    container_name: image-gallery-worker
    command: ["worker"]
    mem_limit: 512m
    environment:
      - GO_ENV=development
      - OTEL_SERVICE_NAME=image-gallery-worker
      - DATABASE_URL=postgres://testuser:testpass@postgres:5432/image_gallery_test?sslmode=disable # pragma: allowlist secret
      - STORAGE_PROVIDER=s3
      - STORAGE_ENDPOINT=minio:9000
      - STORAGE_ACCESS_KEY=minioadmin
      - STORAGE_SECRET_KEY=minioadmin
      - STORAGE_BUCKET=images
      - STORAGE_USE_SSL=false
      - STORAGE_REGION=us-east-1
      - CACHE_ENABLED=true
      - CACHE_ADDRESS=valkey:6379
      - OTEL_TRACES_ENABLED=true
      - OTEL_TRACES_SAMPLER=parentbased_always_on
      - OTEL_EXPORTER_OTLP_TRACES_ENDPOINT=http://victoria-traces:10428/insert/opentelemetry/v1/traces
      - OTEL_METRICS_ENABLED=true
      - OTEL_EXPORTER_OTLP_METRICS_ENDPOINT=http://victoria-metrics:8428/opentelemetry/v1/metrics
    depends_on: [postgres, minio, valkey, victoria-metrics, victoria-traces]
```

The `app` service's existing `environment` list in `docker-compose.yml` is merged with this one by Compose. Keep the `&otel` anchor or drop it; nothing references it.

Create `scripts/soak.sh`:

```bash
#!/usr/bin/env bash
# Local soak for success criterion 5: loadgen `mixed` at the 25 req/s cap for
# 15 minutes at 100 % sampling, under container memory limits. PASS needs no
# OOMKill and a dropped-span ratio under 0.1 %.
set -euo pipefail
cd "$(dirname "$0")/.."
DURATION="${DURATION:-15m}"
compose=(docker compose -f docker-compose.yml -f docker-compose.soak.yml)

"${compose[@]}" up -d --build
trap '"${compose[@]}" logs --tail=50 app worker > soak-logs.txt 2>&1 || true' EXIT
atlas migrate apply --env local
make build
./bin/image-gallery loadgen --target http://localhost:8080 --scenario mixed --rate 25 --duration "$DURATION" --concurrency 40

sleep 30 # let the last export batches and one metrics interval land
fail=0
for c in image-gallery-app image-gallery-worker; do
  oom="$(docker inspect -f '{{.State.OOMKilled}}' "$c")"
  restarts="$(docker inspect -f '{{.RestartCount}}' "$c")"
  echo "$c OOMKilled=$oom restarts=$restarts"
  [[ "$oom" == "false" && "$restarts" == "0" ]] || fail=1
done
q='1 - sum(increase({__name__="telemetry.spans.exported",outcome="success"}[20m])) / sum(increase({__name__="telemetry.spans.ended"}[20m]))'
ratio="$(curl -s http://localhost:8428/api/v1/query --data-urlencode "query=$q" | jq -r '.data.result[0].value[1] // "nan"')"
echo "dropped-span ratio: $ratio (limit 0.001)"
awk -v r="$ratio" 'BEGIN { exit !(r != "nan" && r < 0.001) }' || fail=1
[[ $fail -eq 0 ]] && echo "SOAK PASS" || { echo "SOAK FAIL"; exit 1; }
```

Run `chmod +x scripts/soak.sh`, and add a `soak` target to the `Makefile` (with `.PHONY`) that runs `./scripts/soak.sh`.

- [ ] **Step 4: Run the soak.**

Run: `DURATION=15m ./scripts/soak.sh`
Expected: `SOAK PASS`, with both containers at `OOMKilled=false restarts=0` and a dropped-span ratio below `0.001`.

If it fails, follow the spec's risk rule, and do not tune blindly:
- read `go.memory.used` against `go.memory.limit` in VictoriaMetrics to find the component;
- fix the cause if it is the app;
- otherwise lower the sampling ratio, re-run, and record the measured ceiling. Task 18 then sets that ratio in the claim, and the verification doc states the achieved rate.

- [ ] **Step 5: Commit.**

```bash
git add internal/e2e scripts/soak.sh docker-compose.soak.yml Makefile
git commit -m "test: end-to-end trace and instrument contract, plus a local soak" \
  -m "One in-process run of web, worker and loadgen against real Postgres, MinIO and Valkey asserts a single trace from loadgen through the queue to the worker (DB, Valkey, storage children, consumer link) and every contract metric name. scripts/soak.sh runs mixed at 25 req/s for 15 min at 100 % sampling under memory limits."
```

### Task 17: Documentation and the 2.0.0 release (OWNER GATE)

**Files:**
- Modify: `README.md` (roles, commands, environment), `OBSERVABILITY.md` (the telemetry contract), `docs/ARCHITECTURE.md` (flow), `.env.example` (new variables) and `CLAUDE.md` (the commands section only, if it lists `cmd/server`).

**Interfaces:**
- Consumes: everything above.
- Produces:
  - the image `ghcr.io/smana/image-gallery:2.0.0` (multi-arch);
  - the git tag `v2.0.0`, which carries migration 004.
- Task 18 pins both.

- [ ] **Step 1: Write the docs.**
  - **`OBSERVABILITY.md`:** replace the metrics section with this plan's "Telemetry contract" tables (resource attributes, metrics, spans, faults, logs), and state the dropped-span formula.
  - **`README.md`:** add
    - a "Roles" section with the three commands;
    - an environment table with `STORAGE_PROVIDER` (`s3`|`gcs`), `STORAGE_BUCKET`, `STORAGE_ENDPOINT`/`STORAGE_REGION`/`STORAGE_USE_SSL` (s3 only), `CACHE_ADDRESS` (also the queue), `WORKER_HEALTH_ADDR`, `WORKER_CONCURRENCY`, `POD_NAME`/`POD_NAMESPACE` and the `OTEL_*` variables;
    - a "Demo controls" section showing `curl -X PUT …/api/settings/demo -d '{"latency_ms":800,"latency_probability":0.5}'`;
    - a "Load generator" section with the spec's example command and the scenario table.
  - **`docs/ARCHITECTURE.md`:** add the spec's architecture diagram (§1) and the upload/worker flows.
  - **`.env.example`:** add `STORAGE_PROVIDER=s3`, `WORKER_HEALTH_ADDR=:8081` and `WORKER_CONCURRENCY=2`.
- [ ] **Step 2: Run the full gate.**

Run: `go build ./... && go vet ./... && go test ./... -count=1 && golangci-lint run` (or `make lint`)
Expected: all green, including the integration tests (Docker running).

- [ ] **Step 3: Commit, marking the release version.**

```bash
git add README.md OBSERVABILITY.md docs/ARCHITECTURE.md .env.example CLAUDE.md
git commit -m "docs: v2 roles, storage providers, telemetry contract, demo controls and load generator" \
  -m "Release-As: 2.0.0"
```

- [ ] **Step 4: Push and open the PR.**

```bash
git push -u origin feat/v2-otel-demo
gh pr create --repo Smana/image-gallery --base main \
  --title "feat: image-gallery v2 — worker, GCS, demo controls, load generator, telemetry contract" \
  --body-file <scratch body: summary per task, breaking changes (binary path, metric names, presigned URLs gone), test evidence: go test + e2e + soak output>
```

The body is English, with no attribution line. Wait for CI: `gh pr checks --repo Smana/image-gallery --watch`.

- [ ] **Step 5: OWNER GATE.** The owner merges the PR. Release-please then opens `chore(main): release 2.0.0`, and the owner merges that too, which runs the release workflow.
- [ ] **Step 6: Verify the release.**

Run:
- `docker manifest inspect ghcr.io/smana/image-gallery:2.0.0 | jq -r '.manifests[].platform.architecture'`, then
- `docker run --rm ghcr.io/smana/image-gallery:2.0.0 help`, then
- `gh api 'repos/Smana/image-gallery/contents/internal/platform/database/migrations?ref=v2.0.0' --jq '.[].name'`.

Expected: `amd64` and `arm64`; the usage text; and a listing that includes `004_async_processing_and_demo.sql`.


## Phase D — The claim in cloud-native-ref (Tasks 18–20)

Session: this worktree (`.claude/worktrees/image-gallery-v2`, branch `worktree-image-gallery-v2`), after Tasks 3 and 17 have released. Tools: `kubectl` (kustomize), `flux` ≥ 2.9 with the schema plugin, `jq`, and `yq` if present.

### Task 18: One claim for both clouds, with the worker sidecar and network policies

**Files:**
- Modify (full rewrite): `apps/base/complete/app.yaml`.
- Modify: `apps/aws-0/kustomization.yaml` (storage patch), `apps/gcp-0/kustomization.yaml` (include the base, plus the storage, metadata-egress and backup patch) and `clusters/gcp-0/apps.yaml` (header comment).

**Interfaces:**
- Consumes:
  - the v0.7.0 XRD fields `sidecars[].inheritEnv/livenessProbe/readinessProbe` and `observability.metrics.scrape` (Tasks 1–4);
  - the image `ghcr.io/smana/image-gallery:2.0.0` and the tag `v2.0.0` (Task 17);
  - the app's variables `STORAGE_PROVIDER`, `STORAGE_BUCKET`, `STORAGE_ENDPOINT`, `STORAGE_REGION`, `STORAGE_USE_SSL`, `WORKER_HEALTH_ADDR` and `OTEL_RESOURCE_ATTRIBUTES`.
- Produces: the pod labels `app.kubernetes.io/name=xplane-image-gallery` (from the composition's `_appLabels`), which Task 19's load-generator policy targets.

- [ ] **Step 1: Rewrite `apps/base/complete/app.yaml`.**

```yaml
# source: https://github.com/Smana/image-gallery.git
#
# image-gallery v2, the platform's OpenTelemetry demo app, on BOTH clouds from
# this one claim. Object storage is per cluster (apps/<cluster>/kustomization.yaml
# patches: S3 through EKS Pod Identity on aws-0, GCS through GKE Workload
# Identity on gcp-0). Design: docs/superpowers/specs/2026-09-11-image-gallery-v2-design.md
---
apiVersion: cloud.ogenki.io/v1alpha1
kind: App
metadata:
  name: xplane-image-gallery
  namespace: apps
spec:
  image:
    repository: ghcr.io/smana/image-gallery
    tag: "2.0.0" # move together with atlasSchema.ref below and apps/base/complete/loadgen.yaml
    pullPolicy: IfNotPresent
  replicas: 2
  resources:
    requests:
      cpu: "500m"
      memory: "512Mi"
    limits:
      cpu: "1000m"
      memory: "1Gi"
  onDemand: false
  runAsNonRoot: true
  spreadAcrossZones: true
  antiAffinityPreset: soft
  automountServiceAccountToken: false
  securityContext:
    allowPrivilegeEscalation: false
    readOnlyRootFilesystem: true
    runAsNonRoot: true
    capabilities:
      drop: ["ALL"]
    enableWritableTmp: true

  autoscaling:
    enabled: true
    minReplicas: 2
    maxReplicas: 10
    targetCPUUtilizationPercentage: 60

  pdb:
    enabled: true
    minAvailable: 1
    unhealthyPodEvictionPolicy: AlwaysAllow

  service:
    port: 8080

  # Web role (image-gallery serve, the image's default command). The worker
  # sidecar inherits all of this through inheritEnv. STORAGE_* and
  # OTEL_RESOURCE_ATTRIBUTES are appended per cluster.
  env:
    - name: GO_ENV
      value: "production"
    - name: PORT
      value: "8080"
    - name: LOG_LEVEL
      value: "info"
    - name: LOG_FORMAT
      value: "json"
    - name: DATABASE_URL
      valueFrom:
        secretKeyRef:
          name: xplane-image-gallery-cnpg-image-gallery
          key: uri
    # Valkey: the cache AND the job queue (stream image-gallery:jobs).
    - name: CACHE_ENABLED
      value: "true"
    - name: CACHE_ADDRESS
      value: "xplane-image-gallery-valkey:6379"
    - name: CACHE_PASSWORD
      value: ""

  # Worker role in the same pod: same image, same ServiceAccount, so the
  # storage identity (Pod Identity / Workload Identity) and the secrets work
  # unchanged on both clouds (spec D7).
  sidecars:
    - name: worker
      image: ghcr.io/smana/image-gallery:2.0.0
      args: ["worker"]
      inheritEnv: true
      env:
        - name: OTEL_SERVICE_NAME
          value: xplane-image-gallery-worker
        - name: WORKER_HEALTH_ADDR
          value: ":8081"
      ports:
        - name: worker-health
          containerPort: 8081
      livenessProbe:
        path: /healthz
        port: 8081
      readinessProbe:
        path: /readyz
        port: 8081
      resources:
        requests:
          cpu: "250m"
          memory: "256Mi"
        limits:
          cpu: "1000m"
          memory: "512Mi"

  observability:
    traces:
      enabled: true
      samplingRate: 1.0 # 100 %: the OOM causes are fixed (spec 2.4); dropped spans are measured
    metrics:
      enabled: true
      scrape: false # OTLP push only: there is no /metrics to scrape
    # Sub-project 2 rewrites these rules. The only change here keeps the one
    # working alert alive across the semconv rename (plan ruling 5):
    # http.server.request.count is gone; the duration histogram's count replaces it.
    alertingRules:
      groups:
        - name: http_errors
          interval: 30s
          rules:
            - alert: HighHTTPErrorRate
              expr: |
                sum(rate(http.server.request.duration_count{service.name="xplane-image-gallery",http.response.status_code=~"5.."}[5m]))
                /
                sum(rate(http.server.request.duration_count{service.name="xplane-image-gallery"}[5m]))
                > 0.05
              for: 2m
              labels:
                severity: warning
                service: image-gallery
              annotations:
                summary: "High HTTP 5xx error rate on image-gallery"
                description: |
                  HTTP 5xx error rate is {{ $value | humanizePercentage }} on image-gallery.
                  This indicates server-side errors are affecting more than 5% of requests.
            - alert: HighHTTPLatency
              expr: |
                histogram_quantile(0.95,
                  sum(rate(http.server.request.duration_bucket{service.name="xplane-image-gallery"}[5m])) by (vmrange, http.route)
                ) > 1.0
              for: 5m
              labels:
                severity: warning
                service: image-gallery
              annotations:
                summary: "High HTTP latency on route {{ $labels.http_route }}"
                description: |
                  95th percentile latency is {{ $value }}s on route {{ $labels.http_route }}.
                  Expected latency is below 1 second.
        - name: availability
          interval: 30s
          rules:
            # Reads kube-state-metrics, not the app's own telemetry, so it still
            # fires when no replica is left to emit anything. `critical` because
            # RunLore's trigger policy only investigates critical alerts.
            - alert: ImageGalleryUnavailable
              expr: |
                kube_deployment_status_replicas_available{namespace="apps",deployment="xplane-image-gallery"} == 0
              for: 2m
              labels:
                severity: critical
                service: image-gallery
              annotations:
                summary: "image-gallery has no available replicas"
                description: |
                  The xplane-image-gallery Deployment reports 0 of {{ $labels.deployment }}'s
                  desired replicas as available — users are served nothing at all.
                  Frequent causes: a Secret or ConfigMap the pod mounts has gone missing
                  (pods sit in CreateContainerConfigError), the image cannot be pulled, or
                  the CloudNativePG cluster behind DATABASE_URL is refusing connections.

  # Optional non-infrastructure overrides from OpenBao's `apps/` mount
  # (ADR-0033 Stage 2). `remoteRef` drops the `apps/` prefix: the store carries the mount.
  externalSecrets:
    - name: image-gallery-app-config
      remoteRef: image-gallery/config
      store: openbao-apps
  envFrom:
    - secretRef:
        name: image-gallery-app-config
        optional: true

  route:
    enabled: true
    hostname: "image-gallery"

  # Default-deny. The composition adds the DNS (with the L7 rule), CNPG, Valkey
  # and object-store egress itself for the enabled backends (plan ruling 1);
  # listed here is only what it cannot know. The gcp-0 patch appends the GKE
  # metadata server.
  networkPolicies:
    enabled: true
    ingress:
      - fromEntities:
          - ingress
        toPorts:
          - ports:
              - port: "8080"
                protocol: TCP
      # The in-cluster load generator (apps/base/complete/loadgen.yaml)
      - fromEndpoints:
          - matchLabels:
              "app.kubernetes.io/name": "image-gallery-loadgen"
        toPorts:
          - ports:
              - port: "8080"
                protocol: TCP
    egress:
      - toEndpoints:
          - matchLabels:
              "io.kubernetes.pod.namespace": "observability"
              "app.kubernetes.io/name": "vmsingle"
        toPorts:
          - ports:
              - port: "8428"
                protocol: TCP
      - toEndpoints:
          - matchLabels:
              "io.kubernetes.pod.namespace": "observability"
              "app.kubernetes.io/name": "vt-single"
        toPorts:
          - ports:
              - port: "10428"
                protocol: TCP

  objectStore:
    enabled: true
    permissions: readwrite
    versioning: true
    retentionDays: 90

  kvStore:
    enabled: true
    size: small
    type: valkey

  sqlInstance:
    enabled: true
    size: small
    storageSize: 20Gi
    instances: 2
    primaryUpdateStrategy: unsupervised
    createSuperuser: false
    # Production-safe defaults (sampleRate 0.2, minDuration 1000 ms, no statement logging).
    performanceInsights:
      enabled: true
    roles:
      - name: image-gallery-app
        comment: "Application user for image-gallery"
        superuser: false
        inRoles:
          - pg_monitor
    databases:
      - name: image-gallery
        owner: image-gallery-app
    atlasSchema:
      url: "https://github.com/Smana/image-gallery.git"
      ref: "v2.0.0" # migration 004: processing status + demo_controls
      path: "internal/platform/database/migrations"
    backup:
      # SIX-field cron, seconds first -- CNPG uses robfig/cron, not Kubernetes
      # CronJob syntax. Full explanation: security/base/zitadel/sqlinstance.yaml
      schedule: "0 0 2 * * *"
      bucketName: "${region}-ogenki-cnpg-backups" # gcp-0 patches this to ${project_id}-
      retentionPolicy: "30d"
```

If Task 16's soak had to lower the ratio, set `samplingRate` to the measured value, and say so in the comment.

- [ ] **Step 2: Add the aws-0 storage patch.** Append to `apps/aws-0/kustomization.yaml`:

```yaml

# image-gallery's object storage on aws-0: S3 through EKS Pod Identity. Explicit
# values, not a ${var} whose shape differs per cloud: CI renders both clusters
# with AWS-shaped fixtures and could not catch a GCP-shaped value.
patches:
  - target:
      group: cloud.ogenki.io
      kind: App
      name: xplane-image-gallery
    patch: |-
      - op: add
        path: /spec/env/-
        value: {name: STORAGE_PROVIDER, value: s3}
      - op: add
        path: /spec/env/-
        value: {name: STORAGE_ENDPOINT, value: s3.eu-west-3.amazonaws.com}
      - op: add
        path: /spec/env/-
        value: {name: STORAGE_BUCKET, value: eu-west-3-ogenki-xplane-image-gallery}
      - op: add
        path: /spec/env/-
        value: {name: STORAGE_REGION, value: eu-west-3}
      - op: add
        path: /spec/env/-
        value: {name: STORAGE_USE_SSL, value: "true"}
      - op: add
        path: /spec/env/-
        value: {name: OTEL_RESOURCE_ATTRIBUTES, value: cloud.provider=aws}
```

- [ ] **Step 3: Include the base on gcp-0, with its patch.** Replace `apps/gcp-0/kustomization.yaml` with:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

# Applications on gcp-0: the same four sets as aws-0, from the same shared
# directories. Only image-gallery (../base/complete) carries per-cloud values,
# in the patch below.
resources:
  - ../base/basic
  - ../base/complete
  - ../demo
  - ../platform

# ./llm is absent, and deliberately: apps/gcp-0/llm is applied by
# clusters/gcp-0-llm-platform/apps-llm.yaml under the suspended umbrella, so
# listing it here would apply the LLM platform's claims regardless of that
# suspend — exactly what keeping the umbrella a sibling of clusters/gcp-0/ was
# meant to prevent.

# image-gallery on gcp-0:
#   - GCS through GKE Workload Identity: the composition provisions the bucket
#     <projectID>-ogenki-<name> and a bucket-scoped identity; the app reads ADC.
#   - The GKE metadata server serves the Workload Identity token. On GKE, Cilium
#     does NOT classify 169.254.169.254 as the `host` entity (the composition's
#     auto rule), so it needs this toCIDR, the rule runlore runs live here
#     (observability/gcp-0/runlore/helmrelease.yaml).
#   - CNPG backups go to the project-prefixed bucket, as ZITADEL's do
#     (security/gcp-0/zitadel/kustomization.yaml): GCS bucket names are global.
patches:
  - target:
      group: cloud.ogenki.io
      kind: App
      name: xplane-image-gallery
    patch: |-
      - op: add
        path: /spec/env/-
        value: {name: STORAGE_PROVIDER, value: gcs}
      - op: add
        path: /spec/env/-
        value: {name: STORAGE_BUCKET, value: ogenki-435905-ogenki-xplane-image-gallery}
      - op: add
        path: /spec/env/-
        value: {name: STORAGE_REGION, value: europe-west4}
      - op: add
        path: /spec/env/-
        value: {name: OTEL_RESOURCE_ATTRIBUTES, value: cloud.provider=gcp}
      - op: add
        path: /spec/networkPolicies/egress/-
        value:
          toCIDR:
            - 169.254.169.254/32
          toPorts:
            - ports:
                - port: "80"
                  protocol: TCP
      - op: replace
        path: /spec/sqlInstance/backup/bucketName
        value: ${project_id}-ogenki-cnpg-backups
```

- [ ] **Step 4: Update the `clusters/gcp-0/apps.yaml` header.** Replace the first comment block (the lines from `# Applications on gcp-0` through `# reasoning is in apps/gcp-0/kustomization.yaml.`) with:

```yaml
# Applications on gcp-0 — podinfo, the basic App example, the App Wizard and
# image-gallery (GCS through Workload Identity; its per-cloud patch is in
# apps/gcp-0/kustomization.yaml).
#
# Same shape as clusters/aws-0/apps.yaml: same source, same shard, same
# dependsOn edge onto tooling, same App health expression. Only the path and
# the vars ConfigMap differ.
```

- [ ] **Step 5: Render both clusters and check the result.**

```bash
kubectl kustomize --load-restrictor LoadRestrictionsNone apps/gcp-0 > /tmp/claude-1000/ig-gcp.yaml
kubectl kustomize --load-restrictor LoadRestrictionsNone apps/aws-0 > /tmp/claude-1000/ig-aws.yaml
python3 - <<'EOF'
import yaml
for cluster, want in (("gcp", "gcs"), ("aws", "s3")):
    docs = [d for d in yaml.safe_load_all(open(f"/tmp/claude-1000/ig-{cluster}.yaml")) if d]
    app = [d for d in docs if d["kind"] == "App" and d["metadata"]["name"] == "xplane-image-gallery"][0]
    env = {e["name"]: e.get("value") for e in app["spec"]["env"]}
    assert env["STORAGE_PROVIDER"] == want, (cluster, env)
    assert env["OTEL_RESOURCE_ATTRIBUTES"] == f"cloud.provider={cluster}"
    assert app["spec"]["networkPolicies"]["enabled"] is True
    assert app["spec"]["sidecars"][0]["inheritEnv"] is True
    egress = app["spec"]["networkPolicies"]["egress"]
    has_md = any("169.254.169.254/32" in (r.get("toCIDR") or []) for r in egress)
    assert has_md == (cluster == "gcp"), (cluster, egress)
    bucket = app["spec"]["sqlInstance"]["backup"]["bucketName"]
    assert bucket == ("${project_id}-ogenki-cnpg-backups" if cluster == "gcp" else "${region}-ogenki-cnpg-backups"), bucket
    print(cluster, "OK")
EOF
```

Expected: `gcp OK` and `aws OK`.

- [ ] **Step 6: Run the gates.**

Run: `./scripts/validate-manifests.sh && python3 scripts/flux-schema/check-substitution.py`
Expected: `Invalid: 0, Skipped: 0` and exit 0. The App validates against the v0.7.0 schema. check-substitution confirms `project_id` exists in gcp-0's vars.

- [ ] **Step 7: Commit.**

```bash
git add apps/base/complete/app.yaml apps/aws-0/kustomization.yaml apps/gcp-0/kustomization.yaml clusters/gcp-0/apps.yaml
git commit -m "feat(apps): image-gallery v2 on both clouds, with a worker sidecar and default-deny policies" \
  -m "One shared claim: image 2.0.0 and migrations v2.0.0; a worker sidecar (inheritEnv, own probes on :8081); traces at 100 % sampling; the /metrics scrape off (OTLP push only); networkPolicies on; production performanceInsights. Per cluster: S3 + Pod Identity on aws-0; GCS + Workload Identity, the GKE metadata-server egress and the project-prefixed backup bucket on gcp-0. HighHTTPErrorRate follows the semconv rename."
```

### Task 19: The in-cluster load generator, the wrapper script, and the docs

**Files:**
- Create: `apps/base/complete/loadgen.yaml` and `scripts/demo-load.sh`.
- Modify: `apps/base/complete/kustomization.yaml`.
- Delete: `scripts/image-gallery-benchmark.sh`.
- Modify:
  - `website/content/docs/reference/commands.md`;
  - `website/content/docs/platform/foundations/cloud-support.md`;
  - `website/content/docs/get-started/_index.md`;
  - `website/content/docs/get-started/gcp/_index.md`;
  - `website/content/docs/platform/foundations/gcp.md`.

**Interfaces:**
- Consumes: `image-gallery loadgen` flags (Task 15), the app pods' label `app.kubernetes.io/name=xplane-image-gallery`, and the Service `xplane-image-gallery:8080` (composition).
- Produces: CronJob `apps/image-gallery-loadgen` (suspended), CiliumNetworkPolicy `apps/image-gallery-loadgen`, and `scripts/demo-load.sh <scenario> [duration] [rate]`.

- [ ] **Step 1: Create `apps/base/complete/loadgen.yaml`.**

```yaml
# In-cluster load generator for the image-gallery observability demo.
#
# SUSPENDED by default. When resumed it runs `steady` (1 req/s, the mixed API
# mix) for 14 minutes every 15 minutes, so dashboards always have data.
# On-demand runs of any scenario: scripts/demo-load.sh <scenario>.
#
# The image tag moves with the App's (apps/base/complete/app.yaml): same release, same API.
apiVersion: batch/v1
kind: CronJob
metadata:
  name: image-gallery-loadgen
  namespace: apps
  labels:
    app.kubernetes.io/name: image-gallery-loadgen
    app.kubernetes.io/part-of: image-gallery
spec:
  suspend: true
  schedule: "*/15 * * * *"
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 1
  failedJobsHistoryLimit: 3
  jobTemplate:
    spec:
      backoffLimit: 0
      ttlSecondsAfterFinished: 3600
      template:
        metadata:
          labels:
            app.kubernetes.io/name: image-gallery-loadgen
            app.kubernetes.io/part-of: image-gallery
        spec:
          restartPolicy: Never
          automountServiceAccountToken: false
          securityContext:
            runAsNonRoot: true
            runAsUser: 1001
            runAsGroup: 1001
            seccompProfile:
              type: RuntimeDefault
          containers:
            - name: loadgen
              image: ghcr.io/smana/image-gallery:2.0.0
              imagePullPolicy: IfNotPresent
              args:
                - loadgen
                - --target
                - http://xplane-image-gallery.apps.svc.cluster.local:8080
                - --scenario
                - steady
                - --duration
                - 14m
              env:
                - name: OTEL_SERVICE_NAME
                  value: image-gallery-loadgen
                - name: OTEL_TRACES_SAMPLER
                  value: always_on # the root of every trace it starts
                - name: OTEL_EXPORTER_OTLP_TRACES_ENDPOINT
                  value: http://victoria-traces-vt-single-server.observability.svc.cluster.local:10428/insert/opentelemetry/v1/traces
                - name: OTEL_EXPORTER_OTLP_METRICS_ENDPOINT
                  value: http://vmsingle-victoria-metrics-k8s-stack.observability.svc.cluster.local:8428/opentelemetry/v1/metrics
              resources:
                requests:
                  cpu: 100m
                  memory: 128Mi
                limits:
                  cpu: 500m
                  memory: 512Mi # in-memory image generation for uploads
              securityContext:
                allowPrivilegeEscalation: false
                readOnlyRootFilesystem: true
                runAsNonRoot: true
                capabilities:
                  drop: ["ALL"]
---
# Default-deny for the load generator: DNS, the app, and the two telemetry sinks.
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: image-gallery-loadgen
  namespace: apps
spec:
  endpointSelector:
    matchLabels:
      app.kubernetes.io/name: image-gallery-loadgen
  enableDefaultDeny:
    ingress: true
    egress: true
  egress:
    - toEndpoints:
        - matchLabels:
            k8s:io.kubernetes.pod.namespace: kube-system
            k8s:k8s-app: kube-dns
      toPorts:
        - ports:
            - port: "53"
              protocol: UDP
            - port: "53"
              protocol: TCP
    - toEndpoints:
        - matchLabels:
            app.kubernetes.io/name: xplane-image-gallery
      toPorts:
        - ports:
            - port: "8080"
              protocol: TCP
    - toEndpoints:
        - matchLabels:
            k8s:io.kubernetes.pod.namespace: observability
            app.kubernetes.io/name: vt-single
      toPorts:
        - ports:
            - port: "10428"
              protocol: TCP
    - toEndpoints:
        - matchLabels:
            k8s:io.kubernetes.pod.namespace: observability
            app.kubernetes.io/name: vmsingle
      toPorts:
        - ports:
            - port: "8428"
              protocol: TCP
```

Set `apps/base/complete/kustomization.yaml` `resources:` to `- app.yaml` and `- loadgen.yaml`.

- [ ] **Step 2: Create `scripts/demo-load.sh`** (`chmod +x`).

```bash
#!/usr/bin/env bash
# Run an image-gallery load-generator scenario in-cluster, from the suspended
# image-gallery-loadgen CronJob's template. The Job exports its traces and
# metrics like the app does, so each trace starts at the load generator.
#
#   scripts/demo-load.sh <browse|upload|mixed|steady|incident> [duration] [rate]
#   scripts/demo-load.sh incident          # ~10 min scripted incident; resets the demo controls on exit
#   scripts/demo-load.sh mixed 15m 25      # the soak: the 25 req/s cap for 15 minutes
set -euo pipefail

usage() { sed -n '2,8p' "$0"; }

scenario="${1:-}"
duration="${2:-15m}"
rate="${3:-10}"
case "$scenario" in
  browse | upload | mixed | steady | incident) ;;
  *) usage; exit 2 ;;
esac

ns=apps
name="image-gallery-loadgen-${scenario}-$(date +%s)"
kubectl create job "$name" -n "$ns" --from=cronjob/image-gallery-loadgen --dry-run=client -o json |
  jq --arg s "$scenario" --arg d "$duration" --arg r "$rate" '
    .spec.template.spec.containers[0].args = [
      "loadgen", "--target", "http://xplane-image-gallery.apps.svc.cluster.local:8080",
      "--scenario", $s, "--duration", $d, "--rate", $r, "--concurrency", "10"]' |
  kubectl apply -f -
echo "Started job/$name in $ns. Follow it with: kubectl logs -n $ns -f job/$name"
```

Run: `bash -n scripts/demo-load.sh && scripts/demo-load.sh bogus; echo "exit=$?"`
Expected: the usage text, then `exit=2`.

- [ ] **Step 3: Delete the old benchmark script.** `git rm scripts/image-gallery-benchmark.sh`.
- [ ] **Step 4: Update the docs, with this exact text.**
  - **`commands.md`:** delete the row `| `image-gallery-benchmark.sh` | Benchmarks the image-gallery demo path |`, and add in its place:

    `| `demo-load.sh` | Runs an image-gallery load-generator scenario in-cluster (`browse`, `upload`, `mixed`, `steady`, `incident`) from the suspended `image-gallery-loadgen` CronJob |`
  - **`cloud-support.md`:**
    - the Applications row becomes `| Applications | ✅ | ✅ podinfo · basic · App Wizard · image-gallery (GCS through Workload Identity) |`;
    - under "Genuinely not portable yet", delete the whole `- **`image-gallery`** — …` bullet (5 lines), and leave the Harbor bullet as the first one.
  - **`get-started/_index.md`:** replace

    ```text
    The two lanes are not equivalent in coverage. AWS runs the full platform; GCP
    runs everything except `image-gallery` (not yet portable — it hardcodes an AWS
    S3 endpoint) and `flux-previews` (excluded by design — previews belong to one
    cluster, not both). The exact split is on
    ```

    with

    ```text
    The two lanes are not equivalent in coverage. AWS runs the full platform; GCP
    runs everything except `flux-previews` (excluded by design — previews belong
    to one cluster, not both). The exact split is on
    ```

  - **`get-started/gcp/_index.md`:** replace

    ```text
    What it does **not** run: `image-gallery` (not yet portable) and `flux-previews`
    (excluded by design — previews belong to one cluster). The full comparison,
    ```

    with

    ```text
    What it does **not** run: `flux-previews` (excluded by design — previews belong
    to one cluster). The full comparison,
    ```

  - **`foundations/gcp.md`:** replace

    ```text
    applications included. What it leaves out is deliberate and per-component:
    `image-gallery` (the application itself speaks S3) and `flux-previews`
    (previews belong to one cluster by nature). The
    ```

    with

    ```text
    applications included. What it leaves out is deliberate: `flux-previews`
    (previews belong to one cluster by nature). The
    ```

- [ ] **Step 5: Run the gates.**

Run: `./scripts/validate-manifests.sh && ./scripts/validate-links.sh && ./scripts/validate-doc-claims.sh && grep -rn 'image-gallery-benchmark' --include='*.md' --include='*.sh' --include='*.yaml' . | grep -v -e docs/superpowers -e docs/specs`
Expected: `Invalid: 0, Skipped: 0`, both doc gates exit 0, and the grep prints nothing.
- If Polaris flags the CronJob, fix it as the message says. The existing `security/base/openbao-snapshot/snapshot-cronjob.yaml` is a passing reference.
- If `validate-doc-claims` fails on a changed page, update the claim's `must_contain` phrase to the new sentence in the same commit.

- [ ] **Step 6: Commit, push and open the PR.**

```bash
git add apps/base/complete/loadgen.yaml apps/base/complete/kustomization.yaml scripts/demo-load.sh website/content/docs
git commit -m "feat(apps): in-cluster image-gallery load generator, suspended by default" \
  -m "A suspended CronJob runs image-gallery loadgen (steady) with its own default-deny policy; scripts/demo-load.sh starts any scenario on demand. scripts/image-gallery-benchmark.sh is gone. The docs now list image-gallery as running on both clouds."
git push -u origin worktree-image-gallery-v2
gh pr create --base main --title "feat(apps): image-gallery v2 on both clouds — worker, load generator, default-deny" \
  --body-file <scratch body: link the spec and this plan; Tasks 18–19 summary; validate-manifests output; "live validation on gcp-0 follows in the verification doc before merge">
```

The body is English, with no attribution line.

### Task 20: Validate live on gcp-0 (OWNER GATES) and write the verification doc

Git steps that touch `test/gcp-only-live` run in a session in its worktree (`.claude/worktrees/test-gcp-only-live`). `kubectl` and the other checks can run from any session. The verification doc is written in this worktree. **Ask the owner before starting**: this deploys to the running gcp-0.

**Files:**
- Create: `docs/superpowers/specs/2026-09-11-image-gallery-v2-verification.md`.

- [ ] **Step 1: OWNER GATE: put the branches on the test branch.** In the test-branch worktree session:

```bash
git fetch origin chore/crossplane-configuration-v0.7.0 worktree-image-gallery-v2
git merge --no-ff origin/chore/crossplane-configuration-v0.7.0 -m "test: crossplane-configuration v0.7.0 on gcp-0"
git merge --no-ff origin/worktree-image-gallery-v2 -m "test: image-gallery v2 claim on gcp-0"
git push origin HEAD:test/gcp-only-live
flux reconcile source git flux-system && flux reconcile kustomization flux-system
```

(If the pin PR is already merged, fetch and merge `origin/main` instead of its branch.)

- [ ] **Step 2: Bring core up to v0.7.0.** Crossplane will not upgrade an installed dependency.

Run: `kubectl get configuration.pkg.crossplane.io`. If `crossplane-configuration-gcp` shows `HEALTHY=False` with `incompatible dependencies`, then **with owner approval** run:

```bash
kubectl patch configuration.pkg.crossplane.io smana-crossplane-configuration-core --type=merge \
  -p '{"spec":{"package":"ghcr.io/smana/crossplane-configuration-core:v0.7.0"}}'
```

Expected: both packages at `v0.7.0`, `HEALTHY=True`, and `kubectl get crd apps.cloud.ogenki.io -o json | jq '[.spec.versions[] | .schema.openAPIV3Schema.properties.spec.properties.sidecars.items.properties | has("inheritEnv")] | any'` printing `true`.

- [ ] **Step 3: Check the app config secret.** Run `kubectl get externalsecret -n apps image-gallery-app-config`. If it is not `SecretSynced` because the key is missing, stop and ask the owner. They seed `apps/image-gallery/config` with `{}` on the GCP lineage, using the Stage 2 procedure (`bao kv put apps/image-gallery/config -` through the `bao-env.sh` wrapper recorded in the Stage 2 verification doc). The token never appears in the output.
- [ ] **Step 4: Check that the resources are Ready.**

Run:

```bash
kubectl get app,sqlinstance,kvstore -n apps
kubectl get bucket.storage.gcp.m.upbound.io,gcpworkloadidentity -n apps
kubectl get atlasmigration -n apps
kubectl get pods -n apps -l app.kubernetes.io/name=xplane-image-gallery \
  -o custom-columns=NAME:.metadata.name,READY:.status.containerStatuses[*].ready
kubectl get pod -n apps -l app.kubernetes.io/name=xplane-image-gallery -o json \
  | jq '[.items[0].spec.containers[] | {name, liveness: (.livenessProbe != null), readiness: (.readinessProbe != null)}]'
```

Expected:
- the App shows `SYNCED=True READY=True`;
- the bucket and the identity are Ready, and the migration is applied;
- each pod shows `true,true` (2/2);
- both containers show `liveness: true, readiness: true` (criterion 2, probes).

- [ ] **Step 5: Criterion 1: an upload produces a thumbnail on GCS.**

Run `scripts/demo-load.sh upload 1m 2`, wait for the Job to finish, then:

```bash
curl -s https://image-gallery.priv.gcp.ogenki.io/api/images | jq '[.images[].status] | group_by(.) | map({(.[0]): length}) | add'
id=$(curl -s https://image-gallery.priv.gcp.ogenki.io/api/images | jq -r '.images[0].id')
curl -s -o /dev/null -w '%{http_code} %{content_type}\n' "https://image-gallery.priv.gcp.ogenki.io/api/images/$id/thumbnail"
gcloud storage ls gs://ogenki-435905-ogenki-xplane-image-gallery/thumbnails/ | head -3
```

Expected: the statuses are all `ready`; the thumbnail answers `200 image/…`; and the `thumbnails/` objects exist.

- [ ] **Step 6: Criterion 2: retry, then dead-letter.**

```bash
curl -s -X PUT https://image-gallery.priv.gcp.ogenki.io/api/settings/demo -H 'Content-Type: application/json' -d '{"worker_failure_probability":1}'
scripts/demo-load.sh upload 20s 1
sleep 20
vk=$(kubectl get pods -n apps -l app.kubernetes.io/instance=xplane-image-gallery-valkey -o name | head -1)
kubectl exec -n apps "$vk" -- valkey-cli XLEN image-gallery:jobs:dead
curl -s -X POST https://image-gallery.priv.gcp.ogenki.io/api/settings/demo/reset
```

Expected: `XLEN` ≥ 1; the affected images show `"status":"failed"`; and the `worker.jobs` series has `outcome="retry"` and `outcome="dead_letter"` points (Step 8's query).

- [ ] **Step 7: Criterion 3: one trace, with the logs by `trace_id`.**

```bash
kubectl -n observability port-forward svc/victoria-traces-vt-single-server 10428:10428 &
curl -s 'http://localhost:10428/select/jaeger/api/traces?service=image-gallery-loadgen&operation=loadgen%20upload&limit=20' \
  | jq '[.data[] | {id: .traceID, services: ([.processes[].serviceName] | unique)}
         | select(.services | index("xplane-image-gallery") and index("xplane-image-gallery-worker"))] | .[0]'
```

Expected: one trace whose services include `image-gallery-loadgen`, `xplane-image-gallery` and `xplane-image-gallery-worker`. Open it in Grafana (the VictoriaTraces datasource) and confirm the producer and consumer spans, the consumer's link, and the `sql`, Valkey and `storage.put` children.

Then query VictoriaLogs, through the `victorialogs` MCP or `vlogscli`, with `{kubernetes.pod_namespace="apps"} | unpack_json | log.trace_id:"<that id>" | limit 20`. Expected: lines from both the `xplane-image-gallery` and `worker` containers.

- [ ] **Step 8: Criterion 4: every contract name is in VictoriaMetrics.**

Query, through the `victoriametrics` MCP:

```text
count by (__name__) ({__name__=~"http\\.server\\.request\\.duration.*|http\\.server\\.active_requests|image\\.uploads|image\\.deletions|cache\\.lookups|settings\\.operations|storage\\..*|messaging\\..*|worker\\.jobs|queue\\.(depth|pending|lag)|image\\.processing\\.duration.*|demo\\.faults\\.injected|telemetry\\.spans\\..*|go\\.memory\\.used|go\\.goroutine\\.count", service.name=~"xplane-image-gallery.*"})
```

Expected: every contract metric is present. Confirm that `http.server.request.duration_count` exists: ruling 5's alert rewrite depends on it. If VictoriaMetrics names the count series differently, correct `HighHTTPErrorRate` in Task 18's claim and record it.

- [ ] **Step 9: Criteria 5 and 7: the soak at the cap, with no drops.**

Run `scripts/demo-load.sh mixed 15m 25`. During the run:

```bash
kubectl -n kube-system exec ds/cilium -c cilium-agent -- hubble observe --namespace apps --verdict DROPPED --since 15m
```

Expected: no dropped flows to or from the web, worker or load-generator pods. If metadata-server flows are dropped, record which rule matched, and fix the gcp-0 patch.

After the run:

```bash
kubectl get pods -n apps -l app.kubernetes.io/name=xplane-image-gallery -o json \
  | jq '[.items[].status.containerStatuses[] | {name, restarts: .restartCount, last: .lastState.terminated.reason}]'
```

Then query VictoriaMetrics:

```text
1 - sum(increase({__name__="telemetry.spans.exported",outcome="success",service.name=~"xplane-image-gallery.*"}[20m]))
  / sum(increase({__name__="telemetry.spans.ended",service.name=~"xplane-image-gallery.*"}[20m]))
```

Expected: no `OOMKilled`, and the ratio is below `0.001`. The load generator's own summary shows about 25 req/s with `shed` near 0.

- [ ] **Step 10: Criterion 6: each control and the incident.**
  - Run `scripts/demo-load.sh incident`, follow the Job's log, and confirm the five-phase timeline and `demo controls reset (all off)`.
  - Then, with `mixed` load running, set `slow_db_ms: 500` for 1 minute, then `worker_failure_probability: 0.5` for 1 minute, resetting after each.
  - Expected:
    - `count by (demo.fault) (increase({__name__="demo.faults.injected"}[30m]))` shows `latency`, `error`, `slow_db`, `worker_failure` and `worker_slowdown`;
    - a VictoriaTraces search for the tag `demo.fault` returns spans;
    - VictoriaLogs has `demo fault injected` lines;
    - `GET /api/settings/demo` shows every control at 0.

- [ ] **Step 11: Criteria 8 and 9.**
  - Criterion 8: cite the Task 2 `task check` output (`… match`, with the golden fixtures unchanged).
  - Criterion 9: run `test ! -e scripts/image-gallery-benchmark.sh && kubectl get cronjob -n apps image-gallery-loadgen -o jsonpath='{.spec.suspend}'`. Expected: `true`.
  - If aws-0 is down, record criterion 1 for AWS as **pending**, not claimed.
- [ ] **Step 12: Write the verification doc and commit it.** Create `docs/superpowers/specs/2026-09-11-image-gallery-v2-verification.md`:
  - a header linking the spec and this plan;
  - the date, cluster (gcp-0), versions (image 2.0.0, crossplane-configuration v0.7.0);
  - a table: criterion # | statement | verdict (PASS / PARTIAL / PENDING) | evidence (the command and the key output line from Steps 4–11);
  - a "Deviations and rulings" section: the ruling-5 check result, the metadata-server rule observed, and the soak rate if lowered.

  Then:

```bash
./scripts/validate-links.sh
git add docs/superpowers/specs/2026-09-11-image-gallery-v2-verification.md
git commit -m "docs(spec): image-gallery v2 verification on gcp-0"
git push
```

- [ ] **Step 13: OWNER GATE.** Hand both PRs (the pin, then the claim) to the owner to merge. The test branch stays unmerged.

## Spec coverage map

| Spec item | Tasks |
|---|---|
| D1 both clouds, GCS next to S3 | 7, 8, 18, 20 |
| D2 `loadgen` subcommand | 15, 19 |
| D3 async worker on Valkey streams | 10, 11, 13 |
| D5 Victoria-only: direct OTLP, head sampling | 5, 18 |
| D7 sidecar + composition fix | 1, 2, 3, 4, 18 |
| §2.1 storage (interface, providers, streaming, MinIO locally) | 7, 8 |
| §2.2 queue (stream, group, dead letter, XAUTOCLAIM, traceparent, PRODUCER/CONSUMER + link, retries, idempotency, graceful shutdown, health, metrics) | 10, 13 |
| §2.3 instrumentation (SDK/semconv, dot names, resource attributes, spans, redisotel, runtime, logs) | 5, 6, 8, 10, 11, 13 |
| §2.4 reliability (streaming, bounded queues + drop metric, GOMEMLIMIT, pool limits kept, 100 %) | 5, 7, 12, 13, 16, 20 |
| §2.5 demo controls | 9, 14 |
| §3 load generator (scenarios, open loop, output, telemetry, safety, in-cluster, clean-up) | 15, 19 |
| §4.1 composition fix and release | 1, 2, 3 |
| §4.2 claim (shared base, storage per cluster, worker, observability, network policies, performanceInsights, migrations, load generator) | 18, 19 |
| §4.3 rollout order | Phase order A → B → C → D |
| §5 testing | every task's tests; KCL 1–2; e2e 16; manifests 18–19; live 20 |
| Success criteria 1–9 | 20 (8 cites Task 2) |
| Risks: scrape / Pod Identity / GKE metadata / 100 % / three repos / stale clone / VictoriaTraces 0.x | rulings 2, 1; Task 8 keeps minio + MinIO tests; Tasks 18 + 20 hubble; Tasks 16 + 20 fallback; the execution table; Task 5's session note; nothing relies beyond OTLP ingest |
