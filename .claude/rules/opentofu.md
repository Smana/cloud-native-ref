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
cd opentofu/<stack>  # network, eks/init, eks/configure, openbao/cluster, openbao/management, llm-platform
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

## Opt-in Stacks

Stacks tagged `opt-in` (currently: `llm-platform`) are skipped by default. Their `deploy`/`preview`/`drift detect`/`destroy` scripts are overridden in their own `workflows.tm.hcl` to no-op unless an env var enables them.

```bash
# Default: skipped (echoes [skip] and exits 0).
terramate script run deploy

# Opt-in for one invocation (any depth):
TM_LLM_PLATFORM_ENABLED=true terramate script run deploy

# Filter via tag (CI / audit path; no env var needed):
terramate script run --no-tags=opt-in deploy   # skip every opt-in stack
terramate script run --tags=opt-in    deploy   # run only opt-in stacks
```

Trade-off: opt-in scripts use a single bash heredoc and lose Terramate Cloud sync metadata (`sync_deployment` / `sync_preview`). Acceptable for branch-local stacks.

The LLM platform mirrors this gate on the Flux side via the umbrella Kustomization at `clusters/mycluster-0/llm-platform.yaml` (`spec.suspend: true`). Both gates must be released for an end-to-end deploy — see CLAUDE.md "Self-Hosted LLM Platform" + `clusters/mycluster-0/llm-platform/README.md`.

## Validation

```bash
tofu validate
trivy config --exit-code=1 --ignorefile=./.trivyignore.yaml .
```
