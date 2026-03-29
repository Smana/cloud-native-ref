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
