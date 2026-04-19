---
name: verify-spec
description: Verify that a merged spec's success criteria (SC-XXX) are actually met in the live cluster. Deploys the example manifest, watches Flux reconciliation, queries VictoriaMetrics/VictoriaLogs for evidence, writes docs/specs/<dir>/VERIFICATION.md.
when_to_use: |
  When the user says "verify the spec", "did SC-XXX actually ship",
  "check this spec works", "post-merge verification", "UAT this feature",
  "prove the success criteria", or after a spec PR has merged and the
  user wants to close the loop on whether the delivered feature satisfies
  the spec's acceptance criteria.
disable-model-invocation: true
argument-hint: "<spec-dir> — path to the (archived or active) spec directory"
paths: "docs/specs/**"
allowed-tools: Read, Write, Bash(kubectl:*), Bash(flux:*), Grep, Glob
---

# Verify Spec Skill

Close the acceptance loop. A merged spec is not "done" until its `SC-XXX` criteria are observably met in the target cluster.

## Workflow

### 1. Locate inputs

Resolve `$ARGUMENTS` to a spec directory. Accept either active (`docs/specs/NNN-slug/`) or archived (`docs/specs/done/NNN-slug/` or `docs/specs/done/YYYY-Qn/NNN-slug/`). Abort with guidance if not found.

Read:
- `<dir>/spec.md` — extract `SC-XXX` list.
- `<dir>/plan.md` (if exists) — extract example manifest paths and Tasks section.
- `<dir>/examples/` (if exists).

### 2. Enumerate success criteria

Parse every `**SC-XXX**: <text>` line. For each, infer a verification method:

| Criterion pattern | Verification method |
|---|---|
| "pods can call AWS APIs …" | `kubectl run` a test pod; try the API; check result |
| "reconciliation succeeds within Xs" | `flux get` + time window check |
| "metrics emit" | VictoriaMetrics query for the metric name |
| "logs appear" | VictoriaLogs query for the log stream |
| "latency p95 < Y" | VictoriaMetrics `histogram_quantile(0.95, ...)` |
| "eviction deterministic" | deploy, fill, observe eviction counter |
| "resource X created" | `kubectl get X -l <label>` |

If the method is unclear, list the SC as `MANUAL` and ask the user how they want to verify.

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

### 6. Write `VERIFICATION.md`

Emit to `<spec-dir>/VERIFICATION.md`:

```markdown
# Verification: <spec title>

**Spec**: <slug>
**Cluster**: <context>  (`kubectl config current-context`)
**Verified**: <YYYY-MM-DD HH:MM TZ>
**Verifier**: Claude (verify-spec)

---

## Success criteria results

| ID     | Criterion (1 line)                      | Method              | Verdict | Evidence |
|--------|------------------------------------------|---------------------|---------|----------|
| SC-001 | Pods call AWS APIs without credentials  | kubectl exec probe  | ✅ PASS | `aws-cli output snippet` |
| SC-002 | Evictions deterministic                  | VictoriaMetrics q   | ❌ FAIL | metric `cache_evictions_total` absent |
| SC-003 | IAM roles cleaned up on delete           | kubectl delete + re-query | ✅ PASS | no dangling roles |
| SC-004 | Reconcile < 2 min                        | flux get            | ✅ PASS | 42s |

## Issues found

### SC-002 FAIL — eviction metric absent

<diagnosis, root cause hypothesis, suggested fix>

## Deployment artifacts

- Namespace: `<ns>`
- Flux Kustomizations: `<names>` — all Ready=True
- Helm releases: `<names>`
- Crossplane XRs: `<names>` — Synced=True, Ready=True

## References

- Spec: `<spec-dir>/spec.md`
- Plan: `<spec-dir>/plan.md` (if present)
- Example applied: `<path>`
```

### 7. Summarize

Return to the main context:

- Total SCs: N
- Passed: N
- Failed: N
- Manual: N
- Link to `VERIFICATION.md`

If any SC failed, suggest opening a follow-up issue tagged `spec:regression` and reference this VERIFICATION.md.

## Safety rules

- Never touch production namespaces without explicit user confirmation.
- Never delete resources to "re-test" without the user's go-ahead.
- If the cluster context is not what the user expects, stop and confirm before any apply.

## Related skills

- `/spec` — the upstream spec this verifies
- `/validate` — spec completeness (different concern)
- `/gitops-cluster-debug` (fluxcd plugin) — deep Flux troubleshooting
