---
description: Atlas Operator database migration integration with SQLInstance composition
globs:
  - "infrastructure/base/crossplane/configuration/kcl/cloudnativepg/**"
---

# Database Migrations with Atlas Operator

## Overview

The SQLInstance composition supports declarative schema migrations via Atlas Operator + Flux GitOps.

When `atlasSchema` is defined in SQLInstance spec, the composition creates:
1. **GitRepository** - Flux pulls migration files from Git
2. **Kustomization** - Processes `kustomization.yaml` with `configMapGenerator`
3. **ConfigMap** - Generated with migration SQL files
4. **AtlasMigration** - References ConfigMap to apply migrations

## Migration Repository Requirements

Must contain a `kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
configMapGenerator:
  - name: atlas-db-migrations
    files:
      - ./001_initial_schema.sql
      - ./002_add_users_table.sql
      - atlas.sum
    options:
      disableNameSuffixHash: true
```

## Git Reference Handling

- **Tags**: References starting with `v` (e.g., `v1.0.0`) -> Git tags
- **Branches**: Other references (e.g., `main`, `develop`) -> Git branches

## Troubleshooting

```bash
# ConfigMap not generated
kubectl get kustomization <name>-atlas-migrations-configmap -n <namespace>
kubectl get gitrepository <name>-atlas-migrations-repo -n <namespace>

# Migrations not applied
kubectl get atlasmigration <name>-atlas-migration -n <namespace> -o yaml
kubectl logs -n infrastructure deployment/atlas-operator-controller-manager
```

**Important**: Atlas Operator v0.7.11 does NOT support `dir.remote` for Git repos. Use the GitOps/ConfigMap pattern.
