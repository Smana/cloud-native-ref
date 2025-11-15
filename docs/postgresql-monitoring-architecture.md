# CloudNativePG Monitoring Architecture

## Overview

Comprehensive PostgreSQL monitoring stack for CloudNativePG clusters using VictoriaMetrics, VictoriaLogs, and Grafana. This architecture enables complete observability of database performance, query patterns, and execution plans.

## Architecture Components

### 1. Data Collection Layer

#### CloudNativePG Metrics (via PostgreSQL Exporter)
- **pg_stat_statements**: Query execution statistics
  - Metrics: `cnpg_pg_stat_statements_calls_total`, `cnpg_pg_stat_statements_mean_exec_time_seconds`
  - Labels: `cluster`, `database`, `queryid`, `user`
  - Correlation key: `queryid` (PostgreSQL Query Identifier)

- **CNPG Cluster Health**: Cluster status, replication lag, WAL metrics
  - Metrics: `cnpg_collector_up`, `cnpg_pg_replication_lag_seconds`, `cnpg_pg_wal_files_count`

- **Database Statistics**: Connection counts, transaction rates, tuple operations
  - Metrics: `cnpg_pg_database_numbackends`, `cnpg_pg_database_xact_commit_total`

#### Auto Explain Logs (via Vector VRL)
- **Query Plans**: Full execution plans in JSON format
  - Stored in: VictoriaLogs (`victorialogs_pg_plans` stream)
  - Stream fields (indexed): `cluster_name`, `namespace`, `database`, `query_id`
  - Plan fields: `plan_json` (full JSON), `query_text`, `planning_time_ms`, `execution_time_ms`, `duration_ms`
  - Correlation key: `query_id` (matches pg_stat_statements `queryid`)
  - Parse failures: Routed to separate `victorialogs_pg_parse_failures` stream for debugging
  - Configuration: `observability/base/victoria-logs/helmrelease-vlsingle.yaml` (Vector customConfig)

#### Application Logs
- **Structured logging**: JSON format with trace context
  - Fields: `level`, `service`, `trace_id`, `span_id`, `error`
  - Correlation: `trace_id` links application traces to database queries

### 2. Storage Layer

#### VictoriaMetrics
- **Retention**: 90 days (configurable via retention period)
- **Cardinality**: ~10K active series per cluster
- **Query performance**: Sub-second query times with MetricsQL
- **Use cases**:
  - Time-series metrics from pg_stat_statements
  - Cluster health monitoring
  - Resource utilization tracking

#### VictoriaLogs
- **Retention**: 30 days (configurable)
- **Cardinality**: Low-cardinality stream fields for efficient indexing
- **Query language**: LogsQL with full-text search and JSON parsing
- **Use cases**:
  - Query plan history and analysis
  - Full-text search in query text
  - Correlation with metrics via query_id

### 3. Correlation Layer

The **Query Identifier** (`compute_query_id=on`) is the correlation key that links:
1. **pg_stat_statements metrics** (VictoriaMetrics) → `queryid` label
2. **auto_explain logs** (VictoriaLogs) → `query_id` field
3. **Application traces** (future: OpenTelemetry) → database span attributes

```
┌─────────────────────────────────────────────────────────────────┐
│                     Query Correlation Flow                      │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  Application          PostgreSQL           Metrics & Logs      │
│  ┌─────────┐         ┌──────────┐         ┌───────────────┐   │
│  │         │  SQL    │          │         │ pg_stat       │   │
│  │  App    ├────────>│ Postgres │────────>│ _statements   │   │
│  │ (trace) │         │          │         │               │   │
│  └─────────┘         └────┬─────┘         │ queryid: 123  │   │
│      │                    │               └───────────────┘   │
│      │                    │ auto_explain                      │
│      │                    │                                   │
│      │                    ▼                                   │
│      │               ┌──────────┐         ┌───────────────┐  │
│      │               │ Log:     │         │ VictoriaLogs  │  │
│      │               │ plan {...}────────>│               │  │
│      │               └──────────┘         │ query_id: 123 │  │
│      │                                    └───────────────┘  │
│      │                                                       │
│      └──────────────────────────────────────────────────────┘│
│                Correlated by Query ID: 123                    │
└─────────────────────────────────────────────────────────────────┘
```

## PostgreSQL Configuration Parameters

### Performance Insights Configuration
```yaml
# Applied when performanceInsights.enabled: true

# Auto Explain - Captures execution plans for slow queries
auto_explain.log_min_duration: 1000ms     # Log queries slower than 1s (default: production-safe)
auto_explain.log_analyze: on              # Include actual execution times
auto_explain.log_buffers: on              # Include buffer usage stats
auto_explain.log_format: json             # JSON format for parsing
auto_explain.log_nested_statements: on    # Include nested queries
auto_explain.log_timing: off              # Disable per-node timing (reduces overhead)
auto_explain.log_triggers: on             # Include trigger execution time
auto_explain.sample_rate: 0.2             # Sample 20% of slow queries (default: production-safe)
                                          # Set to 1.0 for debugging (100%)
                                          # Set to 0.1 for high-traffic (10%)

# Query Statistics Tracking
pg_stat_statements.track: all             # Track all queries
pg_stat_statements.max: 10000             # Store up to 10k queries
compute_query_id: on                      # Generate Query Identifier

# Query Statement Logging (optional, configurable)
log_statement: none                       # Log statement types (none|ddl|mod|all)
                                          # none: No statement logging (default)
                                          # ddl: Log DDL statements (CREATE, ALTER, DROP)
                                          # mod: Log DDL + data modifications (INSERT, UPDATE, DELETE)
                                          # all: Log all SQL statements (HIGH OVERHEAD!)
```

### Performance Considerations
- **Default configuration overhead**: ~5-7% CPU, ~280MB memory (production-safe)
  - `sample_rate: 0.2` (20% sampling)
  - `log_min_duration: 1000ms` (queries > 1s)
  - `log_statement: none` (no statement logging)
- **auto_explain overhead**: ~5-10% for logged queries (only slow queries captured)
- **pg_stat_statements overhead**: <1% overall (all queries tracked)
- **log_statement overhead**: Depends on setting
  - `none`: 0% (no statement logging, default)
  - `ddl`: <1% (DDL statements are rare)
  - `mod`: 1-5% (depends on write workload)
  - `all`: 10-30% (HIGH! Logs every query, very verbose)
- **Threshold tuning**: Adjust `log_min_duration` based on workload
  - Production (default): 1000ms (queries > 1s)
  - Staging/Testing: 500ms
  - Development: 100ms or 0 (all queries)
  - High-traffic production: 3000ms+ (only very slow queries)
- **Sample rate tuning**: Adjust `sample_rate` based on traffic
  - Production (default): 0.2 (20% sampling)
  - High-traffic production: 0.1 (10% sampling)
  - Development/Debugging: 1.0 (100%, capture everything)
- **Statement logging**: Use `log_statement` carefully
  - Production (default): `none` (rely on auto_explain for slow queries)
  - Staging: `ddl` or `mod` (audit schema/data changes)
  - Development: `all` (for debugging, accepts high overhead)

## Monitoring Stack Features

### Real-Time Monitoring
1. **Active Queries**: Current running queries with execution time
2. **Query Performance**: Top N slowest queries by mean execution time
3. **Cluster Health**: Replication lag, connection counts, transaction rates
4. **Resource Utilization**: CPU, memory, disk I/O per database

### Historical Analysis
1. **Query Trends**: Performance degradation over time
2. **Plan Changes**: Detect when query plans change
3. **Slow Query Patterns**: Identify common slow query patterns
4. **Capacity Planning**: Database growth, query volume trends

### Alerting Scenarios
1. **Performance Degradation**
   - Alert: Query mean time > 2x baseline
   - Severity: Warning
   - Action: Check plan changes in VictoriaLogs

2. **Missing Indexes**
   - Alert: Sequential scans on large tables
   - Severity: Info
   - Action: Analyze query plans for index recommendations

3. **Connection Saturation**
   - Alert: Active connections > 80% of max_connections
   - Severity: Critical
   - Action: Check connection pooling, scale cluster

4. **Replication Lag**
   - Alert: Lag > 30 seconds
   - Severity: Warning
   - Action: Check WAL archiving, network, replica load

## Grafana Dashboard Design

### Dashboard 1: PostgreSQL Cluster Overview
**Purpose**: High-level cluster health and performance

**Panels**:
1. **Cluster Status** (Stat)
   - Metric: `cnpg_collector_up`
   - Display: Green/Red status per cluster

2. **Active Connections** (Time Series)
   - Metric: `cnpg_pg_database_numbackends`
   - Group by: database

3. **Transaction Rate** (Time Series)
   - Metrics: `rate(cnpg_pg_database_xact_commit_total[5m])`, `rate(cnpg_pg_database_xact_rollback_total[5m])`

4. **Replication Lag** (Time Series)
   - Metric: `cnpg_pg_replication_lag_seconds`

5. **Query Execution Rate** (Time Series)
   - Metric: `rate(cnpg_pg_stat_statements_calls_total[5m])`

**Variables**:
- `$cluster`: Cluster name (from `cluster` label)
- `$namespace`: Kubernetes namespace
- `$database`: Database name

### Dashboard 2: Query Performance Analysis
**Purpose**: Identify and analyze slow queries

**Panels**:
1. **Top 10 Slowest Queries** (Table)
   - Metric: `topk(10, avg by (queryid, query) (cnpg_pg_stat_statements_mean_exec_time_seconds))`
   - Columns: Query ID, Query Text, Mean Time, Total Calls, Total Time
   - Link: Click queryid → Dashboard 3 with `$query_id` variable

2. **Recent Query Executions Timeline** (VictoriaLogs Table)
   - Query: `_stream: {cluster_name="$cluster", database=~"$database"} | duration_ms > $min_duration | sort by _time desc | limit 50`
   - Columns: Timestamp, Duration (ms), Database, User, Query Text (truncated), Query ID (clickable link)
   - Auto-refresh: 30s
   - Purpose: See chronological timeline of recent slow query executions
   - Note: Only shows queries exceeding auto_explain threshold or logged via log_statement

3. **Query Performance Distribution** (Heatmap)
   - Metric: `cnpg_pg_stat_statements_mean_exec_time_seconds`
   - X-axis: Time, Y-axis: Execution time buckets

4. **Queries by Database** (Pie Chart)
   - Metric: `sum by (database) (cnpg_pg_stat_statements_calls_total)`

5. **Query Execution Time Trend** (Time Series)
   - Metric: `cnpg_pg_stat_statements_mean_exec_time_seconds{queryid=~"$query_id"}`
   - Filter by query ID pattern

6. **Cache Hit Ratio** (Gauge)
   - Metric: `cnpg_pg_stat_statements_shared_blks_hit / (cnpg_pg_stat_statements_shared_blks_hit + cnpg_pg_stat_statements_shared_blks_read)`
   - Threshold: <90% warning

**Variables**:
- `$cluster`: Cluster name
- `$database`: Database name
- `$user`: Database user
- `$query_id`: Query identifier (optional filter)
- `$min_duration`: Minimum duration filter for timeline (default: 0, show all)

### Dashboard 3: Query Plan Correlation
**Purpose**: Correlate metrics with execution plans for deep analysis

**Layout**: Two-panel split view

**Top Panel - Metrics**:
1. **Query Performance Metrics** (Time Series)
   - Metrics:
     - Mean execution time: `cnpg_pg_stat_statements_mean_exec_time_seconds{queryid="$query_id"}`
     - Total calls: `rate(cnpg_pg_stat_statements_calls_total{queryid="$query_id"}[5m])`
     - Rows returned: `rate(cnpg_pg_stat_statements_rows_total{queryid="$query_id"}[5m])`

2. **Query Statistics** (Stat Panels)
   - Total calls, Mean time, Max time, Total time
   - Shared blocks hit/read (cache efficiency)

**Bottom Panel - Logs**:
1. **Execution Plans** (VictoriaLogs)
   - Query: `_stream: {cluster_name="$cluster", query_id="$query_id"} | limit 50`
   - Display: Table with columns:
     - Timestamp
     - Duration (ms)
     - Planning Time (ms)
     - Execution Time (ms)
     - Query Text (truncated)
     - Plan (expandable JSON from `plan_json` field)

2. **Plan Analysis** (JSON Panel - custom plugin or table)
   - Parse `plan_json` field to visualize:
     - Node types (Seq Scan, Index Scan, Hash Join, etc.)
     - Startup/Total costs
     - Plan rows vs Actual rows
     - Filter conditions

**Variables**:
- `$cluster`: Cluster name
- `$database`: Database name
- `$query_id`: Query identifier (required, from Dashboard 2 link or manual input)

**PEV2 Visualizer Integration**:
A "Visualize Plan" button is positioned to the right of Query Statistics panel, providing one-click access to Dalibo's PostgreSQL Explain Visualizer 2 (PEV2).

**How it works**:
1. VictoriaLogs stores execution plans with `VL-Msg-Field: plan_json` (from Vector VRL processing)
2. Grafana Dynamic Text Panel queries VictoriaLogs with `_stream: {query_id=$query_id}`
3. JavaScript extracts plan JSON from the `Line` field (VictoriaLogs message field)
4. Button click posts plan to `https://explain.dalibo.com/new` API
5. Opens visualized plan in new browser tab

**Benefits**:
- **Visual plan analysis**: Interactive tree view of query execution
- **Cost visualization**: Visual representation of node costs and timing
- **Easy sharing**: Shareable URL for collaboration
- **No installation**: External service, no additional infrastructure

**Usage**:
1. Enter a query_id in dashboard variable
2. Click "🔍 Open in PEV2" button (right side, next to Query Statistics)
3. Wait for status message (Loading → Sending → Opening)
4. New tab opens with visualized plan at explain.dalibo.com

**Interaction Flow**:
1. User starts at Dashboard 2 (Query Performance)
2. Clicks on slow query in "Top 10" table
3. Redirected to Dashboard 3 with `$query_id` set
4. Top panel shows query metrics over time
5. Bottom panel shows all execution plans for that query
6. User can:
   - Compare plans before/after performance degradation
   - Identify plan changes (e.g., seq scan vs index scan)
   - Correlate plan changes with metric spikes
   - **Click PEV2 button** to visualize latest plan interactively

### Dashboard 4: Database Operations
**Purpose**: Day-to-day database operations and troubleshooting

**Panels**:
1. **Disk Usage** (Time Series)
   - Metric: `cnpg_pg_database_size_bytes`

2. **WAL Generation Rate** (Time Series)
   - Metric: `rate(cnpg_pg_wal_files_count[5m])`

3. **Checkpoint Statistics** (Table)
   - Metrics: Checkpoint time, buffers written, sync time

4. **Lock Waits** (Time Series)
   - Metric: `cnpg_pg_locks_count`
   - Group by: lock type

5. **Recent Slow Queries** (VictoriaLogs)
   - Query: `_stream: {cluster_name="$cluster"} | duration_ms > 1000 | sort by duration_ms desc | limit 20`

6. **Vector Parse Failures** (VictoriaLogs)
   - Query: `{kubernetes.container_name="postgres", metadata.dropped.component="*"} | _time:24h`
   - Purpose: Monitor and debug Vector VRL parsing issues
   - Fields: error_type, cluster, pod, error message

## Implementation Checklist

- [x] Enable performanceInsights in SQLInstance CRD
- [x] Configure CNPG cluster with monitoring parameters
- [x] Deploy Vector VRL parser for auto_explain logs
- [x] Create VRL validation script for CI/CD (`scripts/test-vector-vrl.sh`)
- [x] Add Vector unit tests and error routing
- [x] Create CI/CD validation workflow (`.github/workflows/vector-config-validation.yml`)
- [x] Create Vector configuration documentation (`observability/base/victoria-logs/README.md`)
- [x] Create Grafana dashboard: Cluster Overview
- [x] Create Grafana dashboard: Query Performance Analysis
- [x] Create Grafana dashboard: Query Plan Correlation (with PEV2 integration)
- [ ] Create Grafana dashboard: Database Operations
- [ ] Configure alerting rules in VictoriaMetrics
- [ ] Document query optimization workflow
- [ ] Test end-to-end correlation with real workload

## Best Practices

### Query Optimization Workflow
1. **Identify**: Use Dashboard 2 to find slow queries
2. **Analyze**: Click through to Dashboard 3 to view execution plans
   - Click "Visualize Plan" button for interactive PEV2 visualization
3. **Compare**: Look at plan changes over time
4. **Investigate**: Check for:
   - Missing indexes (Seq Scan on large tables)
   - Inefficient joins (Hash Join vs Nested Loop)
   - Poor estimates (Plan Rows vs Actual Rows mismatch)
   - Expensive operations (Sort, Hash, Materialize)
5. **Optimize**:
   - Add indexes for common filter/join columns
   - Update statistics with ANALYZE
   - Rewrite query if needed
   - Adjust work_mem for large sorts/hashes
6. **Validate**: Monitor Dashboard 3 after changes to confirm improvement

### Capacity Planning
- **Storage**: Monitor `cnpg_pg_database_size_bytes` growth rate
- **Connections**: Track `cnpg_pg_database_numbackends` vs `max_connections`
- **Query volume**: Track `cnpg_pg_stat_statements_calls_total` growth
- **Replication**: Monitor `cnpg_pg_replication_lag_seconds` for replica capacity

### Security Considerations
- **Query text exposure**: pg_stat_statements stores normalized query text
  - Masks literal values (e.g., `WHERE id = 1` → `WHERE id = ?`)
  - Safe for metrics exposure
- **Plan data sensitivity**: auto_explain logs may contain:
  - Table/column names
  - Filter conditions (but not literal values)
  - Join relationships
  - Recommendation: Restrict VictoriaLogs access via RBAC

## Performance Tuning Guidelines

### Auto Explain Thresholds
- **Production (default)**: `log_min_duration = 1000ms` (queries > 1s, production-safe)
- **High-traffic production**: `log_min_duration = 3000ms` (reduce log volume)
- **Staging**: `log_min_duration = 500ms` (balance detail vs volume)
- **Development**: `log_min_duration = 100ms` or `0` (catch most/all queries)
- **Analytics workloads**: `log_min_duration = 2000ms+` (long-running is expected)

### pg_stat_statements Tuning
- **Default**: `max = 10000` (sufficient for most workloads)
- **High cardinality**: Increase if seeing frequent evictions
- **Reset frequency**: Reset monthly during maintenance window
  - `SELECT pg_stat_statements_reset();`

### Vector Processing
- **Batch size**: 1000 events (balance latency vs throughput)
- **Buffer limits**: 100MB (prevent OOM on log spikes)
- **Backpressure**: Drop oldest events if VictoriaLogs is unavailable
- **Error handling**: Parse failures routed to `victorialogs_pg_parse_failures` stream
  - Uses `reroute_dropped: true` pattern for debugging
  - Captures malformed JSON, missing fields, unexpected formats
  - Includes structured error metadata (cluster, pod, error type)
- **Testing**: Comprehensive validation with 6 unit tests
  - Local validation: `./scripts/test-vector-vrl.sh`
  - CI/CD validation: `.github/workflows/vector-config-validation.yml`
  - Test coverage: Valid plans, missing fields, malformed JSON, filtering

## Future Enhancements

1. **OpenTelemetry Integration**
   - Link database spans to query plans
   - Full distributed tracing across services
   - Correlation: trace_id → query_id → plan

2. **ML-Based Anomaly Detection**
   - Detect unusual query patterns
   - Predict performance degradation
   - Auto-suggest index recommendations

3. **Query Plan Diff**
   - Compare plans before/after changes
   - Highlight differences in execution strategy
   - Historical plan comparison

4. **Automated Index Recommendations**
   - Analyze seq scans on large tables
   - Suggest covering indexes
   - Estimate impact on write performance

5. **Cost-Based Alerting**
   - Alert on expensive query plans
   - Track total_cost metric from plans
   - Proactive performance monitoring
