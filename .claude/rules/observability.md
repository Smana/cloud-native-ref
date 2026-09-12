---
description: VictoriaLogs LogsQL syntax, Grafana dashboard best practices, and component time ranges
globs:
  - "observability/**"
  - "tooling/base/grafana*/**"
---

# Observability Rules

## VictoriaLogs / LogsQL Syntax

**CLI tool**: `vlogscli -datasource.url='https://vl.priv.aws.ogenki.io/select/logsql/query'`

### Key Syntax Rules

1. **Kubernetes labels**: Use dot notation (`kubernetes.container_name`), NOT underscores
2. **JSON fields**: After `unpack_json`, fields are prefixed with `log.`
   - Correct: `{kubernetes.container_name="myapp"} | unpack_json | log.level:error`
   - Wrong: `{kubernetes_container_name="myapp"} | unpack_json | level:error`

### Field Structure After `unpack_json`

| Field | Description |
|-------|-------------|
| `log.level` | Severity (info, warn, error) |
| `log.service.name` | Application service name |
| `log.service.version` | Application version |
| `log.deployment.environment.name` | Environment the workload runs in |
| `log.trace_id` | OpenTelemetry trace ID |
| `log.span_id` | OpenTelemetry span ID |
| `log.error` | Error message content |

> **`log.service` was renamed to `log.service.name`** — do not query the old name.
> image-gallery 2.0.0 moved its structured log keys onto semconv
> (`internal/observability/logger.go`: `service.name`, `service.version`,
> `deployment.environment.name`), so a query or panel keyed on `log.service` matches
> nothing once that image is deployed. Apps still on the old key emit `log.service`;
> both may be present while a rollout is in flight.
>
> These names contain dots, which LogsQL treats as path separators after
> `unpack_json` — a bare `log.service.name:x` may need quoting. The exact form is
> **unverified against a live VictoriaLogs instance**; check it with `vlogscli`
> before relying on it in a dashboard, rather than trusting this line.

### Example Queries

```bash
# Error logs for a container
echo '{kubernetes.container_name="myapp"} | unpack_json | log.level:error | limit 10' | vlogscli ...

# Logs with trace context
echo '{kubernetes.container_name="myapp"} | unpack_json | log.trace_id:* | limit 10' | vlogscli ...

# All logs for a namespace
echo '{kubernetes.pod_namespace="apps"} | limit 10' | vlogscli ...
```

### Grafana Variables

Use same syntax with Grafana variables (no quotes): `{kubernetes.container_name=$service} | unpack_json | log.level:error`

## Grafana Dashboard Best Practices

### Datasource Configuration
- Logs panels MUST use `victoriametrics-logs-datasource`, NEVER prometheus/metrics datasource
- Use `$${variable}` (double dollar) in dashboard JSON to preserve Grafana variables after Flux postBuild

### Troubleshooting "No Data"

**Always check data exists first** before investigating infrastructure:
1. Query VictoriaLogs/VictoriaMetrics with wider time range (6h/24h)
2. Consider data generation patterns (continuous vs event-driven)

### Component Time Ranges

| Component | Pattern | Default |
|-----------|---------|---------|
| Karpenter | Event-driven | 6-12h |
| Application pods | Continuous | 1h |
| Flux controllers | Event-driven | 3h |
| Cert-manager | Event-driven | 6h |
