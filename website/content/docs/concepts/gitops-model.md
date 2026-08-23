---
title: The GitOps model
weight: 30
description: Why reconciliation beats deployment, and why the dependency graph matters more than the pipeline.
lastVerified: 2026-08-20
---

A deployment pipeline answers "what happened when I pushed?". A reconciler
answers "what is true right now?". The second question is the one that
matters at three in the morning, and it is the reason nothing in this
repository is applied by a human or a CI job.

## Push versus reconcile

In a push model, CI holds the credentials, runs `kubectl apply`, and the
cluster's state is whatever the last successful pipeline left behind. Drift
is invisible: if someone edits a resource by hand, nothing notices until the
next deploy silently overwrites it — or doesn't.

In a reconcile model, a controller inside the cluster continuously compares
the cluster to Git and corrects the difference. Drift is not a special case;
it is the normal input. And CI never needs cluster credentials at all, which
removes an entire class of blast radius from the CI system.

The practical consequence: recovering this platform is pointing a fresh
cluster's Flux at the same Git path. There is no runbook to replay, because
there was never a sequence of imperative steps to begin with.

## The dependency graph is the design

The interesting part of a GitOps setup is not that it syncs. It is the order
in which things become true.

Namespaces must exist before workloads land in them. CRDs must be
established before a controller can watch them. Crossplane must be running
before a claim can be reconciled. Pod identities must exist before a
controller can reach a cloud API. Each of these is a `dependsOn` edge, and
together they form a graph that Flux walks.

It is worth being precise about that graph, because it is easy to describe
it more neatly than it is. The
[constitution]({{< relref "/docs/reference/platform-constitution.md" >}})
gives a five-step summary — foundations, security, infrastructure,
observability, applications — and now says plainly that this is a simplified
model rather than the real thing. The actual graph is wider: Crossplane is
three sequential Kustomizations, Karpenter sits outside them, several
`flux/*` Kustomizations manage Flux itself in parallel, and `infrastructure`
depends on Karpenter and pod identities rather than on security.

The [GitOps section]({{< relref "/docs/platform/gitops/_index.md" >}})
carries the graph re-derived from the cluster's own manifests. When the
summary and the manifests disagree, the manifests win.

## Why a dependency failure cascades

Because the graph is explicit, a single missing prerequisite does not fail
one thing — it stalls everything downstream of it. A Kustomization that
health-checks a resource whose namespace was never created will sit
`not ready`, and every Kustomization depending on it reports the same,
producing a dozen alarming messages with one actual cause.

That is a feature, not a flaw: the alternative is applying resources into a
cluster that is not ready for them and discovering the problem later, in a
less legible form. But it does mean the first question when the tree goes
red is *which node is the root*, not *why are twelve things broken*.

## What it costs

- **Everything is asynchronous.** You do not get a deploy result; you get a
  status you have to go and read.
- **Git becomes the bottleneck for urgent change.** That is usually correct
  and occasionally infuriating.
- **Secrets cannot live in Git**, which forces a whole external-secrets
  machinery that a push pipeline could have avoided.

## Reading on

- [GitOps]({{< relref "/docs/platform/gitops/_index.md" >}}) — the real
  dependency graph, and the repository layout it reflects
- [ADR-0007]({{< relref "/docs/decisions/0007-cloud-abstraction-boundaries.md" >}})
  — where cloud-specific and cloud-neutral APIs divide
