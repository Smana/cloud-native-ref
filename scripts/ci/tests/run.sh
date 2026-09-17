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
