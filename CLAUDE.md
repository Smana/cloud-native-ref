# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Overview

This is a comprehensive cloud-native platform reference repository implementing GitOps practices with Kubernetes. The repository demonstrates production-ready configurations for building, managing, and maintaining a secure, scalable cloud-native platform using AWS EKS.

## Infrastructure Architecture

The platform is deployed in three sequential stages:

1. **Network Layer** (`opentofu/network/`): VPC, subnets, Route53, and Tailscale VPN
2. **Security Layer** (`opentofu/openbao/`): OpenBao cluster for secrets management and PKI
3. **Kubernetes Layer** (`opentofu/eks/`): EKS cluster with Flux, Cilium, and Karpenter

### Key Components

- **OpenTofu**: Infrastructure as Code (Terraform alternative)
- **Terramate**: OpenTofu orchestration and stack management
- **Flux**: GitOps continuous delivery
- **Crossplane**: Infrastructure composition from Kubernetes
- **OpenBao**: Secrets management and private PKI
- **Cilium**: Advanced networking and security with eBPF
- **Gateway API**: Modern ingress and traffic routing
- **VictoriaMetrics**: High-performance observability stack

## Common Commands

### Terramate Operations

```bash
# Initialize all stacks
terramate script run init

# Preview changes across all stacks
terramate script run preview

# Deploy entire platform
terramate script run deploy

# Check for configuration drift
terramate script run drift detect

# Destroy resources (follow cleanup order)
terramate script run destroy
```

### OpenTofu Operations

```bash
# Individual stack operations
cd opentofu/network  # or eks, openbao/cluster, openbao/management
tofu init
tofu plan -var-file=variables.tfvars
tofu apply -var-file=variables.tfvars
tofu destroy -var-file=variables.tfvars
```

### EKS Cluster Operations

```bash
# Update kubeconfig
aws eks update-kubeconfig --region eu-west-3 --name mycluster-0

# Flux operations
flux get all
flux suspend kustomization --all
flux resume kustomization --all

# Safe cluster cleanup (required order)
flux suspend kustomization --all
kubectl delete gateways --all-namespaces --all
sleep 60
kubectl delete epi --all-namespaces --all
sleep 30
tofu destroy --var-file variables.tfvars
```

### OpenBao Operations

```bash
# Connect to OpenBao
export VAULT_ADDR=https://bao.priv.cloud.ogenki.io:8200
export VAULT_SKIP_VERIFY=true
bao status
bao auth -method=userpass username=admin
```

## Development Workflow

### Prerequisites

- AWS CLI configured with appropriate permissions
- OpenTofu (v1.4+)
- Terramate (latest)
- kubectl
- bao CLI
- jq
- Tailscale account and API key

### Configuration Files

- `opentofu/config.tm.hcl`: Global Terramate configuration
- `opentofu/workflows.tm.hcl`: Terramate scripts and workflows
- `variables.tfvars`: Environment-specific variables (create per stack)

### GitOps with Flux

Flux manages all Kubernetes resources through a dependency hierarchy:

1. **Namespaces** → **CRDs** → **Crossplane** → **EKS Pod Identities**
2. **Security** (External Secrets, Cert-Manager, Kyverno)
3. **Infrastructure** (Cilium, DNS, Load Balancers)
4. **Observability** (VictoriaMetrics, Grafana)
5. **Applications** (Harbor, Headlamp, etc.)

### Crossplane Resources

- **Compositions**: Infrastructure templates in `infrastructure/base/crossplane/configuration/`
- **App Composition**: Platform abstraction for application deployment supporting progressive complexity—from minimal configuration (image only) to production-ready workloads with managed PostgreSQL, Redis/Valkey, S3, autoscaling, high availability, and zero-trust networking. Provides secure defaults while allowing incremental feature adoption.
- **EPI (EKS Pod Identity)**: IAM roles for service accounts in `security/base/epis/`
- **Resource naming**: All Crossplane-managed resources prefixed with `xplane-`

### KCL Formatting Rules

**CRITICAL**: Always run `kcl fmt` before committing KCL code. The CI enforces strict formatting.

#### Formatting Standards

1. **List Comprehensions**: Must be single-line (not multi-line)
   ```kcl
   # ✅ CORRECT (single line)
   _ready = any_true([c.get("type") == "Available" and c.get("status") == "True" for c in conditions or []])

   # ❌ WRONG (multi-line) - will fail CI
   _ready = any_true([
       c.get("type") == "Available" and c.get("status") == "True"
       for c in conditions or []
   ])
   ```

2. **No Trailing Blank Lines**: Remove extra blank lines between logical sections

3. **CRITICAL - Avoid Mutation Pattern (Issue #285)**: Do NOT mutate resource dictionaries after creation

   **Background**: https://github.com/crossplane-contrib/function-kcl/issues/285

   Mutating dictionaries/resources after creation causes function-kcl to create duplicate resources. This is a known bug in function-kcl's duplicate detection mechanism.

   ```kcl
   # ❌ WRONG - Mutation causes DUPLICATES (issue #285)
   _deployment = {
       apiVersion = "apps/v1"
       kind = "Deployment"
       metadata = {
           name = _name
           annotations = {
               "base-annotation" = "value"
           }
       }
   }
   if _deploymentReady:
       _deployment.metadata.annotations["krm.kcl.dev/ready"] = "True"  # ❌ MUTATION!
   _items += [_deployment]

   # ✅ CORRECT - Use inline conditionals
   _deployment = {
       apiVersion = "apps/v1"
       kind = "Deployment"
       metadata = {
           name = _name
           annotations = {
               "base-annotation" = "value"
               if _deploymentReady:
                   "krm.kcl.dev/ready" = "True"  # ✅ Inline conditional
           }
       }
   }
   _items += [_deployment]

   # ✅ CORRECT - List comprehensions (no mutation)
   _items += [{
       apiVersion = "apps/v1"
       kind = "Deployment"
       metadata = {
           name = _name + "-" + db.name
           annotations = {
               "base-annotation" = "value"
               if _ready:
                   "krm.kcl.dev/ready" = "True"
           }
       }
   } for db in databases]
   ```

   **Safe patterns:**
   - Inline conditionals within dictionary literals
   - List comprehensions with inline definitions
   - Ternary operators returning complete dictionaries

   **Unsafe patterns:**
   - Post-creation field assignment: `resource.field = value`
   - Post-creation nested field assignment: `resource.metadata.annotations["key"] = "value"`
   - Any mutation of resource variables after initial creation

4. **Pre-Commit Formatting Check**:
   ```bash
   # Format all KCL files in a module
   cd infrastructure/base/crossplane/configuration/kcl/<module>
   kcl fmt .

   # Verify no changes were made
   git diff --quiet . || echo "Files were reformatted - review changes"
   ```

#### Pre-Commit Checklist for KCL Compositions

**Comprehensive validation script** (REQUIRED before committing):
```bash
# From repository root - validates ALL compositions
./scripts/validate-kcl-compositions.sh
```

This script performs three validation stages for each composition:

1. **KCL Formatting (`kcl fmt`)** - REQUIRED by CI
   - Automatically formats all KCL code
   - Detects formatting violations
   - Shows what needs to be fixed

2. **KCL Syntax Validation (`kcl run`)** - Catches logic errors early
   - Tests KCL code with settings-example.yaml
   - Validates function logic and conditionals
   - Shows detailed error messages

3. **Crossplane Rendering (`crossplane render`)** - End-to-end validation
   - Tests all example files (basic + complete)
   - Validates full composition pipeline
   - Requires Docker (gracefully skips if unavailable)

**Tested Compositions**:
- `app`: app-basic.yaml, app-complete.yaml
- `cloudnativepg` (SQLInstance): sqlinstance-basic.yaml, sqlinstance-complete.yaml
- `eks-pod-identity`: epi.yaml

**Example Output**:
```
╔════════════════════════════════════════════════════════════════╗
║  KCL Crossplane Composition Validation                        ║
╚════════════════════════════════════════════════════════════════╝

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Validating: app
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

📝 [1/3] Checking KCL formatting...
   ✅ Formatting is correct

🧪 [2/3] Validating KCL syntax and logic...
   ✅ KCL syntax valid

🎨 [3/3] Testing crossplane render...
   Testing: app-basic.yaml
   ✅ app-basic.yaml renders successfully
   Testing: app-complete.yaml
   ✅ app-complete.yaml renders successfully

✅ All checks passed for app
```

**CRITICAL**: Always run `./scripts/validate-kcl-compositions.sh` before committing KCL changes. The CI enforces formatting and will fail otherwise.

### Crossplane Composition Validation

**IMPORTANT**: Every change to Crossplane compositions MUST be validated before committing using the following process:

#### 1. Render the Composition

```bash
cd infrastructure/base/crossplane/configuration
crossplane render examples/app-basic.yaml app-composition.yaml functions.yaml \
  --extra-resources examples/environmentconfig.yaml > /tmp/rendered.yaml
```

For complete examples:
```bash
crossplane render examples/app-complete.yaml app-composition.yaml functions.yaml \
  --extra-resources examples/environmentconfig.yaml > /tmp/rendered.yaml
```

#### 2. Validate with Polaris (Security & Best Practices)

```bash
polaris audit --audit-path /tmp/rendered.yaml --format=pretty
```

**Target score**: 85+
**Action**: Address any critical security issues before committing

#### 3. Validate with kube-linter (Kubernetes Best Practices)

```bash
kube-linter lint /tmp/rendered.yaml
```

**Target**: No lint errors
**Action**: Fix all errors before committing

#### 4. Validate with Datree (Policy Enforcement)

```bash
datree test /tmp/rendered.yaml --ignore-missing-schemas
```

**Target**: No policy violations (warnings acceptable if documented)
**Action**: Review and fix policy failures, document accepted warnings

#### Validation Checklist

Before committing Crossplane composition changes:

- [ ] `crossplane render` executes successfully without errors
- [ ] Polaris score is 85+ with no critical security issues
- [ ] kube-linter passes with no errors
- [ ] Datree policy check passes (or warnings are documented)
- [ ] KCL syntax is valid (if using KCL compositions)
- [ ] All composition functions are properly configured
- [ ] Environment configs are included in render

**Why this matters**: These validations catch:
- Security misconfigurations
- Resource limit issues
- Missing health checks
- RBAC problems
- Pod security violations
- Network policy gaps

### Crossplane Known Limitations and Considerations

#### Native Kubernetes Resource Readiness

**Current Implementation**: When using function-kcl to create native Kubernetes resources (Deployment, Service, HTTPRoute, etc.) directly in compositions, readiness is determined by checking actual observed state from the cluster.

**How it works**:
- Crossplane provides observed resources through `option("params").ocds`
- KCL code checks actual status conditions from these observed resources
- Only marks resources ready when specific health conditions are met:
  - **Deployment**: Checks for `status.conditions[type=Available, status=True]`
  - **Service**: Checks if `spec.clusterIP` is assigned
  - **HTTPRoute**: Checks for `status.parents[].conditions[type=Accepted, status=True]`
- The `krm.kcl.dev/ready = "True"` annotation is **conditionally set** based on these checks

**What this means**:
- ✅ **Actual health checking**: Verifies Deployments have available replicas
- ✅ **Status validation**: Confirms HTTPRoutes are accepted by Gateways
- ✅ **Conditional readiness**: Resources only marked ready when actually healthy
- ✅ **No provider-kubernetes needed**: Direct resource creation with real health checks

**Example**:
```kcl
# Check observed Deployment status
_observedDeployment = ocds.get(_name + "-deployment", {})?.Resource
_deploymentReady = any_true([c.get("type") == "Available" and c.get("status") == "True" for c in _observedDeployment?.status?.conditions or []])

# Only add ready annotation when actually available
if _deploymentReady:
    "krm.kcl.dev/ready" = "True"
```

**Why this approach**:
- Accurate health checking without provider-kubernetes complexity
- Resources wait for actual readiness before marking composition ready
- Based on Upbound best practices (project-template-k8s-webapp)

**Alternative approach** (for production):
Use `provider-kubernetes` with `readiness.policy: DeriveFromObject` to actually check resource status:
```yaml
apiVersion: kubernetes.crossplane.io/v1alpha2
kind: Object
spec:
  forProvider:
    manifest:
      apiVersion: apps/v1
      kind: Deployment
      # ... spec
  readiness:
    policy: DeriveFromObject  # Actually checks Deployment.status.conditions[type=Available]
```

**Recommendation**: Monitor actual resource health using:
- Kubernetes events (`kubectl get events`)
- Application metrics and health endpoints
- Crossplane trace command: `crossplane beta trace app <name> -n <namespace>`
- External monitoring (VictoriaMetrics alerts, Grafana dashboards)

**Resources with health checks** in App composition:
- Deployment ✅ (checks `.status.conditions[type=Available]`)
- Service ✅ (checks `spec.clusterIP` assignment)
- HTTPRoute ✅ (checks `.status.parents[].conditions[type=Accepted]`)

**Resources with static readiness** (always marked ready when created):
- HorizontalPodAutoscaler, PodDisruptionBudget, Gateway, CiliumNetworkPolicy, HelmRelease

**NOT affected** (these use proper status conditions):
- SQLInstance (Crossplane XR with actual status)
- EKSPodIdentity (Crossplane XR with actual status)
- S3 Bucket (Managed Resource with proper conditions)

## Security Considerations

### OpenBao PKI Structure

- Root CA → Intermediate CA → Leaf certificates
- AppRole authentication for cert-manager
- Automatic certificate rotation

### IAM and Permissions

- Least privilege principle enforced
- EKS Pod Identity for service account authentication
- Crossplane controllers limited to `xplane-*` prefixed resources
- No deletion permissions for stateful services (S3, IAM, Route53)

### Network Security

- Private EKS API endpoint
- Tailscale VPN for secure access to private resources
- Cilium Network Policies for pod-to-pod communication
- Gateway API for ingress with TLS termination

### Tailscale Gateway API Integration

**Overview**: Private services are exposed via Tailscale using Gateway API with custom domains (`*.priv.cloud.ogenki.io`) instead of MagicDNS names. The platform uses **two separate Gateways** with different Tailscale tags to enforce access control via ACLs.

**Architecture Components**:
1. **Cilium Gateways (Tailscale)**:
   - **General Gateway**: `infrastructure/base/gapi/platform-tailscale-general-gateway.yaml`
     - Tag: `tag:k8s` - Accessible to all Tailscale members
     - Services: Harbor, Headlamp, Homepage, Grafana, VictoriaMetrics (8 services)
   - **Admin Gateway**: `infrastructure/base/gapi/platform-tailscale-admin-gateway.yaml`
     - Tag: `tag:admin` - Restricted to `group:admin` only
     - Services: Hubble UI, VictoriaLogs, Grafana OnCall (5 services)
   - Both use `loadBalancerClass: tailscale` via `CiliumGatewayClassConfig` (critical!)
   - Gateway-level TLS termination (OpenBao certificates)
   - Each exposed at separate Tailscale addresses

2. **ExternalDNS**: `infrastructure/base/external-dns/helmrelease.yaml`
   - Watches HTTPRoutes (via `gateway-httproute` source) referencing both Gateways
   - Creates DNS records in Route53 private zone (`priv.cloud.ogenki.io`)
   - Points records to appropriate Gateway's Tailscale address

3. **HTTPRoutes**: Service-specific routing referencing appropriate Gateway based on access requirements

4. **Tailscale ACLs**: `opentofu/network/tailscale.tf`
   - `tag:admin` → Only `group:admin` can access
   - `tag:k8s` → All `autogroup:member` can access

**Key Innovation**: Cilium Gateway supports `loadBalancerClass: tailscale` via `spec.infrastructure.annotations`, eliminating the need for separate Envoy Gateway installation.

**Setup Requirements**:
1. Deploy CiliumGatewayClassConfig with `service.loadBalancerClass: tailscale`
2. Create both Gateways (general and admin) with label `external-dns: enabled`
3. Configure external-dns to watch `gateway-httproute` source
4. Create HTTPRoutes referencing appropriate Gateway (`platform-tailscale-general` or `platform-tailscale-admin`)
5. Configure Tailscale ACLs with `tag:k8s` and `tag:admin` rules

**Benefits**:
- Custom domains instead of MagicDNS hashes
- Two Tailscale devices for all services (still cost-effective)
- ACL-based access segregation (general vs admin services)
- Advanced routing capabilities (headers, weights, etc.)
- Consistent Gateway API pattern
- Gateway-level TLS management
- Leverages existing Route53 infrastructure
- Zero-trust access control enforcement

**Documentation**: See `docs/tailscale-gateway-api.md` for complete setup guide and troubleshooting.

## Key File Locations

### Infrastructure

- OpenTofu stacks: `opentofu/{network,eks,openbao}`
- Kubernetes manifests: `{infrastructure,security,observability,tooling}/base/`
- Cluster-specific overrides: `{infrastructure,security,observability,tooling}/mycluster-0/`

### GitOps

- Flux configuration: `flux/`
- Custom Resource Definitions: `crds/base/`
- Cluster bootstrap: `clusters/mycluster-0/`

### Scripts

- EKS cleanup: `scripts/eks-prepare-destroy.sh`
- OpenBao configuration: `scripts/openbao-config.sh`
- OpenBao snapshots: `scripts/openbao-snapshot.sh`

## Troubleshooting

### Flux Resources

Use specialized Flux analysis from `.claude/config` for troubleshooting GitOps issues:

- Check FluxInstance status first
- Analyze HelmRelease and Kustomization dependencies
- Review source controller status (GitRepository, HelmRepository)
- Examine managed resource inventory for failures

### Common Issues

- **EKS Access**: Ensure proper IAM permissions and kubeconfig
- **Flux Sync**: Verify GitHub App credentials in AWS Secrets Manager
- **Certificates**: Check OpenBao CA chain and cert-manager logs
- **Network**: Confirm Tailscale subnet router connectivity
- **Resource Conflicts**: Review Crossplane composition functions and resource references

## Database Migrations with Atlas Operator

### Overview

The SQLInstance composition supports declarative database schema migrations using Atlas Operator integrated with Flux GitOps workflow.

### How It Works

When `atlasSchema` is defined in SQLInstance spec, the composition automatically creates:

1. **GitRepository** - Flux pulls migration files from Git repository
2. **Kustomization** - Flux processes `kustomization.yaml` with `configMapGenerator`
3. **ConfigMap** - Automatically generated with migration SQL files
4. **AtlasMigration** - References ConfigMap to apply migrations

### Migration Repository Requirements

The migration repository must contain a `kustomization.yaml` with `configMapGenerator`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

configMapGenerator:
  - name: atlas-db-migrations
    files:
      - ./001_initial_schema.sql
      - ./002_add_users_table.sql
      - atlas.sum
    options:
      disableNameSuffixHash: true
```

### SQLInstance Configuration Example

```yaml
apiVersion: cloud.ogenki.io/v1alpha1
kind: SQLInstance
metadata:
  name: xplane-myapp-sqlinstance
  namespace: apps
spec:
  size: small
  storageSize: 20Gi
  instances: 2
  databases:
    - name: myapp
      owner: myapp-user
  roles:
    - name: myapp-user
      superuser: false
      inRoles: [pg_monitor]
  atlasSchema:
    url: "https://github.com/your-org/your-app.git"
    ref: "v1.1.0"  # Tag (v*) or branch (main, develop, etc.)
    path: "internal/platform/database/migrations"
  backup:
    schedule: "0 2 * * *"
    bucketName: myapp-db-backups
```

### Git Reference Handling

- **Tags**: References starting with `v` (e.g., `v1.0.0`, `v2.1.3`) are treated as Git tags
- **Branches**: Other references (e.g., `main`, `develop`, `feature-branch`) are treated as branches

### Troubleshooting

**ConfigMap not generated:**
```bash
# Check Kustomization status
kubectl get kustomization <name>-atlas-migrations-configmap -n <namespace>

# Check GitRepository sync
kubectl get gitrepository <name>-atlas-migrations-repo -n <namespace>
```

**Migrations not applied:**
```bash
# Check AtlasMigration status
kubectl get atlasmigration <name>-atlas-migration -n <namespace> -o yaml

# Check migration logs
kubectl logs -n infrastructure deployment/atlas-operator-controller-manager
```

**Important Notes:**
- Atlas Operator v0.7.11 does NOT support `dir.remote.url/ref/path` for Git repos
- `dir.remote` only works with Atlas Cloud (requires Atlas Cloud account)
- The GitOps pattern via ConfigMap is the recommended approach for Git-based migrations

## Validation Commands

### Configuration Validation

```bash
# OpenTofu validation with security scanning
tofu validate
trivy config --exit-code=1 --ignorefile=./.trivyignore.yaml .

# Kubernetes manifest validation
kubeconform -summary -output json <manifest>.yaml
```

### Health Checks

```bash
# Cluster health
kubectl get nodes
kubectl get pods --all-namespaces

# Flux status
kubectl get fluxinstance -n flux-operator
flux get all

# OpenBao status
bao status
bao auth list
```
- Never Never push to the main branch it's really important!
