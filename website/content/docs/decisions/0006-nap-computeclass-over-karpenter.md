---
title: GKE node auto-provisioning (ComputeClass) over Karpenter on GCP
linkTitle: 0006 · GKE ComputeClass
weight: 60
description: GCP nodes autoscale via GKE node auto-provisioning (ComputeClass) rather than Karpenter, because ComputeClass can taint every new node before scheduling, which self-managed Cilium requires.
lastVerified: 2026-08-20
---

**Status**: Accepted
**Date**: 2026-08-18
**Deciders**: Smana (Platform Owner)
**Related Design**: [GCP Support — Dual-Cloud Platform Design](https://github.com/Smana/cloud-native-ref/blob/main/docs/superpowers/specs/2026-08-18-gcp-support-design.md)

---

## Context

On AWS the platform autoscales nodes with **Karpenter**, expressed as three pairs of manifests
in `infrastructure/base/karpenter-nodepools/` and `infrastructure/base/karpenter-nodepools-gpu/`:

| Purpose | Manifests |
|---------|-----------|
| general workloads | `default-nodepool.yaml` + `default-ec2nc.yaml` |
| IO-heavy workloads | `io-nodepool.yaml` + `io-ec2nc.yaml` |
| GPU (L4) workloads | `gpu-l4-nodepool.yaml` + `gpu-l4-ec2nc.yaml` |

Adding GCP requires an equivalent. Because [ADR-0005](0005-gke-standard-self-managed-cilium.md)
runs **self-managed Cilium**, whatever provisions nodes must be able to place
`node.cilium.io/agent-not-ready=true:NoSchedule` on **every** node it creates, including nodes
created seconds before a pending pod is scheduled. If it cannot, pods land on nodes with no
working CNI — an intermittent failure that looks like a Cilium bug and is painful to diagnose.

---

## Decision Drivers

- **Production readiness** — dual-cloud means both implementations are maintained and relied on.
- **Cilium taint propagation to autoscaled nodes** — a hard requirement from ADR-0005, not a nicety.
- **Node OS control** — Cilium has kernel requirements, so the image must be pinnable.
- **Conceptual distance from Karpenter** — how much of the mental model transfers.
- **GPU support** — the LLM platform needs L4-class accelerators.

---

## Considered Options

### Option 1: GKE node auto-provisioning via ComputeClass

The modern NAP interface: a `ComputeClass` custom resource with `nodePoolAutoCreation` enabled
(GKE >= 1.33.3-gke.1136000), declaring an ordered `priorities[]` list of machine shapes.

**Pros**:
- Production-ready, Google-supported, and the blessed autoscaling path on GKE.
- **`nodePoolConfig.taints[]` applies taints to auto-created node pools**, which satisfies the
  Cilium `agent-not-ready` requirement declaratively.
- **`nodePoolConfig.imageType`** pins `cos_containerd` / `ubuntu_containerd` for Cilium's kernel
  requirements.
- `priorities[]` carries `machineFamily`, `machineType`, `spot`, `gpu`, `storage.bootDiskType`
  and `nodeSystemConfig` — a close conceptual match to Karpenter requirements plus
  `EC2NodeClass` fields, including ordered fallback (spot first, then on-demand).
- Collapses six manifests into three `ComputeClass` objects.

**Cons**:
- **No equivalent to Karpenter's `disruption` / consolidation semantics.** Bin-packing and
  node-replacement behaviour is the GKE autoscaler's, not ours to tune the same way.
- Cannot set a minimum node count above zero on an auto-created pool, by design — a non-zero
  minimum would prevent removal of empty pools.
- A GCP-only API: the manifests are not shared with AWS, they are a sibling.

### Option 2: karpenter-provider-gcp

A community Karpenter provider for GCP, initiated and primarily developed by CloudPilot AI.

**Pros**:
- Same API as AWS (`NodePool` + a GCP node class), so one mental model and potentially shared
  manifest structure.
- Karpenter's consolidation and disruption budgets carry over.

**Cons**:
- **Preview / alpha, and explicitly not recommended for production.** Not in `kubernetes-sigs`.
- Disqualifying for a cloud that is meant to be maintained in parallel with AWS, not a demo.
- Would make the platform's GCP node lifecycle depend on a single-vendor pre-1.0 controller.
- Compare Azure, where `karpenter-provider-azure` reached GA and backs AKS NAP; GCP has no
  equivalent maturity.

### Option 3: Static managed node pools with cluster autoscaler

Fixed node pools, scaled by the standard cluster autoscaler.

**Pros**:
- Simplest, most predictable, fully supported. Taints and image type are set on the pool.
- No new API to learn.

**Cons**:
- Requires enumerating machine shapes up front; no automatic shape selection.
- Loses the workload-driven provisioning that makes Karpenter valuable on the AWS side, so the
  two clouds' capabilities diverge in a way users would notice.
- Poor fit for the GPU/LLM workloads, which are bursty and shape-specific.

---

## Decision Outcome

**Chosen option**: "Option 1 — GKE node auto-provisioning via ComputeClass"

**Rationale**: Option 2 is the only option that would have preserved a single autoscaling API
across both clouds, and it is disqualified by maturity alone — a preview-grade, single-vendor
controller cannot sit under a cloud the platform claims to maintain. Between the remaining two,
ComputeClass keeps workload-driven provisioning (the property that made Karpenter worth having)
while clearing the two hard constraints ADR-0005 imposes: it can taint auto-created pools and it
can pin the node image. Option 3 remains the fallback if ComputeClass taint propagation turns
out to be unreliable in practice, which the autoscaling slice tests directly.

Note that Option 3 is not wasted work either way: the foundation slice brings up the cluster with a single
**static** tainted node pool, exactly as `eks/init` creates managed node groups before Karpenter
arrives. ComputeClass is layered on afterwards, mirroring the AWS sequence.

---

## Consequences

### Positive

- Blessed, supported autoscaling on GCP, with GPU and Spot support.
- Three `ComputeClass` manifests replace six Karpenter manifests.
- Cilium's readiness taint is handled declaratively at the pool level rather than by a
  post-provisioning hook.
  - *Amended 2026-08-24, after measuring it.* This is true but incomplete, and the omission
    matters: see the toleration requirement under Negative. Declaring the taint works; making it
    **transparent to workloads** does not.

### Negative

- **Consolidation semantics are not portable.** Karpenter's `disruption` block, consolidation
  policy and disruption budgets have no ComputeClass equivalent; cost/packing behaviour will
  differ measurably between the two clouds.
  - *Mitigation*: the autoscaling slice ships an explicit written statement of the gap rather
    than leaving it to be discovered. This is a documented divergence, not an abstraction to be faked.
- **Every workload targeting a ComputeClass must tolerate `node.cilium.io/agent-not-ready`,
  or nothing scales up at all.** Added 2026-08-24 from a live measurement, because this was not
  anticipated when the ADR was written.

  The autoscaler simulates scheduling against a node that *will* carry the class's taint. A pod
  that cannot tolerate it is judged unplaceable, so no node is provisioned — and the symptom is
  silence: three Pending pods for ten minutes with **no `TriggeredScaleUp` event of any kind**,
  only `FailedScheduling`. Adding the toleration alone produced four nodes and all pods Running.
  GKE's admission webhook warns on apply; the warning is load-bearing.

  This is a real divergence from AWS, where the equivalent taint is invisible to workloads
  because static pools carry it and Karpenter provisions against `NodePool` requirements rather
  than simulating a tainted node.
  - *Decision*: keep the taint and require the toleration, rather than dropping it. It still
    gates every pod that does not opt in, and keeps auto-created nodes behaving like static ones.
  - *Accepted cost*: a tolerating pod can land before the Cilium agent is up and log
    `plugin type="cilium-cni" failed (add): unable to create endpoint ... EOF`. That is the CNI
    present with its agent still starting, **not** a missing CNI, and it self-heals — measured 0
    restarts, pods reached `Running` unaided. `kube-system/metrics-server` hits the same transient
    on any fresh node, so it is a property of the platform rather than of this decision.
- No `min > 0` per auto-created pool, so "always keep N warm" must be expressed differently
  (for example a small static pool alongside the auto-created ones).
- Karpenter knowledge does not transfer cleanly; operators need to learn a second model.

### Neutral

- `infrastructure/base/runtimeclass-nvidia/` is **AWS-only** and is not ported. It exists because
  the Bottlerocket NVIDIA AMI pre-configures an `nvidia` containerd runtime handler and advertises
  `nvidia.com/gpu` natively, so a `RuntimeClass` is needed but a device plugin is not. GKE
  installs drivers through its own managed installer and advertises `nvidia.com/gpu` without a
  `RuntimeClass`, so GCP needs a different and smaller GPU shim.

---

## Implementation Notes

Each `ComputeClass` sets `nodePoolConfig.taints[]` to include
`node.cilium.io/agent-not-ready=true:NoSchedule` and pins `nodePoolConfig.imageType`.
`priorities[]` is ordered spot-first then on-demand, mirroring the capacity-type preference in
the existing Karpenter `NodePool`s.

The load-bearing test is not "does it scale" but "does a **freshly auto-created** node come up
carrying the taint, and does Cilium clear it before any workload pod is scheduled there".
The design makes that a success criterion.

---

## References

- [About node pool auto-creation (GKE)](https://docs.cloud.google.com/kubernetes-engine/docs/concepts/node-auto-provisioning)
- [Configure node pool auto-creation (GKE)](https://docs.cloud.google.com/kubernetes-engine/docs/how-to/node-auto-provisioning)
- [ComputeClass CRD reference](https://docs.cloud.google.com/kubernetes-engine/docs/reference/crds/computeclass) — `nodePoolConfig.taints[]`, `nodePoolConfig.imageType`, `priorities[]`
- [cloudpilot-ai/karpenter-provider-gcp](https://github.com/cloudpilot-ai/karpenter-provider-gcp) — preview status
- [ADR-0005](0005-gke-standard-self-managed-cilium.md) — the self-managed Cilium decision that imposes the taint requirement
- Existing Karpenter manifests: `infrastructure/base/karpenter-nodepools/`, `infrastructure/base/karpenter-nodepools-gpu/`
