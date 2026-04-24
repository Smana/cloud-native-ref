# Verification Before Completion

Auto-loaded when editing files under `docs/specs/**`, `infrastructure/**`, `security/**`, `observability/**`, `tooling/**`, or `opentofu/**`. Adapted from Obra's [superpowers](https://github.com/obra/superpowers) `verification-before-completion` skill.

## The iron law

**No completion claims without fresh verification evidence in this message.**

If you haven't run the verification command *in this response*, you cannot claim the thing is done, passing, valid, or fixed. Previous runs don't count — state may have changed.

## The gate function

Before claiming *any* status ("done", "fixed", "passes", "valid", "ready", "shipped"):

1. **IDENTIFY** — what command proves the claim?
2. **RUN** — execute the full command (fresh, complete, no skipping)
3. **READ** — full output, check exit code, count failures
4. **VERIFY** — does output confirm the claim?
   - No → state actual status with evidence
   - Yes → state claim *with* the evidence inline
5. **ONLY THEN** — make the claim

Skipping any step = lying, not verifying.

## Verification command table (this repo)

| Claim | Required evidence | Not sufficient |
|-------|-------------------|----------------|
| KCL composition valid | `./scripts/validate-kcl-compositions.sh` → exit 0 | `kcl fmt` alone (formatter ≠ validator) |
| KCL formatted | `kcl fmt` exits clean, `git diff` is empty | "I ran kcl fmt earlier" |
| Manifest valid | `kubeconform -summary -output json <file>` → 0 invalid | Eyeballed YAML |
| Trivy clean | `trivy config --exit-code=1 --ignorefile=./.trivyignore.yaml .` → exit 0 | Only reviewing a subset |
| OpenTofu plan clean | `tofu plan -var-file=variables.tfvars` → no unexpected changes | `tofu validate` alone |
| Spec ready | `./scripts/validate-spec.sh <spec-dir>` → 0 errors | "FR/SC look complete" |
| SC-XXX met (post-merge) | `/verify-spec <spec-dir>` against live cluster | Plan tasks checked off |
| Flux reconciled | `flux get kustomizations` + `flux get helmreleases` — all Ready=True | "Should reconcile" |
| Crossplane XR ready | `kubectl get <xr> -o yaml` shows `Ready=True` and `Synced=True` | Managed resources exist |
| Network policy works | `hubble observe --verdict DROPPED` during a real request | Policy applied cleanly |
| Composition renders | `crossplane render <xr.yaml> <comp.yaml> <func.yaml>` → no errors | `kcl run` alone |
| Regression test works | Red → revert fix → confirm red → restore fix → confirm green | Test passes once |

## Configuration-change verification

Operation success ≠ intended change. Verify the *observable difference*.

| Change | Insufficient | Required |
|--------|-------------|----------|
| Flip a HelmRelease value | Reconciled=True | Rendered manifest shows new value |
| Swap Crossplane provider version | `crossplane trace` green | Managed resource's API version reflects new provider |
| Enable a feature flag | No errors in logs | Behavior observable: VictoriaLogs query, a request, a Hubble flow |
| Change network policy | Policy applied | Hubble flow shows ALLOWED/DROPPED as intended |
| Set secret | ExternalSecret `SecretSynced=True` | Pod env/mount contains the expected value |

## Red flags — stop and verify

- "Should work now" / "probably" / "seems to"
- "Great!", "Perfect!", "Done!" without an evidence line
- About to commit / push / `/create-pr` without having re-run validators
- Trusting a subagent's success report — check `git diff` yourself
- Partial check ("linter passed, so build passes")
- "Just this once" exceptions
- Different wording to dodge the rule — spirit over letter

## Rationalization table

| Excuse | Reality |
|--------|---------|
| "I'm confident" | Confidence ≠ evidence |
| "Agent said success" | Verify independently (`git diff`, re-run the check) |
| "Partial is enough" | Partial proves nothing |
| "Too slow to re-run" | Slower than shipping wrong |
| "It hasn't changed" | Prove it — `git status` or re-run |
| "Linter passed" | Linter ≠ validator ≠ compiler ≠ cluster reality |

## Evidence in communication

When stating a claim, include the evidence inline:

- ✅ `validate-spec.sh: 0 errors, 0 warnings — spec ready for implementation`
- ✅ `kubeconform on all 14 manifests: 14 valid, 0 invalid`
- ✅ `HelmRelease harbor Ready=True, revision v1.15.2 (observed)`
- ❌ `validation passes` (no output, no numbers, no proof)

## When to apply

Always, before:
- Saying work is done, fixed, complete, shipped, verified
- `/commit`, `/create-pr`, or pushing a branch
- Marking a T001-style task `[x]` in `plan.md`
- Closing a GitHub issue
- Telling the human partner "you can merge"

## Related

- `/validate` — spec validator gate (`scripts/validate-spec.sh`)
- `/commit` — runs pre-commit + conventional commit
- `/verify-spec <spec-dir>` — post-merge live-cluster SC verification
- Debugging discipline: [`debugging.md`](debugging.md)
