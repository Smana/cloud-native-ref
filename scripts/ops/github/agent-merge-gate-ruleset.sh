#!/usr/bin/env bash
# Applies the merge-gate ruleset (SP3 §5.1, ADR-0045, OD-7) to one repository: `policy-bot: main`
# is required, and only from policy-bot's own App, which statuses:write cannot forge. Separate
# from agent-branches. Bypass: the admin role (the owner) for pull requests only, so an absent
# policy-bot never blocks the owner; Renovate always. CI itself stays non-bypassable.
#
# Idempotent: updates the ruleset carrying the JSON source's name when it exists.
# usage: POLICY_BOT_APP_SLUG=<slug> agent-merge-gate-ruleset.sh <owner/repo>
set -euo pipefail

REPO="${1:?usage: POLICY_BOT_APP_SLUG=<slug> agent-merge-gate-ruleset.sh <owner/repo>}"
# No apostrophe in this message: an unmatched ' inside ${VAR:?…} breaks bash's parsing.
: "${POLICY_BOT_APP_SLUG:?set POLICY_BOT_APP_SLUG to the policy-bot App slug}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE="$HERE/../../../.github/rulesets/agent-merge-gate.json"
name="$(jq -er .name "$SOURCE")"
policybot="$(gh api "/apps/$POLICY_BOT_APP_SLUG" --jq .id)"
renovate="$(gh api /apps/renovate --jq .id)"
# 5 is GitHub's built-in admin RepositoryRole: the owner of a user repository.
body="$(jq --argjson pb "$policybot" --argjson rn "$renovate" '
  .rules[0].parameters.required_status_checks[0].integration_id = $pb
  | .bypass_actors = [{"actor_id":5,"actor_type":"RepositoryRole","bypass_mode":"pull_request"},
                      {"actor_id":$rn,"actor_type":"Integration","bypass_mode":"always"}]' "$SOURCE")"
existing="$(gh api "repos/$REPO/rulesets?includes_parents=false&per_page=100" |
  jq -r --arg n "$name" 'first(.[] | select(.name == $n) | .id) // empty')"
if [ -n "$existing" ]; then
  gh api --method PUT "repos/$REPO/rulesets/$existing" --input - <<<"$body" >/dev/null
  echo "updated ruleset $name ($existing) on $REPO"
else
  gh api --method POST "repos/$REPO/rulesets" --input - <<<"$body" >/dev/null
  echo "created ruleset $name on $REPO"
fi
