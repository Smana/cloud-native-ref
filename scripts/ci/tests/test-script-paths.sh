#!/usr/bin/env bash
# requires:
#
# Two things break silently when a script moves, and neither is an external
# reference. The "/.." depth it uses: to reach the repo root, or to reach a
# sibling path (an exec target, a sourced file). A wrong count makes `cd`
# SUCCEED at the wrong directory, or makes an exec/source target resolve to
# nothing -- either way quietly. Root climbs are checked against two markers;
# sibling climbs are checked for existence, EXCEPT when the first segment also
# exists at the repo root and the climb itself isn't the root: AGENTS.md and
# README.md both nest at several depths, so "exists" alone would pass a climb
# that stopped one level short by accident. And the relative path it sources a
# library, or reaches its test subject, through. Six of the nine
# lib/-sourcing scripts run during a terramate apply, so that failure lands
# mid-deploy with no CI gate in front of it.
#
# SCRIPT_PATHS_ROOT exists so this suite can be aimed at a fixture tree and
# proved to fail. Without a negative case a green gate means nothing.
#
# The floors at the end are what make a drop in coverage visible. The printed
# counts cannot: run.sh discards a passing suite's output.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../../.." && pwd)"
SCRIPTS="${SCRIPT_PATHS_ROOT:-$REPO_ROOT/scripts}"
MARKER_ROOT="$(cd "$SCRIPTS/.." && pwd)"

fails=0 n_roots=0 n_rels=0 n_sources=0 n_subjects=0

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

  # 1. Self-resolved paths: a repo-root climb, or a climb into a sibling path.
  #
  # The "/.." run alone does not say which: `cd "$(dirname "$0")/.."` climbs to
  # the root, but `"$(dirname "$0")/../k8s/x.sh"` climbs to a SIBLING directory
  # and was never meant to land on the root at all. Classify by what follows
  # the climb: a named path segment means "sibling" (checked for existence,
  # since it is not the repo root by design); anything else -- the climb ends
  # the path, or a variable follows it -- means "root" (checked against the two
  # markers, which fails loudly on a variable it cannot resolve).
  while IFS=: read -r lineno line; do
    ups="$(printf '%s' "$line" | grep -oE '(/\.\.)+' | head -1)"
    [ -n "$ups" ] || continue
    after="${line#*"$ups"}"
    case "$after" in
      /[A-Za-z0-9_]*)
        seg="$(printf '%s' "$after" | grep -oE '^(/[A-Za-z0-9._-]+)+')"
        n_rels=$((n_rels + 1))
        # A climb that stops one level short of the root, on a directory that
        # HAPPENS to have a same-named entry (AGENTS.md and README.md both
        # nest), passes the plain existence check by accident -- indistinguish-
        # able from a genuine wrong depth. Fail loudly instead when the first
        # segment also exists at the true root and the climb itself is not it.
        first_seg="${seg#/}"; first_seg="${first_seg%%/*}"
        climbed="$(cd "$dir$ups" 2>/dev/null && pwd)"
        if [ -e "$MARKER_ROOT/$first_seg" ] && { [ -z "$climbed" ] || ! is_repo_root "$climbed"; }; then
          fail "$(rel "$script"):$lineno — '$first_seg' also exists at the repo root; this climb stops at ${climbed:-$dir$ups}, not the root. Either way, climb to the repo root (REPO_ROOT) and name the path from there"
        else
          [ -e "$dir$ups$seg" ] \
            || fail "$(rel "$script"):$lineno — reaches a missing path: $dir$ups$seg"
        fi
        continue ;;
    esac
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
    # honest; the floor on n_sources at the end catches a drop in coverage.
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

printf '%d roots, %d relative paths, %d sources, %d subjects checked; %d failed\n' \
  "$n_roots" "$n_rels" "$n_sources" "$n_subjects" "$fails"

# A gate that checked nothing has not passed. 20 sources is the floor measured
# when this gate was written (21 at the time). Below it, suspect a broken
# extraction or a moved scan root first; lower the floor only in the commit that
# really removes the source lines.
if [ "$n_roots" -eq 0 ] || [ "$n_subjects" -eq 0 ] || [ "$n_sources" -lt 20 ]; then
  printf 'FAIL  coverage below floor: %d roots (need >0), %d subjects (need >0), %d sources (need >=20) under %s\n' \
    "$n_roots" "$n_subjects" "$n_sources" "$SCRIPTS" >&2
  exit 1
fi
[ "$fails" -eq 0 ]
