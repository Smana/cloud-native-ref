# KCL Resource Mutation Bug - Deep Dive

## Issue Reference

**GitHub Issue**: https://github.com/crossplane-contrib/function-kcl/issues/285

**Title**: Resource mutation causes duplicate resource creation

**Status**: Known issue in function-kcl duplicate detection mechanism

## The Problem

When you modify (mutate) a KCL dictionary or resource after its initial creation, function-kcl's duplicate detection fails and creates multiple copies of the same resource in the rendered output.

### Why This Happens

function-kcl tracks resources by computing a hash of the resource definition. When you mutate a resource after creation:

1. The resource is created with initial hash: `hash1 = hash(resource_v1)`
2. The resource is mutated: `resource.field = new_value`
3. A new hash is computed: `hash2 = hash(resource_v2)`
4. function-kcl sees two different hashes and thinks they're different resources
5. **Both versions are added to the output** (DUPLICATE!)

### Real-World Impact

This bug has caused:
- Multiple identical Deployments in the same namespace (conflict)
- Duplicate Services with the same ClusterIP allocation (failure)
- Multiple HTTPRoutes with conflicting rules
- Failed Crossplane composition reconciliation

## Technical Examples

### Example 1: Conditional Annotation (Common Pattern)

**WRONG - Causes Duplicates**:
```kcl
# Create base deployment
_deployment = {
    apiVersion = "apps/v1"
    kind = "Deployment"
    metadata = {
        name = "myapp"
        namespace = "apps"
        annotations = {}
    }
    spec = {
        replicas = 3
        # ... rest of spec
    }
}

# Check readiness from observed state
_observedDeployment = ocds.get("myapp-deployment", {})?.Resource
_deploymentReady = any_true([
    c.get("type") == "Available" and c.get("status") == "True"
    for c in _observedDeployment?.status?.conditions or []
])

# ❌ MUTATION! Adding annotation after creation
if _deploymentReady:
    _deployment.metadata.annotations["krm.kcl.dev/ready"] = "True"

# This adds the mutated version
# Result: TWO Deployments in output (original + mutated)
_items += [_deployment]
```

**Rendered Output** (Simplified):
```yaml
# Resource 1 (original)
apiVersion: apps/v1
kind: Deployment
metadata:
  name: myapp
  annotations: {}

---
# Resource 2 (mutated) - DUPLICATE!
apiVersion: apps/v1
kind: Deployment
metadata:
  name: myapp
  annotations:
    krm.kcl.dev/ready: "True"
```

**CORRECT - No Duplicates**:
```kcl
# Check readiness BEFORE creating resource
_observedDeployment = ocds.get("myapp-deployment", {})?.Resource
_deploymentReady = any_true([
    c.get("type") == "Available" and c.get("status") == "True"
    for c in _observedDeployment?.status?.conditions or []
])

# ✅ Create deployment with inline conditional
_deployment = {
    apiVersion = "apps/v1"
    kind = "Deployment"
    metadata = {
        name = "myapp"
        namespace = "apps"
        annotations = {
            # ✅ Inline conditional - no mutation
            if _deploymentReady:
                "krm.kcl.dev/ready" = "True"
        }
    }
    spec = {
        replicas = 3
        # ... rest of spec
    }
}

_items += [_deployment]
```

**Rendered Output**:
```yaml
# Only ONE resource
apiVersion: apps/v1
kind: Deployment
metadata:
  name: myapp
  annotations:
    krm.kcl.dev/ready: "True"
```

### Example 2: Dynamic Labels (List Comprehension)

**WRONG - Causes Duplicates**:
```kcl
# Create services for multiple databases
_services = []

for db in databases:
    _service = {
        apiVersion = "v1"
        kind = "Service"
        metadata = {
            name = "db-" + db.name
            labels = {
                "app" = "database"
            }
        }
        spec = {
            # ... service spec
        }
    }

    # ❌ MUTATION! Adding labels after creation
    if db.type == "primary":
        _service.metadata.labels["role"] = "primary"

    _services += [_service]

_items += _services
```

**CORRECT - No Duplicates**:
```kcl
# ✅ Use list comprehension with inline conditional
_items += [{
    apiVersion = "v1"
    kind = "Service"
    metadata = {
        name = "db-" + db.name
        labels = {
            "app" = "database"
            # ✅ Inline conditional - no mutation
            if db.type == "primary":
                "role" = "primary"
        }
    }
    spec = {
        # ... service spec
    }
} for db in databases]
```

### Example 3: Conditional Resource Creation

**WRONG - Causes Duplicates**:
```kcl
# Create base resource
_httproute = {
    apiVersion = "gateway.networking.k8s.io/v1"
    kind = "HTTPRoute"
    metadata = {
        name = _name + "-route"
        annotations = {}
    }
    spec = {
        # ... route spec
    }
}

# ❌ MUTATION! Adding annotation conditionally
if enableTailscale:
    _httproute.metadata.annotations["tailscale.io/expose"] = "true"

_items += [_httproute]
```

**CORRECT - Using Ternary**:
```kcl
# ✅ Use ternary to create complete resource
_httproute = {
    apiVersion = "gateway.networking.k8s.io/v1"
    kind = "HTTPRoute"
    metadata = {
        name = _name + "-route"
        annotations = {
            if enableTailscale:
                "tailscale.io/expose" = "true"
        }
    }
    spec = {
        # ... route spec
    }
}

_items += [_httproute]
```

## Detection Strategies

### How to Find Mutation Patterns in Code

Search for these patterns in your KCL files:

**Pattern 1: Direct field assignment**:
```bash
grep -r "\.field = " infrastructure/base/crossplane/configuration/kcl/
```

Look for: `_resource.metadata.field = value`

**Pattern 2: Nested field assignment**:
```bash
grep -r "\[\".*\"\] = " infrastructure/base/crossplane/configuration/kcl/
```

Look for: `_resource.metadata.annotations["key"] = "value"`

**Pattern 3: Conditional mutation**:
```bash
grep -A 3 "^if " infrastructure/base/crossplane/configuration/kcl/ | grep "    _.*\..*="
```

Look for conditional blocks that assign to resource fields

### Code Review Checklist

When reviewing KCL code, check:

- [ ] Are resources created with all fields defined inline?
- [ ] Are there any assignments to resource fields after creation?
- [ ] Are conditionals using inline `if` within dictionaries?
- [ ] Are list comprehensions creating complete resources?
- [ ] Is there any use of `.field = value` after resource initialization?

## Safe Patterns Summary

### ✅ Inline Conditionals
```kcl
resource = {
    field = {
        if condition:
            "key" = "value"
    }
}
```

### ✅ Ternary Operators
```kcl
resource = {
    field = "value1" if condition else "value2"
}
```

### ✅ List Comprehensions
```kcl
resources = [{
    field = {
        if item.condition:
            "key" = "value"
    }
} for item in items]
```

### ✅ Complete Resource Construction
```kcl
# Compute all values first
_ready = check_readiness()
_labels = compute_labels()

# Create resource with all computed values
resource = {
    metadata = {
        labels = _labels
        annotations = {
            if _ready:
                "ready" = "True"
        }
    }
}
```

## Unsafe Patterns to Avoid

### ❌ Post-Creation Assignment
```kcl
resource = {field = {}}
resource.field.key = "value"  # MUTATION!
```

### ❌ Conditional Mutation
```kcl
resource = {field = {}}
if condition:
    resource.field = new_value  # MUTATION!
```

### ❌ Dictionary Update
```kcl
resource = {metadata = {annotations = {}}}
resource.metadata.annotations["key"] = "value"  # MUTATION!
```

### ❌ Loop-Based Mutation
```kcl
resource = {items = []}
for item in items:
    resource.items += [item]  # MUTATION!
```

## Migration Guide

If you have code with mutation patterns, here's how to refactor:

### Step 1: Identify Mutations
Run grep patterns above to find all mutation instances

### Step 2: Extract Computations
Move all conditional logic and computations before resource creation:

**Before**:
```kcl
resource = {field = {}}
if condition:
    resource.field.value = "computed"
```

**After**:
```kcl
_computed = "computed" if condition else ""
resource = {
    field = {
        if condition:
            value = _computed
    }
}
```

### Step 3: Use Inline Conditionals
Replace post-creation assignments with inline conditionals:

**Before**:
```kcl
resource = {annotations = {}}
if ready:
    resource.annotations["ready"] = "True"
```

**After**:
```kcl
resource = {
    annotations = {
        if ready:
            "ready" = "True"
    }
}
```

### Step 4: Validate
Run the validation script to ensure no duplicates:
```bash
./scripts/validate-kcl-compositions.sh
```

Check rendered output for duplicates:
```bash
crossplane render examples/app.yaml composition.yaml functions.yaml | \
  grep -c "kind: Deployment"  # Should match expected count
```

## Debugging Duplicate Issues

If you see duplicate resources in rendered output:

### Step 1: Confirm Duplicates
```bash
crossplane render examples/app.yaml composition.yaml functions.yaml > /tmp/rendered.yaml
grep -n "kind: Deployment" /tmp/rendered.yaml
# If you see the same resource multiple times at different line numbers, you have duplicates
```

### Step 2: Identify the Source
Search for mutation patterns in the corresponding KCL module:
```bash
cd infrastructure/base/crossplane/configuration/kcl/app
grep -n "\.metadata\." *.k
grep -n "\[\".*\"\] = " *.k
```

### Step 3: Refactor the Pattern
Apply the safe patterns shown above to eliminate mutations

### Step 4: Verify Fix
Re-render and confirm only one instance of each resource:
```bash
crossplane render examples/app.yaml composition.yaml functions.yaml > /tmp/fixed.yaml
grep -c "kind: Deployment" /tmp/fixed.yaml  # Should match expected count
```

## Future Considerations

This is a known issue in function-kcl that may be fixed in future versions. Until then:

1. Always use inline conditionals for dynamic resource fields
2. Complete all computations before creating resources
3. Never mutate resources after creation
4. Validate with `crossplane render` to catch duplicates early
5. Use the validation script before every commit

## Additional Resources

- function-kcl GitHub: https://github.com/crossplane-contrib/function-kcl
- Crossplane Composition Functions: https://docs.crossplane.io/latest/concepts/composition-functions/
- KCL Language Guide: https://kcl-lang.io/docs/reference/lang/tour
