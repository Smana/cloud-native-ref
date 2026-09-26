#!/usr/bin/env bash
# Applies the agents' branch ruleset (SP1 design §6, OD-7) to one repository.
#
# Every actor NOT on the bypass list may only create, update or delete
# refs/heads/agent/**. The bypass list is every human role that can push (admin,
# maintain, write: the owner, collaborators, and App Wizard pushes made with a
# user's token), Renovate and, once SP3 ships, the factory's App, all `always`.
# A GitHub App is bypassed only when named, never through a role, so the agents'
# App is the only confined actor, and since it cannot update main, it cannot
# merge. SP3's merge-gate ruleset is a separate ruleset.
#
# Idempotent: updates the ruleset named `agent-branches` when it exists.
# usage: agent-branch-ruleset.sh <owner/repo>
#        FACTORY_APP_SLUG=<slug> adds the factory's App to the bypass list.
set -euo pipefail

REPO="${1:?usage: agent-branch-ruleset.sh <owner/repo>}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE="$HERE/../../../.github/rulesets/agent-branches.json"

# GitHub's built-in RepositoryRole ids: 5 admin (the owner of a user repo),
# 2 maintain, 4 write.
bypass="$(jq -c -n '[5, 2, 4] | map({"actor_id":., "actor_type":"RepositoryRole", "bypass_mode":"always"})')"
for slug in renovate ${FACTORY_APP_SLUG:-}; do
  id="$(gh api "/apps/$slug" --jq .id)"
  bypass="$(jq -c --argjson id "$id" '. + [{"actor_id":$id,"actor_type":"Integration","bypass_mode":"always"}]' <<<"$bypass")"
done
body="$(jq --argjson b "$bypass" '.bypass_actors = $b' "$SOURCE")"

existing="$(gh api "repos/$REPO/rulesets" --jq '.[] | select(.name == "agent-branches") | .id')"
if [ -n "$existing" ]; then
  gh api --method PUT "repos/$REPO/rulesets/$existing" --input - <<<"$body" >/dev/null
  echo "updated ruleset agent-branches ($existing) on $REPO"
else
  gh api --method POST "repos/$REPO/rulesets" --input - <<<"$body" >/dev/null
  echo "created ruleset agent-branches on $REPO"
fi
