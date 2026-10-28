#!/usr/bin/env bash
# check-script-headers.sh against run-time fixtures: one script whose first
# comment line after the shebang states its purpose, one whose does not. The
# check must stay quiet about the good one however it is alone, and name the
# bad one when both are present -- naming every offender is the point, so a
# single-name run proves nothing until the other script is also there to be
# missed. The bad fixture fails the three ways a real header can fail: a
# blank line before any comment, a "===" banner, and code first. Fixtures
# are built in a mktemp directory because the check takes the directory to
# scan as its argument, which is also what keeps this suite hermetic.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK="$HERE/../../ops/check-script-headers.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

fails=0
fail() { printf 'FAIL  %s\n' "$*" >&2; fails=$((fails + 1)); }
assert() { # assert <description> <expected-rc> <command...>
  local desc="$1" want="$2"; shift 2
  "$@" >/dev/null 2>"$T/stderr"; local got=$?
  [ "$got" -eq "$want" ] || fail "$desc: exit $got, wanted $want ($(cat "$T/stderr"))"
}

# The good fixture: every header shape the repo's scripts actually use, each
# one alone in its own directory so only that shape is under test.
good_with_bare_hash() { # "#" then the sentence, the majority style
  printf '#!/usr/bin/env bash\n#\n# Sweep the orphaned volumes a teardown left behind.\nset -euo pipefail\n' >"$1"
}
good_inline() { # the sentence on the "#" line itself
  printf '#!/usr/bin/env bash\n# Empty a Cloud DNS managed zone so the zone can be destroyed.\nset -euo pipefail\n' >"$1"
}
good_uppercase_shebang() { # a "/bin/bash" shebang and mixed-case text
  printf '#!/bin/bash\n# Promote a live CNPG cluster archive to a restore seed.\nexit 0\n' >"$1"
}

mkdir "$T/ok-hash" "$T/ok-inline" "$T/ok-shebang"
good_with_bare_hash "$T/ok-hash/sweep.sh"
good_inline "$T/ok-inline/purge.sh"
good_uppercase_shebang "$T/ok-shebang/promote.sh"

assert 'bare-# then sentence passes' 0 "$CHECK" "$T/ok-hash"
assert 'sentence on the # line passes' 0 "$CHECK" "$T/ok-inline"
assert '/bin/bash shebang passes' 0 "$CHECK" "$T/ok-shebang"

# All three good fixtures together: still quiet, and quietly -- no output.
mkdir "$T/ok-mixed" && cp "$T/ok-hash/sweep.sh" "$T/ok-inline/purge.sh" "$T/ok-shebang/promote.sh" "$T/ok-mixed/"
out="$("$CHECK" "$T/ok-mixed" 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && [ -z "$out" ] || fail "all-good directory: exit $rc with output: $out"

# The bad fixture: blank line before the comment, the eks-prepare-destroy.sh
# shape. Named, not just failed: the output must carry the filename.
mkdir "$T/bad"
printf '#!/bin/bash\n\n# Don'\''t use set -e globally - we want to handle errors gracefully during cleanup\nexit 0\n' >"$T/bad/prepare.sh"
out="$("$CHECK" "$T/bad" 2>&1)"; rc=$?
[ "$rc" -eq 1 ] || fail "headerless fixture: exit $rc, wanted 1"
case "$out" in *prepare.sh*) ;; *) fail "headerless fixture not named in: $out";; esac

# A "===" banner as the first comment line, the cleanup-benchmark-images.sh
# shape.
mkdir "$T/banner"
printf '#!/usr/bin/env bash\n\n# ======\n# Cleanup\n# ======\nexit 0\n' >"$T/banner/cleanup.sh"
out="$("$CHECK" "$T/banner" 2>&1)"; rc=$?
[ "$rc" -eq 1 ] || fail "banner fixture: exit $rc, wanted 1"
case "$out" in *cleanup.sh*) ;; *) fail "banner fixture not named in: $out";; esac

# Code before any comment.
mkdir "$T/code-first"
printf '#!/usr/bin/env bash\nset -euo pipefail\n# what this does\nexit 0\n' >"$T/code-first/silent.sh"
assert 'code before the first comment fails' 1 "$CHECK" "$T/code-first"

# Good and bad together: the good one alone passes, the same good one plus
# the bad one fails naming the bad one -- a directory is judged by its
# offenders, and only them.
cp "$T/ok-hash/sweep.sh" "$T/bad/"
out="$("$CHECK" "$T/bad" 2>&1)"; rc=$?
[ "$rc" -eq 1 ] || fail "mixed directory: exit $rc, wanted 1"
case "$out" in *prepare.sh*) ;; *) fail "mixed directory: offender not named in: $out";; esac
case "$out" in *sweep.sh*) fail "mixed directory: good fixture named in: $out";; esac

# A directory with no shell scripts at all is an error, not a pass: a
# mis-aimed scan must not report a green gate.
mkdir "$T/empty"
assert 'directory with no scripts fails' 1 "$CHECK" "$T/empty"

[ "$fails" -eq 0 ] || exit 1
exit 0
