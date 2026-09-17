---
title: Agent instructions and skills are authored once in the open formats, with the Claude-specific paths as symlinks
linkTitle: 0038 · Portable agent configuration
weight: 380
description: Instructions live in AGENTS.md — root and nested per directory — and skills in .agents/skills/, the two open formats every major coding agent reads. CLAUDE.md and .claude/skills become symlinks, because Claude Code reads only its own paths. Maintaining a parallel file per tool is rejected as unmaintainable; staying Claude-only is rejected because it locks the repo to one vendor. The move also fixed 701 lines of rules that were silently loading into every session.
lastVerified: 2026-09-17
---

**Status**: Accepted
**Date**: 2026-09-17
**Deciders**: Smana (Platform Owner)

---

## Context

The repository's agent configuration was entirely Claude Code-shaped: a 474-line `CLAUDE.md`, nine
topic files in a `rules/` directory under `.claude/`, and six skills under `.claude/skills/`. None of those paths is
read by any other coding agent, so evaluating one meant re-authoring the configuration or working
without it.

While auditing that configuration a second problem surfaced, which changed the urgency. Seven of
the nine rules files carried `globs:` frontmatter — the field **Cursor** uses to scope its `.mdc`
rules. Claude Code scopes on `paths:`, and its documented behaviour is that a rule *without* that
field loads unconditionally. The remaining two had no frontmatter at all and asserted their scoping
only in prose. All nine therefore loaded every session.

The measured consequence:

| | Lines | Loaded |
|---|---|---|
| `CLAUDE.md` | 474 | every session |
| the nine `rules/*.md` files under `.claude/` | 701 | every session — intended to be scoped, and were not |
| **Total** | **1,175** | |

Anthropic's own guidance is 200 lines per instruction file, "beyond which adherence drops". The
files meant to carry the repository's hard-won rules were diluting each other, and nothing warned:
the frontmatter looks correct, and a scoped-looking rule that silently always loads produces no
error. This is the most likely explanation for instructions that had to be repeated across
sessions despite being written down.

## Decision

Author each layer once, in the open format, and symlink the Claude-specific path to it.

| Layer | Canonical | Read natively by | Claude Code bridge |
|---|---|---|---|
| Repo-wide instructions | `AGENTS.md` | Codex, Cursor, Gemini CLI, Antigravity, Copilot, Zed, Aider, Jules | `CLAUDE.md` symlink |
| Scoped instructions | nested `AGENTS.md` per directory | same — agents read the nearest file in the tree | `CLAUDE.md` symlink beside each |
| Procedures | `.agents/skills/<name>/SKILL.md` | Codex, Cursor, Gemini CLI, Antigravity, OpenCode, 40+ tools | `.claude/skills` → `../.agents/skills` |

The nested-directory form is what replaces the `rules/` directory under `.claude/`, and it is a strict improvement rather
than a compromise: **Claude Code loads a nested `CLAUDE.md` lazily, when it reads a file in that
directory.** That is precisely the scoping the `globs:` field was reaching for, it is the
`AGENTS.md` specification's own monorepo pattern, and it works in every agent instead of one.

Always-on context falls from 1,175 lines to 135, a 88% reduction — 791 lines moved into nine
directory-scoped files that load only when work touches them. The redistribution is larger than
what was deleted because several traps that lived only in the root file, and several that were
carried in prose, were written out properly where they now apply.

## Alternatives rejected

**Keep `.claude/` and fix `globs:` → `paths:`.** This repairs the context bloat, which was the
larger of the two problems, and is a one-word change in seven files. It was rejected because it
leaves every instruction unreadable by any other agent, and the repository is a public reference
whose readers do not all use Claude Code.

**Maintain parallel files per tool.** `AGENTS.md` *and* `CLAUDE.md` *and* `.cursor/rules/`, kept in
sync. Rejected outright: two copies of a rule is how one of them goes stale, and this repository
has already been bitten by exactly that failure mode in its safety-gate documentation. The symlink
gives byte-identical content by construction.

**`AGENTS.md` imported from `CLAUDE.md` via `@AGENTS.md`** rather than symlinked. This is
Anthropic's documented option and it permits appending Claude-only content below the import. It was
rejected for the root file because there is no Claude-only content to add, and an import is a
second file to keep correct. It remains the right answer on Windows, where symlinks need
Administrator privileges or Developer Mode.

**A `rules/` directory under `.claude/`, symlinked to a shared location.** Supported, but it keeps the Claude-only
path as the source of truth and inverts the dependency this decision is trying to establish.

## Consequences

Claude-specific frontmatter — `disable-model-invocation`, `context: fork`, `argument-hint` — stays
in the skills and stays portable: agents ignore fields they do not recognise. The reverse is also
true, so a Codex-only `agents/openai.yaml` could be added later without disturbing anything.

Two properties are now load-bearing and worth knowing before editing:

- **A rule belongs in the directory it governs.** Adding it to the root file re-creates the
  always-on problem this decision removed. A genuinely cross-cutting rule is either a pointer to
  the page that owns it, or it belongs in a skill that loads on invocation.
- **Symlinks must survive.** `pre-commit`'s `check for broken symlinks` hook covers this, and a
  checkout on a filesystem without symlink support would get a text file containing the target
  path. Windows contributors should use the `@AGENTS.md` import form instead.

Verified on the implementing branch: headless runs confirm the symlinked skills directory resolves,
and that a nested `AGENTS.md` loads on reading a file in its directory — the test asserted a fact
present only in `opentofu/AGENTS.md`. `validate-links.sh`, `validate-doc-claims.sh` and
`validate-manifests.sh` all exit 0.
