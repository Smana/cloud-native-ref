---
title: The identity provider is deployable on either cloud, defaulting to AWS
linkTitle: 0024 · IdP per cloud
weight: 240
description: ZITADEL becomes a per-cloud deployable component behind two gates rather than a singleton pinned to aws-0, so a GCP-only platform can authenticate without an AWS cluster running. It stays a singleton — one directory, hosted on the primary cloud, relocating rather than duplicating. Public DNS stays AWS-owned.
lastVerified: 2026-09-01
---

**Status**: Accepted
**Date**: 2026-08-27
**Deciders**: Platform Team
**Supersedes**: [ADR-0022](0022-single-identity-provider-across-clouds.md)

---

## Context

[ADR-0022](0022-single-identity-provider-across-clouds.md) made ZITADEL a
singleton on `aws-0` serving both clusters, and made its host configurable
through an `identity_provider_url` variable. The reasoning was sound and still
is: two instances are two user directories, two session stores, and two sets of
OIDC clients with nothing federating them.

What it did not weigh is what the singleton costs a **GCP-only** platform.
Everything that authenticates through the IdP — Grafana SSO, Headlamp,
OpenWebUI, the Flux UI — depends on an `aws-0` that is up. On a repository whose
whole point is that either cloud can stand on its own, that is a hard dependency
from GCP to AWS for the most basic function a platform has.

It showed up the moment a `gcp-0` validation run was scoped: nothing on that
cluster could authenticate a user without also building an EKS cluster, an
OpenBao, and an AWS network — roughly doubling both the cost and the time of a
run whose subject was GCP.

The singleton was also never quite as enforced as it read. ADR-0022 says moving
the IdP means "changing THREE things together", with nothing able to check that
they agree.

## Decision

**ZITADEL is a per-cloud deployable component. AWS remains the default host.**

`gcp-0` gains `security/gcp-0/zitadel` and its own Flux Kustomization, both off
unless deliberately turned on. Turning it on takes **two gates that must agree**:

| Gate | Where | Effect |
|---|---|---|
| `deploy_identity_provider = true` | `opentofu/gcp/gke/configure` — **derived, not typed, since 2026-09-01** | Derives `identity_provider_url` to `auth.<this cluster's public domain>` |
| `spec.suspend` removed / resumed | `clusters/gcp-0/security/zitadel.yaml` | Flux actually deploys it |

Gate 1 alone points every consumer at a hostname the cluster does not serve.
Gate 2 alone runs an instance nothing is configured to use. Neither can enforce
the other, so `identity_provider_url` is **derived from gate 1** rather than
typed a second time — the literal is what let "which cloud hosts the IdP"
become unanswerable from configuration in the first place.

{{< callout type="info" >}}
**Update (2026-09-01):** gate 1 is no longer typed by hand either. It is derived
from `global.primary_cloud` (see
[ADR-0027]({{< relref "/docs/decisions/0027-primary-cloud-provider.md" >}})) at
every invocation site, so it cannot disagree with the declared topology. Gate 2
remains committed Flux state — Flux never sees Terramate globals, and `postBuild`
substitution cannot reach a Kustomization's own `spec` — so it is verified
instead, by `./scripts/validate-idp-topology.sh` in CI.

"Neither can enforce the other" is now **one derived, one verified**. The
prediction above was borne out twice before that: this record's own gates were
found disagreeing on 2026-08-29, and a dual-cloud bootstrap on 2026-09-01 ran
two directories at once.
{{< /callout >}}

{{< callout type="warning" >}}
**"Deployable on either cloud" is not "running on both at once."** ZITADEL stays a
singleton: one directory, hosted on the primary cloud, which relocates for a
GCP-only platform rather than being duplicated. Two directories running side by
side is not a smaller version of one — a grant means nothing without knowing which
directory issued it. See
[ADR-0027]({{< relref "/docs/decisions/0027-primary-cloud-provider.md" >}}), which
supplies the framing this record's original "one user directory per cloud" phrasing
was reaching for.
{{< /callout >}}

**Public DNS stays AWS-owned.** `auth.<public domain>` on `gcp-0` resolves
through the same Route53 cross-cloud federation as every other public hostname
there ([ADR-0019](0019-cross-cloud-dns-federation.md)). This decision moves
where the IdP *runs*, not where DNS lives.

## What this accepts

**One user directory per cloud, when both host one.** This is the cost
ADR-0022 correctly identified, and it is accepted here rather than solved.

It is acceptable because of what these platforms are: throwaway clusters torn
down after every run, whose ZITADEL bootstraps **empty** each time — the GCP
claim deliberately drops `objectStoreRecovery`, so there is no long-lived
directory to federate and nothing accumulates across rebuilds.

It would **not** be acceptable on a production two-cloud deployment. There, one
instance remains right, and `deploy_identity_provider = false` is the setting
that gives it. The default is unchanged precisely so that nobody gets a second
directory by accident.

## Alternatives considered

**Keep the singleton and require `aws-0` for GCP work.** The status quo. Honest
about federation, but it makes the cheaper cloud's platform untestable on its
own and couples every GCP validation run to an entire second cloud's
infrastructure. The dependency is one-directional and always in the same
direction, which is what made it worth removing.

**Federate two instances.** ZITADEL can act as an external IdP to another
ZITADEL, which would give per-cloud instances *and* one identity. It is a real
option and the right one if these clusters ever stop being disposable — but it
is a standing cross-cloud trust relationship to configure, monitor and rotate,
which is a large amount of machinery for platforms that are deleted daily.

**Deploy the IdP on GCP and consume it from AWS.** Symmetric to the status quo
and no better: it moves the dependency rather than removing it, and points it at
the cloud with less of the platform on it today.

## Consequences

- A GCP-only platform authenticates without any AWS cluster running. That is
  the point.
- `security/base/zitadel` had to become genuinely cloud-neutral to be shared.
  Its Gateway carried four `service.beta.kubernetes.io/aws-load-balancer-*`
  annotations, meaningless on GKE where Cilium's GatewayClass provisions the
  LoadBalancer; they moved to `security/aws-0/zitadel/gateway-patch.yaml`. The
  eighth instance of a cloud-specific value living in a directory named `base/`
  — see [ADR-0023](0023-portable-secret-store-names.md) for the seventh.
- `gcp-0`'s database claim differs from `aws-0`'s in four ways, three of them
  consequences of the fourth: the GCP Composition, no `objectStoreRecovery`, no
  `backup` (blocked by the barman plugin's S3-only CiliumNetworkPolicy), and
  therefore `instances: 1` — the XRD refuses a multi-instance cluster with no
  backup, correctly, since a replica without a backup is a false sense of one.
  **Update (2026-08-30):** that was true until 2026-08-28 and is not any more
  (`security/gcp-0/zitadel/kustomization.yaml` carries the same note). `gcp-0`
  now writes real backups to its own GCS bucket and restores from a frozen
  seed, so only two differences remain structural — the GCP Composition ref
  and the GCS bucket name — while `objectStoreRecovery` and `backup` are both
  now present. `instances: 1` is no longer forced by the absence of a backup
  (the XRD's CEL rule would now allow 2); it is a standing choice because this
  cluster is rebuilt and torn down after every run.
- Two ZITADEL instances mean two sets of OIDC clients. Creating them by hand
  twice is how they drift, so client creation is scripted against the ZITADEL
  API rather than done in the console.
- ADR-0022's `identity_provider_url` variable survives intact; it is now the
  *consume* half of a two-way choice rather than the only half.

## Related

- [ADR-0022](0022-single-identity-provider-across-clouds.md) — superseded by this
- [ADR-0019](0019-cross-cloud-dns-federation.md) — why public DNS stays on Route53
- [ADR-0023](0023-portable-secret-store-names.md) — the secret-store naming this depends on
