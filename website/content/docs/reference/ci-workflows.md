---
title: CI Workflows
weight: 40
description: What each GitHub Actions workflow gates, verified against .github/workflows.
lastVerified: 2026-08-20
---

CI never applies changes to a cluster — it validates, scans, and publishes;
Flux owns delivery. `.github/workflows/` currently holds five workflow files.

## Workflows at a glance

| Workflow | Trigger | Purpose |
|----------|---------|---------|
| `ci.yaml` | PR → `main` | The main gate: pre-commit, security scanning, manifest validation, rendered diff, shellcheck, doc links |
| `build-container-images.yml` | push / PR / dispatch | Detect changed images under `container-images/`, build each, push on non-PR events |
| `vector-config-validation.yml` | push / PR | Validate the Vector log-parsing configuration |
| `docs-check.yml` | PR → `main` (path-filtered on `website/**`) | Builds the Hugo site (`refLinksErrorLevel: ERROR` fails the build on any unresolved `relref`) and runs `verify-doc-paths.sh` |
| `docs.yml` | push → `main` (path-filtered), or manual dispatch | Builds and deploys the site to GitHub Pages (`cnref.ogenki.io`) |

## `ci.yaml` — six jobs

Runs on every pull request to `main`.

### `pre-commit` 🛃

The standard Terraform pre-commit hooks across every OpenTofu stack:
`terraform_fmt`, `terraform_validate`, `terraform_tflint`. The same hooks
declared in `.pre-commit-config.yaml`, so `pre-commit run --all-files`
reproduces the check locally.

### `security-scan` 🔒

Three scanners, results uploaded to the GitHub Security tab as SARIF: Trivy
(filesystem vulnerability scan, `CRITICAL,HIGH`, exceptions in
`.trivyignore.yaml`), Checkov (IaC static analysis, soft-fail), TruffleHog
(verified-secret detection on the PR diff).

### `kubernetes-validation` ☸

The hard manifest gate — `./scripts/validate-manifests.sh`. Renders the repo
the way Flux does (every Kustomize overlay with `postBuild` vars, every
`HelmRelease` through `helm template`), then runs `flux schema validate`
(`skipMissingSchemas: false` — an unknown Kind fails the build) and `polaris
audit` on the rendered bundle.

### `render-diff` 📝

Informational only — never gates. Renders the PR head and the merge base and
posts a per-PR comment showing exactly which rendered resources the PR
adds/changes/removes.

### `shellcheck` 💻

`shellcheck -x -S warning` over every `scripts/**/*.sh`.

### `links`

`./scripts/validate-links.sh` resolves every relative Markdown link target in
the repository (`git ls-files '*.md'`, then checks each `](target)` relative
to the file holding it). `.linkcheck-allow` holds known pre-existing breaks
so they don't block unrelated work.

## Documentation site workflows

Two workflows exist specifically for `website/` and are new since the site
was scaffolded:

- **`docs-check.yml`** gates every PR that touches `website/**`,
  `docs/architecture/**`, `mise.toml`, or its own workflow file: it builds the
  site with `hugo --minify --gc` — which fails on any unresolved internal
  `relref` because `refLinksErrorLevel: ERROR` is set in `website/hugo.yaml` —
  then runs `./scripts/verify-doc-paths.sh`.
- **`docs.yml`** runs the same build on push to `main` (same path filter) or
  on manual dispatch, then publishes Hugo's build output — the gitignored
  website/public directory — to GitHub Pages.

## Application & image builds

### Container images (`build-container-images.yml`)

Builds the images under `container-images/` (`app-wizard`, `pev2`, …) with a
dynamic build matrix over changed image directories. On pull requests it
builds but does not push (validation only); on push to `main` and
`workflow_dispatch` it pushes to `ghcr.io/smana/<image>`. Tags are
`<branch>-<short-sha>` plus `latest` on the default branch; deployments pin
the immutable `<branch>-<sha>` tag, never `latest`.

### Vector configuration (`vector-config-validation.yml`)

Validates the Vector log-parsing configuration so a malformed pipeline is
caught before it reaches the observability stack.

## Disabled workflows

`terramate-preview.yaml` and `terramate-drift-detection.yaml` are fully
commented out and live in `.github/workflows-disabled/`, which GitHub does
not execute — moved there because a workflow file with no valid `name`/`on`/`jobs`
key otherwise gets queued and recorded as a permanent failed run on every push.

## Pre-commit hooks

```bash
pip install pre-commit
pre-commit install
pre-commit run --all-files
```

| Group | Hooks |
|-------|-------|
| General | `trailing-whitespace`, `end-of-file-fixer`, `check-yaml`, `check-json`, `check-added-large-files`, `check-merge-conflict` |
| OpenTofu / Terraform | `terraform_fmt`, `terraform_validate`, `terraform_tflint` (`--tf-path=tofu`) |
| Secrets | `detect-secrets` (baseline: `.secrets.baseline`) |

## Self-hosted GitHub runners

Self-hosted runner scale sets run in-cluster (`tooling/base/gha-runners/`),
**off by default** — commented out of `tooling/mycluster-0/kustomization.yaml`.
When enabled, they give private-endpoint access, lower latency, no egress
charges for heavy builds, and secrets via External Secrets rather than
long-lived tokens in the workflow.
