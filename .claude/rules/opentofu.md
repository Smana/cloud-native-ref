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
# Stack paths are cloud-prefixed. `cd opentofu && terramate list` is the source
# of truth -- 15 stacks today:
#   aws/{network,eks/init,eks/configure,openbao/cluster,openbao/lineage,openbao/management,llm-platform}
#   gcp/{network,gke/init,gke/configure,openbao/cluster,openbao/lineage,openbao/management}
#   shared/{tailscale,aws-gcp-federation}
cd opentofu/<stack>
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

## Choosing the cloud — `TM_CLOUD`

One variable, defaulting to `aws`. It is a comma list, so a third cloud needs no
new keyword:

```bash
terramate script run deploy                    # aws alone (the default)
TM_CLOUD=gcp     terramate script run deploy   # gcp alone; AWS stacks echo [skip]
TM_CLOUD=aws,gcp terramate script run deploy   # both
TM_CLOUD=all     terramate script run deploy   # every lane
```

A stack's lane is its directory: `opentofu/aws/**`, `opentofu/gcp/**`, and
`opentofu/shared/**` which is owned by neither cloud and always runs.

Enforced in `scripts/tm-provisioner.sh`, which `global.provisioner` points at —
so it wraps every `tofu` call in the shared scripts *and* in every per-stack
override at once. Jobs that run something other than tofu (a repo script,
gcloud) carry `${global.cloud_gate}` or `--tm-run`; the destructive ones must,
since `eks-prepare-destroy.sh` deletes every PVC.

**Why not tags.** A tag filter has no committed default — `--no-tags` has to be
typed, so a fresh clone or CI would get all 15 stacks, and `drift reconcile`
runs `tofu apply -auto-approve`. Tags remain right for *listing*
(`terramate list --tags=gcp`), not for gating. This replaced a two-knob scheme
(`TM_GCP_ENABLED=true` to turn GCP on, `--no-tags=aws` to turn AWS off) where
getting one wrong silently built the wrong cloud.

## EKS Two-Stage Bootstrap

**Stage 1** (`eks/init`): EKS cluster, managed node groups, bootstrap addons (vpc-cni, kube-proxy, coredns, ebs-csi), Gateway API CRDs, IAM, flux-system namespace.

**Stage 2** (`eks/configure`): Disable VPC CNI, install Cilium (replaces CNI + kube-proxy), install Flux Operator + Instance.

**Deploy**: `cd opentofu && terramate script run deploy` covers every stack including
these two. `cd opentofu/aws/eks/init && terramate script run deploy` re-runs just this
stack (both its internal stages) — for a failed run, not for the normal flow.

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

The LLM platform mirrors this gate on the Flux side via the umbrella Kustomization at `clusters/aws-0/llm-platform.yaml` (`spec.suspend: true`). Both gates must be released for an end-to-end deploy — see CLAUDE.md "Self-Hosted LLM Platform" + `clusters/aws-0/llm-platform/README.md`.

## Validation

```bash
tofu validate
trivy config --exit-code=1 --ignorefile=./.trivyignore.yaml .
```
