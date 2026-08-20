---
title: Architecture
weight: 10
description: The platform in three bands — cloud managed services, the cluster that consumes them, and the applications on top.
lastVerified: 2026-08-20
---

The platform is best read in three bands, from the cloud account inwards.

![Platform architecture: AWS managed services on the left, the EKS cluster in four tiers in the centre, and applications and data stores on the right](/images/diagrams/platform-overview.svg)

## The three bands

**Cloud managed services.** Route 53, load balancers, IAM, S3, KMS. The
platform provisions these through Crossplane rather than clicking them into
existence, but it deliberately leans on managed services for the things a
cloud does well — DNS, object storage, key management. Nothing here is
exotic; the set was chosen so that a second cloud can offer equivalents.

**The cluster.** EKS, with Cilium as the CNI and kube-proxy replacement on
nodes that Karpenter provisions on demand. Above the datapath sit four
tiers: GitOps and composition (Flux, Crossplane), compute and networking
(Cilium, Gateway API, ExternalDNS, Karpenter, KEDA), security and identity
(External Secrets, cert-manager, Kyverno, ZITADEL), and observability
(VictoriaMetrics, VictoriaLogs, VictoriaTraces, Grafana).

**Applications and data.** The workloads a developer actually ships, plus
the PostgreSQL, Valkey and S3 instances the compositions provision for
them. The self-hosted LLM platform lives here too, and is off by default.

## Why it is shaped this way

Three decisions do most of the work, and each has its own page:

- **Everything is reconciled, not deployed.** No human and no CI job runs
  `kubectl apply` against this cluster. See
  [the GitOps model]({{< relref "/docs/concepts/gitops-model.md" >}}).
- **Infrastructure is requested through the Kubernetes API.** A developer
  asks for a database with a claim, not a ticket. See
  [progressive complexity]({{< relref "/docs/concepts/progressive-complexity.md" >}}).
- **Access is denied by default and granted explicitly**, at the network,
  the identity and the secret. See
  [zero trust]({{< relref "/docs/concepts/zero-trust.md" >}}).

## Where the boundary between clouds falls

The platform runs on AWS today and is designed for a second cloud. The line
is drawn deliberately, and it is not where people usually put it:
platform-facing APIs stay cloud-shaped and honest, while developer-facing
APIs stay cloud-neutral. An `App` claim should mean the same thing on any
cloud; an IAM policy document should not pretend to.

That rule is set out in
[ADR-0007]({{< relref "/docs/decisions/0007-cloud-abstraction-boundaries.md" >}}),
and it is why the documentation splits where it does: infrastructure
bootstrap branches per provider, everything from the CNI upward does not.

## Reading on

The mechanisms behind each band are documented under
[Platform]({{< relref "/docs/platform/_index.md" >}}) — one section per
domain, each describing what actually runs rather than what was planned.
