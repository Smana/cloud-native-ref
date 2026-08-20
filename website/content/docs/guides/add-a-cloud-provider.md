---
title: Add a cloud provider
weight: 30
description: ADR-0007's rule made operational — what a new provider must implement, and what must not change.
lastVerified: 2026-08-20
---

The platform runs on AWS and is designed so a second cloud is an addition
rather than a rewrite. What makes that possible is a single rule, and the
discipline to apply it consistently.

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

Each gets its own OpenTofu stack and its own section in the documentation.
The GCP design is worked through in
`docs/superpowers/specs/2026-08-18-gcp-support-design.md`, and three decision
records already frame it:
[ADR-0005]({{< relref "/docs/decisions/0005-gke-standard-self-managed-cilium.md" >}}),
[ADR-0006]({{< relref "/docs/decisions/0006-nap-computeclass-over-karpenter.md" >}}),
[ADR-0007]({{< relref "/docs/decisions/0007-cloud-abstraction-boundaries.md" >}}).

## What gains a sibling, not a field

When an API is genuinely cloud-shaped, add a **sibling XRD** rather than a
discriminated union.

`EPI` is the clearest case. Its central field is inline AWS IAM JSON. GCP's
equivalent is a list of predefined roles or a custom role's permissions.
There is no neutral form of that field, and an API carrying both shapes and
choosing at render time is two APIs sharing a name — with worse error
messages than either would have alone.

So: `EPI` for AWS, a sibling for GCP, both consumed internally by the
developer-facing compositions.

## What must not change

`App` and `SQLInstance` claims are developer-facing and stay neutral. The
same claim should mean the same thing on either cloud.

That does not mean nothing underneath changes — the S3 bucket becomes a GCS
bucket and the IAM role becomes a workload identity binding. It means the
*claim* does not, so an application team's manifests are not a per-cloud
artifact.

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

- [Foundations]({{< relref "/docs/platform/foundations/_index.md" >}}) — how
  the AWS stacks are structured, and where a sibling would slot in
- [Developer platform]({{< relref "/docs/platform/developer-platform/_index.md" >}})
  — the neutral APIs that must keep working unchanged
