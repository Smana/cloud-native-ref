# Crossplane Renderer Quick Reference

## Basic Rendering

### Standard Command Pattern
```bash
cd infrastructure/base/crossplane/configuration

crossplane render \
  examples/<claim>.yaml \
  <composition>.yaml \
  functions.yaml \
  --extra-resources examples/environmentconfig.yaml \
  > /tmp/rendered.yaml
```

### Available Compositions

| Composition | Examples | Description |
|-------------|----------|-------------|
| `app-composition.yaml` | `app-basic.yaml`<br/>`app-complete.yaml` | Progressive app deployment |
| `sql-instance-composition.yaml` | `sqlinstance-basic.yaml`<br/>`sqlinstance-complete.yaml` | PostgreSQL databases |
| `epi-composition.yaml` | `epi.yaml` | EKS Pod Identity (IAM roles) |

---

## Common Rendering Commands

### App Compositions

**Minimal app**:
```bash
crossplane render examples/app-basic.yaml app-composition.yaml functions.yaml \
  --extra-resources examples/environmentconfig.yaml > /tmp/app-basic.yaml
```

**Production app** (all features):
```bash
crossplane render examples/app-complete.yaml app-composition.yaml functions.yaml \
  --extra-resources examples/environmentconfig.yaml > /tmp/app-complete.yaml
```

### Database Compositions

**Basic database**:
```bash
crossplane render examples/sqlinstance-basic.yaml sql-instance-composition.yaml functions.yaml \
  --extra-resources examples/environmentconfig.yaml > /tmp/db-basic.yaml
```

**Production database** (HA + backup):
```bash
crossplane render examples/sqlinstance-complete.yaml sql-instance-composition.yaml functions.yaml \
  --extra-resources examples/environmentconfig.yaml > /tmp/db-complete.yaml
```

### EKS Pod Identity

**IAM role for pods**:
```bash
crossplane render examples/epi.yaml epi-composition.yaml functions.yaml \
  --extra-resources examples/environmentconfig.yaml > /tmp/epi.yaml
```

---

## Security Validation

### All-in-One Validation
```bash
polaris audit --audit-path /tmp/rendered.yaml --format=pretty && \
kube-linter lint /tmp/rendered.yaml && \
datree test /tmp/rendered.yaml --ignore-missing-schemas && \
echo "✅ All checks passed"
```

### Individual Tools

**Polaris** (target: 85+):
```bash
polaris audit --audit-path /tmp/rendered.yaml --format=pretty
polaris audit --audit-path /tmp/rendered.yaml --format=score  # Score only
```

**kube-linter** (target: zero errors):
```bash
kube-linter lint /tmp/rendered.yaml
kube-linter lint /tmp/rendered.yaml --format=json  # JSON output
```

**Datree** (target: no violations):
```bash
datree test /tmp/rendered.yaml --ignore-missing-schemas
datree test /tmp/rendered.yaml --ignore-missing-schemas --output json  # JSON output
```

---

## Resource Analysis

### Count Resources
```bash
# All resources by kind
grep "^kind:" /tmp/rendered.yaml | sort | uniq -c

# Specific resource count
grep -c "kind: Deployment" /tmp/rendered.yaml
grep -c "kind: Service" /tmp/rendered.yaml
grep -c "kind: SQLInstance" /tmp/rendered.yaml
```

### Extract Specific Resource
```bash
# Get Deployment
yq 'select(.kind == "Deployment")' /tmp/rendered.yaml

# Get Service
yq 'select(.kind == "Service")' /tmp/rendered.yaml

# Get HTTPRoute
yq 'select(.kind == "HTTPRoute")' /tmp/rendered.yaml

# Get all resources of a kind
yq 'select(.kind == "Deployment")' /tmp/rendered.yaml > /tmp/deployment.yaml
```

### Inspect Resource Fields
```bash
# Deployment replicas
yq 'select(.kind == "Deployment") | .spec.replicas' /tmp/rendered.yaml

# Container image
yq 'select(.kind == "Deployment") | .spec.template.spec.containers[0].image' /tmp/rendered.yaml

# Resource limits
yq 'select(.kind == "Deployment") | .spec.template.spec.containers[0].resources' /tmp/rendered.yaml

# Service type
yq 'select(.kind == "Service") | .spec.type' /tmp/rendered.yaml

# HTTPRoute hostnames
yq 'select(.kind == "HTTPRoute") | .spec.hostnames' /tmp/rendered.yaml
```

---

## Duplicate Detection

### Find Duplicates
```bash
# Count Deployments (should match expected)
grep -c "kind: Deployment" /tmp/rendered.yaml

# Find duplicate resource names
grep "  name:" /tmp/rendered.yaml | sort | uniq -d

# Show all resource names
grep "  name:" /tmp/rendered.yaml | sort
```

### Check Readiness Annotations
```bash
# Resources marked as ready
grep -B 5 'krm.kcl.dev/ready: "True"' /tmp/rendered.yaml

# Count ready resources
grep -c 'krm.kcl.dev/ready: "True"' /tmp/rendered.yaml
```

---

## Development Workflows

### Quick Iteration
```bash
# 1. Edit composition
vim infrastructure/base/crossplane/configuration/kcl/app/main.k

# 2. Render
crossplane render examples/app-complete.yaml app-composition.yaml functions.yaml \
  --extra-resources examples/environmentconfig.yaml > /tmp/test.yaml

# 3. Check output
less /tmp/test.yaml
grep "^kind:" /tmp/test.yaml | sort | uniq -c

# 4. Validate (optional during dev)
polaris audit --audit-path /tmp/test.yaml --format=pretty
```

### Custom Test Claim
```bash
# Create custom claim
cat > /tmp/my-test.yaml <<EOF
apiVersion: cloud.ogenki.io/v1alpha1
kind: App
metadata:
  name: my-test
  namespace: apps
spec:
  image: nginx:1.25.3
  database:
    enabled: true
    size: small
EOF

# Render custom claim
crossplane render /tmp/my-test.yaml app-composition.yaml functions.yaml \
  --extra-resources examples/environmentconfig.yaml > /tmp/my-test-rendered.yaml
```

### Compare Configurations
```bash
# Render basic
crossplane render examples/app-basic.yaml app-composition.yaml functions.yaml \
  --extra-resources examples/environmentconfig.yaml > /tmp/basic.yaml

# Render complete
crossplane render examples/app-complete.yaml app-composition.yaml functions.yaml \
  --extra-resources examples/environmentconfig.yaml > /tmp/complete.yaml

# Compare
diff -u /tmp/basic.yaml /tmp/complete.yaml | less
```

---

## Complete Validation Workflow

### Pre-Commit Checklist

```bash
# 1. Validate KCL (formatting, syntax, render)
./scripts/validate-kcl-compositions.sh

# 2. Security validation for each composition
cd infrastructure/base/crossplane/configuration

crossplane render examples/app-complete.yaml app-composition.yaml functions.yaml \
  --extra-resources examples/environmentconfig.yaml > /tmp/app.yaml

polaris audit --audit-path /tmp/app.yaml --format=pretty
kube-linter lint /tmp/app.yaml
datree test /tmp/app.yaml --ignore-missing-schemas
```

**Expected Results**:
- ✅ All KCL validations pass
- ✅ Polaris score >= 85
- ✅ kube-linter: zero errors
- ✅ Datree: no violations (warnings acceptable if documented)

---

## Troubleshooting

### Docker Not Available
```bash
# Check Docker status
docker info

# Start Docker
sudo systemctl start docker

# Alternative: use podman
alias docker=podman
```

### Composition Not Found
```bash
# Verify you're in the right directory
pwd
# Expected: /path/to/cloud-native-ref/infrastructure/base/crossplane/configuration

# Check files exist
ls -l app-composition.yaml
ls -l functions.yaml
ls -l examples/environmentconfig.yaml
```

### Function Errors
```bash
# Check function images are accessible
docker pull xpkg.upbound.io/crossplane-contrib/function-kcl:latest

# Validate functions.yaml
yq . functions.yaml
```

### Invalid Output
```bash
# Validate YAML syntax
yq . /tmp/rendered.yaml

# Check for KCL issues (use kcl-composition-validator skill)
cd infrastructure/base/crossplane/configuration/kcl/app
kcl fmt .
kcl run . -Y settings-example.yaml
```

---

## Integration with KCL Validator

### Complete Validation (KCL + Rendering + Security)

**Step 1: KCL Validation**
```bash
./scripts/validate-kcl-compositions.sh
```
This runs:
- Stage 1: KCL formatting
- Stage 2: KCL syntax
- Stage 3: Crossplane render

**Step 2: Security Validation** (additional)
```bash
cd infrastructure/base/crossplane/configuration

for EXAMPLE in examples/app-*.yaml; do
    OUTPUT="/tmp/$(basename $EXAMPLE .yaml).yaml"

    crossplane render "$EXAMPLE" app-composition.yaml functions.yaml \
      --extra-resources examples/environmentconfig.yaml > "$OUTPUT"

    polaris audit --audit-path "$OUTPUT" --format=pretty
    kube-linter lint "$OUTPUT"
    datree test "$OUTPUT" --ignore-missing-schemas
done
```

---

## Quick Tips

### Faster Iteration
- Use minimal claims during development
- Run full validation only before commit
- Cache function images locally

### Resource Debugging
- Extract specific resources with `yq`
- Count resources to detect duplicates
- Check readiness annotations

### Security First
- Polaris: Focus on critical issues first
- kube-linter: Fix all errors
- Datree: Document accepted warnings

### Best Practices
1. Always test both basic and complete examples
2. Run security validation before commit
3. Check for duplicate resources
4. Validate resource limits and health probes
5. Verify image tags (no 'latest')

---

## Common File Paths

```
infrastructure/base/crossplane/configuration/
├── app-composition.yaml                   # App composition
├── sql-instance-composition.yaml          # Database composition
├── epi-composition.yaml                   # EKS Pod Identity
├── functions.yaml                         # Function pipeline
├── examples/
│   ├── app-basic.yaml                     # Minimal app
│   ├── app-complete.yaml                  # Full-featured app
│   ├── sqlinstance-basic.yaml             # Basic database
│   ├── sqlinstance-complete.yaml          # Production database
│   ├── epi.yaml                           # EKS Pod Identity example
│   └── environmentconfig.yaml             # Environment config (required)
└── kcl/
    ├── app/                               # App KCL code
    ├── cloudnativepg/                     # Database KCL code
    └── eks-pod-identity/                  # EPI KCL code
```

---

## Validation Targets Summary

| Tool | Target | Command |
|------|--------|---------|
| **Polaris** | Score >= 85 | `polaris audit --audit-path FILE --format=pretty` |
| **kube-linter** | Zero errors | `kube-linter lint FILE` |
| **Datree** | No violations | `datree test FILE --ignore-missing-schemas` |

---

## One-Liners

**Full validation**:
```bash
crossplane render examples/app-complete.yaml app-composition.yaml functions.yaml --extra-resources examples/environmentconfig.yaml > /tmp/app.yaml && polaris audit --audit-path /tmp/app.yaml --format=pretty && kube-linter lint /tmp/app.yaml && datree test /tmp/app.yaml --ignore-missing-schemas
```

**Resource count**:
```bash
grep "^kind:" /tmp/rendered.yaml | sort | uniq -c
```

**Extract all Deployments**:
```bash
yq 'select(.kind == "Deployment")' /tmp/rendered.yaml
```

**Check Polaris score**:
```bash
polaris audit --audit-path /tmp/rendered.yaml --format=score
```

**Find duplicates**:
```bash
grep "  name:" /tmp/rendered.yaml | sort | uniq -d
```
