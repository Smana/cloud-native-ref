# Superpowers SDD Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Superpowers the single documented development workflow for cloud-native-ref, archive the retired in-house SDD machinery without breaking a single link, and mark the published articles that document it as superseded.

**Architecture:** Two repositories, two PRs, strict merge order. In `cloud-native-ref`: promote the platform constitution out of the spec tree, archive eleven merged spec directories into quarterly buckets, repair every inbound and intra-archive link, delete the SDD scripts / CI workflow / issue template / four slash-command skills, retool the two surviving skills against Superpowers artifact paths, and rewrite the four documents that describe the workflow. In `smana.github.io`: add retirement notices to the two articles that document the old flow and close a translation gap.

**Tech Stack:** Markdown, YAML, bash, `git mv`, Hugo 0.139.0, pre-commit, `./scripts/validate-manifests.sh`.

**Spec:** [`docs/superpowers/specs/2026-08-18-superpowers-sdd-migration-design.md`](../specs/2026-08-18-superpowers-sdd-migration-design.md)

## Global Constraints

- **This is a documentation/configuration migration. There is no unit-test suite to write.** Each task's "test" is a concrete shell command with expected output, run fresh in the same step. Never claim a task done without running it.
- **Branch:** `chore/superpowers-sdd-migration` in `/home/smana/Sources/cloud-native-ref` (already created, already carries the design doc in commits `bb53e050` and `d05eb934`).
- **Use `git mv`, never `mv`+`git add`** for every relocation, so history follows the files.
- **Never edit anything under `docs/specs/done/` except the two scripted link rewrites in Task 2.** Archived specs are historical records.
- **Constitution target path is `docs/platform-constitution.md`.** From any archived spec at `docs/specs/done/<quarter>/<slug>/`, the relative path is exactly `../../../../platform-constitution.md`.
- **Commit after every task.** Conventional commits. Never co-author, never add "Generated with Claude Code" attribution.
- **Pre-commit runs on every commit** and must pass. If `identify` breaks again: `uv pip install --python .venv/bin/python --reinstall identify`.
- **Blog repo is `/home/smana/Sources/smana.github.io`**, default branch `main`. It is currently checked out on `fix/searchbar` with unrelated untracked files — cut the blog branch from `origin/main`, and touch only the three `index.md` files named in Tasks 8 and 9.
- **French is the blog's primary language, English is the translation.** Both language versions change in the same commit.
- **Merge order is load-bearing:** the cloud-native-ref PR merges first. The blog links to `blob/main/docs/platform-constitution.md`, which only resolves afterwards.

---

## File Structure

**cloud-native-ref — created:**
- `docs/platform-constitution.md` (moved from `docs/specs/constitution.md`)
- `.claude/rules/platform-constitution.md` (moved from `.claude/rules/spec-constitution.md`)
- `.claude/rules/superpowers.md` (new — the repo's delta layer over the plugin)
- `docs/specs/README.md` (rewritten in place as an archive notice)

**cloud-native-ref — deleted:**
- `.claude/skills/{spec,clarify,validate,spec-status}/`
- `scripts/sdd/`, `scripts/validate-spec.sh`
- `.github/workflows/spec-archive.yaml`, `.github/ISSUE_TEMPLATE/spec.md`
- `docs/specs/templates/`, `docs/specs/PHASED.md`
- `docs/plans/self-hosted-llm-platform/`

**cloud-native-ref — modified:**
- `CLAUDE.md` (§Spec-Driven Development → §Development Workflow, plus one link at line 63)
- `README.md` (§AI-Assisted Development, plus one link at line 214)
- `docs/ci-workflows.md` (workflow table row, §Spec archive, related-docs link)
- `.claude/skills/README.md`, `.claude/rules/process.md`
- `.claude/skills/verify-spec/SKILL.md`, `.claude/skills/spec-research/SKILL.md`
- `.claude/settings.json`, `.gitignore`
- `docs/coding-clients.md`, `clusters/mycluster-0-llm-platform/README.md`, `.fluxschema.yml`
- `infrastructure/base/crossplane/configuration/kcl/{inference-service,kvstore}/README.md`
- `infrastructure/base/crossplane/configuration/inference-service-definition.yaml` (only if the archive sed matches — its two spec mentions are unnumbered prose, so it may end up untouched; that is fine)
- `apps/base/ai/llm/vmrule-llm-slo.yaml`, `apps/base/ai/llm/ai-gateway-routes/route.yaml`

**smana.github.io — modified:**
- `content/{fr,en}/post/series/agentic_ai/ai-coding-agent/index.md`
- `content/{fr,en}/post/series/agentic_ai/ai-coding-tips/index.md`

---

## Task 1: Promote the platform constitution

Moves the constitution out of the spec tree and rewrites the two passages inside it that describe the retired workflow. Must land before Task 2, because Task 2 points forty archived files at the new path.

**Files:**
- Move: `docs/specs/constitution.md` → `docs/platform-constitution.md`
- Move: `.claude/rules/spec-constitution.md` → `.claude/rules/platform-constitution.md`
- Modify: `docs/platform-constitution.md` (lines 5, 196–212, 231)
- Modify: `.claude/rules/platform-constitution.md` (title, line 3, compliance checklist)

**Interfaces:**
- Produces: the path `docs/platform-constitution.md`, consumed by Tasks 2, 4, 6 and by the blog tasks.

- [ ] **Step 1: Move both files with git**

```bash
cd /home/smana/Sources/cloud-native-ref
git mv docs/specs/constitution.md docs/platform-constitution.md
git mv .claude/rules/spec-constitution.md .claude/rules/platform-constitution.md
```

- [ ] **Step 2: Verify the moves are staged as renames**

```bash
git status --short
```

Expected: two `R` lines, no `D`+`??` pairs.

- [ ] **Step 3: Fix the constitution's own relative links (line 5)**

The file moved up one directory, so `../decisions/` and `./README.md` are now wrong. Replace line 5:

```markdown
**Related**: [Architecture Decision Records](../decisions/) | [SDD Workflow](./README.md)
```

with:

```markdown
**Related**: [Architecture Decision Records](./decisions/) | [Development workflow](../CLAUDE.md#development-workflow-superpowers)
```

- [ ] **Step 4: Rewrite section 8.2**

Replace the whole of `### 8.2 Specifications` (from that heading down to and including the line starting `On PR merge, the archive workflow`) with:

```markdown
### 8.2 Design documents

Non-trivial changes are designed before they are built, using the
[Superpowers](https://github.com/obra/superpowers) workflow (see `CLAUDE.md` →
*Development Workflow*).

| Artifact | Path | Produced by |
|----------|------|-------------|
| Design | `docs/superpowers/specs/YYYY-MM-DD-<topic>-design.md` | `superpowers:brainstorming` |
| Plan | `docs/superpowers/plans/YYYY-MM-DD-<topic>-plan.md` | `superpowers:writing-plans` |
| Verification | `docs/superpowers/specs/YYYY-MM-DD-<topic>-verification.md` | `/verify-spec`, post-merge |

**Decisions are durable**: a design records the options considered, the decision, and the
rationale — not just the outcome. Never leave a `[NEEDS CLARIFICATION]` marker in an approved
design; resolve it and write down why.

Specs produced by the retired in-house SDD workflow (2026-Q1 → 2026-Q3) are archived read-only
under [`docs/specs/`](./specs/).
```

- [ ] **Step 5: Fix the compliance checklist (line ~231)**

Replace:

```markdown
- [ ] `/validate` passes before implementation
```

with:

```markdown
- [ ] Design doc written and approved before implementation
```

- [ ] **Step 6: Verify no stale references remain in the constitution**

```bash
grep -n 'docs/specs/NNN\|/clarify\|/validate\|clarifications\.md\|SDD workflow\|3 mandatory artifacts' docs/platform-constitution.md
```

Expected: no output.

- [ ] **Step 7: Update the rule file header**

In `.claude/rules/platform-constitution.md`, replace the first three lines:

```markdown
# SDD Constitution Rules

Auto-loaded when editing files under `docs/specs/**`, `infrastructure/**`, `security/**`, `observability/**`, or `tooling/**`. These are the non-negotiable platform rules every spec / composition / manifest must comply with. Source of truth: [`docs/specs/constitution.md`](../../docs/specs/constitution.md).
```

with:

```markdown
# Platform Constitution Rules

Auto-loaded when editing files under `docs/superpowers/**`, `infrastructure/**`, `security/**`, `observability/**`, or `tooling/**`. These are the non-negotiable platform rules every design / composition / manifest must comply with. Source of truth: [`docs/platform-constitution.md`](../../docs/platform-constitution.md).
```

- [ ] **Step 8: Update the rule file's compliance checklist**

At the end of `.claude/rules/platform-constitution.md`, replace these two lines:

```markdown
- [ ] All 3 spec artifacts present (spec.md / plan.md / clarifications.md)
- [ ] No inline `[CLARIFIED:]` in spec.md (decisions are CL-N entries)
```

with:

```markdown
- [ ] Design doc committed under `docs/superpowers/specs/` and linked from the PR
- [ ] No `[NEEDS CLARIFICATION]` markers left in the approved design
```

- [ ] **Step 9: Verify the rule file**

```bash
grep -n 'docs/specs' .claude/rules/platform-constitution.md
```

Expected: no output.

- [ ] **Step 10: Commit**

```bash
git add -A docs/platform-constitution.md .claude/rules/platform-constitution.md docs/specs .claude/rules
git commit -m "docs(constitution): promote platform constitution out of the spec tree"
```

---

## Task 2: Archive the spec tree and repair every link

Moves eleven merged spec directories into quarterly buckets and fixes all three classes of link breakage in one reviewable unit. A reviewer cannot sensibly approve the move while rejecting the link repair.

**Files:**
- Move: eleven directories `docs/specs/*/` → `docs/specs/done/{2026-Q2,2026-Q3}/`
- Modify (scripted): ~40 files under `docs/specs/done/`
- Modify: `README.md:214`, `CLAUDE.md:63`, `docs/coding-clients.md:143`, `clusters/mycluster-0-llm-platform/README.md:163`, `infrastructure/base/crossplane/configuration/kcl/inference-service/README.md` (8 links), `infrastructure/base/crossplane/configuration/kcl/kvstore/README.md:58`, `infrastructure/base/crossplane/configuration/inference-service-definition.yaml:255`, `apps/base/ai/llm/vmrule-llm-slo.yaml:37`, `apps/base/ai/llm/ai-gateway-routes/route.yaml:19`, `.fluxschema.yml:1`
- Rewrite: `docs/specs/README.md`
- Delete: `docs/specs/templates/`, `docs/specs/PHASED.md`

**Interfaces:**
- Consumes: `docs/platform-constitution.md` from Task 1.
- Produces: `docs/specs/done/2026-Q2/0001-llm-platform-prometheus-autoscaling/` and `docs/specs/done/2026-Q3/{002..011}-*/`, referenced by Tasks 6 and 8.

- [ ] **Step 1: Record the pre-move link inventory**

```bash
git grep -c 'docs/specs/' -- . | wc -l
```

Note the number. It is the baseline for Step 9.

- [ ] **Step 2: Move the eleven directories**

```bash
cd /home/smana/Sources/cloud-native-ref
mkdir -p docs/specs/done/2026-Q2 docs/specs/done/2026-Q3

git mv docs/specs/0001-llm-platform-prometheus-autoscaling docs/specs/done/2026-Q2/

for d in 002-composition-owned-gateway-routing \
         003-inferenceservice-spec-engineargs-escape \
         004-per-inferenceservice-inferencepool-endpoint \
         005-vllm-cold-start-run \
         006-genai-observability-envoy-gateway \
         007-app-composition-workload-types \
         007-flux-schema-validation-replace \
         008-app-wizard-self-service-ui \
         009-app-wizard-oss-split \
         010-cnpg-barman-cloud-plugin \
         011-inferencepool-saturation-keda; do
  git mv "docs/specs/$d" docs/specs/done/2026-Q3/
done
```

- [ ] **Step 3: Verify the archive shape**

```bash
ls docs/specs/
ls docs/specs/done/2026-Q2/ | wc -l
ls docs/specs/done/2026-Q3/ | wc -l
```

Expected: `docs/specs/` lists only `PHASED.md  README.md  done  templates`; `2026-Q2` → `1`; `2026-Q3` → `12` (eleven moved plus the pre-existing `012-kvstore-composition-replace-bitnami`).

- [ ] **Step 4: Rewrite constitution links inside the archive**

Two source forms exist — `](../constitution.md)` in the just-moved directories and `](../../../constitution.md)` in the two that were archived earlier. Both become the same target.

```bash
grep -rl 'constitution\.md' docs/specs/done | xargs sed -i \
  -e 's|\[docs/specs/constitution\.md\](\.\./constitution\.md)|[docs/platform-constitution.md](../../../../platform-constitution.md)|g' \
  -e 's|\[docs/specs/constitution\.md\](\.\./\.\./\.\./constitution\.md)|[docs/platform-constitution.md](../../../../platform-constitution.md)|g'
```

- [ ] **Step 5: Verify every archived constitution link resolves**

```bash
fail=0
while IFS=: read -r f _; do
  d=$(dirname "$f")
  [ -f "$d/../../../../platform-constitution.md" ] || { echo "BROKEN: $f"; fail=1; }
done < <(grep -rn 'platform-constitution\.md' docs/specs/done)
echo "exit=$fail"
```

Expected: `exit=0`, no `BROKEN:` lines.

- [ ] **Step 6: Drop the PHASED.md reference lines**

```bash
grep -rl '^- Phased specs: ' docs/specs/done | xargs sed -i '/^- Phased specs: /d'
grep -rn 'PHASED\.md' docs/specs/done | grep -v '^Binary' || echo "no PHASED refs left"
```

Expected: `no PHASED refs left`.

- [ ] **Step 7: Delete the templates and the phased-spec guide**

```bash
git rm -r -q docs/specs/templates
git rm -q docs/specs/PHASED.md
```

- [ ] **Step 8: Rewrite inbound links across the repo**

```bash
cd /home/smana/Sources/cloud-native-ref
FILES=$(git grep -l 'docs/specs/[0-9]' -- . ':!docs/specs/done')

for f in $FILES; do
  sed -i \
    -e 's|docs/specs/0001-llm-platform-prometheus-autoscaling|docs/specs/done/2026-Q2/0001-llm-platform-prometheus-autoscaling|g' \
    -e 's|docs/specs/002-composition-owned-gateway-routing|docs/specs/done/2026-Q3/002-composition-owned-gateway-routing|g' \
    -e 's|docs/specs/003-inferenceservice-spec-engineargs-escape|docs/specs/done/2026-Q3/003-inferenceservice-spec-engineargs-escape|g' \
    -e 's|docs/specs/004-per-inferenceservice-inferencepool-endpoint|docs/specs/done/2026-Q3/004-per-inferenceservice-inferencepool-endpoint|g' \
    -e 's|docs/specs/005-vllm-cold-start-run|docs/specs/done/2026-Q3/005-vllm-cold-start-run|g' \
    -e 's|docs/specs/006-genai-observability-envoy-gateway|docs/specs/done/2026-Q3/006-genai-observability-envoy-gateway|g' \
    -e 's|docs/specs/007-app-composition-workload-types|docs/specs/done/2026-Q3/007-app-composition-workload-types|g' \
    -e 's|docs/specs/007-flux-schema-validation-replace|docs/specs/done/2026-Q3/007-flux-schema-validation-replace|g' \
    -e 's|docs/specs/008-app-wizard-self-service-ui|docs/specs/done/2026-Q3/008-app-wizard-self-service-ui|g' \
    -e 's|docs/specs/009-app-wizard-oss-split|docs/specs/done/2026-Q3/009-app-wizard-oss-split|g' \
    -e 's|docs/specs/010-cnpg-barman-cloud-plugin|docs/specs/done/2026-Q3/010-cnpg-barman-cloud-plugin|g' \
    -e 's|docs/specs/011-inferencepool-saturation-keda|docs/specs/done/2026-Q3/011-inferencepool-saturation-keda|g' \
    -e 's|docs/specs/012-kvstore-composition-replace-bitnami|docs/specs/done/2026-Q3/012-kvstore-composition-replace-bitnami|g' \
    "$f"
done
```

The `012` rule fixes a link that is **already broken today** in `kcl/kvstore/README.md`.

- [ ] **Step 9: Verify every referenced spec path exists**

This is the gate the design names. It extracts every `docs/specs/...` path mentioned anywhere in the tree and asserts the target exists.

```bash
cd /home/smana/Sources/cloud-native-ref
git grep -ho 'docs/specs/[A-Za-z0-9/_.-]*' -- . \
  | sed 's/[.,)]*$//' | sort -u | while read -r p; do
      case "$p" in
        docs/specs|docs/specs/|docs/specs/done|docs/specs/done/) continue ;;
      esac
      [ -e "$p" ] || echo "MISSING: $p"
    done
echo "check complete"
```

Expected: no `MISSING:` lines. Any hit that is a prose fragment rather than a real path (e.g. `docs/specs/NNN-slug`) must be reworded, not ignored.

- [ ] **Step 10: Sanity-check the two live manifests**

```bash
grep -n 'runbook_url' apps/base/ai/llm/vmrule-llm-slo.yaml
grep -n 'docs/specs' apps/base/ai/llm/ai-gateway-routes/route.yaml .fluxschema.yml
```

Expected: the runbook URL now reads `.../blob/main/docs/specs/done/2026-Q2/0001-llm-platform-prometheus-autoscaling/spec.md#fr-006`; both comments carry `done/2026-Q3/`.

- [ ] **Step 11: Replace `docs/specs/README.md` with the archive notice**

```markdown
# Spec archive (retired workflow)

> **This directory is a read-only archive. Do not add new specs here.**

From 2026-Q1 to 2026-Q3 this repository used an in-house spec-driven workflow — `/spec` →
`/clarify` → `/validate` → `/create-pr` — where each spec was a three-artifact directory
(`spec.md` = WHAT, `plan.md` = HOW, `clarifications.md` = an append-only decision log). It drew
on GitHub Spec Kit, with a platform constitution and a four-persona review checklist layered on
top.

It was retired on **2026-08-18** in favour of the
[Superpowers](https://github.com/obra/superpowers) plugin, which had been the workflow in
practice for several months. See [`CLAUDE.md`](../../CLAUDE.md) → *Development Workflow* for the
current flow, and [`docs/superpowers/`](../superpowers/) for its artifacts.

## What is here

| Bucket | Specs |
|--------|-------|
| [`done/2024-Q1/`](done/2024-Q1/) | `0000-eks-pod-identity` |
| [`done/2026-Q2/`](done/2026-Q2/) | `0001-llm-platform-prometheus-autoscaling` |
| [`done/2026-Q3/`](done/2026-Q3/) | `002`–`012`: gateway routing, `engineArgs` escape hatch, per-service InferencePool, vLLM cold start, GenAI observability, app workload types, Flux schema validation, app wizard (×2), CNPG Barman Cloud, InferencePool saturation, KVStore |

Directories were bucketed by their last-commit date when the archive was created, so a bucket is
an approximation of the merge quarter — **git history is the authority on when each shipped**.

The platform constitution these specs cite now lives at
[`docs/platform-constitution.md`](../platform-constitution.md).
```

- [ ] **Step 12: Verify the tree is clean and commit**

```bash
ls docs/specs/
git add -A
git commit -m "docs(specs): archive the retired SDD spec tree and repair every reference"
```

Expected before commit: `docs/specs/` lists exactly `README.md` and `done`.

---

## Task 3: Delete the legacy SDD machinery

**Files:**
- Delete: `.claude/skills/spec/`, `.claude/skills/clarify/`, `.claude/skills/validate/`, `.claude/skills/spec-status/`
- Delete: `scripts/sdd/`, `scripts/validate-spec.sh`
- Delete: `.github/workflows/spec-archive.yaml`, `.github/ISSUE_TEMPLATE/spec.md`
- Delete: `docs/plans/self-hosted-llm-platform/`

**Interfaces:**
- Consumes: nothing.
- Produces: nothing. Tasks 5 and 6 assume these paths are gone.

- [ ] **Step 1: Confirm nothing in CI calls the scripts**

```bash
cd /home/smana/Sources/cloud-native-ref
grep -rn 'validate-spec\|scripts/sdd' .github/ || echo "no CI references outside spec-archive.yaml"
```

Expected: hits only inside `.github/workflows/spec-archive.yaml` (which is about to be deleted).

- [ ] **Step 2: Delete everything**

```bash
git rm -r -q .claude/skills/spec .claude/skills/clarify .claude/skills/validate .claude/skills/spec-status
git rm -r -q scripts/sdd
git rm -q scripts/validate-spec.sh
git rm -q .github/workflows/spec-archive.yaml
git rm -q .github/ISSUE_TEMPLATE/spec.md
git rm -r -q docs/plans/self-hosted-llm-platform
```

- [ ] **Step 3: Verify the remaining issue templates survived**

```bash
ls .github/ISSUE_TEMPLATE/
```

Expected: `bug_report.md  enhancement.md`.

- [ ] **Step 4: Verify no live file references the deleted machinery**

```bash
git grep -n 'scripts/sdd\|validate-spec\.sh\|spec-archive' -- . ':!docs/specs/done' ':!docs/superpowers' || echo "clean"
```

Expected: `clean`. Hits inside `docs/specs/done/` and `docs/superpowers/` are historical records and are left alone.

- [ ] **Step 5: Commit**

```bash
git commit -m "chore(sdd): remove the retired spec scripts, workflow, issue template and skills"
```

---

## Task 4: Configure Superpowers

**Files:**
- Modify: `.claude/settings.json`
- Create: `.claude/rules/superpowers.md`
- Modify: `.claude/rules/process.md` (line 3)
- Move: three `*-plan.md` files from `docs/superpowers/specs/` → `docs/superpowers/plans/`
- Modify: `.gitignore`

**Interfaces:**
- Produces: `.claude/rules/superpowers.md`, referenced by `CLAUDE.md` in Task 6.

- [ ] **Step 1: Declare the plugin**

Replace the whole of `.claude/settings.json` with:

```json
{
  "enabledPlugins": {
    "gitops-skills@fluxcd": true,
    "superpowers@claude-plugins-official": true
  }
}
```

- [ ] **Step 2: Verify it is valid JSON**

```bash
python3 -m json.tool .claude/settings.json
```

Expected: the formatted document, exit 0.

- [ ] **Step 3: Create the repo delta rule**

Write `.claude/rules/superpowers.md`:

```markdown
---
description: Repo-specific deltas for the Superpowers workflow — artifact locations and the gate that applies at each phase
globs:
  - "docs/superpowers/**"
---

# Superpowers Workflow — repo deltas

The methodology itself lives in the plugin (`superpowers:brainstorming`,
`superpowers:writing-plans`, `superpowers:subagent-driven-development`,
`superpowers:test-driven-development`, `superpowers:verification-before-completion`). This file
is only what differs in cloud-native-ref.

## Artifact locations

| Artifact | Path | Produced by |
|----------|------|-------------|
| Design | `docs/superpowers/specs/YYYY-MM-DD-<topic>-design.md` | `superpowers:brainstorming` |
| Plan | `docs/superpowers/plans/YYYY-MM-DD-<topic>-plan.md` | `superpowers:writing-plans` |
| Research | `docs/superpowers/specs/YYYY-MM-DD-<topic>-research.md` | `/spec-research` |
| Verification | `docs/superpowers/specs/YYYY-MM-DD-<topic>-verification.md` | `/verify-spec`, post-merge |

Designs and plans are committed on the feature branch as the work proceeds, not merged to `main`
ahead of it. The PR body links the design.

## Gate at each phase

| Phase | Gate |
|-------|------|
| Design | [Platform constitution](../../docs/platform-constitution.md) — `xplane-*` naming, default-deny CiliumNetworkPolicy, EKS Pod Identity over IRSA, External Secrets, resource requests + limits |
| Implementation | `kcl-crossplane.md`, `crossplane-validation.md`, `cilium-network-policies.md`, `observability.md`, `opentofu.md` in this directory |
| Before claiming done | `process.md` in this directory — the evidence table. A fresh command run per claim, output cited inline |
| After merge | `/verify-spec` for anything with cluster-observable criteria |

## Isolation

Work that touches the running cluster belongs in a worktree
(`superpowers:using-git-worktrees`); worktrees live in `.claude/worktrees/`, which is gitignored.
When deploying a feature branch to the cluster, pass
`TF_VAR_flux_git_ref=refs/heads/<branch>` to the Terramate deploy script.

## Historical note

The in-house SDD workflow (`/spec` → `/clarify` → `/validate`, three-artifact directories under
`docs/specs/NNN-slug/`) was retired on 2026-08-18. Its output is archived read-only under
[`docs/specs/`](../../docs/specs/). Do not create new artifacts there.
```

- [ ] **Step 4: Repoint the process rule**

In `.claude/rules/process.md`, replace on line 3:

```
Auto-loaded when editing files under `docs/specs/**`, `infrastructure/**`,
```

with:

```
Auto-loaded when editing files under `docs/superpowers/**`, `infrastructure/**`,
```

Then in the same file's evidence table, replace the row:

```markdown
| Spec ready | `./scripts/validate-spec.sh <dir>` → 0 errors |
```

with:

```markdown
| Design ready | Design doc committed under `docs/superpowers/specs/`, no `[NEEDS CLARIFICATION]` markers left |
```

and replace:

```markdown
| SC-XXX met (post-merge) | `/verify-spec <dir>` against live cluster |
```

with:

```markdown
| Success criteria met (post-merge) | `/verify-spec <design-doc>` against live cluster |
```

- [ ] **Step 5: Verify the process rule**

```bash
grep -n 'docs/specs\|validate-spec\|SC-XXX' .claude/rules/process.md
```

Expected: no output.

- [ ] **Step 6: Normalize the docs/superpowers layout**

```bash
cd /home/smana/Sources/cloud-native-ref
git mv docs/superpowers/specs/2026-05-04-coding-llm-fleet-plan.md docs/superpowers/plans/
git mv docs/superpowers/specs/2026-05-05-ai-gateway-redesign-plan.md docs/superpowers/plans/
git mv docs/superpowers/specs/2026-05-06-oss-llm-foundation-showcase-plan.md docs/superpowers/plans/
ls docs/superpowers/specs/ docs/superpowers/plans/
```

Expected: `specs/` holds only `*-design.md` files plus this migration's design; `plans/` holds four `*.md` plan files.

- [ ] **Step 7: Verify the move broke no cross-links**

```bash
git grep -n 'specs/2026-05-04-coding-llm-fleet-plan\|specs/2026-05-05-ai-gateway-redesign-plan\|specs/2026-05-06-oss-llm-foundation-showcase-plan' -- . || echo "no stale plan paths"
```

Expected: `no stale plan paths`. If a hit appears, rewrite that path to `plans/<same-basename>`.

- [ ] **Step 8: Gitignore the worktree directory**

Append to `.gitignore`, right after the existing `.claude/scheduled_tasks.lock` block:

```gitignore
# Superpowers git worktrees (superpowers:using-git-worktrees creates these)
.claude/worktrees/
```

- [ ] **Step 9: Verify the ignore rule works**

```bash
git check-ignore -v .claude/worktrees/anything
```

Expected: a line naming `.gitignore` and the `.claude/worktrees/` pattern.

- [ ] **Step 10: Commit**

```bash
git add -A .claude .gitignore docs/superpowers
git commit -m "chore(claude): configure Superpowers as the declared workflow"
```

---

## Task 5: Retool the two surviving skills

Both skills keep their logic and lose their dependency on the three-artifact format.

**Files:**
- Modify: `.claude/skills/verify-spec/SKILL.md`
- Modify: `.claude/skills/spec-research/SKILL.md`

**Interfaces:**
- Consumes: the artifact paths defined in `.claude/rules/superpowers.md` (Task 4).
- Produces: `/verify-spec` and `/spec-research` as documented in `CLAUDE.md` (Task 6).

- [ ] **Step 1: Rewrite the verify-spec frontmatter**

Replace the frontmatter block of `.claude/skills/verify-spec/SKILL.md` with:

```yaml
---
name: verify-spec
description: Verify that a merged design's success criteria are actually met in the live cluster. Deploys the example manifest, watches Flux reconciliation, queries VictoriaMetrics/VictoriaLogs for evidence, writes docs/superpowers/specs/<topic>-verification.md.
when_to_use: |
  When the user says "verify the design", "did that actually ship",
  "check this works", "post-merge verification", "UAT this feature",
  "prove the success criteria", or after a feature PR has merged and the
  user wants to close the loop on whether the delivered work satisfies
  the design's acceptance criteria.
disable-model-invocation: true
argument-hint: "<design-doc> — path to a docs/superpowers/specs/*-design.md file"
paths: "docs/superpowers/**"
allowed-tools: Read, Write, Bash(kubectl:*), Bash(flux:*), Grep, Glob
---
```

- [ ] **Step 2: Rewrite the verify-spec input section**

Replace `### 1. Locate inputs` and `### 2. Enumerate success criteria` with:

```markdown
### 1. Locate inputs

Resolve `$ARGUMENTS` to a design document under `docs/superpowers/specs/`. Accept a bare topic
slug and glob for it. Abort with guidance if not found.

Read:
- the design doc — its goals, testing table, and any explicit success criteria
- the matching plan at `docs/superpowers/plans/<same-date>-<same-topic>-plan.md`, if present —
  its per-task verification commands are usually the best evidence source
- any example manifests the design names

Archived specs under `docs/specs/done/` are also accepted, for re-verifying older work. Those use
the retired `SC-XXX` format; parse `**SC-XXX**: <text>` lines when you see them.

### 2. Enumerate success criteria

Superpowers designs state criteria in prose and in a **Testing** table rather than as numbered
`SC-XXX` items. Extract one checkable claim per row or per bullet, and give each a stable local
id (`C-1`, `C-2`, …) for the report. For each, infer a verification method:

| Criterion pattern | Verification method |
|---|---|
| "pods can call AWS APIs …" | `kubectl run` a test pod; try the API; check result |
| "reconciliation succeeds within Xs" | `flux get` + time window check |
| "metrics emit" | VictoriaMetrics query for the metric name |
| "logs appear" | VictoriaLogs query for the log stream |
| "latency p95 < Y" | VictoriaMetrics `histogram_quantile(0.95, ...)` |
| "resource X created" | `kubectl get X -l <label>` |
| a literal shell command in the Testing table | run it verbatim; compare to the stated expected output |

If the method is unclear, list the criterion as `MANUAL` and ask the user how they want to verify.
```

- [ ] **Step 3: Repoint the verify-spec output**

In `### 6. Write `VERIFICATION.md``, change the heading to `### 6. Write the verification report`,
change the emit path from `<spec-dir>/VERIFICATION.md` to
`docs/superpowers/specs/<YYYY-MM-DD>-<topic>-verification.md` (same date and topic as the design
it verifies), and in the report template replace the `ID | SC-XXX` column values with the `C-N`
ids from step 2 and the `## References` block with:

```markdown
## References

- Design: `docs/superpowers/specs/<name>-design.md`
- Plan: `docs/superpowers/plans/<name>-plan.md` (if present)
- Example applied: `<path>`
```

- [ ] **Step 4: Fix the verify-spec related-skills list**

Replace the `## Related skills` block with:

```markdown
## Related skills

- `superpowers:brainstorming` — produced the design this verifies
- `superpowers:verification-before-completion` — the generic evidence discipline
- `/gitops-cluster-debug` (fluxcd plugin) — deep Flux troubleshooting
```

- [ ] **Step 5: Rewrite the spec-research frontmatter**

Replace the frontmatter block of `.claude/skills/spec-research/SKILL.md` with:

```yaml
---
name: spec-research
description: Research patterns, ecosystem tools, and best practices before writing a design. Runs in a forked Explore subagent so it can query Context7, WebSearch, and the whole codebase without consuming the main context window. Writes docs/superpowers/specs/YYYY-MM-DD-<slug>-research.md.
when_to_use: |
  When the user says "research before designing", "what does the ecosystem say",
  "look at how others do this", "find existing patterns for X", "scan Context7",
  or when the work covers a topic the platform hasn't built before (new operator,
  new managed service, new KCL pattern).
disable-model-invocation: true
argument-hint: '<slug> "<research question>" — e.g. /spec-research valkey "Valkey caching composition best practices"'
context: fork
agent: Explore
allowed-tools: Read, Grep, Glob, Bash(git:*), WebSearch, WebFetch
---
```

- [ ] **Step 6: Repoint the spec-research paths**

Inside `.claude/skills/spec-research/SKILL.md`, make these substitutions:

| Old | New |
|-----|-----|
| `writes exactly one file: \`docs/specs/<spec-slug>/research.md\`` | `writes exactly one file: \`docs/superpowers/specs/<YYYY-MM-DD>-<slug>-research.md\`` |
| `Research \`$ARGUMENTS\` for the SDD spec at \`docs/specs/<spec-slug>/\`` | `Research \`$ARGUMENTS\` to feed a Superpowers design (`superpowers:brainstorming`)` |
| `If the spec directory does not exist yet, proceed anyway and write research to \`docs/specs/<slug>/research.md\` for the spec author to consume.` | `The design doc need not exist yet — write the research file so the design author can consume it.` |
| `**Constitution** (\`docs/specs/constitution.md\`)` | `**Constitution** (\`docs/platform-constitution.md\`)` |
| `**Similar archived specs** (\`docs/specs/done/\`)` | `**Prior designs** (\`docs/superpowers/specs/\`) and **archived specs** (\`docs/specs/done/\`)` |
| `Emit exactly this structure at \`docs/specs/<spec-slug>/research.md\`` | `Emit exactly this structure at \`docs/superpowers/specs/<YYYY-MM-DD>-<slug>-research.md\`` |
| `**Spec**: <spec-slug>` (in the template) | `**Topic**: <slug>` |
| `<Items to turn into [NEEDS CLARIFICATION: ...] markers in spec.md>` | `<Items to raise as open questions during brainstorming>` |
| `The spec + \`/clarify\` are where decisions happen.` | `Brainstorming is where decisions happen.` |
| `3. **GitHub Spec Kit / GSD patterns** when the research is meta (about the workflow, not the tech).` | `3. **Superpowers skills** (`~/.claude/plugins/.../superpowers/skills/`) when the research is meta — about the workflow, not the tech.` |

- [ ] **Step 7: Verify both skills are clean**

```bash
grep -n 'docs/specs/<\|spec-dir\|SC-XXX\|/clarify\|/validate\|3-artifact\|clarifications\.md' .claude/skills/verify-spec/SKILL.md .claude/skills/spec-research/SKILL.md
```

Expected: no output. (`docs/specs/done/` mentions are intentional and do not match this pattern.)

- [ ] **Step 8: Commit**

```bash
git add .claude/skills
git commit -m "feat(skills): retool verify-spec and spec-research for Superpowers artifacts"
```

---

## Task 6: Rewrite the workflow documentation

**Files:**
- Modify: `CLAUDE.md` (replace `## Spec-Driven Development (SDD)` through the line before `## Security Considerations`)
- Modify: `.claude/skills/README.md`
- Modify: `docs/ci-workflows.md` (three places)
- Modify: `README.md` (§AI-Assisted Development)

**Interfaces:**
- Consumes: the artifact paths from Task 4, the retooled skills from Task 5, the archive from Task 2.

- [ ] **Step 1: Replace the CLAUDE.md section**

Delete everything from `## Spec-Driven Development (SDD)` up to (not including) `## Security Considerations`, and put in its place:

````markdown
## Development Workflow (Superpowers)

Non-trivial changes go through the [Superpowers](https://github.com/obra/superpowers) plugin,
declared in `.claude/settings.json`. Its skills auto-trigger — there are no repo-specific slash
commands to remember for the core flow.

```
superpowers:brainstorming        → docs/superpowers/specs/YYYY-MM-DD-<topic>-design.md
  superpowers:writing-plans      → docs/superpowers/plans/YYYY-MM-DD-<topic>-plan.md
    superpowers:subagent-driven-development (or executing-plans)
      /verify-spec               → docs/superpowers/specs/YYYY-MM-DD-<topic>-verification.md
        /commit → /create-pr
```

**Key documents**:
- [Platform Constitution](docs/platform-constitution.md) — non-negotiable principles (auto-loaded via `.claude/rules/platform-constitution.md`)
- [Architecture Decision Records](docs/decisions/) — cross-cutting technology choices
- [Repo deltas](.claude/rules/superpowers.md) — artifact locations and the gate that applies at each phase
- [Spec archive](docs/specs/) — output of the in-house SDD workflow retired on 2026-08-18, read-only

### When a Design Is Required

| Change Type | Examples |
|-------------|----------|
| New Crossplane Composition | New KCL module, new XRD |
| Major Infrastructure | New OpenTofu stack, VPC changes, EKS upgrades |
| Security Changes | Network policies, RBAC, PKI, secrets |
| Platform Capabilities | Multi-component features, observability |

### When to Skip

Version bumps, documentation-only, single-file bug fixes, minor config changes, HelmRelease value tweaks.

### Repo-Specific Companions

Two skills cover ground the plugin does not. Both are optional.

| Skill | Description |
|-------|-------------|
| `/verify-spec <design-doc>` | Post-merge: verify a design's success criteria against the live cluster via the Flux and VictoriaMetrics/VictoriaLogs MCPs, write `<topic>-verification.md` |
| `/spec-research <slug> "<q>"` | Forked Explore subagent: Context7 + repo scan → writes `<date>-<slug>-research.md` without burning main context |
````

- [ ] **Step 2: Verify CLAUDE.md**

```bash
grep -n 'SDD\|/clarify\|/spec-status\|scripts/sdd\|PHASED\|3-artifact' CLAUDE.md
```

Expected: no output.

- [ ] **Step 3: Rewrite the skills README**

Replace the `## Quick Start` block and the `### Spec-Driven Development (SDD)` section of
`.claude/skills/README.md` with:

````markdown
## Quick Start

The core development workflow is the [Superpowers](https://github.com/obra/superpowers) plugin —
its skills auto-trigger, so there is nothing to type. See `CLAUDE.md` → *Development Workflow*.

The skills in this directory are repo-specific companions to that flow:

```bash
/spec-research <slug> "<question>"   # Deep ecosystem scan in a forked subagent → research doc
/verify-spec <design-doc>            # Post-merge: prove the criteria against the live cluster
/commit                              # Pre-commit validate + conventional commit
/create-pr                           # Open PR with a mermaid diagram
/improve-pr <pr-number>              # Security review + code improvements
```

## Available Skills

### Design and verification

| Skill | Usage | Description |
|-------|-------|-------------|
| **spec-research** | `/spec-research <slug> "<question>"` | Forked Explore subagent: Context7 + repo scan → writes `docs/superpowers/specs/<date>-<slug>-research.md` |
| **verify-spec** | `/verify-spec <design-doc>` | Post-merge: check a design's success criteria against the live cluster via Flux + VictoriaMetrics MCPs, write `<topic>-verification.md` |
````

Leave the *Git & PR Workflows*, *Crossplane & KCL Validation* and *FluxCD GitOps* sections
untouched, and replace the closing paragraph that points at `docs/specs/README.md` with:

```markdown
Path-scoped rules in [`../rules/`](../rules/) auto-load when editing matching files — notably
`superpowers.md` (workflow deltas), `platform-constitution.md` (platform non-negotiables) and
`process.md` (verification + debugging discipline).
```

- [ ] **Step 4: Update docs/ci-workflows.md**

Three edits:

1. Delete the workflow-table row:

```markdown
| `spec-archive.yaml` | PR (merge) | SDD automation: archive a spec directory when its PR merges |
```

2. Delete the whole `### Spec archive (`spec-archive.yaml`)` section, including its body paragraph.

3. In `## Related documentation`, replace:

```markdown
- [Spec-driven development](./specs/README.md) — SDD workflow, including SPEC-007 (manifest validation)
```

with:

```markdown
- [Platform constitution](./platform-constitution.md) — the non-negotiable rules CI enforces
- [Spec archive](./specs/) — the retired SDD workflow that produced SPEC-007 (manifest validation)
```

- [ ] **Step 5: Verify ci-workflows.md**

```bash
grep -n 'spec-archive\|SDD' docs/ci-workflows.md
```

Expected: no output.

- [ ] **Step 6: Rewrite the README paragraph**

In `README.md`, replace the `## AI-Assisted Development` body paragraph with:

```markdown
This repository leverages a coding agent for various development tasks including code generation, troubleshooting, and documentation. The [CLAUDE.md](CLAUDE.md) file provides project context and platform-specific knowledge to help the agent understand the codebase. For non-trivial changes we use the [Superpowers](https://github.com/obra/superpowers) workflow — a design document is brainstormed and approved, turned into an implementation plan, and executed task by task, with every artifact committed under [docs/superpowers/](docs/superpowers/). A [platform constitution](docs/platform-constitution.md) states the non-negotiable rules every design is checked against. The agent also integrates with observability tools via MCP servers (VictoriaMetrics, VictoriaLogs, Flux) for real-time debugging directly from the development environment.
```

- [ ] **Step 7: Verify the README**

```bash
grep -n 'Spec-Driven Development\|docs/specs/README' README.md
```

Expected: no output.

- [ ] **Step 8: Commit**

```bash
git add CLAUDE.md README.md docs/ci-workflows.md .claude/skills/README.md
git commit -m "docs: document Superpowers as the repository development workflow"
```

---

## Task 7: Full verification and pull request

**Files:** none modified — this task only runs gates and opens the PR.

- [ ] **Step 1: Render and gate every manifest**

```bash
cd /home/smana/Sources/cloud-native-ref
./scripts/validate-manifests.sh
```

Expected: exit 0, and the report line reads `Invalid: 0, Skipped: 0`. Two touched files
(`vmrule-llm-slo.yaml`, `route.yaml`) are in the rendered bundle, so this is the gate that proves
the edits did not corrupt them. If it fails, stop and fix the root cause — do not proceed.

- [ ] **Step 2: Prove no dangling spec references**

```bash
git grep -ho 'docs/specs/[A-Za-z0-9/_.-]*' -- . | sed 's/[.,)]*$//' | sort -u | while read -r p; do
  case "$p" in docs/specs|docs/specs/|docs/specs/done|docs/specs/done/) continue ;; esac
  [ -e "$p" ] || echo "MISSING: $p"
done; echo "done"
```

Expected: no `MISSING:` lines.

- [ ] **Step 3: Prove no live reference to deleted machinery**

```bash
git grep -n 'scripts/sdd\|validate-spec\.sh\|spec-archive\|/spec-status\|3-artifact' -- . ':!docs/specs/done' ':!docs/superpowers'
```

Expected: no output.

- [ ] **Step 4: Prove the archive is complete**

```bash
ls docs/specs/
ls docs/specs/done/*/ -d
ls docs/specs/done/*/ | grep -c '^0\|^1'
```

Expected: `docs/specs/` shows `README.md  done`; three bucket directories; thirteen spec
directories in total.

- [ ] **Step 5: Confirm the rules still parse**

```bash
for f in .claude/rules/*.md; do head -1 "$f" | grep -q '^---\|^#' || echo "BAD HEADER: $f"; done; echo ok
grep -l 'docs/superpowers' .claude/rules/*.md
```

Expected: `ok` with no `BAD HEADER`; the grep lists `platform-constitution.md`, `process.md` and
`superpowers.md`.

- [ ] **Step 6: Review the full diff**

```bash
git diff main --stat
```

Read it. Every deletion should be intentional and every rename should show as `R`.

- [ ] **Step 7: Push and open the PR**

```bash
git push -u origin chore/superpowers-sdd-migration
```

Then use `/create-pr`, or `gh pr create` with a body that covers: what changed and why, the
archive mapping table, the fact that the constitution moved, the two skills that survived, and an
explicit note that **the companion blog PR must merge after this one** because it links to
`blob/main/docs/platform-constitution.md`. Title and body in English.

---

## Task 8: Blog — mark the SDD variant as retired

**Files:**
- Modify: `content/fr/post/series/agentic_ai/ai-coding-agent/index.md`
- Modify: `content/en/post/series/agentic_ai/ai-coding-agent/index.md`

**Interfaces:**
- Consumes: `docs/platform-constitution.md` existing on `main` in cloud-native-ref (Task 7 merged).

- [ ] **Step 1: Create the blog branch**

```bash
cd /home/smana/Sources/smana.github.io
git fetch origin
git checkout -b docs/superpowers-switch origin/main
git status -sb
```

Expected: `## docs/superpowers-switch...origin/main`. Untracked files from the previous branch are
unrelated and stay untracked — do not stage them.

- [ ] **Step 2: Add the French banner**

In `content/fr/post/series/agentic_ai/ai-coding-agent/index.md`, immediately after the closing
`+++` of the front matter (line 18) and before the opening paragraph, insert:

```markdown

{{% notice info "Mise à jour 2026-08-18" %}}
Après plusieurs mois à utiliser [Superpowers](https://github.com/obra/superpowers), j'ai basculé [cloud-native-ref](https://github.com/Smana/cloud-native-ref) entièrement dessus : la variante SDD maison décrite plus bas est désormais retirée. Le raisonnement qui la sous-tendait — constitution de plateforme, personas de review, vérification sur cluster réel — reste valable ; c'est le mécanisme qui a changé. J'en parle dans la [partie 2 de la série](/fr/post/series/agentic_ai/ai-coding-tips/).
{{% /notice %}}
```

- [ ] **Step 3: Add the English banner**

Same position in `content/en/post/series/agentic_ai/ai-coding-agent/index.md` (after line 18):

```markdown

{{% notice info "Update 2026-08-18" %}}
After several months of using [Superpowers](https://github.com/obra/superpowers), I moved [cloud-native-ref](https://github.com/Smana/cloud-native-ref) over to it entirely: the in-house SDD variant described below is now retired. The reasoning behind it — platform constitution, review personas, verification against a real cluster — still holds; what changed is the mechanism. I cover this in [part 2 of the series](/post/series/agentic_ai/ai-coding-tips/).
{{% /notice %}}
```

- [ ] **Step 4: Add the French in-section note**

In the FR post, inside the `{{% notice tip "Ma variante SDD pour le Platform Engineering" %}}`
block, insert immediately after the opening shortcode line and before
`Pour [cloud-native-ref](...)`:

```markdown
> **Mise à jour 2026-08-18** — ce workflow maison a été remplacé par [Superpowers](https://github.com/obra/superpowers). La section est conservée telle quelle : elle décrit ce qui a réellement tourné pendant plusieurs mois.

```

- [ ] **Step 5: Add the English in-section note**

Same position in the EN post, inside `{{% notice tip "My SDD variant for Platform Engineering" %}}`:

```markdown
> **Update 2026-08-18** — this in-house workflow has been replaced by [Superpowers](https://github.com/obra/superpowers). The section is kept as written: it describes what actually ran for several months.

```

- [ ] **Step 6: Fix the constitution link in both languages**

```bash
cd /home/smana/Sources/smana.github.io
sed -i 's|cloud-native-ref/blob/main/docs/specs/constitution\.md|cloud-native-ref/blob/main/docs/platform-constitution.md|g' \
  content/fr/post/series/agentic_ai/ai-coding-agent/index.md \
  content/en/post/series/agentic_ai/ai-coding-agent/index.md
grep -n 'platform-constitution' content/{fr,en}/post/series/agentic_ai/ai-coding-agent/index.md
```

Expected: one hit per file.

- [ ] **Step 7: Add Superpowers to both reference lists**

In the FR post, under `### Spec-Driven Development`, append after the BMAD line:

```markdown
- [Superpowers](https://github.com/obra/superpowers) — Le workflow que j'utilise aujourd'hui (plugin Claude Code)
```

In the EN post, same place:

```markdown
- [Superpowers](https://github.com/obra/superpowers) — The workflow I use today (Claude Code plugin)
```

- [ ] **Step 8: Verify both files changed symmetrically**

```bash
git diff --stat
for f in content/fr/post/series/agentic_ai/ai-coding-agent/index.md \
         content/en/post/series/agentic_ai/ai-coding-agent/index.md; do
  echo "$f: notices=$(grep -c '2026-08-18' "$f") \
        superpowers-links=$(grep -c 'github.com/obra/superpowers' "$f") \
        old-constitution=$(grep -c 'docs/specs/constitution' "$f")"
done
```

Expected: both files report `notices=2`, `superpowers-links=3`, `old-constitution=0`. The two
files must report identical numbers — if they diverge, one language is missing an edit.

- [ ] **Step 9: Commit**

```bash
git add content/fr/post/series/agentic_ai/ai-coding-agent/index.md content/en/post/series/agentic_ai/ai-coding-agent/index.md
git commit -m "post(agentic-ai): mark the in-house SDD workflow as retired in favour of Superpowers"
```

---

## Task 9: Blog — close the English translation gap

The English `ai-coding-tips` is missing the article's entire opening section, which is where the
Superpowers claim lives in French.

**Files:**
- Modify: `content/en/post/series/agentic_ai/ai-coding-tips/index.md` (insert section)
- Modify: `content/fr/post/series/agentic_ai/ai-coding-tips/index.md` (update two lines)

- [ ] **Step 1: Update the French SDD bullet**

In `content/fr/post/series/agentic_ai/ai-coding-tips/index.md`, replace:

```markdown
* **SDD** avec **superpowers** : j'ai testé plusieurs déclinaisons (github-specs, gsd) ; c'est aujourd'hui mon préféré pour sa simplicité d'usage, tout en garantissant un workflow complet qui respecte les bonnes pratiques
```

with:

```markdown
* **SDD** avec **superpowers** : j'ai testé plusieurs déclinaisons (github-specs, gsd) ; c'est celui que j'ai retenu, pour sa simplicité d'usage tout en garantissant un workflow complet qui respecte les bonnes pratiques — [cloud-native-ref](https://github.com/Smana/cloud-native-ref) a entièrement basculé dessus en août 2026
```

- [ ] **Step 2: Refresh the French "Article vivant" date**

In the same file, replace:

```markdown
**Dernière mise à jour : 9 mai 2026**
```

with:

```markdown
**Dernière mise à jour : 18 août 2026**
```

- [ ] **Step 3: Insert the translated section into the English post**

In `content/en/post/series/agentic_ai/ai-coding-tips/index.md`, between the `---` on line 27 and
`## :scroll: CLAUDE.md: persistent memory` on line 28, insert:

```markdown
## :wrench: How I currently use Claude Code

Let's be honest: once you're used to Claude Code, expectations run high. I won't go over the concepts again here (MCP, skills, subagents, hooks, SDD, automode) — they're covered in the [first article of the series](/post/series/agentic_ai/ai-coding-agent/). Instead, here's a **non-exhaustive overview** of what I use daily and the **value** I get out of it:

**The MCPs plugged into my session**

* **Tolaria**: direct access to my personal wiki — notes, ADRs, lessons learned, retrieved without leaving the terminal
* **Linear**: reading and creating tickets, linking a PR to an issue, without switching tabs
* **VictoriaMetrics / VictoriaLogs**: querying metrics and logs from the agent, handy for debugging or correlating a behaviour with a deployment
* **Flux**: checking a cluster's GitOps state (HelmReleases, Kustomizations) before acting
* **Context7**: pulling up-to-date docs for a library or an SDK, to avoid hallucinations on recent APIs

**Beyond MCPs**

* **Skills**: specialized capabilities loaded on demand (creating PRs, security audits, writing designs)
* **Subagents and hooks**: automatic triggers (desktop notification, pre-commit validation) and delegation to isolated contexts
* **SDD** with **superpowers**: I tried several flavours (github-specs, gsd); this is the one I settled on, for how simple it is to use while still guaranteeing a complete workflow that respects good practices — [cloud-native-ref](https://github.com/Smana/cloud-native-ref) moved over to it entirely in August 2026
* **Automode** on POCs, with a careful review of the first iteration before letting it run

This workflow plays to **Claude's specific strengths**: Opus reasoning on the critical passages, the 1M context window in beta, and very reliable _function-calling_.

{{% notice tip "Mise en abyme: this setup in action" %}}
The [self-hosted LLM stack](/post/series/agentic_ai/llm-self-hosted-stack/) (part 3 of the series) was **entirely designed and built with Claude Code** — Crossplane/KCL compositions, Helm manifests, ADRs, Grafana dashboards, and the writing of the article itself. It's a concrete example of everything described here: MCPs (Tolaria for design notes, Context7 for the vLLM/KEDA docs, Flux to verify deployments), worktrees to parallelize the platform and the article, an SDD plan to frame the scope, and `code-simplifier` at the end of the cycle. A small irony: using Claude Code to build an alternative to Claude Code.
{{% /notice %}}

---

```

- [ ] **Step 4: Verify the two posts now match structurally**

```bash
cd /home/smana/Sources/smana.github.io
diff <(grep -c '^## ' content/fr/post/series/agentic_ai/ai-coding-tips/index.md) \
     <(grep -c '^## ' content/en/post/series/agentic_ai/ai-coding-tips/index.md) \
  && echo "section counts match"
grep -n 'superpowers' content/en/post/series/agentic_ai/ai-coding-tips/index.md
```

Expected: `section counts match`, and one hit for `superpowers` in the English post.

- [ ] **Step 5: Commit**

```bash
git add content/fr/post/series/agentic_ai/ai-coding-tips/index.md content/en/post/series/agentic_ai/ai-coding-tips/index.md
git commit -m "post(agentic-ai): translate the missing usage section and record the Superpowers switch"
```

---

## Task 10: Blog — build, verify, and open the PR

- [ ] **Step 1: Build the site**

```bash
cd /home/smana/Sources/smana.github.io
hugo --gc --minify
```

Expected: exit 0, no `ERROR` lines. A failure here means a malformed shortcode — most likely an
unbalanced `{{% notice %}}` / `{{% /notice %}}` pair from Task 8.

- [ ] **Step 2: Confirm the notices rendered**

```bash
grep -rl 'Update 2026-08-18\|Mise à jour 2026-08-18' public/ | head
```

Expected: at least the two `ai-coding-agent` pages.

- [ ] **Step 3: Confirm the constitution link points at the new path**

```bash
grep -rho 'cloud-native-ref/blob/main/docs/[a-z-]*\.md' public/ | sort -u
```

Expected: `cloud-native-ref/blob/main/docs/platform-constitution.md`, and no
`docs/specs/constitution.md`.

- [ ] **Step 4: Confirm the cloud-native-ref PR has merged**

```bash
gh pr list --repo Smana/cloud-native-ref --state merged --limit 5 --json title,mergedAt
```

The migration PR must appear. If it has not merged yet, **stop here** — the blog links would 404
on publication.

- [ ] **Step 5: Push and open the PR**

```bash
git push -u origin docs/superpowers-switch
gh pr create --title "Record the switch from the in-house SDD workflow to Superpowers" --body "..."
```

Body in English: what changed in each article, why (the workflow it documents is retired), the
constitution link fix, and the closed translation gap.

---

## Review checklist

Run before declaring the whole migration complete:

- [ ] `./scripts/validate-manifests.sh` → exit 0, `Invalid: 0, Skipped: 0`
- [ ] Every `docs/specs/...` path referenced anywhere resolves to an existing file
- [ ] `git grep 'scripts/sdd\|validate-spec.sh\|spec-archive'` returns only archived content
- [ ] `docs/specs/` contains only `README.md` and `done/`
- [ ] `.claude/rules/` contains `superpowers.md`, `platform-constitution.md`, `process.md` — and no `spec-constitution.md`
- [ ] `.claude/skills/` contains `verify-spec`, `spec-research`, `commit`, `create-pr`, `improve-pr`, `crossplane-validator` — and nothing else
- [ ] `hugo --gc --minify` → exit 0 in the blog repo
- [ ] cloud-native-ref PR merged **before** the blog PR
