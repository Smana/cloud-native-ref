#!/usr/bin/env bash
#
# Tests the `notify-main-broken` job in .github/workflows/ci.yaml.
#
# This job reports a red `main`, and it is the hardest job in the workflow to
# exercise: it runs only `if: failure() && github.event_name == 'push'`, so a
# healthy repository never runs it and the first time it matters is also the
# first time it has ever run. It shipped broken for exactly that reason. It has
# no checkout step -- it needs no code -- so every `gh` call tried to infer the
# repository from a local git remote and died with
#
#     failed to run git: fatal: not a git repository
#
# A broken `main` therefore went unreported, which is the one outcome the job
# exists to prevent. Fixed by adding GH_REPO to the step's `env:`.
#
# THE TEST TAKES ITS ENVIRONMENT FROM THE WORKFLOW, NOT FROM ITSELF. That is
# the whole design, and it is worth stating because two earlier versions of
# this suite got it wrong in the same way the job did. Both exported GH_REPO
# themselves and then asserted the branch logic -- open a new issue vs comment
# on the open one -- so both passed against a workflow with no GH_REPO at all.
# They tested the script's logic while the defect was in how the workflow
# invokes it. Deleting the GH_REPO line from ci.yaml must fail this suite; if a
# change here makes that stop being true, the suite has regressed to testing
# nothing.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKFLOW="${SCRIPT_DIR}/../.github/workflows/ci.yaml"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "${WORKDIR}"' EXIT
NOTIFY="${WORKDIR}/notify.sh"
STEP_ENV="${WORKDIR}/step-env.sh"
failures=0

if ! python3 -c 'import yaml' 2>/dev/null; then
  echo "SKIP  python3 pyyaml is required to parse the workflow" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Extract the step's `run:` block and its `env:` block as the runner sees them.
#
# The de-indentation is why this parses YAML rather than slicing with sed: the
# block is a YAML block scalar, and the body contains a heredoc whose
# terminator must land at column zero once YAML has stripped the common indent.
# Get that wrong and the step is still valid YAML while being broken bash.
# ---------------------------------------------------------------------------
if ! python3 - "$WORKFLOW" "$NOTIFY" "$STEP_ENV" <<'PY'
import pathlib
import re
import shlex
import sys

import yaml

workflow, out, env_out = (pathlib.Path(p) for p in sys.argv[1:4])
job = yaml.safe_load(workflow.read_text())["jobs"]["notify-main-broken"]
step = job["steps"][0]

# The runner expands ${{ ... }} before bash or the environment ever sees it.
expand = lambda s: re.sub(r"\$\{\{[^}]*\}\}", "substituted", str(s))

out.write_text(expand(step["run"]))
env_out.write_text(
    "".join(f"export {k}={shlex.quote(expand(v))}\n" for k, v in (step.get("env") or {}).items())
)

names = sorted((step.get("env") or {}).keys())
print(f"      step env: {' '.join(names) if names else '(none)'}")

terminators = [n for n, line in enumerate(step["run"].splitlines()) if line.strip() == "EOF"]
if not terminators:
    print("FAIL  no heredoc terminator found in the run block")
    sys.exit(1)
for n in terminators:
    if step["run"].splitlines()[n].startswith(" "):
        print(f"FAIL  heredoc terminator on line {n} is indented; bash will not close the heredoc")
        sys.exit(1)
print(f"PASS  heredoc terminator at column 0 (line {terminators[0]})")
PY
then
  failures=1
fi

if bash -n "$NOTIFY" 2>"${WORKDIR}/syntax.err"; then
  echo "PASS  the run block is syntactically valid bash"
else
  echo "FAIL  the run block is not valid bash"
  sed 's/^/      /' "${WORKDIR}/syntax.err"
  failures=1
fi

# ---------------------------------------------------------------------------
# The stub mirrors the real failure: without GH_REPO (or an explicit --repo)
# `gh` needs a git remote to infer the repository from, and there is none here.
# ---------------------------------------------------------------------------
STUB="${WORKDIR}/bin"
NOGIT="${WORKDIR}/nogit"
mkdir -p "$STUB" "$NOGIT"

cat >"${STUB}/gh" <<'STUB'
#!/usr/bin/env bash
echo "CALL: gh $*" >>"$GH_CALLS"
if [ -z "${GH_REPO:-}" ] && ! printf '%s\n' "$@" | grep -qx -- "--repo"; then
  echo "failed to run git: fatal: not a git repository (or any of the parent directories): .git" >&2
  exit 1
fi
case "$1 $2" in
  "issue list") printf '%s' "${FAKE_EXISTING:-}" ;;
esac
exit 0
STUB
chmod +x "${STUB}/gh"
export PATH="${STUB}:${PATH}"

# $3 is either "must-fail" or the gh subcommand the run is expected to reach.
# $5, when set to "drop-gh-repo", removes GH_REPO *after* sourcing the
# workflow's own env -- the one case that deliberately departs from it.
run_case() {
  local name="$1" existing="$2" expect="$3" drop="${4:-}"
  local rc=0

  (
    set -a
    # shellcheck source=/dev/null
    . "$STEP_ENV"
    set +a
    [ "$drop" = "drop-gh-repo" ] && unset GH_REPO
    export GH_CALLS="${WORKDIR}/calls-${name}.txt"
    export FAKE_EXISTING="$existing"
    : >"$GH_CALLS"
    cd "$NOGIT" && bash "$NOTIFY"
  ) >"${WORKDIR}/out-${name}.txt" 2>&1 || rc=$?

  local calls="${WORKDIR}/calls-${name}.txt"
  if [ "$expect" = "must-fail" ]; then
    if [ "$rc" -ne 0 ]; then
      echo "PASS  ${name} -> failed as expected (rc=${rc})"
    else
      echo "FAIL  ${name} -> expected a failure, got rc=0"
      failures=1
    fi
    return
  fi

  if [ "$rc" -eq 0 ] && grep -q "gh issue ${expect}" "$calls" 2>/dev/null; then
    echo "PASS  ${name} -> issue ${expect} (rc=${rc}, outside a git repository)"
  else
    echo "FAIL  ${name} -> rc=${rc}; output was:"
    sed 's/^/      /' "${WORKDIR}/out-${name}.txt"
    failures=1
  fi
}

# The two cases that matter run on the workflow's OWN env. If ci.yaml stops
# supplying GH_REPO these fail, which is the regression this suite exists for.
run_case "workflow-env-fresh" "" "create"
run_case "workflow-env-existing" "417" "comment"
# And this one guards the stub itself: drop GH_REPO and the failure must come
# back, otherwise the two cases above are passing for the wrong reason.
run_case "gh-repo-removed" "" "must-fail" "drop-gh-repo"

if [ "$failures" -ne 0 ]; then
  echo "FAILED"
  exit 1
fi
echo "All notify-main-broken tests passed"
