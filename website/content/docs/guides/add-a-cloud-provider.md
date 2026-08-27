---
title: Add a cloud provider
weight: 30
description: ADR-0007's rule made operational — what a new provider must implement, and what must not change.
lastVerified: 2026-08-20
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
cloud-neutral.**

The line is drawn by audience, not by layer. A platform engineer already
knows which cloud they are configuring, so an API they consume should be
honest about it. An application developer should not have to know, so an API
they consume should not expose it.

[ADR-0007]({{< relref "/docs/decisions/0007-cloud-abstraction-boundaries.md" >}})
records the reasoning, including the option that was rejected: one neutral
abstraction over both, whose most important field would inevitably have been
a free-form cloud-specific blob.

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
discriminated union.

`EPI` is the clearest case. Its central field is inline AWS IAM JSON. GCP's
equivalent is a list of predefined roles or a custom role's permissions.
There is no neutral form of that field, and an API carrying both shapes and
choosing at render time is two APIs sharing a name — with worse error
messages than either would have alone.

So: `EPI` for AWS, `GCPWorkloadIdentity` for GCP — the sibling now exists —
both consumed internally by the developer-facing compositions.

## What must not change

`App` and `SQLInstance` claims are developer-facing and stay neutral. The
same claim should mean the same thing on either cloud.

That does not mean nothing underneath changes — the S3 bucket becomes a GCS
bucket and the IAM role becomes a workload identity binding. It means the
*claim* does not, so an application team's manifests are not a per-cloud
artifact. `App` holds this today: the same claim renders an S3 bucket plus an
`EPI` on one cloud and a GCS bucket plus a `GCPWorkloadIdentity` on the other.

{{< callout type="warning" >}}
**A neutral claim is a promise the compositions have to keep, and one is
outstanding.** `SQLInstance` has no GCP implementation — its GCP Composition
deliberately fails evaluation rather than composing nothing. That is the right
failure mode (a claim that cannot be honoured should say so at reconcile time),
but it means "the same claim means the same thing on either cloud" is currently
an aspiration for `SQLInstance` and a fact for `App`. Neutrality at the API
costs implementation work per cloud; skipping it does not make the API less
neutral, it makes it dishonest.
{{< /callout >}}

Where a genuinely cloud-specific knob is unavoidable, it belongs in a
clearly-marked optional sub-block, not spread through the API.

## The test to apply

Before adding an abstraction, ask who reads it:

- **A platform engineer configuring one cloud?** Keep it cloud-shaped and
  honest. Portability buys nothing here and costs indirection.
- **An application developer who should not care?** Keep it neutral, and put
  the cloud-specific part in the composition where it belongs.

An API that looks neutral but is not produces worse failures than one that is
visibly cloud-specific, because the error arrives later and further from its
cause.

## Reading on

- [Cloud support]({{< relref "/docs/platform/foundations/cloud-support.md" >}})
  — the AWS/GCP result of applying this rule, service by service
- [Foundations]({{< relref "/docs/platform/foundations/_index.md" >}}) — how
  the [AWS]({{< relref "/docs/platform/foundations/aws.md" >}}) and
  [GCP]({{< relref "/docs/platform/foundations/gcp.md" >}}) stacks are
  structured, and where a sibling would slot in
- [Developer platform]({{< relref "/docs/platform/developer-platform/_index.md" >}})
  — the neutral APIs that must keep working unchanged
