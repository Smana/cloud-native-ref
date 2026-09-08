---
title: GCP
weight: 30
description: The six OpenTofu stacks that implement the three-stage model on GCP, and the two places GKE bootstrap is genuinely simpler than EKS.
lastVerified: 2026-09-02
---

GCP instantiates the [three-stage model]({{< relref "/docs/platform/foundations/_index.md" >}})
as six OpenTofu stacks, mirroring [AWS]({{< relref "/docs/platform/foundations/aws.md" >}})
stack for stage. Each stack's `stack.tm.hcl` declares what it runs `after`, so
Terramate applies them in this order:

| Stack | Model stage | Owns |
|---|---|---|
| `opentofu/gcp/network/` | Network | VPC, node/pod/service ranges, the control-plane CIDR, a **private Cloud DNS zone**, the Tailscale subnet router |
| `opentofu/gcp/openbao/lineage/` | Security | Snapshot bucket (also the mirror of AWS snapshots), node and drill identities, Storage Transfer job, GitHub WIF pool. **Persistent** |
| `opentofu/gcp/openbao/cluster/` | Security | OpenBao on Compute Engine, single-node Raft, **Cloud KMS** or the AWS seal (standby) |
| `opentofu/gcp/openbao/management/` | Security | The three-tier PKI, the `lineage/` marker mount, policies, and the rehydrate step. **Persistent** |
| `opentofu/gcp/gke/init/` | Kubernetes (Stage 1) | The GKE cluster, the static node pool, Gateway API CRDs, IAM, the `flux-system` namespace and secrets |
| `opentofu/gcp/gke/configure/` | Kubernetes (Stage 2) | Cilium, Flux Operator + Instance |

Bootstrap is two stacks here for exactly the reason it is on AWS: a provider
cannot be configured from an attribute of a resource the same configuration is
about to create, so the Cilium and Flux `helm_release`s must live in a second
root module that reads the finished cluster back with a data source. That
argument is written out in full on the
[AWS page]({{< relref "/docs/platform/foundations/aws.md" >}}#why-eks-bootstrap-is-two-opentofu-stacks)
and is not repeated here.

Prerequisites are **not** the same as AWS. GCP has three hand-created
bootstrap items — a state bucket in its own project, a Cloud KMS key ring, and
a Tailscale OAuth client. The sequence is in `docs/gcp-bootstrap.md` in the
repository. See also [Get Started → GCP]({{< relref "/docs/get-started/gcp/_index.md" >}}).

## The committed shape

| | Value |
|---|---|
| Location | `europe-west4-a` — **zonal**, not regional |
| Cluster | GKE **Standard** ([ADR-0005](../../decisions/0005-gke-standard-self-managed-cilium.md)) |
| Node image | `COS_CONTAINERD` |
| Static pool | 2 × `e2-standard-4`, **spot** |
| Control plane | Private endpoint, private nodes — reachable only over the tailnet |
| Autoscaling | Node Auto-Provisioning + ComputeClass ([ADR-0006](../../decisions/0006-nap-computeclass-over-karpenter.md)) |

Zonal and spot are deliberate: this is a reference platform that is torn down
after every run, so a regional control plane and on-demand nodes would buy
availability nobody is using. It is not a production posture, and neither is
the AWS side.

## Two create-time settings that decide everything

The whole reason GKE can run this platform at all comes down to two fields in
`opentofu/gcp/gke/init/main.tf`, and both are **create-time only** — changing
either later replaces the cluster.

```hcl
datapath_provider = "DATAPATH_PROVIDER_UNSPECIFIED"
network_policy    = false
```

`DATAPATH_PROVIDER_UNSPECIFIED` selects GKE's legacy datapath rather than
**Dataplane V2**. That reads like choosing the older option, and it is the
important one: Dataplane V2 *is* Cilium — Google's build of it — and it ships
without the `CiliumGatewayClassConfig` CRD and the `io.cilium/gateway-controller`
this platform depends on. Adopting it would break both Tailscale gateways and
the Envoy access-log pipeline into VictoriaLogs. So the platform takes the
legacy datapath and installs its own Cilium on top.

`network_policy = false` turns off GKE's own policy controller, because Cilium
is the policy engine. Leaving it on would put two enforcers in one datapath.

This pairing is why [ADR-0005](../../decisions/0005-gke-standard-self-managed-cilium.md)
rules out **Autopilot** entirely: Autopilot does not permit the privileged
DaemonSet a self-managed CNI requires, so the choice is Standard or nothing.

## Where GKE is simpler than EKS

Two of the most awkward parts of the AWS lane have no counterpart here.

**No CNI to disable first.** On EKS, Stage 2 patches the `aws-node` and
`kube-proxy` DaemonSets onto no nodes before Cilium can take over. On GKE,
Cilium's `cni.exclusive` displaces GKE's CNI config directly — `/etc/cni/net.d`
ends up holding only `05-cilium.conflist`, with GKE's renamed `.cilium_bak` —
and `kubeProxyReplacement` handles kube-proxy without touching a managed
DaemonSet the addon manager would revert anyway.

**No WireGuard.** On AWS, `encryption.type: wireguard` is load-bearing: it works
around an open Cilium bug that breaks the Gateway API L7 proxy under ENI prefix
delegation. GCP does not use prefix delegation and does not hit the bug, so the
tunnel overhead is simply not paid here. This was verified on a live cluster
rather than assumed.

Both differences were checked during the ADR-0005 validation, not inferred from
documentation.

## Identity, DNS and storage

These are the three places the GCP lane genuinely diverges from AWS rather than
just renaming things. The full side-by-side is on
[Cloud support]({{< relref "/docs/platform/foundations/cloud-support.md" >}}); the
short version:

- **Identity** — GKE Workload Identity Federation, claimed through
  `GCPWorkloadIdentity` rather than `EPI`. No static service-account keys.
- **DNS** — the private zone is **Cloud DNS**; the public zone is **Route 53**,
  reached by federating an AWS IAM role onto a projected Kubernetes
  ServiceAccount token ([ADR-0019](../../decisions/0019-cross-cloud-dns-federation.md)).
  `gcp-0` therefore runs *two* external-dns instances, one per provider.
- **Storage** — the default block class is `standard-rwo` (pd-balanced, despite
  the name — `standard` is the HDD tier). Object storage is Cloud Storage, and
  model weights mount through the Cloud Storage FUSE CSI driver
  ([ADR-0021](../../decisions/0021-gcs-fuse-for-model-weights-on-gcp.md)).

## What is excluded here, and why

`gcp-0` reconciles the same layers as `aws-0` — observability, tooling and
applications included. What it leaves out is deliberate and per-component:
`image-gallery` (the application itself speaks S3) and `flux-previews`
(previews belong to one cluster by nature). The
[Cloud support]({{< relref "/docs/platform/foundations/cloud-support.md" >}}) page
has the full map of what runs where, and what closing each exclusion would take.
