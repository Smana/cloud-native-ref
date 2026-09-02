---
title: Use Crossplane and OpenTofu, split at the Kubernetes boundary
linkTitle: 0012 · Crossplane + OpenTofu
weight: 120
description: OpenTofu provisions everything below Kubernetes and Crossplane everything applications claim above it, because a claim reconciled by a controller is continuously enforced while a plan is true only at apply time.
lastVerified: 2026-08-21
---

**Status**: Accepted
**Date**: 2026-08-21
**Deciders**: Smana (Platform Owner)
**Related Design**: N/A — records a boundary already implicit in the repository's layout
**Related**: [ADR-0007](0007-cloud-abstraction-boundaries.md) — the audience-based split this ADR's boundary sits above

---

## Context

This platform runs two infrastructure-as-code tools side by side, and neither
is going away: every `terramate script run deploy` still runs the OpenTofu
stacks under `opentofu/`, and every `App`, `SQLInstance`, or `EPI` a tenant
creates still goes through a Crossplane composition. This record exists
because that split needs a stated rule, not because one tool won.

The rule already exists in the repository's own shape, just not written
down. [Foundations]({{< relref "/docs/platform/foundations/_index.md" >}})
describes the three-stage OpenTofu model — network, security, Kubernetes —
as "everything a Kubernetes API server needs to exist *before* Flux can
reconcile anything," ending the Kubernetes stage once "the cluster, plus
enough of a CNI to make nodes `Ready`, with Flux installed and reconciling"
is up. That is the handoff point. Everything after it — every AWS resource
an application or the platform team asks for once the cluster exists — is a
Crossplane claim, applied through Git like any other Flux-reconciled
manifest, not a new OpenTofu stack.

Compositions themselves are not written in this repository. They live in
[`Smana/crossplane-configuration`](https://github.com/Smana/crossplane-configuration)
and ship as a versioned Configuration package that this repository pins in
`infrastructure/base/crossplane/configuration-aws/configuration-packages.yaml`.
That split is a consequence of the boundary this record states, not the
subject of it: what matters here is which tool owns a resource at all, not
where the Crossplane half of that answer is implemented.

---

## Decision Drivers

- **Reconciliation, not expressiveness.** OpenTofu's HCL maps onto a cloud
  provider's API directly and describes a resource's shape more completely
  than a Crossplane claim, constrained as it is to an XRD's schema. That is
  not in dispute, and it is not the axis this decision turns on. What
  differs is what happens after the resource exists: an OpenTofu-managed
  resource is correct as of its last `tofu apply`, and staying correct
  after that needs someone to invoke a check; a Crossplane-managed one is
  watched by a controller that keeps converging it, continuously, without
  anyone invoking anything.
- **Whether a controller can run there at all.** Crossplane's controller is
  a workload; a workload needs a cluster to run on. Asking it to provision
  the cluster it will run on has no starting point.
- **Who is asking for the resource.** OpenTofu stacks are touched by the
  platform engineers who already read `tofu plan` output. Claims are meant
  to be written by tenants and application teams who should not need `tofu`
  access or a shared state file to ask for an IAM role or a bucket.
- **One implementation per resource kind.** Compositions already have a
  release cadence of their own in `Smana/crossplane-configuration`; letting
  the same AWS resource kind be reachable from both tools would mean two
  implementations to keep in sync instead of one plus a version pin.

---

## Considered Options

### Option 1: Split at the Kubernetes boundary

OpenTofu provisions everything up through a running EKS cluster with Cilium
and Flux installed and reconciling — the network, OpenBao and its PKI, and
both stages of EKS bootstrap. From that handoff point on, every further AWS
resource an application or the platform needs — IAM roles, S3 buckets,
Route53 records, database instances — is requested as a Crossplane claim
(`App`, `SQLInstance`, `EPI`) and provisioned by a composition, not a new
OpenTofu stack.

**Pros**:
- The boundary is mechanical, not a judgment call: "does provisioning this
  need a cluster to already exist?" answers itself for any new resource
  kind.
- Claims stay correct under drift with no one rerunning anything — a
  Crossplane-managed resource that changes or disappears outside Git gets
  reconciled back on the controller's next pass.
- Application teams request infrastructure the same namespaced-object way
  they already request compute, instead of learning `tofu` state and a
  second CI pipeline.
- Composes with [ADR-0007](0007-cloud-abstraction-boundaries.md) rather
  than duplicating it: that record splits APIs *within* the Crossplane
  layer by audience (cloud-shaped for the platform team, neutral for
  developers); this record draws the outer edge of that layer, and
  OpenTofu-owned stacks are cloud-shaped platform APIs by construction, so
  the two rules describe different boundaries that do not conflict.

**Cons**:
- Two IaC tools means two mental models, two state models, and two failure
  modes for contributors — see Consequences.
- A resource kind that could plausibly sit on either side of the line still
  needs the rule applied by a person; nothing enforces it automatically.

### Option 2: OpenTofu for everything

Extend the existing stacks, or add new ones, to cover the resources
application teams need too — IAM roles, buckets, database instances — in
place of Crossplane claims for them.

**Pros**:
- One tool, one state model, one CLI surface for every contributor to
  learn.
- No composition split across two repositories, no package version to pin,
  no App Wizard tag to keep in step with it.
- OpenTofu still describes a cloud resource's shape better than a
  Crossplane claim would — the driver above holds regardless of scope.

**Cons**:
- No continuous enforcement: a resource is correct only as of the last
  `tofu apply` run against it, and nothing notices drift in between unless
  someone invokes a check.
- Puts every application team's routine infrastructure request behind
  `tofu plan`/`apply` against a shared state file — the operational surface
  [ADR-0007](0007-cloud-abstraction-boundaries.md) keeps away from
  developer-facing APIs on purpose.
- Every tenant resource request becomes a stack change reviewed and merged
  by the platform team, which removes the point of a self-service claim API.

### Option 3: Crossplane for everything, including cluster bootstrap

Have Crossplane provision the network, OpenBao, and the EKS cluster itself,
so there is a single tool end to end.

**Pros**:
- One tool, one API shape, one mental model for every resource in the
  platform regardless of layer.

**Cons**:
- **Structurally circular.** Crossplane's controller runs as a workload
  inside a Kubernetes cluster; using it to create the cluster it depends on
  to run has no starting point. This platform's own two-stage EKS bootstrap
  is a smaller version of the same problem — even the Helm provider that
  installs Cilium needs the cluster's endpoint to exist at plan time, which
  is why that install cannot happen in the same `tofu apply` that creates
  the cluster. Crossplane cannot do what a same-apply Helm provider
  already cannot.
- Trades away OpenTofu's better resource description for no functional
  gain below Kubernetes: a VPC or an OpenBao EC2 fleet are not claimed by
  anything else and do not drift minute to minute the way a tenant's IAM
  role can, so continuous reconciliation buys nothing there.

---

## Decision Outcome

**Chosen option**: "Option 1 — split at the Kubernetes boundary"

**Rationale**: OpenTofu describes a cloud resource better than a Crossplane
claim does, and that is granted outright rather than argued away — its HCL
maps onto the provider API with no XRD schema standing between the two. It
is also not what this decision turns on. What decides it is what happens
*after* the resource exists: an OpenTofu-managed resource is correct as of
its last apply, and staying correct after that takes someone invoking a
check; a Crossplane-managed one is watched by a controller that keeps
converging it, indefinitely, with nobody invoking anything. Below
Kubernetes, nothing claims or drifts the network, OpenBao, or the cluster
itself fast enough for that difference to matter, so OpenTofu's better
description wins outright and there is no real trade-off to make. Above
Kubernetes, where tenants and the platform team both make ongoing claims
against shared AWS accounts, continuous enforcement is worth more than a
marginally cleaner resource description, and a namespaced claim beats a
shared `tofu` state file as the thing an application team touches directly.
Option 3 does not reach that trade-off at all: a controller cannot
provision the cluster it needs in order to run.

This does not contradict [ADR-0007](0007-cloud-abstraction-boundaries.md).
That record splits APIs by audience *within* the layer Crossplane already
owns — cloud-shaped for the platform team, neutral for developers. This
record draws the boundary of that layer itself, and OpenTofu-owned stacks
are cloud-shaped platform APIs by construction, so the two rules compose:
ADR-0007 governs the shape of an API once it is known to belong to
Crossplane; this ADR decides whether it belongs to Crossplane at all.

---

## Consequences

### Positive

- A new resource kind's tool is decided by one question — does provisioning
  it need a cluster to already exist? — rather than by feel.
- Application teams get self-service infrastructure through the same
  namespaced-object model they use for `App`, with no `tofu` access and no
  shared state file to contend for.
- Crossplane-managed resources stay correct under drift without anyone
  rerunning anything: the controller's reconcile loop is the enforcement
  mechanism, not a periodically invoked command.
- The OpenTofu stacks stay small and platform-owned, reviewed by the people
  who already read `tofu plan` output, instead of growing to cover every
  application's resource requests.

### Negative

- **Two IaC tools means two mental models, two state models, and two
  failure modes for contributors.** An OpenTofu mistake surfaces as a plan
  diff or an `apply` error at the moment someone runs it; a Crossplane
  mistake surfaces later as a claim stuck `Ready=False`, and the root cause
  is as often a missing RBAC grant or activation-policy entry as anything
  wrong in the claim itself.
- **The Crossplane v2 traps this repo has actually hit.** Managed resources
  are namespaced under provider-aws v2.x (`m.upbound.io`), unlike the
  cluster-scoped v1 (`upbound.io`) equivalents — a direct managed resource
  missing `metadata.namespace` fails Flux's dry-run with
  `namespace not specified`. A `ManagedResourceActivationPolicy` gates
  which of a provider's CRDs are installed at all, so a composition
  reaching for a new managed-resource Kind needs its plural CRD name added
  to that policy too, or the symptom is `no matches for kind <Kind>`. And a
  composition writing a third-party Kind — `keda.sh/scaledobjects`,
  `batch/jobs` — needs an aggregate ClusterRole granted explicitly, or the
  XR reconcile loop stalls on
  `Timeout: failed waiting for *unstructured.Unstructured Informer to sync`.
  Source: [`.claude/rules/crossplane-validation.md`](https://github.com/Smana/cloud-native-ref/blob/main/.claude/rules/crossplane-validation.md).
- **The composition split across repositories means two pins move
  together.** Compositions live in
  [`Smana/crossplane-configuration`](https://github.com/Smana/crossplane-configuration),
  not here, so a schema change needs a release there before the pin in
  `infrastructure/base/crossplane/configuration-aws/configuration-packages.yaml`
  can move. The App Wizard clones that same package tag to render its claim
  preview against the API version the cluster actually serves — bumping
  one pin without the other means the wizard describes a schema the
  cluster does not run.

### Neutral

- OpenTofu's own drift check, `terramate script run drift detect`, plans
  every stack and reports divergence without applying anything — but it is
  a command someone or some automation invokes, not a controller watching
  in the background. That distinction, not "OpenTofu is unwatched forever,"
  is the mechanical difference this decision actually turns on.
- A resource kind that a future need places right at the boundary — for
  instance, a database used only by platform infrastructure rather than a
  tenant — still needs the "does it need a cluster first" question answered
  by a person; nothing in either tool infers it from the resource type.

---

## Implementation Notes

The boundary is visible in the repository's layout rather than enforced by
any tool: OpenTofu stacks live under `opentofu/`, one directory per stage,
ordered by each stack's declared `after` dependencies in `stack.tm.hcl`.
Crossplane claims live under tenant- and platform-facing directories such as
`security/base/epis/` and `apps/`, applied by Flux like any other manifest
once the Kubernetes stage hands off. Nothing currently stops a new resource
kind from being modeled in the wrong tool — this record is what a reviewer
checks a new stack or claim against, not a schema constraint either tool
enforces on its own.

The Negative section's Crossplane v2 traps describe how the *cluster*
behaves, not code owned in this repository: compositions themselves are
edited, tested with `task check`, and released from
`Smana/crossplane-configuration`. This repository only pins the resulting
package version and validates claims against that pinned release's XRD
schemas through `./scripts/validate-manifests.sh`.

---

## References

- [Foundations]({{< relref "/docs/platform/foundations/_index.md" >}}) — the
  three-stage OpenTofu model and the exact handoff point to Flux this
  record's boundary is drawn at
- [Foundations → AWS]({{< relref "/docs/platform/foundations/aws.md" >}}) —
  the AWS OpenTofu stacks and what each one owns
- [GitOps]({{< relref "/docs/platform/gitops/_index.md" >}}) — the Flux
  dependency graph Crossplane claims join once the Kubernetes stage hands
  off
- [ADR-0007](0007-cloud-abstraction-boundaries.md) — the audience-based
  split within the layer this record hands to Crossplane
- [Glossary]({{< relref "/docs/reference/glossary.md" >}}) — Claim,
  Composition, Reconciliation, Drift, Managed resource, Configuration
  package
- [`.claude/rules/crossplane-validation.md`](https://github.com/Smana/cloud-native-ref/blob/main/.claude/rules/crossplane-validation.md)
  — the v2 namespacing, activation-policy, and aggregate-ClusterRole traps
- `infrastructure/base/crossplane/configuration-aws/configuration-packages.yaml`
  — the pinned Configuration package
- `apps/platform/app-wizard/app.yaml` — the version-coupling note between
  the package pin and the App Wizard's cloned tag
- [`Smana/crossplane-configuration`](https://github.com/Smana/crossplane-configuration)
  — where compositions are written, tested, and released
