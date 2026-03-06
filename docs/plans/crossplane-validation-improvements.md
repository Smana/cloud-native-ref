# Crossplane Composition Validation Improvements

## Status

Phase 2 complete (KCL unit tests). Phases 1, 3-5 planned.

## Context

The current validation relies on a monolithic bash script (`scripts/validate-kcl-compositions.sh`) with 3 stages: `kcl fmt`, `kcl run`, and `crossplane render`. There are no KCL unit tests, no schema/CEL validation (`crossplane beta validate`), no security scanning in CI, and no negative test cases. The pre-commit hooks don't cover KCL at all.

## Spike Results (completed)

Validated that `kcl test . -Y settings-example.yaml` works for composition testing:

- `option("params")` is correctly populated from settings YAML files
- `items` from `main.k` is directly accessible in test lambdas (no imports needed)
- Performance: **~500ms total** for 33 tests across all 3 modules
- `kcl fmt` is compatible with test files (auto-formats on save)
- `kcl lint` provides marginal value over `kcl fmt` — **dropped from plan**

KCL test constraints:
- No imperative `for` loops — use list comprehensions only
- Lambda must end with an expression — use guard-style: `assert not cond or check`
- One settings file = one test scenario (each settings file defines the XR input)

## Plan

### Phase 1: Modular Validation Script

Rewrite `scripts/validate-kcl-compositions.sh` with CLI flags for stage selection:

| Stage | Tool | Docker? | Description |
|-------|------|---------|-------------|
| `fmt` | `kcl fmt` | No | Format check via git diff |
| `test` | `kcl test` | No | Unit tests (settings-example.yaml) |
| `render` | `crossplane render` | Yes | Full pipeline render |
| `validate` | `crossplane render \| crossplane beta validate` | Yes | Schema + CEL validation (piped from render) |
| `security` | `polaris` + `kube-linter` | No | Security posture scoring |

CLI interface:
- `./scripts/validate-kcl-compositions.sh` - all stages
- `./scripts/validate-kcl-compositions.sh --stages fmt,test` - specific stages
- `./scripts/validate-kcl-compositions.sh --skip security` - skip stages
- `./scripts/validate-kcl-compositions.sh --module app` - single module

### Phase 2: KCL Unit Tests (DONE)

Added `main_test.k` alongside each `main.k` for testing composition logic without Docker:

- **app**: 16 tests — core resources, image config, security context, autoscaling/HPA, PDB, HTTPRoute, Gateway, network policies, kvStore, SQLInstance, S3 Bucket, external secrets, composition annotations, namespace consistency, observability
- **cloudnativepg**: 10 tests — cluster creation, instance size mapping, databases/ExternalSecrets, backup/IAM, performance insights, monitoring, Atlas schema/Flux resources, postgres version, superuser secret, roles
- **eks-pod-identity**: 7 tests — core IAM resources, PodIdentityAssociation per cluster, resource naming, additional policy attachments, management policies, provider config ref, API versions

Run: `kcl test <module> -Y <module>/settings-example.yaml`

### Phase 3: Negative Test Examples

Create `examples/invalid/` with invalid YAML files testing CEL validation rules:

| File | XRD rule violated |
|------|-------------------|
| `app-autoscaling-min-gt-max.yaml` | minReplicas > maxReplicas |
| `app-route-no-hostname.yaml` | route.enabled without hostname |
| `sqlinstance-multi-no-backup.yaml` | instances > 1 without backup schedule |
| `epi-no-xplane-prefix.yaml` | name without xplane- prefix |
| `epi-no-policy.yaml` | neither policyDocument nor additionalPolicyArns |

Validation: `crossplane beta validate <xrd>.yaml examples/invalid/<file>.yaml`

### Phase 4: CI Workflow

Extend `.github/workflows/crossplane-modules.yml`:
- Add unit test step to `quality-checks` job (`kcl test`)
- Add `render-validate` job with `crossplane render --include-full-xr | crossplane beta validate`
- Add negative example validation (expect non-zero exit)
- Add security scanning with polaris + kube-linter on rendered output

### Phase 5: Pre-commit Hooks

Add lightweight KCL hooks to `.pre-commit-config.yaml`:
- `kcl-fmt`: Format check on changed `.k` files
- `kcl-test`: Run unit tests when `.k` files change (only for changed modules)

No Docker-dependent hooks (render is too slow for pre-commit).

## Implementation Order

Phase 1 -> Phase 3 -> Phase 4 -> Phase 5

Phase 2 is complete. Phase 3 is independent and can start immediately.

## Known Limitations

- `epi-no-xplane-prefix.yaml` (Phase 3): Root-level CEL rules referencing `self.metadata.name` are only enforced by the live Kubernetes API server, not by `crossplane beta validate` offline. This negative test will pass offline validation but is correctly rejected on-cluster.
- `policyDocument` is listed as both `required` in the EPI XRD schema AND validated by CEL, creating double-enforcement.
- `app-s3-no-provider.yaml` removed from Phase 3: the CEL rule for s3Bucket.providerConfigRef was removed in commit 6caae555.

## Verification

1. `kcl test <module> -Y <module>/settings-example.yaml` — 33/33 tests pass (Phase 2 done)
2. `./scripts/validate-kcl-compositions.sh` — all stages pass
3. `./scripts/validate-kcl-compositions.sh --stages fmt,test` — fast path completes in <1s
4. Negative examples correctly rejected by `crossplane beta validate`
5. Pre-commit hooks trigger on `.k` file changes
6. CI workflow runs all new stages on PR
