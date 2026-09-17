# Observability — VictoriaLogs, VictoriaMetrics, Grafana

Metrics go to VictoriaMetrics via `ServiceMonitor` / `VMServiceScrape`. Logs go to VictoriaLogs as
structured JSON. Every pod carries liveness and readiness probes.

## LogsQL

```bash
vlogscli -datasource.url='https://vl.priv.aws.ogenki.io/select/logsql/query'
```

Two rules account for most broken queries:

1. **Kubernetes labels use dot notation** — `kubernetes.container_name`, never underscores.
2. **After `unpack_json`, fields are prefixed `log.`**

```
{kubernetes.container_name="myapp"} | unpack_json | log.level:error | limit 10   # correct
{kubernetes_container_name="myapp"} | unpack_json | level:error                  # matches nothing
```

| Field | Holds |
|---|---|
| `log.level` | severity — info, warn, error |
| `log.service.name` | application service name |
| `log.service.version` | application version |
| `log.deployment.environment.name` | environment the workload runs in |
| `log.trace_id`, `log.span_id` | OpenTelemetry correlation |
| `log.error` | error message content |

**`log.service` was renamed to `log.service.name`.** image-gallery 2.0.0 moved its structured log
keys onto semconv (`internal/observability/logger.go`), so a query or panel keyed on the old name
matches nothing once that image is deployed. Apps still on the old key emit `log.service`; both may
be present mid-rollout.

These names contain dots, which LogsQL treats as path separators after `unpack_json`, so a bare
`log.service.name:x` may need quoting. **The exact form is unverified against a live instance** —
check it with `vlogscli` before relying on it in a dashboard rather than trusting this line.

In Grafana, the same syntax takes variables unquoted:
`{kubernetes.container_name=$service} | unpack_json | log.level:error`

## Grafana dashboards

- Logs panels must use `victoriametrics-logs-datasource`. Never a prometheus/metrics datasource.
- Use `$${variable}` — **double dollar** — in dashboard JSON so the variable survives Flux
  `postBuild` substitution.
- Headlamp's prometheus plugin needs the `headlamp-prometheus=true` opt-in label, which
  VictoriaMetrics never sets on its own.

## "No data"

Confirm the data exists before suspecting infrastructure: query over a wider range (6h/24h) and
consider whether the source is continuous or event-driven.

| Component | Pattern | Range to try |
|---|---|---|
| Karpenter | event-driven | 6–12h |
| Application pods | continuous | 1h |
| Flux controllers | event-driven | 3h |
| cert-manager | event-driven | 6h |

## Alerting rules

`./scripts/validate-vmrules.sh` runs `promtool check rules` over every repo-authored `VMRule`.
Nothing else parses an `expr`: to `flux schema validate` it is just a string in the right place,
and Polaris never reads rules at all. An unbalanced paren or an unknown function used to validate
clean and cost you the alert at runtime — vmalert logs a parse error, the group never evaluates,
and **the alert silently never fires**.

A group is checked when its `type` is unset, empty, or `prometheus`. Today that skips exactly one
group — `loggen` in `base/loggen/demo-vmrule.yaml`, whose `type: vlogs` expressions are LogsQL —
and it **must not be made to pass**. Rules written inline in a HelmRelease `values:` block are
repo-authored but not seen by the script; there are none today.

PromQL is a subset of MetricsQL, so this gate can in principle reject a valid expression. Nothing
relies on MetricsQL-only syntax today. When someone hits it, the fix is not to delete the gate:
rewrite in PromQL, or isolate the rule in its own group with a `type` the script skips, so the hole
is visible.
