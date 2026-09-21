# Design: OpenBao OIDC client rotation (#2045)

Status: approved 2026-09-21 (option B + E, stage5 halts). Issue: #2045. Implementation plan: `docs/superpowers/plans/2026-09-21-openbao-oidc-client-rotation-plan.md`.

Paths below predate PR #2061 in one respect: test suites now live under `scripts/ci/tests/` and are discovered by `run.sh`, so no `ci.yaml` edit is needed.

## Summary

- **Recommendation: B + E, with one change the issue doesn't list.**
  - B: `scripts/zitadel-oidc-clients.sh` gets `reconcile_openbao_oidc`, which runs after the consumer loop. It reads `openbao-oidc` from the store and writes `auth/oidc/config` (client id and secret) and `auth/oidc/role/default` (`bound_audiences`), but only when they differ.
  - The extra change: `oidc.tf` needs `lifecycle.ignore_changes` on those three fields. Otherwise the next management apply rewrites them, fails OpenBao 2.6.2's discovery check while ZITADEL is still down on a rebuild, and aborts the deploy.
  - E: a new `stage5` job that fails the deploy when OpenBao and the store disagree, or when ZITADEL doesn't know the client.
- **Why the others lose:**
  - A applies the management stack a second time from another stack's job. That is the #2044 bug shape.
  - C needs a new stack plus a move of 4 resources across states, and one mistake deletes the `oidc/` mount (#2011's bug).
  - D only makes the failure rare.
- **Size:** 14 tasks (T0–T13), plus 3 follow-ups.
- **What only a real rebuild proves:** the deploy ends with SSO working and no manual re-apply. After it, `bao read -field=oidc_client_id auth/oidc/config` equals both Secrets Manager's `client_id` and the id on stage4's `[created] openbao` line, and differs from the id before the rebuild. A closing `tofu plan` with exit 0 proves the next rebuild's early management apply won't fail.

## 0. Verified facts

| # | Fact | Source |
|---|---|---|
| 1 | OpenBao OIDC exists **only on AWS**. GCP management has no `oidc.tf` ("No human auth method on GCP yet") | `opentofu/gcp/openbao/management/auth.tf` |
| 2 | Topologies: `aws` (aws-0 hosts), `aws,gcp` (aws-0 hosts, gcp-0 consumes), `gcp` (gcp-0 hosts, no aws-0). The fix acts when primary is aws and must stay inert otherwise | `scripts/validate-idp-topology.sh` |
| 3 | Registration is `stage4-oidc-clients`, gated on `primary_cloud == "aws"`. It swallows failures (`\|\| echo "[warn]"`) and has no `${global.cloud_gate}` | `opentofu/aws/eks/init/workflows.tm.hcl:104-205` |
| 4 | `aws/eks/init` runs `after` `aws/openbao/management` | `stack.tm.hcl`, `terramate list --run-order` |
| 5 | The workaround changes **two** resources: the backend (id and secret) **and** the role's `bound_audiences`. Writing only `auth/oidc/config` leaves logins failing on audience | `oidc.tf:160` |
| 6 | In OpenBao v2.6.2, a config write **replaces** the whole config (only `namespace_in_state` is kept) and validates discovery, failing without `skip_jwks_validation`. A read returns every field except `oidc_client_secret`, plus `status` | `openbao@v2.6.2 builtin/credential/jwt/path_config.go` |
| 7 | Role writes **merge**, except four fields that reset to their defaults when omitted: `role_type`, `bound_claims_type`, `callback_mode` and `oidc_disable_confirmation`. The reconcile sends `role_type`, and `oidc.tf` sets none of the other three | `openbao@v2.6.2 path_role.go` |
| 8 | The vault provider **never refreshes `oidc_client_secret`**. B without `ignore_changes` makes the next management apply plan a secret write, which fails discovery while ZITADEL is down | `terraform-provider-vault vault/resource_jwt_auth_backend.go` |
| 9 | Precedent for "Terraform creates, the script rotates": `reconcile_workforce_audience`, paired with `ignore_changes = [oidc[0].client_id]` | `opentofu/gcp/workforce-identity/main.tf:75-81` |
| 10 | The churn comes from the ZITADEL database restoring from a **frozen seed** that predates the `openbao` app, so every rebuild creates a new app with a new id | `scripts/cnpg-promote-seed.sh` |
| 11 | "OIDC lost on rebuild" is #2011 (f333c4a4, 2026-09-10); break-glass `secrets-admin` is #2017 (4734282f) | `git log` |
| 12 | `scripts/test-no-secret-argv.sh` is on `main` and in CI | `ci.yaml:363` |
| 14 | errexit is **off** inside a function or subshell whose status is tested with `\|\|` | bash semantics |

## 1. Options

| Option | Correct in all 3 topologies | Blast radius | Ordering / deadlock | Secrets on argv | Effort |
|---|---|---|---|---|---|
| **A** re-apply management from stage4 | yes; also creates the mount on first bootstrap | the whole management stack applied a second time, late | a **second apply path** run from another stack's job: the #2044 shape | none | S, but only a rebuild tests it |
| **B** the script writes OpenBao | yes; keyed on the target store and the `oidc/` mount existing | 2 paths, 3 fields | no new edge; runs after management (`after` edge); ≤2 sequential writes; **needs `ignore_changes`** | token via a `-K` file, body via stdin; guarded | M (~1.5 d), tested offline |
| **C** a new `aws/openbao/oidc` stack | yes | a state move of 4 resources; a missed `destroy = false` deletes `oidc/` (#2011 again) | a new stack with its own CA step and lineage-gated destroy | none | L (2–3 d plus a migration rebuild) |
| **D** a stable id via a fresh seed | only until the next app or an older seed | runbook | — | — | XS |
| **E** a post-deploy check | detects only | read-only | a final job; exit 1 stops later stacks | reads only | S |

B's reconcile runs **after the loop**, comparing desired and actual state each time. It heals a failed earlier write, and fixes an OpenBao that is stale today. "Write at creation only" does neither.

## 2. Design

**Ownership.** Terraform (`oidc.tf`) creates the mount, tune settings, discovery URL, `default_role`, redirect URIs, scopes, claims and TTLs, and the identity group and alias. It ignores `oidc_client_id`, `oidc_client_secret` and `bound_audiences` after creation. `reconcile_openbao_oidc` rotates exactly those three, and never creates or deletes a mount. This follows the workforce-identity precedent.

**New `scripts/lib/openbao-api.sh`.**
- `openbao_token_config_write <file> <secret>` reads the root token with `store_read`, then writes a curl `-K` config with `printf`, so the token never reaches argv. It refuses an empty token.
- `openbao_req <method> <path> …` runs `curl -fsS --cacert … -K … "$OPENBAO_URL/v1/$path"`. Request bodies come from stdin.

**`scripts/zitadel-oidc-clients.sh`:**
- New flags `--openbao-url`, `--openbao-root-token-secret` and `--openbao-ca-file`. An empty URL makes this a no-op; a URL without the other two exits 2. TLS is never skipped.
- `openbao_oidc_config_payload` is a pure merge: current config minus `status`, plus the new id and secret, with the secret passed via stdin. It refuses a non-empty `provider_config`.
- `reconcile_openbao_oidc <key> <expected_id>`, in this order:
  1. No URL → return 0.
  2. Store key absent → skip.
  3. Read the store, retrying until `client_id` equals ZITADEL's id.
  4. `sys/auth` shows no `oidc/` mount → skip, and print the command for the first-bootstrap management apply.
  5. Read the config and role, then compute `need_cfg` and `need_role` independently.
  6. Neither is needed → `[ok]`, and no write.
  7. Dry run → report the diff.
  8. Merged config POST. On a discovery error, retry 6 × 10s. On final failure, exit 1 **without** writing the role.
  9. Partial role POST, setting `bound_audiences`.
  10. Read both back; exit 1 on a mismatch.

  It runs in a subshell with its **own** EXIT trap, so it doesn't clobber the PAT-file trap. Every call is checked explicitly, because errexit is off in an `||` context.
- `cmd_sync` records the openbao key and id in the loop, calls the reconcile after `reconcile_workforce_audience`, and exits 1 after the summary on failure.

**`opentofu/aws/openbao/management/oidc.tf`:**
- `ignore_changes = [oidc_client_id, oidc_client_secret]` on the backend, and `[bound_audiences]` on the role, each with a comment giving the reason.
- The `variables.tfvars` comment gets updated: first bootstrap needs one management apply after registration; from then on, rotation is the script's job.

**Terramate (`aws/eks/init/workflows.tm.hcl`):**
- stage4 gets `${global.cloud_gate}` and fetches the CA into a temp dir.
- It passes the `--openbao-*` flags **only** on aws-0's own sync. The gcp-0 consumer and GCP calls get none.
- A new `stage5-verify-openbao-oidc` job runs `scripts/openbao-oidc-check.sh`.
- No `after` edges change.

**Authentication.** The script uses the OpenBao root token from Secrets Manager (`openbao/cloud-native-ref/tokens/root`), read with the deploy operator's AWS credentials, which is the same credential the management apply uses. The alternative, a minted narrow-policy token, still needs root to mint it.

**E: `scripts/openbao-oidc-check.sh`.** Exit 0 means consistent or not bootstrapped; 1 means a definite problem; 2 means it cannot tell.
- It exits 1 when:
  - the secret exists but the mount doesn't;
  - the mount exists but the secret doesn't (the next management apply would destroy the mount);
  - the id or audience doesn't match the store;
  - the liveness probe fails. It asks `auth_url` for a first-hop URL and requires the known-client HTTP code: expected 302, versus 400 for App.NotFound, which T0 confirms.
- It prints ids only, never secrets.

**Failure matrix:**

| Situation | Result |
|---|---|
| Re-deploy on a live platform | no writes; E passes |
| Rebuild | stage4 creates, stores and reconciles; E passes |
| Reconcile fails | E fails the deploy; re-running `sync --apply` with the flags heals it |
| ZITADEL times out | registration skipped; E's liveness probe fails loudly |
| First bootstrap | reconcile skips; E prints the management apply command |
| GCP / consumer call | no OpenBao call |
| Dry run | reads only |

## 3. Verification

**Offline suites**, following the stub pattern of `test-zitadel-workforce-audience.sh`:
- `scripts/test-zitadel-oidc-clients-openbao.sh` covers the no-op paths, idempotency, the dry run, the exact POST bodies, the independent config and role writes, no role write after a failed config write, the retries, and the EXIT trap surviving. It proves the token and secret **never reach argv**, and that the token file is mode 600 and gets removed. It also checks invocation-context contracts: only aws-0's sync passes the flags, stage5 exists, `ignore_changes` is present, and the tfvars key line is active.
- `scripts/test-openbao-oidc-check.sh` covers every exit code.
- The existing suites stub `reconcile_openbao_oidc() { :; }`.

**Live check without a rebuild (T11):** a dry `sync` prints `[ok]` or a diff; the check exits 0, or heals with `--apply`; the management `tofu plan -detailed-exitcode` exits 0.

**Real rebuild (T12):** don't promote a new seed first. Preflight: #2011 and #2017 are present, the tfvars line is active, and the break-glass login lists `secrets-admin`. Record `BEFORE`, then run `terramate script run --reverse destroy`, verify the result against the cloud, and deploy with no manual re-apply. Proof: `BAO == AUD == SM == NEW`, where `NEW` is the id on the stage4 `[created] openbao` line and differs from `BEFORE`. `bao login -method=oidc` must work, and the management `tofu plan` must exit 0.

## 5. Risks

- **R1.** A read-modify-write drops any field the read doesn't return. The suite pins the payload shape, and E catches drift.
- **R2.** ZITADEL's public route can lag pod readiness. Mitigated by the retry; E catches what's left.
- **R3.** Operators may still expect a management re-apply to fix a stale client. Docs and E's message give the new command.
- **R4.** A rotation that changes only the secret, not the id, isn't pushed. No such flow exists today.
- **R5.** A deploy from a stale worktree reverting `secrets-admin` is unchanged by B.
- **R6.** A pre-existing hazard in `converge_secret`: a restored seed **older** than the store pairs the old client id with the newer secret, giving `invalid_client`, which E's first-hop probe can't see.
- **R7.** errexit is off in an `||` context.

## 6. Open questions for the owner

1. **The top one:** do you accept the ownership split? Terraform creates, the script rotates, and `ignore_changes` covers 3 fields. After this, re-applying management no longer fixes a stale client, and drift detect stops seeing the id; E replaces it. The alternative is A.
2. Should stage5 **halt** the run, which on `aws,gcp` skips `gcp/gke/init`, or report and continue?
3. Is first bootstrap staying a manual management apply acceptable, now that E calls it out?
4. Root token, or a minted narrow-scope token?
5. An ADR-0034 amendment, or a new ADR? The planner's view: this is an ownership decision, so an amendment is enough.
6. Promote a new seed after T12, given R6?
7. Sequencing with the scripts restructure. If PR 1 lands first, the suites go under `scripts/ci/tests/`, and the `ci.yaml` edit is dropped.
8. Confirm that `terramate script run -j` is never used for deploy.

## 7. Owner decisions (2026-09-21)
- Ownership: **B**. Terraform creates the mount; `zitadel-oidc-clients.sh` rotates the client id, secret and audience; `ignore_changes` covers those three fields.
- stage5 check: **halt the run** on mismatch.
- Timing: **implement after #2061 merges**, on the new layout, with suites under `scripts/ci/tests/`.
- Still open: Q3 (first bootstrap stays a manual management apply), Q4 (root token vs minted token), Q5 (ADR-0034 amendment), Q6 (fresh seed after T12), Q8 (`-j`).
