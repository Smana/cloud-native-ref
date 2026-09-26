#!/usr/bin/env bash
# Applies the agents' branch ruleset (SP1 design §6, OD-7) to one repository.
# Run it BEFORE the agents' App is installed there: until the ruleset exists,
# nothing stops that App from merging its own green PR (ADR-0043).
#
# Every actor NOT on the bypass list may only create, update or delete
# refs/heads/agent/**. The bypass list is every human role that can push (admin,
# maintain, write: the owner, collaborators, and App Wizard pushes made with a
# user's token), Renovate and, once SP3 ships, the factory's App, all `always`.
# A GitHub App is bypassed only when named, never through a role, so the agents'
# App is the only confined actor, and since it cannot update main, it cannot
# merge. SP3's merge-gate ruleset is a separate ruleset.
#
# Idempotent: updates the ruleset carrying the JSON source's name when it exists.
# usage: agent-branch-ruleset.sh <owner/repo>
#        FACTORY_APP_SLUG=<slug> adds the factory's App to the bypass list.
set -euo pipefail

REPO="${1:?usage: agent-branch-ruleset.sh <owner/repo>}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE="$HERE/../../../.github/rulesets/agent-branches.json"
name="$(jq -r .name "$SOURCE")"

# GitHub's built-in RepositoryRole ids: 5 admin (the owner of a user repo),
# 2 maintain, 4 write.
bypass="$(jq -c -n '[5, 2, 4] | map({"actor_id":., "actor_type":"RepositoryRole", "bypass_mode":"always"})')"
for slug in renovate ${FACTORY_APP_SLUG:-}; do
  id="$(gh api "/apps/$slug" --jq .id)"
  bypass="$(jq -c --argjson id "$id" '. + [{"actor_id":$id,"actor_type":"Integration","bypass_mode":"always"}]' <<<"$bypass")"
done
body="$(jq --argjson b "$bypass" '.bypass_actors = $b' "$SOURCE")"

# includes_parents=false: an org-level ruleset of the same name is not ours to update.
existing="$(gh api "repos/$REPO/rulesets?includes_parents=false&per_page=100" |
  jq -r --arg n "$name" 'first(.[] | select(.name == $n) | .id) // empty')"
if [ -n "$existing" ]; then
  # The PUT replaces the bypass list: re-running without FACTORY_APP_SLUG after
  # SP3 would silently stop the factory's App from arming merges.
  dropped="$(gh api "repos/$REPO/rulesets/$existing" |
    jq -c --argjson b "$bypass" '[.bypass_actors[]? | select(.actor_type == "Integration") | .actor_id] - [$b[] | select(.actor_type == "Integration") | .actor_id]')"
  [ "$dropped" = "[]" ] || echo "warning: this update removes App(s) $dropped from the bypass list; set FACTORY_APP_SLUG to keep the factory's" >&2
  gh api --method PUT "repos/$REPO/rulesets/$existing" --input - <<<"$body" >/dev/null
  echo "updated ruleset $name ($existing) on $REPO"
else
  gh api --method POST "repos/$REPO/rulesets" --input - <<<"$body" >/dev/null
  echo "created ruleset $name on $REPO"
fi
