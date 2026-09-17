# Infrastructure — Crossplane, Cilium, Gateway API, Tailscale

## Compositions are not edited here

XRDs and Compositions live in
[`Smana/crossplane-configuration`](https://github.com/Smana/crossplane-configuration) and ship as a
Configuration package. This repo pins a version in
`base/crossplane/configuration-aws/configuration-packages.yaml`. Edit the KCL there, run
`task check` there, cut a release, then bump the pin here.

Two things in this repo gate on that pin:

- `../scripts/validate-manifests.sh` validates every claim against the XRD schemas fetched from the
  pinned release, so a pin bump that changes a schema fails here if a claim no longer matches.
- The App Wizard clones the same tag (see `../apps/platform/app-wizard/app.yaml`). **Bump both
  together.**

Still owned here: `functions.yaml` (version-pinned rather than resolved by the packages'
`dependsOn`), `environmentconfig.yaml`, and the provider config.

## Crossplane v2 traps (provider-aws v2.x, `m.upbound.io` group)

1. **Managed resources are namespaced** — v1 `upbound.io` was cluster-scoped. Every direct MR
   (`Bucket`, `BucketVersioning`, `BucketPublicAccessBlock`, IAM `Role`…) needs
   `metadata.namespace`. Symptom: `<Kind>/<name> namespace not specified` on Flux dry-run.
2. **`ManagedResourceActivationPolicy` gates which CRDs install.** Provider packages ship dozens,
   but only those listed in `base/crossplane/providers-aws/activation-policy.yaml` are installed.
   A new MR Kind usually needs its plural CRD name added there. Symptom: `no matches for kind <Kind>`.
3. **Compositions writing third-party Kinds need an aggregate ClusterRole.** The Crossplane SA gets
   RBAC only for what the providers manage; `keda.sh/scaledobjects`, `batch/jobs` and friends need
   an explicit grant via a ClusterRole labeled `rbac.crossplane.io/aggregate-to-crossplane: "true"`
   — see `base/crossplane/providers-aws/additional-rbac.yaml`. Symptom: the XR reconcile loops on
   `Timeout: failed waiting for *unstructured.Unstructured Informer to sync`.
4. **The informer can stall after a fresh CRD is activated** even with RBAC in place. Diagnose with
   the cheap deterministic check first —
   `kubectl auth can-i --as=system:serviceaccount:crossplane-system:crossplane list <plural> -A` —
   and if it returns `yes` while the timeout persists,
   `kubectl rollout restart deployment -n crossplane-system crossplane`.

**Raise the cloud packages' `dependsOn` when bumping the Crossplane core**: Crossplane will not
auto-upgrade an installed dependency.

**Package adoption vs Flux prune**: packages adopt existing XRDs, but Flux prune then deletes them
and destroys every claim. Migrate in two PRs.

## Readiness

Readiness checks read observed cluster state via `option("params").ocds`:

| Resource | Ready when |
|---|---|
| Deployment | `status.conditions[type=Available, status=True]` |
| Service | `spec.clusterIP` assigned |
| HTTPRoute | `status.parents[].conditions[type=Accepted, status=True]` |
| AIGatewayRoute | top-level `status.conditions[type=Accepted, status=True]`; rendering is additionally latched on Deployment readiness |

**Static-ready** (always ready once created): HPA, PDB, Gateway, CiliumNetworkPolicy, HelmRelease,
Backend and AIServiceBackend. **XR status** with proper conditions: SQLInstance, EKSPodIdentity,
S3 Bucket.

## Tailscale Gateway API

Private services are exposed on `*.priv.aws.ogenki.io` through two gateways whose split enforces
ACL-based access control, both using `loadBalancerClass: tailscale` via `CiliumGatewayClassConfig`:

| Gateway | Tag | Services |
|---|---|---|
| General | `tag:k8s` — all tailnet members | Harbor, Headlamp, Homepage, Grafana, VictoriaMetrics, **VictoriaLogs** |
| Admin | `tag:admin` — `group:admin` only | Hubble UI |

Both of VictoriaLogs' HTTPRoutes name `platform-tailscale-general`, despite it being an
operational tool. ExternalDNS watches HTTPRoutes to create Route53 records.

**external-dns with a child domain-filter silently resolves zero zones** — it needs
`--aws-zone-match-parent`.

## Gateways stuck `Waiting for controller`

cilium-operator probes for the Gateway API CRDs **once, at startup**, and permanently disables its
Gateway API controller if any are missing. No crash, no alert. The symptoms cascade:
`GatewayClass ACCEPTED=Unknown`, Gateways unprogrammed, HTTPRoutes with no `status.parents`, and
every `App` claim owning a route stuck `READY=False`.

```bash
kubectl logs -n kube-system -l io.cilium/app=operator | grep "Required GatewayAPI resources"
kubectl rollout restart -n kube-system deployment/cilium-operator
```

Both clouds install these CRDs from `../opentofu/shared/modules/gateway-api-crds`, which applies
the whole experimental-channel bundle keyed by `for_each` — so a CRD Cilium wants can no longer be
missing from an enumeration. If a *newer Gateway API release* is the fix, the two pins move
together (see `../opentofu/AGENTS.md`).

Keep Cilium ≥ 1.19.5: Cilium and Gateway API move in lockstep.
