---
title: PostgreSQL
weight: 40
description: CloudNativePG's pg_stat_statements metrics, the Vector pipeline that parses auto_explain plans, and Barman Cloud plugin backups.
lastVerified: 2026-08-30
---

CloudNativePG itself is an infrastructure-layer component
(`infrastructure/base/cloudnative-pg*/`), not part of `observability/base/` —
but every `SQLInstance` claim it backs feeds the same VictoriaMetrics,
VictoriaLogs, and Grafana covered on the rest of this lane. This page is
that integration, re-verified against SPEC-010 (the Barman Cloud plugin
migration) rather than carried forward from the pre-migration draft.

## Metrics

CloudNativePG's built-in exporter surfaces `pg_stat_statements` as
Prometheus-format metrics, scraped like any other `VMServiceScrape` target.
Confirmed live metric names, pulled directly from the two Grafana dashboards
that query them:

- `cnpg_pg_stat_statements_calls`
- `cnpg_pg_stat_statements_mean_exec_time` / `_max_exec_time`
- `cnpg_pg_stat_statements_rows`
- `cnpg_pg_stat_statements_shared_blks_hit` / `_shared_blks_read`

(An earlier draft of this documentation used `_calls_total` and similar
`_total`-suffixed names — those don't match what the dashboards actually
query and have been dropped.)

Two dashboards, both in the `databases` Grafana folder
(`infrastructure/base/cloudnative-pg/`):

- **`databases-cnpg-query-performance`** — per-query mean execution time,
  call volume, cache-hit ratio, aggregated across `database`/`query_id`.
- **`databases-cnpg-query-plan-correlation`** — drills into one `query_id`:
  execution stats plus every `auto_explain` plan captured for it (see Logs
  below), with a button that copies the latest plan JSON to the clipboard
  and opens a private [PEV2](https://pev2.priv.aws.ogenki.io/) instance
  (Postgres Explain Visualizer 2) to paste it into.

{{< callout type="warning" >}}
The `postgresql.conf` parameters behind these metrics — `pg_stat_statements.track`,
`shared_preload_libraries`, `compute_query_id`, and the `auto_explain.*`
thresholds — are set by the `SQLInstance` composition itself, which lives in
[`Smana/crossplane-configuration`](https://github.com/Smana/crossplane-configuration),
not in this repo. The metric names above are verified live (they're queried
by dashboards that exist and render); the exact server-side settings that
produce them are not verifiable from this repository alone.
{{< /callout >}}

No CloudNativePG-specific `VMRule` is deployed anywhere in this repo —
`victoria-metrics-k8s-stack/vmrules/` holds rules for `karpenter`, `openbao`,
and `runlore` only. Connection-saturation, replication-lag, or
query-regression alerting for CloudNativePG doesn't exist yet.

## Logs: the auto_explain pipeline

`victoria-logs`'s Vector configuration (`observability/base/victoria-logs/helmrelease-vlsingle.yaml`)
carries a purpose-built pipeline, separate from general Kubernetes log
collection, that exists only to parse CloudNativePG's `auto_explain` output:

```
k8s (kubernetes_logs source)
  → parse_pg_json        (unwraps CloudNativePG's JSON log envelope)
  → filter_pg_auto_explain  (keeps only postgres containers, auto_explain lines)
  → parse_pg_auto_explain   (extracts plan JSON, query_id, timings)
  → sinks:
      victorialogs_pg_plans          (successfully parsed plans)
      victorialogs_pg_parse_failures (anything that failed to parse — kept, not dropped)
      vlogs-0                        (everything else, general k8s logs)
```

The plans sink streams on `cluster_name,namespace,database,query_id` and
keeps a fixed, small field set (`only_fields`); the parse-failures sink is
deliberately **not** dropped silently — it exists so a parsing regression
shows up as its own queryable stream instead of vanishing. Six Vector unit
tests ship alongside the config (valid plan, missing duration, malformed
JSON, non-Postgres filtering, and two more).

`query_id` is the correlation key end to end: it's a `pg_stat_statements`
label on the metrics side and a stream field here, which is what lets the
query-plan-correlation dashboard join "this query is slow" to "here are its
actual plans."

## Backups: Barman Cloud CNPG-I plugin

CloudNativePG's in-tree `barmanObjectStore` backup config was removed in
operator 1.31.0; this repo migrated to the Barman Cloud CNPG-I plugin model
ahead of that bump (SPEC-010, done). Confirmed live in
`infrastructure/base/cloudnative-pg-barman-plugin/`:

- A `barman-cloud` controller `Deployment`, installed via a Flux
  `Kustomization` sourcing the plugin's upstream `kubernetes/` overlay at a
  pinned tag (no Helm chart exists upstream) into the `infrastructure`
  namespace — co-located with the CNPG operator itself, since the plugin
  must share its namespace.
- Its own `CiliumNetworkPolicy` (`network-policy.yaml`): DNS with L7
  inspection, Kubernetes API access, S3 egress on 443, and the EKS Pod
  Identity Agent (`169.254.170.23:80`, classified as the `host` entity —
  `toCIDR` alone wouldn't match it).
- The `ObjectStore` CRD, backed by an S3 `Bucket` (`cnpg-backups`,
  `infrastructure/aws-0/cloudnative-pg/s3-bucket.yaml`) with
  `managementPolicies` deliberately excluding `Delete` — backups must
  outlive any individual cluster's teardown.

A claim's `SQLInstance` spec (`spec.backup.schedule`, `spec.backup.bucketName`,
`spec.objectStoreRecovery`) is unchanged by the migration; only the rendered
`Cluster`'s internals moved from `barmanObjectStore` to
`spec.plugins: [{name: barman-cloud.cloudnative-pg.io}]`. This is live on the
cluster today, not just shipped code — Zitadel's `SQLInstance`
(`security/base/zitadel/sqlinstance.yaml`) documents an actual
promotion/recovery cycle against it:

```yaml
objectStoreRecovery:
  bucketName: "eu-west-3-ogenki-cnpg-backups"
  path: "zitadel-20260829"          # frozen dated snapshot, not the live prefix
backup:
  schedule: "0 0 * * *"
  bucketName: "eu-west-3-ogenki-cnpg-backups"
```

Recovery deliberately reads from a **frozen, dated snapshot prefix**
(`zitadel-20260719`), not the live cluster's own accruing backup prefix — a
bad day on the live database (corruption, an accidental `DROP`) can't
cascade into a poisoned recovery source, at the cost of manually promoting a
new snapshot when the schema or data changes meaningfully. Credentials
default to EKS Pod Identity: per SPEC-010's refined credential-mechanism
clarification (`docs/specs/done/2026-Q3/010-cnpg-barman-cloud-plugin/clarifications.md:125`),
the rendered `ObjectStore` sets `s3Credentials.inheritFromIAMRole: true` — a
verbatim carry-over of the pre-migration in-tree config — rather than
omitting the block; ambient credentials still come from Pod Identity via the
AWS SDK default chain, and no new Kubernetes Secret is created. A claim can
opt into access-key credentials sourced from OpenBao via `ExternalSecret`
instead, but that's not the default path.
