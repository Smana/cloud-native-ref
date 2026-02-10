---
description: VictoriaLogs LogsQL syntax, Grafana dashboard best practices, and component time ranges
globs:
  - "observability/**"
  - "tooling/base/grafana*/**"
---

# Observability Rules

## VictoriaLogs / LogsQL Syntax

**CLI tool**: `vlogscli -datasource.url='https://vl.priv.cloud.ogenki.io/select/logsql/query'`

### Key Syntax Rules

1. **Kubernetes labels**: Use dot notation (`kubernetes.container_name`), NOT underscores
2. **JSON fields**: After `unpack_json`, fields are prefixed with `log.`
   - Correct: `{kubernetes.container_name="myapp"} | unpack_json | log.level:error`
   - Wrong: `{kubernetes_container_name="myapp"} | unpack_json | level:error`

### Field Structure After `unpack_json`

| Field | Description |
|-------|-------------|
| `log.level` | Severity (info, warn, error) |
| `log.service` | Application service name |
| `log.trace_id` | OpenTelemetry trace ID |
| `log.span_id` | OpenTelemetry span ID |
| `log.error` | Error message content |

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
