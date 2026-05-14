---
description: KCL formatting and mutation pattern rules for Crossplane compositions
globs:
  - "infrastructure/base/crossplane/configuration/kcl/**/*.k"
  - "infrastructure/base/crossplane/configuration/kcl/**/settings*.yaml"
---

# KCL Crossplane Rules

1. **Always `kcl fmt`** before committing — CI enforces strict formatting
2. **Never mutate dicts** after creation (function-kcl issue #285 causes duplicate resources)
3. **List comprehensions** must be single-line (multi-line fails CI)
4. **Identifier shadowing in dict comprehensions** — `[{name = name} for name in xs]` writes the value of `name` as both key AND value (yields `{<value>: <value>}`, not `{name: <value>}`). Always rename the loop variable: `for n in xs`. Symptom: K8s rejects the rendered manifest with `field not declared in schema`.
5. **`kcl mod push` ignores the OCI tag suffix in the URL** — uses the `version` field from `kcl.mod` as the actual published tag. PR-prefix CI workflows must rewrite `kcl.mod` before push (the `crossplane-modules.yml` workflow does this with `sed`). Verify a tag is anonymously pullable before pointing a composition at it (function-kcl pulls anonymously).
6. **Validate**: `./scripts/validate-kcl-compositions.sh`

For detailed patterns, examples, and security validation: see `/crossplane-validator` skill.
