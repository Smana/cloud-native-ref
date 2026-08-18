# Migrate spec-driven development to Superpowers

**Date**: 2026-08-18
**Status**: Approved (design)
**Scope**: repository workflow + agent configuration, plus a companion documentation update in
the blog repo (`Smana/smana.github.io`). No platform/cluster changes.

## Problem

The repo carries two competing spec workflows.

The home-grown SDD stack — `/spec` → `/clarify` → `/validate` → `/create-pr`, backed by
`scripts/sdd/`, `scripts/validate-spec.sh`, a 3-artifact directory per spec under
`docs/specs/NNN-slug/`, a GitHub issue template, and an auto-archive workflow — is documented
everywhere (CLAUDE.md, README.md, `.claude/skills/README.md`, `docs/specs/README.md`) but is no
longer used. It was retired after SPEC-012, when `spec-archive.yaml` both failed to archive
(the PR body did not contain the literal spec path it greps for) and was found to interpolate
the PR body directly into a shell script — backticks in a PR body execute in CI.

The Superpowers plugin has been the actual workflow since 2026-05: brainstorming produces a
design doc, writing-plans produces an implementation plan, subagent-driven-development executes
it. Seven design/plan documents already live under `docs/superpowers/`.

The cost of the split: CLAUDE.md instructs agents to run scripts nobody runs, `docs/specs/`
looks like an active pipeline when all eleven directories in it are merged work, one
cross-reference is already broken (`kvstore/README.md` points at a spec archived weeks ago),
and a CI workflow with a shell-injection bug is still armed on every merge to `main`.

## Goals

1. Superpowers is the single documented workflow for non-trivial changes.
2. Historical specs stay readable and correctly linked — they explain why the platform looks
   the way it does, and public README/CLAUDE.md/KCL docs cite them.
3. Repo-specific engineering gates (platform constitution, verification evidence table,
   systematic debugging) keep applying — rebound to the Superpowers artifacts.
4. Nothing in CI references specs afterward.
5. The published articles that document the retired SDD workflow say so, and their links keep
   resolving after the constitution moves.

## Non-goals

- Changing the platform constitution's *content*. It moves and is renamed; the rules are unchanged.
- Replacing `/commit`, `/improve-pr`, `/crossplane-validator`, or the three custom subagents.
  They are workflow-agnostic and stay as-is.
- Building repo-local wrappers around Superpowers skills. The plugin's skills are used directly.

> **Correction (during execution, 2026-08-18):** this section originally listed `/create-pr` as
> workflow-agnostic. It is not. Its "Detect spec context" step greps for
> `docs/specs/[0-9]+-[a-z0-9-]+`, its PR-body template carries a `Spec status` line and a
> "⚠️ Spec Recommendation" block pointing at the now-deleted `/spec`, and its related-skills list
> links `/spec`. Left untouched it would emit that recommendation on **every** PR. It is retooled
> alongside the other two skills in §E.

## Target workflow

```
Idea
 └─ superpowers:brainstorming      → docs/superpowers/specs/YYYY-MM-DD-<topic>-design.md
     └─ superpowers:writing-plans  → docs/superpowers/plans/YYYY-MM-DD-<topic>-plan.md
         └─ superpowers:subagent-driven-development | executing-plans
             └─ /verify-spec       → docs/superpowers/specs/YYYY-MM-DD-<topic>-verification.md
                 └─ /commit → /create-pr
```

Repo-specific gates attach to the phases rather than to a bespoke pipeline:

| Superpowers phase | Repo gate | Where it lives |
|---|---|---|
| brainstorming (design) | platform constitution compliance | `.claude/rules/platform-constitution.md` (auto-loaded) |
| implementation | KCL / Crossplane rules, CNP rules, observability rules | existing `.claude/rules/*.md` |
| before "done" | evidence table — fresh command output per claim | `.claude/rules/process.md` |
| after merge | live-cluster success-criteria verification | `/verify-spec` skill |

## Design

### A. `docs/specs/` becomes a read-only archive

The eleven active directories are merged work that was never archived (the archive workflow
silently skipped them). They move into quarterly buckets by last-commit date:

| Spec | Last commit | Destination |
|---|---|---|
| `0001-llm-platform-prometheus-autoscaling` | 2026-05-09 | `done/2026-Q2/` |
| `002-composition-owned-gateway-routing` … `006-genai-observability-envoy-gateway` | 2026-07-13 | `done/2026-Q3/` |
| `007-app-composition-workload-types` | 2026-07-14 | `done/2026-Q3/` |
| `007-flux-schema-validation-replace` | 2026-07-15 | `done/2026-Q3/` |
| `008-app-wizard-self-service-ui` | 2026-07-14 | `done/2026-Q3/` |
| `009-app-wizard-oss-split` | 2026-07-17 | `done/2026-Q3/` |
| `010-cnpg-barman-cloud-plugin` | 2026-07-18 | `done/2026-Q3/` |
| `011-inferencepool-saturation-keda` | 2026-07-18 | `done/2026-Q3/` |

The two `007-` directories keep distinct slugs, so the flat bucket has no collision. Bucketing
by last-commit date is an approximation of merge date; the archive README says so explicitly and
points at git history as the authority on status.

`git mv` is used so history follows the files.

`docs/specs/README.md` is replaced by a short archive notice — what this directory is, which
workflow produced it, when it stopped, and where the current workflow lives. `templates/` and
`PHASED.md` are deleted; both are pure SDD ceremony with no reader value once the workflow is gone.

### B. The constitution is promoted out of the archive

`docs/specs/constitution.md` → `docs/platform-constitution.md`. It is standing platform policy
(`xplane-*` naming, KCL no-mutation, zero-trust pod defaults, EKS Pod Identity, observability
requirements), not spec ceremony, and it must not sit inside a directory labelled "archive".

Its Section on "spec structure" (the 3-artifact layout, quarterly archiving) is rewritten to
describe the Superpowers artifacts instead. Everything else is unchanged.

`.claude/rules/spec-constitution.md` → `.claude/rules/platform-constitution.md`, with:
- the auto-load glob `docs/specs/**` replaced by `docs/superpowers/**`
- the source-of-truth link repointed at `docs/platform-constitution.md`
- the "Spec compliance checklist" entries about 3 artifacts and `[CLARIFIED:]` markers replaced
  by the Superpowers equivalents (design doc + plan committed, no `[NEEDS CLARIFICATION]`
  placeholders left in the design)

### C. Link repair

Three classes, all mechanical:

1. **Inbound links** (~15) from `README.md`, `CLAUDE.md`, `docs/coding-clients.md`,
   `clusters/mycluster-0-llm-platform/README.md`, `infrastructure/base/crossplane/configuration/kcl/inference-service/README.md`,
   `infrastructure/base/crossplane/configuration/kcl/kvstore/README.md`, `.fluxschema.yml`,
   `apps/base/ai/llm/ai-gateway-routes/route.yaml`, and the `runbook_url` in
   `apps/base/ai/llm/vmrule-llm-slo.yaml` — repointed at the archived paths. The kvstore
   README link is already broken today and gets fixed in the same pass.

2. **Constitution links inside archived docs** (~40 occurrences) — two forms exist today:
   `](../constitution.md)` in the directories being moved, and `](../../../constitution.md)` in
   the two already-archived ones. Both are rewritten to
   `[docs/platform-constitution.md](../../../../platform-constitution.md)`, matching the uniform
   post-move depth `docs/specs/done/<quarter>/<slug>/`.

3. **PHASED.md links inside archived docs** (~10 `- Phased specs: [...](../PHASED.md)` lines) —
   deleted, since the target is deleted.

The `runbook_url` in `vmrule-llm-slo.yaml` is a live alert annotation pointing at a
`github.com/.../blob/main/...` URL. It is the one link whose breakage is user-visible in
Grafana/Alertmanager, so it is verified explicitly.

### D. Superpowers configuration

| Change | Rationale |
|---|---|
| `.claude/settings.json` gains `"superpowers@claude-plugins-official": true` | the repo declares the plugin it depends on. Today only `gitops-skills@fluxcd` is declared and Superpowers is inherited from user-level settings, so a fresh clone by anyone else gets a documented workflow with no plugin behind it |
| New `.claude/rules/superpowers.md`, glob `docs/superpowers/**` | repo delta layer: artifact naming and locations, constitution gate at design time, evidence table at completion, worktree convention, and the pointer to `/verify-spec` |
| `.claude/rules/process.md` glob | `docs/specs/**` → `docs/superpowers/**` |
| `docs/superpowers/` normalized | three `*-plan.md` files currently sit in `specs/`; they move to `plans/` so `specs/` holds designs (+ research, verification) and `plans/` holds plans |
| `.gitignore` gains `.claude/worktrees/` | `superpowers:using-git-worktrees` creates them; untracked-but-not-ignored today |

The repo does not shadow, wrap, or re-word any Superpowers skill. Configuration is limited to
declaring the plugin, telling agents where artifacts go, and stating which repo gates apply
at which phase.

### E. Retooled power tools

Two skills survive because Superpowers has no equivalent:

**`/verify-spec <design-doc>`** — post-merge verification against the live cluster via the
`flux-operator-mcp` and `victoriametrics` / `victorialogs` MCPs. Rewritten to take a Superpowers
design doc instead of a 3-artifact directory: it reads the design's success criteria (whatever
their heading — the design format is prose, not `SC-XXX` templates), executes the checks, and
writes `docs/superpowers/specs/YYYY-MM-DD-<topic>-verification.md` alongside the design it verifies. It stays the mechanism behind
the `.claude/rules/process.md` evidence table for cluster-level claims.

**`/spec-research <slug> "<question>"`** — forked Explore subagent doing Context7 + repo scan
without burning main context. Output path changes to
`docs/superpowers/specs/YYYY-MM-DD-<slug>-research.md`.

Both are documented as optional companions to the Superpowers flow, not steps in it.

### F. Deletions

| Path | Reason |
|---|---|
| `.claude/skills/spec/`, `clarify/`, `validate/`, `spec-status/` | superseded by brainstorming / writing-plans |
| `scripts/sdd/create-spec.sh`, `scripts/sdd/generate-summary.sh` | scaffolding + SUMMARY generation for a format no longer produced |
| `scripts/validate-spec.sh` | validates the 3-artifact structure |
| `.github/workflows/spec-archive.yaml` | the buggy archiver; also the shell-injection surface |
| `.github/ISSUE_TEMPLATE/spec.md` | Superpowers has no GitHub-issue step |
| `docs/specs/templates/`, `docs/specs/PHASED.md` | SDD ceremony |
| `docs/plans/self-hosted-llm-platform/` | pre-SDD drafts for delivered work, citing scripts this change deletes |

`docs/plans/crossplane-validation-improvements.md` stays.

### G. Documentation rewrites

| File | Change |
|---|---|
| `CLAUDE.md` | §"Spec-Driven Development (SDD)" → §"Development Workflow (Superpowers)": the four-phase flow, artifact locations, when a design doc is warranted vs. skipped (the existing required/skip tables carry over verbatim — they are about change size, not workflow), the two surviving power tools, and the constitution link |
| `.claude/skills/README.md` | SDD tables removed; Superpowers flow described with the repo's own skills as companions |
| `docs/ci-workflows.md` | drop the `spec-archive.yaml` table row and its section |
| `README.md` | the public "we use Spec-Driven Development" paragraph rewritten to describe the Superpowers flow, pointing at `docs/superpowers/` |
| `docs/specs/README.md` | replaced by the archive notice |

### H. Blog: mark the custom SDD workflow as retired

The custom SDD workflow is public. Two articles in the `agentic_ai` series on
[blog.ogenki.io](https://blog.ogenki.io) describe it, and one links directly into the file tree
this change rearranges. Repo: `Smana/smana.github.io` (separate repository, separate PR).

**`content/{fr,en}/post/series/agentic_ai/ai-coding-agent/index.md`** (2026-02-06) — carries the
whole "My SDD variant for Platform Engineering" section: the constitution, the 4 review personas,
the `/spec` `/clarify` `/validate` `/create-pr` skill table, eight screenshots and a full
walkthrough. Three edits:

1. **Top banner** — `{{% notice info "Update 2026-08-18" %}}` immediately after the front matter,
   matching the convention already used in `terraform-controller` and
   `crossplane_composition_functions`. States that after several months of using Superpowers the
   repo switched to it, and that the workflow described below is retired.
2. **In-section note** — a short line at the head of the "My SDD variant" notice, so a reader
   arriving mid-article from a search result is not misled. The section body is *not* rewritten:
   it remains an accurate account of what was built and why, and the reasoning behind it
   (constitution, review personas, verification against a live cluster) survived the switch —
   only the mechanism changed.
3. **Link fix** — the constitution link
   (`.../blob/main/docs/specs/constitution.md`) is repointed at
   `.../blob/main/docs/platform-constitution.md`. Superpowers is added to the article's
   "Spec-Driven Development" reference list, which currently lists Spec Kit, OpenSpec and BMAD
   but not the tool that won.

The screenshots stay. They document a real workflow that ran for months; the notes frame them.

**`content/en/post/series/agentic_ai/ai-coding-tips/index.md`** (2026-02-08) — the English
translation is missing the article's entire opening section, `## Mon utilisation actuelle de
Claude Code` (~25 lines: the MCP list, the skills / subagents / SDD bullets, and the
"mise en abyme" notice about the self-hosted LLM stack). The French version already states that
Superpowers is the preferred SDD flavour; the English reader never sees it. The section is
translated and inserted, with the SDD bullet updated from "my current preference" to the
completed switch.

Tone and formatting follow the `ogenki-blog-style` skill; both language versions are edited in
the same commit so translations never diverge again on this point.

## Error handling and risks

| Risk | Mitigation |
|---|---|
| Link rot from the archive move | explicit `git grep` sweep for `docs/specs/[0-9]` after the move; every hit must resolve to a file that exists |
| `vmrule-llm-slo.yaml` runbook URL breaks silently (renders fine, 404s in a browser) | verify the target path exists at the new location before committing; it is a `blob/main` URL so it only resolves after merge |
| Someone re-runs a deleted script from muscle memory or an old doc | deletions and doc rewrites land in the same commit series; no doc left pointing at a deleted script |
| Constitution content drifts from `.claude/rules/platform-constitution.md` | unchanged from today — the rule file already summarizes the doc. The link is repointed, the duplication is pre-existing and deliberate (rules are loaded into context; the doc is for humans) |
| Archived specs' internal cross-references between each other (e.g. 009 → 008) | both move to the same bucket, so sibling `../008-.../` links keep resolving |
| Blog constitution link 404s between the two merges | the blog link is a `blob/main` URL, so it only resolves once the cloud-native-ref PR is on `main`. Merge order is enforced: platform PR first, blog PR second |
| Blog repo is mid-work (`fix/searchbar` branch, unrelated untracked files) | blog edits go on their own branch cut from the blog repo's default branch, touching only the three `index.md` files |

## Testing

| Claim | Evidence |
|---|---|
| Manifests still valid | `./scripts/validate-manifests.sh` → exit 0, `Invalid: 0, Skipped: 0` |
| No dangling `docs/specs/` links | scripted check: extract every `docs/specs/...` path referenced anywhere in the tree, assert each resolves to a file or directory that exists |
| No live references to deleted machinery | `git grep -n 'scripts/sdd\|validate-spec.sh\|spec-archive\|/clarify\|/spec-status'` returns only archive content |
| Rules still auto-load | `.claude/rules/*.md` front matter globs reviewed; `docs/superpowers/**` present in both `platform-constitution.md` and `process.md` |
| Archive complete | `docs/specs/` contains only `README.md` and `done/`; `ls docs/specs/done/*/` shows 13 spec directories |
| Blog builds | `hugo --gc --minify` in the blog repo → exit 0, no broken shortcode |
| Blog link targets exist | the constitution path referenced by both language versions resolves in the cloud-native-ref working tree |
| Translations in sync | FR and EN `ai-coding-agent` carry the same two notices; EN `ai-coding-tips` contains the ported section |

## Rollout

**Platform repo** — single PR on `chore/superpowers-sdd-migration`, structured as ordered commits
so review is tractable: (1) archive move + link repair, (2) constitution promotion,
(3) deletions, (4) Superpowers configuration, (5) documentation rewrites, (6) power-tool
retooling.

**Blog repo** — a second, smaller PR on its own branch, merged *after* the platform PR so the
`blob/main` constitution link resolves on publication.
