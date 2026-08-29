---
title: Teardown
weight: 30
description: Tear the platform down safely, in reverse dependency order.
lastVerified: 2026-08-20
---

Destroying by hand, stack by stack, is easy to get wrong: the EKS cluster
holds resources (Gateways, PVC-backed volumes, IAM access keys) that need
cleaning up in a specific order before OpenTofu can even start deleting.

## EKS only

This is the safe, documented path — always tear the cluster down this way:

```bash
cd opentofu/aws/eks/init
terramate script run destroy
```

Four steps, defined in `opentofu/aws/eks/init/workflows.tm.hcl`:

1. **`prepare-destroy`** — runs `scripts/eks-prepare-destroy.sh` (see below).
2. **`stage2-destroy-addons`** — destroys the `eks/configure` stack (Cilium, Flux).
3. **`stage1-destroy-cluster`** — destroys the `eks/init` stack (the cluster itself).
4. **`stage3-sweep-orphaned-volumes`** — deletes the EBS volumes that were still
   detaching when step 1 swept ([why](#the-sweep-after-the-destroy)).

## Full teardown

Tears down every stack — EKS, OpenBao, Network — in one command:

```bash
cd opentofu
terramate script run --reverse destroy          # aws (the default)
TM_CLOUD=all terramate script run --reverse destroy   # both clouds
```

Reverse dependency order, with a single confirmation prompt
(`scripts/terramate-destroy-confirm.sh`) cached for 10 minutes so the whole
sweep only asks once. `TM_DESTROY_CONFIRMED=true` skips it for CI.

{{< callout type="info" >}}
**Why `eks/configure` shows `[skip]`.** It is a registered stack
(`after = ["/opentofu/aws/eks/init"]`), so a reverse walk reaches it *before*
`eks/init` — the opposite of the order a cluster needs. It used to destroy
itself there, which brought Cilium and Flux down raw: Flux never suspended,
admission webhooks left admitting, and PVCs, NodePools and IAM access keys
never cleaned up. `eks/init`'s `prepare-destroy` then ran against a cluster
whose networking was already gone, and this page carried a warning telling
people not to use the command that ought to work.

Its `destroy` script is now a no-op that says so. The stack is still destroyed
— by `eks/init`'s `stage2-destroy-addons` job, at the point in the sequence
where it is safe. Ownership of the ordering lives in one place because the
stack graph cannot express it.
{{< /callout >}}

## What `eks-prepare-destroy.sh` does first

Before OpenTofu deletes anything, the script:

- Suspends every Flux Kustomization.
- Disables Kyverno's and the Cilium operator's blocking admission webhooks —
  once their pods are evicted with the nodes, every subsequent delete would
  otherwise fail against a webhook with no live endpoint.
- Reclaims CSI-provisioned EBS volumes, by calling
  `scripts/k8s-reclaim-csi-volumes.sh` — the same script the GKE teardown
  calls, since every step of it is plain Kubernetes. It patches **every** PV's
  `persistentVolumeReclaimPolicy` to `Delete` — including PVs deliberately
  set to `Retain` — deletes CloudNativePG `Cluster` resources so the operator
  releases their PVCs cleanly, scales down every Deployment/StatefulSet that
  mounts a PVC, deletes remaining PVC-mounting pods, then runs
  `kubectl delete pvc --all --all-namespaces` and waits up to 300s for
  reclaim. **This step is unconditional** — nothing in the script gates it,
  and it deletes PVC data regardless of the reclaim policy a PV was created
  with. If you need to keep data, back it up out of band *before* running
  `eks-prepare-destroy.sh`; there is no flag that skips this step.
- Separately, sweeps EBS volumes **orphaned by earlier teardown runs** —
  volumes in `available` state, tagged for this cluster, whose PV no longer
  exists. `EKS_DESTROY_KEEP_VOLUMES=true` skips only this sweep of
  already-orphaned volumes; it has no effect on the PV/PVC reclaim above.
  This sweep runs *before* the destroy, so it can only see what has finished
  detaching by then — see [the second sweep](#the-sweep-after-the-destroy) for
  the rest.
- Reclaims the IAM access keys Harbor's S3 registry storage uses — AWS caps
  `AccessKeysPerUser` at 2, so without this a second or third rebuild's
  Harbor can fail to start on a full quota.
- Deletes Karpenter NodePools, Gateway API resources (HTTPRoutes → Gateways →
  GatewayClasses, with finalizers stripped once controllers are gone), Envoy
  Gateway / AI Gateway extension resources, InferencePool resources, and EKS
  Pod Identity associations.
- Strips finalizers from any Crossplane composite resource stuck terminating,
  so the namespace delete that follows doesn't hang forever.

## The sweep after the destroy

`terramate script run destroy` ends with `stage3-sweep-orphaned-volumes`, which
runs `scripts/aws-sweep-orphaned-volumes.sh` once the cluster is gone.

It exists because the pre-destroy sweep above runs at the wrong moment to be
complete. It fires moments after the PVCs are deleted, so a volume still
detaching is not yet `available` and is skipped — and the script says so:
*"may still be detaching — the next run retries"*. The next **run** is the next
teardown, which is a whole rebuild away, so a volume that detached a second too
late bills for the entire gap, and forever if the cluster is never rebuilt.
That is the shape of the accumulation: 62 volumes (~518 GiB) by 2026-07, each
teardown leaving a few for the following one to find.

After `tofu destroy` returns, every node is terminated, so every volume of this
cluster is unambiguously detached and there is no in-flight state left to race.
The same three filters apply — `available`, tagged
`kubernetes.io/cluster/<name>=owned`, and tagged
`kubernetes.io/created-for/pvc/name` — so it can neither touch a second live
cluster's storage nor a hand-made volume.

Run it by hand if you tore the cluster down some other way. It is a dry run
unless you pass `--apply`:

```bash
./scripts/aws-sweep-orphaned-volumes.sh --cluster-name aws-0 --region eu-west-3
```

GCP has the same step as `stage2-sweep-orphaned-disks` — see the
[GCP teardown]({{< relref "/docs/get-started/gcp/teardown.md" >}}).

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
