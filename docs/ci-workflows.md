# CI/CD Workflows

This document explains the continuous integration and delivery workflows used in this repository.

## Overview

Our CI/CD strategy focuses on:

- **Early feedback**: Catch issues locally with pre-commit hooks
- **Comprehensive validation**: Security scanning, syntax checking, policy enforcement
- **Portable pipelines**: Run the same checks locally and in CI using Dagger
- **GitOps delivery**: Flux automatically deploys what's in Git
- **Module publishing**: Crossplane KCL modules published to GitHub Container Registry

## CI Philosophy

**"Shift Left" Approach**: Catch issues as early as possible in the development workflow:

1. **Pre-commit hooks** - Before Git commit
2. **Local Dagger runs** - During development
3. **GitHub Actions** - On pull request
4. **Flux sync** - On merge to main

## GitHub Actions Workflows

### CI Pipeline (`.github/workflows/ci.yaml`)

Runs on every pull request to validate changes before merge.

#### Pre-commit Checks

```yaml
- Pre-commit OpenTofu validation via Dagger
```

Uses Dagger to run pre-commit hooks in a consistent environment:
- `terraform_fmt`: Format checking
- `terraform_validate`: Syntax validation
- `terraform_tflint`: Linting with TFLint

#### Security Scanning

**Trivy**: Vulnerability scanning for containers, infrastructure, and dependencies
```bash
- Scans: Terraform, Kubernetes manifests, container images
- Output: SARIF format for GitHub Security tab
- Fail on: Critical/High vulnerabilities (configurable via .trivyignore.yaml)
```

**Checkov**: Static analysis for infrastructure as code
```bash
- Scans: Terraform/OpenTofu configurations, Kubernetes manifests
- Checks: Security best practices, compliance frameworks
- Output: Detailed policy violations with remediation guidance
```

**TruffleHog**: Secret detection
```bash
- Scans: Git history, file content
- Detects: API keys, passwords, tokens, certificates
- Prevents: Accidental secret commits
```

#### Kubernetes Validation

**kubeconform**: Kubernetes manifest schema validation
```bash
- Validates: All YAML manifests against Kubernetes API schemas
- Checks: Flux clusters, Kustomize directories
- Detects: Invalid resource definitions, API version mismatches
```

**Polaris**: Best practices enforcement
```bash
- Checks: Resource limits, security contexts, health probes
- Validates: Pod Security Standards compliance
- Reports: Actionable recommendations
```

#### Shell Script Validation

**ShellCheck**: Bash/shell script linting
```bash
- Validates: All .sh scripts in repository
- Detects: Common shell scripting errors
- Enforces: Best practices (quoting, error handling)
```

### Crossplane Modules Pipeline (`.github/workflows/crossplane-modules.yml`)

Handles KCL module validation, testing, and publishing.

#### Change Detection

```yaml
- Detects modified KCL modules
- Tracks changes in infrastructure/base/crossplane/configuration/kcl/
- Triggers module-specific validation
```

#### Quality Checks

**KCL Formatting** (CRITICAL - CI Enforced!)
```bash
kcl fmt .
```
- **Mandatory**: CI fails if code is not formatted
- **Rules**: Single-line list comprehensions, no trailing blank lines
- **Local check**: Run `kcl fmt` before committing
- **Why**: Consistent code style, avoid mutation patterns

**KCL Linting**
```bash
kcl lint .
```
- Static analysis for KCL code
- Detects: Unused variables, type errors, logic issues

**KCL Testing**
```bash
kcl test .
```
- Runs unit tests for composition logic
- Validates: Function behavior, edge cases

**Syntax Validation**
```bash
kcl run -Y settings-example.yaml
```
- Tests KCL code with example inputs
- Ensures: Compositions can parse and execute

#### Publishing Strategy

**Pull Request**: Publishes with `-pr{number}` suffix
```bash
# Example: ghcr.io/smana/cloud-native-ref/app:v1.0.0-pr123
- Purpose: Testing in development environments
- Overwritable: Yes (for iterative PR development)
```

**Main Branch**: Publishes with version + latest tag
```bash
# Example: ghcr.io/smana/cloud-native-ref/app:v1.0.0
#          ghcr.io/smana/cloud-native-ref/app:latest
- Purpose: Production releases
- Immutable: Version tags cannot be overwritten
- Latest: Points to most recent stable version
```

#### Composition Validation

Ensures compositions reference the latest module versions:
```bash
# Validates that compositions use the correct module versions
# Prevents: Using outdated or PR-suffixed modules in production
```

#### Job Summary

Generates markdown summary with:
- Module version published
- GHCR URL
- Usage instructions for referencing in compositions

### Terramate Workflows

**Drift Detection** (`.github/workflows/terramate-drift-detection.yaml`)
```bash
terramate script run drift detect
```
- **Frequency**: Scheduled (e.g., daily)
- **Purpose**: Detect infrastructure drift from desired state
- **Alerts**: Creates GitHub issues on drift detection

**Preview** (`.github/workflows/terramate-preview.yaml`)
```bash
terramate script run preview
```
- **Trigger**: Pull requests modifying OpenTofu code
- **Purpose**: Show what will change before merge
- **Output**: Plan output as PR comment

## Pre-commit Hooks

Local validation before Git commits (`.pre-commit-config.yaml`).

### General Hooks

```yaml
- trailing-whitespace: Remove trailing spaces
- end-of-file-fixer: Ensure files end with newline
- check-yaml: Validate YAML syntax
- check-json: Validate JSON syntax
- check-added-large-files: Prevent large file commits
- check-merge-conflict: Detect unresolved merge conflicts
```

### OpenTofu/Terraform Hooks

```yaml
- terraform_fmt: Format Terraform files
- terraform_validate: Validate Terraform syntax
- terraform_tflint: Lint Terraform code
```

### Security Hooks

```yaml
- detect-secrets: Scan for secrets using baseline
```

**Baseline**: `.secrets.baseline` contains known false positives

### KCL Hooks

```yaml
# Note: KCL files (.k) excluded from trailing-whitespace
# Reason: KCL uses indented blank lines in specific patterns
```

### Installation

```bash
# Install pre-commit
pip install pre-commit

# Or with uv (recommended)
uv pip install pre-commit

# Install hooks
pre-commit install

# Run manually
pre-commit run --all-files
```

## Dagger: The Missing Piece

**Why Dagger?**

Traditional CI/CD has the "works on my machine" problem. Dagger solves this by:

- **Portable**: Same pipeline runs locally and in CI
- **Fast**: Sophisticated caching across runs
- **Debuggable**: Test CI changes locally before pushing
- **Code over YAML**: Define pipelines in real programming languages

**Current Dagger Functions**:

```bash
# Pre-commit Terraform validation
dagger call pre-commit-terraform \
  --directory=./opentofu/network

# Kubeconform validation
dagger call kubeconform \
  --manifests=./clusters/mycluster-0
```

**Related**: [Dagger: The missing piece of the developer experience](https://blog.ogenki.io/post/dagger-intro/)

## Validation Scripts

### Crossplane Composition Validation

**Script**: `scripts/validate-kcl-compositions.sh`

Comprehensive validation for all Crossplane compositions:

**Stage 1: KCL Formatting**
```bash
kcl fmt .
```
- Checks formatting compliance
- Shows what needs to be fixed
- **Required** by CI

**Stage 2: KCL Syntax Validation**
```bash
kcl run -Y settings-example.yaml
```
- Tests KCL logic with example inputs
- Validates: Conditionals, loops, function calls
- Catches errors early before crossplane render

**Stage 3: Crossplane Rendering**
```bash
crossplane render examples/app-basic.yaml \
  app-composition.yaml \
  functions.yaml \
  --extra-resources examples/environmentconfig.yaml
```
- End-to-end validation
- Tests with multiple examples (basic + complete)
- Requires Docker
- Validates full composition pipeline

**Usage**:
```bash
# From repository root - validates ALL compositions
./scripts/validate-kcl-compositions.sh
```

**Output Example**:
```
╔════════════════════════════════════════════════════════════════╗
║  KCL Crossplane Composition Validation                        ║
╚════════════════════════════════════════════════════════════════╝

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Validating: app
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

📝 [1/3] Checking KCL formatting...
   ✅ Formatting is correct

🧪 [2/3] Validating KCL syntax and logic...
   ✅ KCL syntax valid

🎨 [3/3] Testing crossplane render...
   Testing: app-basic.yaml
   ✅ app-basic.yaml renders successfully
   Testing: app-complete.yaml
   ✅ app-complete.yaml renders successfully

✅ All checks passed for app
```

## Self-Hosted GitHub Runners

**Why Self-Hosted Runners?**

- **Private endpoint access**: Validate resources not publicly accessible
- **Faster builds**: No egress charges, lower latency
- **Secure environment**: Runs within VPC, no exposure of credentials

**Setup**:

Enabled via `tooling` Kustomization:
```yaml
# tooling/mycluster-0/kustomization.yaml
# Uncomment github-runners patch
```

**Security Considerations**:
- Dedicated service account with minimal permissions
- Ephemeral runners (destroyed after each job)
- Network policies restrict outbound access
- Secrets injected via External Secrets Operator

## CI Best Practices

### Before Committing

1. ✅ Run pre-commit hooks: `pre-commit run --all-files`
2. ✅ Format KCL code: `kcl fmt .` (if modified)
3. ✅ Validate compositions: `./scripts/validate-kcl-compositions.sh`
4. ✅ Test locally with Dagger (if available)

### Pull Request Workflow

1. Create feature branch
2. Make changes
3. Run local validation
4. Push and create PR
5. Review CI results
6. Address any failures
7. Request review
8. Merge when approved and green

### Merge to Main

1. Flux detects changes in Git
2. Reconciles resources based on dependencies
3. Health checks ensure proper deployment
4. Monitors for drift

## Troubleshooting CI Failures

### KCL Formatting Failures

```bash
Error: KCL files are not formatted correctly
```

**Fix**:
```bash
cd infrastructure/base/crossplane/configuration/kcl/app
kcl fmt .
git add .
git commit --amend
```

### Security Scan Failures

**Trivy finds vulnerabilities**:
- Review findings in Security tab
- Update base images or dependencies
- Add to `.trivyignore.yaml` if false positive (with justification)

**TruffleHog finds secrets**:
- Never commit real secrets!
- Use placeholder values
- Store real secrets in AWS Secrets Manager
- Update `.secrets.baseline` if false positive

### Kubeconform Validation Failures

**Unknown resource type**:
- Check CRD is installed
- Verify API version matches CRD version
- Ensure kubeconform has correct schema path

### Crossplane Render Failures

**Module not found**:
- Verify module is published to GHCR
- Check composition references correct version
- Ensure `functions.yaml` includes module

**KCL logic errors**:
- Review error message for line number
- Test with `kcl run -Y settings-example.yaml`
- Check for mutation patterns (issue #285)

## Future Enhancements

- [ ] **E2E Testing**: Automated testing of deployed applications
- [ ] **Performance Testing**: Load testing for critical paths
- [ ] **Chaos Engineering**: Automated failure injection
- [ ] **Progressive Delivery**: Canary/blue-green deployments
- [ ] **SBOM Generation**: Software Bill of Materials for security

## Related Documentation

- [Technology Choices](./technology-choices.md) - Why Dagger, GitHub Actions
- [Crossplane](./crossplane.md) - Composition validation requirements
- [GitHub Self-Hosted Runners Documentation](https://docs.github.com/en/actions/hosting-your-own-runners)
