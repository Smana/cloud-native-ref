# Evidence gate

No "done / fixed / passing / ready" claim without a fresh command run **in the same response**.
Previous runs do not count — file and cluster state drift between them.

For each claim the branch makes: identify the command, run it now, cite the output inline as
numbers or an exit code. Not as prose.

| Claim | Evidence |
|---|---|
| Manifests valid | `./scripts/ci/validate-manifests.sh` → exit 0, report shows `Invalid: 0, Skipped: 0` |
| Alerting rules parse | `./scripts/ci/validate-vmrules.sh` → exit 0, skipped groups named |
| Docs links resolve | `./scripts/ci/validate-links.sh` → exit 0 (after **any** file move — a path grep cannot see relative-link rot) |
| Docs still true | `./scripts/ci/validate-doc-claims.sh` → exit 0 (after **any** config change a page describes) |
| Docs name real paths | `./scripts/ci/verify-doc-paths.sh` → exit 0 (after **any** move or rename — a backticked path in website prose, or an absolute GitHub link, is a claim the link checker cannot see) |
| IdP topology intact | `./scripts/ci/validate-idp-topology.sh` → exit 0 |
| OpenTofu valid | `tofu validate` → exit 0, and `trivy config --exit-code=1 --ignorefile=./.trivyignore.yaml .` |
| KCL composition valid | `task check` in `Smana/crossplane-configuration` → exit 0 (compositions are not in this repo) |
| Flux reconciled | `flux get kustomizations` / `helmreleases` → `Ready=True` |
| Crossplane XR ready | `kubectl get <xr>` → `Synced=True` and `Ready=True` |
| Policy change works | `hubble observe --verdict DROPPED` matches intent |
| Config change took effect | an observable difference — rendered manifest, log line, API response. Not "it reconciled" |
| Design ready | committed under `docs/superpowers/specs/`, no `[NEEDS CLARIFICATION]` left |
| Success criteria met | `/verify-spec <design-doc>` against the live cluster, post-merge |

**`Skipped: 0` is part of the claim, not decoration.** A resource with no schema is not validated,
it is ignored. Reporting "validation passed" while resources were skipped is precisely the failure
SPEC-007 was written to remove.

## Rationalizations that are common and wrong

| Excuse | Reality |
|---|---|
| "Should work now" / "I'm confident" | Run the command. Confidence is not evidence |
| "The subagent said success" | Check `git diff` yourself, re-run the validator |
| "The linter passed" | Linter ≠ validator ≠ cluster reality |
| "Quick fix first, investigate later" | The first fix sets the pattern |
| "Multiple fixes at once saves time" | You cannot isolate what worked, and it creates new bugs |
| "It's simple, skip the process" | Simple bugs have root causes too, and the process is fast for them |
| "One more attempt" (after three) | Three failed fixes means the architecture is wrong, not that fix #4 is right |

## When a stage fails

Do not patch the symptom. Four phases, in order:

1. **Investigate** — read the error exactly, reproduce it, check recent commits and Renovate PRs
   and Flux `lastHandled` timestamps. Gather evidence at each layer.
2. **Pattern** — find a working analogue: a sibling composition, a prior commit, a reference ADR.
   List every difference. No detail is too small.
3. **Hypothesize** — one stated theory, the smallest test, one variable. Worked → fix it. Did not
   work → new hypothesis. Never pile fixes.
4. **Fix** — a single change at the root cause, reproduced as a test where feasible, verified with
   the table above.

After three failed fixes, stop and raise it. The pattern is wrong, not the next attempt.
