---
title: Validation
weight: 30
description: Why manifests are validated as Flux's rendered desired state, not as raw source files, and the two properties that make the gate real.
lastVerified: 2026-08-30
---

"Git is the source of truth" only holds if what merges to `main` is actually
what Flux is about to apply. `./scripts/validate-manifests.sh` is what keeps
that claim honest: it renders every Kustomize overlay and every `HelmRelease`
the same way Flux does, then gates the *rendered* result — not the source
tree — before a PR can merge. See [CI Workflows]({{< relref "/docs/reference/ci-workflows.md" >}})
for the full pipeline this runs in and [Commands]({{< relref "/docs/reference/commands.md" >}})
for how to run it locally.

It runs as `Kubernetes validation ☸`, one of the six required checks — the
hard gate in the middle-left of this pipeline:

![The CI pipeline: a pull request fans into ci.yaml's six jobs, of which Kubernetes validation is the manifest gate, plus three path-filtered workflows that are not required checks; all six required checks gate the merge, after which Flux reconciles the cluster from main](/images/diagrams/ci-pipeline.svg)

## Why render before validating

A raw `HelmRelease` or a Kustomize patch fragment is not a complete
Kubernetes object — it's an input to one. Validating the source tree checks
almost nothing, because almost nothing in the source tree is a finished
manifest. Rendering first, then validating, is what makes the gate check the
thing that actually reaches the cluster:

1. **`check-substitution.py`** — verifies every Flux Kustomization's variable
   wiring first, because it is the one check the rendered bundle cannot make:
   a missing `postBuild` lands literal `${var}` text on the cluster, and a
   `${var}` the cluster's own ConfigMap does not define substitutes to an
   empty string — both render schema-valid.
2. **`gen-catalog.sh` → `.schemas/`** — builds a JSON Schema catalog from
   this repository's own Crossplane XRDs (there is no public schema for
   `cloud.ogenki.io` kinds), plus the Envoy AI Gateway CRDs rendered from the
   exact chart version this repository pins.
3. **`render-bundle.py` → `.bundle/`** — every top-level Kustomize overlay
   through `kustomize build` with Flux's `postBuild` substitutions applied,
   every `HelmRelease` through `helm template` with its own `spec.values`
   and `postRenderers`, standalone manifests copied verbatim.
4. **Two gates on `.bundle/`**: `flux schema validate` (structure and
   `x-kubernetes-validations` CEL rules), then `polaris audit` (workload
   best practices — privilege escalation, capabilities, resource limits,
   image tags).

## The two properties that make this gate real

**`skipMissingSchemas: false`.** Verified directly in `.fluxschema.yml`:

```yaml
validate:
  schemaLocation: [ ./.schemas, ..., default, ecosystem ]
  skipMissingSchemas: false
```

An unknown Kind **fails the build** instead of being silently skipped. The
setup this replaced ran kubeconform with `-ignore-missing-schemas`, so any
`cloud.ogenki.io` claim — `App`, `SQLInstance`, `EPI`, every Crossplane
composition this platform ships — went unvalidated for the life of the
repository, and the CI run still reported green. `Skipped: 0` is part of
what a passing run means here, not incidental detail.

**Polaris audits the rendered bundle, not the source tree.** Re-verified on
this branch by rendering the repository and counting both sides directly:
the tree has **one** raw `Deployment` manifest
(`tooling/base/dagger-engine/deployment.yaml`); the rendered bundle has
**156 controllers** — 109 `Deployment`, 25 `Job`, 10 `StatefulSet`, 8
`DaemonSet`, 4 `CronJob` — everything else arrives as a `HelmRelease` and
only becomes a controller after `helm template` runs. A best-practices audit
pointed at the source tree would check one workload; pointed at the
rendered bundle, it checks what's actually scheduled.

## Requirements

`flux` ≥ 2.9 with the schema plugin (`mise install && flux plugin install schema`)
and Polaris 8.5.0 — `preflight.sh` hard-fails on a too-old client or a
missing plugin rather than silently falling back to whatever binary happens
to be first on `PATH`.
