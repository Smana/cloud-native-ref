# KCL Composition Quick Reference

## Pre-Commit Checklist

```bash
# From repository root - RUN BEFORE EVERY COMMIT
./scripts/validate-kcl-compositions.sh
```

**Target**: ✅ Zero errors, minimal warnings

---

## Three Validation Stages

### 1. Formatting (CI Enforced)
```bash
cd infrastructure/base/crossplane/configuration/kcl/<module>
kcl fmt .
git diff --quiet . || echo "Files reformatted"
```

### 2. Syntax Validation
```bash
cd infrastructure/base/crossplane/configuration/kcl/<module>
kcl run . -Y settings-example.yaml
```

### 3. Render Test
```bash
crossplane render examples/app.yaml app-composition.yaml functions.yaml \
  --extra-resources examples/environmentconfig.yaml
```

---

## Critical Rules

### ❌ NEVER MUTATE RESOURCES (Issue #285)

**WRONG - Causes Duplicates**:
```kcl
_resource = {field = {}}
if condition:
    _resource.field.value = "x"  # ❌ MUTATION!
```

**CORRECT - Inline Conditional**:
```kcl
_resource = {
    field = {
        if condition:
            value = "x"  # ✅ No mutation
    }
}
```

### ✅ Single-Line List Comprehensions

**WRONG** (CI fails):
```kcl
_items = [
    {name = x}
    for x in list
]
```

**CORRECT**:
```kcl
_items = [{name = x} for x in list]
```

---

## Safe Patterns

### Inline Conditionals
```kcl
resource = {
    metadata = {
        annotations = {
            if condition:
                "key" = "value"
        }
    }
}
```

### Ternary Operators
```kcl
replicas = 5 if _isProd else 3 if _isStaging else 1
```

### List Comprehensions
```kcl
_items += [{apiVersion = "v1", kind = "Service", metadata.name = svc.name} for svc in services]
```

### Compute Before Create
```kcl
# Compute values first
_ready = check_readiness()
_size = get_size_config()

# Then create resource
_deployment = {
    metadata = {
        annotations = {
            if _ready:
                "krm.kcl.dev/ready" = "True"
        }
    }
    spec.replicas = _size.replicas
}
```

---

## Unsafe Patterns (AVOID)

### ❌ Post-Creation Assignment
```kcl
resource = {field = {}}
resource.field.key = "value"  # ❌
```

### ❌ Conditional Mutation
```kcl
resource = {field = {}}
if condition:
    resource.field = value  # ❌
```

### ❌ Dictionary Update
```kcl
resource = {annotations = {}}
resource.annotations["key"] = "value"  # ❌
```

### ❌ Loop Mutation
```kcl
resource = {items = []}
for item in items:
    resource.items += [item]  # ❌
```

---

## Readiness Check Patterns

### Deployment
```kcl
_observed = ocds.get(_name + "-deployment", {})?.Resource
_ready = any_true([c.get("type") == "Available" and c.get("status") == "True" for c in _observed?.status?.conditions or []])

_deployment = {
    metadata.annotations = {
        if _ready:
            "krm.kcl.dev/ready" = "True"
    }
}
```

### Service
```kcl
_observed = ocds.get(_name + "-service", {})?.Resource
_ready = _observed?.spec?.clusterIP != None and _observed?.spec?.clusterIP != ""

_service = {
    metadata.annotations = {
        if _ready:
            "krm.kcl.dev/ready" = "True"
    }
}
```

### HTTPRoute
```kcl
_observed = ocds.get(_name + "-route", {})?.Resource
_ready = any_true([c.get("type") == "Accepted" and c.get("status") == "True" for parent in _observed?.status?.parents or [] for c in parent.conditions or []])

_httproute = {
    metadata.annotations = {
        if _ready:
            "krm.kcl.dev/ready" = "True"
    }
}
```

---

## Conditional Resources

```kcl
# Base resources always added
_items += [_deployment, _service]

# Conditional resources
if _spec.database?.enabled:
    _items += [_sqlinstance]

if _spec.autoscaling?.enabled:
    _items += [_hpa]

if _spec.ingress?.enabled:
    _items += [_httproute]
```

---

## Environment-Based Configuration

```kcl
# Get environment
_env = option("params").oxr?.spec?.environment or "dev"
_isProd = _env == "prod"
_isStaging = _env == "staging"

# Apply environment-specific config
_deployment = {
    spec = {
        replicas = 5 if _isProd else 3 if _isStaging else 1
        template.spec.containers = [{
            resources.limits = {
                cpu = "2000m" if _isProd else "1000m" if _isStaging else "500m"
                memory = "2Gi" if _isProd else "1Gi" if _isStaging else "512Mi"
            }
        }]
    }
}
```

---

## Size-Based Configuration

```kcl
# Define size map
_sizeMap = {
    "small": {"cpu": "500m", "memory": "512Mi", "replicas": 2}
    "medium": {"cpu": "1000m", "memory": "1Gi", "replicas": 3}
    "large": {"cpu": "2000m", "memory": "2Gi", "replicas": 5}
}

# Get size config
_size = _spec.size or "small"
_config = _sizeMap[_size]

# Use in resource
_deployment = {
    spec = {
        replicas = _config.replicas
        template.spec.containers = [{
            resources.limits = {
                cpu = _config.cpu
                memory = _config.memory
            }
        }]
    }
}
```

---

## Dynamic Labels/Annotations

```kcl
_deployment = {
    metadata = {
        labels = {
            "app.kubernetes.io/name" = _name
            "app.kubernetes.io/managed-by" = "crossplane"
            if _spec.tier:
                "app.kubernetes.io/tier" = _spec.tier
            if _spec.environment:
                "environment" = _spec.environment
        }
        annotations = {
            "version" = _spec.version or "latest"
            if _spec.monitoring?.enabled:
                "monitoring" = "enabled"
        }
    }
}
```

---

## Debugging Duplicates

### Find Duplicates in Output
```bash
crossplane render examples/app.yaml composition.yaml functions.yaml > /tmp/rendered.yaml
grep -n "kind: Deployment" /tmp/rendered.yaml
# Multiple line numbers = duplicates!
```

### Find Mutation Patterns in Code
```bash
# Direct field assignment
grep -r "\.field = " infrastructure/base/crossplane/configuration/kcl/

# Nested field assignment
grep -r "\[\".*\"\] = " infrastructure/base/crossplane/configuration/kcl/

# Conditional mutations
grep -A 3 "^if " infrastructure/base/crossplane/configuration/kcl/ | grep "    _.*\..*="
```

---

## Common Commands

### Format Single Module
```bash
cd infrastructure/base/crossplane/configuration/kcl/<module>
kcl fmt .
```

### Validate Single Module
```bash
cd infrastructure/base/crossplane/configuration/kcl/<module>
kcl run . -Y settings-example.yaml
```

### Test Specific Example
```bash
cd infrastructure/base/crossplane/configuration
crossplane render examples/app-basic.yaml app-composition.yaml functions.yaml \
  --extra-resources examples/environmentconfig.yaml > /tmp/rendered.yaml
```

### Comprehensive Validation
```bash
# From repository root
./scripts/validate-kcl-compositions.sh
```

---

## Modules Validated

- **app**: Application composition (progressive complexity)
- **cloudnativepg**: PostgreSQL SQLInstance
- **eks-pod-identity**: EKS Pod Identity (IAM roles)

---

## Success Criteria

✅ `kcl fmt` makes no changes
✅ `kcl run` executes without errors
✅ `crossplane render` succeeds for all examples
✅ No duplicate resources in rendered output
✅ Validation script reports zero errors

---

## Quick Tips

1. **Compute values BEFORE creating resources**
2. **Use inline conditionals for dynamic fields**
3. **Keep list comprehensions single-line**
4. **NEVER mutate after creation**
5. **Run validation script before commit**
6. **Check rendered output for duplicates**
7. **Reference examples.md for detailed patterns**
8. **Reference reference.md for mutation bug details**
