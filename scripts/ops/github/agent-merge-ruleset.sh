#!/usr/bin/env bash
# Applies the merge ruleset (SP3 R16; owner, 2026-09-27) to one repository: main and the revert
# branches may be created, updated or deleted only by the human roles, Renovate and the merger App.
# The factory's App and the agents' App are on no list. Apply it BEFORE the split agent-branches,
# which refuses otherwise, so main and revert-* are never uncovered.
#
# Idempotent: updates the ruleset carrying the JSON source's name when it exists.
# usage: MERGER_APP_SLUG=<slug> agent-merge-ruleset.sh <owner/repo>
set -euo pipefail

REPO="${1:?usage: MERGER_APP_SLUG=<slug> agent-merge-ruleset.sh <owner/repo>}"
# No apostrophe in this message: an unmatched ' inside ${VAR:?…} breaks bash's parsing.
: "${MERGER_APP_SLUG:?set MERGER_APP_SLUG to the merger App slug}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE="$HERE/../../../.github/rulesets/agent-merge.json"
name="$(jq -er .name "$SOURCE")"
merger="$(gh api "/apps/$MERGER_APP_SLUG" --jq .id)"
renovate="$(gh api /apps/renovate --jq .id)"
# 5, 2, 4 are GitHub's built-in admin, maintain and write RepositoryRoles: the humans who can push.
body="$(jq --argjson m "$merger" --argjson rn "$renovate" '
  .bypass_actors = ([5, 2, 4] | map({"actor_id":., "actor_type":"RepositoryRole", "bypass_mode":"always"}))
    + [{"actor_id":$rn,"actor_type":"Integration","bypass_mode":"always"},
       {"actor_id":$m,"actor_type":"Integration","bypass_mode":"always"}]' "$SOURCE")"
existing="$(gh api "repos/$REPO/rulesets?includes_parents=false&per_page=100" |
  jq -r --arg n "$name" 'first(.[] | select(.name == $n) | .id) // empty')"
if [ -n "$existing" ]; then
  gh api --method PUT "repos/$REPO/rulesets/$existing" --input - <<<"$body" >/dev/null
  echo "updated ruleset $name ($existing) on $REPO"
else
  gh api --method POST "repos/$REPO/rulesets" --input - <<<"$body" >/dev/null
  echo "created ruleset $name on $REPO"
fi
