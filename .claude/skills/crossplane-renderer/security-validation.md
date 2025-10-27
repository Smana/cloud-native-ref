# Security & Policy Validation Guide

This document provides comprehensive guidance on validating Crossplane compositions for security and policy compliance using three industry-standard tools.

## Table of Contents

1. [Overview](#overview)
2. [Polaris - Security & Best Practices](#polaris---security--best-practices)
3. [kube-linter - Kubernetes Best Practices](#kube-linter---kubernetes-best-practices)
4. [Datree - Policy Enforcement](#datree---policy-enforcement)
5. [Common Issues and Fixes](#common-issues-and-fixes)
6. [CI/CD Integration](#cicd-integration)

---

## Overview

### Why These Tools?

**Polaris**: Audits Kubernetes resources for security issues and configuration best practices
**kube-linter**: Analyzes Kubernetes manifests and Helm charts for common errors
**Datree**: Enforces policy-as-code to prevent misconfigurations from reaching production

### Validation Targets

| Tool | Target | Acceptable Outcome |
|------|--------|-------------------|
| **Polaris** | 85+ score | No critical issues, Green/Yellow acceptable |
| **kube-linter** | No errors | Clean output with zero errors |
| **Datree** | No violations | Warnings acceptable if documented |

### When to Run

**During Development**:
- After major composition changes
- When adding new resource types
- Before creating pull requests

**Always Before Commit**:
- Run on rendered composition output
- Address critical issues
- Document accepted warnings

---

## Polaris - Security & Best Practices

### What Polaris Checks

**Security**:
- Privileged containers
- Host network/IPC/PID usage
- Capabilities
- Running as root
- Read-only root filesystem

**Reliability**:
- Resource limits (CPU/memory)
- Liveness probes
- Readiness probes
- Pod disruption budgets

**Efficiency**:
- Resource requests
- LimitRange usage

### Running Polaris

**Basic audit**:
```bash
polaris audit --audit-path /tmp/rendered.yaml --format=pretty
```

**JSON output** (for parsing):
```bash
polaris audit --audit-path /tmp/rendered.yaml --format=json > /tmp/polaris-report.json
```

**Score-only check**:
```bash
polaris audit --audit-path /tmp/rendered.yaml --format=score
```

### Interpreting Polaris Output

**Example output**:
```
Polaris audited Path /tmp/rendered.yaml at 2025-10-27T23:30:00Z
    Nodes: 0 | Namespaces: 2 | Controllers: 5
    Final score: 87

deployment/myapp in namespace apps:
    [✓] cpuRequestsMissing
    [✓] memoryRequestsMissing
    [✗] cpuLimitsMissing - CPU limits should be set
    [✓] memoryLimitsMissing
    [✓] runAsRootAllowed
    [✓] runAsPrivileged
    [✓] readOnlyRootFilesystem
    [✗] livenessProbeNotSet - Liveness probe should be configured
    [✓] readinessProbeNotSet
```

**Score Interpretation**:
- **90-100**: Excellent (Green)
- **85-89**: Good (Yellow) - **Acceptable**
- **70-84**: Needs improvement (Orange)
- **Below 70**: Critical issues (Red) - **Must fix**

### Target Score: 85+

**Why 85+?**
- Balances security with practicality
- Allows some acceptable warnings
- Catches critical misconfigurations
- Aligns with production readiness

### Common Polaris Issues and Fixes

#### Issue 1: CPU Limits Missing

**Polaris Error**: `cpuLimitsMissing - CPU limits should be set`

**Impact**: Containers can consume unlimited CPU, affecting other pods

**Fix in App Composition** (`kcl/app/main.k`):
```kcl
_deployment = {
    spec.template.spec.containers = [{
        name = _name
        image = _spec.image
        resources = {
            requests = {
                cpu = "100m"
                memory = "128Mi"
            }
            limits = {
                cpu = "500m"      # ✅ Add CPU limit
                memory = "512Mi"
            }
        }
    }]
}
```

#### Issue 2: Memory Limits Missing

**Polaris Error**: `memoryLimitsMissing - Memory limits should be set`

**Impact**: Containers can consume unlimited memory, risking OOM kills

**Fix**: Add memory limits (see Issue 1 example)

#### Issue 3: Liveness Probe Not Set

**Polaris Error**: `livenessProbeNotSet - Liveness probe should be configured`

**Impact**: Kubernetes cannot detect and restart unhealthy containers

**Fix**:
```kcl
_deployment = {
    spec.template.spec.containers = [{
        name = _name
        image = _spec.image
        livenessProbe = {           # ✅ Add liveness probe
            httpGet = {
                path = "/healthz"
                port = 8080
            }
            initialDelaySeconds = 30
            periodSeconds = 10
        }
    }]
}
```

#### Issue 4: Readiness Probe Not Set

**Polaris Error**: `readinessProbeNotSet - Readiness probe should be configured`

**Impact**: Traffic may be sent to containers before they're ready

**Fix**:
```kcl
_deployment = {
    spec.template.spec.containers = [{
        name = _name
        image = _spec.image
        readinessProbe = {          # ✅ Add readiness probe
            httpGet = {
                path = "/ready"
                port = 8080
            }
            initialDelaySeconds = 5
            periodSeconds = 5
        }
    }]
}
```

#### Issue 5: Running as Root

**Polaris Error**: `runAsRootAllowed - Should not be allowed to run as root`

**Impact**: Security risk if container is compromised

**Fix**:
```kcl
_deployment = {
    spec.template.spec = {
        securityContext = {          # ✅ Add pod-level security context
            runAsNonRoot = True
            runAsUser = 1000
            fsGroup = 1000
        }
        containers = [{
            name = _name
            image = _spec.image
            securityContext = {      # ✅ Add container-level security context
                allowPrivilegeEscalation = False
                readOnlyRootFilesystem = True
                runAsNonRoot = True
                runAsUser = 1000
                capabilities = {
                    drop = ["ALL"]
                }
            }
        }]
    }
}
```

#### Issue 6: Privileged Container

**Polaris Error**: `runAsPrivileged - Should not be allowed to run privileged`

**Impact**: Severe security risk, full host access

**Fix**: Remove `privileged: true` unless absolutely required for infrastructure components

**If required** (document justification):
```kcl
# ONLY for system components like CNI, CSI drivers, etc.
# Document why privileged access is required
if _requiresPrivilegedAccess:
    _deployment.spec.template.spec.containers[0].securityContext.privileged = True
```

---

## kube-linter - Kubernetes Best Practices

### What kube-linter Checks

**Reliability**:
- Liveness/readiness probes
- Resource limits
- Replica counts
- Anti-affinity rules

**Security**:
- Security contexts
- Capabilities
- Host namespace usage
- Service account configuration

**Maintainability**:
- Label schemas
- Annotation standards
- API version deprecations

### Running kube-linter

**Basic lint**:
```bash
kube-linter lint /tmp/rendered.yaml
```

**Show all checks**:
```bash
kube-linter checks list
```

**Ignore specific checks**:
```bash
kube-linter lint /tmp/rendered.yaml --ignore=no-read-only-root-fs
```

**JSON output**:
```bash
kube-linter lint /tmp/rendered.yaml --format=json > /tmp/kube-linter-report.json
```

### Interpreting kube-linter Output

**Example output**:
```
/tmp/rendered.yaml: (object: apps/myapp Deployment) container "myapp" does not have a read-only root file system (check: no-read-only-root-fs, remediation: Set readOnlyRootFilesystem to true in the container securityContext.)

/tmp/rendered.yaml: (object: apps/myapp Deployment) container "myapp" is not set to runAsNonRoot (check: run-as-non-root, remediation: Set runAsNonRoot to true in the container securityContext.)

Error: found 2 lint errors
```

### Target: Zero Errors

kube-linter is stricter than Polaris. All errors must be addressed.

### Common kube-linter Issues and Fixes

#### Issue 1: No Read-Only Root Filesystem

**Error**: `container "myapp" does not have a read-only root file system`

**Fix**:
```kcl
_deployment = {
    spec.template.spec.containers = [{
        securityContext = {
            readOnlyRootFilesystem = True  # ✅ Add read-only root FS
        }
    }]
}
```

**If container needs write access**:
```kcl
_deployment = {
    spec.template.spec = {
        containers = [{
            securityContext = {
                readOnlyRootFilesystem = True
            }
            volumeMounts = [{           # ✅ Add tmpfs for writable dirs
                name = "tmp"
                mountPath = "/tmp"
            }]
        }]
        volumes = [{
            name = "tmp"
            emptyDir = {}
        }]
    }
}
```

#### Issue 2: Not Set to Run as Non-Root

**Error**: `container "myapp" is not set to runAsNonRoot`

**Fix**: See Polaris Issue 5 (same remediation)

#### Issue 3: Missing Resource Limits

**Error**: `container "myapp" has no resource limits`

**Fix**: See Polaris Issues 1 and 2

#### Issue 4: Incorrect Label Schema

**Error**: `object is missing recommended label "app.kubernetes.io/name"`

**Fix**:
```kcl
_deployment = {
    metadata = {
        labels = {
            "app.kubernetes.io/name" = _name               # ✅ Add recommended labels
            "app.kubernetes.io/instance" = _name
            "app.kubernetes.io/version" = _version or "latest"
            "app.kubernetes.io/component" = "application"
            "app.kubernetes.io/part-of" = _name
            "app.kubernetes.io/managed-by" = "crossplane"
        }
    }
}
```

#### Issue 5: Deprecated API Version

**Error**: `object uses deprecated API version "apps/v1beta1"`

**Fix**: Update to current API version:
```kcl
_deployment = {
    apiVersion = "apps/v1"  # ✅ Use current version (not v1beta1, v1beta2)
}
```

---

## Datree - Policy Enforcement

### What Datree Checks

**Policy Rules**:
- Image pull policies
- Image tag validation (no 'latest')
- Network policies
- Service account best practices
- Ingress/Egress policies
- Label requirements

**Custom Policies**:
- Organization-specific rules
- Compliance requirements
- Naming conventions

### Running Datree

**Basic test**:
```bash
datree test /tmp/rendered.yaml --ignore-missing-schemas
```

**Note**: `--ignore-missing-schemas` is required because Crossplane CRDs may not be in Datree's schema registry

**Policy-specific test**:
```bash
datree test /tmp/rendered.yaml --policy=staging --ignore-missing-schemas
```

**JSON output**:
```bash
datree test /tmp/rendered.yaml --ignore-missing-schemas --output json > /tmp/datree-report.json
```

### Interpreting Datree Output

**Example output**:
```
>>  File: /tmp/rendered.yaml

[V] YAML validation
[V] Kubernetes schema validation

[X] Policy check

❌  Ensure each container has a configured liveness probe  [1 occurrence]
    - metadata.name: myapp (kind: Deployment)
💡  Incorrect value for key `livenessProbe` - value should be set (learn more)

❌  Ensure each container image has a pinned (tag) version  [1 occurrence]
    - metadata.name: myapp (kind: Deployment)
💡  Incorrect value for key `image` - add a pinned version to the image (learn more)

⚠️  Ensure Deployment has a configured PodDisruptionBudget  [1 occurrence]
    - metadata.name: myapp (kind: Deployment)
💡  Missing key `PodDisruptionBudget` - add PodDisruptionBudget (learn more)

Summary: 2 rules failed, 1 rule passed, 0 rules skipped, 1 warning
```

### Target: No Violations

**Errors** (❌): Must be fixed before commit
**Warnings** (⚠️): Acceptable if documented (add comment in composition explaining why)

### Common Datree Issues and Fixes

#### Issue 1: Image Tag Validation

**Error**: `Ensure each container image has a pinned (tag) version`

**Cause**: Using `image: nginx:latest` or `image: nginx`

**Fix**:
```kcl
_deployment = {
    spec.template.spec.containers = [{
        image = "nginx:1.25.3"  # ✅ Use specific version tag (not 'latest')
    }]
}
```

**In compositions**, enforce tag validation:
```kcl
# Validate image has a tag
_imageTag = _spec.image.split(":")[-1]
assert _imageTag != "latest", "Image tag 'latest' is not allowed"
assert ":" in _spec.image, "Image must include a version tag"
```

#### Issue 2: Missing Liveness Probe

**Error**: `Ensure each container has a configured liveness probe`

**Fix**: See Polaris Issue 3

#### Issue 3: Missing PodDisruptionBudget

**Warning**: `Ensure Deployment has a configured PodDisruptionBudget`

**Impact**: No guaranteed availability during cluster maintenance

**Fix**:
```kcl
# Add PodDisruptionBudget for HA deployments
if _spec.replicas > 1:
    _items += [{
        apiVersion = "policy/v1"
        kind = "PodDisruptionBudget"
        metadata = {
            name = _name + "-pdb"
            namespace = _namespace
        }
        spec = {
            minAvailable = 1          # ✅ Ensure at least 1 pod available
            selector = {
                matchLabels = {"app": _name}
            }
        }
    }]
```

**Alternative** (for critical services):
```kcl
spec = {
    maxUnavailable = 1  # Only 1 pod can be unavailable at a time
}
```

#### Issue 4: Missing Network Policy

**Warning**: `Ensure NetworkPolicy is configured for workload`

**Impact**: No network segmentation, pods can communicate freely

**Fix** (for App composition):
```kcl
_items += [{
    apiVersion = "cilium.io/v2"
    kind = "CiliumNetworkPolicy"
    metadata = {
        name = _name
        namespace = _namespace
    }
    spec = {
        endpointSelector.matchLabels = {"app": _name}
        ingress = [{
            fromEndpoints = [{
                matchLabels = {
                    "io.kubernetes.pod.namespace" = "infrastructure"
                    "app.kubernetes.io/name" = "cilium-gateway"
                }
            }]
            toPorts = [{
                ports = [{"port": "8080", "protocol": "TCP"}]
            }]
        }]
        egress = [{
            toEndpoints = [{
                matchLabels = {}  # Allow egress (customize as needed)
            }]
        }]
    }
}]
```

#### Issue 5: Service Account Not Set

**Warning**: `Ensure workload uses a dedicated service account`

**Impact**: Uses default service account, broader permissions than needed

**Fix**:
```kcl
# Create ServiceAccount
_items += [{
    apiVersion = "v1"
    kind = "ServiceAccount"
    metadata = {
        name = _name
        namespace = _namespace
    }
}]

# Reference in Deployment
_deployment = {
    spec.template.spec.serviceAccountName = _name  # ✅ Use dedicated SA
}
```

---

## Common Issues and Fixes

### Cross-Tool Issue Matrix

| Issue | Polaris | kube-linter | Datree | Priority |
|-------|---------|-------------|--------|----------|
| Missing resource limits | ✅ | ✅ | ✅ | **Critical** |
| Missing health probes | ✅ | ✅ | ✅ | **Critical** |
| Running as root | ✅ | ✅ | ❌ | **High** |
| Read-only root FS | ✅ | ✅ | ❌ | **High** |
| Image tag 'latest' | ❌ | ❌ | ✅ | **High** |
| Missing PDB | ❌ | ❌ | ✅ | **Medium** |
| Missing Network Policy | ❌ | ❌ | ✅ | **Medium** |
| Missing labels | ❌ | ✅ | ✅ | **Low** |

### Fixing Multiple Issues Simultaneously

**Comprehensive security fix**:
```kcl
_deployment = {
    metadata = {
        labels = {
            "app.kubernetes.io/name" = _name
            "app.kubernetes.io/instance" = _name
            "app.kubernetes.io/version" = _version
            "app.kubernetes.io/managed-by" = "crossplane"
        }
    }
    spec = {
        replicas = _spec.replicas or 3
        template = {
            spec = {
                serviceAccountName = _name           # Dedicated SA
                securityContext = {                  # Pod security
                    runAsNonRoot = True
                    runAsUser = 1000
                    fsGroup = 1000
                }
                containers = [{
                    name = _name
                    image = _spec.image              # Must have version tag
                    securityContext = {              # Container security
                        allowPrivilegeEscalation = False
                        readOnlyRootFilesystem = True
                        runAsNonRoot = True
                        runAsUser = 1000
                        capabilities.drop = ["ALL"]
                    }
                    resources = {                    # Resource limits
                        requests = {
                            cpu = "100m"
                            memory = "128Mi"
                        }
                        limits = {
                            cpu = "500m"
                            memory = "512Mi"
                        }
                    }
                    livenessProbe = {               # Health checks
                        httpGet = {
                            path = "/healthz"
                            port = 8080
                        }
                        initialDelaySeconds = 30
                        periodSeconds = 10
                    }
                    readinessProbe = {
                        httpGet = {
                            path = "/ready"
                            port = 8080
                        }
                        initialDelaySeconds = 5
                        periodSeconds = 5
                    }
                    volumeMounts = [{                # Writable tmp dir
                        name = "tmp"
                        mountPath = "/tmp"
                    }]
                }]
                volumes = [{
                    name = "tmp"
                    emptyDir = {}
                }]
            }
        }
    }
}

# Add PodDisruptionBudget
if _spec.replicas > 1:
    _items += [{
        apiVersion = "policy/v1"
        kind = "PodDisruptionBudget"
        metadata.name = _name + "-pdb"
        spec = {
            minAvailable = 1
            selector.matchLabels = {"app": _name}
        }
    }]
```

---

## CI/CD Integration

### Pre-Commit Hook

```bash
#!/bin/bash
# .git/hooks/pre-commit

# Render composition
cd infrastructure/base/crossplane/configuration
crossplane render examples/app-complete.yaml app-composition.yaml functions.yaml \
  --extra-resources examples/environmentconfig.yaml > /tmp/rendered.yaml

# Run security validation
polaris audit --audit-path /tmp/rendered.yaml --format=score | grep -qE "(8[5-9]|9[0-9]|100)" || {
    echo "❌ Polaris score below 85"
    exit 1
}

kube-linter lint /tmp/rendered.yaml || {
    echo "❌ kube-linter found errors"
    exit 1
}

datree test /tmp/rendered.yaml --ignore-missing-schemas --only-k8s-files || {
    echo "❌ Datree policy violations"
    exit 1
}

echo "✅ Security validation passed"
```

### GitHub Actions

```yaml
name: Composition Validation
on: [pull_request]

jobs:
  validate:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Render Composition
        run: |
          crossplane render \
            examples/app-complete.yaml \
            app-composition.yaml \
            functions.yaml \
            --extra-resources examples/environmentconfig.yaml \
            > rendered.yaml
        working-directory: infrastructure/base/crossplane/configuration

      - name: Polaris Audit
        run: |
          polaris audit --audit-path rendered.yaml --format=score
          score=$(polaris audit --audit-path rendered.yaml --format=score)
          if [[ $score -lt 85 ]]; then
            echo "❌ Polaris score $score is below 85"
            exit 1
          fi

      - name: kube-linter
        run: kube-linter lint rendered.yaml

      - name: Datree
        run: datree test rendered.yaml --ignore-missing-schemas
```

---

## Summary

### Validation Workflow

```bash
# 1. Render composition
crossplane render examples/app.yaml app-composition.yaml functions.yaml \
  --extra-resources examples/environmentconfig.yaml > /tmp/rendered.yaml

# 2. Polaris (target: 85+)
polaris audit --audit-path /tmp/rendered.yaml --format=pretty

# 3. kube-linter (target: zero errors)
kube-linter lint /tmp/rendered.yaml

# 4. Datree (target: no violations)
datree test /tmp/rendered.yaml --ignore-missing-schemas
```

### Minimum Requirements

Before committing composition changes:

✅ Polaris score >= 85
✅ kube-linter reports zero errors
✅ Datree shows no policy violations (warnings documented)
✅ Resource limits defined for all containers
✅ Health probes (liveness + readiness) configured
✅ Security contexts set (non-root, read-only FS)
✅ Images use specific version tags (no 'latest')
✅ HA deployments have PodDisruptionBudget
✅ Network policies defined (where applicable)

### Quick Reference

```bash
# All-in-one validation
polaris audit --audit-path /tmp/rendered.yaml --format=pretty && \
kube-linter lint /tmp/rendered.yaml && \
datree test /tmp/rendered.yaml --ignore-missing-schemas && \
echo "✅ All security checks passed"
```
