#!/usr/bin/env bash
# Applies the agents' branch ruleset (SP1 design §6, OD-7) to one repository.
# Run it BEFORE the agents' App is installed there: until the ruleset exists,
# nothing stops that App from merging its own green PR (ADR-0043).
#
# Every actor NOT on the bypass list may only create, update or delete
# refs/heads/agent/**. The bypass list is every human role that can push (admin,
# maintain, write: the owner, collaborators, and App Wizard pushes made with a
# user's token) and Renovate, all `always`. SP3 (R16) moves main and the revert
# branches to agent-merge. A GitHub App is bypassed only when named, never
# through a role, so the agents' App is the only confined actor, and since it
# cannot update main, it cannot merge. SP3's merge-gate ruleset is a separate
# ruleset.
#
# Idempotent: updates the ruleset carrying the JSON source's name when it exists.
# usage: agent-branch-ruleset.sh <owner/repo>
set -euo pipefail

REPO="${1:?usage: agent-branch-ruleset.sh <owner/repo>}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE="$HERE/../../../.github/rulesets/agent-branches.json"
name="$(jq -er .name "$SOURCE")"

# GitHub's built-in RepositoryRole ids: 5 admin (the owner of a user repo),
# 2 maintain, 4 write.
bypass="$(jq -c -n '[5, 2, 4] | map({"actor_id":., "actor_type":"RepositoryRole", "bypass_mode":"always"})')"
# R16: Renovate is the only App on this list; the merger's lives in agent-merge.
renovate="$(gh api /apps/renovate --jq .id)"
bypass="$(jq -c --argjson id "$renovate" '. + [{"actor_id":$id,"actor_type":"Integration","bypass_mode":"always"}]' <<<"$bypass")"
body="$(jq --argjson b "$bypass" '.bypass_actors = $b' "$SOURCE")"

# includes_parents=false: an org-level ruleset of the same name is not ours to update.
list="$(gh api "repos/$REPO/rulesets?includes_parents=false&per_page=100")"
# R16: the split source leaves main and the revert branches to agent-merge. Without it they would
# be uncovered, and the agents' App could create a revert-* branch.
if jq -e '.conditions.ref_name.exclude | index("refs/heads/main")' "$SOURCE" >/dev/null &&
  ! jq -e 'any(.[]; .name == "agent-merge")' <<<"$list" >/dev/null; then
  echo "refusing: apply agent-merge first (task ops:github:agent-merge-ruleset)" >&2
  exit 1
fi
existing="$(jq -r --arg n "$name" 'first(.[] | select(.name == $n) | .id) // empty' <<<"$list")"
if [ -n "$existing" ]; then
  # The PUT replaces the bypass list: warn loudly when it drops an App.
  dropped="$(gh api "repos/$REPO/rulesets/$existing" |
    jq -c --argjson b "$bypass" '[.bypass_actors[]? | select(.actor_type == "Integration") | .actor_id] - [$b[] | select(.actor_type == "Integration") | .actor_id]')"
  [ "$dropped" = "[]" ] || echo "warning: this update removes App(s) $dropped from the bypass list (R16: only Renovate bypasses agent-branches)" >&2
  gh api --method PUT "repos/$REPO/rulesets/$existing" --input - <<<"$body" >/dev/null
  echo "updated ruleset $name ($existing) on $REPO"
else
  gh api --method POST "repos/$REPO/rulesets" --input - <<<"$body" >/dev/null
  echo "created ruleset $name on $REPO"
fi
