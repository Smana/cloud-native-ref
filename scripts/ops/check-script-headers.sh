#!/usr/bin/env bash
# Name every shell script under a directory whose first comment line after the
# shebang does not say what the script does, and exit 1; exit 0 when all of
# them state their purpose. Structural, not semantic: the first comment line
# must be a "#" line whose text is a sentence about the script. A bare "#"
# (the blank comment that opens a block comment) is that sentence's margin, so
# the first line after it carries the purpose. A blank line, code, a "# ==="
# banner, or a comment about the code rather than what it is for fails.
#
#   scripts/ops/check-script-headers.sh [dir]
#
# Runs against scripts/ops/ by default; any directory can be handed to it,
# which is how its test aims it at fixtures.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DIR="${1:-$ROOT/scripts/ops}"

# The first comment line, with its "#" and one space of margin stripped. A
# comment must come before any other line -- a blank line or code first means
# the script opens without a header. A bare "#" (the blank comment that opens
# a block comment) is that sentence's margin, so the first comment line WITH
# text after it carries the purpose.
first_comment() { # <file>
  awk '
    NR == 1 && /^#!/ { next }
    /^[[:space:]]*#/ {
      line = $0
      sub(/^[[:space:]]*#[[:space:]]?/, "", line)
      if (line != "") { print line; exit }
      next
    }
    { exit }
  ' "$1"
}

# A header states a purpose. Backticks, dashes and quotes are fine; a "==="
# banner (or any run of non-word characters) is decoration, not a sentence;
# an empty first comment line defers to the next one.
states_purpose() { # <first-comment-line>
  [ -n "$1" ] || return 1
  [[ "$1" =~ [A-Za-z] ]] || return 1
  [[ "$1" =~ ^[[:space:]]*[=/|*+-]{3,} ]] && return 1
  return 0
}

rc=0
found=0
while IFS= read -r -d '' script; do
  found=1
  comment="$(first_comment "$script")"
  if ! states_purpose "$comment"; then
    printf '%s: no purpose in its first comment line after the shebang (got: %q)\n' \
      "${script#"$ROOT"/}" "$comment" >&2
    rc=1
  fi
done < <(find "$DIR" -name '*.sh' -type f -print0 | sort -z)

[ "$found" -eq 1 ] || { printf 'no shell scripts under %s\n' "$DIR" >&2; exit 1; }
exit "$rc"
