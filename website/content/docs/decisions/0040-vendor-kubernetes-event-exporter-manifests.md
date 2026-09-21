---
title: Vendor kubernetes-event-exporter as plain manifests instead of a Helm chart
linkTitle: 0040 · Vendor kubernetes-event-exporter manifests
weight: 400
description: The last Bitnami dependency (issue #1089) is the kubernetes-event-exporter chart itself — the image already moved to a community fork. No maintained chart exists that both wraps the same binary and meets this repo's resource-limits bar, so the chart's own rendered output is vendored as plain manifests and the bitnami HelmRepository is deleted. Consequence: no chart to upgrade, config edits are hand edits, and only the image tag stays Renovate-tracked.
lastVerified: 2026-09-21
---

**Status**: Accepted
**Date**: 2026-09-21
**Deciders**: Smana (Platform Owner)

---

## Context

Issue #1089 tracks migrating every Bitnami-sourced dependency off `oci://registry-1.docker.io/bitnamicharts`,
ahead of Broadcom's `bitnamilegacy` deprecation. `kubernetes-event-exporter` was the last one: the
container image already runs `ghcr.io/civitatis/kubernetes-event-exporter:1.8` (a community fork),
with `global.security.allowInsecureImages: true` set so the Bitnami chart accepts a non-Bitnami
image. Only the chart itself — `kubernetes-event-exporter` v3.6.3, sourced from the `bitnami`
`HelmRepository` — was still Bitnami's.

No comment on #1089 names a mandated replacement chart. Two independent Helm charts exist on
ArtifactHub; both were rendered with this repo's values (`helm template`) and diffed against the
Bitnami baseline before this decision.

## Decision

Vendor the Bitnami chart's own rendered output as plain manifests under
`observability/base/kubernetes-event-exporter/` (`Deployment`, `ConfigMap`, `Service`,
`ServiceMonitor`, `NetworkPolicy`, `PodDisruptionBudget`, RBAC), stripped of Helm-only metadata, and
delete `flux/sources/helmrepo-bitnami.yaml`. `${cluster_name}` stays in the `ConfigMap` for Flux
`postBuild` substitution, unchanged from how the `HelmRelease` fed it.

## Alternatives rejected

| Option | Rejected because |
|---|---|
| **`itakurah/kubernetes-event-exporter` chart (0.2.3)** | Wraps the same upstream binary this repo already runs, but ships no `resources` field anywhere in values or templates — violates this repo's requests+limits non-negotiable and would need a `postRenderers` JSON6902 patch to add them. Also carries an open, unfixed template bug (an all-hex 8-char config checksum can parse as a YAML number and reject the apply), unpatched for 6+ months. |
| **`ownkube/kubernetes-events-exporter` chart (0.1.2)** | A full Go rewrite, not the resmoio/mustafaakin codebase this repo runs — `loki` receiver and `route.match` compatibility is unverified, not just untested. Its apparent activity doesn't hold up either: no human-merged commit in 5 months, only 11 open Dependabot PRs. |
| **Keep pulling the Bitnami OCI chart** | Exactly what #1089 asks to stop. Sibling components (Valkey, RabbitMQ images) are already mid-migration off Bitnami, confirming the source itself is on a deprecation path, not just this one chart. |
| **Use the real upstream chart** | Doesn't exist. The upstream repo (`resmoio`, now pushed under `mustafaakin/kubernetes-event-exporter`) ships a raw `deploy/` manifest directory, not a Helm chart. |

## Consequences

- **No chart to upgrade.** A future exporter version means re-rendering and re-diffing by hand, not
  bumping a chart version.
- **Config changes are hand edits.** `config.yaml` (routes, receivers, log settings) is now a
  committed `ConfigMap` literal, edited directly instead of through `values.yaml`.
- **Only the image tag is Renovate-tracked**, via the repo-wide `kubernetes` manager
  (`.github/renovate.json`) that already scans every manifest outside `clusters/` and `opentofu/`.
- **No checksum-triggered rollout.** The Helm chart's `checksum/config` pod annotation was dropped
  with the rest of the Helm-only metadata; a `config.yaml` edit no longer forces a new
  `ReplicaSet` on its own and needs an explicit rollout restart.
