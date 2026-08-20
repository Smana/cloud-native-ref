---
title: GitOps
weight: 20
description: What GitOps means here, why Flux, and the dependency hierarchy re-derived from the cluster's own manifests.
lastVerified: 2026-08-20
---

Once [Foundations]({{< relref "/docs/platform/foundations/_index.md" >}})
hands off a cluster with Flux installed and reconciling, everything else in
this repository — infrastructure, security, observability, tooling,
applications — is described in Git and applied by Flux, never by a human or
a CI job running `kubectl apply`.

## What is GitOps

- **Git is the source of truth.** The desired state of the cluster is
  whatever is committed to `main`, not whatever is currently running.
- **Controllers reconcile continuously**, not on a one-shot deploy — drift
  gets corrected on the next sync interval, not just noticed.
- **Declarative, not imperative.** Manifests describe the end state; nothing
  in this repository is a step-by-step script for reaching it.
- **The audit trail is Git history** — every change to the cluster has a
  commit, an author, and (via required PR review) an approval.
- **Disaster recovery is pointing a fresh cluster's Flux at the same Git
  path** — not replaying a runbook.

## Why Flux

- **Kubernetes-native** — CRDs and controllers, not an external service
  polling the cluster from outside.
- **Built-in dependency management** (`dependsOn`, see below) and health
  checking — a Kustomization can wait for another to actually be healthy,
  not just applied.
- **GitHub App authentication** rather than a long-lived personal access
  token for pulling this repository.
- **CNCF project**, actively developed, with the Flux Operator this repository
  uses for lifecycle management of Flux itself.

## The dependency hierarchy

This is re-derived from `spec.dependsOn` in every `clusters/mycluster-0/**/*.yaml`
Kustomization — not carried over from an earlier description of it — because
the shape has changed more than once: Crossplane's install is now three
sequential Kustomizations instead of one, Karpenter is not gated behind
Crossplane at all, and Flux's own notification/observability/preview wiring
depends directly on Security in parallel with everything else. The opt-in
`llm-platform` umbrella (see [Repository Structure]({{< relref "/docs/platform/gitops/repository-structure.md" >}}))
sits outside this graph entirely.

**The spine**, one Kustomization deep at each step:

```
namespaces → crds → crossplane-controller → crossplane-providers
           → crossplane-configuration → eks-pod-identities → security
```

`crds` also has a second, independent consumer — `karpenter` depends on
`crds` directly, not on the Crossplane chain, because its IAM Pod Identity is
created by OpenTofu in [Foundations]({{< relref "/docs/platform/foundations/_index.md" >}}),
not by Crossplane's `EKSPodIdentity` composition.

`security` is where the graph forks. Five Kustomizations depend on it
directly and run in parallel once it's healthy:

| Kustomization | Depends on | What it does after |
|---|---|---|
| `observability-victoria-metrics-k8s-stack` | `security` | → `observability-victoria-traces` and `observability-grafana-operator`, both of which feed → `observability` |
| `infrastructure` | `karpenter`, `eks-pod-identities` | Cilium policies, Gateway API, External DNS, the AWS Load Balancer Controller, EFS CSI, KEDA — it needs Crossplane's EPIs for their IAM roles, not Security's External Secrets/cert-manager/Kyverno |
| `flux-operator` | `security` | Flux's own operator lifecycle management |
| `flux-observability` | `security` | Flux's metrics/dashboards wiring |
| `flux-notifications` | `security` | Alertmanager and Slack notification wiring |
| `flux-previews` | `security` | Flux preview-environment wiring |

`zitadel` depends on both `infrastructure` and `security` directly — it
needs a database (via `infrastructure`'s Crossplane-provisioned resources)
and Security's secrets/certificates.

Everything converges at the bottom: `tooling` depends on `observability` and
`infrastructure`; `apps` — the tenant-facing `App` composition claims —
depends only on `tooling`.

Two Kustomizations have no `dependsOn` at all and aren't part of this chain:
`flux-artifact-generators` and `flux-sources`. `flux-artifact-generators`
sources directly from the `flux-system` `GitRepository` — it has to, since it
is what creates the `ExternalArtifact`s every other Kustomization in this
repository (including `flux-sources`) sources from instead. See
[Repository Structure]({{< relref "/docs/platform/gitops/repository-structure.md" >}})
for that mechanism. In practice both run first, just not through
`dependsOn` — Flux still waits for a Kustomization's `sourceRef` artifact to
exist before reconciling it.

## Validation before any of this applies

Every manifest above is rendered and gated before it reaches `main` — see
[Validation]({{< relref "/docs/platform/gitops/validation.md" >}}).
