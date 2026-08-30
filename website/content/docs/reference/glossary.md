---
title: Glossary
weight: 50
description: Terms used across the site — Crossplane, GitOps, and platform-specific vocabulary in one place.
lastVerified: 2026-08-30
---

**Claim** — the Kubernetes object a tenant creates to request infrastructure
(an `App`, `SQLInstance`, or `EPI`). A claim is namespaced, validated against
its composition's schema, and owns the managed resources Crossplane creates
in response.

**Composition** — the Crossplane object that maps a claim to concrete managed
resources (IAM roles, S3 buckets, Deployments, …). Compositions in this
platform are written in KCL rather than patch-and-transform, and live in
[`Smana/crossplane-configuration`](https://github.com/Smana/crossplane-configuration),
not in this repository.

**XR (Composite Resource)** — the cluster-scoped resource Crossplane creates
from a claim plus its composition; it in turn owns the individual managed
resources.

**XRD (Composite Resource Definition)** — the schema that defines a claim's
API: its fields, validation, and the composition that handles it.

**EPI (EKS Pod Identity)** — the composition that grants a pod IAM permissions
via EKS Pod Identity (never IRSA — see
[ADR-0002]({{< relref "/docs/decisions/0002-eks-pod-identity-over-irsa.md" >}})).
Produces an IAM Role, an IAM Policy, and a Pod Identity Association scoped to
a `(namespace, ServiceAccount)` pair.

**Stack** — a Terramate unit of OpenTofu configuration with its own state:
`network`, `openbao/cluster`, `openbao/management`, `eks/init`,
`eks/configure`, `gke/init`, `gke/configure`, `llm-platform`. Terramate
orchestrates dependencies and ordering across stacks; `tofu` runs within one.

**Reconciliation** — Flux's continuous loop of comparing the cluster's actual
state to what Git declares, and applying the difference. "Reconciled" means
this loop has run and converged, not merely that a resource was created once.

**Drift** — a difference between what Git declares and what the cluster
actually runs, whether from a manual `kubectl apply`, an external actor, or a
reconciliation that hasn't caught up yet. `terramate script run drift detect`
checks for it on the OpenTofu side; Flux's own reconciliation is the
Kubernetes-side equivalent.

**Tenant** — a namespace-scoped consumer of the platform's claim APIs. `app`
is the only tenant namespace defined today; OpenBao's namespace layout
reserves namespaces for tenants specifically, keeping shared platform
services (the PKI, operator logins) in the root namespace instead.

**Prefix delegation** — the Cilium/AWS-VPC-CNI IPAM mode that assigns pods IP
addresses from `/28` prefixes carved out of an ENI's secondary IP range,
rather than one secondary IP per pod — multiplying the pod density an ENI can
support. Only applies to nodes created after Cilium is installed (Stage 2);
Stage 1 bootstrap nodes keep the lower per-ENI ceiling for their lifetime.

**GitOps** — the operating model where Git is the single source of truth for
both infrastructure (OpenTofu, reconciled by Terramate) and cluster state
(Kubernetes manifests, reconciled by Flux): a commit is the only way to
change what's running, and reverting a commit is the rollback path.

**Managed resource (MR)** — the lowest-level Crossplane object representing
one piece of real infrastructure (an AWS `Bucket`, an IAM `Role`, …). A
composition's job is to produce a coherent set of these from one claim.
Provider-aws v2.x managed resources are namespaced, unlike the v1
cluster-scoped equivalents.

**Configuration package** — a Crossplane package (an OCI artifact) that
ships a set of XRDs and Compositions together, installed via a `Configuration`
object. This repository consumes two pinned packages, one per cloud
(`infrastructure/base/crossplane/configuration-aws/configuration-packages.yaml`
and its `configuration-gcp` sibling), each pulling the shared `-core` package
through its own `dependsOn` — built and released from
`Smana/crossplane-configuration`, rather than authoring compositions in-tree.

**Shard** — a Flux controller partition; this repository runs two (default and
`apps`, via `sharding.fluxcd.io/key`) — the sharp edge that comes with them is
on [Repository structure]({{< relref "/docs/platform/gitops/repository-structure.md" >}}).
