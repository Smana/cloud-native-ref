---
name: debug-spec
description: Start or resume a persistent debug session for a deployed spec. Writes docs/specs/<dir>/debug/<slug>.md with symptom / hypotheses / evidence / eliminated paths so multi-session troubleshooting survives context resets.
when_to_use: |
  When the user says "debug this spec", "help me troubleshoot", "capture the investigation",
  "ongoing bug in composition X", "save debug state", "resume debugging",
  "the spec is broken", or when a previously-deployed spec shows issues that
  need structured investigation across sessions.
disable-model-invocation: true
argument-hint: "<spec-dir> <short-symptom-slug> — e.g. /debug-spec docs/specs/done/2026-Q2/005-queueinstance sqs-reconcile-loop"
paths: "docs/specs/**"
allowed-tools: Read, Write, Edit, Bash(kubectl:*), Bash(flux:*), Grep, Glob
---

# Debug Spec Skill

Persistent, scientific-method debug sessions attached to a spec. Inspired by `/gsd-debug` but stays inside `docs/specs/` so debug state lives next to the feature it covers.

## Workflow

### 1. Parse arguments

Expect `<spec-dir> <symptom-slug>`. Normalize slug (kebab-case, 3–5 words). The target file is `<spec-dir>/debug/<symptom-slug>.md`. If neither argument is given, list existing debug sessions:

```bash
find docs/specs -path '*/debug/*.md' -type f 2>/dev/null
```

### 2. Resume if session exists

If the file already exists, treat as a resume. Read existing content, summarize state back to the user, and ask what's new (new evidence? new hypothesis? eliminated one?). Update in place; never truncate prior hypotheses.

### 3. Create new session (if needed)

Emit the scaffold:

```markdown
---
status: investigating | fixing | blocked | resolved
started: YYYY-MM-DD HH:MM TZ
spec: <spec-dir>
symptom_slug: <slug>
---

# Debug: <one-line symptom>

## Symptom

<Exactly what the user observes. Reproduce steps. Logs. Screenshots.>

## Impact

<Who is affected, how severely, from when>

## Current focus

**Working hypothesis**: <text>
**Next action**: <concrete experiment or query>

## Hypotheses tracked

### H1 — <short name>  [status: testing | confirmed | eliminated]

**Claim**: <if this is true, symptom should look like X>
**Test**: <command / query / observation>
**Result**: <outcome + date>

### H2 — ...

## Evidence

### 2026-04-18 — <source>
<raw log / metric / kubectl output — keep concise, link to dashboard if long>

## Eliminated paths

- <hypothesis>: why not (with evidence line reference)

## Environment

- Cluster: <context>
- Namespace(s): <list>
- Flux kustomizations: <list with Ready state>
- Related Crossplane XRs: <list with Synced/Ready>

## Next steps

- [ ] <action>
- [ ] <action>

## Resolution (filled when status=resolved)

**Root cause**: <text>
**Fix**: <PR link or commit>
**Prevention**: <ADR / constitution rule / test added>
```

### 4. Capture evidence methodically

Use the MCPs where possible (less copy-paste noise):

- Flux: `mcp__flux-operator-mcp__get_kubernetes_resources`, `get_kubernetes_logs`, `reconcile_flux_*`
- Metrics: `mcp__victoriametrics__query` / `query_range`
- Logs: `mcp__victorialogs__query`

Paste only the relevant fields; dump full JSON only into an `Evidence` subsection if genuinely needed.

### 5. Update on every new datapoint

Every new observation is appended (never overwrite). If an observation disproves a hypothesis, move it to "Eliminated paths" with a reference to the evidence line that killed it.

### 6. Close out

When the root cause is known and a fix lands:

- Set `status: resolved` in frontmatter.
- Fill the `Resolution` section.
- If the root cause points to a missing constitution rule, an ADR, or a test gap, create a follow-up todo (`/gsd-add-todo`) or file an issue.
- Do **not** delete the session file — future readers hunting "how did we solve X last time?" will find it.

## Anti-patterns

- Don't fabricate evidence. If a test wasn't run, mark the hypothesis `testing`, not `confirmed`.
- Don't overwrite earlier hypotheses — science requires the eliminated paths to be visible.
- Don't stash secrets or cluster-admin tokens into the file. Link to the dashboard / portal instead.
- Don't mutate the spec (`spec.md`) to record bugs. Bugs live in `debug/`, not the contract.

## Related skills

- `/verify-spec` — if the bug was found during post-merge verification, reference the VERIFICATION.md here
- `/gitops-cluster-debug` (fluxcd plugin) — deeper Flux inspection
- `/gsd-debug` — more elaborate multi-session debug framework (if you ever need waveform tracking / checkpoints)
