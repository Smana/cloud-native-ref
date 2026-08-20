---
title: Repository Layout
weight: 10
description: What lives where — top-level directories, the base/overlay pattern, and how a change maps to a domain.
lastVerified: 2026-08-20
---

Every deployable domain in this repository follows the same shape:
`<domain>/base/<component>/` holds the Kubernetes manifests, `<domain>/mycluster-0/`
overlays them for this cluster, and a Flux `Kustomization` under
`clusters/mycluster-0/` (or a sibling `clusters/mycluster-0-*/` for an opt-in
umbrella) wires the overlay into the reconciliation graph. Infrastructure that
predates Kubernetes — the VPC, EKS itself, OpenBao — lives under `opentofu/`
instead, orchestrated by Terramate.

{{< repo-tree >}}

## The base / overlay pattern

Within `infrastructure/`, `security/`, `observability/` and `tooling/`, each
component gets its own directory under `base/` — typically a `HelmRelease` or
a handful of raw manifests plus a `kustomization.yaml`. The cluster-specific
`mycluster-0/kustomization.yaml` lists which of those base components are
actually included for this cluster; a component present under `base/` but
absent (or commented out) from the overlay is not deployed. `tooling/base/gha-runners`
is the clearest example — present under `base/`, commented out in
`tooling/mycluster-0/kustomization.yaml`, so the self-hosted CI runners stay off
by default.

A handful of components bypass the shared overlay and get their own top-level
Flux `Kustomization` directly under `clusters/mycluster-0/<domain>/` instead —
`crossplane-controller`, `karpenter`, `grafana-operator`, `victoria-metrics`,
`victoria-traces` and `zitadel` are wired this way, usually because they need
their own `dependsOn` ordering rather than sharing the domain's overlay
lifecycle.

## Two deployment models in one tree

- **OpenTofu / Terramate** (`opentofu/`) provisions everything that has to
  exist *before* a Kubernetes API server does: the VPC, the EKS cluster
  itself, and the OpenBao cluster. See [Commands]({{< relref "/docs/reference/commands.md" >}}).
- **Flux / Kustomize** (everything else) reconciles the cluster once it
  exists. `clusters/mycluster-0/` is the entry point Flux's `FluxInstance`
  points at; from there the dependency chain runs Namespaces → CRDs →
  Crossplane → EKS Pod Identities → Security → Infrastructure →
  Observability → Applications.

## Opt-in surfaces

Two parts of the tree are deliberately inert by default, each gated
independently of the base/overlay mechanism above:

- **`opentofu/llm-platform/`** — a Terramate stack tagged `opt-in`; its
  scripts no-op unless `TM_LLM_PLATFORM_ENABLED=true`.
- **`clusters/mycluster-0-llm-platform/`** — an umbrella Flux `Kustomization`
  (`clusters/mycluster-0/llm-platform.yaml`) with `spec.suspend: true`, kept a
  sibling of `clusters/mycluster-0/` specifically so `flux-system`'s recursive
  sync does not pick up its children and bypass the suspend.

Both gates have to be released for an end-to-end LLM platform deploy — see the
[repository CLAUDE.md](https://github.com/Smana/cloud-native-ref/blob/main/CLAUDE.md#self-hosted-llm-platform-opt-in).
