# scripts/ restructure — PR 3 (`provision/`) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move the apply-time provisioning scripts into `scripts/provision/`, so that `scripts/`
root holds no loose executables (spec criterion 1).

**Architecture:** Both gates from PRs 1 and 2 already guard every path this PR touches:
- `test-terramate-script-refs.sh` covers the 88 executed `.tf`/`.tm.hcl` references;
- `test-script-paths.sh` covers roots, sibling paths and suite subjects.

The files move in three risk groups, one commit each, and each group's measured failures return
to 0.

**The whole recipe was simulated end to end in a sandbox on 2026-09-22: the moves, the rewrite,
the depth fixes and the suite paths. It ends at refs 88/0, the paths gate at 0 failed, and suites
23/1/0.**

**Tech Stack:** bash, terramate 0.17.3, OpenTofu, go-task 3.53.1.

**Spec:** [`docs/superpowers/specs/2026-09-17-scripts-restructure-design.md`](../specs/2026-09-17-scripts-restructure-design.md)
— the layout, and *Risk and sequencing* ("PR 3 is the one that can fail at 2am"). PR 2's plan,
[`2026-09-21-scripts-restructure-pr2-plan.md`](2026-09-21-scripts-restructure-pr2-plan.md), holds
the rewrite recipe this plan reuses.

## Global Constraints

- **Never execute a `provision/` script, and never run `terramate script run` or `tofu plan`/`apply`
  against real state.** These scripts drive OpenBao, ZITADEL and the secret store in live clouds.
  Prove paths statically.
- **Never anchor a rewrite on the bare token `scripts/`.** `opentofu/{aws,gcp}/openbao/cluster/scripts/`
  are module-local, and their basenames don't overlap with this PR's.
- **`sed -i --follow-symlinks`, always.** Select files with `git grep -l`. The dated archive is
  never rewritten.
- **Basenames are unchanged:** no candidate repeats `provision`. Each move is
  `scripts/<name>` → `scripts/provision/<name>`.
- **`scripts/lib/` stays.** Its sources in moved scripts become `$(dirname "$0")/../lib/…`.
- **`openbao-snapshot.sh` stays a symlink.** It moves to `scripts/provision/`, re-pointed to
  `../../container-images/openbao-snapshot/openbao-snapshot.sh`. `openbao-config.sh:1224` and
  `:1403` run it as a sibling (`sh "$(dirname "$0")/openbao-snapshot.sh"`), so those two lines do
  not change. Owner decision, 2026-09-22.
- **The owner decided (2026-09-22) to index the four human-run scripts** in `task --list`:
  `secret-store`, `zitadel-oidc-clients`, `zitadel-idp` and `openbao-snapshot`. The other four are
  terramate or tofu plumbing and stay unindexed.
- **Job names in `.github/workflows/` must not change,** and no workflow should need to.
- Repository metadata is English. No co-author trailer and no generated-with line.

## Sequencing with #2045 (owner decision: build both now)

#2045 (`feat/openbao-oidc-rotation`, in progress) edits `scripts/zitadel-oidc-clients.sh`. It adds
`scripts/openbao-oidc-check.sh`, and suites that reach both as `$HERE/../../<name>.sh`. Whichever PR
merges second rebases:
- **If #2045 merges first:** Task 3 also `git mv`s `scripts/openbao-oidc-check.sh` into
  `provision/`, repoints `opentofu/aws/eks/init/workflows.tm.hcl`'s stage5 call, and updates the
  subject paths of `test-zitadel-oidc-clients-openbao.sh` and `test-openbao-oidc-check.sh`.
- **If PR 3 merges first:** #2045 rebases. Git carries its edits across the rename. Its check script
  is created in `provision/`, and its suites point at `../../provision/`.

## Evidence required before merge (the design's PR 3 row)

This is the one PR where `terramate script run preview` is real evidence.
`opentofu/{aws/eks,gcp/gke}/configure/main.tf` call `helm-release-present.sh` at **plan time**
through `data "external"`, so a wrong path fails the preview.

The owner runs it on both clouds, and it can share a cluster session with #2045's rebuild. `tofu
validate` runs per stack, and the static gates run in CI.

---

### Task 1: The plumbing every stack calls

**Moves:** `tm-provisioner.sh`, `helm-release-present.sh`, `openbao-adopt-jwt-mount.sh`.

**Load-bearing lines:**
- `opentofu/config.tm.hcl:10`, `global.provisioner`: 172 usages change through this one line.
- `opentofu/config.tm.hcl:24`, `global.cloud_gate`. **It names `tm-provisioner.sh` independently** of
  `global.provisioner`.
- `opentofu/{aws/eks,gcp/gke}/configure/main.tf`: `${path.module}/../../../../scripts/helm-release-present.sh`.

- [ ] **Step 1: move them, and watch the gates fail**
  ```bash
  mkdir -p scripts/provision
  git mv scripts/tm-provisioner.sh scripts/helm-release-present.sh scripts/openbao-adopt-jwt-mount.sh scripts/provision/
  bash scripts/ci/tests/test-terramate-script-refs.sh | tail -1   # expect: 88 … checked; 27 failed
  bash scripts/ci/tests/test-script-paths.sh | tail -1            # expect: … 1 failed
  task ci:test | tail -1                                          # expect: … 3 failed
  ```
  These three scripts have no self-resolved paths (inventory §3), so there is no depth fix.
- [ ] **Step 2: rewrite the references.** The target is 18 files, 43 lines.
  ```bash
  RE='scripts/(tm-provisioner|helm-release-present|openbao-adopt-jwt-mount)\.sh'
  TARGETS=$(git grep -l -E "$RE" -- ':!docs/superpowers/plans' ':!docs/superpowers/specs' ':!docs/specs')
  printf '%s\n' "$TARGETS" | wc -l      # expect 18
  for n in tm-provisioner helm-release-present openbao-adopt-jwt-mount; do
    # shellcheck disable=SC2086
    sed -i --follow-symlinks "s|scripts/${n}\.sh|scripts/provision/${n}.sh|g" $TARGETS
  done
  ```
- [ ] **Step 3: fix the suite subject.** `scripts/ci/tests/test-tm-provisioner.sh:4` becomes
  `G="$HERE/../../provision/tm-provisioner.sh"`. Delete its "still at scripts/ root" comment.
- [ ] **Step 4: verify.**
  - The refs gate gives `88 … 0 failed`, the paths gate `0 failed`, and `task ci:test` `23 passed, 1 skipped, 0 failed`.
  - `(cd opentofu && terramate fmt --check && terramate list | wc -l)` gives 16.
  - `git diff HEAD -- 'opentofu/**'` shows only `scripts/<name>` → `scripts/provision/<name>` substitutions.
  - For each of the 13 symlinks, `[ -L ]` still holds.
- [ ] **Step 5: commit** `refactor(scripts): move the terramate and tofu plumbing to scripts/provision/`.

### Task 2: OpenBao configuration and the secret store

**Moves:** `openbao-config.sh`, `secret-store.sh`, and the `openbao-snapshot.sh` symlink (re-pointed).

- [ ] **Step 1: move them, and watch the gates fail**
  ```bash
  git mv scripts/openbao-config.sh scripts/secret-store.sh scripts/provision/
  git rm -q scripts/openbao-snapshot.sh
  ln -s ../../container-images/openbao-snapshot/openbao-snapshot.sh scripts/provision/openbao-snapshot.sh
  git add scripts/provision/openbao-snapshot.sh
  test -x scripts/provision/openbao-snapshot.sh && echo "symlink resolves"
  bash scripts/ci/tests/test-terramate-script-refs.sh | tail -1   # expect: 19 failed
  bash scripts/ci/tests/test-script-paths.sh | tail -1            # expect: 8 failed
  task ci:test | tail -1                                          # expect: 8 failed
  ```
- [ ] **Step 2: fix the depths.** `lib/` sources gain one `../`.

  | File:line | From | To |
  |---|---|---|
  | `scripts/provision/openbao-config.sh:6` | `. "$(dirname "$0")/lib/gcloud-adc.sh"` | `. "$(dirname "$0")/../lib/gcloud-adc.sh"` |
  | `scripts/provision/openbao-config.sh:13` | `. "$(dirname "$0")/lib/cloud-secret-store.sh"` | `. "$(dirname "$0")/../lib/cloud-secret-store.sh"` |
  | `scripts/provision/secret-store.sh:81` | `. "$(dirname "$0")/lib/gcloud-adc.sh"` | `. "$(dirname "$0")/../lib/gcloud-adc.sh"` |

  `openbao-config.sh:1224` and `:1403` (`$(dirname "$0")/openbao-snapshot.sh`) **stay as they are**,
  because the symlink moved with them. No gate checks a bare `$(dirname "$0")/x` path, so prove it:
  `test -x "scripts/provision/$(basename openbao-snapshot.sh)"`.

  Leave the `# shellcheck source=scripts/lib/…` directives alone. They are root-relative, which is
  what CI's shellcheck needs.
- [ ] **Step 3: rewrite the references.** The target is 34 files, 69 lines. Use the same loop as Task 1,
  with `openbao-config|secret-store|openbao-snapshot`, and expect `wc -l` to give **34**.
- [ ] **Step 4: fix the suite subjects.** Edit `$HERE/../../<name>.sh` → `$HERE/../../provision/<name>.sh`
  in these suites, and delete each one's "still at scripts/ root" comment:
  - `test-openbao-fallback-address.sh:46`
  - `test-openbao-root-token-probe.sh:36`
  - `test-openbao-pki-verify.sh:35`
  - `test-openbao-seal-status-tls.sh:50`
  - `test-openbao-snapshot-key.sh:50`

  `test-secret-store-lint.sh:20` reads `scripts/secret-store.sh` from the repo root, so Step 3's
  rewrite covers it. Delete its revisit comment too.
- [ ] **Step 5: verify** as in Task 1 Step 4. Also confirm that
  `git ls-files -s scripts/provision/openbao-snapshot.sh` shows mode `120000` with the new target.
- [ ] **Step 6: commit** `refactor(scripts): move OpenBao configuration and the secret store to scripts/provision/`.

### Task 3: ZITADEL

**Moves:** `zitadel-idp.sh`, `zitadel-actions/`, `zitadel-oidc-clients.sh`. The `zitadel-actions/`
directory moves with `zitadel-idp.sh`, which reads it, so the relative read needs no fix.

- [ ] **Step 1: move them, and watch the gates fail**
  ```bash
  git mv scripts/zitadel-idp.sh scripts/zitadel-actions scripts/zitadel-oidc-clients.sh scripts/provision/
  bash scripts/ci/tests/test-terramate-script-refs.sh | tail -1   # expect: 7 failed
  bash scripts/ci/tests/test-script-paths.sh | tail -1            # expect: 12 failed
  task ci:test | tail -1                                          # expect: 6 failed
  ```
- [ ] **Step 2: fix the depths.** Six `lib/` sources, `zitadel-idp.sh:60,62,64` and
  `zitadel-oidc-clients.sh:54,56,58`, each become `$(dirname "$0")/../lib/<same>.sh`. Verify each
  line by content first. If #2045 has merged, `zitadel-oidc-clients.sh` also sources
  `lib/openbao-api.sh`; fix that line the same way.
- [ ] **Step 3: rewrite the references.** The target is 18 files, 34 lines. Use the same loop, with
  `zitadel-idp\.sh|zitadel-oidc-clients\.sh` plus a separate `s|scripts/zitadel-actions/|scripts/provision/zitadel-actions/|g`.
- [ ] **Step 4: fix the suite subjects.** Edit `$HERE/../../<name>.sh` → `$HERE/../../provision/<name>.sh`
  in these suites, and delete each revisit comment:
  - `test-zitadel-idp-convergence.sh:91`
  - `test-zitadel-oidc-clients-convergence.sh:61`
  - `test-zitadel-oidc-clients-project.sh:35`
  - `test-zitadel-oidc-clients-redirects.sh:54`
  - `test-zitadel-oidc-clients-secrets.sh:106`
  - `test-zitadel-workforce-audience.sh:36`

  If #2045 has merged, apply the #2045 steps from the Sequencing section above.
- [ ] **Step 5: verify** as in Task 1 Step 4. Also run a final grep:
  ```bash
  git grep -n "still at scripts/ root" -- scripts/ci/tests   # expect: no output
  ls scripts/        # expect only: AGENTS.md CLAUDE.md README.md tasks.yaml ci docs lib ops provision
  ```
- [ ] **Step 6: commit** `refactor(scripts): move ZITADEL provisioning to scripts/provision/`.

### Task 4: Index the human-run scripts, and document the layout

**Files:**
- Create: `scripts/provision/tasks.yaml`. Not `taskfile.yaml`: go-task stops at the first
  taskfile it finds walking up.
- Modify: `taskfile.yaml`, adding the include. Also modify `scripts/README.md`, `scripts/AGENTS.md`
  (only if it names moved paths the rewrite missed), and `website/content/docs/reference/commands.md`.

- [ ] **Step 1: write `scripts/provision/tasks.yaml`.** Use four tasks: `secret-store`,
  `zitadel-oidc-clients`, `zitadel-idp` and `openbao-snapshot`.
  - Each is a one-line `{{.TASKFILE_DIR}}/<name>.sh {{.CLI_ARGS}}` with a one-line `desc` taken from
    the script's header.
  - Add a top comment naming the four unindexed plumbing scripts, and why: terramate and tofu call
    them.
  - If a script needs a particular working directory, add `dir:`; check each header.
- [ ] **Step 2:** add `provision: {taskfile: scripts/provision/tasks.yaml}` to `taskfile.yaml`,
  next to the `ops:` and `docs:` includes.
- [ ] **Step 3: `scripts/README.md`.**
  - Add a `provision/` row: invoked by terramate and tofu during an apply, plus the four `task
    provision:*` entry points.
  - Replace the closing "still sit at the root … later phase" sentence. Criterion 1 is met now.
- [ ] **Step 4: verify.**
  - `task --list | grep -cE '^\* (ops|docs|provision):'` gives **19** (15 + 4).
  - `task --dry provision:secret-store -- --help` resolves to `scripts/provision/secret-store.sh`.
  - `task ci:links`, `task ci:doc-paths` and `task ci:doc-claims` all pass.
- [ ] **Step 5: commit** `feat(task): index the human-run provision scripts`.

### Task 5: Verification and the PR (controller, inline)

- [ ] Rebase onto `origin/main`. **Check whether #2045 has merged**, and if it has, apply the
  Sequencing steps.
- [ ] Run the refs gate (88/0), the paths gate (0 failed), `task ci:test` (0 failed), the docs
  gates, `terramate fmt --check`, a check that every symlink is intact, and ShellCheck with CI's
  exact `find`.
- [ ] Run `tofu init -backend=false && tofu validate` in every stack that references a moved
  script. Clean up each `.terraform/` afterwards.
- [ ] Open the PR. Its body carries:
  - links to the design and all three plans;
  - criterion 1, now met: `ls scripts/`;
  - the static evidence;
  - **an unchecked merge checkbox for the owner-run `terramate script run preview` on both clouds**
    (real evidence here, because `helm-release-present.sh` runs at plan time);
  - the #2045 sequencing note.
- [ ] **Do not merge** until the owner ticks the preview box.

## Self-Review

- **Spec coverage.** The design's PR 3 row lists `provision/`, `tofu validate` per stack, and a
  preview on both clouds: Tasks 1–3 and Task 5. Criterion 1 is proved by Task 3 Step 5. Criterion 2
  is covered by Task 4, per the owner's decision.
- **Measured, not copied.**
  - The design said 125 live refs; measurement found 145 lines in 59 files (inventory).
  - The executed refs number 53 (27 + 19 + 7), matching the three tasks' simulated failures.
  - The per-task target counts (18, 34, 18 files) come from `git grep -l`. `git archive` omits the
    `.tfvars` files, so the counts are taken from the repo, not the sandbox.
- **Load-bearing lines called out:**
  - `global.cloud_gate` names `tm-provisioner.sh` independently;
  - `openbao-config.sh`'s sibling calls to the symlink;
  - `helm-release-present.sh` runs at plan time.
