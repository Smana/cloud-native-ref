# App KCL Module

A KCL composition function module for deploying cloud-native applications with integrated infrastructure on Kubernetes using Crossplane. This module provides a complete application deployment platform with built-in support for scaling, networking, secrets management, and infrastructure components.

## Overview

This module creates a complete application deployment with:
- Kubernetes Deployment with configurable scaling and resource management
- Service and HTTPRoute for Gateway API-based networking
- Optional dedicated Gateway or shared gateway routing
- Horizontal Pod Autoscaler and Pod Disruption Budget for high availability
- ConfigMap and External Secrets integration for configuration management
- Infrastructure components: Key-Value store (Valkey/Redis), SQL databases, S3 buckets
- EKS Pod Identity for secure AWS access
- Cilium Network Policies for micro-segmentation

## Features

- **Cloud-Native Deployments**: Production-ready Kubernetes deployments with best practices
- **Auto-Scaling**: Horizontal Pod Autoscaler with CPU-based scaling
- **High Availability**: Pod Disruption Budgets, anti-affinity, and zone spreading
- **Gateway API**: Modern ingress with HTTPRoute and optional dedicated gateways
- **Configuration Management**: ConfigMaps and External Secrets for secure config injection
- **Infrastructure Integration**: Optional Redis/Valkey, PostgreSQL, and S3 storage
- **Security**: Network policies, non-root containers, and EKS Pod Identity
- **Observability**: Built-in health checks and monitoring endpoints

## Resource Configurations

### Container Resources
Applications can specify custom resource requests/limits or use defaults:

```yaml
resources:
  requests:
    cpu: "100m"
    memory: "128Mi"
  limits:
    cpu: "200m"
    memory: "256Mi"
```

### Infrastructure Sizing
| Component | Small | Medium | Large |
|-----------|--------|---------|-------|
| **KV Store** | 100m CPU, 256Mi RAM | 200m CPU, 512Mi RAM | 500m CPU, 1Gi RAM |
| **SQL Instance** | Configurable via SQLInstance composition | | |

## Security

This module enforces security best practices by default:

- **Read-only root filesystem**: Containers cannot write to their root filesystem
- **Non-root user**: Containers run as non-privileged users (UID 1001)
- **No privilege escalation**: Prevents containers from gaining additional privileges
- **Dropped capabilities**: All Linux capabilities are dropped by default
- **Seccomp profile**: RuntimeDefault seccomp profile applied
- **Service account token**: Not auto-mounted unless explicitly enabled
- **Writable /tmp**: Provided via emptyDir volume for temporary files

All security settings can be customized via `spec.securityContext` and `spec.automountServiceAccountToken`.

## Network Policies

Optional **Cilium Network Policies** provide micro-segmentation and zero-trust networking:

- **Layer 3-4 policies**: Control traffic based on endpoints and ports
- **FQDN-based egress**: Allow external API calls by DNS name
- **Default deny**: No network policies are created by default - explicit allow model when enabled

Network policies are disabled by default. Enable with `spec.networkPolicies.enabled: true`.

**Example use cases:**
- Restrict ingress to only Gateway pods
- Allow egress to specific databases or services
- Control external API access by FQDN
- Implement defense-in-depth with DNS-aware policies

See `examples/app-with-network-policies.yaml` for detailed examples.

## Examples

The `examples/` directory contains:
- **app-basic.yaml**: Minimal configuration (just image and port)
- **app-complete.yaml**: Full-featured app with database, autoscaling, HA, security, and network policies
- **app-custom-security.yaml**: Example of overriding security defaults
- **app-with-network-policies.yaml**: Comprehensive Cilium network policy examples

### Basic Application

Minimal configuration - just specify the container and port:

```yaml
apiVersion: cloud.ogenki.io/v1alpha1
kind: App
metadata:
  name: basic-app
  namespace: demo
spec:
  image:
    repository: ghcr.io/example/basic-app
    tag: "v1.0.0"

  route:
    port: 8080
```

All other settings use secure defaults (read-only filesystem, non-root, etc.).

### Complete Application with Database

Full-featured application with PostgreSQL database, Atlas migrations, autoscaling, and high availability:

```yaml
apiVersion: cloud.ogenki.io/v1alpha1
kind: App
metadata:
  name: full-stack-app
  namespace: production
spec:
  # Application container
  image:
    repository: "myorg/myapp"
    tag: "v1.2.3"
    pullPolicy: "IfNotPresent"

  # High availability configuration
  autoscaling:
    enabled: true
    minReplicas: 3
    maxReplicas: 20
    targetCPUUtilizationPercentage: 70

  pdb:
    enabled: true
    minAvailable: 2

  spreadAcrossZones: true
  antiAffinityPreset: "soft"

  # Security settings
  runAsNonRoot: true

  # Configuration management
  configs:
    app-config:
      path: "/app/config/app.yaml"
      content: |
        database:
          host: full-stack-app-sqlinstance
          port: 5432
          name: app_db
        redis:
          host: full-stack-app-kvstore
          port: 6379
        features:
          enable_feature_x: true
          debug_mode: false

  secrets:
    db-credentials:
      path: "apps/full-stack-app/database"
      keys: ["username", "password"]
    api-keys:
      path: "apps/full-stack-app/external-apis"
      keys: ["stripe_key", "sendgrid_key"]

  # Gateway and routing
  gateway:
    enabled: true
    gatewayClassName: "istio"
    name: "full-stack-gateway"
    namespace: "production"

  route:
    port: 8080
    internetFacing: true
    rules:
      - backendPort: 8080
        pathPrefix: /api
      - backendPort: 8080
        pathPrefix: /

  # Network security
  networkPolicies:
    enabled: true
    policies:
      ingress:
        - name: allow-from-gateway
          from:
            - namespaceSelector:
                matchLabels:
                  gateway: "true"
          ports:
            - protocol: TCP
              port: 8080
      egress:
        - name: allow-to-database
          to:
            - namespaceSelector:
                matchLabels:
                  database: "true"
          ports:
            - protocol: TCP
              port: 5432
        - name: allow-to-redis
          to:
            - namespaceSelector:
                matchLabels:
                  redis: "true"
          ports:
            - protocol: TCP
              port: 6379

  # Infrastructure components
  kvStore:
    enabled: true
    type: "valkey"
    size: "medium"

  sqlInstance:
    enabled: true
    size: "medium"
    storageSize: 100Gi
    backup:
      schedule: "0 2 * * *"
      retentionPolicy: "30d"
      bucketName: "full-stack-app-db-backups"

  s3Bucket:
    enabled: true
    providerConfigRef:
      name: "aws-provider"
      namespace: "crossplane-system"
    region: "eu-west-3"
    permissions: "readwrite"
    versioning: true
    retentionDays: 90
```

### Microservice with Custom S3 Permissions

Deploy a microservice with fine-grained S3 access:

```yaml
apiVersion: cloud.ogenki.io/v1alpha1
kind: App
metadata:
  name: file-processor
  namespace: services
spec:
  image:
    repository: "myorg/file-processor"
    tag: "v2.1.0"

  replicas: 2

  # Custom resource allocation
  resources:
    requests:
      cpu: "200m"
      memory: "512Mi"
    limits:
      cpu: "1000m"
      memory: "1Gi"

  route:
    port: 8080
    rules:
      - backendPort: 8080
        pathPrefix: /process

  # S3 with custom IAM policy
  s3Bucket:
    enabled: true
    region: "eu-west-3"
    permissions: "custom"
    customPolicy: |
      [
        {
          "Effect": "Allow",
          "Action": [
            "s3:ListBucket"
          ],
          "Resource": [
            "arn:aws:s3:::file-processor-uploads"
          ]
        },
        {
          "Effect": "Allow",
          "Action": [
            "s3:GetObject",
            "s3:PutObject",
            "s3:DeleteObject"
          ],
          "Resource": [
            "arn:aws:s3:::file-processor-uploads/incoming/*",
            "arn:aws:s3:::file-processor-uploads/processed/*"
          ]
        }
      ]
    versioning: true
    retentionDays: 30
```

## Configuration Reference

### Required Fields

- `image.repository`: Container image repository (string)

### Optional Fields

#### Application Configuration
- `image.tag`: Image tag (string, default: `"latest"`)
- `image.pullPolicy`: Image pull policy (`Always`, `Never`, `IfNotPresent`)
- `replicas`: Fixed number of replicas when autoscaling is disabled (integer, default: 1)
- `resources`: Container resource requests and limits
- `onDemand`: Use on-demand instances (boolean, default: false)
- `runAsNonRoot`: Run container as non-root user (boolean, default: true)

#### High Availability
- `autoscaling`: Horizontal pod autoscaler configuration
  - `enabled`: Enable HPA (boolean, default: false)
  - `minReplicas`: Minimum replicas (integer, default: 1)
  - `maxReplicas`: Maximum replicas (integer, default: 5)
  - `targetCPUUtilizationPercentage`: Target CPU utilization (integer, default: 70)
- `pdb`: Pod Disruption Budget configuration
  - `enabled`: Enable PDB (boolean, default: false)
  - `minAvailable`: Minimum available pods (integer, default: 1)
- `spreadAcrossZones`: Spread pods across zones (boolean, default: true)
- `antiAffinityPreset`: Anti-affinity preset (`soft`, `hard`, default: `"soft"`)

#### Configuration and Secrets
- `configs`: Configuration files to mount as volumes (map)
  - `path`: Mount path in container (string)
  - `content`: Configuration content (string)
- `secrets`: Secrets to inject as environment variables (map)
  - `path`: Path in secrets store (string)
  - `keys`: Array of keys to extract (array of strings)

#### Networking
- `gateway`: Dedicated gateway configuration
  - `enabled`: Create dedicated gateway (boolean, default: false)
  - `gatewayClassName`: Gateway class name (string)
  - `name`: Gateway name (string)
  - `namespace`: Gateway namespace (string)
- `route`: HTTP routing configuration
  - `port`: Service port (integer)
  - `internetFacing`: Internet-facing service (boolean, default: false)
  - `rules`: Array of routing rules
    - `backendPort`: Backend port (integer)
    - `pathPrefix`: Path prefix (string, default: `"/"`)

#### Network Policies
- `networkPolicies`: Cilium network policy configuration
  - `enabled`: Enable network policies (boolean, default: false)
  - `policies`: Policy definitions
    - `ingress`: Array of ingress policies
    - `egress`: Array of egress policies

#### Infrastructure Components
- `kvStore`: Key-value store (Valkey/Redis)
  - `enabled`: Enable KV store (boolean, default: false)
  - `type`: Store type (`valkey`, `redis`, default: `"valkey"`)
  - `size`: Store size (`small`, `medium`, `large`)
- `sqlInstance`: PostgreSQL database
  - `enabled`: Enable SQL instance (boolean, default: false)
  - `size`: Instance size (`small`, `medium`, `large`)
  - `storageSize`: Storage size (string, e.g., `"20Gi"`)
  - `backup`: Backup configuration (object)
- `s3Bucket`: S3 bucket storage
  - `enabled`: Enable S3 bucket (boolean, default: false)
  - `providerConfigRef`: Crossplane provider reference
  - `region`: AWS region (string)
  - `permissions`: Bucket permissions (`readwrite`, `readonly`, `custom`)
  - `customPolicy`: Custom IAM policy JSON (when permissions is custom)
  - `versioning`: Enable versioning (boolean, default: false)
  - `retentionDays`: Object retention period (integer)

## Prerequisites

1. **Crossplane**: Installed with required providers
2. **Gateway API**: Gateway API CRDs and controllers
3. **External Secrets Operator**: For secrets management
4. **ClusterSecretStore**: Named `clustersecretstore`
5. **EKS Pod Identity**: For AWS resource access (when using S3)
6. **Cilium**: For network policies (optional)

## Created Resources

The module creates Kubernetes resources based on configuration:

### Core Resources (Always Created)
1. **Deployment**: Application pods with specified configuration
2. **Service**: ClusterIP service for pod discovery

### Conditional Resources
1. **HorizontalPodAutoscaler**: When `autoscaling.enabled: true`
2. **PodDisruptionBudget**: When `pdb.enabled: true`
3. **ConfigMaps**: For each entry in `configs`
4. **ExternalSecrets**: For each entry in `secrets`
5. **Gateway**: When `gateway.enabled: true`
6. **HTTPRoute**: When `route` is specified
7. **CiliumNetworkPolicy**: When `networkPolicies.enabled: true`
8. **Helm Release**: For KV store when `kvStore.enabled: true`
9. **SQLInstance**: When `sqlInstance.enabled: true`
10. **S3 Bucket + EKSPodIdentity**: When `s3Bucket.enabled: true`

## Security Best Practices

### 1. Container Security
- Runs as non-root by default
- Resource limits prevent resource exhaustion
- Health checks ensure application reliability

### 2. Network Security
- Network policies provide micro-segmentation
- Service mesh integration for advanced traffic management
- Gateway API for secure ingress

### 3. Secrets Management
- External Secrets for credential injection
- EKS Pod Identity for AWS access without long-lived credentials
- Secrets stored in external secret stores (not in Git)

### 4. Infrastructure Security
- S3 buckets with encryption and lifecycle policies
- IAM policies follow least-privilege principle
- Database backups encrypted in transit and at rest

## Monitoring and Observability

### Health Checks
The module automatically configures:
- **Liveness Probe**: HTTP GET to `/health` endpoint
- **Readiness Probe**: HTTP GET to `/ready` endpoint

### Metrics Integration
- Applications can expose Prometheus metrics
- Integration with VictoriaMetrics and Grafana
- Infrastructure components provide built-in metrics

## Troubleshooting

### Common Issues

1. **Image Pull Errors**: Check image repository and pull policy
2. **Pod Startup Failures**: Verify resource requests and health check endpoints
3. **Networking Issues**: Check Gateway API configuration and network policies
4. **Secret Access**: Verify ClusterSecretStore and External Secrets configuration
5. **Infrastructure Access**: Check EKS Pod Identity associations and IAM policies

### Useful Commands

```bash
# Check application status
kubectl get apps

# View application details
kubectl describe app <app-name>

# Check related resources
kubectl get deployment,service,hpa,pdb -l app.kubernetes.io/name=<app-name>

# Verify routing
kubectl get httproute,gateway

# Check secrets synchronization
kubectl get externalsecrets

# View network policies
kubectl get ciliumnetworkpolicy
```

### Debugging Tips

1. **Check logs**: `kubectl logs deployment/<app-name>`
2. **Verify connectivity**: Use `kubectl exec` to test network access
3. **Resource constraints**: Monitor CPU and memory usage
4. **Gateway status**: Check Gateway and HTTPRoute status conditions

## Version Compatibility

- **KCL**: v0.11.3+
- **Kubernetes**: v1.25+
- **Gateway API**: v1.0+
- **Crossplane**: v1.14+
- **External Secrets**: v0.9+
- **Cilium**: v1.14+ (for network policies)

## Migration Guide

### From Basic Kubernetes Manifests
1. Convert Deployment and Service to App spec
2. Configure routing with Gateway API instead of Ingress
3. Migrate secrets to External Secrets
4. Add infrastructure components as needed

### From Helm Charts
1. Extract container configuration to `image` and `resources`
2. Convert Ingress to `route` configuration
3. Migrate values to App spec structure
4. Remove chart dependencies, use infrastructure components instead

This module provides a comprehensive platform for deploying modern cloud-native applications with integrated infrastructure, following Kubernetes and cloud-native best practices.
