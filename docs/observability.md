# Observability

This document explains the observability stack used for monitoring, logging, and alerting in this platform.

## Overview

Effective observability is essential for maintaining system health, diagnosing issues, and optimizing performance. This platform uses a comprehensive stack covering:

- **Metrics**: VictoriaMetrics for time-series data
- **Logs**: VictoriaLogs for log aggregation and search
- **Dashboards**: Grafana for visualization
- **Alerting**: VMRules and VMAlertmanager for notifications

## Why VictoriaMetrics?

**Traditional Choice**: Prometheus is the de-facto standard for Kubernetes metrics.

**Why VictoriaMetrics Instead?**

- ✅ **Better Performance**: Lower resource usage, faster queries
- ✅ **Cost Efficiency**: Superior compression (10x typical), less storage needed
- ✅ **PromQL Compatible**: Drop-in replacement, existing dashboards work
- ✅ **Unified Stack**: VictoriaLogs integrates seamlessly for logs
- ✅ **Scalability**: Better handling of high-cardinality metrics

**Performance Comparison** (approximate):
- **Storage**: 10x better compression vs Prometheus
- **Query Speed**: 2-5x faster for common queries
- **Memory**: 50% less RAM for equivalent workload

**Related**: [Technology Choices - VictoriaMetrics](./technology-choices.md#victoriametrics-over-prometheus)

## Metrics Stack

### VictoriaMetrics Components

This platform uses the VictoriaMetrics Operator to manage components.

#### VictoriaMetrics Operator

Manages VictoriaMetrics resources via Kubernetes CRDs.

```bash
# Check operator status
kubectl get deployment victoria-metrics-operator -n observability

# View managed resources
kubectl get vmcluster,vmagent,vmalert -n observability
```

#### VMCluster (VictoriaMetrics Cluster)

High-availability cluster for metrics storage and querying.

```yaml
apiVersion: operator.victoriametrics.com/v1beta1
kind: VMCluster
metadata:
  name: vmcluster
  namespace: observability
spec:
  retentionPeriod: "30d"  # Keep metrics for 30 days
  vmstorage:
    replicaCount: 2  # HA storage
    resources:
      requests:
        memory: 1Gi
        cpu: 500m
  vmselect:
    replicaCount: 2  # Query frontend
    resources:
      requests:
        memory: 512Mi
        cpu: 250m
  vminsert:
    replicaCount: 2  # Ingestion endpoint
    resources:
      requests:
        memory: 512Mi
        cpu: 250m
```

**Components**:
- **vmstorage**: Stores time-series data (stateful)
- **vmselect**: Handles queries (stateless)
- **vminsert**: Ingests metrics (stateless)

**Alternative**: VMSingle for smaller deployments (all-in-one)

#### VMAgent

Scrapes metrics from targets and forwards to VMCluster.

```yaml
apiVersion: operator.victoriametrics.com/v1beta1
kind: VMAgent
metadata:
  name: vmagent
  namespace: observability
spec:
  selectAllByDefault: true  # Auto-discover ServiceMonitors and PodMonitors
  remoteWrite:
    - url: http://vmcluster-vminsert.observability:8480/insert/0/prometheus/api/v1/write
```

**Scrape Discovery**:
- **ServiceMonitor**: Scrapes Kubernetes Services
- **PodMonitor**: Scrapes Pods directly
- **VMNodeScrape**: Scrapes node-level metrics

**Example ServiceMonitor**:
```yaml
apiVersion: operator.victoriametrics.com/v1beta1
kind: VMServiceScrape
metadata:
  name: cloudnativepg
  namespace: observability
spec:
  selector:
    matchLabels:
      postgresql: cloudnativepg
  namespaceSelector:
    any: true
  endpoints:
    - port: metrics
      interval: 30s
```

#### VMAlert

Evaluates alerting rules and sends notifications.

```yaml
apiVersion: operator.victoriametrics.com/v1beta1
kind: VMAlert
metadata:
  name: vmalert
  namespace: observability
spec:
  datasource:
    url: http://vmcluster-vmselect.observability:8481/select/0/prometheus
  notifier:
    url: http://vmalertmanager.observability:9093
  ruleSelector:
    matchLabels:
      managed-by: victoria-metrics-operator
```

### Pre-configured Dashboards

#### Kubernetes Dashboards

**views-global**: Cluster-wide overview
```yaml
- CPU, memory, network usage across all nodes
- Pod count, restarts, failures
- API server latency and request rate
```

**views-nodes**: Per-node metrics
```yaml
- CPU, memory, disk, network per node
- Node conditions (Ready, MemoryPressure, DiskPressure)
- Kubelet metrics
```

**views-pods**: Pod-level metrics
```yaml
- CPU, memory per pod
- Container restarts
- Resource requests vs usage
```

**views-namespaces**: Namespace aggregation
```yaml
- Resource usage by namespace
- Pod count per namespace
- Network traffic per namespace
```

#### Node Exporter

System-level metrics from each node.

```yaml
- CPU usage (user, system, iowait)
- Memory (used, cached, available)
- Disk I/O (read/write IOPS, latency)
- Network (packets, bytes, errors)
- Filesystem usage
```

#### Karpenter Metrics

Autoscaler metrics and node provisioning.

```yaml
- Node pool capacity and usage
- Provisioning time and success rate
- Consolidation actions
- Spot instance interruptions
```

#### Database Dashboards

**CloudNativePG**: PostgreSQL cluster monitoring
```yaml
- Connection count
- Transaction rate (commits, rollbacks)
- Replication lag
- Cache hit ratio
- Slow queries
```

#### Application Metrics

Applications expose metrics via Prometheus client libraries.

**Example** (Go application):
```go
import "github.com/prometheus/client_golang/prometheus"

httpRequestsTotal := prometheus.NewCounterVec(
    prometheus.CounterOpts{
        Name: "http_requests_total",
        Help: "Total number of HTTP requests",
    },
    []string{"method", "endpoint", "status"},
)
```

Scraped via PodMonitor:
```yaml
apiVersion: operator.victoriametrics.com/v1beta1
kind: VMPodMonitor
metadata:
  name: myapp
  namespace: apps
spec:
  selector:
    matchLabels:
      app: myapp
  podMetricsEndpoints:
    - port: metrics
      path: /metrics
```

### Accessing VictoriaMetrics

**vmui** (VictoriaMetrics UI):
```
https://vl.priv.cloud.ogenki.io/select/vmui/
```

Features:
- PromQL query editor
- Metric explorer
- Graph visualization
- Cardinality explorer

**Example Queries**:
```promql
# CPU usage by pod
sum(rate(container_cpu_usage_seconds_total[5m])) by (pod)

# Memory usage by namespace
sum(container_memory_working_set_bytes) by (namespace)

# HTTP request rate
sum(rate(http_requests_total[5m])) by (endpoint)

# 95th percentile latency
histogram_quantile(0.95, rate(http_request_duration_seconds_bucket[5m]))
```

## Logs Stack

### VictoriaLogs

High-performance log aggregation and querying.

**Why VictoriaLogs?**
- ✅ Integrated with VictoriaMetrics stack
- ✅ High compression ratio
- ✅ Fast full-text search
- ✅ PromQL-like query language (LogsQL)
- ✅ Cost-effective at scale

#### VictoriaLogs Single

All-in-one log storage and query.

```yaml
apiVersion: operator.victoriametrics.com/v1beta1
kind: VLSingle
metadata:
  name: vlsingle
  namespace: observability
spec:
  retentionPeriod: "7d"  # Keep logs for 7 days
  storage:
    volumeClaimTemplate:
      spec:
        resources:
          requests:
            storage: 50Gi
```

**Alternative**: VLCluster for high-scale deployments (ingest/storage separation)

#### Log Collection

Logs collected via Fluent Bit or Promtail.

**Example**: Fluent Bit DaemonSet
```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: fluent-bit-config
  namespace: observability
data:
  fluent-bit.conf: |
    [INPUT]
        Name tail
        Path /var/log/containers/*.log
        Parser docker
        Tag kube.*

    [OUTPUT]
        Name http
        Match kube.*
        Host vlsingle.observability
        Port 9428
        URI /insert/jsonline
        Format json
```

#### Accessing VictoriaLogs

**vlui** (VictoriaLogs UI):
```
https://vl.priv.cloud.ogenki.io/select/vmui
```

**Example Queries**:
```logsql
# Find errors in specific namespace
{namespace="apps"} | grep "error"

# Filter by pod and time
{pod="myapp-*"} | time:last 1h

# Count logs by level
{level=~"error|warn"} | count() by (level)

# Search for specific message
{app="frontend"} | grep "connection refused"
```

### Kubernetes Event Exporter

Centralize Kubernetes events as logs.

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: event-exporter-config
  namespace: observability
data:
  config.yaml: |
    route:
      routes:
        - match:
            - receiver: victorialogs
    receivers:
      - name: victorialogs
        http:
          endpoint: http://vlsingle:9428/insert/jsonline
```

**Captured Events**:
- Pod creation/deletion
- Container restarts
- Scheduling failures
- Resource quota exceeded
- Image pull errors

## Dashboards with Grafana

### Grafana Operator

Manages Grafana instances and resources via CRDs.

```yaml
apiVersion: grafana.integreatly.org/v1beta1
kind: Grafana
metadata:
  name: grafana
  namespace: observability
spec:
  config:
    server:
      root_url: https://grafana.priv.cloud.ogenki.io
    auth:
      disable_login_form: false
    security:
      admin_user: admin
      admin_password: ${ADMIN_PASSWORD}  # From Secret
```

### GrafanaDatasource

Define data sources declaratively.

**VictoriaMetrics Datasource**:
```yaml
apiVersion: grafana.integreatly.org/v1beta1
kind: GrafanaDatasource
metadata:
  name: victoriametrics
  namespace: observability
spec:
  instanceSelector:
    matchLabels:
      dashboards: grafana
  datasource:
    name: VictoriaMetrics
    type: prometheus
    url: http://vmcluster-vmselect.observability:8481/select/0/prometheus
    isDefault: true
    jsonData:
      timeInterval: 30s
```

**VictoriaLogs Datasource**:
```yaml
apiVersion: grafana.integreatly.org/v1beta1
kind: GrafanaDatasource
metadata:
  name: victorialogs
  namespace: observability
spec:
  datasource:
    name: VictoriaLogs
    type: victorialogs
    url: http://vlsingle.observability:9428/select/logsql/query
```

### GrafanaDashboard

Deploy dashboards as Kubernetes resources.

```yaml
apiVersion: grafana.integreatly.org/v1beta1
kind: GrafanaDashboard
metadata:
  name: kubernetes-overview
  namespace: observability
spec:
  instanceSelector:
    matchLabels:
      dashboards: grafana
  json: |
    {
      "dashboard": {
        "title": "Kubernetes Overview",
        "panels": [
          {
            "title": "CPU Usage",
            "targets": [{
              "expr": "sum(rate(container_cpu_usage_seconds_total[5m])) by (namespace)"
            }]
          }
        ]
      }
    }
```

**Pre-loaded Dashboards**:
- Kubernetes cluster overview
- Node metrics
- Pod resource usage
- Karpenter autoscaling
- CloudNativePG databases
- Flux GitOps status

### Accessing Grafana

```
https://grafana.priv.cloud.ogenki.io
```

Default credentials stored in AWS Secrets Manager (synced via External Secrets).

## Alerting

### VMRules

Define alerting rules using PromQL.

```yaml
apiVersion: operator.victoriametrics.com/v1beta1
kind: VMRule
metadata:
  name: karpenter-alerts
  namespace: observability
spec:
  groups:
    - name: karpenter
      interval: 30s
      rules:
        - alert: KarpenterNodeAllocationHigh
          expr: |
            (
              sum(karpenter_nodes_allocatable{resource_type="cpu"})
              - sum(karpenter_nodes_allocatable{resource_type="cpu"})
            ) / sum(karpenter_nodes_allocatable{resource_type="cpu"}) > 0.85
          for: 5m
          labels:
            severity: warning
          annotations:
            summary: "Karpenter node allocation is high"
            description: "Node allocation is {{ $value | humanizePercentage }}"

        - alert: KarpenterProvisioningFailed
          expr: |
            rate(karpenter_provisioner_scheduling_duration_seconds_count{result="failed"}[5m]) > 0
          for: 5m
          labels:
            severity: critical
          annotations:
            summary: "Karpenter node provisioning failing"
```

**Common Alert Types**:

**Resource Alerts**:
```yaml
- PodMemoryHigh
- PodCPUThrottling
- PersistentVolumeSpaceLow
- NodeDiskSpaceLow
```

**Application Alerts**:
```yaml
- HighErrorRate (5xx responses > 5%)
- HighLatency (p95 > 1s)
- PodCrashLooping
- DeploymentReplicasMismatch
```

**Infrastructure Alerts**:
```yaml
- NodeNotReady
- KubeletDown
- APIServerLatencyHigh
- EtcdHighCommitDuration
```

### VMAlertmanager

Routes and deduplicates alerts to notification channels.

```yaml
apiVersion: operator.victoriametrics.com/v1beta1
kind: VMAlertmanager
metadata:
  name: vmalertmanager
  namespace: observability
spec:
  replicaCount: 2  # HA alertmanager
  configSecret: alertmanager-config
```

**Configuration** (in Secret):
```yaml
global:
  resolve_timeout: 5m

route:
  group_by: ['alertname', 'cluster']
  group_wait: 10s
  group_interval: 10s
  repeat_interval: 12h
  receiver: 'slack-notifications'
  routes:
    - match:
        severity: critical
      receiver: 'slack-critical'
      continue: true

receivers:
  - name: 'slack-notifications'
    slack_configs:
      - api_url: '<webhook-url-from-secret>'
        channel: '#alerts'
        title: '{{ .GroupLabels.alertname }}'
        text: '{{ range .Alerts }}{{ .Annotations.description }}{{ end }}'

  - name: 'slack-critical'
    slack_configs:
      - api_url: '<webhook-url-from-secret>'
        channel: '#critical-alerts'
        title: '[CRITICAL] {{ .GroupLabels.alertname }}'
```

**Notification Channels Supported**:
- Slack
- PagerDuty
- Email
- Webhook (generic)
- OpsGenie
- VictorOps

**Slack Integration** (via External Secrets):
```yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: slack-webhook
  namespace: observability
spec:
  secretStoreRef:
    name: aws-secrets-manager
  target:
    name: slack-webhook-url
  data:
    - secretKey: url
      remoteRef:
        key: /observability/slack-webhook
```

## Metrics Server

Lightweight metrics for basic cluster operations.

```yaml
# Deployed in kube-system namespace
kubectl get deployment metrics-server -n kube-system
```

**Provides**:
- `kubectl top nodes` - Node CPU/memory
- `kubectl top pods` - Pod CPU/memory
- HPA (Horizontal Pod Autoscaler) metrics

**Note**: VictoriaMetrics provides much richer metrics; Metrics Server is for basic kubectl commands.

## Accessing Observability Stack

| Tool | URL | Purpose |
|------|-----|---------|
| Grafana | https://grafana.priv.cloud.ogenki.io | Dashboards |
| VictoriaMetrics | https://vl.priv.cloud.ogenki.io/select/vmui/ | Metrics query |
| VictoriaLogs | https://vl.priv.cloud.ogenki.io/select/vmui | Log search |
| Alertmanager | http://vmalertmanager.observability:9093 | Alert management (internal) |

All accessible via Tailscale VPN (private domain).

## Best Practices

### Metrics

1. **Label Cardinality**: Keep labels low-cardinality (avoid UUIDs, timestamps in labels)
2. **Retention**: Balance storage cost vs historical data needs (default: 30 days)
3. **Scrape Intervals**: Standard 30s, adjust for high-frequency metrics
4. **Aggregation**: Pre-aggregate when possible (recording rules)
5. **Naming**: Follow Prometheus naming conventions (unit suffix: `_seconds`, `_bytes`)

### Logs

1. **Structured Logging**: Use JSON for easier parsing and filtering
2. **Log Levels**: Use appropriate levels (DEBUG, INFO, WARN, ERROR)
3. **Retention**: Shorter than metrics (default: 7 days, logs are bulkier)
4. **Sampling**: Sample high-volume logs (100% of errors, 1% of info)
5. **Context**: Include request ID, user ID, trace ID for correlation

### Dashboards

1. **Templating**: Use variables for namespace, pod selection
2. **SLOs**: Display Service Level Objectives prominently
3. **Annotations**: Mark deployments, incidents on graphs
4. **Folders**: Organize by team, service, layer
5. **Sharing**: Export dashboards as JSON, store in Git

### Alerting

1. **Actionable**: Only alert on actionable issues
2. **Severity**: Classify correctly (critical = wake me up, warning = check tomorrow)
3. **Deduplication**: Group related alerts
4. **Runbooks**: Link to remediation documentation
5. **Testing**: Regularly test alert routing and on-call rotation

## Troubleshooting

### No Metrics Appearing

```bash
# Check VMAgent scraping
kubectl logs -n observability deployment/vmagent

# Check VMCluster ingestion
kubectl logs -n observability statefulset/vmcluster-vmstorage

# Verify ServiceMonitor/PodMonitor
kubectl get vmservicescrape,vmpodmonitor -n observability

# Test metric endpoint directly
kubectl port-forward -n apps pod/myapp-xxx 8080:8080
curl http://localhost:8080/metrics
```

### Alerts Not Firing

```bash
# Check VMAlert evaluation
kubectl logs -n observability deployment/vmalert

# Verify VMRule exists and is valid
kubectl get vmrule -n observability
kubectl describe vmrule karpenter-alerts -n observability

# Check Alertmanager receives alerts
kubectl port-forward -n observability svc/vmalertmanager 9093:9093
# Visit http://localhost:9093/#/alerts
```

### High Cardinality Issues

```bash
# Find high-cardinality metrics in vmui
# Visit: Cardinality Explorer tab

# Check top metrics by series count
# Reduce labels or increase retention period
```

### Dashboard Not Loading

```bash
# Check Grafana logs
kubectl logs -n observability deployment/grafana

# Verify datasource configured
kubectl get grafanadatasource -n observability

# Check datasource connectivity from Grafana pod
kubectl exec -n observability deployment/grafana -- \
  curl http://vmcluster-vmselect.observability:8481/select/0/prometheus/api/v1/query?query=up
```

## Cost Optimization

### Storage

- **Metrics Retention**: 30 days (vs 15 days for high-volume)
- **Logs Retention**: 7 days (vs 30 days for compliance)
- **Compression**: VictoriaMetrics achieves 10x compression
- **Downsampling**: Reduce resolution for old data (future enhancement)

### Compute

- **Right-size Components**: Start small, scale based on actual usage
- **SPOT Instances**: VictoriaMetrics components can run on SPOT (stateful storage needs care)
- **Scrape Intervals**: 30s default, 60s for low-priority metrics

### Network

- **Minimize Egress**: Keep observability stack in same region/VPC
- **Efficient Queries**: Use recording rules for expensive queries run often

## Future Enhancements

- [ ] **Tracing**: Implement distributed tracing (Tempo, Jaeger)
- [ ] **Profiling**: Continuous profiling (Pyroscope)
- [ ] **SLO Tracking**: Automated SLO/SLI tracking and reporting
- [ ] **Log Parsing**: Structured log parsing for application logs
- [ ] **Anomaly Detection**: ML-based anomaly detection for metrics
- [ ] **Cost Attribution**: Per-team, per-app cost tracking

## Related Documentation

- [Technology Choices](./technology-choices.md) - Why VictoriaMetrics
- [Ingress](./ingress.md) - Accessing observability UIs via Tailscale
- [Crossplane](./crossplane.md) - App composition with monitoring integration
- [Blog: VictoriaMetrics and Grafana Operators](https://blog.ogenki.io/post/series/observability/metrics)
- [Blog: Effective Alerts](https://blog.ogenki.io/post/series/observability/alerts/)

**External Resources**:
- [VictoriaMetrics Documentation](https://docs.victoriametrics.com/)
- [Grafana Operator Documentation](https://grafana.github.io/grafana-operator/)
- [PromQL Basics](https://prometheus.io/docs/prometheus/latest/querying/basics/)
