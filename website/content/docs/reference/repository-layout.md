---
title: Repository Layout
weight: 10
description: What lives where — top-level directories, the base/overlay pattern, and how a change maps to a domain.
lastVerified: 2026-08-30
---

Every deployable domain in this repository follows the same shape:
`<domain>/base/<component>/` holds the cloud-neutral Kubernetes manifests,
`<domain>/<cluster>/` overlays them for one cluster, and a Flux `Kustomization`
under `clusters/<cluster>/` (or a sibling `clusters/<cluster>-*/` for an opt-in
umbrella) wires the overlay into the reconciliation graph.

There are **two clusters**: `aws-0` and `gcp-0`. Both read the same `base/`
directories, so a component is written once and overlaid twice. Infrastructure
that predates Kubernetes — the VPC, the cluster itself, OpenBao — lives under
`opentofu/<cloud>/` instead, orchestrated by Terramate.

The rule that keeps this honest: **anything in `base/` must work on both
clouds.** A manifest only one cloud can use belongs in that cloud's overlay,
even when both clouds happen to want a file of the same name — see
`infrastructure/aws-0/gapi/platform-public-gateway.yaml` and
`security/aws-0/openbao-snapshot/s3-bucket.yaml`.

{{< repo-tree >}}

## The base / overlay pattern

Within `infrastructure/`, `security/`, `observability/` and `tooling/`, each
component gets its own directory under `base/` — typically a `HelmRelease` or
a handful of raw manifests plus a `kustomization.yaml`. The cluster's own
`kustomization.yaml` lists which of those base components are
actually included; a component present under `base/` but absent (or commented
out) from the overlay is not deployed. `tooling/base/gha-runners` is the
clearest example — present under `base/`, commented out in
`tooling/aws-0/kustomization.yaml`, so the self-hosted CI runners stay off
by default.

This is also why the two clusters run different amounts of platform: `gcp-0`'s
overlays simply include fewer base components today. Which ones, and why, is on
[Cloud support]({{< relref "/docs/platform/foundations/cloud-support.md" >}}).

A handful of components bypass the shared overlay and get their own top-level
Flux `Kustomization` directly under `clusters/<cluster>/<domain>/` instead —
on `aws-0`: `crossplane-controller`, `karpenter`, `grafana-operator`,
`victoria-metrics`, `victoria-traces` and `zitadel`; `gcp-0` adds
`gapi`/`gapi-public` and four `security-*` Kustomizations (OpenBao, its
snapshots, public certs, Tailscale) — usually because they need their own
`dependsOn` ordering rather than sharing the domain's overlay lifecycle.

## Two deployment models in one tree

- **OpenTofu / Terramate** (`opentofu/`) provisions everything that has to
  exist *before* a Kubernetes API server does: the VPC, the cluster itself, and
  the OpenBao cluster. Split `opentofu/aws/`, `opentofu/gcp/` and
  `opentofu/shared/` — the last holding the tailnet and the AWS↔GCP DNS
  federation, which belong to neither cloud. See
  [Commands]({{< relref "/docs/reference/commands.md" >}}).
- **Flux / Kustomize** (everything else) reconciles the cluster once it
  exists. `clusters/aws-0/` and `clusters/gcp-0/` are the entry points each
  cluster's `FluxInstance` points at; from there the dependency chain runs
  Namespaces → CRDs → Crossplane → workload identities → Security →
  Infrastructure → Observability → Applications.

## Opt-in surfaces

Several parts of the tree are deliberately inert by default, each gated
independently of the base/overlay mechanism above:

- **`opentofu/aws/llm-platform/`** — a Terramate stack tagged `opt-in`; its
  scripts no-op unless `TM_LLM_PLATFORM_ENABLED=true`.
- **`clusters/aws-0-llm-platform/`** — an umbrella Flux `Kustomization`
  (`clusters/aws-0/llm-platform.yaml`) with `spec.suspend: true`, kept a
  sibling of `clusters/aws-0/` specifically so `flux-system`'s recursive
  sync does not pick up its children and bypass the suspend.
- **`clusters/gcp-0-llm-platform/`** — the same suspended-umbrella pattern
  for `gcp-0`, gated by `clusters/gcp-0/llm-platform.yaml`.
- **`opentofu/<lane>/**`** — the directory *is* the cloud selector. Stacks
  under `aws/` and `gcp/` run only when `TM_CLOUD` names their lane (it defaults
  to `aws`); anything under `shared/` is owned by neither cloud and always runs.
  So an AWS deploy from `opentofu/` never builds GCP as a side effect, and a GCP
  one never rebuilds `aws-0`.

On `aws-0` both LLM gates have to be released for an end-to-end deploy; on
`gcp-0` the umbrella is the only LLM gate — see the
[repository CLAUDE.md](https://github.com/Smana/cloud-native-ref/blob/main/CLAUDE.md#self-hosted-llm-platform-opt-in).
