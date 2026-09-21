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
  while IFS= read -r ref; do
    [ -n "$ref" ] || continue
    if [[ "$ref" == '${path.module}/'* ]]; then
      target="$ROOT/$(dirname "$file")/${ref#'${path.module}/'}"
    else
      target="$ROOT/scripts/${ref#*scripts/}"
    fi
    checked=$((checked + 1))
    if [ ! -e "$target" ]; then
      printf 'FAIL  %s:%s  %s\n      resolved to %s\n' "$file" "$line" "$ref" "${target#"$ROOT"/}"
      failed=$((failed + 1))
    fi
  done < <(grep -oE '[$]?[$][{][^}]+[}](/\.\.)*/scripts/[A-Za-z0-9_./-]+\.(sh|py|js)|(^|[[:space:]"(])scripts/[A-Za-z0-9_./-]+\.(sh|py|js)' <<<"$text" \
             | sed -E 's/^[[:space:]"(]//')
done < <(cd "$ROOT" && grep -rnE --include='*.tf' --include='*.tm.hcl' --include='*.tfvars' \
           'scripts/[A-Za-z0-9_./-]+\.(sh|py|js)' opentofu 2>/dev/null)

if [ "$checked" -lt "$FLOOR" ]; then
  echo "FAIL  checked $checked script reference(s), floor is $FLOOR: the extraction broke, not the references"
  exit 1
fi
echo "$checked script reference(s) on executed opentofu/terramate lines checked; $failed failed"
[ "$failed" -eq 0 ]
