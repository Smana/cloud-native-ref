# OpenBao OIDC client rotation (#2045) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** After a rebuild, OpenBao's `oidc/` auth backend points at the ZITADEL client that the
rebuild created, with no manual re-apply. A post-deploy check fails the deploy if it doesn't.

**Architecture:**
- Terraform keeps creating the OIDC mount.
- `scripts/zitadel-oidc-clients.sh` becomes the writer of the three fields that rotate on every
  rebuild: `oidc_client_id`, `oidc_client_secret` and the role's `bound_audiences`. It reconciles them
  right after it creates or finds the ZITADEL app.
- `oidc.tf` ignores changes to those three fields. Otherwise the next early management apply would
  rewrite them while ZITADEL is down, and fail OpenBao's discovery check.
- A new `stage5` job verifies the result and halts the run on a mismatch.

**Tech Stack:** bash, curl, jq, OpenTofu (vault provider), Terramate 0.17.3, OpenBao 2.6.2.

**Spec:** [`docs/superpowers/specs/2026-09-21-openbao-oidc-client-rotation-design.md`](../specs/2026-09-21-openbao-oidc-client-rotation-design.md).
Read §0 (verified facts) and §2 (design) before any task. The facts are load-bearing:
- facts 5 and 6: the role also carries the id, and a config write replaces the whole config;
- fact 8: the provider never refreshes the secret;
- fact 14: errexit is off inside `||`.

## Global Constraints

- **Secrets never touch argv.** The root token reaches curl only through a mode-0600 `-K` config
  file, written with `printf` (a builtin). Request bodies carrying the client secret go through stdin
  (`--data-binary @-`). `scripts/ci/tests/test-no-secret-argv.sh` scans every new file automatically,
  and it must stay green.
- **TLS is always verified,** with `--cacert`. Never `-k`, and never `skip_jwks_validation`.
- **Inert unless explicitly configured.** An empty `--openbao-url` means no OpenBao calls at all.
  Only aws-0's own sync passes the flags. The gcp-0 consumer call and every GCP call pass none. OpenBao
  OIDC exists only on AWS (design fact 1).
- **Idempotent.** A converged state makes zero writes.
- **No new `after` edge, and no second apply path.** The #2044 bug shape is off-limits.
- **Every curl and jq call inside the reconcile is checked explicitly** (`|| exit 1`), because
  errexit is off in `||` contexts.
- Test suites go in `scripts/ci/tests/`, where `run.sh` discovers them. Subjects at `scripts/` root
  are reached as `$HERE/../../<name>.sh`, with the comment "The subject is still at scripts/ root.
  When it moves, this path moves with it."
- Stubs are PATH-based, following `scripts/ci/tests/test-zitadel-workforce-audience.sh` and
  `test-cloud-secret-store.sh`. Functions are lifted with sed. **No test contacts a real cloud,
  OpenBao or ZITADEL.**
- Never run `terramate script run` in any mode. Never run a deploy or destroy.
- Repository metadata is English. No co-author trailer and no generated-with line.

## Rulings on the design's open questions (controller, 2026-09-21)

The owner decided Q1 (option B), Q2 (stage5 halts) and Q7 (after #2061). The rest were ruled on the
planner's recommendation, and the PR must list them for the owner:
- **Q3:** first bootstrap stays one manual management apply, which E names explicitly. No second
  apply path.
- **Q4:** the root token, read from the store as `openbao-adopt-jwt-mount.sh` already does. Minting
  a narrow token needs root anyway.
- **Q5:** an amendment to ADR-0034, not a new ADR. This is an ownership decision, not a technology
  choice.
- **Q6:** promoting a fresh ZITADEL seed is a follow-up, out of this PR.
- **Q8:** a PR note that `terramate script run -j` is not used for deploy.
- **T0 (live spike) is skipped.** No cluster is reachable. E's liveness probe treats HTTP 302 as a
  known client and 400 as unknown. Any other code is exit 2, "cannot tell", which still fails the job.
  The PR states the codes are unverified until the first live run.

---

### Task 1: `scripts/lib/openbao-api.sh`, and the contract-guard suite

**Files:**
- Create: `scripts/lib/openbao-api.sh`
- Create: `scripts/ci/tests/test-zitadel-oidc-clients-openbao.sh` (the contract guards start here;
  Task 2 extends the file)

**Interfaces (produced):**
- `openbao_token_config_write <file> <root_token_secret_name>` reads the token through `store_read`
  (from `scripts/lib/cloud-secret-store.sh`, whose `CLOUD`/`REGION` must be set by the caller). It
  takes `.token // .root_token // empty`, escapes `\` and `"`, and writes
  `header = "X-Vault-Token: <token>"` with `printf`. It returns 1 on an empty token. The caller owns
  `umask 077`, `mktemp` and the trap.
- `openbao_req <method> <path> [extra curl args...]` runs
  `curl -fsS --cacert "$OPENBAO_CA_FILE" -K "$OPENBAO_TOKEN_CONFIG" -X <method> "$OPENBAO_URL/v1/<path>" <extra>`.
  It reads the globals `OPENBAO_URL`, `OPENBAO_CA_FILE` and `OPENBAO_TOKEN_CONFIG`.

- [ ] **Step 1: write the failing tests.** Add them to `test-zitadel-oidc-clients-openbao.sh`:
  - **Contract guards against the real repo files:**
    - the `CONSUMERS` openbao key in `scripts/zitadel-oidc-clients.sh` equals `openbao_oidc_secret_id`
      in `opentofu/aws/openbao/management/variables.tfvars`, on an uncommented line (this guards #2011);
    - the role's callback path in `oidc.tf` is `/ui/vault/auth/oidc/oidc/callback`.
  - **Library tests with a stub `curl`.** The stub logs its argv, its stdin, and the `-K` file's
    contents and mode at call time. The tests check:
    - the token file holds the header and has mode 600;
    - the token appears in **no** argv;
    - curl receives `--cacert` and `-K`, and never `-k`;
    - an empty token returns 1 and writes nothing;
    - a token containing `"` and `\` is escaped correctly.
- [ ] **Step 2:** run `bash scripts/ci/tests/test-zitadel-oidc-clients-openbao.sh`. The library
  tests FAIL (no library yet). The contract guards PASS on main. Prove each guard can fail: comment
  out the tfvars line in a temp copy the test points at. Report it, and don't commit the break.
- [ ] **Step 3:** implement `scripts/lib/openbao-api.sh`, with a header comment giving the why:
  secrets never on argv, and one copy of the root-token handling.
- [ ] **Step 4:** the suite PASSES. `bash scripts/ci/tests/test-no-secret-argv.sh` passes, and
  `shellcheck -x -S warning` on both files is clean.
- [ ] **Step 5:** commit `feat(scripts): an OpenBao API helper that keeps the token off argv`.

### Task 2: `openbao_oidc_config_payload`, and `reconcile_openbao_oidc`

**Files:**
- Modify: `scripts/zitadel-oidc-clients.sh`. Add the two functions near `reconcile_workforce_audience` (~:724).
- Test: `scripts/ci/tests/test-zitadel-oidc-clients-openbao.sh`

**Interfaces (produced):**
- **`openbao_oidc_config_payload`** is pure. Its stdin is two JSON docs: first the current `.data`
  from `GET auth/oidc/config`, then the store payload `{client_id, client_secret, endpoint}`. It
  emits `($cfg | del(.status)) + {oidc_client_id: $s.client_id, oidc_client_secret: $s.client_secret}`.
  It returns 1 if `$cfg.provider_config` is non-empty, because the read strips sensitive keys. The
  secret must never go through `jq --arg`.
- **`reconcile_openbao_oidc <store_key> <expected_client_id>`** implements design §2's steps 1–10
  exactly:
  - it is a no-op when there is no URL, no store key, or no `oidc/` mount;
  - it retries the store read until `client_id` equals the expected id;
  - it computes `need_cfg` and `need_role` independently;
  - `[ok]` means no write, and a dry run makes no writes;
  - it POSTs the merged config, retrying 6× `${OPENBAO_DISCOVERY_RETRY_SLEEP:-10}`s on "error
    checking oidc discovery URL";
  - on a failed config write it returns 1 **before** writing the role;
  - the role POST is partial (`role_type` plus `bound_audiences`);
  - it reads back and fails on a mismatch.

  Its output markers are `[skip   ]`, `[ok     ]`, `[dry-run]` and `[reconciled]`. Its body is `{ ( … ) }`
  with a subshell-private EXIT trap for the token file, so it doesn't replace the script's top-level
  trap (:230).

- [ ] **Step 1: failing tests.** Every case in design §3 "Offline suites":
  - the no-op paths;
  - idempotency: zero POSTs when converged;
  - dry run: zero POSTs, and the diff reported;
  - the exact POST bodies: the merged config keeps `default_role`, the discovery URL,
    `namespace_in_state` and `bound_issuer`, drops `status`, and carries the new id and secret;
  - the independent config and role writes;
  - a failed config write means no role write and a non-zero return;
  - the discovery retry and the store-agreement retry, with sleeps stubbed to 0 through the env vars;
  - the caller's EXIT trap survives;
  - the secret and the token are in no argv.
- [ ] **Step 2:** run the suite. The new cases FAIL.
- [ ] **Step 3:** implement the two functions.
- [ ] **Step 4:** the suite PASSES; `test-no-secret-argv.sh` and shellcheck are clean.
- [ ] **Step 5:** commit `feat(scripts): reconcile OpenBao's OIDC client to the one ZITADEL issued`.

### Task 3: flags, and the `cmd_sync` wiring

**Files:**
- Modify: `scripts/zitadel-oidc-clients.sh`. The flag parser is at ~:103-115, the library sources at
  ~:53-58, and `cmd_sync` at ~:796. Also update the header's WHAT IT DOES.
- Modify: `scripts/ci/tests/test-zitadel-oidc-clients-redirects.sh` and
  `scripts/ci/tests/test-zitadel-oidc-clients-convergence.sh`. Each gets an explicit
  `reconcile_openbao_oidc() { :; }` stub.

**Interfaces:**
- New flags `--openbao-url`, `--openbao-root-token-secret` and `--openbao-ca-file`, all empty by
  default. A URL without the other two exits 2. A missing CA file exits 2.
- In the loop, the consumer named `openbao` records its store key and client id. Use `if`, not
  `[ ] &&`. After `reconcile_workforce_audience`, run
  `reconcile_openbao_oidc "$openbao_key" "$openbao_client_id" || openbao_failed=1`, then `exit 1`
  after the summary if it failed.

- [ ] **Step 1: failing tests.**
  - The reconcile is called exactly once, after the loop, with `(openbao-oidc, <id>)`, both on the
    existing-app path and on the create path.
  - A failure exits 1 after the summary.
  - A URL without a token secret exits 2.
  - Drive `cmd_sync` under `set +e`, **not** `|| true` (design fact 14).
- [ ] **Step 2:** FAIL. **Step 3:** implement. **Step 4:** all `scripts/ci/tests/test-zitadel-*.sh`,
  plus `test-no-secret-argv.sh`, pass.
- [ ] **Step 5:** commit `feat(scripts): wire the OpenBao reconcile into zitadel-oidc-clients sync`.

### Task 4: `ignore_changes` in `oidc.tf`

**Files:**
- Modify: `opentofu/aws/openbao/management/oidc.tf`
  - `vault_jwt_auth_backend.oidc` (~:87) gets `lifecycle { ignore_changes = [oidc_client_id, oidc_client_secret] }`.
  - `vault_jwt_auth_backend_role.oidc_default` (~:121) gets `lifecycle { ignore_changes = [bound_audiences] }`.
  - Add a short comment giving the why (design facts 6 and 8) and pointing at `reconcile_openbao_oidc`.
- Modify: the `opentofu/aws/openbao/management/variables.tfvars` comment (~:21-49). Replace "The next
  apply then picks the secret up on its own" with two points:
  - first bootstrap needs one management apply after registration, while ZITADEL is up;
  - after that, rotation is the script's job.
- Test: extend the contract guards so the suite asserts both `ignore_changes` entries exist.

- [ ] **Step 1:** add the failing guard assertion. **Step 2:** FAIL. **Step 3:** edit the files.
  **Step 4:** the guard PASSES.
  - `cd opentofu/aws/openbao/management && tofu init -backend=false && tofu validate` exits 0.
  - `trivy config --exit-code=1 --ignorefile=./.trivyignore.yaml opentofu/aws/openbao/management` exits 0.
- [ ] **Step 5:** commit `fix(openbao): let the ZITADEL sync own the rotating OIDC client fields`.

### Task 5: E, `scripts/openbao-oidc-check.sh`, and its suite

**Files:**
- Create: `scripts/openbao-oidc-check.sh`
- Create: `scripts/ci/tests/test-openbao-oidc-check.sh`

**Interface:**
- Args: `--url`, `--root-token-secret-name`, `--ca-file`, `--cloud aws|gcp`, `--region`/`--project`,
  `--oidc-secret` (default `openbao-oidc`), `--redirect-uri`.
- Exit codes:
  - **0:** consistent, or not bootstrapped (no secret and no mount).
  - **1:** a definite problem, one of:
    - the secret is present but the mount is absent: print the management apply command;
    - the mount is present but the secret is absent: warn that the next management apply destroys
      the mount;
    - the config id or the role audience doesn't match the store: print all three ids and the fix
      command;
    - liveness failed: `POST auth/oidc/oidc/auth_url` returned an empty URL, or the authorize URL's
      first hop returned 400.
  - **2:** cannot tell. Covers OpenBao unreachable, an unreadable token, and a first-hop code other
    than 302 or 400.
- It prints ids only, never secrets.

- [ ] **Step 1: failing tests**, one per exit-code case, with stub `aws` and `curl`. **Step 2:** FAIL.
  **Step 3:** implement, sourcing `lib/cloud-secret-store.sh` and `lib/openbao-api.sh`.
  **Step 4:** PASS; `test-no-secret-argv.sh` and shellcheck are clean.
- [ ] **Step 5:** commit `feat(scripts): check that OpenBao's OIDC client matches ZITADEL's`.

### Task 6: Terramate wiring (`opentofu/aws/eks/init/workflows.tm.hcl`)

**Files:**
- Modify: `opentofu/aws/eks/init/workflows.tm.hcl`, in `stage4-oidc-clients` (~:105) and a new
  `stage5-verify-openbao-oidc` job.
- Test: extend the contract guards.

Steps:
- **stage4:**
  - put `${global.cloud_gate}` on the heredoc's first line;
  - before aws-0's own sync, fetch the CA into a temp dir with `scripts/openbao-config.sh ca`, using
    `--root-ca-secret-name "${global.ca_chain_secret_name}"`, the region and the profile (check the
    exact globals in `config.tm.hcl`);
  - on success, set `OPENBAO_ARGS=(…)`; on failure, print `[warn]` and leave the array empty;
  - append `$${OPENBAO_ARGS[@]+"$${OPENBAO_ARGS[@]}"}` to **only** aws-0's own sync. The gcp-0
    consumer call gets nothing.
- **stage5:**
  - `${global.cloud_gate}`, then the same `primary_cloud != aws` skip as stage4, then the CA fetch;
  - then `scripts/openbao-oidc-check.sh …`;
  - a non-zero exit fails the job, and **it halts the run** (owner decision).
- **Contract guards:**
  - only aws-0's sync passes `--openbao-url`;
  - `gcp/gke/init/workflows.tm.hcl` passes none;
  - stage5 exists after stage4 and calls the check.

- [ ] **Step 1:** add the failing guards. **Step 2:** FAIL. **Step 3:** edit the file.
  **Step 4:** the guards PASS.
  - `cd opentofu && terramate fmt --check` exits 0.
  - `terramate -C opentofu/aws/eks/init script info deploy` lists stage5.
  - `bash scripts/ci/tests/test-terramate-script-refs.sh` stays green, if it is on main by then.
- [ ] **Step 5:** commit `feat(opentofu): reconcile and verify OpenBao's OIDC client on every deploy`.

### Task 7: docs

**Files:**
- Modify: `website/content/docs/platform/security/openbao.md`, § Operator login. Add a short "OIDC
  client rotation" paragraph covering the ownership split, the recovery command and the check.
- Modify: ADR-0034, Consequences. Amend it with "client credentials rotated by
  `zitadel-oidc-clients.sh` (#2045)".
- Modify: the `scripts/AGENTS.md` table. Add a row for `openbao-oidc-check.sh`.
- Modify: the scripts table in `website/content/docs/reference/commands.md`.

- [ ] **Step 1:** edit them. **Step 2:** `task ci:links`, `task ci:doc-paths` and
  `task ci:doc-claims` all exit 0.
- [ ] **Step 3:** commit `docs(openbao): who rotates the OIDC client, and how to check it`.

### Task 8: verification and PR (controller, inline)

- [ ] `task ci:test` shows 0 failed. `test-no-secret-argv.sh` passes. `shellcheck` is clean over
  `scripts/`.
- [ ] Open the PR:
  - link #2045, the design and this plan;
  - list the rulings above for the owner;
  - include the rebuild procedure (design §3, T12) as an **unchecked merge checkbox**.

  **Do not merge.** Only a real rebuild proves the fix. A live check without a rebuild (T11: a dry
  `sync` with the flags, the check, and a `tofu plan -detailed-exitcode`) is also owner-run, because
  no cluster is reachable from here.
