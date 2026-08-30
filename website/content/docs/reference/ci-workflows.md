---
title: CI Workflows
weight: 40
description: Every GitHub Actions job, what it runs, and which six of them can actually block a merge — verified against .github/workflows and the branch protection API.
lastVerified: 2026-08-30
---

CI never applies changes to a cluster. It validates, scans and publishes;
[Flux]({{< relref "/docs/platform/gitops/_index.md" >}}) owns delivery from
`main`. Five workflow files live in `.github/workflows/`, and exactly six jobs
— all of them in `ci.yaml` — can block a merge.

![The CI pipeline: a pull request fans into ci.yaml's six jobs and, when their paths change, three path-filtered workflows that are not required checks; the six required checks gate the merge under strict and enforce_admins; after the merge three independent consumers read main — Flux reconciles the cluster, docs.yml publishes the site, and build-container-images pushes to ghcr.io](/images/diagrams/ci-pipeline.svg)

## What blocks a merge

Branch protection on `main` requires these six contexts, and nothing else:

| Job (`ci.yaml`) | What it runs | Blocks the merge |
|---|---|---|
| **Pre-commit checks** 🛃 | Terraform hooks across every OpenTofu stack | ✅ |
| **Security scanning** 🔒 | Trivy, Checkov, TruffleHog → SARIF | ✅ |
| **Kubernetes validation** ☸ | `./scripts/validate-manifests.sh` | ✅ |
| **Rendered manifest diff** 📝 | renders head vs merge-base, posts a PR comment | ✅ the *job* must succeed; the diff's **content** never fails it |
| **Check the shell scripts** 💻 | `shellcheck -x -S warning` over `scripts/**/*.sh` | ✅ |
| **Check the documentation links** 🔗 | `./scripts/validate-links.sh`, then `./scripts/validate-doc-claims.sh` | ✅ |

Two protection settings matter as much as the list:

- **`strict: true`** — the branch has to be up to date with `main` before it
  can merge, so a green check on a stale branch is not enough.
- **`enforce_admins: true`** — there is no `gh pr merge --admin` escape
  hatch, for anybody. A stuck check gets re-run, not bypassed.

Required approving reviews are set to **0**: the gates are mechanical, not
social, which is the whole reason they have to be trustworthy.

## `ci.yaml` — the six jobs

Runs on every pull request targeting `main`, with no path filter.

### `pre-commit` 🛃

Runs the Terraform pre-commit hooks — `terraform_fmt`, `terraform_validate`,
`terraform_tflint` — across every OpenTofu stack. `jdx/mise-action` installs
tool versions from `mise.toml`, then the job calls `pre-commit` directly —
the same command a contributor runs locally, so there is no separate
container pipeline to keep in sync.

```bash
# Reproduce the job locally
mise install
pre-commit run --all-files
```

`PCT_TFPATH=tofu` tells the pre-commit-terraform hooks to call `tofu` instead
of `terraform`. `GITHUB_TOKEN` is also set, so `tflint --init` authenticates
when it fetches its ruleset rather than hitting GitHub's anonymous rate limit.

The job first writes three placeholder certificate files into the OpenBao
cluster stack's gitignored `.tls/` directory: `tofu validate` needs those
files to exist, and the real certificates are never in Git.

### `security-scan` 🔒

Three scanners, all uploading SARIF to the GitHub Security tab:

| Scanner | Scope | Failure mode |
|---|---|---|
| Trivy | filesystem, `CRITICAL,HIGH` | exceptions in `.trivyignore.yaml` |
| Checkov | IaC static analysis | soft-fail — reports, never blocks |
| TruffleHog | verified secrets on the PR diff | blocks on a verified finding |

### `kubernetes-validation` ☸

The hard manifest gate — `./scripts/validate-manifests.sh`. It renders the
repository the way Flux does (every Kustomize overlay with its `postBuild`
vars substituted, every `HelmRelease` through `helm template` with its own
values and `postRenderers`), then applies two gates to the *rendered* output:
`flux schema validate` with `skipMissingSchemas: false`, so an unknown Kind
fails the build rather than being skipped, and `polaris audit`. See
[Validation]({{< relref "/docs/platform/gitops/validation.md" >}}) for why
both properties are load-bearing.

### `render-diff` 📝

Renders the PR head and the merge base and posts a sticky PR comment showing
exactly which rendered resources the change adds, modifies or removes. It is
a **required check** — the job has to succeed — but its content is
informational: a diff showing a hundred changed resources passes exactly like
a diff showing none. It exists so a reviewer sees the real effect of a values
change rather than the YAML that produced it.

### `shellcheck` 💻

`shellcheck -x -S warning` over every `scripts/**/*.sh`.

### `links` 🔗

`./scripts/validate-links.sh` resolves every relative Markdown link target in
the repository: `git ls-files '*.md'`, then each `](target)` checked relative
to the file holding it. `.linkcheck-allow` exists for known pre-existing
breaks and is **currently empty** — the goal state. Never add an entry to
route around a break your own change introduced.

The same job then runs `./scripts/validate-doc-claims.sh`, which checks the
specific claims pinned in `.doc-claims.yaml` against the configuration they
describe — it lives in this job rather than its own so the required-check
list on `main` does not have to change.

## Path-filtered workflows

None of these is a required check. They run only when their paths change.

| Workflow | Trigger | What it does |
|---|---|---|
| `docs-check.yml` | PR touching `website/**`, `docs/architecture/**`, `mise.toml`, `scripts/verify-doc-paths.sh`, or itself | `hugo --minify --gc`, then `./scripts/verify-doc-paths.sh` |
| `docs.yml` | push to `main` touching `website/**`, `docs/architecture/**`, `mise.toml` (a narrower set than `docs-check.yml` — no `scripts/verify-doc-paths.sh`), or manual dispatch | same build, then publishes to GitHub Pages at `cnref.ogenki.io` |
| `vector-config-validation.yml` | PR or push touching `observability/base/victoria-logs/helmrelease-*.yaml` | validates the Vector VRL log-parsing rules |
| `build-container-images.yml` | PR or push touching `container-images/**`, or manual dispatch | builds a dynamic matrix over changed image directories |

### The documentation site

`docs-check.yml` builds the site on every PR that touches it. Two things make
that build a real gate even though it is not a required check:

- **`refLinksErrorLevel: ERROR`** in `website/hugo.yaml` turns any unresolved
  internal `relref` into a build failure, so a renamed page cannot silently
  404.
- **`./scripts/verify-doc-paths.sh`** asserts that every backticked
  repository path written in the site's prose still exists. It walks
  `git ls-files`, so it only sees tracked files — run it after `git add`, or
  a brand-new page passes without ever being checked.

`docs.yml` runs the same build on push and publishes Hugo's output, but its
path filter is narrower than `docs-check.yml`'s — a change to
`scripts/verify-doc-paths.sh` alone triggers the PR check but not a deploy.
Its `concurrency` group never cancels an in-flight deploy: a half-published
site is worse than a slightly stale one.

### Container images

On a pull request `build-container-images.yml` builds each changed image
(no push) but does **not** run Trivy — the scan step is gated
`if: github.event_name != 'pull_request'`, so it runs only on push to `main`
or manual dispatch. On push to `main` and on manual dispatch it also pushes
to `ghcr.io/smana/<image>`, tagged `<branch>-<short-sha>` plus `latest` on the
default branch. Deployments pin the immutable `<branch>-<sha>` tag; nothing in
this repository deploys `latest`.

## Disabled workflows

`terramate-preview.yaml` and `terramate-drift-detection.yaml` are fully
commented out and live in `.github/workflows-disabled/`, a directory GitHub
does not execute. They were moved there rather than left in place because a
workflow file with no valid `name`/`on`/`jobs` key still gets queued and
recorded as a permanently failed run on every push.

## Pre-commit hooks

```bash
pip install pre-commit
pre-commit install
pre-commit run --all-files
```

| Group | Hooks |
|-------|-------|
| General | `trailing-whitespace`, `end-of-file-fixer`, `check-yaml`, `check-json`, `check-added-large-files`, `check-merge-conflict`, `check-case-conflict`, `check-symlinks`, `check-executables-have-shebangs`, `detect-private-key` |
| OpenTofu / Terraform | `terraform_fmt`, `terraform_validate`, `terraform_tflint` (`--tf-path=tofu`) |
| Secrets | `detect-secrets` (baseline: `.secrets.baseline`) |

`check-added-large-files` caps a file at 1000 KB, which is the constraint the
diagram export budget in `scripts/export-diagrams.sh` is set below.

## Self-hosted GitHub runners

Runner scale sets run in-cluster (`tooling/base/gha-runners/`) and are **off
by default** — commented out of `tooling/aws-0/kustomization.yaml`.
When enabled they give private-endpoint access, lower latency, no egress
charges for heavy builds, and secrets via External Secrets rather than
long-lived tokens in a workflow. A second scale set is dedicated to Dagger
builds and shares the in-cluster `dagger-engine`.
