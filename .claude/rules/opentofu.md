---
description: OpenTofu and Terramate operations, EKS two-stage bootstrap, and stack conventions
globs:
  - "opentofu/**/*.tf"
  - "opentofu/**/*.hcl"
  - "opentofu/**/*.tfvars"
---

# OpenTofu / Terramate Rules

## Stack Operations

```bash
# Individual stack
cd opentofu/<stack>  # network, eks/init, eks/configure, openbao/cluster, openbao/management
tofu init
tofu plan -var-file=variables.tfvars
tofu apply -var-file=variables.tfvars
```

## Terramate Orchestration

```bash
terramate script run init      # Initialize all stacks
terramate script run preview   # Preview changes
terramate script run deploy    # Deploy platform
terramate script run drift detect  # Check drift
```

## EKS Two-Stage Bootstrap

**Stage 1** (`eks/init`): EKS cluster, managed node groups, bootstrap addons (vpc-cni, kube-proxy, coredns, ebs-csi), Gateway API CRDs, IAM, flux-system namespace.

**Stage 2** (`eks/configure`): Disable VPC CNI, install Cilium (replaces CNI + kube-proxy), install Flux Operator + Instance.

**Deploy both stages**: `cd opentofu/eks/init && terramate script run deploy`

**Feature branch testing**: `TF_VAR_flux_git_ref='refs/heads/my-branch' terramate script run deploy`

## Validation

```bash
tofu validate
trivy config --exit-code=1 --ignorefile=./.trivyignore.yaml .
```
