---
title: Use Flux for GitOps reconciliation
linkTitle: 0008 · Flux over Argo CD
weight: 80
description: The cluster is reconciled by Flux rather than Argo CD, because dependsOn expresses the platform's layered bootstrap ordering and Flux's controllers are CRDs the platform composes against.
lastVerified: 2026-08-21
---

**Status**: Accepted
**Date**: 2026-08-21
**Deciders**: Smana (Platform Owner)
**Related Design**: N/A — records a choice predating the design workflow

---

## Context

Nothing in this repository is applied by a human or a CI job running
`kubectl apply`. A push pipeline holds credentials, runs the apply, and
leaves the cluster in whatever state the last successful run produced —
drift is invisible until the next deploy silently overwrites it, or
doesn't. A reconciler instead runs inside the cluster, continuously
compares it to Git, and treats drift as the normal input rather than a
special case, which also means CI never needs cluster credentials at all.

That choice, reconcile over push, is not this record — it is the subject
of [The GitOps model]({{< relref "/docs/concepts/gitops-model.md" >}}).
This record is the next one down: which reconciler.

The interesting part of this platform's GitOps setup is not that it syncs,
it is the order in which things become true. Namespaces must exist before
workloads land in them, CRDs before a controller can watch them, Crossplane
must be running before a claim reconciles, and pod identities must exist
before a controller can reach a cloud API. Each of these is a `dependsOn`
edge, and together they form a graph. The constitution gives a five-step
summary of it — foundations, security, infrastructure, observability,
applications — but that summary is explicitly simplified: the real graph,
re-derived from `spec.dependsOn` in every `clusters/aws-0/**/*.yaml`
Kustomization, is wider. Crossplane's install is three sequential
Kustomizations, Karpenter depends on `crds` directly rather than on the
Crossplane chain, and `infrastructure` depends on `karpenter` and
`eks-pod-identities` rather than on `security`. Whatever reconciler runs
this cluster has to express and health-gate a graph of that shape natively,
not approximate it with pipeline step ordering.

---

## Decision Drivers

- **Explicit, health-gated dependency ordering** across a graph deeper than
  a straight-line pipeline — a Kustomization has to wait for another to be
  actually healthy, not just applied.
- **A Kubernetes-native composition surface.** The platform's own Crossplane
  compositions should be able to render the GitOps tool's own objects
  directly, without a translation layer.
- **GitHub App authentication** for pulling this repository, rather than a
  long-lived personal access token.
- **A single-command bootstrap.** The tool that reconciles the cluster
  should itself be installable by the same OpenTofu apply that creates the
  cluster.
- **Active CNCF governance**, so the reconciler and its API are not a
  one-vendor risk.

---

## Considered Options

### Option 1: Flux

Kubernetes-native GitOps toolkit: `GitRepository`/`OCIRepository` sources,
`Kustomization` and `HelmRelease` for reconciliation, wired together with
`dependsOn` and health checks. Installed and lifecycle-managed by the Flux
Operator via a `FluxInstance` custom resource.

**Pros**:
- `dependsOn` plus health checking is a first-class primitive for exactly
  the graph described in Context — not sync-order metadata bolted onto a
  simpler model.
- Flux's reconciliation objects are themselves CRDs, so the platform's own
  Crossplane compositions can render them directly: the `App` claim's
  nested `KVStore` composition renders a `HelmRelease` for the official
  `valkey-helm` chart, the same Kind Flux itself reconciles with.
- Flux Operator + `FluxInstance` install from `opentofu/aws/eks/configure/main.tf`
  (Stage 2) right after Cilium, in the same `terramate script run deploy`
  that creates the cluster — the two-stage EKS bootstrap stays one command.
- GitHub App authentication for pulling this repository.
- CNCF project with active development.

**Cons**:
- No built-in web UI — see Consequences.
- Controller sharding is extra operational surface a simpler push model
  would not have — see Consequences.

### Option 2: Argo CD

Kubernetes-native GitOps continuous delivery tool, centered on the
`Application` CRD: one object per synced path or chart, with sync waves
(ordering by annotation) and a built-in web UI.

**Pros**:
- First-class web UI out of the box for sync status, diffs, and health —
  something this platform runs Headlamp with a dedicated Flux plugin partly
  to compensate for not having.
- Sync waves give ordering across an `Application`'s resources, in the same
  spirit as `dependsOn`.
- Also a CNCF project, with comparable governance and maturity.

**Cons**:
- `Application` is one thin object describing "sync this path" — it is not
  itself the multi-CRD family (`Kustomization`, `HelmRelease`,
  `GitRepository`) that this platform's compositions already render
  directly; adopting Argo CD would mean the platform's own compositions
  target an object model the reconciler doesn't natively speak.
- Sync waves order resources within an `Application` by wave number, not by
  named dependencies with health gating the way `dependsOn` plus Flux's
  Kustomization health checks work across the whole cluster.

### Option 3: Helm + CI push

A CI pipeline runs `helm upgrade`/`kubectl apply` against the cluster on
every merge to `main`. No reconciler runs inside the cluster.

**Pros**:
- Simple mental model: the deploy result is synchronous and visible in the
  pipeline log, not a status you go read later.
- No extra in-cluster component to run or upgrade.

**Cons**:
- CI holds long-lived cluster credentials — an entire class of blast radius
  a reconciler removes by construction.
- Drift is invisible: a hand-edited resource is only caught, and silently
  overwritten, on the next deploy — if there is one.
- No standing dependency graph. The `dependsOn` ordering described in
  Context would have to be hand-sequenced as pipeline steps instead of
  expressed as edges the reconciler itself walks and health-checks.

---

## Decision Outcome

**Chosen option**: "Option 1 — Flux"

**Rationale**: The platform's bootstrap graph is wider and more irregular
than a straight-line pipeline — Crossplane alone is three sequential
Kustomizations, and `infrastructure` depends on `karpenter` and
`eks-pod-identities` rather than `security`. `dependsOn` plus health
checking is built for exactly that shape. Just as importantly, this
platform's own Crossplane compositions already render Flux's objects
directly — the `App` claim's `KVStore` composition emits a `HelmRelease` —
so Flux is not just the reconciler, it is also the object model the rest
of the platform composes against. Installing Flux Operator and
`FluxInstance` from the same OpenTofu Stage 2 that installs Cilium keeps
the whole EKS bootstrap to one command.

Argo CD would also have worked. Its `Application` model and sync waves are
a legitimate, CNCF-governed alternative, and its built-in UI is a genuine
advantage this decision gives up (see Consequences). This is a preference
for the CRD-first composition surface and the ordering primitive it
already needed, not a verdict that Argo CD is deficient.

---

## Consequences

### Positive

- The full dependency graph — Crossplane's three sequential Kustomizations,
  Karpenter's independent branch off `crds`, `infrastructure` forking on
  `karpenter` and `eks-pod-identities` rather than `security` — is enforced
  by the reconciler itself via `dependsOn` and health checks, not by
  pipeline step ordering that has to be kept in sync by hand.
- The platform's Crossplane compositions render Flux's own CRDs (for
  example `HelmRelease` from the `KVStore` composition) without a
  translation layer.
- Flux Operator and `FluxInstance` install from the same OpenTofu Stage 2
  step that installs Cilium, so the whole EKS bootstrap is one
  `terramate script run deploy`.
- GitHub App authentication replaces a long-lived personal access token for
  pulling this repository.

### Negative

- **Controller sharding is a real operational trap.** The `FluxInstance`
  configures one extra shard (`sharding.fluxcd.io/key: apps`), carried by
  the `tooling` and `apps` Kustomizations and everything they create. A
  `GitRepository`/`HelmRepository` placed under an app-owned directory
  instead of `flux/sources/` inherits that label the same way any other
  resource there does — the default shard's `source-controller`/
  `helm-controller` then can't see it, and a completely unrelated
  `HelmRelease` on the default shard fails with "source not found", far
  from the actual cause, while the Source itself reports `Ready`.
  *Mitigation*: every `GitRepository`/`HelmRepository` in this repository
  lives under `flux/sources/`, never under an app-owned directory.
- **Flux has no built-in UI.** The platform runs Headlamp partly to
  compensate — its `HelmRelease` installs a dedicated
  `headlamp-plugin-flux` init container alongside the cert-manager and
  AI-assistant plugins, specifically to surface Flux state in a web UI Flux
  itself does not provide.

### Neutral

- The costs of reconciling over pushing — everything becomes asynchronous
  (a status to go read, not a deploy result), Git becomes the bottleneck
  for urgent change, secrets cannot live in Git — are costs of the reconcile
  model in general. Argo CD would have accepted the same trade-offs; they
  are not specific to choosing Flux over Argo CD.

---

## Implementation Notes

Flux Operator and `FluxInstance` install as two sequential `helm_release`
resources in `opentofu/aws/eks/configure/main.tf` (Stage 2), after Cilium is
up and kube-proxy is disabled. `FluxInstance`'s values, including the
`sharding.key: sharding.fluxcd.io/key` / `shards: ["apps"]` configuration,
live in `opentofu/aws/eks/init/helm_values/flux-instance.yaml`.

The dependency graph itself is not hand-maintained prose — it is
re-derived from `spec.dependsOn` in every `clusters/aws-0/**/*.yaml`
Kustomization. See [GitOps]({{< relref "/docs/platform/gitops/_index.md" >}})
for its current shape, and
[Repository Structure]({{< relref "/docs/platform/gitops/repository-structure.md" >}})
for the `ArtifactGenerator`/`ExternalArtifact` split and the sharding
mechanism referenced above.

---

## References

- [The GitOps model]({{< relref "/docs/concepts/gitops-model.md" >}}) —
  reconcile versus push, and why the dependency graph is the design
- [GitOps]({{< relref "/docs/platform/gitops/_index.md" >}}) — the
  dependency hierarchy re-derived from the cluster's own manifests
- [Repository Structure]({{< relref "/docs/platform/gitops/repository-structure.md" >}})
  — controller sharding and the `ArtifactGenerator`/`ExternalArtifact` split
- `opentofu/aws/eks/configure/main.tf` — Flux Operator and `FluxInstance`
  installed in Stage 2, right after Cilium
- `tooling/base/headlamp/helmrelease.yaml` — the `headlamp-plugin-flux`
  init container
- [Argo CD core concepts](https://argo-cd.readthedocs.io/en/stable/core_concepts/)
  — the `Application` CRD
- [Argo CD sync waves](https://argo-cd.readthedocs.io/en/stable/user-guide/sync-waves/)
  — annotation-based ordering
