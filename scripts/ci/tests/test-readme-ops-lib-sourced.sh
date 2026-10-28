#!/usr/bin/env bash
# requires:
#
# scripts/README.md is read one row at a time: the reader looking at the ops row
# never reaches the lib/ row five lines below. That ops row (ops/aws/,
# ops/gcp/, ops/k8s/) stayed silent about the library helpers those scripts
# rely on -- ops/k8s/cnpg-prepare-restore.sh:60 sources scripts/lib/gcloud-adc.sh
# -- so a reader who runs a helper instead of sourcing it gets nothing,
# quietly. The issue asks for one sentence in that row saying the helpers are
# meant to be sourced, not run. This suite pins it in the row itself, and pins
# the lib/ row verbatim: the sentence belongs in the ops row, not in a rewrite
# of the one row that already said it.
#
# The fixtures carry the proof a green run needs: the README as it is today must
# fail this suite, and one carrying the sentence must pass. Without the negative
# case, a green gate means nothing.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../../.." && pwd)"

fails=0
fail() { printf 'FAIL  %s\n' "$*" >&2; fails=$((fails + 1)); }

# The row is found by what it lists -- all three of ops/aws/, ops/gcp/ and
# ops/k8s/ in the directory cell -- not by its line number, which every edit
# above it moves.
ops_rows() { grep '^|' "$1" | grep -F '`ops/aws/`' | grep -F '`ops/gcp/`' | grep -F '`ops/k8s/`'; }

# The description cell: everything after the directory cell, trailing pipe gone.
desc_cell() { local d="${1#*|}"; d="${d#*|}"; printf '%s' "${d%|}"; }

# The sentence, in any wording it may take: the library helpers are mentioned,
# they are sourced, and they are not run directly.
says_sourced_not_run() {
  local d; d="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  case "$d" in *lib*) ;; *) return 1 ;; esac
  printf '%s' "$d" | grep -q 'sourc' || return 1
  printf '%s' "$d" | grep -qE \
    '(never|not) (run|executed) directly|not meant to be run|meant to be sourced|rather than (run|executed)' \
    || return 1
  return 0
}

check_readme() { # check_readme <repo-root> <label> — returns 1 when it failed
  local root="$1" label="$2" base=$fails readme row n=0
  readme="$root/scripts/README.md"
  [ -f "$readme" ] || { fail "$label: no scripts/README.md under $root"; return; }

  grep -qxF '| `lib/` | sourced by the others, never run directly |' "$readme" \
    || fail "$label: the lib/ row is reworded or gone — the sentence belongs in the ops row, not a rewrite of this one"

  while IFS= read -r row; do
    [ -n "$row" ] || continue
    n=$((n + 1))
    says_sourced_not_run "$(desc_cell "$row")" || fail \
      "$label: the row listing ops/aws/, ops/gcp/ and ops/k8s/ does not say its library helpers are sourced by other scripts and never run directly: $(desc_cell "$row")"
  done < <(ops_rows "$readme")
  [ "$n" -gt 0 ] || fail "$label: no table row lists ops/aws/, ops/gcp/ and ops/k8s/ together"
  [ "$fails" -eq "$base" ]
}

# Fixtures: the README without the sentence (the shape at the commit that added
# this gate) and with it, differing only in that sentence.
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/before/scripts" "$T/after/scripts"
lib_row='| `lib/` | sourced by the others, never run directly |'
printf '# scripts/\n\n| Directory | Audience |\n|---|---|\n' \
  | tee "$T/before/scripts/README.md" "$T/after/scripts/README.md" >/dev/null
printf '| `ops/aws/`, `ops/gcp/`, `ops/k8s/` | day-2 operations, run by a human. |\n%s\n' "$lib_row" \
  >>"$T/before/scripts/README.md"
printf '| `ops/aws/`, `ops/gcp/`, `ops/k8s/` | day-2 operations, run by a human. The library helpers these scripts rely on are sourced by other scripts and never run directly. |\n%s\n' "$lib_row" \
  >>"$T/after/scripts/README.md"

# The README without the sentence must fail — in a subshell, because its
# failure is the point, not a failure of this suite.
( check_readme "$T/before" 'fixture: README without the sentence' ) 2>"$T/neg.err"; neg_rc=$?
[ "$neg_rc" -ne 0 ] || fail "suite passes a README without the sentence — the gate checks nothing ($(cat "$T/neg.err"))"

check_readme "$T/after" 'fixture: README with the sentence'

check_readme "$REPO_ROOT" 'scripts/README.md'

[ "$fails" -eq 0 ]
