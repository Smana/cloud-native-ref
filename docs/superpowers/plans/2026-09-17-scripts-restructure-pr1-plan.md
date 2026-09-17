# scripts/ restructure — PR 1 (`ci/`, taskfile, gates) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move the CI-facing half of `scripts/` into `scripts/ci/`, index every entry point with a
`taskfile.yaml`, and replace `ci.yaml`'s hand-maintained test list with a runner that discovers
suites and honours a `# requires:` header — all underneath a new gate that proves no script's
self-resolved paths broke in the move.

**Architecture:** Three safety nets are built *first, on the unmoved tree* (taskfile wiring, the
`test-script-paths.sh` gate, the discovering runner), so each is provably green before anything
relocates. Only then do the files move, one directory per commit, re-running the gate after each.
go-task is an index, never a dependency: every task body is a one-line call to a script that still
runs standalone.

**Tech Stack:** bash, go-task v3 (via `mise.toml`), GitHub Actions, Python 3 (existing
`flux-schema/` tooling untouched).

**Spec:** [`docs/superpowers/specs/2026-09-17-scripts-restructure-design.md`](../specs/2026-09-17-scripts-restructure-design.md)

## Global Constraints

- **Job names in `.github/workflows/ci.yaml` must not change.** They are required-check contexts
  on `main` (six required checks, `enforce_admins`). Renaming one silently makes the required
  check "did not run", which is not "passed".
- **`scripts/openbao-snapshot.sh` is a symlink** to `../container-images/openbao-snapshot/openbao-snapshot.sh`.
  It does not move in this PR. The ShellCheck find in `ci.yaml` must keep `\( -type f -o -type l \)`.
- **Never anchor a path rewrite on the bare token `scripts/`.** `opentofu/{aws,gcp}/openbao/cluster/scripts/`
  are module-local directories reached via `${path.module}/scripts/`. Anchor on `./scripts/<name>`
  or on an enumerated basename.
- **The dated archive is not rewritten** — `docs/superpowers/plans/`, `docs/superpowers/specs/`,
  `docs/specs/`. 887 references live there and stay as written.
- **Repository metadata is English.** Commits, PR title and body.
- **Never co-author commits**, no generated-with attribution lines.
- Work happens in the existing worktree `.claude/worktrees/scripts-restructure` on branch
  `worktree-scripts-restructure`.

---

## File Structure

**Created:**

| Path | Responsibility |
|---|---|
| `taskfile.yaml` | repo-root index; `check` aggregate; includes `scripts/taskfile.yaml` under the `ci:` namespace |
| `scripts/taskfile.yaml` | one task per CI entry point, each a single-line call |
| `scripts/ci/tests/run.sh` | globs `test-*.sh`, reads `# requires:`, runs or skips, prints a summary |
| `scripts/ci/tests/test-script-paths.sh` | the gate: self-resolved roots, `source` targets, subject defaults |
| `scripts/README.md` | five-line directory index |
| `website/content/docs/decisions/0039-go-task-as-the-entry-point.md` | ADR |
| `docs/superpowers/plans/README.md`, `docs/specs/README.md` | stale-path notes |

**Moved** (`git mv`, depth corrections in the same commit):

| From | To |
|---|---|
| `scripts/validate-*.sh`, `scripts/verify-doc-paths.sh` (8 files) | `scripts/ci/` |
| `scripts/flux-schema/{render-bundle.py,check-substitution.py,gen-catalog.sh,render-both.sh,diff-bundles.py,preflight.sh,yamlcompat.py,vendored-crds/}` | `scripts/ci/flux-schema/` |
| `scripts/flux-schema/test-{render-bundle,check-substitution}.py` | `scripts/ci/tests/flux-schema/` |
| `scripts/test-*.sh` (20 files) | `scripts/ci/tests/` |
| `scripts/alertmanager-fixtures/`, `scripts/vector-vrl-tests/` | `scripts/ci/tests/` |

**Modified:** `mise.toml`, `.github/workflows/ci.yaml`, `.doc-claims.yaml`, `AGENTS.md`,
`scripts/AGENTS.md`, `observability/AGENTS.md`, `clusters/AGENTS.md`, `infrastructure/AGENTS.md`,
`docs/architecture/AGENTS.md`, `.agents/skills/ship-it/references/evidence.md`,
`.claude/agents/kubernetes-reviewer.md`, and the `website/content/` pages listed in Task 8.

**Not touched in this PR:** everything destined for `ops/`, `provision/`, `docs/`; `scripts/lib/`.

---

### Task 1: go-task installed and wired, calling the tree as it stands

Proves the runner works before it is asked to point at moved files. At the end of this task
`task check` runs the same three gates CI runs, against the current flat layout.

**Files:**
- Modify: `mise.toml`
- Create: `taskfile.yaml`
- Create: `scripts/taskfile.yaml`

**Interfaces:**
- Produces: task names `ci:validate`, `ci:test`, `ci:links`, `ci:vmrules`, `ci:alertmanager`,
  `ci:doc-claims`, `ci:doc-paths`, `ci:idp-topology`, and the root aggregate `check`. Tasks 3, 9
  and 10 call these by name.

- [ ] **Step 1: Add go-task to the tool pins**

Append to the `[tools]` table in `mise.toml`, after the `kustomize` line:

```toml
# Task runner (taskfile.yaml). Pinned here rather than installed separately so
# the jdx/mise-action already in every CI job picks it up with no new action.
task = "3"
```

- [ ] **Step 2: Verify mise resolves it**

Run: `mise install task && mise exec -- task --version`
Expected: a `3.x` version string, exit 0.

- [ ] **Step 3: Write the repo-root taskfile**

Create `taskfile.yaml`:

```yaml
version: "3"

includes:
  ci:
    taskfile: scripts/taskfile.yaml
    dir: .

tasks:
  default:
    cmds: [{task: "--list"}]

  check:
    desc: Everything CI gates, run locally
    cmds:
      - {task: "ci:validate"}
      - {task: "ci:test"}
      - {task: "ci:links"}
```

- [ ] **Step 4: Write the scripts taskfile**

Create `scripts/taskfile.yaml`. Paths are repo-root-relative because the include sets `dir: .`;
they are updated to their `ci/` form in Tasks 5–7.

```yaml
version: "3"

tasks:
  validate:
    desc: Render the repo as Flux would, then gate it (schema + polaris)
    cmds: ["./scripts/validate-manifests.sh"]

  test:
    desc: Run every shell test suite the environment can satisfy
    cmds: ["./scripts/test-runner-placeholder.sh"]

  links:
    desc: Resolve every relative Markdown link
    cmds: ["./scripts/validate-links.sh"]

  vmrules:
    desc: Parse the PromQL in every repo-authored VMRule
    cmds: ["./scripts/validate-vmrules.sh"]

  alertmanager:
    desc: Render the Slack templates against the fixture payloads
    cmds: ["./scripts/validate-alertmanager-templates.sh"]

  doc-claims:
    desc: Check documentation claims against configuration
    cmds: ["./scripts/validate-doc-claims.sh"]

  doc-paths:
    desc: Check every backticked repository path in the docs site exists
    cmds: ["./scripts/verify-doc-paths.sh"]

  idp-topology:
    desc: Assert exactly one cloud hosts ZITADEL (ADR-0027)
    cmds: ["./scripts/validate-idp-topology.sh"]
```

The `test` task points at a file that does not exist yet. That is deliberate — Task 3 creates it
and repoints this line. Do not invent a stopgap.

- [ ] **Step 5: Verify the index and one real gate**

Run: `task --list`
Expected: nine task names with their descriptions, `check` among them.

Run: `task ci:links`
Expected: `==> All relative Markdown links resolve (0 allowlisted).`, exit 0.

- [ ] **Step 6: Commit**

```bash
git add mise.toml taskfile.yaml scripts/taskfile.yaml
git commit -m "build: add go-task as the local and CI entry point

Every task body is a single-line call to a script that still runs
standalone, so the scripts stay liftable into another repo. The ci:test
task points at a runner that Task 3 creates."
```

---

### Task 2: The `test-script-paths.sh` gate

The gate ships before anything moves, so Tasks 5–7 relocate files underneath a check that is
already green. It is written TDD-first: a fixture tree with a deliberately wrong depth must make
it fail before the real tree is allowed to make it pass.

**Files:**
- Create: `scripts/ci/tests/test-script-paths.sh`
- Test: the suite is its own test; its negative case runs against a fixture under `$TMPDIR`

**Interfaces:**
- Consumes: nothing.
- Produces: `scripts/ci/tests/test-script-paths.sh`, honouring `SCRIPT_PATHS_ROOT` (default
  `<repo>/scripts`) so it can be aimed at a fixture. Exit 0 on success, 1 on any failure.
  Tasks 5, 6 and 7 run it after every move.

- [ ] **Step 1: Write the failing test — the fixture that must be rejected**

Create the fixture and expectation as a scratch script first, so the negative case exists before
the gate does. Run this in your shell:

```bash
FIX=$(mktemp -d)
mkdir -p "$FIX/scripts/deep/deeper" "$FIX/scripts/lib"
touch "$FIX/AGENTS.md"; mkdir -p "$FIX/opentofu"
# A script one level too deep that still uses a single "/..": lands on scripts/,
# not the repo root. This is EXACTLY what a naive `git mv` produces.
cat > "$FIX/scripts/deep/wrong-depth.sh" <<'EOF'
#!/usr/bin/env bash
cd "$(dirname "$0")/.." || exit 1
EOF
# A source line whose target does not exist.
cat > "$FIX/scripts/deep/missing-source.sh" <<'EOF'
#!/usr/bin/env bash
. "$(dirname "$0")/lib/nope.sh"
EOF
echo "$FIX"
```

- [ ] **Step 2: Run the not-yet-existing gate against the fixture, to verify it fails**

Run: `SCRIPT_PATHS_ROOT="$FIX/scripts" bash scripts/ci/tests/test-script-paths.sh`
Expected: FAIL — `bash: scripts/ci/tests/test-script-paths.sh: No such file or directory`, exit 127.

- [ ] **Step 3: Write the gate**

Create `scripts/ci/tests/test-script-paths.sh`, `chmod +x`:

```bash
#!/usr/bin/env bash
# requires:
#
# Two things break silently when a script moves, and neither is an external
# reference. The "/.." depth it uses to reach the repo root: a wrong count makes
# `cd` SUCCEED at the wrong directory, so every relative path after it is quietly
# wrong. And the relative path it sources a library, or reaches its test subject,
# through. Six of the nine lib/-sourcing scripts run during a terramate apply, so
# that failure lands mid-deploy with no CI gate in front of it.
#
# SCRIPT_PATHS_ROOT exists so this suite can be aimed at a fixture tree and
# proved to fail. Without a negative case a green gate means nothing.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../../.." && pwd)"
SCRIPTS="${SCRIPT_PATHS_ROOT:-$REPO_ROOT/scripts}"
MARKER_ROOT="$(cd "$SCRIPTS/.." && pwd)"

fails=0 n_roots=0 n_sources=0 n_subjects=0

fail() { printf 'FAIL  %s\n' "$*" >&2; fails=$((fails + 1)); }
rel()  { printf '%s' "${1#"$MARKER_ROOT"/}"; }

# The repo root is whatever holds both of these. Two markers, not one: a lone
# AGENTS.md also sits in half the subdirectories.
is_repo_root() { [ -f "$1/AGENTS.md" ] && [ -d "$1/opentofu" ]; }

while IFS= read -r script; do
  dir="$(cd "$(dirname "$script")" && pwd)"

  # 1. Self-resolved repo roots.
  while IFS=: read -r lineno line; do
    ups="$(printf '%s' "$line" | grep -oE '(/\.\.)+' | head -1)"
    [ -n "$ups" ] || continue
    n_roots=$((n_roots + 1))
    if ! resolved="$(cd "$dir$ups" 2>/dev/null && pwd)"; then
      fail "$(rel "$script"):$lineno — '$dir$ups' resolves nowhere"
      continue
    fi
    is_repo_root "$resolved" \
      || fail "$(rel "$script"):$lineno — resolves to '$resolved', which is not the repo root"
  done < <(grep -nE 'dirname.*(BASH_SOURCE|\$0).*(/\.\.)+' "$script" 2>/dev/null || true)

  # 2. source / . targets.
  while IFS=: read -r lineno line; do
    target="$(printf '%s' "$line" | sed -nE 's/^[[:space:]]*(\.|source)[[:space:]]+"([^"]+)".*/\2/p')"
    [ -n "$target" ] || continue
    e="$target"
    e="${e//\$(dirname \"\$0\")/$dir}"
    e="${e//\$(dirname \"\${BASH_SOURCE[0]}\")/$dir}"
    e="${e//\$\{HERE\}/$dir}"; e="${e//\$HERE/$dir}"
    e="${e//\$\{SCRIPT_DIR\}/$dir}"; e="${e//\$SCRIPT_DIR/$dir}"
    e="${e//\$\{REPO_ROOT\}/$MARKER_ROOT}"; e="${e//\$REPO_ROOT/$MARKER_ROOT}"
    # Anything still holding a variable cannot be checked statically. Skipping is
    # honest; the counts printed at the end make a drop in coverage visible.
    case "$e" in *'$'*) continue ;; esac
    n_sources=$((n_sources + 1))
    [ -f "$e" ] || fail "$(rel "$script"):$lineno — sources a missing file: $e"
  done < <(grep -nE '^[[:space:]]*(\.|source)[[:space:]]+"' "$script" 2>/dev/null || true)

  # 3. Test-subject defaults: SRC="${OVERRIDE:-$HERE/subject.sh}" and friends.
  while IFS=: read -r lineno line; do
    while IFS= read -r ref; do
      sub="${ref#*\}/}"; sub="${sub#*/}"
      n_subjects=$((n_subjects + 1))
      [ -e "$dir/$sub" ] \
        || fail "$(rel "$script"):$lineno — points at a missing file: $dir/$sub"
    done < <(printf '%s' "$line" \
      | grep -oE '\$\{?(HERE|SCRIPT_DIR)\}?/[A-Za-z0-9._/-]+\.(sh|py)' || true)
  done < <(grep -nE '\$\{?(HERE|SCRIPT_DIR)\}?/[A-Za-z0-9._/-]+\.(sh|py)' "$script" 2>/dev/null || true)

done < <(find "$SCRIPTS" \( -type f -o -type l \) -name '*.sh' | sort)

printf '%d roots, %d sources, %d subjects checked; %d failed\n' \
  "$n_roots" "$n_sources" "$n_subjects" "$fails"
[ "$fails" -eq 0 ]
```

- [ ] **Step 4: Run against the fixture to verify it FAILS**

Run: `SCRIPT_PATHS_ROOT="$FIX/scripts" bash scripts/ci/tests/test-script-paths.sh; echo "exit=$?"`
Expected: two `FAIL` lines — one naming `wrong-depth.sh` resolving to the fixture's `scripts`
directory, one naming `missing-source.sh` and `lib/nope.sh` — then `exit=1`.

If it exits 0, the gate is not testing anything. Do not proceed.

- [ ] **Step 5: Run against the real tree to verify it PASSES**

Run: `bash scripts/ci/tests/test-script-paths.sh; echo "exit=$?"`
Expected: `11 roots, 14 sources, 16 subjects checked; 0 failed` (exact counts may differ by one or
two; **`0 failed` is the assertion**), `exit=0`.

If the real tree fails here, something is already broken — stop and report it rather than
adjusting the gate to accommodate it.

- [ ] **Step 6: Clean up the fixture and commit**

```bash
rm -rf "$FIX"
git add scripts/ci/tests/test-script-paths.sh
git commit -m "test(ci): gate every script's self-resolved paths

42 of 55 scripts compute paths from where they sit, so a git mv breaks
them whether or not every external reference is rewritten. A wrong /..
depth makes cd succeed at the wrong directory, and six of the nine
lib/-sourcing scripts run during a terramate apply.

Ships before anything moves, so the restructure relocates files
underneath a check that already passes."
```

---

### Task 3: The discovering test runner

**Files:**
- Create: `scripts/ci/tests/run.sh`
- Modify: `scripts/taskfile.yaml` (repoint `test:`)
- Modify: the 20 `scripts/test-*.sh` files (add `# requires:` where non-empty)

**Interfaces:**
- Consumes: `task` from Task 1; `test-script-paths.sh` from Task 2.
- Produces: `scripts/ci/tests/run.sh`, honouring `TESTS_DIR` (default: its own directory). Prints
  `PASS`/`SKIP`/`FAIL` per suite and a `N passed, N skipped, N failed` summary. Exit 1 if any
  suite failed; a skip is **not** a failure. Task 9 replaces `ci.yaml`'s inline loop with it.

- [ ] **Step 1: Write the failing test — a fixture directory the runner must classify**

```bash
FIX=$(mktemp -d)
printf '#!/usr/bin/env bash\nexit 0\n' > "$FIX/test-green.sh"
printf '#!/usr/bin/env bash\necho "boom" >&2\nexit 1\n' > "$FIX/test-red.sh"
printf '#!/usr/bin/env bash\n# requires: definitely-not-a-real-binary\nexit 0\n' > "$FIX/test-skipped.sh"
echo "$FIX"
```

- [ ] **Step 2: Run the not-yet-existing runner, to verify it fails**

Run: `TESTS_DIR="$FIX" bash scripts/ci/tests/run.sh`
Expected: FAIL — `No such file or directory`, exit 127.

- [ ] **Step 3: Write the runner**

Create `scripts/ci/tests/run.sh`, `chmod +x`:

```bash
#!/usr/bin/env bash
# Runs every suite in this directory, honouring each one's `# requires:` header.
#
# Discovery rather than a list, because the list was the bug: seven ZITADEL
# suites existed and went unrun for months, since writing a suite and getting CI
# to run it were separate acts and the second one got forgotten. A suite added
# here is covered by the commit that adds it.
#
# A skip is printed, never silent. "It didn't run" and "it passed" are the two
# outcomes a CI log must never conflate.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS="${TESTS_DIR:-$HERE}"

pass=0 skip=0 fail=0 rc=0

for t in "$TESTS"/test-*.sh; do
  [ -e "$t" ] || continue
  name="$(basename "$t" .sh)"

  # First `# requires:` line only. Absent or empty means bash and jq, which CI
  # and every developer machine already have.
  missing=""
  for tool in $(sed -n 's/^# requires:[[:space:]]*//p' "$t" | head -1); do
    command -v "$tool" >/dev/null 2>&1 || missing="$missing $tool"
  done
  if [ -n "$missing" ]; then
    printf 'SKIP  %-42s missing:%s\n' "$name" "$missing"
    skip=$((skip + 1))
    continue
  fi

  SECONDS=0
  if out="$(bash "$t" 2>&1)"; then
    printf 'PASS  %-42s (%ds)\n' "$name" "$SECONDS"
    pass=$((pass + 1))
  else
    printf 'FAIL  %-42s (%ds)\n' "$name" "$SECONDS"
    # The output, not just the name: a red check whose body is one word costs a
    # local re-run to learn anything from.
    printf '%s\n' "$out" | sed 's/^/      /'
    fail=$((fail + 1))
    rc=1
  fi
done

printf '%d passed, %d skipped, %d failed\n' "$pass" "$skip" "$fail"
exit "$rc"
```

- [ ] **Step 4: Run against the fixture to verify all three outcomes**

Run: `TESTS_DIR="$FIX" bash scripts/ci/tests/run.sh; echo "exit=$?"`
Expected, in this order:

```
PASS  test-green                                  (0s)
FAIL  test-red                                    (0s)
      boom
SKIP  test-skipped                                missing: definitely-not-a-real-binary
1 passed, 1 skipped, 1 failed
exit=1
```

The assertion is that the skip did **not** count as a pass and did **not** set the exit code.

- [ ] **Step 5: Add the `# requires:` headers**

Insert as line 2 of each file (directly under the shebang). Only these four are non-empty — every
other suite stubs its external calls onto `PATH` and needs nothing:

```bash
# scripts/test-flux-schema.sh
# requires: flux helm kustomize python3

# scripts/test-vector-vrl.sh
# requires: vector

# scripts/test-openbao-pki-verify.sh
# requires: openssl

# scripts/test-validate-idp-topology.sh
# requires: kustomize
```

`test-openbao-pki-verify.sh` generates real throwaway CAs rather than stubbing `openssl` — a stub
would be assuming the answer under test. `test-validate-idp-topology.sh` executes the real
validator, which shells out to `kustomize`.

- [ ] **Step 6: Run the runner against the real suites, still in their flat location**

Run: `TESTS_DIR=scripts bash scripts/ci/tests/run.sh; echo "exit=$?"`
Expected: 20 lines. `PASS` for 18, and either `PASS` or `SKIP  … missing: …` for
`test-flux-schema` and `test-vector-vrl` depending on what is installed locally. Summary line, and
`exit=0`.

If any suite prints `FAIL`, it is a pre-existing failure — record it and stop; do not proceed with
a red baseline.

- [ ] **Step 7: Repoint the taskfile**

In `scripts/taskfile.yaml`, replace the `test:` task body:

```yaml
  test:
    desc: Run every shell test suite the environment can satisfy
    cmds: ["TESTS_DIR=scripts ./scripts/ci/tests/run.sh"]
```

- [ ] **Step 8: Verify through task**

Run: `task ci:test; echo "exit=$?"`
Expected: same output as Step 6, `exit=0`.

- [ ] **Step 9: Clean up and commit**

```bash
rm -rf "$FIX"
git add scripts/ci/tests/run.sh scripts/taskfile.yaml scripts/test-*.sh
git commit -m "test(ci): discover suites and honour a requires header

Replaces a hand-maintained list of 11 with a glob over all 20. Each suite
declares what it needs on PATH; the runner skips what is absent and says
which tool was missing, so 'did not run' can never read as 'passed'."
```

---

### Task 4: Move the validators into `scripts/ci/`

**Files:**
- Move: 8 files from `scripts/` to `scripts/ci/`
- Modify: `scripts/ci/validate-manifests.sh` (depth + 4 sibling calls),
  `scripts/ci/validate-links.sh`, `scripts/ci/validate-doc-claims.sh`,
  `scripts/ci/validate-alertmanager-templates.sh`, `scripts/ci/validate-vmrules.sh`,
  `scripts/ci/verify-doc-paths.sh` (depth), `scripts/taskfile.yaml`

**Interfaces:**
- Consumes: the gate from Task 2.
- Produces: `scripts/ci/validate-*.sh`, `scripts/ci/verify-doc-paths.sh`. Tasks 5–9 reference
  these paths.

- [ ] **Step 1: Move the files**

```bash
mkdir -p scripts/ci
git mv scripts/validate-alertmanager-templates.sh scripts/validate-doc-claims.sh \
       scripts/validate-idp-topology.sh scripts/validate-links.sh \
       scripts/validate-manifests.sh scripts/validate-vector-vrl.sh \
       scripts/validate-vmrules.sh scripts/verify-doc-paths.sh \
       scripts/ci/
```

- [ ] **Step 2: Run the gate to verify it now FAILS**

Run: `bash scripts/ci/tests/test-script-paths.sh; echo "exit=$?"`
Expected: six `FAIL` lines, each of the form
`scripts/ci/validate-links.sh:36 — resolves to '<repo>/scripts', which is not the repo root`,
then `exit=1`.

This is the gate doing its job. If it exits 0 after a move, the gate is broken — stop.

- [ ] **Step 3: Correct the depths**

Each of these moved one level deeper, so `/..` becomes `/../..`:

```bash
sed -i 's|cd "$(dirname "$0")/\.\."|cd "$(dirname "$0")/../.."|' \
  scripts/ci/validate-links.sh \
  scripts/ci/validate-alertmanager-templates.sh \
  scripts/ci/validate-doc-claims.sh \
  scripts/ci/validate-vmrules.sh \
  scripts/ci/verify-doc-paths.sh

sed -i 's|REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE\[0\]}")/\.\." \&\& pwd)"|REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." \&\& pwd)"|' \
  scripts/ci/validate-manifests.sh
```

- [ ] **Step 4: Fix `validate-manifests.sh`'s four sibling calls**

It `cd`s to `REPO_ROOT` first, so these are repo-root-relative — only the `scripts/` segment
changes. Edit these five lines in `scripts/ci/validate-manifests.sh`:

| Line | From | To |
|---|---|---|
| 21 | `source "${REPO_ROOT}/scripts/flux-schema/preflight.sh"` | `source "${REPO_ROOT}/scripts/ci/flux-schema/preflight.sh"` |
| 40 | `python3 scripts/flux-schema/check-substitution.py` | `python3 scripts/ci/flux-schema/check-substitution.py` |
| 48 | `./scripts/validate-vmrules.sh` | `./scripts/ci/validate-vmrules.sh` |
| 51 | `./scripts/flux-schema/gen-catalog.sh > /dev/null` | `./scripts/ci/flux-schema/gen-catalog.sh > /dev/null` |
| 55 | `python3 scripts/flux-schema/render-bundle.py "${BUNDLE_DIR}"` | `python3 scripts/ci/flux-schema/render-bundle.py "${BUNDLE_DIR}"` |
| 68 | `./scripts/validate-alertmanager-templates.sh` | `./scripts/ci/validate-alertmanager-templates.sh` |

Also update the shellcheck directive on line 20 to `# shellcheck source=./flux-schema/preflight.sh`
— it is already relative to the file, so it stays correct; verify rather than change it.

The `flux-schema/` paths point at Task 5's destination and will not resolve until that task lands.
That is expected; Step 5 below checks only the depths.

- [ ] **Step 5: Run the gate to verify it PASSES again**

Run: `bash scripts/ci/tests/test-script-paths.sh; echo "exit=$?"`
Expected: `… 0 failed`, `exit=0`.

- [ ] **Step 6: Verify two validators that do not depend on Task 5**

Run: `./scripts/ci/validate-links.sh`
Expected: `==> All relative Markdown links resolve (0 allowlisted).`, exit 0.

Run: `./scripts/ci/verify-doc-paths.sh`
Expected: exit 0. (It will fail if any `website/content/` page still cites a moved path — that is
Task 8's work. If it fails here, record the failing paths and continue; Step 8 of Task 8 is where
it must go green.)

- [ ] **Step 7: Update the taskfile paths**

In `scripts/taskfile.yaml`, prefix `ci/` on every validator path: `./scripts/ci/validate-manifests.sh`,
`./scripts/ci/validate-links.sh`, `./scripts/ci/validate-vmrules.sh`,
`./scripts/ci/validate-alertmanager-templates.sh`, `./scripts/ci/validate-doc-claims.sh`,
`./scripts/ci/verify-doc-paths.sh`, `./scripts/ci/validate-idp-topology.sh`.

- [ ] **Step 8: Commit**

```bash
git add -A scripts taskfile.yaml
git commit -m "refactor(scripts): move the CI validators to scripts/ci/

Depths corrected in the same commit as the move, and test-script-paths.sh
proves every self-resolved root still lands on the repo root."
```

---

### Task 5: Move `flux-schema/` into `scripts/ci/flux-schema/`

**Files:**
- Move: `scripts/flux-schema/` (except the two `test-*.py`) to `scripts/ci/flux-schema/`
- Modify: `scripts/ci/flux-schema/gen-catalog.sh` (depth), `scripts/ci/flux-schema/render-both.sh`,
  `.github/workflows/ci.yaml` (the `render-diff` job's call)

**Interfaces:**
- Consumes: Task 4's `scripts/ci/validate-manifests.sh`, which already points here.
- Produces: `scripts/ci/flux-schema/{render-bundle.py,check-substitution.py,gen-catalog.sh,render-both.sh,preflight.sh,diff-bundles.py,yamlcompat.py,vendored-crds/}`.

- [ ] **Step 1: Move everything except the two test files**

```bash
mkdir -p scripts/ci/flux-schema
git mv scripts/flux-schema/render-bundle.py scripts/flux-schema/check-substitution.py \
       scripts/flux-schema/gen-catalog.sh scripts/flux-schema/render-both.sh \
       scripts/flux-schema/diff-bundles.py scripts/flux-schema/preflight.sh \
       scripts/flux-schema/yamlcompat.py scripts/flux-schema/vendored-crds \
       scripts/ci/flux-schema/
```

- [ ] **Step 2: Run the gate to verify it fails on the new depth**

Run: `bash scripts/ci/tests/test-script-paths.sh; echo "exit=$?"`
Expected: a `FAIL` naming `scripts/ci/flux-schema/gen-catalog.sh:31` resolving to `<repo>/scripts`,
`exit=1`.

- [ ] **Step 3: Correct the depth**

`gen-catalog.sh` already used `/../..` because it sat one level deep; it is now two:

```bash
sed -i 's|REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE\[0\]}")/\.\./\.\." \&\& pwd)"|REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." \&\& pwd)"|' \
  scripts/ci/flux-schema/gen-catalog.sh
```

- [ ] **Step 4: Fix the two internal `scripts/flux-schema/` string paths**

In `scripts/ci/flux-schema/render-both.sh`, lines 22 and 34 hold the repo-root-relative form
`scripts/flux-schema/render-bundle.py`. Change both to `scripts/ci/flux-schema/render-bundle.py`.

In `scripts/ci/flux-schema/gen-catalog.sh`, line 38 holds `/flux-schema/preflight.sh` as part of a
repo-root-relative path. Change it to `/ci/flux-schema/preflight.sh`.

- [ ] **Step 5: Run the gate, then the real validator end to end**

Run: `bash scripts/ci/tests/test-script-paths.sh; echo "exit=$?"`
Expected: `… 0 failed`, `exit=0`.

Run: `task ci:validate`
Expected: the full render plus three gates, ending in the `flux schema validate` and `polaris
audit` summaries, exit 0. **Cite the resource count** — a count that moves between runs is the
tell for the `.bundle/` race, so run it once, alone, in this checkout.

- [ ] **Step 6: Update the render-diff job's call**

In `.github/workflows/ci.yaml`, the `render-diff` job (step "Render head and base (concurrent)"):

```yaml
        run: ./scripts/ci/flux-schema/render-both.sh "origin/${{ github.base_ref }}"
```

- [ ] **Step 7: Commit**

```bash
git add -A scripts .github/workflows/ci.yaml
git commit -m "refactor(scripts): move flux-schema/ under scripts/ci/

gen-catalog.sh went from one level deep to two, so its repo-root hop goes
from /../.. to /../../.. -- the depth-coupling the gate exists to catch."
```

---

### Task 6: Move the test suites into `scripts/ci/tests/`

The largest move, and the one with two-stage path edits: 16 suites point at a subject that does
not move until PR 2 or PR 3, so their subject paths get a *temporary* form here and a final form
later.

**Files:**
- Move: 20 `scripts/test-*.sh`, `scripts/flux-schema/test-*.py`, `scripts/alertmanager-fixtures/`,
  `scripts/vector-vrl-tests/`
- Modify: the moved suites' depths, `lib/` sources, and subject paths; `scripts/taskfile.yaml`

**Interfaces:**
- Consumes: `run.sh` and the gate, both already in `scripts/ci/tests/`.
- Produces: `scripts/ci/tests/test-*.sh` discoverable by `run.sh` with no `TESTS_DIR` override.

- [ ] **Step 1: Move the suites and their fixtures**

```bash
mkdir -p scripts/ci/tests/flux-schema
git mv scripts/test-*.sh scripts/ci/tests/
git mv scripts/flux-schema/test-check-substitution.py \
       scripts/flux-schema/test-render-bundle.py scripts/ci/tests/flux-schema/
git mv scripts/alertmanager-fixtures scripts/vector-vrl-tests scripts/ci/tests/
rmdir scripts/flux-schema
```

- [ ] **Step 2: Run the gate to verify it fails**

Run: `bash scripts/ci/tests/test-script-paths.sh; echo "exit=$?"`
Expected: `FAIL` lines covering `test-flux-schema.sh` (depth), `test-secret-store-lint.sh` (depth),
both `lib/` sources, and the subject paths in `test-openbao-*`, `test-zitadel-*`,
`test-cnpg-promote-seed.sh`, `test-validate-idp-topology.sh`. `exit=1`.

- [ ] **Step 3: Correct the two depths**

Both moved two levels deeper, so `/..` becomes `/../../..`:

```bash
sed -i 's|cd "$(dirname "$0")/\.\."|cd "$(dirname "$0")/../../.."|' \
  scripts/ci/tests/test-secret-store-lint.sh
sed -i 's|REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE\[0\]}")/\.\." \&\& pwd)"|REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." \&\& pwd)"|' \
  scripts/ci/tests/test-flux-schema.sh
```

Then in `scripts/ci/tests/test-flux-schema.sh` line 12, the sourced preflight path moves with
Task 5: `source "${REPO_ROOT}/scripts/ci/flux-schema/preflight.sh"`.

- [ ] **Step 4: Correct the two `lib/` sources**

`scripts/lib/` does not move in this PR, so both reach back two levels:

```bash
sed -i 's|\. "$HERE/lib/zitadel-pat.sh"|. "$HERE/../../lib/zitadel-pat.sh"|' \
  scripts/ci/tests/test-zitadel-pat.sh
sed -i 's|\. "$HERE/lib/cloud-secret-store.sh"|. "$HERE/../../lib/cloud-secret-store.sh"|' \
  scripts/ci/tests/test-cloud-secret-store.sh
```

- [ ] **Step 5: Correct the 16 subject paths**

Thirteen point at scripts that stay at `scripts/` root until PR 2 or PR 3 — those get `../../`.
Two point at `openbao-snapshot.sh`, which never moves. One points at a validator that moved in
Task 4 — that one gets `../`.

```bash
# Subjects still at scripts/ root (PR 2 and PR 3 move them later).
sed -i 's|\$HERE/openbao-config\.sh|$HERE/../../openbao-config.sh|' \
  scripts/ci/tests/test-openbao-root-token-probe.sh \
  scripts/ci/tests/test-openbao-pki-verify.sh \
  scripts/ci/tests/test-openbao-fallback-address.sh
sed -i 's|\$HERE/openbao-snapshot\.sh|$HERE/../../openbao-snapshot.sh|' \
  scripts/ci/tests/test-openbao-seal-status-tls.sh \
  scripts/ci/tests/test-openbao-snapshot-key.sh
sed -i 's|\$HERE/zitadel-oidc-clients\.sh|$HERE/../../zitadel-oidc-clients.sh|' \
  scripts/ci/tests/test-zitadel-workforce-audience.sh \
  scripts/ci/tests/test-zitadel-oidc-clients-secrets.sh \
  scripts/ci/tests/test-zitadel-oidc-clients-redirects.sh \
  scripts/ci/tests/test-zitadel-oidc-clients-project.sh \
  scripts/ci/tests/test-zitadel-oidc-clients-convergence.sh
sed -i 's|\$HERE/zitadel-idp\.sh|$HERE/../../zitadel-idp.sh|' \
  scripts/ci/tests/test-zitadel-idp-convergence.sh
sed -i 's|\$HERE/cnpg-promote-seed\.sh|$HERE/../../cnpg-promote-seed.sh|' \
  scripts/ci/tests/test-cnpg-promote-seed.sh

# Subject moved in Task 4: one level up, not two.
sed -i 's|\${SCRIPT_DIR}/validate-idp-topology\.sh|${SCRIPT_DIR}/../validate-idp-topology.sh|' \
  scripts/ci/tests/test-validate-idp-topology.sh
```

Leave a comment above each `../../` subject so PR 3 knows to revisit it. Add to
`scripts/ci/tests/test-openbao-root-token-probe.sh` and its siblings, once per file:

```bash
# The subject is still at scripts/ root; it moves to scripts/provision/ in the
# provision phase, and this path moves with it.
```

- [ ] **Step 6: Run the gate to verify it PASSES**

Run: `bash scripts/ci/tests/test-script-paths.sh; echo "exit=$?"`
Expected: `… 0 failed`, `exit=0`.

- [ ] **Step 7: Run every suite from its new home**

In `scripts/taskfile.yaml`, drop the override now that the suites sit beside the runner:

```yaml
  test:
    desc: Run every shell test suite the environment can satisfy
    cmds: ["./scripts/ci/tests/run.sh"]
```

Run: `task ci:test; echo "exit=$?"`
Expected: 21 result lines (20 suites plus `test-script-paths`), `0 failed`, `exit=0`.

- [ ] **Step 8: Commit**

```bash
git add -A scripts
git commit -m "refactor(scripts): move the test suites to scripts/ci/tests/

Sixteen suites reach their subject by a relative path, and thirteen of
those subjects do not move until a later phase -- so those paths are
temporary and carry a comment saying so. The gate covers all of them."
```

---

### Task 7: Rewrite the live references outside `scripts/`

126 references across workflows, manifests, agent configuration and the docs site.

**Files:**
- Modify: `.github/workflows/ci.yaml`, `.github/workflows/docs-check.yml`,
  `.github/workflows/vector-config-validation.yml`, `.github/workflows/openbao-restore-drill.yml`,
  `.doc-claims.yaml`, `mise.toml`, `AGENTS.md`, `scripts/AGENTS.md`, `observability/AGENTS.md`,
  `clusters/AGENTS.md`, `infrastructure/AGENTS.md`, `opentofu/AGENTS.md`,
  `docs/architecture/AGENTS.md`, `docs/architecture/README.md`, `docs/platform-constitution.md`,
  `.agents/skills/ship-it/references/evidence.md`, `.claude/agents/kubernetes-reviewer.md`,
  `observability/base/victoria-logs/README.md`, `website/content/**` (the pages Step 3 lists)

- [ ] **Step 1: Enumerate what must change, anchored safely**

The moved basenames, and nothing else. Write the list to a file so the rewrite is reviewable:

```bash
cat > /tmp/moved-pr1.txt <<'EOF'
validate-alertmanager-templates.sh|ci/
validate-doc-claims.sh|ci/
validate-idp-topology.sh|ci/
validate-links.sh|ci/
validate-manifests.sh|ci/
validate-vector-vrl.sh|ci/
validate-vmrules.sh|ci/
verify-doc-paths.sh|ci/
flux-schema/render-bundle.py|ci/
flux-schema/check-substitution.py|ci/
flux-schema/gen-catalog.sh|ci/
flux-schema/render-both.sh|ci/
flux-schema/diff-bundles.py|ci/
flux-schema/preflight.sh|ci/
flux-schema/test-render-bundle.py|ci/tests/
flux-schema/test-check-substitution.py|ci/tests/
EOF
# every test-*.sh basename lands in ci/tests/
for f in scripts/ci/tests/test-*.sh; do
  echo "$(basename "$f")|ci/tests/" >> /tmp/moved-pr1.txt
done
wc -l /tmp/moved-pr1.txt
```

Expected: 37 lines (16 + 21).

- [ ] **Step 2: Rewrite, anchored on `scripts/<basename>` only**

Never on the bare token `scripts/` — `opentofu/{aws,gcp}/openbao/cluster/scripts/` are
module-local directories that must not be touched.

```bash
TARGETS=$(git ls-files \
  '.github/workflows/*' '*.md' '.doc-claims.yaml' 'mise.toml' \
  'website/content/**' '.agents/**' '.claude/agents/*' \
  | grep -v '^docs/superpowers/plans/' \
  | grep -v '^docs/superpowers/specs/' \
  | grep -v '^docs/specs/')

while IFS='|' read -r base dest; do
  # shellcheck disable=SC2086
  sed -i "s|scripts/${base}|scripts/${dest}${base}|g" $TARGETS
done < /tmp/moved-pr1.txt
```

Note the `flux-schema/*` entries produce `scripts/ci/flux-schema/render-bundle.py` — correct —
and the loop must run the `flux-schema/` lines **before** any bare-basename line that could also
match. The file above is already ordered that way; do not sort it.

- [ ] **Step 3: Verify nothing module-local was touched**

Run: `git diff --stat -- opentofu`
Expected: **no output.** No file under `opentofu/` changes in this step; its three references
(`validate-idp-topology.sh` ×2, `validate-doc-claims.sh` ×1) are handled in Step 4 by hand.

If `opentofu/` appears here, the rewrite hit a module-local path — `git checkout -- opentofu` and
redo with a tighter anchor.

- [ ] **Step 4: Update the three terramate references by hand**

Find them: `grep -rn 'scripts/validate-' opentofu`. Each becomes `scripts/ci/validate-…`. Then:

Run: `terramate list`
Expected: the full stack list, exit 0 — it parses every `.tm.hcl`, so a syntax error surfaces here.

- [ ] **Step 5: Verify every rewritten path resolves**

```bash
grep -rhoE '(\./)?scripts/[A-Za-z0-9_/-]+\.(sh|py)' \
  .github .doc-claims.yaml mise.toml AGENTS.md */AGENTS.md \
  website/content .agents .claude/agents opentofu \
  | sed 's|^\./||' | sort -u \
  | while read -r p; do [ -e "$p" ] || echo "MISSING: $p"; done
```

Expected: **no output.**

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "refactor: point every live reference at scripts/ci/

Anchored on moved basenames rather than the bare 'scripts/' token, so the
module-local opentofu/**/cluster/scripts/ directories are untouched. The
dated plan and spec archive keeps its original paths."
```

---

### Task 8: `ci.yaml` calls task; the 60-line list goes

**Files:**
- Modify: `.github/workflows/ci.yaml`

- [ ] **Step 1: Replace the manifest validation step**

In the `kubernetes-validation` job, the step named `Validate manifests (flux schema + polaris)`:

```yaml
      - name: Validate manifests (flux schema + polaris)
        run: task ci:validate
```

Leave the job's `name:` untouched — it is a required-check context.

- [ ] **Step 2: Replace the unit-test step**

Same job, the step named `Unit tests for the validation scripts`:

```yaml
      - name: Unit tests for the validation scripts
        run: task ci:test
```

- [ ] **Step 3: Delete the inline loop and its 60 lines of justification**

In the `shellcheck` job, delete the entire `Run the shell test suites` step — the `for t in
scripts/test-zitadel-*.sh …` loop and every comment block above it explaining why the list is a
list. That reasoning now lives as one `# requires:` header per affected suite.

Keep the `Run ShellCheck` step and its `-type l` comment: the symlink argument is still true and
still load-bearing.

Update the find to the new tree — it already globs recursively, so only confirm it still reads
`./scripts`.

- [ ] **Step 4: Move the `links` job's suite call**

The `links` job's `Run identity provider topology tests` step ran one suite by name. That suite is
now discovered by `task ci:test` in the `kubernetes-validation` job. Delete the step, and delete
the comment block above it arguing for naming suites explicitly rather than globbing.

Keep the `Install Python dependencies` step — `validate-doc-claims.sh` still needs pyyaml.

- [ ] **Step 5: Verify the workflow parses and the comment bloat is gone**

Run: `python3 -c "import yaml,sys; yaml.safe_load(open('.github/workflows/ci.yaml')); print('parsed')"`
Expected: `parsed`.

Run: `wc -l .github/workflows/ci.yaml`
Expected: roughly 400 lines, down from 488. **Cite the number.**

- [ ] **Step 6: Confirm no job name changed**

```bash
git diff origin/main -- .github/workflows/ci.yaml | grep -E '^[-+]\s+name: ' | sort | uniq -c
```
Expected: every `name:` line appears as both a `-` and a `+`, or not at all. A `name:` that appears
only as `-` or only as `+` is a renamed job and breaks a required check — revert it.

- [ ] **Step 7: Commit**

```bash
git add .github/workflows/ci.yaml
git commit -m "ci: call task, and drop the hand-maintained suite list

The 60 lines arguing for which suites to name are replaced by a requires
header on the four suites that need one. Job names are unchanged, so the
required-check list on main is untouched."
```

---

### Task 9: `scripts/README.md`, the archive notes, and ADR-0039

**Files:**
- Create: `scripts/README.md`, `docs/superpowers/plans/README.md`, `docs/specs/README.md`,
  `website/content/docs/decisions/0039-go-task-as-the-entry-point.md`
- Modify: `scripts/AGENTS.md`

- [ ] **Step 1: Write `scripts/README.md`**

```markdown
# scripts/

Organised by **who runs it**, because every file has one answer to that and several to "what is
this about?". Entry points are indexed by `task --list`; run them with `task`, or call any script
directly — none of them depend on the task runner.

| Directory | Audience |
|---|---|
| `ci/` | the gates CI runs, and you before pushing. `task check` runs all of them |
| `ci/tests/` | shell suites. `run.sh` discovers them; each declares `# requires:` |
| `lib/` | sourced by the others, never run directly |

Directories for day-2 operations and apply-time provisioning land in later phases of this
restructure; until then those scripts remain at the root of `scripts/`.
```

- [ ] **Step 2: Write the two archive notes**

`docs/superpowers/plans/README.md` and `docs/specs/README.md`, same body:

```markdown
# Archive

Dated records of work already done. They are **not** updated when the repository moves around
them — a 2026-08 plan citing a 2026-09 path would be a retcon a reviewer could not distinguish
from a real edit.

Paths under `scripts/` in these documents predate the 2026-09-17 restructure. For current
locations see [`scripts/README.md`](../../scripts/README.md).
```

Adjust the relative depth per file so `validate-links.sh` passes.

- [ ] **Step 3: Write ADR-0039**

`website/content/docs/decisions/0039-go-task-as-the-entry-point.md`. Match the frontmatter shape of
`0038-*.md` exactly — `title`, `linkTitle`, `weight: 390`, `description`, `lastVerified`, then
`**Status**` / `**Date**` / `**Deciders**`.

It must record, with the measurements from the design doc:
- **Context**: 55 flat scripts, a hand-maintained 11-suite list in CI defended by 60 comment lines,
  no task runner, no local equivalent of what CI runs.
- **Decision**: go-task (`taskfile.yaml`, lowercase, v3), pinned in `mise.toml`, every task body a
  one-line call so scripts stay liftable.
- **Rejected — a bespoke `./scripts/run` dispatcher**: no tool to install, but ~80 lines of
  argument parsing nobody else knows, maintained forever.
- **Rejected — Make**: tab-sensitive recipes; the repo owner's own repos
  (`cilium-gateway-api`, `demo-tf-controller`, `dune-modem`) use `taskfile.yaml`.
- **Rejected — Dagger**: decommissioned 2026-07-20 for engine startup cost and
  `Smana/daggerverse` maintenance; reaffirmed 2026-09-12 after an engine crash-loop hung a
  `make lint` for 8 minutes with no output, because the client blocks in its own retry loop rather
  than erroring when the engine is down. **This ADR is where that decision now lives** — before it,
  the reasoning survived only in three orphaned comments in `ci.yaml`.
- **Consequences**: `task check` is the same command locally and in CI; an adopter who does not
  want go-task copies a single `.sh`; one more pinned tool in `mise.toml`.

- [ ] **Step 4: Update `scripts/AGENTS.md`**

Its opening line names `./scripts/validate-manifests.sh` as the entry point. Change to
`./scripts/ci/validate-manifests.sh` (or `task ci:validate`), and add one line pointing at
`scripts/README.md` for the layout. Do not rewrite the rest — the gate descriptions are still
accurate and out of scope.

- [ ] **Step 5: Verify links and doc paths**

Run: `task ci:links`
Expected: `==> All relative Markdown links resolve (0 allowlisted).`

Run: `task ci:doc-paths`
Expected: exit 0.

- [ ] **Step 6: Commit**

```bash
git add scripts/README.md scripts/AGENTS.md docs/superpowers/plans/README.md \
        docs/specs/README.md website/content/docs/decisions/0039-go-task-as-the-entry-point.md
git commit -m "docs: ADR-0039, the scripts/ index, and the archive notes

ADR-0039 also gives the 2026-07 Dagger decommission a durable home; until
now it survived only as three orphaned comments in ci.yaml."
```

---

### Task 10: Full verification and the PR

- [ ] **Step 1: Rebase onto the current `origin/main`**

```bash
git fetch origin
git rebase origin/main
```

A comparison against a stale local `origin/main` reports "up to date" on a branch that is not.

- [ ] **Step 2: Run the whole gate set, once, alone in this checkout**

```bash
task check
```

Expected: `ci:validate` renders and passes all three gates; `ci:test` reports `21 passed, 0 failed`
(or with skips named); `ci:links` passes. **Cite the rendered resource count and the test summary
line verbatim** — concurrent runs in one checkout race on `.bundle/` and a moving count is the tell.

- [ ] **Step 3: Prove the discovery property**

```bash
printf '#!/usr/bin/env bash\nexit 0\n' > scripts/ci/tests/test-zz-discovery-proof.sh
task ci:test | grep zz-discovery-proof
rm scripts/ci/tests/test-zz-discovery-proof.sh
```

Expected: `PASS  test-zz-discovery-proof`. This is success criterion 5 — a new suite runs with no
edit to `ci.yaml`.

- [ ] **Step 4: Prove the layout criterion**

Run: `ls scripts/`
Expected: `ci`, `lib`, `README.md`, `taskfile.yaml`, plus the not-yet-moved `ops`/`provision`
candidates still at root. Criterion 1 ("no loose executables") is satisfied only after PR 3 — state
that plainly in the PR body rather than claiming it now.

- [ ] **Step 5: Run the remaining repo validators**

```bash
./scripts/ci/validate-vmrules.sh
./scripts/ci/validate-doc-claims.sh
./scripts/ci/validate-idp-topology.sh
trivy config --exit-code=1 --ignorefile=./.trivyignore.yaml .
```

Expected: each exits 0. Cite each.

- [ ] **Step 6: Open the PR**

Use the `create-pr` skill. The body must carry:
- a link to the design doc and to this plan;
- a mermaid diagram of before/after;
- the cited output from Steps 2, 3 and 5;
- an explicit statement that **PRs 2 and 3 are still pending**, and that 13 test suites hold
  temporary `../../` subject paths that PR 3 finalises;
- the note that success criterion 1 is not yet met.

---

## Self-Review

**Spec coverage.** Decision 1 (audience directories) → Tasks 4–6, partially: this PR creates `ci/`
only. Decision 2 (taskfile) → Task 1. Decision 3 (`# requires:`) → Task 3. Decision 4 (archive
untouched) → Task 7 Step 2's exclusions and Task 9 Step 2. Decision 5 (depths + gate) → Tasks 2,
4, 5, 6. ADR gate → Task 9. Success criteria 2, 3, 4, 5, 6, 8, 10, 11 → Task 10. Criteria 1, 7 and
9 belong to PRs 2 and 3 and are called out as unmet.

**Known gaps, stated rather than hidden:**
- `scripts/openbao-snapshot.sh` (symlink) and criterion 11 are unaffected by this PR — nothing
  moves relative to it. Task 10 does not re-verify it; PR 2 must.
- Two suites (`test-flux-schema.sh`, `test-vector-vrl.sh`) may SKIP locally. CI installs their
  tooling via mise, so they run there. Verify in the PR's CI run, not locally.
- The 13 temporary `../../` subject paths are a deliberate intermediate state. They are correct
  for the tree as it exists at the end of this PR and are covered by `test-script-paths.sh`.
