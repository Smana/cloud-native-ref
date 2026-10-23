#!/usr/bin/env bash
# requires: bash
#
# run.sh's two modes for test-contract (agent-platform v3 feature 4): suites named as arguments run
# alone, and AGENT_TEST_REPORT gets one JUnit testcase a suite, its path from the repository root,
# a SKIP as <skipped/> and a FAIL as <failure/>. With no argument every suite runs, as before, and
# the failed suites are still repeated after the last suite, before the count line.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/scripts/ci/tests/sub"
cp "$HERE/run.sh" "$TMP/scripts/ci/tests/run.sh"
printf 'exit 0\n' > "$TMP/scripts/ci/tests/test-pass.sh"
printf 'echo broken; exit 1\n' > "$TMP/scripts/ci/tests/test-fail.sh"
printf 'echo later; exit 77\n' > "$TMP/scripts/ci/tests/test-skip.sh"
printf '# requires: no-such-tool-anywhere\nexit 0\n' > "$TMP/scripts/ci/tests/test-needs.sh"
printf 'raise SystemExit(0)\n' > "$TMP/scripts/ci/tests/sub/test-deep.py"
fail=0
ok() { printf 'ok   %s\n' "$1"; }
no() { printf 'FAIL %s\n' "$1"; fail=1; }

cd "$TMP"
out="$(AGENT_TEST_REPORT="$TMP/r.xml" bash scripts/ci/tests/run.sh scripts/ci/tests/test-pass.sh scripts/ci/tests/test-fail.sh \
  scripts/ci/tests/test-skip.sh scripts/ci/tests/test-needs.sh scripts/ci/tests/sub/test-deep.py)" && no "a failing suite exits 1" || ok "a failing suite exits 1"
case "$out" in *"2 passed, 2 skipped, 1 failed"*) ok "the named suites run, and only they" ;; *) no "the named suites run: $out" ;; esac
r="$(cat "$TMP/r.xml" 2>/dev/null || true)"
for want in '<testcase classname="scripts/ci/tests/test-pass.sh" name="scripts/ci/tests/test-pass.sh"></testcase>' \
            '<testcase classname="scripts/ci/tests/test-fail.sh" name="scripts/ci/tests/test-fail.sh"><failure/></testcase>' \
            '<testcase classname="scripts/ci/tests/test-skip.sh" name="scripts/ci/tests/test-skip.sh"><skipped/></testcase>' \
            '<testcase classname="scripts/ci/tests/test-needs.sh" name="scripts/ci/tests/test-needs.sh"><skipped/></testcase>' \
            '<testcase classname="scripts/ci/tests/sub/test-deep.py" name="scripts/ci/tests/sub/test-deep.py"></testcase>'; do
  case "$r" in *"$want"*) ok "report: ${want:20:48}" ;; *) no "report lacks $want" ;; esac
done
out="$(bash scripts/ci/tests/run.sh scripts/ci/tests/test-pass.sh)" || no "one passing suite exits 0"
case "$out" in *"1 passed, 0 skipped, 0 failed"*) ok "one named suite runs alone" ;; *) no "one suite: $out" ;; esac
out="$(bash scripts/ci/tests/run.sh || true)"
case "$out" in *"2 passed, 2 skipped, 1 failed"*) ok "no argument runs every suite, as before" ;; *) no "every suite: $out" ;; esac
# The failed suites are repeated after the last suite, before the count line (#2545).
repeat="$(printf '%s\n' "$out" | awk '/^FAIL  test-fail/{n++} n==2 && /broken/{b=1} /passed, .* failed/{if(n==2&&b)print "yes"}')"
[ "$repeat" = yes ] && ok "the failures are repeated before the count line" || no "failures not repeated before the count: $out"
[ ! -e "$TMP/r2.xml" ] && ok "no AGENT_TEST_REPORT, no report" || no "a report without AGENT_TEST_REPORT"
exit "$fail"
