# Skills

Repeatable procedures for this repo, in the [Agent Skills](https://agentskills.io) open-standard
layout: one directory per skill, each with a `SKILL.md`.

## Why this path

`.agents/skills/` is the location Codex, Cursor, Gemini CLI and Antigravity read directly. Claude
Code reads only `.claude/skills/`, which is a **symlink to this directory** — so one copy of each
skill serves every agent.

The same split applies to instructions: `AGENTS.md` is canonical at the repo root and in each
directory that carries its own rules, with a `CLAUDE.md` symlink beside it. Claude Code loads a
nested `CLAUDE.md` lazily, when it reads a file in that directory, which is the behaviour the
retired `.claude/rules/` directory was meant to provide and did not.

## The skills

| Skill | Use |
|---|---|
| **ship-it** | The full pre-merge pipeline: rebase → simplify → prune prose → validate → review → commit → PR |
| **sync-branch** | Rebase the current branch onto the latest `origin/main`, fetch first |
| **commit** | Pre-commit validation, then a conventional commit |
| **create-pr** | Open or update a PR with a mermaid diagram, file walkthrough and the design link |
| **spec-research** | Forked Explore subagent: ecosystem scan → research doc, without burning main context |
| **verify-spec** | Post-merge: prove a design's success criteria against the live cluster |

`ship-it` is the entry point for finished work — it calls the others in the order that makes each
one worth running. The rest are usable on their own.

Non-trivial changes go through the [Superpowers](https://github.com/obra/superpowers) plugin first
(brainstorm → plan → execute); its skills auto-trigger. Flux troubleshooting comes from the
`fluxcd/agent-skills` plugin: `/gitops-knowledge`, `/gitops-repo-audit`, `/gitops-cluster-debug`.

## Writing one

Keep `SKILL.md` under 500 lines and push detail into `references/` — agents load the body only on
activation and the references only when a step calls for them.

The `description` is what an agent matches against to decide whether to load the skill, so it must
say **what the skill does and when to use it**, with the words someone would actually type. Only
`name` and `description` are required; `name` must match the directory.

Claude-specific frontmatter (`disable-model-invocation`, `context: fork`, `argument-hint`) stays
portable — other agents ignore fields they do not recognise.

```bash
skills-ref validate .agents/skills/<name>   # checks frontmatter and naming
```

## Prerequisites

Git and `gh` authenticated. Flux work needs the `fluxcd/agent-skills` plugin; `verify-spec` needs
cluster access plus the VictoriaMetrics/VictoriaLogs MCPs.
