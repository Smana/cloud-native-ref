# Crossplane: Infrastructure from Kubernetes

This document explains how Crossplane is used in this platform to manage infrastructure as Kubernetes resources.

## What is Crossplane?

Crossplane extends Kubernetes to manage cloud infrastructure using the Kubernetes API. Instead of writing Terraform or CloudFormation, you create Kubernetes custom resources that provision and manage cloud services.

**Key Benefits**:
- **Kubernetes-native**: Use kubectl, RBAC, GitOps workflows
- **Platform abstraction**: Hide infrastructure complexity behind simple APIs
- **Self-service**: Developers provision infrastructure without leaving Kubernetes
- **Composition**: Build higher-level abstractions from primitive resources
- **Lifecycle management**: Resources are automatically updated and deleted

**Related**: [Technology Choices - Crossplane for Infrastructure Abstraction](./technology-choices.md#crossplane-for-infrastructure-abstraction)

## Why Crossplane AND OpenTofu?

This platform uses both tools for different purposes:

**OpenTofu (Terraform)** manages:
- ✅ Foundational infrastructure (VPC, EKS, OpenBao cluster)
- ✅ Resources created once during initial setup
- ✅ Infrastructure that rarely changes
- ✅ Bootstrap dependencies for Kubernetes

**Crossplane** manages:
- ✅ Application-scoped infrastructure (databases, storage, IAM)
- ✅ Resources that applications create/destroy dynamically
- ✅ Self-service infrastructure for development teams
- ✅ Resources tied to application lifecycle

This separation provides clear boundaries and ownership.

## Crossplane Security Model

Security is paramount when granting infrastructure provisioning capabilities.

### Least Privilege IAM

Crossplane controllers use EKS Pod Identity with carefully scoped IAM policies:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "s3:CreateBucket",
        "s3:PutBucketPolicy",
        "s3:PutBucketVersioning"
      ],
      "Resource": "arn:aws:s3:::xplane-*"  // Only xplane-* prefixed resources
    },
    {
      "Effect": "Deny",
      "Action": [
        "s3:DeleteBucket",
        "iam:DeleteRole",
        "route53:DeleteHostedZone"
      ],
      "Resource": "*"  // No deletion of stateful services
    }
  ]
}
```

**Key Security Principles**:
1. **Resource Prefix Restriction**: Only manage resources prefixed with `xplane-*`
2. **No Deletion Permissions**: Cannot delete S3 buckets, IAM roles, or Route53 zones
3. **Scoped Actions**: Only necessary actions for resource lifecycle
4. **EKS Pod Identity**: Modern, more secure than IRSA (IAM Roles for Service Accounts)

### Resource Naming Convention

All Crossplane-managed AWS resources MUST be prefixed with `xplane-`:

```yaml
# ✅ ALLOWED
apiVersion: cloud.ogenki.io/v1alpha1
kind: App
metadata:
  name: xplane-podinfo  # Creates xplane-podinfo-* resources

# ❌ BLOCKED by IAM policy
apiVersion: s3.aws.upbound.io/v1beta1
kind: Bucket
metadata:
  name: my-app-bucket  # IAM denies creation (no xplane- prefix)
```

This prevents accidental modification of manually created resources.

## Available Compositions

This platform provides three Crossplane compositions for common infrastructure patterns.

### 1. App Composition

**Purpose**: Deploy full-stack applications with integrated infrastructure

**API**: `cloud.ogenki.io/v1alpha1/App`

**Philosophy**: **Progressive Complexity**
- Start with minimal configuration (just container image)
- Add features incrementally as needs grow
- No "platform migration" from prototype to production

**Minimal Example**:
```yaml
apiVersion: cloud.ogenki.io/v1alpha1
kind: App
metadata:
  name: xplane-myapp
  namespace: apps
spec:
  image:
    repository: ghcr.io/myorg/myapp
    tag: v1.0.0
```

This creates:
- Deployment with security defaults (non-root, read-only filesystem)
- Service
- HTTPRoute (Gateway API)

**Production Example**:
```yaml
apiVersion: cloud.ogenki.io/v1alpha1
kind: App
metadata:
  name: xplane-myapp
  namespace: apps
spec:
  # Application
  image:
    repository: ghcr.io/myorg/myapp
    tag: v1.0.0
  replicas: 3
  autoscaling:
    enabled: true
    minReplicas: 3
    maxReplicas: 10
    targetCPUUtilizationPercentage: 70

  # High Availability
  podDisruptionBudget:
    enabled: true
    minAvailable: 2
  topologySpreadConstraints:
    - maxSkew: 1
      topologyKey: topology.kubernetes.io/zone

  # Infrastructure
  databases:
    - name: main
      size: medium
      instances: 3
  kvStore:
    enabled: true
    size: small
  s3:
    enabled: true
    buckets:
      - name: uploads
        versioning: true

  # Networking
  ingress:
    enabled: true
    host: myapp.cloud.example.com
    gateway: dedicated  # Dedicated Gateway for this app
  networkPolicies:
    enabled: true
```

This creates 30+ Kubernetes and AWS resources automatically!

**What App Composition Manages**:
- ✅ Kubernetes Deployment (with HPA, PDB, anti-affinity)
- ✅ Service + HTTPRoute (Gateway API)
- ✅ Optional dedicated Gateway
- ✅ ConfigMaps and External Secrets
- ✅ KV store (Valkey/Redis) via HelmRelease
- ✅ PostgreSQL databases via SQLInstance composition
- ✅ S3 buckets with IAM permissions
- ✅ EKS Pod Identity (IAM role for service account)
- ✅ Cilium Network Policies (zero-trust micro-segmentation)

**Related**: [App Composition Detailed Guide](../infrastructure/base/crossplane/configuration/kcl/app/README.md)

### 2. SQLInstance Composition

**Purpose**: Managed PostgreSQL clusters with CloudNativePG

**API**: `cloud.ogenki.io/v1alpha1/SQLInstance`

**Features**:
- Configurable sizes (small/medium/large) with predefined resource allocations
- High availability with multiple instances
- S3 backups with retention policies
- Multiple databases and roles per instance
- External Secrets for credentials
- Atlas Operator for schema migrations
- Optional superuser access

**Example**:
```yaml
apiVersion: cloud.ogenki.io/v1alpha1
kind: SQLInstance
metadata:
  name: xplane-myapp-db
  namespace: apps
spec:
  size: medium          # Predefined resource allocations
  storageSize: 50Gi
  instances: 3          # High availability
  databases:
    - name: myapp
      owner: myapp-user
  roles:
    - name: myapp-user
      superuser: false
      inRoles: [pg_monitor]
  backup:
    enabled: true
    schedule: "0 2 * * *"  # Daily at 2 AM
    retentionPolicy: 7d
    bucketName: db-backups
  atlasSchema:
    enabled: true
    url: https://github.com/myorg/myapp
    ref: v1.0.0
    path: migrations/
```

**What SQLInstance Creates**:
- CloudNativePG Cluster resource
- S3 bucket for backups
- Scheduled backups configuration
- Database roles and permissions
- External Secrets for credentials
- Atlas Operator resources for migrations

**Related**: [CloudNativePG Composition](../infrastructure/base/crossplane/configuration/kcl/cloudnativepg/README.md)

### 3. EKSPodIdentity Composition

**Purpose**: IAM roles for Kubernetes service accounts (EKS Pod Identity)

**API**: `cloud.ogenki.io/v1alpha1/EKSPodIdentity`

**Why Pod Identity?** Modern replacement for IRSA:
- Simpler configuration (no OIDC provider setup)
- Supports multiple clusters
- Better credential rotation
- Easier to audit

**Example**:
```yaml
apiVersion: cloud.ogenki.io/v1alpha1
kind: EKSPodIdentity
metadata:
  name: xplane-external-secrets
  namespace: security
spec:
  serviceAccountName: external-secrets
  clusterNames:
    - mycluster-0
    - mycluster-1  # Multi-cluster support
  inlinePolicies:
    - name: secrets-access
      policy: |
        {
          "Version": "2012-10-17",
          "Statement": [{
            "Effect": "Allow",
            "Action": [
              "secretsmanager:GetSecretValue",
              "secretsmanager:DescribeSecret"
            ],
            "Resource": "arn:aws:secretsmanager:*:*:secret:apps/*"
          }]
        }
  managedPolicyARNs:
    - arn:aws:iam::aws:policy/ReadOnlyAccess
```

**What EKSPodIdentity Creates**:
- IAM Role with trust policy for service account
- Inline IAM policies
- Managed policy attachments
- EKS Pod Identity Associations (one per cluster)

**Related**: [EKS Pod Identity Composition](../infrastructure/base/crossplane/configuration/kcl/eks-pod-identity/README.md)

## Composition Functions with KCL

This platform uses **KCL (Kusion Configuration Language)** instead of traditional Crossplane patch-and-transform.

### Why KCL?

**Traditional Composition Problems**:
```yaml
# ❌ Complex, hard to read, limited logic
patches:
  - type: FromCompositeFieldPath
    fromFieldPath: spec.replicas
    toFieldPath: spec.forProvider.manifest.spec.replicas
    transforms:
      - type: math
        math:
          multiply: 2
```

**KCL Solution**:
```python
# ✅ Readable, testable, powerful
_replicas = option("params").oxr.spec.replicas or 1
_deployment = {
    apiVersion = "apps/v1"
    kind = "Deployment"
    spec.replicas = _replicas * 2  # Simple conditional logic
}
```

**KCL Advantages**:
- **Readability**: Code is self-documenting
- **Validation**: Built-in type checking and schema validation
- **Testing**: Unit tests for composition logic
- **Conditionals**: Complex business logic without gymnastics
- **Iteration**: Easy loops over databases, buckets, etc.

### KCL Module Publishing

KCL modules are published to GitHub Container Registry as OCI artifacts:

```bash
# Published to GHCR
ghcr.io/smana/cloud-native-ref/app:v1.0.0
ghcr.io/smana/cloud-native-ref/sqlinstance:v1.0.0
ghcr.io/smana/cloud-native-ref/eks-pod-identity:v1.0.0
```

**Referenced in Composition**:
```yaml
# app-composition.yaml
apiVersion: apiextensions.crossplane.io/v1
kind: Composition
metadata:
  name: app
spec:
  mode: Pipeline
  pipeline:
    - step: kcl-function
      functionRef:
        name: kcl
      input:
        apiVersion: krm.kcl.dev/v1alpha1
        kind: KCLRun
        spec:
          source: oci://ghcr.io/smana/cloud-native-ref/app:v1.0.0
```

## Validation Requirements

**CRITICAL**: Every Crossplane composition change MUST be validated before committing.

### Automated Validation Script

```bash
# From repository root - validates ALL compositions
./scripts/validate-kcl-compositions.sh
```

This script performs three stages:

#### Stage 1: KCL Formatting (CI Enforced!)

```bash
kcl fmt .
```

**CRITICAL**: CI will fail if code is not formatted correctly.

**Common Issues**:
- Multi-line list comprehensions (must be single-line)
- Trailing blank lines between sections
- **Mutation patterns** (see Known Limitations below)

#### Stage 2: KCL Syntax Validation

```bash
kcl run -Y settings-example.yaml
```

Tests KCL logic with example inputs:
- Validates conditionals and loops
- Catches type errors
- Ensures functions work correctly

#### Stage 3: Crossplane Rendering

```bash
crossplane render examples/app-basic.yaml \
  app-composition.yaml \
  functions.yaml \
  --extra-resources examples/environmentconfig.yaml
```

End-to-end validation:
- Tests with multiple examples (basic + complete)
- Validates full composition pipeline
- Ensures all resources render correctly

### Manual Validation Tools

After rendering, validate with additional tools:

**Polaris** (Security and Best Practices):
```bash
polaris audit --audit-path /tmp/rendered.yaml --format=pretty
```
- **Target**: Score 85+
- **Action**: Fix critical security issues

**kube-linter** (Kubernetes Best Practices):
```bash
kube-linter lint /tmp/rendered.yaml
```
- **Target**: No errors
- **Action**: Fix all lint errors

**Datree** (Policy Enforcement):
```bash
datree test /tmp/rendered.yaml --ignore-missing-schemas
```
- **Target**: No policy violations
- **Action**: Fix failures, document accepted warnings

**Related**: [CI Workflows - Crossplane Modules Pipeline](./ci-workflows.md#crossplane-modules-pipeline-githubworkflowscrossplane-modulesyml)

## Known Limitations and Considerations

### KCL Mutation Bug (#285)

**Issue**: https://github.com/crossplane-contrib/function-kcl/issues/285

**Problem**: Mutating dictionaries/resources after creation causes duplicate resources.

```python
# ❌ WRONG - Mutation causes DUPLICATES
_deployment = {
    apiVersion = "apps/v1"
    kind = "Deployment"
    metadata.name = "myapp"
}
if condition:
    _deployment.metadata.annotations["ready"] = "True"  # ❌ MUTATION!
_items += [_deployment]

# ✅ CORRECT - Use inline conditionals
_deployment = {
    apiVersion = "apps/v1"
    kind = "Deployment"
    metadata = {
        name = "myapp"
        annotations = {
            if condition:
                "ready" = "True"  # ✅ Inline conditional
        }
    }
}
_items += [_deployment]
```

**Safe Patterns**:
- ✅ Inline conditionals within dictionary literals
- ✅ List comprehensions with inline definitions
- ✅ Ternary operators returning complete dictionaries

**Unsafe Patterns**:
- ❌ Post-creation field assignment: `resource.field = value`
- ❌ Post-creation nested assignment: `resource.metadata.annotations["key"] = "value"`
- ❌ Any mutation of resource variables after initial creation

### Native Kubernetes Resource Readiness

Crossplane doesn't natively track readiness of native Kubernetes resources created by compositions.

**Current Approach**: Check observed state via `option("params").ocds`

```python
# Example: Check Deployment readiness
_observedDeployment = ocds.get(_name + "-deployment", {})?.Resource
_deploymentReady = any_true([
    c.get("type") == "Available" and c.get("status") == "True"
    for c in _observedDeployment?.status?.conditions or []
])

# Only mark ready when actually available
_deployment = {
    apiVersion = "apps/v1"
    kind = "Deployment"
    metadata = {
        annotations = {
            if _deploymentReady:
                "krm.kcl.dev/ready" = "True"
        }
    }
}
```

**Alternative** (for future consideration): Use provider-kubernetes with `readiness.policy: DeriveFromObject`

## Development Workflow

### Writing a New Composition

1. **Define the API (XRD)**
   ```yaml
   # Define your Custom Resource Definition
   apiVersion: apiextensions.crossplane.io/v1
   kind: CompositeResourceDefinition
   metadata:
     name: xmyresources.cloud.example.com
   spec:
     group: cloud.example.com
     names:
       kind: XMyResource
       plural: xmyresources
   ```

2. **Write KCL Module**
   ```python
   # infrastructure/base/crossplane/configuration/kcl/myresource/main.k
   oxr = option("params").oxr
   ocds = option("params").ocds

   _name = oxr.metadata.name
   _namespace = oxr.metadata.namespace

   # Your resource logic here
   ```

3. **Create Composition**
   ```yaml
   # Reference your KCL module
   apiVersion: apiextensions.crossplane.io/v1
   kind: Composition
   metadata:
     name: myresource
   ```

4. **Validate**
   ```bash
   # Format
   cd infrastructure/base/crossplane/configuration/kcl/myresource
   kcl fmt .

   # Test
   kcl test .

   # Validate full composition
   cd ../..
   ./scripts/validate-kcl-compositions.sh
   ```

5. **Publish Module** (via CI)
   - Commit changes
   - CI publishes to GHCR with version tag

**Related**: [KCL Development Guide](../infrastructure/base/crossplane/configuration/kcl/README.md)

## Using Compositions

### Deploy an Application

```bash
# Create App resource
cat <<EOF | kubectl apply -f -
apiVersion: cloud.ogenki.io/v1alpha1
kind: App
metadata:
  name: xplane-myapp
  namespace: apps
spec:
  image:
    repository: ghcr.io/myorg/myapp
    tag: v1.0.0
  replicas: 2
  ingress:
    enabled: true
    host: myapp.example.com
EOF

# Watch resources being created
kubectl get app xplane-myapp -n apps -w

# Crossplane creates all resources
kubectl get all -n apps -l app.kubernetes.io/name=xplane-myapp
```

### Debug Compositions

**Check Composite Resource**:
```bash
kubectl get app xplane-myapp -n apps -o yaml
```

Look for:
- `.status.conditions`: Health and readiness
- `.status.connectionDetails`: Generated secrets/credentials

**Trace Managed Resources**:
```bash
# Using Crossplane CLI
crossplane beta trace app xplane-myapp -n apps

# Expected output shows resource tree:
# App/apps/xplane-myapp
# ├── Deployment/apps/xplane-myapp
# ├── Service/apps/xplane-myapp
# ├── HTTPRoute/apps/xplane-myapp
# └── SQLInstance/apps/xplane-myapp-db
```

**Check Function Logs**:
```bash
# View KCL function execution logs
kubectl logs -n crossplane-system deployment/function-kcl
```

## Best Practices

1. **Start Simple**: Begin with minimal configuration, add complexity as needed
2. **Use Compositions**: Don't create managed resources directly
3. **Follow Naming Convention**: Always prefix with `xplane-`
4. **Validate Before Commit**: Run `./scripts/validate-kcl-compositions.sh`
5. **Format KCL Code**: Always run `kcl fmt` before committing
6. **Avoid Mutations**: Use inline conditionals, not post-creation assignment
7. **Monitor Resources**: Use `crossplane beta trace` for debugging
8. **Document Decisions**: Add comments explaining non-obvious logic

## Further Reading

**Composition Detailed Guides**:
- [App Composition](../infrastructure/base/crossplane/configuration/kcl/app/README.md) - Comprehensive guide (507 lines!)
- [SQLInstance Composition](../infrastructure/base/crossplane/configuration/kcl/cloudnativepg/README.md)
- [EKS Pod Identity Composition](../infrastructure/base/crossplane/configuration/kcl/eks-pod-identity/README.md)

**KCL Development**:
- [KCL Module Development](../infrastructure/base/crossplane/configuration/kcl/README.md)
- [KCL Documentation](https://kcl-lang.io/)

**Crossplane**:
- [Crossplane Documentation](https://docs.crossplane.io/)
- [Function KCL](https://github.com/crossplane-contrib/function-kcl)
- [Upbound Marketplace](https://marketplace.upbound.io/)

**Blog Posts**:
- [Going Further with Crossplane: Compositions and Functions](https://blog.ogenki.io/post/crossplane_composition_functions/)
- [My Kubernetes Cluster with Crossplane](https://blog.ogenki.io/post/crossplane_k3d/)

**Related Documentation**:
- [Technology Choices](./technology-choices.md) - Why Crossplane
- [GitOps](./gitops.md) - How Crossplane fits in Flux workflow
- [CI Workflows](./ci-workflows.md) - Validation and publishing
