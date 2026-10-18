#!/usr/bin/env bash
# Applies the merge-gate ruleset (SP3 §5.1, ADR-0045, OD-7) to one repository: `policy-bot: main`
# is required, and only from policy-bot's own App, which statuses:write cannot forge. Separate
# from agent-branches. Bypass: the admin role (the owner) for pull requests only, so an absent
# policy-bot never blocks the owner; Renovate always. CI itself stays non-bypassable.
#
# Idempotent: updates the ruleset carrying the JSON source's name when it exists.
# usage: [RENOVATE_BYPASS=false] POLICY_BOT_APP_SLUG=<slug> agent-merge-gate-ruleset.sh <owner/repo>
#    or: POLICY_BOT_APP_ID=<id> agent-merge-gate-ruleset.sh <owner/repo>
# A private App answers 404 on /apps/<slug> to a user token: pass its id (App settings page).
set -euo pipefail

REPO="${1:?usage: POLICY_BOT_APP_SLUG=<slug> or POLICY_BOT_APP_ID=<id> agent-merge-gate-ruleset.sh <owner/repo>}"
# No apostrophe in this message: an unmatched ' inside ${VAR:?…} breaks bash's parsing.
[ -n "${POLICY_BOT_APP_ID:-}" ] || : "${POLICY_BOT_APP_SLUG:?set POLICY_BOT_APP_SLUG or POLICY_BOT_APP_ID for the policy-bot App}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE="$HERE/../../../.github/rulesets/agent-merge-gate.json"
name="$(jq -er .name "$SOURCE")"
policybot="${POLICY_BOT_APP_ID:-$(gh api "/apps/$POLICY_BOT_APP_SLUG" --jq .id)}"
# RENOVATE_BYPASS=false: the repository has no Renovate installation, and GitHub refuses (422) an
# Integration bypass actor that is not installed on it.
renovate="[]"
[ "${RENOVATE_BYPASS:-true}" = false ] || renovate="[$(gh api /apps/renovate --jq .id)]"
# 5 is GitHub's built-in admin RepositoryRole: the owner of a user repository.
body="$(jq --argjson pb "$policybot" --argjson rn "$renovate" '
  .rules[0].parameters.required_status_checks[0].integration_id = $pb
  | .bypass_actors = [{"actor_id":5,"actor_type":"RepositoryRole","bypass_mode":"pull_request"}]
      + ($rn | map({"actor_id":., "actor_type":"Integration", "bypass_mode":"always"}))' "$SOURCE")"
existing="$(gh api "repos/$REPO/rulesets?includes_parents=false&per_page=100" |
  jq -r --arg n "$name" 'first(.[] | select(.name == $n) | .id) // empty')"
if [ -n "$existing" ]; then
  gh api --method PUT "repos/$REPO/rulesets/$existing" --input - <<<"$body" | { jq -c "select(.errors)" >&2 || true; }
  echo "updated ruleset $name ($existing) on $REPO"
else
  gh api --method POST "repos/$REPO/rulesets" --input - <<<"$body" | { jq -c "select(.errors)" >&2 || true; }
  echo "created ruleset $name on $REPO"
fi
