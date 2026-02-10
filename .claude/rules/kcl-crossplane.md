---
description: KCL formatting rules, mutation patterns, and validation for Crossplane compositions
globs:
  - "infrastructure/base/crossplane/configuration/kcl/**/*.k"
  - "infrastructure/base/crossplane/configuration/kcl/**/settings*.yaml"
---

# KCL Crossplane Composition Rules

## Formatting (CI-enforced)

**Always run `kcl fmt` before committing.** The CI will reject unformatted code.

### List Comprehensions: Single-line only

```kcl
# CORRECT
_ready = any_true([c.get("type") == "Available" and c.get("status") == "True" for c in conditions or []])

# WRONG (multi-line) - CI will fail
_ready = any_true([
    c.get("type") == "Available" and c.get("status") == "True"
    for c in conditions or []
])
```

### No Trailing Blank Lines

Remove extra blank lines between logical sections.

## CRITICAL: Avoid Mutation Pattern (function-kcl Issue #285)

**Background**: https://github.com/crossplane-contrib/function-kcl/issues/285

Mutating dictionaries after creation causes function-kcl to create **duplicate resources**.

```kcl
# WRONG - Mutation causes DUPLICATES
_deployment = {
    apiVersion = "apps/v1"
    kind = "Deployment"
    metadata.name = _name
    metadata.annotations = {"base" = "value"}
}
if _deploymentReady:
    _deployment.metadata.annotations["krm.kcl.dev/ready"] = "True"  # MUTATION!
_items += [_deployment]

# CORRECT - Use inline conditionals
_deployment = {
    apiVersion = "apps/v1"
    kind = "Deployment"
    metadata = {
        name = _name
        annotations = {
            "base" = "value"
            if _deploymentReady:
                "krm.kcl.dev/ready" = "True"
        }
    }
}
_items += [_deployment]

# CORRECT - List comprehensions (no mutation)
_items += [{
    apiVersion = "apps/v1"
    kind = "Deployment"
    metadata = {
        name = _name + "-" + db.name
        annotations = {
            "base" = "value"
            if _ready:
                "krm.kcl.dev/ready" = "True"
        }
    }
} for db in databases]
```

**Safe patterns:** Inline conditionals, list comprehensions, ternary operators returning complete dicts.
**Unsafe patterns:** Post-creation field assignment (`resource.field = value`), nested field mutation.

## Validation (REQUIRED before committing)

Run the comprehensive validation script from repository root:

```bash
./scripts/validate-kcl-compositions.sh
```

Three stages per composition:
1. **`kcl fmt`** - Formatting (CI-enforced)
2. **`kcl run`** - Syntax validation with settings-example.yaml
3. **`crossplane render`** - End-to-end pipeline test (requires Docker)

**Tested compositions**: app, cloudnativepg (SQLInstance), eks-pod-identity.
