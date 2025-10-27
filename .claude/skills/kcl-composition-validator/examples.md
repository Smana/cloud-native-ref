# KCL Composition Patterns and Examples

This document provides practical examples of correct and incorrect KCL patterns for Crossplane compositions.

## Table of Contents

1. [Readiness Checks](#readiness-checks)
2. [Conditional Resources](#conditional-resources)
3. [List Comprehensions](#list-comprehensions)
4. [Annotations and Labels](#annotations-and-labels)
5. [Multi-Resource Compositions](#multi-resource-compositions)
6. [Environment-Based Configuration](#environment-based-configuration)

---

## Readiness Checks

### Pattern: Deployment Readiness

**❌ WRONG - Mutation Pattern**:
```kcl
# Create deployment first
_deployment = {
    apiVersion = "apps/v1"
    kind = "Deployment"
    metadata = {
        name = _name
        namespace = _namespace
        annotations = {
            "app.kubernetes.io/name" = _name
        }
    }
    spec = {
        replicas = 3
        selector.matchLabels = {"app": _name}
        template = {
            metadata.labels = {"app": _name}
            spec.containers = [{
                name = _name
                image = _image
            }]
        }
    }
}

# Check readiness from observed state
_observedDeployment = ocds.get(_name + "-deployment", {})?.Resource
_deploymentReady = any_true([c.get("type") == "Available" and c.get("status") == "True" for c in _observedDeployment?.status?.conditions or []])

# ❌ MUTATION! This creates duplicates
if _deploymentReady:
    _deployment.metadata.annotations["krm.kcl.dev/ready"] = "True"

_items += [_deployment]
```

**✅ CORRECT - Inline Conditional**:
```kcl
# Check readiness FIRST
_observedDeployment = ocds.get(_name + "-deployment", {})?.Resource
_deploymentReady = any_true([c.get("type") == "Available" and c.get("status") == "True" for c in _observedDeployment?.status?.conditions or []])

# Create deployment with inline conditional
_deployment = {
    apiVersion = "apps/v1"
    kind = "Deployment"
    metadata = {
        name = _name
        namespace = _namespace
        annotations = {
            "app.kubernetes.io/name" = _name
            # ✅ Inline conditional - no mutation
            if _deploymentReady:
                "krm.kcl.dev/ready" = "True"
        }
    }
    spec = {
        replicas = 3
        selector.matchLabels = {"app": _name}
        template = {
            metadata.labels = {"app": _name}
            spec.containers = [{
                name = _name
                image = _image
            }]
        }
    }
}

_items += [_deployment]
```

### Pattern: Service Readiness

**✅ CORRECT**:
```kcl
# Check observed Service
_observedService = ocds.get(_name + "-service", {})?.Resource
_serviceReady = _observedService?.spec?.clusterIP != None and _observedService?.spec?.clusterIP != ""

# Create Service with readiness annotation
_service = {
    apiVersion = "v1"
    kind = "Service"
    metadata = {
        name = _name
        namespace = _namespace
        annotations = {
            if _serviceReady:
                "krm.kcl.dev/ready" = "True"
        }
    }
    spec = {
        selector = {"app": _name}
        ports = [{
            port = 80
            targetPort = 8080
        }]
    }
}

_items += [_service]
```

### Pattern: HTTPRoute Readiness

**✅ CORRECT**:
```kcl
# Check HTTPRoute accepted by Gateway
_observedRoute = ocds.get(_name + "-route", {})?.Resource
_routeReady = any_true([c.get("type") == "Accepted" and c.get("status") == "True" for parent in _observedRoute?.status?.parents or [] for c in parent.conditions or []])

# Create HTTPRoute with readiness
_httproute = {
    apiVersion = "gateway.networking.k8s.io/v1"
    kind = "HTTPRoute"
    metadata = {
        name = _name + "-route"
        namespace = _namespace
        annotations = {
            if _routeReady:
                "krm.kcl.dev/ready" = "True"
        }
    }
    spec = {
        parentRefs = [{
            name = "platform-gateway"
            namespace = "infrastructure"
        }]
        hostnames = [_hostname]
        rules = [{
            backendRefs = [{
                name = _name
                port = 80
            }]
        }]
    }
}

_items += [_httproute]
```

---

## Conditional Resources

### Pattern: Optional Database

**❌ WRONG - Post-Creation Modification**:
```kcl
_resources = []

# Always create base resources
_resources += [_deployment, _service]

# ❌ WRONG - Modifying list after creation
if _spec.database?.enabled:
    _resources += [_sqlinstance]
```

**✅ CORRECT - Inline Conditional**:
```kcl
# ✅ Build list with inline conditionals
_items += [_deployment, _service]

# ✅ Conditionally add database
if _spec.database?.enabled:
    _items += [{
        apiVersion = "cloud.ogenki.io/v1alpha1"
        kind = "SQLInstance"
        metadata = {
            name = _name + "-db"
            namespace = _namespace
        }
        spec = {
            size = _spec.database?.size or "small"
            storageSize = _spec.database?.storageSize or "20Gi"
            instances = _spec.database?.instances or 2
        }
    }]
```

### Pattern: Feature Flags

**✅ CORRECT**:
```kcl
# Define feature flags
_enableAutoscaling = _spec.autoscaling?.enabled or False
_enableIngress = _spec.ingress?.enabled or False
_enableMonitoring = _spec.monitoring?.enabled or False

# Conditionally add resources
if _enableAutoscaling:
    _items += [{
        apiVersion = "autoscaling/v2"
        kind = "HorizontalPodAutoscaler"
        metadata = {
            name = _name + "-hpa"
            namespace = _namespace
        }
        spec = {
            scaleTargetRef = {
                apiVersion = "apps/v1"
                kind = "Deployment"
                name = _name
            }
            minReplicas = _spec.autoscaling?.minReplicas or 2
            maxReplicas = _spec.autoscaling?.maxReplicas or 10
        }
    }]

if _enableIngress:
    _items += [_httproute]

if _enableMonitoring:
    _items += [_servicemonitor]
```

---

## List Comprehensions

### Pattern: Multiple Databases

**❌ WRONG - Loop with Mutation**:
```kcl
_databases = []

for db in _spec.databases or []:
    _sqlinstance = {
        apiVersion = "cloud.ogenki.io/v1alpha1"
        kind = "SQLInstance"
        metadata = {
            name = _name + "-" + db.name
            namespace = _namespace
        }
        spec = {
            size = db.size
            storageSize = db.storageSize
        }
    }

    # ❌ WRONG - Mutating in loop
    if db.backup?.enabled:
        _sqlinstance.spec.backup = {
            schedule = db.backup.schedule
            bucketName = db.backup.bucketName
        }

    _databases += [_sqlinstance]

_items += _databases
```

**✅ CORRECT - Single-Line Comprehension**:
```kcl
# ✅ List comprehension with inline conditionals
_items += [{
    apiVersion = "cloud.ogenki.io/v1alpha1"
    kind = "SQLInstance"
    metadata = {
        name = _name + "-" + db.name
        namespace = _namespace
        annotations = {
            if db.highAvailability:
                "ha.cloud.ogenki.io/enabled" = "true"
        }
    }
    spec = {
        size = db.size
        storageSize = db.storageSize
        instances = 3 if db.highAvailability else 1
        if db.backup?.enabled:
            backup = {
                schedule = db.backup.schedule
                bucketName = db.backup.bucketName
            }
    }
} for db in _spec.databases or []]
```

### Pattern: Environment-Specific Services

**✅ CORRECT**:
```kcl
# Get environment config
_environments = ["dev", "staging", "prod"]

# Create services for each environment
_items += [{
    apiVersion = "v1"
    kind = "Service"
    metadata = {
        name = _name + "-" + env
        namespace = _namespace
        labels = {
            "app" = _name
            "environment" = env
            if env == "prod":
                "tier" = "critical"
        }
    }
    spec = {
        selector = {
            "app" = _name
            "environment" = env
        }
        ports = [{
            port = 80
            targetPort = 8080
        }]
        type = "LoadBalancer" if env == "prod" else "ClusterIP"
    }
} for env in _environments]
```

---

## Annotations and Labels

### Pattern: Dynamic Labels Based on Spec

**❌ WRONG - Sequential Mutation**:
```kcl
_labels = {
    "app.kubernetes.io/name" = _name
    "app.kubernetes.io/managed-by" = "crossplane"
}

# ❌ WRONG - Mutating labels dictionary
if _spec.tier:
    _labels["app.kubernetes.io/tier"] = _spec.tier

if _spec.environment:
    _labels["environment"] = _spec.environment

_deployment = {
    metadata = {
        labels = _labels
    }
}
```

**✅ CORRECT - Inline Conditionals**:
```kcl
# ✅ Define all labels inline with conditionals
_deployment = {
    metadata = {
        labels = {
            "app.kubernetes.io/name" = _name
            "app.kubernetes.io/managed-by" = "crossplane"
            if _spec.tier:
                "app.kubernetes.io/tier" = _spec.tier
            if _spec.environment:
                "environment" = _spec.environment
            if _spec.monitoring?.enabled:
                "monitoring" = "enabled"
        }
    }
}
```

### Pattern: Computed Annotations

**✅ CORRECT**:
```kcl
# Compute values first
_imageDigest = _spec.image.split("@")[1] if "@" in _spec.image else "unknown"
_buildTimestamp = _spec.metadata?.buildTimestamp or "unknown"
_gitCommit = _spec.metadata?.gitCommit or "unknown"

# Use computed values in annotations
_deployment = {
    metadata = {
        annotations = {
            "app.kubernetes.io/version" = _spec.version or "latest"
            "build.cloud.ogenki.io/timestamp" = _buildTimestamp
            "build.cloud.ogenki.io/commit" = _gitCommit
            if _imageDigest != "unknown":
                "image.cloud.ogenki.io/digest" = _imageDigest
        }
    }
}
```

---

## Multi-Resource Compositions

### Pattern: Complete Application Stack

**✅ CORRECT - Proper Resource Ordering**:
```kcl
# 1. Compute all values and checks first
_observedDeployment = ocds.get(_name + "-deployment", {})?.Resource
_deploymentReady = any_true([c.get("type") == "Available" and c.get("status") == "True" for c in _observedDeployment?.status?.conditions or []])

_observedService = ocds.get(_name + "-service", {})?.Resource
_serviceReady = _observedService?.spec?.clusterIP != None

_enableDatabase = _spec.database?.enabled or False
_enableCache = _spec.cache?.enabled or False
_enableIngress = _spec.ingress?.enabled or False

# 2. Create infrastructure resources first
if _enableDatabase:
    _items += [{
        apiVersion = "cloud.ogenki.io/v1alpha1"
        kind = "SQLInstance"
        metadata.name = _name + "-db"
        spec = {
            size = _spec.database?.size or "small"
            storageSize = _spec.database?.storageSize or "20Gi"
        }
    }]

if _enableCache:
    _items += [{
        apiVersion = "cloud.ogenki.io/v1alpha1"
        kind = "RedisInstance"
        metadata.name = _name + "-cache"
        spec.size = _spec.cache?.size or "small"
    }]

# 3. Create application resources
_items += [{
    apiVersion = "apps/v1"
    kind = "Deployment"
    metadata = {
        name = _name
        namespace = _namespace
        annotations = {
            if _deploymentReady:
                "krm.kcl.dev/ready" = "True"
        }
    }
    spec = {
        replicas = _spec.replicas or 3
        selector.matchLabels = {"app": _name}
        template = {
            metadata.labels = {"app": _name}
            spec.containers = [{
                name = _name
                image = _spec.image
                env = [
                    if _enableDatabase:
                        {"name": "DB_HOST", "value": _name + "-db"}
                    if _enableCache:
                        {"name": "CACHE_HOST", "value": _name + "-cache"}
                ]
            }]
        }
    }
}]

# 4. Create Service
_items += [{
    apiVersion = "v1"
    kind = "Service"
    metadata = {
        name = _name
        namespace = _namespace
        annotations = {
            if _serviceReady:
                "krm.kcl.dev/ready" = "True"
        }
    }
    spec = {
        selector = {"app": _name}
        ports = [{"port": 80, "targetPort": 8080}]
    }
}]

# 5. Create Ingress if enabled
if _enableIngress:
    _items += [{
        apiVersion = "gateway.networking.k8s.io/v1"
        kind = "HTTPRoute"
        metadata.name = _name + "-route"
        spec = {
            parentRefs = [{"name": "platform-gateway", "namespace": "infrastructure"}]
            hostnames = [_spec.ingress.hostname]
            rules = [{"backendRefs": [{"name": _name, "port": 80}]}]
        }
    }]
```

---

## Environment-Based Configuration

### Pattern: Size-Based Resource Allocation

**✅ CORRECT - Using Ternary and Maps**:
```kcl
# Define size mappings
_sizeMap = {
    "small": {
        "cpu": "500m"
        "memory": "512Mi"
        "replicas": 2
    }
    "medium": {
        "cpu": "1000m"
        "memory": "1Gi"
        "replicas": 3
    }
    "large": {
        "cpu": "2000m"
        "memory": "2Gi"
        "replicas": 5
    }
}

# Get size configuration
_size = _spec.size or "small"
_sizeConfig = _sizeMap[_size]

# Use in deployment
_deployment = {
    spec = {
        replicas = _sizeConfig.replicas
        template.spec.containers = [{
            name = _name
            image = _spec.image
            resources = {
                requests = {
                    cpu = _sizeConfig.cpu
                    memory = _sizeConfig.memory
                }
                limits = {
                    cpu = _sizeConfig.cpu
                    memory = _sizeConfig.memory
                }
            }
        }]
    }
}
```

### Pattern: Environment-Specific Configuration

**✅ CORRECT**:
```kcl
# Get environment from EnvironmentConfig
_env = option("params").oxr?.spec?.environment or "dev"

# Environment-specific settings
_isProd = _env == "prod"
_isStaging = _env == "staging"

# Apply environment-based configuration
_deployment = {
    spec = {
        replicas = 5 if _isProd else 3 if _isStaging else 1
        template.spec = {
            containers = [{
                name = _name
                image = _spec.image
                env = [
                    {"name": "ENVIRONMENT", "value": _env}
                    {"name": "LOG_LEVEL", "value": "error" if _isProd else "info" if _isStaging else "debug"}
                ]
                resources = {
                    limits = {
                        cpu = "2000m" if _isProd else "1000m" if _isStaging else "500m"
                        memory = "2Gi" if _isProd else "1Gi" if _isStaging else "512Mi"
                    }
                }
            }]
            affinity = {
                if _isProd:
                    podAntiAffinity = {
                        requiredDuringSchedulingIgnoredDuringExecution = [{
                            labelSelector.matchLabels = {"app": _name}
                            topologyKey = "kubernetes.io/hostname"
                        }]
                    }
            }
        }
    }
}
```

---

## Common Anti-Patterns to Avoid

### ❌ Building Resources Incrementally

**WRONG**:
```kcl
_deployment = {apiVersion = "apps/v1", kind = "Deployment"}
_deployment.metadata = {name = _name}
_deployment.spec = {replicas = 3}
_deployment.spec.template = {spec = {containers = []}}
```

**CORRECT**:
```kcl
_deployment = {
    apiVersion = "apps/v1"
    kind = "Deployment"
    metadata.name = _name
    spec = {
        replicas = 3
        template.spec.containers = []
    }
}
```

### ❌ Mutating in Conditionals

**WRONG**:
```kcl
_service = {metadata = {annotations = {}}}
if condition:
    _service.metadata.annotations["key"] = "value"
```

**CORRECT**:
```kcl
_service = {
    metadata = {
        annotations = {
            if condition:
                "key" = "value"
        }
    }
}
```

### ❌ Multi-Line List Comprehensions

**WRONG** (CI will fail):
```kcl
_items = [
    {name = item.name, value = item.value}
    for item in items
]
```

**CORRECT**:
```kcl
_items = [{name = item.name, value = item.value} for item in items]
```

---

## Testing Patterns

### Validate with Example Files

Always test with both basic and complete examples:

```bash
# Test basic configuration
crossplane render examples/app-basic.yaml app-composition.yaml functions.yaml \
  --extra-resources examples/environmentconfig.yaml > /tmp/basic.yaml

# Test complete configuration
crossplane render examples/app-complete.yaml app-composition.yaml functions.yaml \
  --extra-resources examples/environmentconfig.yaml > /tmp/complete.yaml

# Verify no duplicates
grep -c "kind: Deployment" /tmp/basic.yaml  # Should be 1
grep -c "kind: Service" /tmp/basic.yaml     # Should be 1
```

### Check Readiness Logic

Test that readiness annotations are added correctly:

```bash
# Render composition
crossplane render examples/app.yaml composition.yaml functions.yaml > /tmp/rendered.yaml

# Check readiness annotations
yq '.metadata.annotations["krm.kcl.dev/ready"]' /tmp/rendered.yaml
```

---

## Summary of Best Practices

1. **Always compute values before creating resources**
2. **Use inline conditionals for dynamic fields**
3. **Prefer list comprehensions over loops**
4. **Keep list comprehensions on single lines**
5. **Never mutate resources after creation**
6. **Test with both basic and complete examples**
7. **Run validation script before every commit**
8. **Check rendered output for duplicates**
