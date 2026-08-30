---
title: Technology Stack
weight: 20
description: What runs on this platform, and what each piece is responsible for.
lastVerified: 2026-08-30
---

Every component this platform runs, and what it is responsible for — not
which version. There is no version column below, on purpose: Renovate opens a
pull request for every upstream release, and CI renders the whole repository
against it before that pull request can merge. A version number copied into
this page would be stale the moment that job runs next, and nothing would
fail to tell us — a hand-maintained version table rots silently, a role does
not. Where the version actually lives — `mise.toml`, `opentofu/config.tm.hcl`,
a `HelmRelease`, an `OCIRepository` — is still worth knowing, so the "Pinned
in" column stays. For the *why* behind a choice, see
[Decisions]({{< relref "/docs/decisions/_index.md" >}}).

The table is generated from `website/data/stack.yaml`, which is also what
renders the strip on the [landing page](/) — one source, so the two cannot
disagree.

## CLI tools

{{< stack-table group="cli" >}}

## EKS bootstrap

What the cluster is built from, before Flux takes over.

{{< stack-table group="bootstrap" >}}

## GKE bootstrap

Same shape on GCP — the versions Cilium and Flux run are shared with EKS,
pinned once in `opentofu/config.tm.hcl`.

{{< stack-table group="bootstrap-gke" >}}

## Infrastructure

{{< stack-table group="infrastructure" >}}

## Security

{{< stack-table group="security" >}}

## Observability

{{< stack-table group="observability" >}}

## Data and tooling

{{< stack-table group="tooling" >}}

## Managed cloud services

Not in the table above because there is nothing to install or upgrade: Route
53 (DNS), Elastic Load Balancing, IAM (via EKS Pod Identity), KMS, and S3 are
AWS APIs this platform calls, not software this repository deploys and
Renovate bumps. On GCP the same applies to Cloud DNS, GCS, Secret Manager,
Workload Identity, and Cloud KMS.

A handful of components render a lettered tile rather than a logo. That is
deliberate: `website/static/images/logos/LICENSES.md` records every mark's
source and terms, and explains why borrowing a neighbouring project's logo —
Terraform's for Terramate, the Kubernetes wheel for four different SIG
projects — was rejected as misleading rather than merely imperfect.
