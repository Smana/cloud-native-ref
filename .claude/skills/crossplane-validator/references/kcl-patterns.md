# KCL Patterns & Security Validation Reference

## Mutation Bug Deep Dive (function-kcl Issue #285)

**GitHub**: https://github.com/crossplane-contrib/function-kcl/issues/285

function-kcl tracks resources by computing a hash at creation. Mutation creates a second hash, so both versions appear in output as duplicates.

### Detection

```bash
# Direct field assignment
grep -r "\.field = " infrastructure/base/crossplane/configuration/kcl/

# Nested field assignment
grep -r "\[\".*\"\] = " infrastructure/base/crossplane/configuration/kcl/

# Conditional mutations
grep -A 3 "^if " infrastructure/base/crossplane/configuration/kcl/ | grep "    _.*\..*="

# Verify in rendered output
crossplane render examples/app.yaml app-composition.yaml functions.yaml > /tmp/rendered.yaml
grep -n "kind: Deployment" /tmp/rendered.yaml  # Multiple lines = duplicates
```

### Safe Patterns

**Inline conditionals**:
```kcl
resource = {
    metadata.annotations = {
        if _ready:
            "krm.kcl.dev/ready" = "True"
    }
}
```

**Ternary operators**:
```kcl
replicas = 5 if _isProd else 3 if _isStaging else 1
```

**List comprehensions** (single-line, CI enforced):
```kcl
_items += [{apiVersion = "v1", kind = "Service", metadata.name = svc.name} for svc in services]
```

**Compute before create**:
```kcl
_ready = check_readiness()
_labels = compute_labels()
_deployment = {
    metadata = {
        labels = _labels
        annotations = {
            if _ready:
                "ready" = "True"
        }
    }
}
```

### Unsafe Patterns

```kcl
resource = {field = {}}
resource.field.key = "value"              # Post-creation assignment
if condition:
    resource.field = value                # Conditional mutation
resource.metadata.annotations["k"] = "v" # Dictionary update
for item in items:
    resource.items += [item]              # Loop mutation
```

## Readiness Check Patterns

### Deployment
```kcl
_observed = ocds.get(_name + "-deployment", {})?.Resource
_ready = any_true([c.get("type") == "Available" and c.get("status") == "True" for c in _observed?.status?.conditions or []])
```

### Service
```kcl
_observed = ocds.get(_name + "-service", {})?.Resource
_ready = _observed?.spec?.clusterIP != None and _observed?.spec?.clusterIP != ""
```

### HTTPRoute
```kcl
_observed = ocds.get(_name + "-route", {})?.Resource
_ready = any_true([c.get("type") == "Accepted" and c.get("status") == "True" for parent in _observed?.status?.parents or [] for c in parent.conditions or []])
```

## Security Tool Recipes

### Polaris (Target: 85+)

**Common issues and fixes**:
- Missing resource limits -> Add `requests`/`limits` in composition
- No health checks -> Add liveness/readiness probes
- Running as root -> Add `securityContext` with non-root user
- Privileged containers -> Remove `privileged: true` unless justified

**Score interpretation**: 90-100 Green, 85-89 Yellow (acceptable), 70-84 Orange, <70 Red

### kube-linter (Target: No errors)

**Common issues**: Missing probes, no resource limits, incorrect label schemas, deprecated API versions.

### Datree (Target: No violations, warnings OK)

**Common issues**: Missing `app.kubernetes.io/*` labels, using `latest` tag, missing owner references, network policy gaps.

## Optional: function-unit-test (Experimental)

[crossplane-contrib/function-unit-test](https://github.com/crossplane-contrib/function-unit-test) (v0.1.1) enables CEL-based assertions within the composition pipeline:

```yaml
testCases:
  - description: "All resources have security-setting label"
    assert: |-
      desired.resources.all(r, "labels" in desired.resources[r].resource.metadata &&
      "security-setting" in desired.resources[r].resource.metadata.labels)
```

This is experimental but useful for inline validation of rendered resources.
