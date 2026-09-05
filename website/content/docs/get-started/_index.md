---
title: Get Started
weight: 10
description: Deploy the platform into your own cloud account — AWS or GCP — in about forty-five minutes, almost all of it unattended.
lastVerified: 2026-08-30
---

The platform deploys in three sequential stages: the network, then the secrets
and PKI layer, then Kubernetes. Each is a separate OpenTofu stack orchestrated
by Terramate, and each must complete before the next begins. Once Kubernetes is
up, Flux takes over and reconciles everything else from Git.

Both cloud lanes are implemented and were each deployed end-to-end before this
page was written.

## How long it takes, and what you are waiting for

**About 45 minutes, and you are only needed for the first minute of it.** The
split matters more than the total, because the two halves fail differently:

| | Roughly | What is happening |
|---|---|---|
| Infrastructure | 30 min | Terramate applies the stacks. Network, OpenBao, the EKS/GKE cluster, Cilium, Flux. This is the part that stops if something is wrong with your account or your variables. |
| Convergence | 15 min | Flux reconciles the rest from Git — security, infrastructure, observability, tooling. Nothing to do but watch `flux get all`. |

`terramate script run deploy` returning is **not** the finish line: at that point
the cluster exists and Flux has been handed the repository, but Harbor, Grafana
and the identity provider are still coming up. The identity provider is usually
last, because it waits for its own database to be restored.

## Before you pick a cloud

Three things are worth knowing up front, because none of them is obvious from
inside a stage.

**This costs real money while it runs.** A managed control plane, several nodes,
a load balancer and an OpenBao instance are billable from the first apply. The
committed configuration is deliberately cheap — spot instances, a single-node
OpenBao, a zonal GKE cluster — but it is not free: measured, it runs about
**$730/month on AWS** and **$220/month on GCP**, and roughly $66/month keeps
billing on AWS after everything is destroyed. The numbers, and which lines are
worth attacking, are in
[What it costs]({{< relref "/docs/get-started/costs.md" >}}). Read
[Teardown](#when-you-are-done) before you start, not after.

**The committed values are a working reference, not a template to fill in.**
Every stack already has a `variables.tfvars` in Git with values that deploy.
You are *editing* a working configuration — domain, cluster name, your fork's
URL — not authoring one from scratch.

**One prerequisite cannot be automated.** Each cloud needs a state bucket
created by hand before anything can `plan`, because a stack that created it
would have nowhere to record that it had. GCP needs two more. They are all in
[Prerequisites]({{< relref "/docs/get-started/prerequisites.md" >}}), which is
the page to read first regardless of cloud.

## Pick a lane

{{< cards >}}
  {{< card link="/docs/get-started/prerequisites/" title="1 · Prerequisites" icon="clipboard-check" subtitle="Start here. Accounts, the hand-created state bucket, and `mise install`." >}}
  {{< card link="/docs/get-started/aws/" title="2a · AWS" icon="cloud" subtitle="EKS with Cilium and Karpenter. Three stages, two commands." >}}
  {{< card link="/docs/get-started/gcp/" title="2b · GCP" icon="cloud" subtitle="GKE Standard with self-managed Cilium. Three stages, two commands." >}}
  {{< card link="/docs/get-started/access/" title="3 · Access" icon="key" subtitle="Tailscale is the only door — same model on both clouds. OpenBao, kubectl, dashboard." >}}
  {{< card link="/docs/get-started/first-app/" title="4 · First application" icon="puzzle" subtitle="Deploy an app with one small YAML claim." >}}
{{< /cards >}}

The two lanes are not equivalent in coverage. AWS runs the full platform; GCP
runs everything except `image-gallery` (not yet portable — it hardcodes an AWS
S3 endpoint) and `flux-previews` (excluded by design — previews belong to one
cluster, not both). The exact split is on
[Cloud support]({{< relref "/docs/platform/foundations/cloud-support.md" >}}) —
worth a look before you choose, if you are evaluating rather than just trying it.

## When you are done

Tearing down matters more than usual here, because the expensive resources are
the ones that stay up quietly. The AWS lane has a
[Teardown]({{< relref "/docs/get-started/aws/teardown.md" >}}) page covering the
order and the resources that outlive a naive `destroy` — orphaned EBS volumes
and load balancers in particular. The GCP lane has its own
[Teardown]({{< relref "/docs/get-started/gcp/teardown.md" >}}) page, with GCP's
own traps and what to verify afterwards.
