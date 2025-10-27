# Crossplane Rendering Examples and Scenarios

This document provides practical examples for rendering and validating Crossplane compositions in various scenarios.

## Table of Contents

1. [Basic Rendering Examples](#basic-rendering-examples)
2. [Testing Different Configurations](#testing-different-configurations)
3. [Debugging Scenarios](#debugging-scenarios)
4. [Security Validation Workflows](#security-validation-workflows)
5. [Development Iteration Patterns](#development-iteration-patterns)

---

## Basic Rendering Examples

### Example 1: Minimal App Configuration

**Claim** (`examples/app-basic.yaml`):
```yaml
apiVersion: cloud.ogenki.io/v1alpha1
kind: App
metadata:
  name: simple-app
  namespace: apps
spec:
  image: nginx:1.25.3
```

**Render**:
```bash
cd infrastructure/base/crossplane/configuration
crossplane render examples/app-basic.yaml app-composition.yaml functions.yaml \
  --extra-resources examples/environmentconfig.yaml > /tmp/simple-app.yaml
```

**Expected Resources**:
- 1 Deployment
- 1 Service
- 0 additional resources (no database, cache, etc.)

**Verify**:
```bash
# Count resources
grep -c "kind: Deployment" /tmp/simple-app.yaml  # Should be 1
grep -c "kind: Service" /tmp/simple-app.yaml     # Should be 1

# Check image
yq 'select(.kind == "Deployment") | .spec.template.spec.containers[0].image' /tmp/simple-app.yaml
# Output: nginx:1.25.3
```

### Example 2: App with Database

**Claim**:
```yaml
apiVersion: cloud.ogenki.io/v1alpha1
kind: App
metadata:
  name: app-with-db
  namespace: apps
spec:
  image: myapp:v1.2.3
  database:
    enabled: true
    size: small
    storageSize: 20Gi
```

**Render**:
```bash
crossplane render /tmp/app-with-db.yaml app-composition.yaml functions.yaml \
  --extra-resources examples/environmentconfig.yaml > /tmp/app-db.yaml
```

**Expected Resources**:
- 1 Deployment (app)
- 1 Service (app)
- 1 SQLInstance (database)

**Verify Database**:
```bash
# Check SQLInstance created
yq 'select(.kind == "SQLInstance") | .metadata.name' /tmp/app-db.yaml
# Output: app-with-db-sqlinstance

# Check database size
yq 'select(.kind == "SQLInstance") | .spec.size' /tmp/app-db.yaml
# Output: small

# Check storage
yq 'select(.kind == "SQLInstance") | .spec.storageSize' /tmp/app-db.yaml
# Output: 20Gi
```

### Example 3: Complete Production App

**Claim** (`examples/app-complete.yaml`):
```yaml
apiVersion: cloud.ogenki.io/v1alpha1
kind: App
metadata:
  name: prod-app
  namespace: apps
spec:
  image: myapp:v2.0.0
  replicas: 5
  database:
    enabled: true
    size: large
    storageSize: 100Gi
    instances: 3
  cache:
    enabled: true
    size: medium
  storage:
    enabled: true
    bucketName: prod-app-assets
  autoscaling:
    enabled: true
    minReplicas: 3
    maxReplicas: 10
  ingress:
    enabled: true
    hostname: app.priv.cloud.ogenki.io
```

**Render**:
```bash
crossplane render examples/app-complete.yaml app-composition.yaml functions.yaml \
  --extra-resources examples/environmentconfig.yaml > /tmp/prod-app.yaml
```

**Expected Resources**:
- 1 Deployment
- 1 Service
- 1 SQLInstance (PostgreSQL)
- 1 RedisInstance (cache)
- 1 S3 Bucket
- 1 HorizontalPodAutoscaler
- 1 PodDisruptionBudget
- 1 HTTPRoute
- 1 CiliumNetworkPolicy

**Verify All Resources**:
```bash
# Count all resources
grep "^kind:" /tmp/prod-app.yaml | sort | uniq -c

# Expected output:
#   1 CiliumNetworkPolicy
#   1 Deployment
#   1 HorizontalPodAutoscaler
#   1 HTTPRoute
#   1 PodDisruptionBudget
#   1 S3Bucket
#   1 SQLInstance
#   1 RedisInstance
#   1 Service
```

---

## Testing Different Configurations

### Scenario 1: Testing Autoscaling Configuration

**Create test claim**:
```bash
cat > /tmp/test-autoscaling.yaml <<EOF
apiVersion: cloud.ogenki.io/v1alpha1
kind: App
metadata:
  name: test-hpa
  namespace: apps
spec:
  image: nginx:1.25.3
  replicas: 3
  autoscaling:
    enabled: true
    minReplicas: 2
    maxReplicas: 20
    targetCPUUtilizationPercentage: 70
EOF
```

**Render and verify**:
```bash
cd infrastructure/base/crossplane/configuration
crossplane render /tmp/test-autoscaling.yaml app-composition.yaml functions.yaml \
  --extra-resources examples/environmentconfig.yaml > /tmp/test-hpa.yaml

# Check HPA configuration
yq 'select(.kind == "HorizontalPodAutoscaler") | .spec' /tmp/test-hpa.yaml
```

**Expected HPA spec**:
```yaml
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: test-hpa
  minReplicas: 2
  maxReplicas: 20
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 70
```

### Scenario 2: Testing High Availability Configuration

**Create HA claim**:
```bash
cat > /tmp/test-ha.yaml <<EOF
apiVersion: cloud.ogenki.io/v1alpha1
kind: App
metadata:
  name: ha-app
  namespace: apps
spec:
  image: myapp:v1.0.0
  replicas: 5
  database:
    enabled: true
    size: large
    instances: 3
    highAvailability: true
EOF
```

**Render**:
```bash
crossplane render /tmp/test-ha.yaml app-composition.yaml functions.yaml \
  --extra-resources examples/environmentconfig.yaml > /tmp/ha-app.yaml
```

**Verify HA features**:
```bash
# Check deployment replicas
yq 'select(.kind == "Deployment") | .spec.replicas' /tmp/ha-app.yaml
# Expected: 5

# Check PodDisruptionBudget
yq 'select(.kind == "PodDisruptionBudget") | .spec' /tmp/ha-app.yaml

# Check database instances
yq 'select(.kind == "SQLInstance") | .spec.instances' /tmp/ha-app.yaml
# Expected: 3

# Check anti-affinity rules
yq 'select(.kind == "Deployment") | .spec.template.spec.affinity.podAntiAffinity' /tmp/ha-app.yaml
```

### Scenario 3: Testing Network Policy

**Render app with ingress**:
```bash
cat > /tmp/test-netpol.yaml <<EOF
apiVersion: cloud.ogenki.io/v1alpha1
kind: App
metadata:
  name: netpol-app
  namespace: apps
spec:
  image: nginx:1.25.3
  ingress:
    enabled: true
    hostname: netpol.priv.cloud.ogenki.io
EOF

crossplane render /tmp/test-netpol.yaml app-composition.yaml functions.yaml \
  --extra-resources examples/environmentconfig.yaml > /tmp/netpol.yaml
```

**Verify network policy**:
```bash
# Check CiliumNetworkPolicy created
yq 'select(.kind == "CiliumNetworkPolicy") | .spec' /tmp/netpol.yaml

# Expected ingress rules (from Gateway)
yq 'select(.kind == "CiliumNetworkPolicy") | .spec.ingress' /tmp/netpol.yaml
```

---

## Debugging Scenarios

### Scenario 1: Composition Doesn't Render

**Problem**: Render command fails with error

**Debug steps**:

1. **Check Docker is running**:
```bash
docker info
# If fails: sudo systemctl start docker
```

2. **Verify file paths**:
```bash
ls -l infrastructure/base/crossplane/configuration/app-composition.yaml
ls -l infrastructure/base/crossplane/configuration/functions.yaml
ls -l infrastructure/base/crossplane/configuration/examples/environmentconfig.yaml
```

3. **Validate YAML syntax**:
```bash
yq . examples/app-basic.yaml
yq . app-composition.yaml
yq . functions.yaml
```

4. **Check composition syntax**:
```bash
# Validate composition structure
kubectl --dry-run=client -f app-composition.yaml
```

5. **Run with verbose output**:
```bash
crossplane render examples/app-basic.yaml app-composition.yaml functions.yaml \
  --extra-resources examples/environmentconfig.yaml --verbose
```

### Scenario 2: Unexpected Resources in Output

**Problem**: Rendered output contains wrong resources or duplicates

**Debug steps**:

1. **Count resources**:
```bash
grep "^kind:" /tmp/rendered.yaml | sort | uniq -c
```

2. **Check for duplicates**:
```bash
# Find duplicate resource names
grep "  name:" /tmp/rendered.yaml | sort | uniq -d
```

3. **Verify claim matches composition**:
```bash
# Check claim apiVersion and kind
yq '.apiVersion, .kind' examples/app-basic.yaml

# Check composition matches
yq '.spec.compositeTypeRef' app-composition.yaml
```

4. **Inspect KCL code**:
```bash
# Check for mutation patterns (see kcl-composition-validator skill)
grep -n "\.metadata\." infrastructure/base/crossplane/configuration/kcl/app/*.k
```

5. **Test with minimal claim**:
```bash
cat > /tmp/minimal.yaml <<EOF
apiVersion: cloud.ogenki.io/v1alpha1
kind: App
metadata:
  name: minimal
  namespace: apps
spec:
  image: nginx:1.25
EOF

crossplane render /tmp/minimal.yaml app-composition.yaml functions.yaml \
  --extra-resources examples/environmentconfig.yaml
```

### Scenario 3: Resources Missing Expected Fields

**Problem**: Rendered resources don't have expected configuration

**Debug steps**:

1. **Check specific resource**:
```bash
# Extract Deployment
yq 'select(.kind == "Deployment")' /tmp/rendered.yaml > /tmp/deployment.yaml

# Inspect full spec
cat /tmp/deployment.yaml
```

2. **Verify environment config**:
```bash
# Check EnvironmentConfig values
yq '.data' examples/environmentconfig.yaml
```

3. **Test KCL logic directly**:
```bash
cd infrastructure/base/crossplane/configuration/kcl/app
kcl run . -Y settings-example.yaml
```

4. **Check function pipeline**:
```bash
# Verify functions.yaml configuration
yq '.spec.pipeline' ../functions.yaml
```

### Scenario 4: Security Validation Fails

**Problem**: Polaris/kube-linter/Datree report errors

**Debug workflow**:

1. **Identify specific issue**:
```bash
# Run Polaris
polaris audit --audit-path /tmp/rendered.yaml --format=pretty | grep "✗"

# Run kube-linter
kube-linter lint /tmp/rendered.yaml

# Run Datree
datree test /tmp/rendered.yaml --ignore-missing-schemas
```

2. **Extract failing resource**:
```bash
# Get resource with issue
yq 'select(.metadata.name == "myapp" and .kind == "Deployment")' /tmp/rendered.yaml
```

3. **Fix in KCL composition**:
```bash
# Edit the KCL code
vim infrastructure/base/crossplane/configuration/kcl/app/main.k

# Re-render
crossplane render examples/app-complete.yaml app-composition.yaml functions.yaml \
  --extra-resources examples/environmentconfig.yaml > /tmp/fixed.yaml

# Re-validate
polaris audit --audit-path /tmp/fixed.yaml --format=pretty
```

4. **Compare before/after**:
```bash
diff -u /tmp/rendered.yaml /tmp/fixed.yaml | less
```

---

## Security Validation Workflows

### Workflow 1: Complete Security Audit

**Full validation pipeline**:

```bash
#!/bin/bash
set -euo pipefail

# Configuration
COMPOSITION="app-composition.yaml"
EXAMPLE="examples/app-complete.yaml"
OUTPUT="/tmp/security-audit.yaml"

cd infrastructure/base/crossplane/configuration

# Step 1: Render
echo "🎨 Rendering composition..."
crossplane render "$EXAMPLE" "$COMPOSITION" functions.yaml \
  --extra-resources examples/environmentconfig.yaml > "$OUTPUT"

# Step 2: Polaris
echo "🔒 Running Polaris security audit..."
POLARIS_SCORE=$(polaris audit --audit-path "$OUTPUT" --format=score)
echo "   Polaris Score: $POLARIS_SCORE"

if [[ $POLARIS_SCORE -lt 85 ]]; then
    echo "   ❌ Score below 85, showing details:"
    polaris audit --audit-path "$OUTPUT" --format=pretty
    exit 1
fi

# Step 3: kube-linter
echo "🔍 Running kube-linter..."
if kube-linter lint "$OUTPUT"; then
    echo "   ✅ kube-linter passed"
else
    echo "   ❌ kube-linter found issues"
    exit 1
fi

# Step 4: Datree
echo "📋 Running Datree policy check..."
if datree test "$OUTPUT" --ignore-missing-schemas; then
    echo "   ✅ Datree passed"
else
    echo "   ❌ Datree found policy violations"
    exit 1
fi

echo ""
echo "✅ All security checks passed!"
echo "   Polaris: $POLARIS_SCORE"
echo "   kube-linter: PASS"
echo "   Datree: PASS"
```

### Workflow 2: Progressive Security Fixing

**Iterative improvement process**:

```bash
# 1. Initial render
crossplane render examples/app-complete.yaml app-composition.yaml functions.yaml \
  --extra-resources examples/environmentconfig.yaml > /tmp/v1.yaml

# 2. First audit (collect all issues)
polaris audit --audit-path /tmp/v1.yaml --format=pretty > /tmp/polaris-v1.txt
kube-linter lint /tmp/v1.yaml > /tmp/kube-linter-v1.txt 2>&1 || true
datree test /tmp/v1.yaml --ignore-missing-schemas > /tmp/datree-v1.txt 2>&1 || true

# 3. Fix issues in KCL
vim infrastructure/base/crossplane/configuration/kcl/app/main.k

# 4. Re-render and compare
crossplane render examples/app-complete.yaml app-composition.yaml functions.yaml \
  --extra-resources examples/environmentconfig.yaml > /tmp/v2.yaml

polaris audit --audit-path /tmp/v2.yaml --format=pretty > /tmp/polaris-v2.txt

# 5. Compare scores
echo "Before:"
grep "Final score" /tmp/polaris-v1.txt
echo "After:"
grep "Final score" /tmp/polaris-v2.txt

# 6. Repeat until score >= 85
```

### Workflow 3: CI/CD Integration Test

**Test locally before pushing**:

```bash
#!/bin/bash
# Simulate CI validation

FAILED=0

# Test all examples
for EXAMPLE in examples/app-*.yaml; do
    echo "Testing $EXAMPLE..."

    OUTPUT="/tmp/$(basename $EXAMPLE .yaml)-rendered.yaml"

    crossplane render "$EXAMPLE" app-composition.yaml functions.yaml \
      --extra-resources examples/environmentconfig.yaml > "$OUTPUT"

    # Polaris
    SCORE=$(polaris audit --audit-path "$OUTPUT" --format=score)
    if [[ $SCORE -lt 85 ]]; then
        echo "  ❌ Polaris: $SCORE (< 85)"
        FAILED=1
    else
        echo "  ✅ Polaris: $SCORE"
    fi

    # kube-linter
    if kube-linter lint "$OUTPUT" > /dev/null 2>&1; then
        echo "  ✅ kube-linter: PASS"
    else
        echo "  ❌ kube-linter: FAIL"
        FAILED=1
    fi

    # Datree
    if datree test "$OUTPUT" --ignore-missing-schemas > /dev/null 2>&1; then
        echo "  ✅ Datree: PASS"
    else
        echo "  ❌ Datree: FAIL"
        FAILED=1
    fi
done

exit $FAILED
```

---

## Development Iteration Patterns

### Pattern 1: Rapid Feature Development

**Goal**: Quick iteration when adding new features

```bash
#!/bin/bash
# Quick dev loop

COMPOSITION="app-composition.yaml"
EXAMPLE="/tmp/dev-test.yaml"

# Create test claim
cat > "$EXAMPLE" <<EOF
apiVersion: cloud.ogenki.io/v1alpha1
kind: App
metadata:
  name: dev-test
  namespace: apps
spec:
  image: nginx:1.25.3
  # Add feature being tested
  newFeature:
    enabled: true
    setting: value
EOF

# Watch for changes and re-render
while true; do
    clear
    echo "🔄 Rendering..."

    if crossplane render "$EXAMPLE" "$COMPOSITION" functions.yaml \
         --extra-resources examples/environmentconfig.yaml > /tmp/dev.yaml 2>&1; then
        echo "✅ Render successful"
        echo ""
        echo "Resources created:"
        grep "^kind:" /tmp/dev.yaml | sort | uniq -c
    else
        echo "❌ Render failed"
    fi

    echo ""
    echo "Press Ctrl+C to stop, or wait 5s for next check..."
    sleep 5
done
```

### Pattern 2: Feature Flag Testing

**Goal**: Test different feature combinations

```bash
#!/bin/bash
# Test matrix of feature flags

FEATURES=(
    "database:true cache:false"
    "database:false cache:true"
    "database:true cache:true"
    "autoscaling:true ingress:true"
)

for COMBO in "${FEATURES[@]}"; do
    echo "Testing: $COMBO"

    # Parse features
    IFS=' ' read -ra OPTS <<< "$COMBO"

    # Generate claim
    cat > /tmp/test-combo.yaml <<EOF
apiVersion: cloud.ogenki.io/v1alpha1
kind: App
metadata:
  name: test-combo
  namespace: apps
spec:
  image: nginx:1.25.3
EOF

    for OPT in "${OPTS[@]}"; do
        IFS=':' read -r FEATURE VALUE <<< "$OPT"
        echo "  $FEATURE:" >> /tmp/test-combo.yaml
        echo "    enabled: $VALUE" >> /tmp/test-combo.yaml
    done

    # Render and validate
    if crossplane render /tmp/test-combo.yaml app-composition.yaml functions.yaml \
         --extra-resources examples/environmentconfig.yaml > /tmp/combo.yaml 2>&1; then
        RESOURCES=$(grep "^kind:" /tmp/combo.yaml | wc -l)
        echo "  ✅ Rendered $RESOURCES resources"
    else
        echo "  ❌ Failed"
    fi
done
```

### Pattern 3: Comparison Testing

**Goal**: Compare different configuration sizes

```bash
#!/bin/bash
# Compare small/medium/large configurations

SIZES=("small" "medium" "large")

for SIZE in "${SIZES[@]}"; do
    cat > /tmp/test-$SIZE.yaml <<EOF
apiVersion: cloud.ogenki.io/v1alpha1
kind: App
metadata:
  name: test-$SIZE
  namespace: apps
spec:
  image: nginx:1.25.3
  size: $SIZE
  database:
    enabled: true
    size: $SIZE
EOF

    crossplane render /tmp/test-$SIZE.yaml app-composition.yaml functions.yaml \
      --extra-resources examples/environmentconfig.yaml > /tmp/rendered-$SIZE.yaml

    echo "Size: $SIZE"
    echo "  Deployment replicas:"
    yq 'select(.kind == "Deployment") | .spec.replicas' /tmp/rendered-$SIZE.yaml

    echo "  CPU limit:"
    yq 'select(.kind == "Deployment") | .spec.template.spec.containers[0].resources.limits.cpu' /tmp/rendered-$SIZE.yaml

    echo "  Memory limit:"
    yq 'select(.kind == "Deployment") | .spec.template.spec.containers[0].resources.limits.memory' /tmp/rendered-$SIZE.yaml
    echo ""
done
```

---

## Summary

### Quick Commands Reference

```bash
# Basic render
crossplane render examples/app-basic.yaml app-composition.yaml functions.yaml \
  --extra-resources examples/environmentconfig.yaml

# Full security audit
polaris audit --audit-path /tmp/rendered.yaml --format=pretty && \
kube-linter lint /tmp/rendered.yaml && \
datree test /tmp/rendered.yaml --ignore-missing-schemas

# Resource analysis
grep "^kind:" /tmp/rendered.yaml | sort | uniq -c
yq 'select(.kind == "Deployment")' /tmp/rendered.yaml

# Duplicate detection
grep "  name:" /tmp/rendered.yaml | sort | uniq -d
```

### Best Practices

1. **Always test with multiple examples** (basic + complete)
2. **Run security validation before commit**
3. **Use minimal claims during development** for faster iteration
4. **Compare rendered output** when making changes
5. **Check for duplicates** after every render
6. **Validate KCL separately** with kcl-composition-validator skill
