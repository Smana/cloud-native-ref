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
4. **Validate**: `./scripts/validate-kcl-compositions.sh`

For detailed patterns, examples, and security validation: see `/crossplane-validator` skill.
