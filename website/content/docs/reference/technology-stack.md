---
title: Technology Stack
weight: 20
description: What runs, which version, and where that version is pinned in this repository.
lastVerified: 2026-08-20
---

Every version below was re-read from the pin in this repository on 2026-08-20
— `mise.toml`, `opentofu/config.tm.hcl`, an OpenTofu variable default, or a
`HelmRelease`/`OCIRepository` — not copied from prose. Where a component has
no version pinned in this repo, that is stated instead of a guessed number.
For the *why* behind a choice, see [Decisions]({{< relref "/docs/decisions/_index.md" >}}).

The table is generated from `website/data/stack.yaml`, which is also what
renders the strip on the [landing page](/) — one source, so the two cannot
disagree.

## CLI tools

{{< stack-table group="cli" >}}

## EKS bootstrap

The versions the cluster is built from, before Flux takes over.

{{< stack-table group="bootstrap" >}}

## Infrastructure

{{< stack-table group="infrastructure" >}}

## Security

{{< stack-table group="security" >}}

## Observability

{{< stack-table group="observability" >}}

## Data and tooling

{{< stack-table group="tooling" >}}

## Managed AWS services

No version to pin — these are AWS APIs, not deployed software: Route 53 (DNS),
Elastic Load Balancing, IAM (via EKS Pod Identity), KMS, and S3.

## What this table intentionally omits

The retired `technology-choices` page carried a flatter, badge-illustrated
version of this table with no version column at all — every entry there had
drifted from what actually deploys, which is the reason this page exists. This
page also drops a few rows that duplicated the
[Repository Layout]({{< relref "/docs/reference/repository-layout.md" >}})
page's directory listing without adding version information.

A handful of components render a lettered tile rather than a logo. That is
deliberate: `website/static/images/logos/LICENSES.md` records every mark's
source and terms, and explains why borrowing a neighbouring project's logo —
Terraform's for Terramate, the Kubernetes wheel for four different SIG
projects — was rejected as misleading rather than merely imperfect.
