---
title: GCP
weight: 30
description: Designed, not yet implemented.
lastVerified: 2026-08-20
---

{{< callout type="warning" >}}
GCP is **not implemented**. This page exists so the documentation has a place
for it, and so nothing above it silently assumes AWS.
{{< /callout >}}

The [three-stage model]({{< relref "/docs/platform/foundations/_index.md" >}})
— network, then security, then Kubernetes — holds for GCP too; only the
stacks that implement it don't exist yet. Three decision records already
frame the design:

- [ADR-0005]({{< relref "/docs/decisions/0005-gke-standard-self-managed-cilium.md" >}}) — GKE Standard with self-managed Cilium
- [ADR-0006]({{< relref "/docs/decisions/0006-nap-computeclass-over-karpenter.md" >}}) — node autoscaling via ComputeClass rather than Karpenter
- [ADR-0007]({{< relref "/docs/decisions/0007-cloud-abstraction-boundaries.md" >}}) — where the platform draws its cloud boundary

The full design lives in the repository at
`docs/superpowers/specs/2026-08-18-gcp-support-design.md`. See also
[Get Started → GCP]({{< relref "/docs/get-started/gcp/_index.md" >}}).
