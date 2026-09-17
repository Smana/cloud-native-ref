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

# Verify Spec Skill

Close the acceptance loop. Merged work is not "done" until the design's success criteria are observably met in the target cluster.

## Workflow

### 1. Locate inputs

Resolve `$ARGUMENTS` to a design document under `docs/superpowers/specs/`. Accept a bare topic
slug and glob for it. Abort with guidance if not found.

Read:
- the design doc — its goals, its **Testing** table, and any explicit success criteria
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
| "eviction deterministic" | deploy, fill, observe eviction counter |
| "resource X created" | `kubectl get X -l <label>` |
| a literal shell command in the Testing table | run it verbatim; compare to the stated expected output |

If the method is unclear, list the criterion as `MANUAL` and ask the user how they want to verify.

### 3. Deploy the example (idempotent)

Prefer `kubectl apply -k <dir>/examples/` or `kubectl apply -f <dir>/examples/<name>.yaml`. If the resource is a Flux `HelmRelease` / `Kustomization`, just wait for reconciliation — Flux owns deployment.

Do **not** deploy to production namespaces without explicit user approval. Confirm target cluster context before each apply.

### 4. Watch reconciliation (Flux MCP)

For Crossplane/Flux-managed specs, use the Flux MCP tools:

```
mcp__flux-operator-mcp__get_kubernetes_resources (kind: Kustomization/HelmRelease)
mcp__flux-operator-mcp__reconcile_flux_kustomization (if stalled)
mcp__flux-operator-mcp__get_flux_instance
```

Report any resource whose `Ready=False` condition persists past the timeout named in the spec (default 5 min).

### 5. Query observability (VictoriaMetrics / VictoriaLogs MCP)

For metrics-based SCs: `mcp__victoriametrics__query` / `query_range` with the metric name extracted from the SC text. For log-based SCs: `mcp__victorialogs__query` with a LogsQL stream filter (respect the project's dot-notation convention: `kubernetes.container_name`, `log.level`, etc.).

### 6. Write the verification report

Emit to `docs/superpowers/specs/<YYYY-MM-DD>-<topic>-verification.md`, using the same date and
topic as the design it verifies:

```markdown
# Verification: <spec title>

**Design**: <design-doc filename>
**Cluster**: <context>  (`kubectl config current-context`)
**Verified**: <YYYY-MM-DD HH:MM TZ>
**Verifier**: Claude (verify-spec)

---

## Success criteria results

| ID  | Criterion (1 line)                      | Method              | Verdict | Evidence |
|-----|------------------------------------------|---------------------|---------|----------|
| C-1 | Pods call AWS APIs without credentials  | kubectl exec probe  | ✅ PASS | `aws-cli output snippet` |
| C-2 | Evictions deterministic                  | VictoriaMetrics q   | ❌ FAIL | metric `cache_evictions_total` absent |
| C-3 | IAM roles cleaned up on delete           | kubectl delete + re-query | ✅ PASS | no dangling roles |
| C-4 | Reconcile < 2 min                        | flux get            | ✅ PASS | 42s |

## Issues found

### C-2 FAIL — eviction metric absent

<diagnosis, root cause hypothesis, suggested fix>

## Deployment artifacts

- Namespace: `<ns>`
- Flux Kustomizations: `<names>` — all Ready=True
- Helm releases: `<names>`
- Crossplane XRs: `<names>` — Synced=True, Ready=True

## References

- Design: `docs/superpowers/specs/<name>-design.md`
- Plan: `docs/superpowers/plans/<name>-plan.md` (if present)
- Example applied: `<path>`
```

### 7. Summarize

Return to the main context:

- Total criteria: N
- Passed: N
- Failed: N
- Manual: N
- Link to the verification report

If any criterion failed, suggest opening a follow-up issue and reference the verification report.

## Safety rules

- Never touch production namespaces without explicit user confirmation.
- Never delete resources to "re-test" without the user's go-ahead.
- If the cluster context is not what the user expects, stop and confirm before any apply.

## Related skills

- `superpowers:brainstorming` — produced the design this verifies
- `superpowers:verification-before-completion` — the generic evidence discipline
- `/gitops-cluster-debug` (fluxcd plugin) — deep Flux troubleshooting
