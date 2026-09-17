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

# Spec Research Skill (subagent)

Runs in an isolated Explore-agent context. Read-only across the repo + external sources; writes exactly one file: `docs/superpowers/specs/<YYYY-MM-DD>-<slug>-research.md`.

## Your mission

Research `$ARGUMENTS` to feed a Superpowers design (`superpowers:brainstorming`). Produce a concise, reusable research artifact the design author can build on.

## Research protocol

### 1. Frame the question

Parse `$ARGUMENTS` for the topic slug (first token) and the research question (remainder). The design doc need not exist yet — write the research file so the design author can consume it.

### 2. Map the local landscape first

Before going external, exhaust the repo:

- **Existing compositions** in the sibling [`Smana/crossplane-configuration`](https://github.com/Smana/crossplane-configuration) repo, under `apis/<api>/kcl/` — grep for analogous patterns (e.g., if researching cache, look at `app/`, `sqlinstance/`).
- **Constitution** (`docs/platform-constitution.md`) — which rules apply to this topic?
- **ADRs** (`docs/decisions/`) — any prior decision constrains this?
- **Prior designs** (`docs/superpowers/specs/`) and **archived specs** (`docs/specs/done/`) — reuse patterns rather than reinvent.
- **Runtime examples**: `infrastructure/aws-0/`, `security/aws-0/`, etc.

### 3. External sources (in priority order)

1. **Context7** via `mcp__context7__resolve-library-id` then `mcp__context7__query-docs` — up-to-date docs for any named library or operator.
2. **Official operator/vendor docs** via WebFetch.
3. **Superpowers skills** (the installed plugin's `skills/` directory) when the research is meta — about the workflow, not the tech.
4. **WebSearch** only if the above three yielded nothing — lowest signal, easiest to misquote.

### 4. Write `research.md`

Emit exactly this structure at `docs/superpowers/specs/<YYYY-MM-DD>-<slug>-research.md`:

```markdown
# Research: <one-line question>

**Topic**: <slug>
**Conducted**: <YYYY-MM-DD>
**Researcher**: Claude (spec-research subagent)

---

## TL;DR

<3–5 bullet points: the decisions the researcher would recommend and why>

## Standard stack

<Operators, libraries, images we should use. Pin to specific versions when docs list an LTS.>

| Component | Pick | Version | Source |
|-----------|------|---------|--------|

## Local patterns worth reusing

<File paths + 1-line note on what each shows. Copy existing patterns over invention.>

- `<path>`: <why it matters>

## Don't hand-roll

<Things the ecosystem already solves. Saves the spec author from designing these.>

## Common pitfalls

<Sharp edges from ecosystem docs / community. Especially: KCL mutation (#285),
Cilium bug #43493 for prefix delegation, anything that broke in this repo before.>

## Open questions surfaced

<Items to raise as open questions during brainstorming>

- [ ] <question>
- [ ] <question>

## References

- Context7: `<library-id>` <brief excerpt>
- <Vendor doc URL>
- Local files: `<path>`, `<path>`
```

### 5. Constraints on this artifact

- **Factual, not opinionated beyond the TL;DR.** Cite sources for every non-obvious claim.
- **Resist scope creep** — this is not a design document; it is inputs for one.
- **No decisions, only options.** Brainstorming is where decisions happen.
- Keep under 400 lines; split into `research-<topic>.md` files if the topic genuinely spans multiple subdomains.

### 6. Return to caller

Return a 5-line summary (TL;DR bullets) back to the main context. Full detail lives in the written file.
