#!/usr/bin/env bash
# Reconcile ZITADEL project-role grants from Google Workspace group membership.
#
# The matrix (security/base/access-matrix/matrix.yaml) says which Workspace
# group backs which team; this makes ZITADEL agree. Adding or removing someone
# in Workspace becomes the only action needed.
#
# DRY RUN BY DEFAULT. --apply writes.
#
# Sourceable: the CLI is guarded at the bottom so scripts/test-access-matrix-
# sync.sh can call reconcile_team directly with fixtures and no network.
set -uo pipefail

# GUARD 3 trips when revocations EXCEED max(n_current / MAX_REVOKE_FRACTION,
# MIN_REVOKE_FLOOR), or REACH n_current -- i.e. every current holder -- unless
# --max-revocations raises the limit. MIN_REVOKE_FLOOR is a FLOOR, not a cap:
# 10 holders allow up to 5 revocations (10/2), while a 3-member team's raw
# fraction (1) is floored up to 2 so a couple of legitimate leavers still get
# through. It is the n_current clause -- not the floor -- that keeps a team
# from ever being revoked to zero through this guard: with a pure 1/2 fraction
# and no floor, one remaining holder already allows 0, so revoking that last
# holder trips anyway.
MAX_REVOKE_FRACTION=2      # denominator: 1/2
MIN_REVOKE_FLOOR=2

# Teams that must never be left with zero members. The platform team is the
# break-glass path for Kubernetes, which has no equivalent of OpenBao's
# userpass login.
PROTECTED_TEAMS="platform"

# reconcile_team <team> <members-json|__UNREADABLE__> <grants-json>
#
# Pure: no network, no writes. Prints one action per line and returns non-zero
# when a guard stops the run. Every caller must treat a non-zero return as "do
# nothing for this team", never as "continue with what was printed".
#
# ZITADEL holds one grant per user per project, carrying a list of role keys --
# "grant"/"revoke" here mean "add/remove this team's role on that grant", never
# "create/delete the whole grant". Task 8 turns these per-team intents into
# per-user grant updates.
reconcile_team() {
    local team="$1" members="$2" grants="$3"

    # GUARD 1 -- an unreadable group is not an empty group.
    #
    # This is the guard that stops a Google outage becoming a lockout. Treating
    # a failed list as "nobody is in this group" would revoke every grant on the
    # platform, and every downstream consumer would start denying at once.
    if [ "$members" = "__UNREADABLE__" ]; then
        echo "GUARD unreadable: could not list the Workspace group for ${team}; making no change"
        return 1
    fi

    local current want to_grant to_revoke n_revoke n_current
    want="$(jq -r '.[]' <<<"$members" | sort -u)"
    current="$(jq -r '.[].email' <<<"$grants" | sort -u)"

    to_grant="$(comm -23 <(printf '%s\n' "$want") <(printf '%s\n' "$current"))"
    to_revoke="$(comm -13 <(printf '%s\n' "$want") <(printf '%s\n' "$current"))"

    n_current="$(grep -c . <<<"$current")"
    n_revoke="$(grep -c . <<<"$to_revoke")"

    # GUARD 2 -- never empty a protected team.
    if [[ " $PROTECTED_TEAMS " == *" $team "* ]] \
       && [ "$n_revoke" -ge "$n_current" ] && [ "$n_current" -gt 0 ]; then
        echo "GUARD zero-members: refusing to leave ${team} with no members"
        return 1
    fi

    # GUARD 3 -- blast radius.
    if [ "$n_revoke" -gt 0 ]; then
        local allowed=$(( n_current / MAX_REVOKE_FRACTION ))
        [ "$allowed" -lt "$MIN_REVOKE_FLOOR" ] && allowed="$MIN_REVOKE_FLOOR"
        if [ "$n_revoke" -gt "$allowed" ] || [ "$n_revoke" -ge "$n_current" ]; then
            echo "GUARD blast-radius: ${n_revoke} of ${n_current} grants for ${team} would be revoked (max ${allowed}); making no change"
            return 1
        fi
    fi

    # GUARD 4 -- a member with no ZITADEL user is normal, not an error. A user
    # exists only after their first login, so the grant simply lands on a later
    # run.
    local email
    while read -r email; do
        [ -z "$email" ] && continue
        if zitadel_user_id "$email" >/dev/null 2>&1; then
            echo "grant ${email}"
        else
            echo "skip-no-user ${email}"
        fi
    done <<<"$to_grant"

    while read -r email; do
        [ -z "$email" ] && continue
        echo "revoke ${email}"
    done <<<"$to_revoke"

    return 0
}

# Overridden by the tests. The real implementation lands in Task 8.
if ! declare -F zitadel_user_id >/dev/null; then
    zitadel_user_id() { case "$1" in ghost@*) return 1 ;; *) echo "stub" ;; esac; }
fi

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    echo "CLI lands in Task 8; this file is currently sourceable only." >&2
    exit 64
fi
