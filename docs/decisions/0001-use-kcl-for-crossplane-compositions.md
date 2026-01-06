# ADR-0001: Use KCL for Crossplane Compositions

**Status**: Accepted
**Date**: 2024-01-15
**Deciders**: Platform Team
**Related Spec**: N/A (foundational decision)

---

## Context

Crossplane compositions require complex logic for:
- Conditional resource creation based on claim inputs
- Iteration over dynamic lists (e.g., multiple databases, buckets)
- Complex transformations and defaults
- Status aggregation from multiple managed resources

Traditional Crossplane patch-and-transform compositions become unwieldy and hard to maintain for these scenarios. We needed a more expressive way to define composition logic while maintaining the declarative, GitOps-friendly nature of our platform.

---

## Decision Drivers

- **Readability**: Composition logic should be understandable by the team
- **Maintainability**: Changes should be easy to make and review
- **Testability**: Logic should be testable before deployment
- **Expressiveness**: Must handle conditionals, loops, and complex transformations
- **Team familiarity**: Python-like syntax preferred over Go templates
- **Ecosystem**: Active development and community support

---

## Considered Options

### Option 1: Patch-and-Transform (Native Crossplane)

Native Crossplane composition patches using `ToCompositeFieldPath`, `FromCompositeFieldPath`, and `CombineFromComposite`.

**Pros**:
- No external dependencies
- Well-documented in Crossplane docs
- Familiar to existing Crossplane users

**Cons**:
- Becomes verbose for complex logic
- No native conditionals (requires workarounds)
- No iteration over lists
- Difficult to test in isolation
- Poor readability for complex compositions

### Option 2: Go Templates (function-go-templating)

Using Go templates via `function-go-templating` for composition logic.

**Pros**:
- Powerful templating capabilities
- Native Kubernetes ecosystem tool
- Conditionals and loops supported

**Cons**:
- Go template syntax is verbose and error-prone
- `{{ .Values.x | default "y" }}` patterns are hard to read
- Limited IDE support for Go templates in YAML
- Difficult to debug complex templates
- Team less familiar with Go template idioms

### Option 3: KCL (function-kcl)

Using KCL (Kusion Configuration Language) via `function-kcl` for composition logic.

**Pros**:
- Python-like syntax, readable and familiar
- Strong typing and built-in validation
- Rich conditionals (`if/else`, ternary)
- Native list comprehensions for iteration
- Testable with `kcl run`
- Active development by the KCL community
- Published as OCI artifacts for versioning

**Cons**:
- Learning curve for KCL-specific patterns
- Known mutation bug (#285) requires specific coding patterns
- Additional CI/CD for module publishing
- Smaller community than Go templates

---

## Decision Outcome

**Chosen option**: "KCL (function-kcl)"

**Rationale**: KCL provides the best balance of readability, expressiveness, and testability. The Python-like syntax aligns with team skills, and the ability to test compositions with `kcl run` before deployment significantly reduces risk. While the mutation bug (#285) requires careful coding patterns, these are well-documented and enforced by our validation scripts.

---

## Consequences

### Positive

- Readable composition code that team members can quickly understand
- Unit testable logic via `kcl run` with settings files
- Rich conditionals enable progressive complexity (basic → complete examples)
- Strong typing catches errors at development time
- OCI artifact publishing enables versioned, reproducible deployments

### Negative

- Team needs to learn KCL syntax and patterns
- Must avoid mutation pattern (issue #285) - documented in CLAUDE.md
- Requires CI/CD pipeline for module publishing to GHCR
- Mitigation: Comprehensive validation script (`scripts/validate-kcl-compositions.sh`)

### Neutral

- Compositions now split between YAML (XRD, Composition wrapper) and KCL (logic)
- Module versioning adds explicit dependency management

---

## Implementation Notes

- KCL modules located in `infrastructure/base/crossplane/configuration/kcl/`
- Modules published to `ghcr.io/smana/cloud-native-ref/crossplane-<name>:<version>`
- Validation via `./scripts/validate-kcl-compositions.sh` (formatting, syntax, rendering)
- Three stages: `kcl fmt` → `kcl run` → `crossplane render`

---

## References

- [KCL Documentation](https://kcl-lang.io/)
- [function-kcl GitHub](https://github.com/crossplane-contrib/function-kcl)
- [KCL Mutation Bug #285](https://github.com/crossplane-contrib/function-kcl/issues/285)
- [Blog: Going Further with Crossplane](https://blog.ogenki.io/post/crossplane_composition_functions/)
- Existing compositions: `infrastructure/base/crossplane/configuration/kcl/{app,cloudnativepg,eks-pod-identity}/`
