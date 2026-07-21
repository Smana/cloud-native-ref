# VERIFICATION — SPEC-012 KVStore composition

**Date**: 2026-07-21
**Cluster**: `mycluster-0` (recreated from scratch from post-merge `main`; verified during initial reconciliation)
**Merged PRs**: #1664 (composition), #1665 (consumers), #1666 (app pin strip)
**Verifier**: Claude (session evidence below, all commands run against the live cluster)

## Scope note

Grafana OnCall is **not deployed on this cluster** — `observability/mycluster-0/kustomization.yaml`
includes `runlore` (its replacement) and never references `../base/grafana-oncall`. The
`xplane-oncall` KVStore claim is therefore verified at manifest level only (SC-001); the
deployed, verifiable instances are **App/image-gallery** and **Harbor**.

## Success criteria

### SC-001 — repo renders clean, zero bitnamilegacy ✅

`./scripts/validate-manifests.sh` (PR 2 CI + local): exit 0,
`Summary: 1191 resources found in 182 files - Valid: 1191, Invalid: 0, Skipped: 0`, Polaris 88.
Rendered bundle contains zero `bitnamilegacy` / Bitnami-valkey references (the `bitnami`
HelmRepository itself remains for `kubernetes-event-exporter` + OnCall `rabbitmq`, per FR-007).

### SC-002 — XR Ready + official images ✅

Both deployed claims `Synced=True, Ready=True` **within ~60s of creation** (well under the 5-min bar):

```
NAMESPACE   NAME                   SYNCED   READY   AGE
apps        xplane-image-gallery   True     True    51s
tooling     xplane-harbor          True     True    62s
```

Pods 2/2 Running on official images:

```
apps/xplane-image-gallery-valkey-...: docker.io/valkey/valkey:9.1.0 ghcr.io/oliver006/redis_exporter:v1.79.0
tooling/xplane-harbor-valkey-...:     docker.io/valkey/valkey:9.1.0 ghcr.io/oliver006/redis_exporter:v1.79.0
```

HelmReleases: `Helm install succeeded ... with chart valkey@0.10.0` (official repo).

### SC-003 — App auto-wiring + connectivity ✅

`REDIS_URL=redis://xplane-image-gallery-valkey:6379` injected into the App workload.
`valkey-cli CLIENT LIST` on the instance shows **6 established connections from the app pod IP**
(`100.64.42.92`), `lib-name=go-redis`, `cmd=ping`, commands flowing — live traffic through the
CNP allow path (established TCP ⇒ no policy drops on this flow).

### SC-004 — Harbor healthy on authenticated Valkey ✅

All Harbor Deployments Ready (core, exporter, jobservice, nginx, portal, registry). Zero
redis errors in harbor-core logs. Authenticated `CLIENT LIST` maps live connections to:
**jobservice ×6, core ×2, exporter ×1, trivy ×1** — the job queue is served by the new instance
(jobservice's readiness gate requires its Redis pool). Auth works via classic `AUTH <password>`
against the chart's mandatory `default` ACL user, using the pre-existing
`harbor-valkey-password` ExternalSecret unchanged.

### SC-005 — exporter scraped by VictoriaMetrics ✅

```
redis_up{job="xplane-image-gallery-valkey-metrics", namespace="apps"}    = 1
redis_up{job="xplane-harbor-valkey-metrics",       namespace="tooling"} = 1
```

Via the chart's ServiceMonitor (VM-operator-converted). The scrape traverses the CNP's
`9121-from-observability` ingress rule — proving that rule functional, not just present.

### SC-006 — default-deny enforced ✅

Cross-namespace probe (`default/cnp-test` → `xplane-harbor-valkey.tooling:6379`) timed out;
Hubble on the instance's node:

```
default/cnp-test:40721 <> tooling/xplane-harbor-valkey-...:6379 Policy denied DROPPED (TCP Flags: SYN)
```

### SC-007 — composition validation ✅

`./scripts/validate-kcl-compositions.sh` exit 0 (fmt + syntax + `crossplane render` of both
examples against the published OCI module); `kcl test` 15/15 (kvstore) and 30/30 (app).

## Additional assertions

- **Ephemeral by design (CL-4)**: `kubectl get pvc -A | grep -ci valkey` → **0** in-cluster.
- **AWS cleanup**: 26 orphaned Bitnami-era valkey EBS volumes (leftover from pre-rebuild
  clusters; teardown does not reclaim CSI volumes) deleted, plus 36 other orphaned CSI volumes
  (414Gi) authorized and deleted in the same session.
- Unrelated bootstrap observation: one image-gallery replica crash-looped on **S3 "Access
  Denied"** (Pod Identity settling) during early reconciliation — database and Valkey paths
  unaffected; sibling replica healthy.

## Verdict

All success criteria verified on the deployed surface; SPEC-012 **PASSES**.
