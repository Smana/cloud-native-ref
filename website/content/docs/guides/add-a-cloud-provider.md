---
title: Add a cloud provider
weight: 30
description: ADR-0007's rule made operational — what a new provider must implement, and what must not change.
lastVerified: 2026-08-27
---

The platform runs on AWS **and GCP**, and the second cloud was an addition
rather than a rewrite. What made that possible is a single rule, and the
discipline to apply it consistently.

This page is no longer a plan. Everything below has been through one full
round — see [Cloud support]({{< relref "/docs/platform/foundations/cloud-support.md" >}})
for what the result actually looks like, including where the rule cost
something.

## The rule

**Platform-facing APIs stay cloud-shaped. Developer-facing APIs stay
cloud-neutral.** The line is drawn by audience, not by layer —
[ADR-0007]({{< relref "/docs/decisions/0007-cloud-abstraction-boundaries.md" >}})
records the reasoning, including the rejected option: one neutral abstraction
over both.

## What a new provider must implement

| Layer | What is needed | Why it is cloud-shaped |
|---|---|---|
| Network | VPC-equivalent, subnets, private DNS zone, VPN reachability | Topology and naming differ fundamentally |
| Cluster | Managed Kubernetes with a CNI you control | The bootstrap sequence is provider-specific |
| Identity | Workload-to-cloud-API binding | Trust policy shapes are not interchangeable |
| Secrets store | Somewhere ESO can read from | Provider-specific auth |
| Node autoscaling | Karpenter or the provider's equivalent | Not every cloud has a production-ready Karpenter |

Each gets its own OpenTofu stack and its own section in the documentation. GCP
filled every row: `opentofu/gcp/network`, `gke/{init,configure}`,
`GCPWorkloadIdentity`, Google Secret Manager, and Node Auto-Provisioning with
ComputeClasses. The decisions behind each are
[ADR-0005]({{< relref "/docs/decisions/0005-gke-standard-self-managed-cilium.md" >}}),
[ADR-0006]({{< relref "/docs/decisions/0006-nap-computeclass-over-karpenter.md" >}})
and [ADR-0007]({{< relref "/docs/decisions/0007-cloud-abstraction-boundaries.md" >}}).

Two rows carried a surprise worth passing on. **Node autoscaling** is the
clearest vindication of the table: Karpenter has no production-ready GCP
provider, so the row had to be filled by something else entirely rather than
ported. And **DNS** is the row the table does not have — it turned out not to be
cleanly per-cloud at all, because the public zone must stay in one place for
Let's Encrypt to resolve a challenge. That is
[ADR-0019]({{< relref "/docs/decisions/0019-cross-cloud-dns-federation.md" >}}),
and it is the one place the platform accepted a deliberate cross-cloud
dependency.

## What gains a sibling, not a field

When an API is genuinely cloud-shaped, add a **sibling XRD** rather than a
discriminated union: `EPI` for AWS, `GCPWorkloadIdentity` for GCP, both
consumed internally by the developer-facing compositions.
[ADR-0007]({{< relref "/docs/decisions/0007-cloud-abstraction-boundaries.md" >}})
works the case through `EPI`, whose central field — inline AWS IAM JSON — has
no neutral form.

## What must not change

`App` and `SQLInstance` claims are developer-facing and stay neutral. The
same claim should mean the same thing on either cloud.

That does not mean nothing underneath changes — the S3 bucket becomes a GCS
bucket and the IAM role becomes a workload identity binding. It means the
*claim* does not, so an application team's manifests are not a per-cloud
artifact. `App` holds this today: the same claim renders an S3 bucket plus an
`EPI` on one cloud and a GCS bucket plus a `GCPWorkloadIdentity` on the other.

{{< callout type="info" >}}
**A neutral claim is a promise the compositions have to keep — and
`SQLInstance` now keeps it.** Until crossplane-configuration v0.4.0 its GCP
Composition deliberately failed evaluation rather than composing nothing — the
right interim failure mode, since a claim that cannot be honoured should say
so at reconcile time. Both clouds now render from the same KCL module,
differing only in where barman writes its backups (Cloud Storage rather than
S3) and the identity that writes them, and the CloudNativePG operator runs on
both clusters from the same base — dashboards included.
{{< /callout >}}

Where a genuinely cloud-specific knob is unavoidable, it belongs in a
clearly-marked optional sub-block, not spread through the API.

## The test to apply

Before adding an abstraction, ask who reads it: a platform engineer
configuring one cloud gets a cloud-shaped API, an application developer who
should not care gets a neutral one.
[ADR-0007]({{< relref "/docs/decisions/0007-cloud-abstraction-boundaries.md" >}})
spells out the test — and why an API that only looks neutral fails worse than
one that is visibly cloud-specific.

## Reading on

- [Cloud support]({{< relref "/docs/platform/foundations/cloud-support.md" >}})
  — the AWS/GCP result of applying this rule, service by service
- [Foundations]({{< relref "/docs/platform/foundations/_index.md" >}}) — how
  the [AWS]({{< relref "/docs/platform/foundations/aws.md" >}}) and
  [GCP]({{< relref "/docs/platform/foundations/gcp.md" >}}) stacks are
  structured, and where a sibling would slot in
- [Developer platform]({{< relref "/docs/platform/developer-platform/_index.md" >}})
  — the neutral APIs that must keep working unchanged
