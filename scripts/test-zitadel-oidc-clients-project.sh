#!/usr/bin/env bash
#
# Regression test for DEFECT 1: a failed ZITADEL API call must never be
# reported as "the project doesn't exist yet". Observed live: `curl: (22)
# The requested URL returned error: 404` printed immediately above a clean
# `created: 5, updated: 0, unchanged: 0` plan.
#
# api_or_fail()/ensure_project() are LIFTED verbatim out of
# zitadel-oidc-clients.sh via sed, not hand-restated -- the same technique
# test-secret-store-lint.sh uses for LINT_JQ ("The filter is not re-declared
# here; it is lifted verbatim out of the script, so a change there is a
# change under test."). zitadel-oidc-clients.sh itself is not sourceable (it
# parses argv and requires --cluster/--cloud unconditionally at the top of
# the file), so only the two functions under test are extracted, against a
# stubbed api().
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
fail=0
check() { if [ "$2" = "$3" ]; then printf '  ok   %s\n' "$1"
          else printf '  FAIL %s: expected %q got %q\n' "$1" "$2" "$3"; fail=1; fi }

# $1: path to a zitadel-oidc-clients.sh to extract from. api_or_fail is
# optional -- the pre-fix script this test must also run against (see the
# script header for how to reproduce that) has no such function at all,
# because ensure_project called `api` directly and swallowed its failure.
load_functions() {
    local src="$1" body
    body="$(sed -n '/^api_or_fail() {/,/^}/p' "$src")"
    [ -n "$body" ] && eval "$body"
    body="$(sed -n '/^ensure_project() {/,/^}/p' "$src")"
    [ -n "$body" ] || { echo "could not extract ensure_project() from $src" >&2; exit 1; }
    eval "$body"
}

load_functions "${ZITADEL_OIDC_CLIENTS_SCRIPT:-$HERE/zitadel-oidc-clients.sh}"

# Read only by ensure_project()'s eval'd body above -- shellcheck can't see
# that use through the eval.
# shellcheck disable=SC2034
ZITADEL_PROJECT_NAME="platform"

# ── 1. api() succeeds, project exists -> id returned ────────────────────────
api() { printf '{"result":[{"id":"proj-123","name":"platform"}]}'; }
APPLY=false
out="$(ensure_project)"; rc=$?
check "existing project: exit 0"   "0"        "$rc"
check "existing project: id value" "proj-123" "$out"

# ── 2. api() succeeds, empty result, dry-run -> DRYRUN-PROJECT sentinel ────
# (Legitimate case: the sentinel is fine here, this is not the defect.)
api() { printf '{"result":[]}'; }
APPLY=false
out="$(ensure_project)"; rc=$?
check "no project, dry-run: exit 0"   "0"              "$rc"
check "no project, dry-run: sentinel" "DRYRUN-PROJECT" "$out"

# ── 3. THE DEFECT: api() FAILS (curl -f style: nonzero exit, empty stdout) ──
# A fixed ensure_project must return non-zero and print NOTHING useful on
# stdout -- specifically NOT "DRYRUN-PROJECT", which a caller cannot tell
# apart from "the project genuinely does not exist yet".
api() { return 22; }
APPLY=false
out="$(ensure_project 2>/dev/null)"; rc=$?
check "api failure: ensure_project returns non-zero"   "1" "$rc"
check "api failure: stdout is empty, NOT the sentinel" ""  "$out"

err="$(ensure_project 2>&1 >/dev/null)"
case "$err" in *FAILED*) printf '  ok   api failure: prints a [FAILED] diagnostic\n' ;;
               *) printf '  FAIL api failure: no diagnostic printed\n'; fail=1 ;; esac

# Same failure, under --apply -- the CREATE call failing must not silently
# continue either.
api() { return 22; }
APPLY=true
out="$(ensure_project 2>/dev/null)"; rc=$?
check "api failure under --apply: returns non-zero" "1" "$rc"
check "api failure under --apply: no id on stdout"  ""  "$out"

# ── 4. The caller-side guard, reproduced exactly as cmd_sync uses it ───────
# `if ! project_id=$(ensure_project); then exit 1; fi`. The live defect was
# in the CALLER treating a non-empty sentinel as success -- testing only
# ensure_project's own return value would not catch a caller that ignored
# it, so this exercises the actual call shape.
api() { return 22; }
# shellcheck disable=SC2034  # read only by ensure_project()'s eval'd body
APPLY=false
caller_detected_failure=0
# project_id itself is not read again below -- the point of this check is
# the `if !` outcome, reproducing the exact shape cmd_sync uses.
# shellcheck disable=SC2034
if ! project_id="$(ensure_project 2>/dev/null)"; then
    caller_detected_failure=1
fi
check "caller: if ! project_id=\$(ensure_project) detects the failure" \
    "1" "$caller_detected_failure"

exit "$fail"
