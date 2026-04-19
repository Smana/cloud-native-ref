---
name: spec-research
description: Research patterns, ecosystem tools, and best practices before filling a spec. Runs in a forked Explore subagent so it can query Context7, WebSearch, and the whole codebase without consuming the main context window. Writes docs/specs/NNN-slug/research.md.
when_to_use: |
  When the user says "research before speccing", "what does the ecosystem say",
  "look at how others do this", "find existing patterns for X", "scan Context7",
  or when a spec covers a topic the platform hasn't built before (new operator,
  new managed service, new KCL pattern).
disable-model-invocation: true
argument-hint: '<spec-slug> "<research question>" — e.g. /spec-research 003-valkey "Valkey caching composition best practices"'
context: fork
agent: Explore
allowed-tools: Read, Grep, Glob, Bash(git:*), WebSearch, WebFetch
---

# Spec Research Skill (subagent)

Runs in an isolated Explore-agent context. Reads-only across the repo + external sources; writes exactly one file: `docs/specs/<spec-slug>/research.md`.

## Your mission

Research `$ARGUMENTS` for the SDD spec at `docs/specs/<spec-slug>/`. Produce a concise, reusable research artifact that the next steps (spec filling, design review, /clarify) can build on.

## Research protocol

### 1. Frame the question

Parse `$ARGUMENTS` for the spec slug (first token) and the research question (remainder). If the spec directory does not exist yet, proceed anyway and write research to `docs/specs/<slug>/research.md` for the spec author to consume.

### 2. Map the local landscape first

Before going external, exhaust the repo:

- **Existing compositions** in `infrastructure/base/crossplane/configuration/kcl/` — grep for analogous patterns (e.g., if researching cache, look at `app/`, `sqlinstance/`).
- **Constitution** (`docs/specs/constitution.md`) — which rules apply to this topic?
- **ADRs** (`docs/decisions/`) — any prior decision constrains this?
- **Similar archived specs** (`docs/specs/done/`) — reuse patterns rather than reinvent.
- **Runtime examples**: `infrastructure/mycluster-0/`, `security/mycluster-0/`, etc.

### 3. External sources (in priority order)

1. **Context7** via `mcp__context7__resolve-library-id` then `mcp__context7__query-docs` — up-to-date docs for any named library or operator.
2. **Official operator/vendor docs** via WebFetch.
3. **GitHub Spec Kit / GSD patterns** when the research is meta (about the workflow, not the tech).
4. **WebSearch** only if the above three yielded nothing — lowest signal, easiest to misquote.

### 4. Write `research.md`

Emit exactly this structure at `docs/specs/<spec-slug>/research.md`:

```markdown
# Research: <one-line question>

**Spec**: <spec-slug>
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

<Items to turn into [NEEDS CLARIFICATION: ...] markers in spec.md>

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
- **No decisions, only options.** The spec + `/clarify` are where decisions happen.
- Keep under 400 lines; split into `research-<topic>.md` files if the topic genuinely spans multiple subdomains.

### 6. Return to caller

Return a 5-line summary (TL;DR bullets) back to the main context. Full detail lives in the written file.
