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

# The self-location idioms, held in VARIABLES and written without quotes.
#
# Variables because a literal ${BASH_SOURCE[0]} inside a ${var//pat/rep} ends the
# expansion at its own closing brace: bash appends the remainder as text instead
# of substituting, and every source check silently passes garbage. Measured, not
# theorised.
#
# Without quotes because check 2 strips quotes from the line before matching --
# see the comment there.
P_D0='$(dirname $0)'
P_DBS='$(dirname ${BASH_SOURCE[0]})'

while IFS= read -r script; do
  # This gate is itself a *.sh under SCRIPTS, and its own comments carry example
  # idioms that match its own detectors. Scanning itself reports failures that
  # exist only in its documentation.
  case "$script" in */test-script-paths.sh) continue ;; esac

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
  #
  # Nested quoting is the NORM here -- `. "$(dirname "$0")/lib/x.sh"` -- so any
  # extraction delimited by the first pair of quotes truncates at the INNER quote
  # and checks a fragment instead of a path. Strip every quote first, resolve the
  # idioms against this script's directory, then take the last path on the line.
  while IFS=: read -r lineno line; do
    n="${line//\"/}"; n="${n//\'/}"
    n="${n//"$P_D0"/$dir}"
    n="${n//"$P_DBS"/$dir}"
    n="${n//'${HERE}'/$dir}";       n="${n//'$HERE'/$dir}"
    n="${n//'${SCRIPT_DIR}'/$dir}"; n="${n//'$SCRIPT_DIR'/$dir}"
    n="${n//'${REPO_ROOT}'/$MARKER_ROOT}"; n="${n//'$REPO_ROOT'/$MARKER_ROOT}"
    target="$(printf '%s' "$n" | grep -oE '/[A-Za-z0-9._/-]+\.(sh|py)' | tail -1)"
    [ -n "$target" ] || continue
    # Anything still holding a variable cannot be checked statically. Skipping is
    # honest; the counts printed at the end make a drop in coverage visible.
    case "$target" in *'$'*) continue ;; esac
    n_sources=$((n_sources + 1))
    [ -f "$target" ] || fail "$(rel "$script"):$lineno — sources a missing file: $target"
  done < <(grep -nE '^[[:space:]]*(\.|source)[[:space:]]+' "$script" 2>/dev/null || true)

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
