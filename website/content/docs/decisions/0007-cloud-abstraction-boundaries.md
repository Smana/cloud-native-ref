---
title: Cloud abstraction boundaries — cloud-shaped platform APIs, neutral developer APIs
linkTitle: 0007 · Cloud boundaries
weight: 70
description: Platform-facing infrastructure APIs stay cloud-shaped per provider, while developer-facing APIs like App stay cloud-neutral, splitting the abstraction by audience instead of forcing one shape on both.
lastVerified: 2026-08-30
---

**Status**: Accepted
**Date**: 2026-08-18
**Deciders**: Smana (Platform Owner)
**Related Design**: [GCP Support — Dual-Cloud Platform Design](https://github.com/Smana/cloud-native-ref/blob/main/docs/superpowers/specs/2026-08-18-gcp-support-design.md)

---

## Context

The platform is adding GCP as a second maintained cloud. Roughly fifteen workstreams are
affected (see the [design](https://github.com/Smana/cloud-native-ref/blob/main/docs/superpowers/specs/2026-08-18-gcp-support-design.md) scope split), and almost every one of them raises the
same question in a different costume: **do we build one cloud-neutral API, or two honest
cloud-specific ones?**

Getting this wrong in either direction is expensive:

- Over-abstracting produces APIs whose most important field is a free-form cloud-specific blob.
  The abstraction then costs indirection without buying portability — and every new provider
  feature needs a two-cloud design before anyone can use it.
- Under-abstracting means an `App` manifest written for the AWS cluster cannot be applied to the
  GCP cluster, which removes most of the reason to run two clouds.

Rather than relitigate this per workstream, this ADR sets the rule.

The `EPI` composition makes the tension concrete. `EPI` (EKS Pod Identity) has nine claim
manifests in `security/base/epis/`, is consumed internally by the `App` and `SQLInstance`
compositions, and its central field is `spec.policyDocument` — inline AWS IAM JSON. There is no
neutral form of that field. GCP's equivalent is a list of predefined roles and/or a custom role's
permission list. Any "cloud-agnostic identity" API would carry both shapes and pick one at
render time, which is two APIs wearing one name.

---

## Decision Drivers

- **Who reads the API.** Platform engineers already know which cloud they are configuring;
  application developers should not have to.
- **Where portability actually pays.** A portable `App` claim is valuable. A portable
  `policyDocument` is meaningless — the permissions themselves are cloud-specific.
- **Honesty over uniformity.** An API that looks neutral but is not causes worse errors than one
  that is visibly cloud-shaped.
- **Migration cost.** The `xplane-*` prefix is load-bearing for IAM scoping, and renaming a
  Crossplane managed resource is delete-and-create against live cloud IAM.
- **Cost of the next cloud.** The rule should not need rewriting at cloud number three.

---

## Considered Options

### Option 1: Asymmetric — cloud-shaped platform APIs, neutral developer APIs

Draw the line at the audience. APIs consumed by the platform team stay cloud-specific and
honest (sibling XRDs per cloud). APIs consumed by application developers are cloud-neutral, with
provider-specific knobs confined to a clearly-marked optional sub-block.

**Pros**:
- Portability is bought exactly where it is worth paying for: developer-facing claims.
- Platform-facing APIs stay honest — no pretending IAM JSON and GCP role bindings are one thing.
- No rename of `EPI` and therefore no delete-and-create against live IAM roles.
- The escape hatch keeps provider features reachable without polluting the common surface.

**Cons**:
- Two rules to remember instead of one, and the boundary needs judgement for APIs with mixed
  audiences.
- Compositions consuming platform APIs must branch internally on target cloud.

### Option 2: Neutral everywhere

One XRD per concept, cloud selected by `EnvironmentConfig` / `ProviderConfig`. `EPI` becomes
`WorkloadIdentity`; `spec.s3Bucket` becomes `spec.objectStore`.

**Pros**:
- One API surface, uniform rule, smallest thing to explain.
- Every manifest is portable in principle.

**Cons**:
- The abstraction leaks at the field that matters most (`policyDocument`), so it is neutral in
  name only.
- Renames nine `EPI` manifests and the `xplane-*` resources they own — delete-and-create against
  live IAM roles for no functional gain.
- Every provider-specific feature becomes a two-cloud design exercise before anyone can use it.

### Option 3: Cloud-shaped everywhere

Sibling APIs at every layer: `EPI` + `GCPWorkloadIdentity`, `spec.s3Bucket` + `spec.gcsBucket`.

**Pros**:
- Maximum honesty and zero migration; each API is exactly its cloud's model.
- Simplest compositions — no branching, no merged schemas.

**Cons**:
- An `App` claim becomes cloud-bound, which forfeits the main benefit of running two clouds.
- Application developers are forced to learn cloud specifics to request a bucket.

---

## Decision Outcome

**Chosen option**: "Option 1 — asymmetric, split by audience"

**Rationale**: The audience boundary is the one that tracks where portability has value.
`EPI` is written by platform engineers who already know they are configuring AWS, and its central
field has no neutral form — so a cloud-shaped sibling API costs nothing and lies about nothing.
`App` is written by application developers, and a portable `App` claim is close to the whole point
of maintaining two clouds — so it gets a neutral surface with provider knobs quarantined in
optional `aws {}` / `gcp {}` blocks.

**The rule**: *cloud-shaped platform APIs, neutral developer APIs, with provider-specific fields
confined to a named optional sub-block rather than spread across the schema.*

A finding from designing the GCP identity API supports this more than expected. Modern GCP Workload Identity
Federation allows binding an IAM policy **directly to the Kubernetes ServiceAccount principal** —
`principal://iam.googleapis.com/projects/N/locations/global/workloadIdentityPools/PROJECT.svc.id.goog/subject/ns/NS/sa/KSA`
— with no Google service account and no `iam.gke.io/gcp-service-account` annotation. That is
structurally the *same* model as EKS Pod Identity: bind an identity to the (namespace,
ServiceAccount) pair from outside, leaving nothing on the ServiceAccount. So the two sibling XRDs
end up near-isomorphic in shape while remaining honest about their differing permission models.
Sibling APIs did not force conceptual divergence; it only declined to hide the one field that
genuinely differs.

---

## Consequences

### Positive

- `EPI` and its nine claim manifests are untouched. No delete-and-create against live IAM.
- [ADR-0002](0002-eks-pod-identity-over-irsa.md) stays valid, with its scope narrowed to AWS.
- Developer-facing claims stay portable, so the dual-cloud investment is visible to app teams.
- The rule is reusable: it decides workstreams 8 through 13 without fresh debate.

### Negative

- `App`/`SQLInstance` compositions branch internally on target cloud, adding conditional
  rendering paths that must both be covered by `main_test.k`.
- Renaming `spec.s3Bucket` to `spec.objectStore` is a **breaking XRD change**, requiring
  migration of examples, the App Wizard form, and any live claims.
  - *Mitigation*: sequenced as its own roadmap workstream, not smuggled into a cluster spec.
- Two identity XRDs mean two sets of documentation and tests.

### Neutral

- The "which cloud am I" signal that compositions branch on has to come from somewhere —
  most likely a per-cloud `EnvironmentConfig` (the AWS one is already
  `EnvironmentConfig/eks-environment`, carrying `accountId`, `oidcArn`, `vpcId`). The exact
  mechanism is settled by the identity slice, not here.

---

## Implementation Notes

Applying the rule across the roadmap:

| Workstream | Audience | Treatment |
|------------|----------|-----------|
| `EPI` / `GCPWorkloadIdentity` | platform | sibling, cloud-shaped |
| `App.spec.objectStore` | developer | neutral + `aws {}` / `gcp {}` escape hatch |
| `SQLInstance` backups | developer | neutral surface; backend selected by composition |
| Node autoscaling (`NodePool` vs `ComputeClass`) | platform | sibling, cloud-shaped ([ADR-0006](0006-nap-computeclass-over-karpenter.md)) |
| Cilium Helm values | platform | sibling files, forked ([ADR-0005](0005-gke-standard-self-managed-cilium.md)) |
| Gateway / LoadBalancer annotations | platform | sibling, cloud-shaped |
| StorageClass names | platform | sibling, cloud-shaped |

`xplane-*` naming is unchanged and applies to both clouds' managed resources — it is a
constitution requirement, not an AWS detail.

---

## References

- [Platform Constitution]({{< relref "/docs/reference/platform-constitution.md" >}}) — `xplane-*` naming, KCL patterns, security defaults
- [ADR-0002: EKS Pod Identity over IRSA](0002-eks-pod-identity-over-irsa.md) — scope narrowed to AWS by this ADR
- [ADR-0005](0005-gke-standard-self-managed-cilium.md), [ADR-0006](0006-nap-computeclass-over-karpenter.md)
- [GKE Workload Identity Federation](https://docs.cloud.google.com/kubernetes-engine/docs/how-to/workload-identity) — direct KSA principal binding
- [GCP support design](https://github.com/Smana/cloud-native-ref/blob/main/docs/superpowers/specs/2026-08-18-gcp-support-design.md) — the fifteen workstreams this rule applies to
- `EPI` composition and `App` composition: both in [`Smana/crossplane-configuration`](https://github.com/Smana/crossplane-configuration),
  pinned here via `infrastructure/base/crossplane/configuration-aws/configuration-packages.yaml`
