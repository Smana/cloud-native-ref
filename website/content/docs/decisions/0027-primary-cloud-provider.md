---
title: AWS is the primary cloud, and cross-cloud singletons live there
linkTitle: 0027 · Primary cloud
weight: 270
description: Some services cannot sensibly exist twice — one public DNS zone, one identity directory, one federation trust. Naming AWS the primary cloud gives those a defined home, and gives a GCP-only platform a defined way to take it over.
lastVerified: 2026-08-29
---

**Status**: Accepted
**Date**: 2026-08-29
**Deciders**: Platform Team

---

## Context

The platform runs on two clouds, and most of it is genuinely per-cloud: each
cluster has its own network, OpenBao, secret store, state bucket and backup
bucket. Those are copies of one design, and nothing about them is shared.

A few things cannot be copies.

- **Public DNS.** `cloud.ogenki.io` is one zone with one set of nameservers. It
  cannot exist twice.
- **The identity directory.** Two ZITADEL instances mean two user directories, so
  a person's grants on one say nothing about the other.
- **The cross-cloud trust.** GKE workloads reach Route53 by assuming an AWS IAM
  role through an OIDC provider that trusts the GKE issuer
  ([ADR-0019](0019-cross-cloud-dns-federation.md)). That trust is a single object
  and it lives in an AWS account by construction.

These already lived on AWS, but only as an accumulation of individual choices.
Nothing named the pattern, so each one had to be rediscovered — most visibly when
`opentofu/shared/aws-gcp-federation` turned out to be a stack that a GCP deploy
needs and an AWS-only deploy also applies, which reads as an error until you know
why.

The gap showed up again on 2026-08-29. ADR-0024 made ZITADEL per-cloud deployable
and recorded the cost as "one user directory per cloud", which sounds like two
directories running side by side. The actual intent was one directory, hosted on
AWS, that relocates only for a GCP-only platform. With no name for that idea, the
weaker reading won, and a test cluster ended up running two directories with
nobody able to say whether that was the design.

## Decision

**AWS is the primary cloud. Services that cannot sensibly exist twice live
there.**

Every stack and component falls into exactly one of three classes, and the class
determines where it lives:

| Class | Home | Examples |
|---|---|---|
| **Primary-cloud singleton** | the primary cloud | public Route53 zone, ZITADEL, the `aws-gcp-federation` OIDC provider and role |
| **Cloud-agnostic** | neither cloud | Tailscale and the tailnet ACL — a SaaS control plane, in `opentofu/shared/tailscale` |
| **Per-cloud** | every cloud, independently | network, GKE/EKS, OpenBao, secret store, state and backup buckets |

`opentofu/shared/` holds the first two classes, which is why a GCP-only deploy
still applies `aws-gcp-federation`, and why an AWS-only deploy applies it too at
no cost.

**A GCP-only platform makes GCP primary.** This is not a permanent designation of
AWS; it is a designation of *the cloud you are running*. When only GCP runs, the
singletons relocate to it — the case
[ADR-0024](0024-identity-provider-per-cloud.md) opens the IdP gates for. What is
ruled out is the third state: **two clouds running with the singletons
duplicated.** Two identity directories is not a smaller version of one; it is a
different, worse system in which a grant means nothing without knowing which
directory issued it.

**Relocation is an exception, and it is a migration.** Moving a singleton carries
its data — for ZITADEL that is the database seed, the admin credential and the
client secrets, which travel together or the move half-works in silence. It is a
deliberate act with a written procedure, not something that happens as a side
effect of enabling a cluster.

## Consequences

**What gets better.** "Where does this live, and why?" is answerable from the
class, not from history. A new cross-cloud service starts with one question —
singleton, agnostic, or per-cloud? — and the answer places it. The federation
stack's presence in an AWS-only deploy stops looking like a mistake.

**What it costs.** The primary cloud is a dependency for the other one. A GCP
cluster with no AWS account still needs public DNS and the federation trust, so
"GCP-only" means *relocating* the singletons, not doing without them. That
relocation has never been performed end to end; until it has, treat the GCP-only
path as designed rather than proven.

**What it does not change.** Nothing per-cloud. Both clusters keep their own
OpenBao, secret store, state and backups, and neither depends on the other for
them. This decision is only about the handful of things that cannot be two.

## Alternatives considered

**Leave it implicit.** Every choice already pointed at AWS, and the platform
worked. Rejected because the implicit version is what produced two ZITADEL
instances and an unanswerable question about whether that was intended. A pattern
nobody can name is a pattern nobody can apply to the next service.

**Make everything per-cloud, with no singletons.** Genuinely simpler to describe:
each cloud complete and independent. Rejected because it is not achievable for
the actual cases — one public DNS zone cannot become two, and duplicating the
identity directory produces the split-grant problem above. It would trade a
documented dependency for a silent inconsistency.

**Make the platform cloud-symmetric with an external primary.** Move the
singletons somewhere owned by neither cloud, the way Tailscale already is: a
managed DNS provider, a hosted IdP. This is the cleanest answer in principle and
is what a production platform with a real budget would likely do. Rejected here
because it adds a third vendor to a reference platform whose point is to
demonstrate the two clouds, and because the AWS account already exists and costs
nothing extra to hold a hosted zone.

## Related

- [ADR-0024](0024-identity-provider-per-cloud.md) — the IdP as a per-cloud
  deployable component; this ADR supplies the framing its "accepted cost"
  paragraph was reaching for
- [ADR-0019](0019-cross-cloud-dns-federation.md) — the AWS IAM trust that lets
  GKE write to Route53, the clearest example of a primary-cloud singleton
- [ADR-0017](0017-multi-cloud-dns-naming.md) — the naming scheme the single
  public zone carries for both clouds
