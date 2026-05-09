---
description: Crossplane composition validation workflow and readiness patterns
globs:
  - "infrastructure/base/crossplane/configuration/**"
---

# Crossplane Validation

Every composition change must pass validation. Run `/crossplane-validator` or:

```bash
./scripts/validate-kcl-compositions.sh
```

## Native K8s Resource Readiness

Readiness checks use observed cluster state via `option("params").ocds`:

- **Deployment**: `status.conditions[type=Available, status=True]`
- **Service**: `spec.clusterIP` assigned
- **HTTPRoute**: `status.parents[].conditions[type=Accepted, status=True]`

The `krm.kcl.dev/ready = "True"` annotation is set conditionally based on these checks.

**Static readiness** (always ready when created): HPA, PDB, Gateway, CiliumNetworkPolicy, HelmRelease.
**XR status** (proper conditions): SQLInstance, EKSPodIdentity, S3 Bucket.

## Crossplane v2 traps (provider-aws v2.x, `m.upbound.io` group)

1. **Managed resources are namespaced** (v1 `upbound.io` was cluster-scoped). Every direct MR — `Bucket`, `BucketVersioning`, `BucketPublicAccessBlock`, IAM `Role`, etc. — needs `metadata.namespace`. Symptom: `<Kind>/<name> namespace not specified` on Flux Kustomization dry-run.
2. **`ManagedResourceActivationPolicy` gates which CRDs install**. Provider packages ship dozens of CRDs but only those listed in `infrastructure/base/crossplane/providers/activation-policy.yaml` are installed. Adding a new MR Kind to a composition or claim usually requires adding its plural-CRD-name to the policy. Symptom: `no matches for kind <Kind>`.
3. **Compositions writing third-party Kinds need an aggregate ClusterRole**. The Crossplane SA gets RBAC only for what the providers manage; `keda.sh/scaledobjects`, `batch/jobs`, etc. need explicit grants via a ClusterRole labeled `rbac.crossplane.io/aggregate-to-crossplane: "true"` (see `infrastructure/base/crossplane/providers/additional-rbac.yaml` for the existing pattern). Symptom on missing RBAC: XR reconcile loops on `Timeout: failed waiting for *unstructured.Unstructured Informer to sync`.
4. **Informer can stall after a fresh CRD is activated** even with RBAC in place. Diagnose with `kubectl auth can-i --as=system:serviceaccount:crossplane-system:crossplane list <plural> -A` first (cheap, deterministic); if it returns `yes` and the timeout persists, restart the controller: `kubectl rollout restart deployment -n crossplane-system crossplane`.
