#!/usr/bin/env bash
# Applies the agents' two rulesets (SP1 design §6, OD-7) to one repository.
# Run it BEFORE the agents' App is installed there: until the rulesets exist,
# nothing stops that App from merging its own green PR (ADR-0043).
#
#   agent-branches  every actor NOT on the bypass list may only create, update
#                   or delete refs/heads/agent/**; SP3 (R16) moves main and the
#                   revert branches to agent-merge
#   agent-tags      the same actors may not create, update or delete any tag:
#                   `contents: write` covers refs/tags/*, so without it the App
#                   could push a tag that a `tags:` workflow fires on
#
# Both carry the same bypass list: every human role that can push (admin,
# maintain, write: the owner, collaborators, and App Wizard pushes made with a
# user's token) and Renovate, all `always`. A GitHub App is bypassed only when
# named, never through a role, so the agents' App is the only confined actor,
# and since it cannot update main, it cannot merge. SP3's merge-gate ruleset is
# a separate ruleset.
#
# Idempotent: updates each ruleset carrying its JSON source's name when it exists.
# usage: agent-branch-ruleset.sh <owner/repo>
set -euo pipefail

REPO="${1:?usage: agent-branch-ruleset.sh <owner/repo>}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RULESETS="$HERE/../../../.github/rulesets"

# GitHub's built-in RepositoryRole ids: 5 admin (the owner of a user repo),
# 2 maintain, 4 write.
bypass="$(jq -c -n '[5, 2, 4] | map({"actor_id":., "actor_type":"RepositoryRole", "bypass_mode":"always"})')"
# R16: Renovate is the only App on these lists; the merger's lives in agent-merge.
renovate="$(gh api /apps/renovate --jq .id)"
bypass="$(jq -c --argjson id "$renovate" '. + [{"actor_id":$id,"actor_type":"Integration","bypass_mode":"always"}]' <<<"$bypass")"

# includes_parents=false: an org-level ruleset of the same name is not ours to update.
current="$(gh api "repos/$REPO/rulesets?includes_parents=false&per_page=100")"
# R16: the split source leaves main and the revert branches to agent-merge. Without it they would
# be uncovered, and the agents' App could create a revert-* branch.
if jq -e '.conditions.ref_name.exclude | index("refs/heads/main")' "$RULESETS/agent-branches.json" >/dev/null &&
  ! jq -e 'any(.[]; .name == "agent-merge")' <<<"$current" >/dev/null; then
  echo "refusing: apply agent-merge first (task ops:github:agent-merge-ruleset)" >&2
  exit 1
fi

for source in "$RULESETS/agent-branches.json" "$RULESETS/agent-tags.json"; do
  name="$(jq -er .name "$source")"
  body="$(jq --argjson b "$bypass" '.bypass_actors = $b' "$source")"
  existing="$(jq -r --arg n "$name" 'first(.[] | select(.name == $n) | .id) // empty' <<<"$current")"
  if [ -n "$existing" ]; then
    # The PUT replaces the bypass list: warn loudly when it drops an App.
    dropped="$(gh api "repos/$REPO/rulesets/$existing" |
      jq -c --argjson b "$bypass" '[.bypass_actors[]? | select(.actor_type == "Integration") | .actor_id] - [$b[] | select(.actor_type == "Integration") | .actor_id]')"
    [ "$dropped" = "[]" ] || echo "warning: updating $name removes App(s) $dropped from its bypass list (R16: only Renovate bypasses the agents' rulesets)" >&2
    gh api --method PUT "repos/$REPO/rulesets/$existing" --input - <<<"$body" >/dev/null
    echo "updated ruleset $name ($existing) on $REPO"
  else
    gh api --method POST "repos/$REPO/rulesets" --input - <<<"$body" >/dev/null
    echo "created ruleset $name on $REPO"
  fi
done
