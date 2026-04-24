# Systematic Debugging

Auto-loaded when editing files under `infrastructure/**`, `security/**`, `observability/**`, `tooling/**`, `opentofu/**`, `clusters/**`, `flux/**`, or investigating cluster issues. Adapted from Obra's [superpowers](https://github.com/obra/superpowers) `systematic-debugging` skill.

## The iron law

**No fixes without root-cause investigation first.**

If you haven't completed Phase 1, you cannot propose fixes. Symptom fixes are failure — they mask the real problem and create new bugs.

## When to apply

Any technical issue — **especially when tempted to skip the process:**

- Failing / stuck `HelmRelease` / `Kustomization` / `GitRepository`
- Crossplane XR `Synced=False` or `Ready=False`
- Pod `CrashLoopBackOff`, `OOMKilled`, `ImagePullBackOff`
- Network timeouts (check `CiliumNetworkPolicy` + Hubble first)
- `tofu plan` unexpected drift
- CI failures (`kcl fmt`, kubeconform, trivy, validate-kcl-compositions)
- OpenBao auth / PKI / cert-manager issues
- "It worked yesterday"

**Especially do not skip when:**
- Under time pressure — guessing is slower than thinking
- "Just one quick fix" seems obvious
- You've already tried 1–2 fixes that didn't stick
- You don't fully understand the error yet

## Phase 1: Root-cause investigation

Complete this phase **before** any change.

1. **Read errors carefully.** Don't skim stack traces. Note exact error codes, Flux condition messages, controller log lines, Hubble verdicts, Crossplane Composition pipeline errors.

2. **Reproduce consistently.** Can you trigger it reliably? What are the exact steps? If not reproducible → gather more data, don't guess.

3. **Check recent changes.**
   - `git log --oneline -20` on the relevant path
   - `flux get kustomizations` → `lastHandledReconcileAt`
   - Renovate PRs merged recently (version bumps often cause drift)
   - Recent HelmRelease chart or values updates

4. **Gather evidence at each boundary** (this is a GitOps / multi-controller system):

   Flux → Crossplane → Provider → Cloud:
   ```bash
   # Layer 1: Flux sees the change
   flux get kustomizations --all-namespaces
   flux logs --level=error --since=1h

   # Layer 2: Manifests reach the cluster
   kubectl get <kind> <name> -n <ns> -o yaml

   # Layer 3: Crossplane Composition accepted and rendered
   kubectl describe <xr-kind> <xr-name>
   kubectl get composite -A | grep <xr-name>

   # Layer 4: Provider controller converging
   kubectl logs -n crossplane-system deploy/provider-<name>

   # Layer 5: Actual cloud state
   aws <service> describe-<resource> ...
   ```

   For pod networking — **always** inspect Hubble first:
   ```bash
   hubble observe --pod <ns>/<pod> --verdict DROPPED --last 200
   ```

   For logs at scale, use VictoriaLogs via the MCP (`mcp__victorialogs__query`) with structured field queries — don't grep kubectl output blindly.

5. **Trace data flow.** When an error is deep in a call stack or a controller reconcile loop:
   - Where does the bad value originate?
   - Which controller / function reads it next?
   - Keep tracing *upstream* until you find the source.
   - Fix at source, not at symptom.

## Phase 2: Pattern analysis

1. **Find a working example.** Similar composition in `infrastructure/base/crossplane/configuration/kcl/`? Working HelmRelease in a sibling cluster? A prior commit that worked?

2. **Read the reference completely.** If you're following a pattern (e.g., the `App` composition, an ADR), read every line — don't skim.

3. **List every difference.** Between broken and working, no detail is too small. Version skew, API version, a single missing label, an omitted `CiliumNetworkPolicy` egress rule.

4. **Understand dependencies.** What does this resource need? EKS Pod Identity? An OpenBao AppRole? A specific subnet tag? A Flux dependency in `spec.dependsOn`?

## Phase 3: Hypothesis and testing

Scientific method — not pattern-matching from vibes.

1. **Form *one* hypothesis.** Write it down: "I think X is the root cause because Y."
2. **Test minimally.** Smallest change that would confirm or deny the hypothesis. One variable at a time.
3. **Verify before continuing.**
   - Worked → Phase 4
   - Didn't work → **new** hypothesis, don't pile fixes
4. **When you don't know, say so.** Ask the human partner or research more. Don't pretend.

## Phase 4: Implementation

1. **Reproduce as a test** (when feasible):
   - KCL composition → add to `main_test.k`
   - Manifest shape → kubeconform + a render test
   - Controller behavior → a minimal reproducer manifest

2. **Single fix.** Address the root cause — no "while I'm here" refactoring, no bundled changes.

3. **Verify the fix** using the gate function in [`verification.md`](verification.md). Evidence inline in the commit / PR.

4. **If the fix doesn't work:**
   - Stop.
   - Count prior fix attempts.
   - **< 3 attempts** → back to Phase 1 with new evidence.
   - **≥ 3 attempts** → stop and question the architecture. Three failed fixes usually means the pattern is wrong, not that fix #4 is the answer. Raise this with the human partner.

## Red flags — stop and follow the process

- "Quick fix for now, investigate later"
- "Just try changing X and see if it works"
- "Here are the main problems: [list of fixes]" (without evidence)
- "I'll add multiple changes and run tests"
- "Pattern says X but I'll adapt differently"
- "One more fix attempt" after 2+ failures
- Proposing solutions before running diagnostic commands

**All of these = return to Phase 1.**

## Signals you're doing it wrong

From the human partner — take any of these as a hard stop:
- "Is that even happening?" — you assumed without verifying
- "Stop guessing" — you're proposing fixes without understanding
- "Ultrathink this" — question fundamentals, not symptoms
- "We're stuck?" (frustrated) — your approach isn't working

## Rationalization table

| Excuse | Reality |
|--------|---------|
| "Issue is simple, skip the process" | Simple bugs have root causes too; process is fast for simple bugs |
| "Emergency, no time" | Systematic is *faster* than guess-and-check thrashing |
| "Try this first, then investigate" | First fix sets the pattern — do it right from the start |
| "I'll write the test after it works" | Untested fixes regress; test first proves the fix |
| "Multiple fixes save time" | Can't isolate what worked; often causes new bugs |
| "I see the problem, let me fix it" | Seeing symptoms ≠ understanding root cause |
| "One more attempt" (after 2+) | 3+ failures = architectural problem; question the pattern |

## Quick reference

| Phase | Activities | Success criteria |
|-------|-----------|-------------------|
| 1. Root cause | Read errors, reproduce, check recent changes, gather cross-layer evidence | Understand *what* and *why* |
| 2. Pattern | Find a working example, list every difference | Differences identified |
| 3. Hypothesis | One theory, minimal test | Confirmed or new hypothesis |
| 4. Fix | Single change, verify with evidence | Bug resolved + evidence inline |

## Related

- Verification discipline: [`verification.md`](verification.md)
- Observability MCPs: `flux-operator-mcp`, `victorialogs`, `victoriametrics`
- FluxCD plugin skills: `/gitops-cluster-debug`, `/gitops-knowledge`, `/gitops-repo-audit`
