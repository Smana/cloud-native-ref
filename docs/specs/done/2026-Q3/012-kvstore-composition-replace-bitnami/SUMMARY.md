# SUMMARY — SPEC-012: KVStore composition (official valkey chart, off bitnamilegacy)

**Issue**: #1662 · **PRs**: #1664 (composition) → #1665 (consumers) → #1666 (pin strip)
**Merged**: 2026-07-21 · **Verified**: 2026-07-21 ([VERIFICATION.md](VERIFICATION.md), all SCs pass)

## What shipped

- Namespaced `KVStore` XRD (`cloud.ogenki.io/v1alpha1`) + `kcl/kvstore` module (OCI
  `crossplane-kvstore:0.1.0`) wrapping the **official valkey-helm chart 0.10.0** — official
  `valkey/valkey` images, size map, optional ACL auth from existing Secrets, ephemeral by
  default, hardened exporter + ServiceMonitor, default-deny CiliumNetworkPolicy per instance.
- App composition 0.5.0: inline Bitnami kvStore HelmRelease → nested `KVStore` XR
  (SQLInstance pattern); `REDIS_URL` → `redis://<managedName>-valkey:6379`; App API unchanged
  (`kvStore.type` deprecated/ignored, CL-5).
- Harbor + Grafana OnCall migrated to `KVStore` claims (existing ExternalSecrets reused);
  their Bitnami HelmReleases deleted. Zero `bitnamilegacy` references remain (the `bitnami`
  HelmRepository stays for rabbitmq + kubernetes-event-exporter — FR-007 conditional,
  follow-up spec material).

## Tasks

T001–T010 all completed (see plan.md). Cleanup extra: 26 orphaned Bitnami-era valkey EBS
volumes + 36 other orphaned CSI volumes (414Gi) deleted from AWS.

## Deviations

- Pin-strip flow corrected: `validate-composition-versions` requires the `-pr<N>` tag on PR
  runs → merge pinned, strip in the next PR after main publishes (plan.md Deviations).
- OnCall is not deployed on `mycluster-0` (replaced by RunLore) — its claim is verified at
  manifest level only.
- Spec auto-archive skipped (PR body lacked the literal spec path) → archived manually with
  this wrap-up. The archive workflow also exhibits PR-body shell interpolation; not fixed —
  the SDD machinery is being replaced by the superpowers flow.

## Decisions (clarifications.md)

CL-1 in-cluster (CNPG precedent) · CL-2 cache semantics, no failover · CL-3 official chart
behind the XRD (operator swap stays invisible to consumers; an official valkey-operator now
exists) · CL-4 ephemeral default · CL-5 `kvStore.type` ignored.
