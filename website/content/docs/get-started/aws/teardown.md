---
title: Teardown
weight: 30
description: Tear the platform down safely, in reverse dependency order.
lastVerified: 2026-08-20
---

Destroying by hand, stack by stack, is easy to get wrong: the EKS cluster
holds resources (Gateways, PVC-backed volumes, IAM access keys) that need
cleaning up in a specific order before OpenTofu can even start deleting, and
every stack has to go in the reverse of the order it was created. The
`destroy` script handles both.

## Full teardown

```bash
cd opentofu
terramate script run --reverse destroy
```

Destroys every stack in reverse dependency order — EKS (`configure` then
`init`) → OpenBao management → OpenBao cluster → Network — with a single
confirmation prompt (`scripts/terramate-destroy-confirm.sh`), cached for 10
minutes so the whole reverse sweep only asks once.

## EKS only

To rebuild just the cluster and leave Network/OpenBao standing:

```bash
cd opentofu/eks/init
terramate script run destroy
```

Three steps, defined in `opentofu/eks/init/workflows.tm.hcl`:

1. **`prepare-destroy`** — runs `scripts/eks-prepare-destroy.sh` (see below).
2. **`stage2-destroy-addons`** — destroys the `eks/configure` stack (Cilium, Flux).
3. **`stage1-destroy-cluster`** — destroys the `eks/init` stack (the cluster itself).

## What `eks-prepare-destroy.sh` does first

Before OpenTofu deletes anything, the script:

- Suspends every Flux Kustomization.
- Disables Kyverno's and the Cilium operator's blocking admission webhooks —
  once their pods are evicted with the nodes, every subsequent delete would
  otherwise fail against a webhook with no live endpoint.
- Reclaims CSI-provisioned EBS volumes: marks every PV reclaimable, deletes
  CloudNativePG `Cluster` resources so the operator releases their PVCs
  cleanly, scales down every Deployment/StatefulSet that mounts a PVC,
  deletes remaining PVC-mounting pods, then deletes the PVCs and waits up to
  300s for reclaim. Set `EKS_DESTROY_KEEP_VOLUMES=true` to skip this if you
  need to salvage data first.
- Reclaims the IAM access keys Harbor's S3 registry storage uses — AWS caps
  `AccessKeysPerUser` at 2, so without this a second or third rebuild's
  Harbor can fail to start on a full quota.
- Deletes Karpenter NodePools, Gateway API resources (HTTPRoutes → Gateways →
  GatewayClasses, with finalizers stripped once controllers are gone), Envoy
  Gateway / AI Gateway extension resources, InferencePool resources, and EKS
  Pod Identity associations.
- Strips finalizers from any Crossplane composite resource stuck terminating,
  so the namespace delete that follows doesn't hang forever.

## What is not deleted

The platform constitution withholds delete permissions from Crossplane for
stateful services — so `xplane-*` IAM roles, policies, and S3 buckets outlive
the cluster. They cost nothing to leave behind and are re-adopted by name on
the next deploy. To remove them by hand once you are sure you are done:

```bash
aws iam list-roles --query 'Roles[?starts_with(RoleName, `xplane-`)].RoleName' --output text
```

## Non-interactive

Both destroy scripts accept `TM_DESTROY_CONFIRMED=true` to skip the
interactive `y/n` prompt. It exists for CI; skip it on a first manual
teardown so you get the confirmation.
