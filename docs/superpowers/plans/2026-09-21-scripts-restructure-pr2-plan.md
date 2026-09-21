# scripts/ restructure — PR 2 (`ops/`, `docs/`, the terramate-reference gate) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move the day-2 operations scripts into `scripts/ops/<area>/` and the docs-site generators
into `scripts/docs/`, and move `check-rebased.sh` to `scripts/ci/`. `teardown.sh` and its orphan sweep
move too: the design listed them for deletion, but they are live human tools (see Task 2). All of it happens under a new gate that proves every script path opentofu and
terramate execute still resolves.

**Architecture:** This PR has the same shape as PR 1: the gate ships first, on the unmoved tree,
and is provably green before anything relocates. Then the files move, one audience per commit, and
each move re-runs the gate. The gate is needed because 30 executed references to these scripts
live in `.tf` and `.tm.hcl` files. They run at apply and destroy time, no CI job executes
them, and neither existing gate reads them.

**Tech Stack:** bash, go-task v3.53.1 (via `mise.toml`), terramate, Python 3 (`diagram-icons.py`,
untouched apart from its root depth).

**Spec:** [`docs/superpowers/specs/2026-09-17-scripts-restructure-design.md`](../specs/2026-09-17-scripts-restructure-design.md)
— the target layout (~lines 55–100) and *Risk and sequencing*. PR 1's plan,
[`2026-09-17-scripts-restructure-pr1-plan.md`](2026-09-17-scripts-restructure-pr1-plan.md), holds
the reference-rewrite recipe this plan reuses.

## Global Constraints

- **Branch base.** Work happens in worktree `.claude/worktrees/scripts-pr2` on branch
  `worktree-scripts-pr2`, which is cut from PR 1's head `7ec01df5` (#2061, unmerged). **PR 2 does
  not open until #2061 merges**. The `check-rebased` pre-push hook refuses the push anyway.
- **Never execute an `ops/` script to test a move.** They act on live clouds:
  `eks-prepare-destroy.sh` deletes every PVC. Prove paths statically, with `bash -n`, `test -e` on
  the resolved path, and the gates.
- **Never anchor a path rewrite on the bare token `scripts/`.** `opentofu/{aws,gcp}/openbao/cluster/scripts/`
  are module-local directories. Anchor on `scripts/<old-name>`.
- **`sed -i --follow-symlinks`, always.** `sed -i` replaces a symlink with a regular file even on
  a no-match run. The repo has 13 tracked symlinks, and ten are `CLAUDE.md` → `AGENTS.md`.
- **Select rewrite targets with `git grep -l`, never a file glob.**
- **The dated archive is not rewritten:** `docs/superpowers/plans/`, `docs/superpowers/specs/`,
  `docs/specs/`.
- **The prefix drops only when it repeats the directory name.** `aws-sweep-orphaned-volumes.sh`
  becomes `ops/aws/sweep-orphaned-volumes.sh`. `eks-`, `cnpg-` and `destroy-` are not directory
  names and stay.
- **Do not move:** `openbao-snapshot.sh` (a symlink whose home is unsettled), or anything bound
  for `provision/` in PR 3: `helm-release-present.sh`, `openbao-adopt-jwt-mount.sh`,
  `openbao-config.sh`, `secret-store.sh`, `tm-provisioner.sh`, `zitadel-actions/`,
  `zitadel-idp.sh`, `zitadel-oidc-clients.sh`.
- **Job names in `.github/workflows/*.y*ml` must not change.** They are required-check contexts.
  No PR 2 script is referenced from a workflow (0 hits), so no workflow should change at all.
- Repository metadata is English. Never co-author commits, and add no generated-with lines.

---

## File Structure

**Created:**

| Path | Responsibility |
|---|---|
| `scripts/ci/tests/test-terramate-script-refs.sh` | the gate: every script path on an executed opentofu/terramate line exists |
| `scripts/ops/tasks.yaml` | `ops:*` tasks, each a one-line call with `{{.CLI_ARGS}}` passthrough |
| `scripts/docs/tasks.yaml` | `docs:*` tasks |

**Moved** (`git mv`; depth fixes go in the same commit):

| From `scripts/` | To `scripts/` | Task |
|---|---|---|
| `export-diagrams.sh`, `diagram-icons.py`, `build-og-card.html` | `docs/` (names unchanged) | 3 |
| `aws-sweep-orphaned-volumes.sh` | `ops/aws/sweep-orphaned-volumes.sh` | 4 |
| `aws-sweep-teardown-blockers.sh` | `ops/aws/sweep-teardown-blockers.sh` | 4 |
| `aws-sweep-controller-orphans.sh` | `ops/aws/sweep-controller-orphans.sh` | 4 |
| `eks-prepare-destroy.sh`, `eks-recycle-bootstrap-nodes.sh` | `ops/aws/` (names unchanged) | 4 |
| `gcp-adopt-workforce-pool.sh` | `ops/gcp/adopt-workforce-pool.sh` | 4 |
| `gcp-purge-dns-records.sh` | `ops/gcp/purge-dns-records.sh` | 4 |
| `gcp-sweep-orphaned-disks.sh` | `ops/gcp/sweep-orphaned-disks.sh` | 4 |
| `k8s-reclaim-csi-volumes.sh` | `ops/k8s/reclaim-csi-volumes.sh` | 4 |
| `cnpg-prepare-restore.sh`, `cnpg-promote-seed.sh` | `ops/k8s/` (names unchanged) | 4 |
| `demo-load.sh` | `ops/demo/load.sh` | 4 |
| `cleanup-benchmark-images.sh` | `ops/demo/` (name unchanged) | 4 |
| `destroy-stage2.sh`, `tofu-destroy-contained.sh`, `terramate-destroy-confirm.sh` | `ops/teardown/` (names unchanged) | 5 |
| `teardown.sh` | `ops/teardown/teardown.sh` | 5 |
| `check-rebased.sh` | `ci/check-rebased.sh` | 6 |

**Deleted:** nothing. The design's Deletions table listed `teardown.sh` and
`aws-sweep-controller-orphans.sh`; the owner overruled it on 2026-09-21 (Task 2).

**Modified:** `taskfile.yaml`, `.pre-commit-config.yaml`, `scripts/README.md`, `scripts/AGENTS.md`,
`scripts/ci/tests/test-cnpg-promote-seed.sh`, plus every file `git grep -l` selects in Tasks 3–6.

---

### Task 1: The `test-terramate-script-refs.sh` gate

Measured on this branch: **87** script references on executed (non-comment) lines under
`opentofu/`, in five shapes. `${terramate.root.path.fs.absolute}/scripts/X` ×70, `$${ROOT}/scripts/X`
×7, bare `scripts/X` in `echo` hints ×4, `${path.module}/scripts/X` ×4 (module-local), and
`${path.module}/../../../../scripts/X` ×2.

Two rules resolve all five. A `${path.module}/` prefix resolves beside the `.tf` file. Everything
else resolves from the repo root.

**Files:**
- Create: `scripts/ci/tests/test-terramate-script-refs.sh`
- Modify: `scripts/AGENTS.md` (one row in `## The rest`)

**Interfaces:**
- Produces: the suite. `run.sh` discovers it with no wiring. Two env overrides exist for fixtures:
  `TM_REFS_ROOT` (repo root to scan) and `TM_REFS_FLOOR` (coverage floor, default 80). Tasks 3–6
  re-run it after every move.

- [ ] **Step 1: Write the gate**

```bash
#!/usr/bin/env bash
# Every script path that opentofu and terramate name on an executed line must exist.
#
# These run at apply and destroy time, and no CI job executes them. A move that
# misses one fails mid-destroy with a bare "No such file". test-script-paths.sh
# checks paths computed *inside* scripts; verify-doc-paths.sh reads only the docs
# site. Neither reads *.tm.hcl or *.tf, which is where these live.
#
# Comment lines are skipped: a stale comment misleads, but it cannot break a run.
# `echo` hints are checked — an operator copies them during a failed destroy.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${TM_REFS_ROOT:-$(cd "$HERE/../../.." && pwd)}"
# Measured at the commit that added this gate. A count below it means the
# extraction broke, not that references went away; fail rather than pass over less.
FLOOR="${TM_REFS_FLOOR:-80}"

checked=0 failed=0
while IFS= read -r hit; do
  file="${hit%%:*}"; rest="${hit#*:}"; line="${rest%%:*}"; text="${rest#*:}"
  [[ "$text" =~ ^[[:space:]]*(#|//) ]] && continue
  while IFS= read -r ref; do
    [ -n "$ref" ] || continue
    if [[ "$ref" == '${path.module}/'* ]]; then
      target="$ROOT/$(dirname "$file")/${ref#'${path.module}/'}"
    else
      target="$ROOT/scripts/${ref#*scripts/}"
    fi
    checked=$((checked + 1))
    if [ ! -e "$target" ]; then
      printf 'FAIL  %s:%s  %s\n      resolved to %s\n' "$file" "$line" "$ref" "${target#"$ROOT"/}"
      failed=$((failed + 1))
    fi
  done < <(grep -oE '[$]?[$][{][^}]+[}](/\.\.)*/scripts/[A-Za-z0-9_./-]+\.(sh|py|js)|(^|[[:space:]"(])scripts/[A-Za-z0-9_./-]+\.(sh|py|js)' <<<"$text" \
             | sed -E 's/^[[:space:]"(]//')
done < <(cd "$ROOT" && grep -rnE --include='*.tf' --include='*.tm.hcl' --include='*.tfvars' \
           'scripts/[A-Za-z0-9_./-]+\.(sh|py|js)' opentofu 2>/dev/null)

if [ "$checked" -lt "$FLOOR" ]; then
  echo "FAIL  checked $checked script reference(s), floor is $FLOOR: the extraction broke, not the references"
  exit 1
fi
echo "$checked script reference(s) on executed opentofu/terramate lines checked; $failed failed"
[ "$failed" -eq 0 ]
```

`chmod +x` it. The `'${path.module}/'` single quotes are deliberate: they are a literal match, not
an expansion. ShellCheck's SC2016 is not raised at `-S warning`, but confirm that in Step 6.

- [ ] **Step 2: Run it against the real tree**

Run: `bash scripts/ci/tests/test-terramate-script-refs.sh; echo "exit=$?"`
Expected: `87 script reference(s) on executed opentofu/terramate lines checked; 0 failed`, `exit=0`.

- [ ] **Step 3: Prove it catches a moved script**

It must fail on exactly the move it exists for. Run it against a copy with
`terramate-destroy-confirm.sh` moved and nothing rewritten:

```bash
T=$(mktemp -d); cp -r opentofu scripts "$T"/
mkdir -p "$T/scripts/ops/teardown"
mv "$T/scripts/terramate-destroy-confirm.sh" "$T/scripts/ops/teardown/"
TM_REFS_ROOT="$T" bash scripts/ci/tests/test-terramate-script-refs.sh | tail -1; echo "exit=${PIPESTATUS[0]}"
```
Expected: `87 script reference(s) … checked; 15 failed`, `exit=1`.

- [ ] **Step 4: Prove it resolves `${path.module}` climbs**

```bash
mv "$T/scripts/ops/teardown/terramate-destroy-confirm.sh" "$T/scripts/"
mv "$T/scripts/helm-release-present.sh" "$T/scripts/helm-release-present.sh.bak"
TM_REFS_ROOT="$T" bash scripts/ci/tests/test-terramate-script-refs.sh | grep -c '^FAIL'
```
Expected: `2`, meaning the two `${path.module}/../../../../scripts/helm-release-present.sh` lines
in `opentofu/{aws/eks,gcp/gke}/configure/main.tf`.

- [ ] **Step 5: Prove it refuses to pass over nothing**

```bash
E=$(mktemp -d); mkdir -p "$E/opentofu"
TM_REFS_ROOT="$E" bash scripts/ci/tests/test-terramate-script-refs.sh; echo "exit=$?"
rm -rf "$T" "$E"
```
Expected: `FAIL  checked 0 script reference(s), floor is 80: …`, `exit=1`.

- [ ] **Step 6: Lint, and prove discovery**

```bash
shellcheck -x -S warning scripts/ci/tests/test-terramate-script-refs.sh; echo "shellcheck=$?"
task ci:test | grep -E 'terramate-script-refs|passed,'
```
Expected: `shellcheck=0`, a `PASS  test-terramate-script-refs` line, and
`23 passed, 1 skipped, 0 failed` (PR 1 had 22 passed).

- [ ] **Step 7: Document it**

In `scripts/AGENTS.md`, in the `| Script | Checks |` table under `## The rest`, add this row
directly after the `validate-idp-topology.sh` row:

```markdown
| `ci/tests/test-terramate-script-refs.sh` | every script path on an **executed** `.tf`/`.tm.hcl` line exists — the apply- and destroy-time calls no CI job runs. Comments are skipped; `echo` hints are not |
```

- [ ] **Step 8: Commit**

```bash
git add scripts/ci/tests/test-terramate-script-refs.sh scripts/AGENTS.md
git commit -m "test(ci): gate every script path opentofu and terramate execute

87 references on executed lines, 30 of them to scripts this PR moves.
They run at apply and destroy time and no CI job executes them; neither
test-script-paths.sh nor verify-doc-paths.sh reads a .tf or .tm.hcl."
```

---

### Task 2: Dropped — `teardown.sh` and its orphan sweep are kept

The design's Deletions table listed both as "no caller in CI, opentofu, manifests or docs". That is
true, and it misses the point: **a human is the caller.**

- `teardown.sh` calls itself "the supported way to tear the platform down" (#1970, #1976). It exists
  because bare `terramate script run --reverse destroy` stops at the first failing stack and can
  report success having destroyed nothing. It continues past failures, sweeps what controllers left,
  retries, then verifies against the cloud.
- `aws-sweep-controller-orphans.sh` is that sweep. It exists for the teardown that fails partway,
  when `eks/init`'s own destroy-time sweeps can no longer run.

The owner decided on 2026-09-21 to keep both. They move with their audience instead:
`aws-sweep-controller-orphans.sh` in Task 4, `teardown.sh` in Task 5. Both are indexed in Task 7.
Nothing is deleted in this PR.

---

### Task 3: Move the docs-site generators into `scripts/docs/`

Three files, 14 reference lines across 9 files. All three compute a path to the repo root from
where they sit, and each lands one level deeper.

**Files:**
- Move: `scripts/{export-diagrams.sh,diagram-icons.py,build-og-card.html}` → `scripts/docs/`
- Modify: the three files' root depths, plus every file Step 4 selects

**Interfaces:**
- Produces: `scripts/docs/export-diagrams.sh`, `scripts/docs/diagram-icons.py`,
  `scripts/docs/build-og-card.html`. Task 7 indexes the first two.

- [ ] **Step 1: Record the audit baseline**

`diagram-icons.py audit` exits 0 whatever it finds. Run from the wrong root, it prints nothing and
still exits 0, so only its counts prove it read the diagrams:

```bash
python3 scripts/diagram-icons.py audit 2>&1 | grep -cE '^[a-z0-9]'
python3 scripts/diagram-icons.py audit 2>&1 | grep -E '^ +[0-9]+ (local|none)'
```
Expected, as measured on this branch: `10`, then `    18 local …` and `     8 none …`.

- [ ] **Step 2: Move**

```bash
mkdir -p scripts/docs
git mv scripts/export-diagrams.sh scripts/diagram-icons.py scripts/build-og-card.html scripts/docs/
```

- [ ] **Step 3: Correct the three depths**

| File:line | From | To |
|---|---|---|
| `scripts/docs/export-diagrams.sh:22` | `cd "$(dirname "$0")/.."` | `cd "$(dirname "$0")/../.."` |
| `scripts/docs/diagram-icons.py:36` | `ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))` | `ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))` |
| `scripts/docs/build-og-card.html:85` | `src="../website/static/images/ogenki-mark-white.svg"` | `src="../../website/static/images/ogenki-mark-white.svg"` |

Verify each line number before editing. Then grep all three files for any other `..`, `dirname`
or `scripts/` path, and fix it the same way.

- [ ] **Step 4: Rewrite the references**

```bash
cat > /tmp/moved-pr2-docs.txt <<'EOF'
export-diagrams.sh|docs/export-diagrams.sh
diagram-icons.py|docs/diagram-icons.py
build-og-card.html|docs/build-og-card.html
EOF
TARGETS=$(git grep -l -E 'scripts/(export-diagrams\.sh|diagram-icons\.py|build-og-card\.html)' \
  -- ':!docs/superpowers/plans' ':!docs/superpowers/specs' ':!docs/specs')
printf '%s\n' "$TARGETS" | wc -l      # expect 9
while IFS='|' read -r old new; do
  # shellcheck disable=SC2086
  sed -i --follow-symlinks "s|scripts/${old}|scripts/${new}|g" $TARGETS
done < /tmp/moved-pr2-docs.txt
```

The `scripts/docs/…` targets contain no `scripts/<old>` substring, so the loop is idempotent. Also
update the two rows in `scripts/AGENTS.md`'s `## The rest` table that name `diagram-icons.py
audit` and `export-diagrams.sh` by bare name: prefix them `docs/`.

- [ ] **Step 5: Verify**

```bash
python3 scripts/docs/diagram-icons.py audit 2>&1 | grep -cE '^[a-z0-9]'
python3 scripts/docs/diagram-icons.py audit 2>&1 | grep -E '^ +[0-9]+ (local|none)'
test -e "scripts/docs/../../website/static/images/ogenki-mark-white.svg" && echo "og-card img ok"
bash -n scripts/docs/export-diagrams.sh; echo "syntax=$?"
bash scripts/ci/tests/test-script-paths.sh | tail -1
task ci:links; task ci:doc-paths
for f in $(git ls-files -s | awk '$1=="120000"{print $4}'); do [ -L "$f" ] || echo "NOT A SYMLINK: $f"; done
```
Expected:
- the same `10` / `18 local` / `8 none` as Step 1;
- `og-card img ok`;
- `syntax=0`;
- the paths gate: `0 failed`. It checks `export-diagrams.sh`'s `cd … /../..` root;
- both doc gates pass;
- no `NOT A SYMLINK` line.

Do not run `export-diagrams.sh` for real. It needs the pinned drawio, and it rewrites every SVG.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "refactor(scripts): move the docs-site generators to scripts/docs/"
```

---

### Task 4: Move the day-2 operations scripts into `scripts/ops/{aws,gcp,k8s,demo}/`

13 files, 44 reference lines across 18 files. 11 of those lines are in `.tf`/`.tm.hcl`, and 8 of
those 11 are executed; the other 3 are comments. Seven
files also change name, so bare-name mentions go stale as well as paths.

**Files:**
- Move: the 13 files in the File Structure table marked Task 4
- Modify: four internal paths (Step 3), `scripts/ci/tests/test-cnpg-promote-seed.sh:25-26`, and
  every file Step 4 selects

**Interfaces:**
- Consumes: Task 1's gate.
- Produces: the `ops/aws|gcp|k8s|demo/` paths Task 7 indexes.

- [ ] **Step 1: Move**

```bash
mkdir -p scripts/ops/{aws,gcp,k8s,demo}
git mv scripts/aws-sweep-orphaned-volumes.sh   scripts/ops/aws/sweep-orphaned-volumes.sh
git mv scripts/aws-sweep-teardown-blockers.sh  scripts/ops/aws/sweep-teardown-blockers.sh
git mv scripts/aws-sweep-controller-orphans.sh scripts/ops/aws/sweep-controller-orphans.sh
git mv scripts/eks-prepare-destroy.sh          scripts/ops/aws/eks-prepare-destroy.sh
git mv scripts/eks-recycle-bootstrap-nodes.sh  scripts/ops/aws/eks-recycle-bootstrap-nodes.sh
git mv scripts/gcp-adopt-workforce-pool.sh     scripts/ops/gcp/adopt-workforce-pool.sh
git mv scripts/gcp-purge-dns-records.sh        scripts/ops/gcp/purge-dns-records.sh
git mv scripts/gcp-sweep-orphaned-disks.sh     scripts/ops/gcp/sweep-orphaned-disks.sh
git mv scripts/k8s-reclaim-csi-volumes.sh      scripts/ops/k8s/reclaim-csi-volumes.sh
git mv scripts/cnpg-prepare-restore.sh         scripts/ops/k8s/cnpg-prepare-restore.sh
git mv scripts/cnpg-promote-seed.sh            scripts/ops/k8s/cnpg-promote-seed.sh
git mv scripts/demo-load.sh                    scripts/ops/demo/load.sh
git mv scripts/cleanup-benchmark-images.sh     scripts/ops/demo/cleanup-benchmark-images.sh
```

- [ ] **Step 2: Watch the gate fail**

```bash
bash scripts/ci/tests/test-terramate-script-refs.sh | tail -1
bash scripts/ci/tests/test-script-paths.sh | tail -1
```
Expected: `87 … checked; 8 failed` (the executed references, which Step 4 fixes), then
`11 roots, 21 sources, 16 subjects checked; 4 failed`: the three `lib/` sources and
`test-cnpg-promote-seed.sh`'s subject, all fixed in Step 3. Both counts were measured by simulating
this move. A different number means the measurement is stale: report it.

- [ ] **Step 3: Correct the internal paths**

| File:line | From | To |
|---|---|---|
| `scripts/ops/gcp/sweep-orphaned-disks.sh:53` | `. "$(dirname "$0")/lib/gcloud-adc.sh"` | `. "$(dirname "$0")/../../lib/gcloud-adc.sh"` |
| `scripts/ops/gcp/purge-dns-records.sh:38` | `. "$(dirname "$0")/lib/gcloud-adc.sh"` | `. "$(dirname "$0")/../../lib/gcloud-adc.sh"` |
| `scripts/ops/k8s/cnpg-prepare-restore.sh:60` | `. "$(dirname "$0")/lib/gcloud-adc.sh"` | `. "$(dirname "$0")/../../lib/gcloud-adc.sh"` |
| `scripts/ops/aws/eks-prepare-destroy.sh` (~`:115`; find it by content) | `"$(dirname "$0")/k8s-reclaim-csi-volumes.sh" \|\| true` | `"$(dirname "$0")/../k8s/reclaim-csi-volumes.sh" \|\| true` |

The last row is the one no gate sees. Both files move into *different* directories, and the target
is renamed. It is a path passed to `exec`, not a `source`, so `test-script-paths.sh` cannot check
it. Update any `# shellcheck source=` directive next to the three `lib/` lines in the same way.

In `scripts/ci/tests/test-cnpg-promote-seed.sh`, delete the revisit comment at line 25 ("The
subject is still at scripts/ root. When it moves, this path moves with it.") and change line 26:

```bash
SCRIPT="$HERE/../../ops/k8s/cnpg-promote-seed.sh"
```

- [ ] **Step 4: Rewrite the references**

```bash
cat > /tmp/moved-pr2-ops.txt <<'EOF'
aws-sweep-orphaned-volumes.sh|ops/aws/sweep-orphaned-volumes.sh
aws-sweep-teardown-blockers.sh|ops/aws/sweep-teardown-blockers.sh
aws-sweep-controller-orphans.sh|ops/aws/sweep-controller-orphans.sh
eks-prepare-destroy.sh|ops/aws/eks-prepare-destroy.sh
eks-recycle-bootstrap-nodes.sh|ops/aws/eks-recycle-bootstrap-nodes.sh
gcp-adopt-workforce-pool.sh|ops/gcp/adopt-workforce-pool.sh
gcp-purge-dns-records.sh|ops/gcp/purge-dns-records.sh
gcp-sweep-orphaned-disks.sh|ops/gcp/sweep-orphaned-disks.sh
k8s-reclaim-csi-volumes.sh|ops/k8s/reclaim-csi-volumes.sh
cnpg-prepare-restore.sh|ops/k8s/cnpg-prepare-restore.sh
cnpg-promote-seed.sh|ops/k8s/cnpg-promote-seed.sh
demo-load.sh|ops/demo/load.sh
cleanup-benchmark-images.sh|ops/demo/cleanup-benchmark-images.sh
EOF
RE='scripts/(aws-sweep-orphaned-volumes|aws-sweep-teardown-blockers|aws-sweep-controller-orphans|eks-prepare-destroy|eks-recycle-bootstrap-nodes|gcp-adopt-workforce-pool|gcp-purge-dns-records|gcp-sweep-orphaned-disks|k8s-reclaim-csi-volumes|cnpg-prepare-restore|cnpg-promote-seed|demo-load|cleanup-benchmark-images)\.sh'
TARGETS=$(git grep -l -E "$RE" -- ':!docs/superpowers/plans' ':!docs/superpowers/specs' ':!docs/specs')
printf '%s\n' "$TARGETS" | wc -l      # expect 18
while IFS='|' read -r old new; do
  # shellcheck disable=SC2086
  sed -i --follow-symlinks "s|scripts/${old}|scripts/${new}|g" $TARGETS
done < /tmp/moved-pr2-ops.txt
```

No new path contains an old `scripts/<name>` substring, so the loop is idempotent.

- [ ] **Step 5: Fix the bare-name mentions the path rewrite cannot reach**

Eight files were renamed, and 13 mentions name them without a `scripts/` prefix. Prose, usage
strings and error messages would name a file that no longer exists:

```bash
git grep -n -E '(^|[^/a-z-])(aws-sweep-orphaned-volumes|aws-sweep-teardown-blockers|aws-sweep-controller-orphans|gcp-adopt-workforce-pool|gcp-purge-dns-records|gcp-sweep-orphaned-disks|k8s-reclaim-csi-volumes|demo-load)\.sh' \
  -- ':!docs/superpowers/plans' ':!docs/superpowers/specs' ':!docs/specs'
```

Before Step 4 this returned 13 lines. Change each remaining hit to the new name, or to the new
path where the text names a location. A script's own `Usage:` line should give its new path from
the repo root, e.g. `scripts/ops/gcp/purge-dns-records.sh`. Re-run the grep; expected: no output.

Also update the `scripts/AGENTS.md` `## The rest` row naming `eks-prepare-destroy.sh` to
`ops/aws/eks-prepare-destroy.sh`.

- [ ] **Step 6: Verify**

```bash
bash scripts/ci/tests/test-terramate-script-refs.sh | tail -1
bash scripts/ci/tests/test-script-paths.sh | tail -1
for f in scripts/ops/*/*.sh; do bash -n "$f" || echo "SYNTAX: $f"; done
test -x scripts/ops/aws/../k8s/reclaim-csi-volumes.sh && echo "eks->k8s call resolves"
task ci:test | tail -1
task ci:links; task ci:doc-paths
git diff --name-only HEAD -- opentofu | grep -E '\.(tf|tm\.hcl|tfvars)$'
(cd opentofu && terramate fmt --check && terramate list >/dev/null && echo "terramate ok")
for f in $(git ls-files -s | awk '$1=="120000"{print $4}'); do [ -L "$f" ] || echo "NOT A SYMLINK: $f"; done
```
Expected:
- the terramate gate: `87 … checked; 0 failed`;
- the paths gate: `0 failed`. It checks the three `lib/` sources;
- no `SYNTAX:` line;
- `eks->k8s call resolves`;
- `23 passed, 1 skipped, 0 failed`. `test-cnpg-promote-seed` passes against its new subject;
- both doc gates pass;
- the `git diff` lists only `.tm.hcl`/`.tf` files whose diff is a `scripts/<old>` → `scripts/<new>`
  substitution. Inspect each with `git diff -- <file>` and confirm no `${path.module}` line changed;
- `terramate ok`;
- no `NOT A SYMLINK` line.

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "refactor(scripts): move the day-2 operations scripts to scripts/ops/

aws/, gcp/, k8s/, demo/. The cloud prefix drops where it repeats the
directory. eks-prepare-destroy.sh's call to reclaim-csi-volumes.sh
crosses directories now and is corrected by hand: no gate sees a path
passed to exec."
```

---

### Task 5: Move the teardown scripts into `scripts/ops/teardown/`

Four files, 34 reference lines across 22 files, and **22 of those lines are in `.tm.hcl`**. This
is the destroy path: `terramate script run --reverse destroy` calls these from every stack. The task
is kept separate from Task 4 because a reviewer can reject one while approving the other.

**Files:**
- Move: `scripts/{destroy-stage2.sh,tofu-destroy-contained.sh,terramate-destroy-confirm.sh}` →
  `scripts/ops/teardown/`, and `scripts/teardown.sh` → `scripts/ops/teardown/teardown.sh`
- Modify: `teardown.sh`'s root depth (line 38)
- Modify: every file Step 3 selects

**Interfaces:**
- Consumes: Task 1's gate. Produces: `scripts/ops/teardown/`. Task 7 indexes `teardown.sh` and
  documents the other three.

- [ ] **Step 1: Move, and watch the gate fail**

```bash
mkdir -p scripts/ops/teardown
git mv scripts/destroy-stage2.sh scripts/tofu-destroy-contained.sh \
       scripts/terramate-destroy-confirm.sh scripts/ops/teardown/
git mv scripts/teardown.sh scripts/ops/teardown/teardown.sh
bash scripts/ci/tests/test-terramate-script-refs.sh | tail -1
bash scripts/ci/tests/test-script-paths.sh | tail -1
```
Expected: `87 … checked; 22 failed`, then `11 roots, 21 sources, 16 subjects checked; 1 failed`. That
one is `teardown.sh:38`, which resolves to `scripts/ops` instead of the repo root. Both counts were
measured by simulating this move.

- [ ] **Step 2: Correct `teardown.sh`'s depth, and check the other three**

| File:line | From | To |
|---|---|---|
| `scripts/ops/teardown/teardown.sh:38` | `ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"` | `ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"` |

Its `${ROOT}/scripts/aws-sweep-*.sh` calls were already rewritten to `${ROOT}/scripts/ops/aws/…` by
Task 4, since the file was still at `scripts/` root then. With `ROOT` corrected they resolve
unchanged.

```bash
grep -nE 'BASH_SOURCE|dirname|source |^\s*\. |\.\./' scripts/ops/teardown/{destroy-stage2,tofu-destroy-contained,terramate-destroy-confirm}.sh
```
The inventory found no self-resolved path in those three. If this grep shows one, correct its depth
as in Task 4 Step 3, and say so in the report.

- [ ] **Step 3: Rewrite the references**

```bash
cat > /tmp/moved-pr2-teardown.txt <<'EOF'
destroy-stage2.sh|ops/teardown/destroy-stage2.sh
tofu-destroy-contained.sh|ops/teardown/tofu-destroy-contained.sh
terramate-destroy-confirm.sh|ops/teardown/terramate-destroy-confirm.sh
teardown.sh|ops/teardown/teardown.sh
EOF
TARGETS=$(git grep -l -E 'scripts/(destroy-stage2|tofu-destroy-contained|terramate-destroy-confirm|teardown)\.sh' \
  -- ':!docs/superpowers/plans' ':!docs/superpowers/specs' ':!docs/specs')
printf '%s\n' "$TARGETS" | wc -l      # expect 22
while IFS='|' read -r old new; do
  # shellcheck disable=SC2086
  sed -i --follow-symlinks "s|scripts/${old}|scripts/${new}|g" $TARGETS
done < /tmp/moved-pr2-teardown.txt
```

- [ ] **Step 4: Verify**

Run the same block as Task 4 Step 6, plus:

```bash
for f in scripts/ops/teardown/*.sh; do bash -n "$f" || echo "SYNTAX: $f"; done
bash scripts/ci/tests/test-script-paths.sh | tail -1
for s in sweep-teardown-blockers sweep-controller-orphans sweep-orphaned-volumes; do
  test -e "scripts/ops/teardown/../../../scripts/ops/aws/$s.sh" && echo "teardown -> $s ok"; done
git grep -n -E 'scripts/(destroy-stage2|tofu-destroy-contained|terramate-destroy-confirm|teardown)\.sh' \
  -- ':!docs/superpowers/plans' ':!docs/superpowers/specs' ':!docs/specs'
```
Expected:
- the terramate gate: `87 … checked; 0 failed`;
- `terramate ok`;
- no `SYNTAX:` line;
- the paths gate: `11 roots, … 0 failed`;
- three `teardown -> … ok` lines: `teardown.sh`'s corrected `ROOT` still reaches the sweeps;
- the final `git grep`: no output.

The `scripts/teardown.sh` → `scripts/ops/teardown/teardown.sh` substitution is idempotent: the new
path does not contain the substring `scripts/teardown.sh`.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "refactor(scripts): move the teardown scripts to scripts/ops/teardown/

teardown.sh is the supported teardown entry point; the other three are
what terramate destroy calls (22 of the 34 references). The terramate
reference gate went from 22 failed to 0."
```

---

### Task 6: Move `check-rebased.sh` into `scripts/ci/`

It is the pre-push hook that refuses a branch behind `origin/main`. `scripts/README.md` already
describes `ci/` as "the gates CI runs, and you before pushing", and this hook is the second half
of that sentence. The owner chose `ci/` on 2026-09-21.

**Files:**
- Move: `scripts/check-rebased.sh` → `scripts/ci/check-rebased.sh`
- Modify: `.pre-commit-config.yaml:76`

- [ ] **Step 1: Move and repoint**

```bash
git mv scripts/check-rebased.sh scripts/ci/check-rebased.sh
sed -i --follow-symlinks 's|entry: scripts/check-rebased.sh|entry: scripts/ci/check-rebased.sh|' .pre-commit-config.yaml
git grep -n 'check-rebased\.sh' -- ':!docs/superpowers/plans' ':!docs/superpowers/specs' ':!docs/specs'
```
Expected: every hit names `scripts/ci/check-rebased.sh`. Fix any that does not. The inventory found
no self-resolved path in the script. Confirm with
`grep -nE 'BASH_SOURCE|dirname|source ' scripts/ci/check-rebased.sh`.

- [ ] **Step 2: Verify the hook still finds it**

```bash
pre-commit run check-rebased --hook-stage pre-push --all-files; echo "exit=$?"
```

While this branch is based on unmerged PR 1, the hook correctly **refuses**: it reports the branch
behind `origin/main` and exits nonzero. Both outcomes prove the path resolves. The only failure is
pre-commit reporting the executable as not found.

- [ ] **Step 3: Commit**

```bash
git add -A
git commit -m "refactor(scripts): move check-rebased.sh to scripts/ci/"
```

---

### Task 7: Index `ops/` and `docs/` in `task --list`, and document the layout

Spec criterion 2: `task --list` names every entry point with a one-line description. In
`ops/teardown/`, only `teardown.sh` is an entry point. Terramate destroy scripts call the other three,
so they are documented but not indexed.

**Files:**
- Create: `scripts/ops/tasks.yaml`, `scripts/docs/tasks.yaml`
- Modify: `taskfile.yaml`, `scripts/README.md`

**Interfaces:**
- Consumes: every path from Tasks 3–5.
- Produces: `task ops:<area>:<name>` and `task docs:<name>`. Arguments pass through with `--`, e.g.
  `task ops:gcp:purge-dns-records -- --help`.

Both files keep PR 1's two properties. They are **not** named `taskfile.yaml`, because go-task stops
at the first taskfile it finds walking up, so a nested `taskfile.yaml` would shadow the root one.
And every command is `{{.TASKFILE_DIR}}`-relative, so tasks work from any directory.

- [ ] **Step 1: Write `scripts/ops/tasks.yaml`**

```yaml
version: "3"

# The three helpers beside teardown.sh are not indexed: terramate destroy
# scripts call them. teardown.sh is the entry point.
tasks:
  teardown:
    desc: Tear the platform down — destroy past failures, sweep controller orphans, retry, verify against the cloud
    cmds: ["{{.TASKFILE_DIR}}/teardown/teardown.sh {{.CLI_ARGS}}"]
  aws:sweep-orphaned-volumes:
    desc: Delete EBS volumes the CSI driver created that nothing uses, after a cluster destroy
    cmds: ["{{.TASKFILE_DIR}}/aws/sweep-orphaned-volumes.sh {{.CLI_ARGS}}"]
  aws:sweep-teardown-blockers:
    desc: Clear the two things that reliably block tofu destroy on AWS
    cmds: ["{{.TASKFILE_DIR}}/aws/sweep-teardown-blockers.sh {{.CLI_ARGS}}"]
  aws:sweep-controller-orphans:
    desc: Sweep what in-cluster controllers left in AWS after a partial teardown (refuses while the cluster exists)
    cmds: ["{{.TASKFILE_DIR}}/aws/sweep-controller-orphans.sh {{.CLI_ARGS}}"]
  aws:eks-prepare-destroy:
    desc: Prepare an EKS cluster for destruction — suspends Flux, deletes every PVC
    cmds: ["{{.TASKFILE_DIR}}/aws/eks-prepare-destroy.sh {{.CLI_ARGS}}"]
  aws:eks-recycle-bootstrap-nodes:
    desc: Recycle EKS nodes whose ENIs predate Cilium
    cmds: ["{{.TASKFILE_DIR}}/aws/eks-recycle-bootstrap-nodes.sh {{.CLI_ARGS}}"]
  gcp:adopt-workforce-pool:
    desc: Make the workforce pool survive a teardown and rebuild
    cmds: ["{{.TASKFILE_DIR}}/gcp/adopt-workforce-pool.sh {{.CLI_ARGS}}"]
  gcp:purge-dns-records:
    desc: Empty a Cloud DNS managed zone so the zone can be destroyed
    cmds: ["{{.TASKFILE_DIR}}/gcp/purge-dns-records.sh {{.CLI_ARGS}}"]
  gcp:sweep-orphaned-disks:
    desc: Delete Persistent Disks GKE's CSI driver created that nothing uses
    cmds: ["{{.TASKFILE_DIR}}/gcp/sweep-orphaned-disks.sh {{.CLI_ARGS}}"]
  k8s:reclaim-csi-volumes:
    desc: Reclaim CSI-provisioned volumes before a cluster destroy (cloud-neutral)
    cmds: ["{{.TASKFILE_DIR}}/k8s/reclaim-csi-volumes.sh {{.CLI_ARGS}}"]
  k8s:cnpg-prepare-restore:
    desc: Clear a CNPG cluster's live WAL archive so a new cluster can start (off the normal path)
    cmds: ["{{.TASKFILE_DIR}}/k8s/cnpg-prepare-restore.sh {{.CLI_ARGS}}"]
  k8s:cnpg-promote-seed:
    desc: Promote a live CNPG archive to a frozen restore seed, or verify one
    cmds: ["{{.TASKFILE_DIR}}/k8s/cnpg-promote-seed.sh {{.CLI_ARGS}}"]
  demo:load:
    desc: Run an image-gallery load-generator scenario in-cluster
    cmds: ["{{.TASKFILE_DIR}}/demo/load.sh {{.CLI_ARGS}}"]
  demo:cleanup-benchmark-images:
    desc: Remove benchmark-generated images from the image-gallery database and bucket
    cmds: ["{{.TASKFILE_DIR}}/demo/cleanup-benchmark-images.sh {{.CLI_ARGS}}"]
```

Check each `desc` against its script's header comment. Where the header says something the desc
contradicts, the header wins: fix the desc.

- [ ] **Step 2: Write `scripts/docs/tasks.yaml`**

```yaml
version: "3"

# build-og-card.html is not a task: open it in a browser and screenshot it.
tasks:
  export-diagrams:
    desc: Regenerate every diagram SVG the site embeds from its .drawio source (needs the pinned drawio)
    cmds: ["{{.TASKFILE_DIR}}/export-diagrams.sh {{.CLI_ARGS}}"]
  diagram-icons:
    desc: The icon library behind docs/architecture/*.drawio — `task docs:diagram-icons -- audit`
    cmds: ["python3 {{.TASKFILE_DIR}}/diagram-icons.py {{.CLI_ARGS}}"]
```

- [ ] **Step 3: Include both from the root taskfile**

In `taskfile.yaml`, add two entries beside the existing `ci:` include, in the same shape:

```yaml
  ops:
    taskfile: scripts/ops/tasks.yaml
  docs:
    taskfile: scripts/docs/tasks.yaml
```

Leave `check` unchanged. No `ops:` or `docs:` task is a CI gate.

- [ ] **Step 4: Update `scripts/README.md`**

Replace the table and the closing sentence with:

```markdown
| Directory | Audience |
|---|---|
| `ci/` | the gates CI runs, and you before pushing. `task check` runs every one CI runs |
| `ci/tests/` | suites `run.sh` discovers: `test-*.sh` and `test-*.py` here, `*/test-*.py` one level down. A `# requires:` tool that is absent, or an exit 77, reports `SKIP` |
| `ops/aws/`, `ops/gcp/`, `ops/k8s/` | day-2 operations, run by a human. Some are also called from terramate destroy scripts |
| `ops/teardown/` | `teardown.sh` is the supported way to tear the platform down (`task ops:teardown`). The other three are called by terramate destroy scripts |
| `ops/demo/` | demo load generation and cleanup |
| `docs/` | docs-site generators, run by hand. `build-og-card.html` opens in a browser |
| `lib/` | sourced by the others, never run directly |

Apply-time provisioning scripts move to `provision/` in the next phase; until then they remain at
the root of `scripts/`.
```

- [ ] **Step 5: Verify**

```bash
task --list | grep -cE '^\* (ops|docs):'
(cd scripts/ops/aws && task ops:gcp:purge-dns-records -- --help >/dev/null 2>&1; echo "from-subdir exit=$?")
task docs:diagram-icons -- audit 2>&1 | grep -E '^ +[0-9]+ (local|none)'
task ci:links
```
Expected:
- `16`;
- the `--help` call: exit 0, or the script's own usage exit code. Confirm by reading its argument
  parsing that `--help` only prints usage. If it does anything else, use a different read-only
  proof and say which;
- `18 local` / `8 none`;
- links pass.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat(task): index ops/ and docs/ in task --list

Spec criterion 2: every entry point has a one-line description.
Only teardown.sh is indexed in ops/teardown/; terramate calls the rest."
```

---

### Task 8: Rebase onto `main`, full verification, and the PR

The controller runs this inline. It only starts **after #2061 merges**.

- [ ] **Step 1: Drop PR 1's commits and rebase**

PR 1 squash-merges, so its 30 commits on this branch become one commit on `main` with a different
SHA. Rebase only this PR's own commits:

```bash
git fetch origin
git rebase --onto origin/main 7ec01df5
git log --oneline origin/main..HEAD      # only this plan's commits
```

`7ec01df5` is PR 1's head when this branch was cut. If #2061 gained commits after 2026-09-21, use
its final head instead: `gh pr view 2061 --json headRefOid`.

- [ ] **Step 2: Run the whole gate set, once, alone in this checkout**

```bash
task check
bash scripts/ci/tests/test-terramate-script-refs.sh
```
Expected:
- `task check` exits 0, with the rendered resource count, `23 passed, 1 skipped, 0 failed`, and all
  six gates passing;
- the terramate gate: `87 … checked; 0 failed`.

Cite both verbatim.

- [ ] **Step 3: Prove the layout**

```bash
ls scripts/
```
Expected:
- directories: `ci docs lib ops zitadel-actions`;
- files: `AGENTS.md CLAUDE.md README.md tasks.yaml`;
- eight files still at root: seven that PR 3 moves (`helm-release-present.sh openbao-adopt-jwt-mount.sh
  openbao-config.sh secret-store.sh tm-provisioner.sh zitadel-idp.sh zitadel-oidc-clients.sh`), plus
  the `openbao-snapshot.sh` symlink, whose home is unsettled.

Criterion 1 ("no loose executables") is met only after PR 3. Say so in the PR body.

- [ ] **Step 4: The rest of the evidence**

```bash
./scripts/ci/validate-vmrules.sh
(cd opentofu && terramate fmt --check && terramate list | wc -l)
shellcheck -x -S warning $(find ./scripts \( -type f -o -type l \) -name "*.sh")
for f in $(git ls-files -s | awk '$1=="120000"{print $4}'); do [ -L "$f" ] || echo "NOT A SYMLINK: $f"; done
```
Expected: each exits 0, and no `NOT A SYMLINK` line.

- [ ] **Step 5: The owner-run preview (a merge gate, not a CI gate)**

`terramate script run preview` needs a live cluster, because Helm reads the endpoint at plan time.
The owner decided on 2026-09-21 that the PR may open on the static gate, and that the preview runs
before merge, whenever a cluster is next up:

```bash
cd opentofu
TM_CLOUD=aws terramate script run preview
TM_CLOUD=gcp terramate script run preview
```

The PR body carries this as an unchecked merge checkbox. **Do not merge with it unchecked.**

- [ ] **Step 6: Open the PR**

Follow `.agents/skills/create-pr/SKILL.md`. The body must carry:
- links to the design, PR 1's plan, and this plan;
- a mermaid diagram of before/after;
- the cited output from Steps 2–4;
- the preview merge checkbox from Step 5;
- a statement that PR 3 (`provision/`) is still pending;
- a note that the design's Deletions table was overruled for `teardown.sh` and
  `aws-sweep-controller-orphans.sh`: they moved instead (owner decision, 2026-09-21).

---

## Self-Review

- **Spec coverage.** The design's PR 2 row names `ops/` and `docs/`: Tasks 3–5. Its evidence column
  names a preview on both clouds: Task 8 Step 5, as a merge gate with the owner's decision, backed
  in CI by Task 1. Its Deletions table: overruled for two live tools (owner, 2026-09-21, Task 2); its other two
  entries are already absent. Criterion 2: Task 7. `check-rebased.sh` post-dates
  the design; Task 6 carries the owner's placement.
- **Measured, not copied.** The design says PR 2 has 77 live references. Measured: 147 matches
  across the 18 moving files, 123 excluding a script's mention of itself. Each task's rewrite
  expects its own measured count (9, 18, 22 files), not the design's.
- **Exact values are consistent across tasks:** 87 references checked, floor 80; failure counts
  8 (Task 4) and 22 (Task 5), both measured by simulating the move; suite count 23.
