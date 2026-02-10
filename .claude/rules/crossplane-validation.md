---
description: Crossplane composition render/validate workflow and known limitations
globs:
  - "infrastructure/base/crossplane/configuration/**"
---

# Crossplane Composition Validation

## Render & Validate Workflow

Every composition change MUST be validated before committing:

```bash
# 1. Render
cd infrastructure/base/crossplane/configuration
crossplane render examples/app-basic.yaml app-composition.yaml functions.yaml \
  --extra-resources examples/environmentconfig.yaml > /tmp/rendered.yaml

# 2. Security (target: 85+)
polaris audit --audit-path /tmp/rendered.yaml --format=pretty

# 3. Best practices (target: no errors)
kube-linter lint /tmp/rendered.yaml

# 4. Policy (target: no violations, warnings OK if documented)
datree test /tmp/rendered.yaml --ignore-missing-schemas
```

## Native Kubernetes Resource Readiness

When using function-kcl for native K8s resources (Deployment, Service, HTTPRoute), readiness checks use observed cluster state via `option("params").ocds`:

- **Deployment**: `status.conditions[type=Available, status=True]`
- **Service**: `spec.clusterIP` assigned
- **HTTPRoute**: `status.parents[].conditions[type=Accepted, status=True]`

The `krm.kcl.dev/ready = "True"` annotation is set conditionally based on these checks.

**Static readiness** (always ready when created): HPA, PDB, Gateway, CiliumNetworkPolicy, HelmRelease.
**XR status** (proper conditions): SQLInstance, EKSPodIdentity, S3 Bucket.

## Monitoring Composition Health

```bash
crossplane beta trace app <name> -n <namespace>
kubectl get events -n <namespace>
```
