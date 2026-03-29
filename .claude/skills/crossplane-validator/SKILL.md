---
name: crossplane-validator
description: Validates Crossplane compositions end-to-end — KCL formatting, syntax, rendering, and security/policy checks (Polaris, kube-linter, Datree). Auto-activates for KCL and composition files.
paths: "infrastructure/base/crossplane/configuration/**"
argument-hint: "[module] - app, cloudnativepg, eks-pod-identity, or all"
allowed-tools: Read, Bash, Grep, Glob
---

# Crossplane Composition Validator

## Quick Start

```bash
# From repository root — validates ALL compositions through all stages
./scripts/validate-kcl-compositions.sh
```

## Four-Stage Validation Pipeline

### Stage 1: KCL Formatting (CI Enforced)

```bash
cd infrastructure/base/crossplane/configuration/kcl/<module>
kcl fmt .
git diff --quiet . || echo "Files reformatted - review and commit"
```

**Rules**: Single-line list comprehensions only. No trailing blank lines.

### Stage 2: KCL Syntax Validation

```bash
cd infrastructure/base/crossplane/configuration/kcl/<module>
kcl run . -Y settings-example.yaml
```

Catches syntax errors, logic errors, type mismatches, reference errors.

### Stage 3: Composition Rendering

```bash
cd infrastructure/base/crossplane/configuration
crossplane render examples/<claim>.yaml <composition>.yaml functions.yaml \
  --extra-resources examples/environmentconfig.yaml > /tmp/rendered.yaml
```

**Debug pipeline issues** (v2.2):
```bash
crossplane render examples/<claim>.yaml <composition>.yaml functions.yaml \
  --include-function-results \
  --extra-resources examples/environmentconfig.yaml
```

**Offline schema validation** (v2.2):
```bash
crossplane render ... > /tmp/rendered.yaml
crossplane beta validate /tmp/rendered.yaml
```

### Stage 4: Security & Policy Validation

| Tool | Target | Command |
|------|--------|---------|
| **Polaris** | Score 85+ | `polaris audit --audit-path /tmp/rendered.yaml --format=pretty` |
| **kube-linter** | No errors | `kube-linter lint /tmp/rendered.yaml` |
| **Datree** | No violations | `datree test /tmp/rendered.yaml --ignore-missing-schemas` |

## Available Compositions

| Composition | File | Examples |
|-------------|------|----------|
| App | `app-composition.yaml` | `app-basic.yaml`, `app-complete.yaml` |
| SQLInstance | `sql-instance-composition.yaml` | `sqlinstance-basic.yaml`, `sqlinstance-complete.yaml` |
| EKS Pod Identity | `epi-composition.yaml` | `epi.yaml` |

## Critical KCL Rules

### NEVER Mutate Resources (function-kcl Issue #285)

Mutating dicts after creation causes **duplicate resources**. function-kcl hashes resources at creation — mutation creates a second hash, producing two copies.

```kcl
# WRONG - Mutation causes DUPLICATES
_deployment = {
    apiVersion = "apps/v1"
    kind = "Deployment"
    metadata.name = _name
    metadata.annotations = {}
}
if _ready:
    _deployment.metadata.annotations["krm.kcl.dev/ready"] = "True"  # MUTATION!
_items += [_deployment]

# CORRECT - Inline conditional
_deployment = {
    apiVersion = "apps/v1"
    kind = "Deployment"
    metadata = {
        name = _name
        annotations = {
            if _ready:
                "krm.kcl.dev/ready" = "True"
        }
    }
}
_items += [_deployment]
```

**Safe**: Inline conditionals, list comprehensions, ternary operators, compute-before-create.
**Unsafe**: Post-creation field assignment (`resource.field = value`), nested mutation, loop mutation.

### Single-Line List Comprehensions (CI Enforced)

```kcl
# WRONG (CI fails)
_ready = any_true([
    c.get("type") == "Available"
    for c in conditions or []
])

# CORRECT
_ready = any_true([c.get("type") == "Available" and c.get("status") == "True" for c in conditions or []])
```

## Rendered Output Analysis

```bash
# Count resources by kind
grep "^kind:" /tmp/rendered.yaml | sort | uniq -c

# Extract specific resource
yq 'select(.kind == "Deployment")' /tmp/rendered.yaml

# Check readiness annotations
grep -B 5 'krm.kcl.dev/ready: "True"' /tmp/rendered.yaml

# Detect duplicate resources
grep "name:" /tmp/rendered.yaml | sort | uniq -d
```

## Native K8s Resource Readiness

Readiness checks use observed cluster state via `option("params").ocds`:

| Resource | Condition |
|----------|-----------|
| Deployment | `status.conditions[type=Available, status=True]` |
| Service | `spec.clusterIP` assigned |
| HTTPRoute | `status.parents[].conditions[type=Accepted, status=True]` |

**Static readiness** (always ready): HPA, PDB, Gateway, CiliumNetworkPolicy, HelmRelease.

## Troubleshooting

| Issue | Fix |
|-------|-----|
| `kcl fmt` makes changes | Review diff, commit formatted version |
| `kcl run` syntax error | Check line number, fix and re-run |
| `crossplane render` fails | Verify example matches schema, check functions.yaml, ensure Docker running |
| Duplicate resources | Search for mutation patterns (`grep -r "\.field = " kcl/`), refactor to inline conditionals |
| Schema validation fails | Run `crossplane beta validate` to identify unknown fields |

## Success Criteria

1. `kcl fmt` makes no changes
2. `kcl run` executes without errors
3. `crossplane render` succeeds for all examples
4. Polaris score 85+ with no critical issues
5. kube-linter reports no errors
6. Datree passes (warnings acceptable if documented)
7. No duplicate resources in rendered output

For detailed KCL patterns and security tool recipes, see [references/kcl-patterns.md](references/kcl-patterns.md).
