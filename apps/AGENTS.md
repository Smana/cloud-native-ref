# Apps — claims and database migrations

Apps are `App` claims against the composition in
[`Smana/crossplane-configuration`](https://github.com/Smana/crossplane-configuration). The
composition supports progressive complexity: image-only up to production-ready with managed
PostgreSQL, Redis/Valkey, S3, autoscaling, HA and zero-trust networking. Only the claim lives here.

**`SQLInstance` composes differently per cloud** — RDS on AWS, in-cluster CNPG on GCP. A claim name
tells you nothing about what exists in the cloud, and `kubectl get managed` needs `-A` or it
silently searches only `default`.

**CNPG restore needs an empty destination archive.** Every rebuild refuses until the live prefix is
cleared.

## Atlas migrations

When `atlasSchema` is set on a `SQLInstance` spec, the composition creates a GitRepository (Flux
pulls the migration files), a Kustomization (processes `kustomization.yaml` with
`configMapGenerator`), the generated ConfigMap, and an AtlasMigration referencing it.

The migration repository must contain a `kustomization.yaml`:

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

Git references starting with `v` (`v1.0.0`) resolve as tags; anything else (`main`, `develop`) as
branches.

**Atlas Operator v0.7.11 does not support `dir.remote` for Git repos.** Use the GitOps/ConfigMap
pattern above.

```bash
# ConfigMap not generated
kubectl get kustomization <name>-atlas-migrations-configmap -n <namespace>
kubectl get gitrepository <name>-atlas-migrations-repo -n <namespace>

# Migrations not applied
kubectl get atlasmigration <name>-atlas-migration -n <namespace> -o yaml
kubectl logs -n infrastructure deployment/atlas-operator-controller-manager
```

## App Wizard

`platform/app-wizard/app.yaml` clones a `crossplane-configuration` tag. **It must track the package
pin** in `../infrastructure/base/crossplane/configuration-aws/configuration-packages.yaml` — bump
both in the same change.

Its image must ship the Crossplane **core** binary as well as the CLI: only the core implements
`internal render`.
