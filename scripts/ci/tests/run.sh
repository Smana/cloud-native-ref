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
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS="${TESTS_DIR:-$HERE}"

pass=0 skip=0 fail=0 rc=0

for t in "$TESTS"/test-*.sh "$TESTS"/*/test-*.py; do
  [ -e "$t" ] || continue
  case "$t" in
    "$TESTS"/test-*.sh) name="$(basename "$t" .sh)"; interpreter=bash ;;
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
    printf 'SKIP  %-42s %s\n' "$name" "${out##*$'\n'}"
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
exit "$rc"
