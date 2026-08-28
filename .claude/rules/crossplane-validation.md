---
description: Crossplane composition validation workflow and readiness patterns
globs:
  - "infrastructure/base/crossplane/configuration-aws/**"
---

# Crossplane Validation

**Compositions are not edited in this repo.** They live in
[`Smana/crossplane-configuration`](https://github.com/Smana/crossplane-configuration) and ship as a
Configuration package; this repo pins a version in
`infrastructure/base/crossplane/configuration-aws/configuration-packages.yaml`. Change a composition
there, run `task check` there, cut a release, then bump the pin here.

Two things in this repo still gate on that pin:

- `./scripts/validate-manifests.sh` validates every claim against the XRD schemas fetched from the
  pinned release — so a pin bump that changes a schema fails here if a claim no longer matches.
- The App Wizard clones the same tag (see the version-coupling note in
  `apps/platform/app-wizard/app.yaml`). Bump both together.

The readiness and v2 traps below still apply: they describe how the *cluster* behaves, which is
what this repo's claims and manifests run against.

## Native K8s Resource Readiness

Readiness checks use observed cluster state via `option("params").ocds`:

- **Deployment**: `status.conditions[type=Available, status=True]`
- **Service**: `spec.clusterIP` assigned
- **HTTPRoute**: `status.parents[].conditions[type=Accepted, status=True]`
- **AIGatewayRoute** (aigateway.envoyproxy.io): top-level `status.conditions[type=Accepted, status=True]`; its *rendering* is additionally latched on Deployment readiness (SPEC-002 FR-002)

The `krm.kcl.dev/ready = "True"` annotation is set conditionally based on these checks.

**Static readiness** (always ready when created): HPA, PDB, Gateway, CiliumNetworkPolicy, HelmRelease, Backend + AIServiceBackend (Envoy AI Gateway).
**XR status** (proper conditions): SQLInstance, EKSPodIdentity, S3 Bucket.

## Crossplane v2 traps (provider-aws v2.x, `m.upbound.io` group)

1. **Managed resources are namespaced** (v1 `upbound.io` was cluster-scoped). Every direct MR — `Bucket`, `BucketVersioning`, `BucketPublicAccessBlock`, IAM `Role`, etc. — needs `metadata.namespace`. Symptom: `<Kind>/<name> namespace not specified` on Flux Kustomization dry-run.
2. **`ManagedResourceActivationPolicy` gates which CRDs install**. Provider packages ship dozens of CRDs but only those listed in `infrastructure/base/crossplane/providers-aws/activation-policy.yaml` are installed. Adding a new MR Kind to a composition or claim usually requires adding its plural-CRD-name to the policy. Symptom: `no matches for kind <Kind>`.
3. **Compositions writing third-party Kinds need an aggregate ClusterRole**. The Crossplane SA gets RBAC only for what the providers manage; `keda.sh/scaledobjects`, `batch/jobs`, etc. need explicit grants via a ClusterRole labeled `rbac.crossplane.io/aggregate-to-crossplane: "true"` (see `infrastructure/base/crossplane/providers-aws/additional-rbac.yaml` for the existing pattern). Symptom on missing RBAC: XR reconcile loops on `Timeout: failed waiting for *unstructured.Unstructured Informer to sync`.
4. **Informer can stall after a fresh CRD is activated** even with RBAC in place. Diagnose with `kubectl auth can-i --as=system:serviceaccount:crossplane-system:crossplane list <plural> -A` first (cheap, deterministic); if it returns `yes` and the timeout persists, restart the controller: `kubectl rollout restart deployment -n crossplane-system crossplane`.
