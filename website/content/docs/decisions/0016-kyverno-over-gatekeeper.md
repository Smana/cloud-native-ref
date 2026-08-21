---
title: Use Kyverno for admission policy
linkTitle: 0016 · Kyverno admission
weight: 160
description: Admission control runs on Kyverno rather than OPA Gatekeeper or Pod Security Admission alone, for YAML policies and mutation alongside validation — accepting that the enforced policy set currently comes from the upstream chart's defaults.
lastVerified: 2026-08-21
---

**Status**: Accepted
**Date**: 2026-08-21
**Deciders**: Smana (Platform Owner)
**Related Design**: N/A — records a choice predating the design workflow

---

## Context

The constitution's security defaults — `runAsNonRoot`, a read-only root
filesystem, no privilege escalation, capabilities dropped to `[ALL]`,
`seccompProfile.type: RuntimeDefault` — are written down in the [Platform
Constitution's security context
rule]({{< relref "/docs/reference/platform-constitution.md#33-security-context" >}}).
A rule that lives only in a document is a hope, not a gate: something
has to act on a manifest that violates it. `./scripts/validate-manifests.sh`
already audits the *rendered* bundle with Polaris before merge, but that is
a pre-merge check against Git content — it says nothing about a `kubectl
apply` run from a live session, or a Pod spec a controller generates at
runtime rather than one anyone hand-wrote and committed.

Two `HelmRelease`s in `security/base/kyverno/` close that gap: `kyverno`,
the admission-webhook controller, and `kyverno-policies`, the upstream
pack that implements the Kubernetes Pod Security Standards as
`ClusterPolicy` resources. Both are pinned to the same chart version,
sourced from a shared `HelmRepository`
(`flux/sources/helmrepo-kyverno.yaml`); the controller sets `crds.install:
false`, and its CRDs instead come from a `GitRepository` pin
(`flux/sources/gitrepo-kyverno.yaml`, tag `v1.18.2`) applied by
`crds/base/kustomization-kyverno.yaml` — one entry among a dozen siblings
in the `crds` Kustomization (`clusters/mycluster-0/crds.yaml`) that
installs every CRD-owning component's CRDs ahead of the controller that
consumes them.

Kyverno is documented at [Zero-Trust]({{< relref "/docs/concepts/zero-trust.md" >}})
as one of the platform's "enforced, not documented" gates — it "rejects
non-compliant workloads at admission" — and that is a materially different
guarantee from a CI check: CI only ever sees what is in Git before merge,
while an admission webhook sees every write the API server accepts,
regardless of where it originated.

---

## Decision Drivers

- **Enforcement at the API server, not only in CI.**
  `./scripts/validate-manifests.sh` runs against rendered Git content; it
  has no visibility into a manifest applied directly or a Pod spec a
  controller generates at runtime.
- **Policy language reviewability.** A policy written as a Kubernetes
  object the same people already review `Deployment`s and
  `CiliumNetworkPolicy`s in, rather than a second language only a subset
  of reviewers know.
- **Beyond validate-only.** A validating-only gate can reject a
  noncompliant workload but not fix it, and cannot generate a companion
  resource a policy implies should exist.
- **CRD management consistency.** Every CRD-owning component in this
  repository installs its CRDs from `crds/base/`, ahead of the controller
  that consumes them — the same ordering this decision has to fit.

---

## Considered Options

### Option 1: Kyverno

`kyverno` (the controller) plus `kyverno-policies` (the upstream Pod
Security Standards pack), both `HelmRelease`s in `security/base/kyverno/`.

**Pros**:
- Policies are Kubernetes-native YAML — a `ClusterPolicy` resembles the
  objects it governs, reviewable by anyone who already reads a
  `Deployment` or `CiliumNetworkPolicy` manifest.
- Kyverno validates, **mutates, and generates**; Pod Security Admission
  only validates. A policy can rewrite a noncompliant field instead of
  only rejecting the request, or create a companion resource a rule
  implies should exist.
- `kyverno-policies` ships the Pod Security Standards as `ClusterPolicy`
  resources already, with no local authoring needed to get the baseline
  running.

**Cons**:
- An admission webhook sits in the request path for every matching API
  call; see Consequences.
- `kyverno-policies` installs with `values: {}` here, deferring policy
  selection to the chart; see Consequences.

### Option 2: OPA Gatekeeper

The other general-purpose Kubernetes admission controller, policies
written in Rego and packaged as `ConstraintTemplate`/`Constraint` pairs.
Not present anywhere in this repository.

**Pros**:
- Also a mature, widely deployed CNCF admission controller with a large
  policy library (Gatekeeper library).
- OPA's Rego engine is shared with other policy surfaces outside
  Kubernetes, which can be an advantage where the same team already
  writes Rego elsewhere.

**Cons**:
- Policies are Rego, a purpose-built logic language distinct from the
  YAML every other manifest in this repository is written in — a second
  language for whoever reviews a policy, on top of Kubernetes YAML and
  KCL (compositions) they already need.
- Validates only; no mutation, no resource generation — a noncompliant
  request is rejected, not corrected.

### Option 3: Pod Security Admission alone

Kubernetes' built-in, in-tree admission controller: a namespace label
selects `privileged`/`baseline`/`restricted`, no separate controller to
run.

**Pros**:
- No extra component: no `HelmRelease`, no webhook pods, no chart to
  version.
- No webhook in the request path — enforcement is done inside the API
  server process itself.

**Cons**:
- Covers only the Pod Security Standards' fixed three profiles; nothing
  outside `Pod`-shape checks — no rule for, say, requiring an
  `EKSPodIdentity` label or restricting an image registry.
- Validate-only, same as Gatekeeper: rejects, cannot mutate or generate.
- No custom policy authoring at all — the enforced ruleset is exactly the
  three built-in profiles, with no room to grow.

### Option 4: Native `ValidatingAdmissionPolicy` (CEL, in-tree)

Kubernetes' CEL-based, in-tree admission policy mechanism — no webhook,
no extra pods. Present in this repository exactly once, and not as the
platform's policy engine: `infrastructure/base/envoy-gateway/helmrelease.yaml`
notes that the `gateway-api` chart's own bundled CRDs ship a
`safe-upgrades` `ValidatingAdmissionPolicy` that refuses CRD downgrades,
which conflicts with this platform's separately pinned Gateway API CRDs
and is why that chart's `crds: Skip` install mode is set. That is a
CRD-protection policy shipped by an upstream chart, unrelated to workload
security policy, and `envoy-gateway` itself is an opt-in component wired
only into the LLM platform's cluster directory
(`clusters/mycluster-0-llm-platform/`), not the default cluster.

**Pros**:
- No webhook in the request path at all — the check runs inside the API
  server via a compiled CEL expression, removing the failure mode where a
  webhook with no live endpoint blocks writes.
- No extra controller, no chart, no version to track.

**Cons**:
- CEL is its own expression language to write and review, with no
  mutation or resource-generation capability — closer to Option 3's
  validate-only ceiling than to Kyverno's.
- Was not viable at the time this platform's admission story was built
  out; see Consequences and Implementation Notes for where this stands
  today.

---

## Decision Outcome

**Chosen option**: "Option 1 — Kyverno"

**Rationale**: The deciding factor is not any single feature but the
combination the constitution's security defaults need: something that
runs at the API server rather than only in CI, is authored in a language
the same reviewers who read the rest of this repository's YAML already
know, and can do more than reject a bad request — the `App` composition
and other platform-generated objects benefit from mutation and generation,
not only validation. Gatekeeper matches the enforcement point but costs a
second policy language. Pod Security Admission and native
`ValidatingAdmissionPolicy` both avoid the webhook cost entirely, but
neither goes past validate-only, and PSA's ruleset cannot grow beyond its
three built-in profiles. Kyverno is the only option that clears all four
drivers at once — at the accepted cost of a webhook in the request path,
recorded below rather than hidden.

---

## Consequences

### Positive

- Policies are Kubernetes-native YAML, reviewed the same way every other
  manifest in this repository is reviewed — no Rego, no CEL, for anyone
  auditing what a `ClusterPolicy` actually does.
- Kyverno can mutate and generate, not only validate — a capability
  neither Gatekeeper, Pod Security Admission, nor native
  `ValidatingAdmissionPolicy` offers on its own.
- The Pod Security Standards baseline ships from `kyverno-policies` as
  `ClusterPolicy` resources with no local policy authoring required to
  get it running.
- CRD lifecycle matches every other CRD-owning component: `crds.install:
  false` on the controller, the CRDs applied from `crds/base/` ahead of
  it.

### Negative

- **`kyverno-policies` installs with `values: {}`
  (`security/base/kyverno/helmrelease-policies.yaml`).** No policy
  selection, no audit-versus-enforce override — the enforced `ClusterPolicy`
  set, and whether each one runs in `audit` or `enforce` mode, comes
  entirely from the chart's own defaults. This is a deliberate deferral
  recorded here as an accepted trade-off, not an oversight: the platform
  gets the Pod Security Standards baseline running with zero local policy
  authoring, at the cost of not having chosen, or even enumerated, which
  policies are actually active or in which mode.
  - *Mitigation*: none today. Reviewing the chart's default values for
    the pinned version and pinning the ones this platform actually wants
    is the natural next step, not yet taken.
- **An admission webhook sits in the request path for every matching API
  call, and a failed webhook can block writes.** This is not
  hypothetical here: `eks-prepare-destroy.sh` has to explicitly disable
  "Kyverno's and the Cilium operator's blocking admission webhooks"
  before a teardown, because once their pods are evicted with the nodes,
  every subsequent delete would otherwise fail against a webhook with no
  live endpoint
  ([teardown docs]({{< relref "/docs/get-started/aws/teardown.md" >}})).
  The same class of failure — a webhook pod down, unreachable, or
  overloaded — can block ordinary writes outside a teardown too.
  - *Mitigation*: none automated beyond the teardown script's explicit
    disable step; day-to-day operation relies on the webhook staying
    healthy.
- **Native `ValidatingAdmissionPolicy` has since become a viable
  alternative for at least the validate-only slice of this problem**, and
  would remove the webhook-in-the-path failure mode entirely for
  whatever it covers. It is not adopted here; see Implementation Notes
  for how that reconsideration is scoped.

### Neutral

- Kyverno's controller and its policy pack are two separate `HelmRelease`s
  sharing one chart family and one `HelmRepository`, versioned together —
  a version bump touches both files, not one.
- The CRD/controller split (`crds/base/kustomization-kyverno.yaml` pulling
  from a `GitRepository` pin, the controller itself from a `HelmRepository`
  pin) means two independent version references have to be read to know
  what is actually installed — the chart version in the `HelmRelease` and
  the tag in `flux/sources/gitrepo-kyverno.yaml`.

---

## Implementation Notes

`security/base/kyverno/` holds both `HelmRelease`s:
`helmrelease-controller.yaml` (`crds.install: false`,
`fullnameOverride: kyverno`) and `helmrelease-policies.yaml`
(`values: {}`). Both reference the `kyverno` `HelmRepository`
(`flux/sources/helmrepo-kyverno.yaml`). The controller's CRDs come from
the `kyverno` `GitRepository` (`flux/sources/gitrepo-kyverno.yaml`),
applied by `crds/base/kustomization-kyverno.yaml`, itself one resource in
the `crds` Kustomization (`clusters/mycluster-0/crds.yaml`) that runs
ahead of `security` in the Flux dependency graph.

Turning `kyverno-policies`'s `values: {}` into a chosen, reviewed policy
set — rather than whatever the pinned chart version defaults to — is the
natural next step this record leaves open; it has not been done.

Revisiting native `ValidatingAdmissionPolicy` for the parts of this
policy set that are pure validation (no mutation, no generation) is a
future reconsideration, not a rejection: the option did not exist as a
mature, in-tree mechanism when this platform's admission story was first
built out, and adopting it now would be a scoped follow-up — replacing
the validate-only subset of `kyverno-policies`'s coverage, not the whole
of Kyverno, since mutation and generation still need a controller.

---

## References

- [Policies]({{< relref "/docs/platform/security/policies.md" >}}) — how
  the platform implements the constitution's admission, network, and pod
  security rules
- [Zero-Trust]({{< relref "/docs/concepts/zero-trust.md" >}}) — Kyverno
  admission listed among the platform's "enforced, not documented" gates
- [Teardown]({{< relref "/docs/get-started/aws/teardown.md" >}}) — the
  concrete case of Kyverno's blocking admission webhook needing an
  explicit disable step before cluster teardown
- [Gateway API]({{< relref "/docs/platform/networking/gateway-api.md" >}}) —
  the `allow-gateway-l7-proxy` policy scoped by namespace specifically so
  it does not also open up unrelated pods like Kyverno's admission
  webhook
- `security/base/kyverno/helmrelease-controller.yaml` — the controller
  `HelmRelease`, `crds.install: false`
- `security/base/kyverno/helmrelease-policies.yaml` — the
  `kyverno-policies` `HelmRelease`, `values: {}`
- `crds/base/kustomization-kyverno.yaml` — the CRD Kustomization sourced
  from the `kyverno` `GitRepository`
- `flux/sources/gitrepo-kyverno.yaml`, `flux/sources/helmrepo-kyverno.yaml`
  — the Git and Helm source pins
- `infrastructure/base/envoy-gateway/helmrelease.yaml` — the one
  repository reference to `ValidatingAdmissionPolicy`, a CRD-protection
  policy shipped by the `gateway-api` chart, unrelated to workload
  security policy
- [Platform
  Constitution]({{< relref "/docs/reference/platform-constitution.md#33-security-context" >}})
  §3.3 — the security-context baseline this admission layer enforces
- [Kyverno documentation](https://kyverno.io/docs/) — validate, mutate,
  and generate policy types
- [OPA Gatekeeper documentation](https://open-policy-agent.github.io/gatekeeper/website/docs/)
  — the Rego-based alternative
- [Kubernetes ValidatingAdmissionPolicy](https://kubernetes.io/docs/reference/access-authn-authz/validating-admission-policy/)
  — the native, in-tree CEL mechanism
