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
- **EPI (EKS Pod Identity)**: IAM roles for service accounts in `security/base/epis/`
- **Resource naming**: All Crossplane-managed resources prefixed with `xplane-`

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
