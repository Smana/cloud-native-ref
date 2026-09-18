#!/usr/bin/env bash
# Runs every suite in this directory, plus every .py suite one level down (e.g.
# flux-schema/test-*.py), honouring each one's `# requires:` header.
#
# Discovery rather than a list, because the list was the bug: seven ZITADEL
# suites existed and went unrun for months, since writing a suite and getting CI
# to run it were separate acts and the second one got forgotten. A suite added
# here is covered by the commit that adds it.
#
# A skip is printed, never silent. "It didn't run" and "it passed" are the two
# outcomes a CI log must never conflate.
#
# Exit 77 is also a SKIP, and its last output line is the reason. `# requires:`
# stays the way to skip; 77 is only for a prerequisite `command -v` cannot test,
# such as a Python module. The design rejected per-suite 77 self-skips (Decision
# 3 in docs/superpowers/specs/2026-09-17-scripts-restructure-design.md); this
# narrow exception is deliberate, so do not remove it.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS="${TESTS_DIR:-$HERE}"

pass=0 skip=0 fail=0 rc=0

for t in "$TESTS"/test-*.sh "$TESTS"/test-*.py "$TESTS"/*/test-*.py; do
  [ -e "$t" ] || continue
  case "$t" in
    "$TESTS"/test-*.sh) name="$(basename "$t" .sh)"; interpreter=bash ;;
    "$TESTS"/test-*.py) name="$(basename "$t" .py)"; interpreter=python3 ;;
    *)                  name="$(basename "$(dirname "$t")")/$(basename "$t" .py)"; interpreter=python3 ;;
  esac

  # First `# requires:` line only. Absent or empty means bash and jq (or, for a
  # .py suite, python3), which CI and every developer machine already have.
  # `#` is a comment in both languages, so the same sed line parses either.
  missing=""
  command -v "$interpreter" >/dev/null 2>&1 || missing="$missing $interpreter"
  for tool in $(sed -n 's/^# requires:[[:space:]]*//p' "$t" | head -1); do
    command -v "$tool" >/dev/null 2>&1 || missing="$missing $tool"
  done
  if [ -n "$missing" ]; then
    printf 'SKIP  %-42s missing:%s\n' "$name" "$missing"
    skip=$((skip + 1))
    continue
  fi

  SECONDS=0
  out="$("$interpreter" "$t" 2>&1)"
  code=$?
  if [ "$code" -eq 0 ]; then
    printf 'PASS  %-42s (%ds)\n' "$name" "$SECONDS"
    pass=$((pass + 1))
  elif [ "$code" -eq 77 ]; then
    reason="${out##*$'\n'}"
    printf 'SKIP  %-42s %s\n' "$name" "${reason:-no reason given}"
    skip=$((skip + 1))
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

# Zero suites is a wrong TESTS path or a broken glob, never a pass.
if [ $((pass + skip + fail)) -eq 0 ]; then
  echo "no suites found under $TESTS" >&2
  exit 1
fi
exit "$rc"
