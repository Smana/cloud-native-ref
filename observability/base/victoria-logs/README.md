# VictoriaLogs with Vector - PostgreSQL Query Plan History

## Overview

This directory contains the VictoriaLogs Helm configuration with embedded Vector for log processing. The primary use case is capturing and indexing PostgreSQL execution plans from CloudNativePG clusters for performance analysis.

### Architecture

```
PostgreSQL (CloudNativePG)
  ↓ JSON logs with auto_explain
Vector (VictoriaLogs pod)
  ├─ Parse PostgreSQL JSON logs
  ├─ Extract execution plans
  ├─ Route to VictoriaLogs
  └─ Route failures to separate stream
VictoriaLogs
  ├─ Query plans (indexed by query_id)
  └─ Parse failures (for debugging)
Grafana
  ↓ Query via VictoriaLogs datasource
User (Query Plan Correlation Dashboard)
```

## Components

### 1. Vector Configuration

**File**: `helmrelease-vlsingle.yaml` (`.spec.values.vector.customConfig`)

**Pipeline Stages**:

1. **parse_pg_json**: Parse PostgreSQL JSON-formatted logs from CloudNativePG
2. **filter_pg_auto_explain**: Filter for logs containing execution plans
3. **parse_pg_auto_explain**: Extract plan JSON, metadata, and timing information
4. **parser**: Handle other (non-PostgreSQL) Kubernetes logs

**Sinks**:

- `victorialogs_pg_plans`: Successfully parsed execution plans
- `victorialogs_pg_parse_failures`: Events that failed parsing (for debugging)
- `vlogs-0`: All other Kubernetes logs

### 2. PostgreSQL Log Structure

CloudNativePG formats PostgreSQL logs as JSON:

```json
{
  "timestamp": "2025-01-14 10:30:45.123 UTC",
  "record": {
    "query_id": "1234567890",
    "database_name": "mydb",
    "user_name": "appuser",
    "message": "duration: 150.5 ms  plan: {\"Query Text\":\"SELECT ...\",\"Plan\":{...}}"
  }
}
```

auto_explain embeds JSON plans in the `message` field:

```
duration: 150.5 ms  plan: {"Query Text":"...", "Plan":{...}, "Planning Time":1.2, "Execution Time":149.3}
```

### 3. Extracted Fields

Vector extracts and stores:

| Field | Source | Description |
|-------|--------|-------------|
| `query_id` | `record.query_id` | Correlates with pg_stat_statements |
| `cluster_name` | `pod_labels.cnpg.io/cluster` | PostgreSQL cluster name |
| `namespace` | `namespace_name` | Kubernetes namespace |
| `pod_name` | `pod_name` | PostgreSQL pod name |
| `database` | `record.database_name` | Database name |
| `user` | `record.user_name` | PostgreSQL user |
| `duration_ms` | Regex from message | Total query duration |
| `plan_json` | Parsed from message | Execution plan tree |
| `query_text` | `Plan["Query Text"]` | SQL query |
| `planning_time_ms` | `Plan["Planning Time"]` | Query planning time |
| `execution_time_ms` | `Plan["Execution Time"]` | Query execution time |

## Testing

### Prerequisites

- `yq` (>= v4): https://github.com/mikefarah/yq
- `docker`: For running Vector validation

### Local Testing

Run the test script:

```bash
# Run all checks (validation + unit tests)
./scripts/test-vector-vrl.sh

# Only validate configuration syntax
./scripts/test-vector-vrl.sh --validate-only

# Only run unit tests
./scripts/test-vector-vrl.sh --test-only

# Show test coverage details
./scripts/test-vector-vrl.sh --show-tests

# Create sample logs for manual testing
./scripts/test-vector-vrl.sh --create-samples
```

### CI/CD Validation

The GitHub Actions workflow `.github/workflows/vector-config-validation.yml` automatically:

1. Extracts Vector configuration from HelmRelease
2. Validates syntax with `vector validate`
3. Runs all unit tests with `vector test`
4. Reports results in PR comments

**Triggers**:
- Pull requests touching `observability/base/victoria-logs/*.yaml`
- Pushes to `main` or `feat_*` branches

### Test Coverage

Six comprehensive test cases validate:

1. **Valid plan with all fields**: Ensures complete parsing of well-formed logs
2. **Missing duration field**: Tests graceful degradation when duration is absent
3. **Optional timing fields**: Validates handling of missing Planning/Execution Time
4. **Malformed JSON**: Confirms error routing to `.dropped` output
5. **Non-PostgreSQL logs**: Verifies filtering works correctly
6. **PostgreSQL logs without plans**: Tests that non-auto_explain logs are filtered

### Manual VRL Testing

Use the [VRL Playground](https://playground.vrl.dev/) for interactive testing:

1. Create sample log (see `scripts/test-vector-vrl.sh --create-samples`)
2. Copy VRL code from `parse_pg_auto_explain` transform
3. Paste both into VRL Playground
4. Test and debug transformations

## Querying VictoriaLogs

### Successful Plans

```logsql
# All plans for a specific query_id
_stream: {query_id="1234567890"}

# Plans from a specific cluster
_stream: {cluster_name="prod-cluster"}

# Slow queries (duration > 1 second)
_stream: {cluster_name="prod-cluster"} | duration_ms > 1000 | sort by duration_ms desc

# Plans for a specific database
_stream: {database="myapp"}

# Recent plans (last hour)
_stream: {cluster_name="prod-cluster"} | _time:1h
```

### Parse Failures (Debugging)

```logsql
# All parsing failures
{kubernetes.container_name="postgres", metadata.dropped.component="*"}

# Failures for a specific cluster
{kubernetes.pod_name:*test-cluster*, metadata.dropped.component="*"}

# Recent failures
{metadata.dropped.component="*"} | _time:24h
```

## Troubleshooting

### No Plans Appearing in VictoriaLogs

**Check**:

1. **Is auto_explain enabled?**
   ```bash
   kubectl exec -n databases <pod> -- psql -U postgres -c "SHOW auto_explain.log_min_duration"
   ```
   Should show a value >= 0 (not -1)

2. **Are queries slow enough?**
   - Default threshold: 1000ms
   - Check `performanceInsights.explain.minDuration` in SQLInstance spec

3. **Is Vector running?**
   ```bash
   kubectl get pods -n observability -l app.kubernetes.io/name=victoria-logs-single-server-vector
   kubectl logs -n observability <vector-pod> | grep -i error
   ```

4. **Check Vector metrics**:
   ```bash
   kubectl port-forward -n observability svc/victoria-logs-victoria-logs-single-server 9090:9090
   # Visit http://localhost:9090/metrics
   # Look for: component_errors_total{component_name="parse_pg_auto_explain"}
   ```

### High Parse Failure Rate

**Check failures stream**:

```logsql
{metadata.dropped.component="pg_auto_explain_parser"} | _time:1h
```

**Common causes**:

- **Malformed JSON**: PostgreSQL log output changed
- **Missing fields**: CloudNativePG version incompatibility
- **Unexpected format**: Custom PostgreSQL logging configuration

**Debug steps**:

1. Get raw PostgreSQL logs:
   ```bash
   kubectl logs -n databases <cnpg-pod> -c postgres | grep "plan:" | head -1
   ```

2. Test in VRL Playground with actual log data

3. Check CloudNativePG version:
   ```bash
   kubectl get pods -n infrastructure -l app.kubernetes.io/name=cloudnative-pg
   ```

### Performance Impact

**Vector Metrics to Monitor**:

- `component_received_events_total`: Total events processed
- `component_sent_events_total`: Successfully sent events
- `component_discarded_events_total`: Dropped events
- `component_errors_total`: Processing errors

**Expected Overhead**:

- **CPU**: ~5-10% per Vector pod
- **Memory**: ~100-200MB per Vector pod
- **Network**: Minimal (only plan logs, not all PostgreSQL logs)

**Optimization**:

- Increase `auto_explain.sample_rate` in production (0.1-0.2)
- Increase `auto_explain.log_min_duration` (1000ms+)
- Adjust Vector batch sizes if needed

## Configuration Updates

### Changing Sample Rate or Threshold

Update the SQLInstance or App spec:

```yaml
performanceInsights:
  enabled: true
  explain:
    sampleRate: 0.5      # 50% of slow queries
    minDuration: 2000    # Only queries > 2 seconds
```

### Adding Custom Fields

Edit `helmrelease-vlsingle.yaml`:

1. Add field extraction in `parse_pg_auto_explain` transform
2. Add field to `victorialogs_pg_plans` sink `only_fields` list
3. Run validation: `./scripts/test-vector-vrl.sh --validate-only`
4. Add test case for new field
5. Run tests: `./scripts/test-vector-vrl.sh`

### Debugging New VRL Code

1. Use structured logging:
   ```vrl
   log({
     "level": "debug",
     "component": "my_transform",
     "field": .my_field,
     "message": "Debug info"
   }, level: "debug")
   ```

2. Check Vector logs:
   ```bash
   kubectl logs -n observability <vector-pod> | grep my_transform
   ```

## Future-Proofing

### Migrating to RDS or Other PostgreSQL

The configuration is named `pg` (not `cnpg`) to support future migration:

**Current**: CloudNativePG with JSON logs

**Future RDS**: Would need:
1. Update `parse_pg_json` to handle RDS log format
2. Update field extraction (RDS uses different JSON structure)
3. Keep sinks and downstream queries unchanged

**Migration Path**:

1. Deploy new `parse_rds_json` transform
2. Route both CNPG and RDS logs to same sinks
3. Gradually migrate databases
4. Remove `parse_pg_json` when migration complete

### Adding More Sinks

The `reroute_dropped` pattern enables:

- Sending failures to alerting systems
- Storing failures in S3 for replay
- Routing to different VictoriaLogs instances

Example - add Slack notifications for failures:

```yaml
sinks:
  slack_parse_failures:
    type: http
    inputs:
      - parse_pg_auto_explain.dropped
    uri: https://hooks.slack.com/services/YOUR/WEBHOOK/URL
    encoding:
      codec: json
```

## Resources

- **Vector Documentation**: https://vector.dev/docs/
- **VRL Reference**: https://vector.dev/docs/reference/vrl/
- **VRL Playground**: https://playground.vrl.dev/
- **VictoriaLogs**: https://docs.victoriametrics.com/victorialogs/
- **CloudNativePG**: https://cloudnative-pg.io/

## Support

For issues or questions:

1. Check test results: `./scripts/test-vector-vrl.sh`
2. Review Vector logs: `kubectl logs -n observability <vector-pod>`
3. Check failures stream: `{metadata.dropped.component="*"}` in VictoriaLogs
4. Validate configuration: `.github/workflows/vector-config-validation.yml`
