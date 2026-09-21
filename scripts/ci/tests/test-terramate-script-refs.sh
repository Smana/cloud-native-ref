#!/usr/bin/env bash
# Every script path that opentofu and terramate name on an executed line must exist.
#
# These run at apply and destroy time, and no CI job executes them. A move that
# misses one fails mid-destroy with a bare "No such file". test-script-paths.sh
# checks paths computed *inside* scripts; verify-doc-paths.sh reads only the docs
# site. Neither reads *.tm.hcl or *.tf, which is where these live.
#
# Comment lines are skipped: a stale comment misleads, but it cannot break a run.
# `echo` hints are checked — an operator copies them during a failed destroy.
#
# Every mention is either resolved or fails loudly. A line where fewer refs were
# extracted than "scripts/..." mentions counted holds a shape the inner regex
# cannot parse -- these used to pass silently at 0 checked. A ${...}/$${...}
# prefix resolves only as ${path.module} (beside the file),
# ${terramate.root.path.fs.absolute} or $${ROOT} (the repo root) -- the three
# this codebase actually uses; anything else is an unrecognised prefix, never a
# guess at what it might mean.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${TM_REFS_ROOT:-$(cd "$HERE/../../.." && pwd)}"
# Measured at the commit that added this gate. A count below it means the
# extraction broke, not that references went away; fail rather than pass over less.
FLOOR="${TM_REFS_FLOOR:-80}"

checked=0 failed=0
while IFS= read -r hit; do
  file="${hit%%:*}"; rest="${hit#*:}"; line="${rest%%:*}"; text="${rest#*:}"
  [[ "$text" =~ ^[[:space:]]*(#|//) ]] && continue

  # The outer count has no prefix opinion: it is the floor every extracted ref
  # must meet. Fewer extracted than mentioned means a shape the inner regex
  # cannot parse -- e.g. an unbraced variable, a single-quoted path, a bare
  # "../.." climb -- slipped through unresolved.
  want="$(grep -oE 'scripts/[A-Za-z0-9_./-]+\.(sh|py|js|ya?ml)' <<<"$text" | wc -l)"
  got=0
  while IFS= read -r ref; do
    [ -n "$ref" ] || continue
    got=$((got + 1))
    case "$ref" in
      '${path.module}/'*)
        target="$ROOT/$(dirname "$file")/${ref#'${path.module}/'}" ;;
      '${terramate.root.path.fs.absolute}/'*|'$${ROOT}/'*|'scripts/'*)
        target="$ROOT/scripts/${ref#*scripts/}" ;;
      '${'*|'$${'*)
        # Any other brace prefix -- ${path.root}, ${terramate.stack.path.absolute}
        # -- is NOT the repo root and NOT beside the file. Guessing it is one
        # of those is exactly the silent-wrong-resolution this gate exists to
        # catch, so it fails instead of resolving against $ROOT/scripts/.
        checked=$((checked + 1)); failed=$((failed + 1))
        printf 'FAIL  %s:%s  unrecognised prefix: %s\n' "$file" "$line" "$ref"
        continue ;;
      *)
        target="$ROOT/scripts/${ref#*scripts/}" ;;
    esac
    checked=$((checked + 1))
    if [ ! -e "$target" ]; then
      printf 'FAIL  %s:%s  %s\n      resolved to %s\n' "$file" "$line" "$ref" "${target#"$ROOT"/}"
      failed=$((failed + 1))
    fi
  done < <(grep -oE '[$]?[$][{][^}]+[}](/\.\.)*/scripts/[A-Za-z0-9_./-]+\.(sh|py|js|ya?ml)|(^|[[:space:]"(])scripts/[A-Za-z0-9_./-]+\.(sh|py|js|ya?ml)' <<<"$text" \
             | sed -E 's/^[[:space:]"(]//')
  if [ "$got" -lt "$want" ]; then
    printf 'FAIL  %s:%s  a script path in a shape this gate cannot resolve\n' "$file" "$line"
    failed=$((failed + 1))
  fi
done < <(cd "$ROOT" && grep -rnE --exclude-dir=.terraform --include='*.tf' --include='*.tm.hcl' --include='*.tfvars' \
           'scripts/[A-Za-z0-9_./-]+\.(sh|py|js|ya?ml)' opentofu 2>/dev/null)

if [ "$checked" -lt "$FLOOR" ]; then
  echo "FAIL  checked $checked script reference(s), floor is $FLOOR: the extraction broke, not the references"
  exit 1
fi
echo "$checked script reference(s) on executed opentofu/terramate lines checked; $failed failed"
[ "$failed" -eq 0 ]
