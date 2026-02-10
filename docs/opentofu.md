# Infrastructure Deployment with OpenTofu

This document explains how to deploy the foundational infrastructure using OpenTofu and Terramate.

## Overview

The platform infrastructure is deployed in **three sequential stages** using OpenTofu:

1. **Network Layer**: VPC, subnets, Route53, Tailscale VPN
2. **Security Layer**: OpenBao cluster for secrets management and PKI
3. **Kubernetes Layer**: EKS cluster with Flux, Cilium, and Karpenter

Each stage depends on the previous one being successfully deployed.

## Why OpenTofu?

**OpenTofu** is an open-source fork of Terraform, created after HashiCorp's license change.

**Why OpenTofu over Terraform?**
- ✅ Truly open-source (Linux Foundation project)
- ✅ Community-driven governance
- ✅ Feature parity with Terraform
- ✅ No vendor lock-in concerns
- ✅ Compatible with existing Terraform code

**Related**: [Technology Choices - OpenTofu](./technology-choices.md)

## Why Terramate?

**Terramate** orchestrates multiple OpenTofu "stacks" (logical infrastructure units).

**Benefits**:
- ✅ **Stack Management**: Organize infrastructure into manageable chunks
- ✅ **Drift Detection**: Continuous monitoring of actual vs desired state
- ✅ **Change Preview**: See what will change before applying
- ✅ **DRY Configuration**: Share variables across stacks
- ✅ **Workflow Automation**: Script common operations consistently

**Alternative**: Manually running `tofu apply` in each directory works but loses orchestration benefits.

## Repository Structure

```
opentofu/
├── config.tm.hcl              # Global Terramate configuration
├── workflows.tm.hcl           # Terramate scripts (deploy, drift, destroy)
│
├── network/                   # Stage 1: Network infrastructure
│   ├── stack.tm.hcl          # Stack metadata
│   ├── main.tf               # VPC, subnets, Route53
│   ├── tailscale.tf          # Tailscale subnet router
│   ├── variables.tfvars      # Environment-specific values (create this)
│   └── README.md             # Detailed network setup
│
├── openbao/
│   ├── cluster/              # Stage 2a: OpenBao cluster
│   │   ├── stack.tm.hcl
│   │   ├── main.tf           # EC2 instances, Raft cluster
│   │   ├── variables.tfvars  # (create this)
│   │   ├── README.md
│   │   └── docs/             # PKI, getting started guides
│   │
│   └── management/           # Stage 2b: OpenBao configuration
│       ├── stack.tm.hcl
│       ├── main.tf           # PKI setup, AppRoles, policies
│       ├── variables.tfvars  # (create this)
│       ├── README.md
│       └── docs/             # AppRole, cert-manager, backup
│
└── eks/                      # Stage 3: Kubernetes cluster (two-stage)
    ├── init/                 # Stage 3a: EKS cluster infrastructure
    │   ├── stack.tm.hcl
    │   ├── main.tf           # EKS cluster, node groups, bootstrap addons
    │   ├── kubernetes.tf     # Namespace, secrets, Gateway API CRDs
    │   ├── karpenter.tf      # Karpenter IAM
    │   └── variables.tfvars  # (create this)
    │
    └── configure/            # Stage 3b: CNI and GitOps
        ├── main.tf           # Cilium + Flux helm_releases
        └── variables.tf      # Versions with defaults
```

## Prerequisites

Before deploying, ensure you have:

### Tools

```bash
# OpenTofu (v1.4+)
brew install opentofu
# Or: https://opentofu.org/docs/intro/install/

# Terramate (latest)
brew install terramate
# Or: https://terramate.io/docs/installation

# AWS CLI
brew install awscli
aws configure

# kubectl
brew install kubectl

# bao CLI (for OpenBao)
brew install openbao/tap/openbao

# jq (JSON processing)
brew install jq
```

### AWS Account

- Admin-level permissions (or equivalent for VPC, EKS, IAM, S3, Route53)
- AWS credentials configured (`~/.aws/credentials` or environment variables)

### GitHub Account

- Personal access token or GitHub App for Flux GitOps
- Fork this repository (or use your own)

### Tailscale Account

- Tailscale API key for subnet router provisioning
- Account at https://login.tailscale.com/

### Domain

- Registered domain for Route53 (e.g., `example.com`)
- Ability to create hosted zone and delegate DNS

## Configuration

### Global Variables (config.tm.hcl)

Edit `opentofu/config.tm.hcl` with your environment values:

```hcl
globals {
  provisioner        = "tofu"
  region             = "eu-west-3"
  eks_cluster_name   = "mycluster-0"

  # Helm chart versions for EKS bootstrap
  cilium_version        = "1.19.0"
  flux_operator_version = "0.41.0"
  flux_instance_version = "0.41.0"

  # Flux sync configuration
  flux_sync_repository_url = "https://github.com/YOUR_ORG/cloud-native-ref.git"

  # OpenBao configuration
  openbao_url                      = "https://bao.priv.cloud.example.com:8200"
  root_token_secret_name           = "openbao/ref/tokens/root"
  cert_manager_approle_secret_name = "openbao/ref/approles/cert-manager"
}
```

### Stack-Specific Variables

Create `variables.tfvars` in each stack directory with environment-specific values.

**Example: network/variables.tfvars**
```hcl
vpc_cidr              = "10.0.0.0/16"
availability_zones    = ["eu-west-3a", "eu-west-3b", "eu-west-3c"]
domain_name           = "priv.cloud.example.com"
tailscale_api_key     = "tskey-xxxxx"  # From environment variable
```

**Example: eks/variables.tfvars**
```hcl
cluster_version       = "1.30"
node_group_min_size   = 2
node_group_max_size   = 10
node_group_desired_size = 3
```

**Security Note**: Never commit sensitive values (API keys, tokens) to Git!
- Use environment variables: `export TF_VAR_tailscale_api_key=<key>`
- Or use AWS Secrets Manager and reference in code

## Deployment

### Option 1: Terramate (Recommended)

Deploy all stacks in correct order with a single command.

**1. Set Environment Variables**
```bash
export TF_VAR_tailscale_api_key=<YOUR_TAILSCALE_API_KEY>
```

**2. Initialize All Stacks**
```bash
cd opentofu
terramate script run init
```

**3. Preview Changes**
```bash
terramate script run preview
```

Reviews what will be created in each stack.

**4. Deploy**
```bash
terramate script run deploy
```

Deploys in order:
1. Network
2. OpenBao cluster
3. OpenBao management
4. EKS cluster

**5. Verify**
```bash
# Check Tailscale
tailscale status

# Check OpenBao
export VAULT_ADDR=https://bao.priv.cloud.example.com:8200
export VAULT_SKIP_VERIFY=true
bao status

# Check Kubernetes
kubectl get nodes
```

### Option 2: Manual Stack Deployment

Deploy each stack individually for more control.

#### Stage 1: Network

```bash
cd opentofu/network

# Initialize
tofu init

# Plan
tofu plan -var-file=variables.tfvars

# Apply
tofu apply -var-file=variables.tfvars

# Verify
tailscale status
# Should see subnet router advertising VPC CIDR
```

**What's Created**:
- VPC with public/private subnets across 3 AZs
- Internet Gateway, NAT Gateways
- Route53 hosted zone for private domain
- Tailscale subnet router EC2 instance
- VPC endpoints (S3, DynamoDB)

**Detailed Guide**: [Network Setup](../opentofu/network/README.md)

#### Stage 2a: OpenBao Cluster

```bash
cd opentofu/openbao/cluster

# Initialize
tofu init

# Plan
tofu plan -var-file=variables.tfvars

# Apply
tofu apply -var-file=variables.tfvars

# Initialize OpenBao (first time only)
export VAULT_ADDR=https://bao.priv.cloud.example.com:8200
export VAULT_SKIP_VERIFY=true
bao operator init -key-shares=5 -key-threshold=3

# Save unseal keys and root token to AWS Secrets Manager
# (scripts/openbao-config.sh automates this)

# Unseal OpenBao
bao operator unseal <key1>
bao operator unseal <key2>
bao operator unseal <key3>
```

**What's Created**:
- 5 EC2 instances (mixed SPOT types) for HA Raft cluster
- Network Load Balancer for OpenBao access
- Security groups for OpenBao cluster communication
- EBS volumes (RAID0) for high-performance storage
- Auto-unseal configuration (KMS)

**Detailed Guide**: [OpenBao Cluster Setup](../opentofu/openbao/cluster/README.md)

#### Stage 2b: OpenBao Management

```bash
cd opentofu/openbao/management

# Authenticate
bao login  # Use root token or user credentials

# Initialize
tofu init

# Plan
tofu plan -var-file=variables.tfvars

# Apply
tofu apply -var-file=variables.tfvars
```

**What's Configured**:
- Three-tier PKI (Root CA → Intermediate CA → Leaf certificates)
- AppRole for cert-manager
- Policies for certificate issuance
- Automated snapshot backups to S3

**Detailed Guide**: [OpenBao Management](../opentofu/openbao/management/README.md)

#### Stage 3: EKS Cluster

Two-stage deployment: Stage 1 creates infrastructure, Stage 2 replaces CNI and installs Flux.

```bash
# Full deployment (both stages)
cd opentofu/eks/init && terramate script run deploy

# Update kubeconfig
aws eks update-kubeconfig --region eu-west-3 --name mycluster-0

# Verify
kubectl get nodes
flux get all
```

**Stage 1 (`opentofu/eks/init/`)**: EKS cluster, managed node groups, bootstrap addons (vpc-cni, kube-proxy, coredns, ebs-csi), Gateway API CRDs, IAM roles, flux-system namespace + secrets/ConfigMap.

**Stage 2 (`opentofu/eks/configure/`)**:

1. Disable VPC CNI (patch nodeSelector)
2. Install Cilium (replaces CNI + kube-proxy)
3. Disable kube-proxy (patch nodeSelector)
4. Install Flux Operator + Instance

**Upgrading versions**:

```bash
# Edit opentofu/config.tm.hcl: cilium_version, flux_operator_version, flux_instance_version
cd opentofu/eks/init && terramate script run deploy

# Or override Flux branch for testing
TF_VAR_flux_git_ref='refs/heads/feature-branch' terramate script run deploy
```

**Post-bootstrap (Flux manages)**: Karpenter, AWS Load Balancer Controller, External DNS, Crossplane, and all other infrastructure.

## Terramate Scripts

Terramate provides reusable workflow scripts.

### init

Initialize all stacks.

```bash
terramate script run init
```

Runs `tofu init` in each stack directory.

### preview

Show what will change without applying.

```bash
terramate script run preview
```

Runs `tofu plan` in each stack in dependency order.

### deploy

Apply changes to all stacks.

```bash
terramate script run deploy
```

**Confirmation**: Prompts for approval before applying (unless `--auto-approve`).

### drift detect

Check if actual state matches desired state.

```bash
terramate script run drift detect
```

**Use case**: Detect manual changes made outside of Terraform.

**CI Integration**: Run as scheduled job to detect drift.

### destroy

Destroy resources in reverse order.

**Safe Destroy Order**:

1. EKS cluster (has built-in cleanup)
2. OpenBao management
3. OpenBao cluster
4. Network

**For EKS**: The destroy script handles cleanup automatically:

```bash
cd opentofu/eks/init && terramate script run destroy
```

This runs `scripts/eks-prepare-destroy.sh` first, which suspends Flux, deletes Gateways, NodePools, and EPIs before destroying infrastructure.

## Post-Deployment

After successful deployment, verify each component:

### Network

```bash
# Tailscale status
tailscale status

# Check VPN connection
ping 10.0.1.1  # Private IP in VPC

# DNS resolution
dig grafana.priv.cloud.example.com
```

### OpenBao

```bash
# Status
export VAULT_ADDR=https://bao.priv.cloud.example.com:8200
export VAULT_SKIP_VERIFY=true
bao status

# List PKI engines
bao secrets list

# Check intermediate CA
bao read pki/priv_cloud_example_com/cert/ca
```

### Kubernetes

```bash
# Nodes
kubectl get nodes

# Flux
flux get all

# Check critical Kustomizations
kubectl get kustomization -n flux-system

# Verify Crossplane
kubectl get provider,composition -n crossplane-system
```

## State Management

OpenTofu state is stored **locally** by default.

**Production Recommendation**: Use remote state backend.

**S3 Backend Example**:
```hcl
# backend.tf in each stack
terraform {
  backend "s3" {
    bucket         = "my-terraform-state"
    key            = "network/terraform.tfstate"
    region         = "eu-west-3"
    encrypt        = true
    dynamodb_table = "terraform-locks"
  }
}
```

**Benefits**:
- ✅ Team collaboration (shared state)
- ✅ State locking (prevent concurrent modifications)
- ✅ Encryption at rest
- ✅ Versioning and backup

## Drift Detection

Detect when actual infrastructure diverges from desired state.

### Manual Drift Check

```bash
# Single stack
cd opentofu/eks
tofu plan -var-file=variables.tfvars

# All stacks
terramate script run drift detect
```

**Drift Causes**:
- Manual changes in AWS Console
- Changes by other tools/users
- Kubernetes operators creating AWS resources
- Auto-scaling events

### Automated Drift Detection

**GitHub Actions**: `.github/workflows/terramate-drift-detection.yaml`

```yaml
# Runs daily
schedule:
  - cron: '0 8 * * *'  # 8 AM UTC

# Creates GitHub issue if drift detected
```

## Troubleshooting

### OpenTofu Init Fails

```bash
# Check OpenTofu version
tofu version

# Clear plugin cache
rm -rf .terraform
tofu init
```

### Plan Shows Unexpected Changes

```bash
# Refresh state
tofu refresh -var-file=variables.tfvars

# Check for manual changes
tofu show

# Review changes
tofu plan -var-file=variables.tfvars | grep "~"
```

### Apply Fails Mid-Run

```bash
# Check state
tofu state list

# Verify resource exists in AWS
aws ec2 describe-instances --filters "Name=tag:Name,Values=<resource>"

# Import if necessary
tofu import <resource_type>.<name> <aws_id>

# Re-apply
tofu apply -var-file=variables.tfvars
```

### EKS Cluster Won't Destroy

**Problem**: VPC has dependent resources (ENIs, Load Balancers).

**Solution**: Use the terramate destroy script which handles cleanup automatically:

```bash
cd opentofu/eks/init && terramate script run destroy
```

This script:
1. Runs `scripts/eks-prepare-destroy.sh` (suspends Flux, deletes Gateways, NodePools, EPIs)
2. Destroys Stage 2 (Cilium, Flux)
3. Destroys Stage 1 (EKS cluster)

### OpenBao Sealed After SPOT Replacement

SPOT instances can be terminated, causing OpenBao to seal.

**Solution**: Auto-unseal configured via KMS.

**Manual Unseal** (if needed):
```bash
bao operator unseal <key1>
bao operator unseal <key2>
bao operator unseal <key3>
```

**Automated Snapshots**: Backups stored in S3 for disaster recovery.

## Cost Optimization

### SPOT Instances

- OpenBao cluster: 100% SPOT for cost savings (HA tolerates node loss)
- EKS nodes: Mixed on-demand + SPOT via Karpenter

**Savings**: ~70% vs on-demand pricing

### Right-Sizing

- Start with smaller instance types
- Monitor with VictoriaMetrics
- Scale up based on actual usage

### NAT Gateway Costs

NAT Gateways are expensive ($0.045/hour + data transfer).

**Alternatives**:
- Use VPC endpoints for AWS services (free data transfer)
- Tailscale subnet router reduces need for public NAT

### Cleanup Unused Resources

```bash
# Find unattached EBS volumes
aws ec2 describe-volumes --filters "Name=status,Values=available"

# Delete old snapshots
aws ec2 describe-snapshots --owner-id <account-id>

# Check for unused Elastic IPs
aws ec2 describe-addresses --filters "Name=association-id,Values="
```

## Security Best Practices

1. **Secrets Management**:
   - Never commit sensitive values to Git
   - Use AWS Secrets Manager for production secrets
   - Rotate credentials regularly

2. **IAM Policies**:
   - Least privilege principle
   - Use EKS Pod Identity instead of IRSA
   - Regular policy audits

3. **Network Security**:
   - Private subnets for workloads
   - Security groups restrict inbound traffic
   - VPC Flow Logs for monitoring

4. **State File**:
   - Remote state backend with encryption
   - State locking to prevent concurrent changes
   - Backup state files

5. **Access Control**:
   - MFA for AWS console access
   - Assume roles for deployment (don't use root credentials)
   - Audit CloudTrail logs

## Upgrade Strategy

### OpenTofu Version Upgrades

```bash
# Check current version
tofu version

# Upgrade OpenTofu
brew upgrade opentofu

# Test with plan
tofu plan -var-file=variables.tfvars

# Apply if no unexpected changes
tofu apply -var-file=variables.tfvars
```

### Provider Version Upgrades

```hcl
# versions.tf
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"  # Allow minor version upgrades
    }
  }
}
```

**Upgrade Process**:
1. Review provider changelog
2. Update version constraint
3. `tofu init -upgrade`
4. `tofu plan` to review changes
5. Test in non-production first

### Kubernetes Version Upgrades

```bash
# Update cluster version in variables.tfvars
cluster_version = "1.31"  # From 1.30

# Plan
cd opentofu/eks
tofu plan -var-file=variables.tfvars

# Apply
tofu apply -var-file=variables.tfvars

# Node groups will be updated rolling
# Flux will redeploy any affected resources
```

## Related Documentation

- [Network Setup](../opentofu/network/README.md)
- [OpenBao Cluster](../opentofu/openbao/cluster/README.md)
- [OpenBao Management](../opentofu/openbao/management/README.md)
- [Technology Choices](./technology-choices.md) - Why OpenTofu, Terramate
- [GitOps](./gitops.md) - What happens after Flux bootstraps
- [Ingress](./ingress.md) - Tailscale VPN access

**External Resources**:
- [OpenTofu Documentation](https://opentofu.org/docs/)
- [Terramate Documentation](https://terramate.io/docs/)
- [AWS Best Practices](https://aws.amazon.com/architecture/well-architected/)
