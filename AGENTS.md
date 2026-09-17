# cloud-native-ref

A production-grade cloud-native platform reference: GitOps on AWS EKS and GCP GKE, built with
OpenTofu, Terramate, Flux, Crossplane, Cilium and OpenBao.

Instructions are **scoped by directory**. This file holds what applies everywhere; each directory
below carries its own `AGENTS.md` that loads when you work in it. Read the nearest one before
changing anything there.

| Directory | Covers |
|---|---|
| `opentofu/` | Terramate orchestration, `TM_*` gates, EKS/GKE two-stage bootstrap |
| `infrastructure/` | Crossplane claims and traps, Cilium, Gateway API, Tailscale |
| `security/` | OpenBao, PKI, IAM, CiliumNetworkPolicy authoring |
| `observability/` | VictoriaLogs LogsQL, VictoriaMetrics, Grafana dashboards |
| `clusters/` | Flux dependency graph, variable substitution, the LLM-platform opt-in gates |
| `apps/` | App claims, Atlas database migrations |
| `scripts/` | What each validator actually checks, and what it cannot |
| `docs/architecture/` | Diagram authoring and the icon library |
| `docs/superpowers/` | Design and plan artifacts, and the gate at each phase |

## How work gets done here

**Always work in a git worktree.** Every task that changes files. In Claude Code use the
`EnterWorktree` tool, never `git checkout -b` in place — worktrees branch from `origin/main`, so a
concurrent session on another branch cannot leak its commits into yours. That is not theoretical:
on 2026-08-18 two commits were merged under the wrong PR exactly this way (#1765 / #1766).

**Rebase onto `origin/main` before every review, push and PR.** Fetch first — a comparison against
a stale local `origin/main` reports "up to date" on a branch that is not. The `sync-branch` skill
does this; `ship-it` runs it as stage 1.

**Never claim done without fresh evidence.** No "done / fixed / passing / ready" without a command
run in the same response, with its output cited as numbers or an exit code. The claim-to-command
table is in [`.agents/skills/ship-it/references/evidence.md`](.agents/skills/ship-it/references/evidence.md).

**Write less.** Comments carry *why* — a non-obvious constraint, a deliberate deviation, a gotcha,
a workaround — never *how*. Docs lead with the conclusion and prefer tables to paragraphs. Say a
thing once, on the page that owns it. The full gauntlet, which `ship-it` applies before review, is
in [`.agents/skills/ship-it/references/prose.md`](.agents/skills/ship-it/references/prose.md).

**Diagrams are the exception to "write less" — prefer more of them.** Default to **mermaid**: it
renders in the docs site, on GitHub, and in every agent's output, and it diffs as text. Reach for
`.drawio` only when explicitly asked for it, or when editing a diagram that already exists under
`docs/architecture/`.

**A technology choice with a rejected alternative needs an [ADR](website/content/docs/decisions/)
before merge.** If you can name what it was chosen over, write the record. If nothing credible
competed it is an installation, not a decision — say so in the PR rather than leaving it unsaid.
Version bumps, chart-value changes and single-file fixes never need one.

**Repository metadata is English** — commit messages, PR titles and bodies — even when the content
being changed is not. A French blog post keeps its language; the commit describing it does not.

**Never co-author commits** and never add generated-with attribution lines to PRs.

## Non-negotiables

Full text in [`docs/platform-constitution.md`](docs/platform-constitution.md). Read it before
designing anything under `infrastructure/`, `security/`, `observability/` or `tooling/`.

- Crossplane-managed resources are prefixed **`xplane-*`**. The prefix is load-bearing for IAM
  scoping, and a rename is a delete-and-create.
- **Default-deny CiliumNetworkPolicy** on every workload that runs a pod.
- **No hardcoded credentials.** External Secrets backed by OpenBao.
- **EKS Pod Identity, never IRSA** (ADR-0002).
- Resource requests *and* limits, liveness *and* readiness probes, restricted pod security context.
- RBAC least-privilege. Never cluster-admin for a workload.

## Deploying

Three sequential stages — network, then OpenBao, then Kubernetes — orchestrated by Terramate.

```bash
cd opentofu && terramate script run deploy     # the whole platform, both clouds gated by TM_CLOUD
terramate script run preview                   # dry run
terramate script run drift detect

TF_VAR_flux_git_ref='refs/heads/my-branch' terramate script run deploy   # feature-branch cluster
```

Tool versions come from `mise.toml`; run `mise install` first. Cilium, Flux and Gateway API
versions are pinned in `opentofu/config.tm.hcl`.

`opentofu/AGENTS.md` has the stack list, the seven `TM_*` environment gates and the two-stage
bootstrap. Read it before running anything destructive.

## Validating

```bash
./scripts/ci/validate-manifests.sh      # renders the repo as Flux would, then gates it
./scripts/ci/validate-vmrules.sh        # promtool over every repo-authored VMRule
./scripts/ci/validate-links.sh          # every relative Markdown link
./scripts/ci/validate-doc-claims.sh     # docs still agree with config
./scripts/ci/verify-doc-paths.sh        # every backticked repo path in the docs site exists
./scripts/ci/validate-idp-topology.sh   # exactly one cloud hosts ZITADEL (ADR-0027)
tofu validate && trivy config --exit-code=1 --ignorefile=./.trivyignore.yaml .
```

`validate-manifests.sh` is the single entry point CI runs and the one to cite as evidence. Two
properties are load-bearing and easy to break: `skipMissingSchemas: false` means an unknown Kind
**fails** the build rather than being skipped, and Polaris audits the *rendered* bundle (156
controllers) rather than the source tree (1). `scripts/AGENTS.md` explains what each gate catches
and, more usefully, what none of them can.

## Skills

Repeatable procedures live in [`.agents/skills/`](.agents/skills/), the Agent Skills open-standard
location that Codex, Cursor, Gemini CLI and Antigravity read directly. `.claude/skills` is a
symlink to it, because Claude Code reads only its own path.

| Skill | Use |
|---|---|
| `ship-it` | The full pre-merge pipeline: rebase → simplify → prune → validate → review → PR |
| `sync-branch` | Rebase onto the latest `origin/main` |
| `commit` | Pre-commit validation, then a conventional commit |
| `create-pr` | Open or update a PR with a mermaid diagram and the design link |
| `spec-research` | Forked subagent: ecosystem scan → research doc, without burning main context |
| `verify-spec` | Post-merge: prove a design's criteria against the live cluster |

Non-trivial changes go through the [Superpowers](https://github.com/obra/superpowers) plugin —
brainstorm, then plan, then execute. Artifacts land under `docs/superpowers/`; that directory's
`AGENTS.md` has the gate that applies at each phase.

## Troubleshooting entry points

- **Anything timing out**: check the network policies first. Cilium, then `hubble observe`.
- **Flux**: `FluxInstance` status → HelmRelease/Kustomization → source → managed resources → pod logs.
- **Crossplane**: XR conditions → composition pipeline → managed resources → provider controller logs.
- **Grafana "no data"**: confirm the data exists over a wider range before suspecting infrastructure.
  Event-driven components (Karpenter, Flux, cert-manager) need 6–12h.

Compositions are **not edited here** — they live in
[`Smana/crossplane-configuration`](https://github.com/Smana/crossplane-configuration) and ship as a
version-pinned package. Change the KCL there, run `task check` there, cut a release, then bump the
pin here.
