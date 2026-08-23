---
title: AWS
weight: 20
description: The five OpenTofu stacks that implement the three-stage model on AWS, and why EKS bootstrap needs two of them.
lastVerified: 2026-08-20
---

AWS instantiates the [three-stage model]({{< relref "/docs/platform/foundations/_index.md" >}})
as five OpenTofu stacks. Each stack's `stack.tm.hcl` declares the stacks it
runs `after`, so Terramate always applies them in this order even when one
command spans several:

| Stack | Model stage | Owns |
|---|---|---|
| `opentofu/aws/network/` | Network | VPC across three AZs, pod subnets on a secondary CIDR for Cilium ENI prefix delegation, a Route53 private zone, the Tailscale subnet router |
| `opentofu/aws/openbao/cluster/` | Security | OpenBao on EC2 with KMS auto-unseal. Ships as `mode = "dev"` — a single node on `file` storage; `mode = "ha"` builds the five-node Raft cluster on SPOT with RAID-0 NVMe |
| `opentofu/aws/openbao/management/` | Security | The three-tier PKI (root → intermediate → leaf), the cert-manager AppRole, backup automation |
| `opentofu/aws/eks/init/` | Kubernetes (Stage 1) | The EKS cluster, managed node groups, bootstrap addons, IAM, the `flux-system` namespace and secrets |
| `opentofu/aws/eks/configure/` | Kubernetes (Stage 2) | Cilium, Flux Operator + Instance |

Prerequisites (accounts, tools, `mise install`) are not repeated here — see
[Prerequisites]({{< relref "/docs/get-started/prerequisites.md" >}}). For the
deploy commands themselves, see [Get Started → AWS]({{< relref "/docs/get-started/aws/_index.md" >}}).

## Why EKS bootstrap is two OpenTofu stacks

This is the single most important mechanical detail in AWS foundations. A
Kubernetes cluster and the Cilium/Flux Helm releases running inside it cannot
be created by the same `tofu apply`, because of how the Helm provider is
configured — not by design choice, but by a real OpenTofu constraint.

**Stage 1** (`opentofu/aws/eks/init/`) creates the EKS cluster with `terraform-aws-modules/eks/aws`,
plus a temporary bootstrap CNI: VPC-CNI and kube-proxy get the nodes to
`Ready` quickly, CoreDNS and the EBS CSI driver come up behind them, and the
EKS Pod Identity Agent runs from the start (it's needed permanently, not
just for bootstrap). It also creates the Gateway API CRDs, IAM roles, and the
`flux-system` namespace and secrets Stage 2 will populate.

**Stage 2** (`opentofu/aws/eks/configure/`) is a separate OpenTofu root module in
its own directory. Its providers are configured like this:

```hcl
provider "helm" {
  kubernetes = {
    host                   = data.aws_eks_cluster.this.endpoint
    cluster_ca_certificate = base64decode(data.aws_eks_cluster.this.certificate_authority[0].data)
    # ...
  }
}
```

`data.aws_eks_cluster.this` is a **data source** — it reads a cluster that
already exists in AWS at plan time. OpenTofu (like Terraform) cannot
configure a provider from an attribute of a resource the same configuration
is about to create; the provider graph has to resolve before the resource
graph does. So the Cilium and Flux `helm_release`s can't live in Stage 1
alongside the `aws_eks_cluster` resource that produces the endpoint they'd
need — they have to live in a second root module that reads the
already-created cluster back out with a data source. That constraint is the
entire reason this is two OpenTofu stacks and not one.

With the cluster reachable, Stage 2 runs in order: patch the `aws-node`
(VPC-CNI) DaemonSet's `nodeSelector` so it schedules on no nodes, install
Cilium (which also replaces kube-proxy — see the
[repository CLAUDE.md](https://github.com/Smana/cloud-native-ref/blob/main/CLAUDE.md)
for the WireGuard requirement this mode carries), patch out the `kube-proxy`
DaemonSet the same way, then install the Flux Operator and a `FluxInstance`
pointed at this repository — the point at which the cluster starts
reconciling everything under [GitOps]({{< relref "/docs/platform/gitops/_index.md" >}})
on its own. DaemonSets are patched rather than the EKS addons deleted so the
whole stage stays declarative, with no `local-exec` step.

One command runs both: the `deploy` script in
`opentofu/aws/eks/init/workflows.tm.hcl` defines this as two jobs in the same
script — the second job `cd`s into `../configure` and applies it directly —
plus a third job that recycles any node-group node whose ENIs predate
Cilium. Those nodes exist from Stage 1, before Cilium is running, so Cilium
hands them individually-allocated secondary IPs instead of `/28` prefixes
and never converts them: a permanent ceiling of roughly 42 pod IPs per node.
With prefix delegation a Karpenter-provisioned node has several hundred — more
than the 100 pods its `EC2NodeClass` sets as `maxPods`, so scheduling binds
before addressing does. A bootstrap node runs out of IPs long before it
reaches that limit. The failure surfaces far from the cause — a DaemonSet pod that
can't get an IP keeps its rollout `InProgress`, which times out an unrelated
HelmRelease's `--wait` and reports that HelmRelease `InstallFailed`. The
recycle script is idempotent: it inspects each node's `CiliumNode` and only
acts on ones actually missing prefixes, so it's a no-op on every deploy
after the first.

## The OpenBao cluster stack

`opentofu/aws/openbao/cluster/` has two shapes, chosen by one variable. **The
committed configuration is the smaller one** — `variables.tfvars` sets
`mode = "dev"`, and that is what a `terramate script run deploy` gives you
unless you change it.

| | `mode = "dev"` (committed) | `mode = "ha"` |
|---|---|---|
| Nodes | 1 | 5 |
| Storage backend | `file`, on the root volume | Raft, with `retry_join` auto-discovery by tag |
| Instances | `t3.micro`, on-demand | SPOT across several pools, mixed-instances policy |
| Data volume | gp3 root volume | RAID-0 over instance-store NVMe |
| Unseal | KMS auto-unseal | KMS auto-unseal |

So the default posture is a single node whose OpenBao data *and* server TLS
private key both sit on one encrypted gp3 root volume. It is enough to
exercise every path this documentation describes, and it is not highly
available — a Raft-only command like `bao operator raft list-peers` has
nothing to talk to.

In `ha` mode, an interrupted SPOT node comes back from a different pool and
rejoins automatically, and KMS auto-unseal means it does so without a manual
`bao operator unseal`. All five ASG overrides carry equal `weighted_capacity`,
because the ASG reads `desired_capacity` in capacity units — unequal weights
would make the quorum size depend on which SPOT pool happened to win, rather
than always being five.

Neither shape is a production posture. The cluster is torn down and
reprovisioned on every platform test, which is what `dev` mode is priced for
and what the SPOT-everywhere, RAID-0-with-no-redundancy choices in `ha` mode
are priced for. `opentofu/aws/openbao/management/`
then layers the three-tier PKI, the cert-manager AppRole, and policies on
top of the running cluster — see `opentofu/aws/openbao/cluster/README.md` and
`opentofu/aws/openbao/management/README.md` for the operational detail (unseal
keys, AppRole setup, backup and restore).
