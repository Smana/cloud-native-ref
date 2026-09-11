#!/usr/bin/env bash
# Reconcile ZITADEL project-role grants from Google Workspace group membership.
#
# The matrix (security/base/access-matrix/matrix.yaml) says which Workspace
# group backs which team; this makes ZITADEL agree. Adding or removing someone
# in Workspace becomes the only action needed.
#
# DRY RUN BY DEFAULT. --apply writes. `--help` lists flags and environment.
#
# Sourceable: the CLI is guarded at the bottom so scripts/test-access-matrix-
# sync.sh can call every function directly with fixtures and no network.
#
# THE WRITE MODEL. ZITADEL keeps ONE user grant per (user, project), holding a
# roleKeys LIST. A team's "grant"/"revoke" is therefore never a grant
# create/delete: it adds or removes that team's role on the user's one grant.
# Per run:
#
#   1. read everything ONCE: the users, the project's grants, each team's group;
#   2. per team, reconcile_team turns (members, holders) into intents -- or trips
#      a guard, and then contributes NO intent at all;
#   3. plan_user_changes (pure) folds every intent into ONE change per user,
#      starting from the roles that user holds now, so any role no intent names
#      -- a legacy `admin`, a tripped team's role -- is carried through;
#   4. apply_user_changes POSTs, PUTs or DELETEs that user's grant.
set -uo pipefail

# GUARD 3 trips when revocations EXCEED max(n_current / MAX_REVOKE_FRACTION,
# MIN_REVOKE_FLOOR), or REACH n_current -- i.e. every current holder.
# MIN_REVOKE_FLOOR is a FLOOR, not a cap: 10 holders allow up to 5 revocations
# (10/2), while a 3-member team's raw fraction (1) is floored up to 2 so a
# couple of legitimate leavers still get through. It is the n_current clause
# -- not the floor -- that keeps a team from ever being revoked to zero through
# this guard: with a pure 1/2 fraction and no floor, one remaining holder
# already allows 0, so revoking that last holder trips anyway.
#
# --max-revocations <n> (MAX_REVOCATIONS) REPLACES that limit outright: n IS
# the limit, with no floor, so `--max-revocations 0` really means zero. It
# replaces ONLY the limit. The reaches-n_current clause, guard 1 (unreadable)
# and guard 2 (never empty platform) hold whatever the cap.
MAX_REVOKE_FRACTION=2      # denominator: 1/2
MIN_REVOKE_FLOOR=2

# Teams that must never be left with zero members. The platform team is the
# break-glass path for Kubernetes, which has no equivalent of OpenBao's
# userpass login.
PROTECTED_TEAMS="platform"

# Both ZITADEL searches ask for this many results in ONE page. A page that
# comes back full is treated as possibly truncated -- see refuse_truncated.
ZITADEL_SEARCH_LIMIT=1000

# Writes happen only when main sees --apply. Not read from the environment: an
# APPLY=true left in some shell must never turn a dry run into writes.
APPLY=false

_SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ACCESS_MATRIX="${ACCESS_MATRIX:-$(dirname "$_SCRIPTS_DIR")/security/base/access-matrix/matrix.yaml}"

# shellcheck source=scripts/lib/zitadel-pat.sh
source "$_SCRIPTS_DIR/lib/zitadel-pat.sh"

# reconcile_team <team> <members-json|__UNREADABLE__> <grants-json>
#
# Pure: no network, no writes -- zitadel_user_id is a lookup in the PRELOADED
# users map. Prints one action per line and returns non-zero when a guard stops
# the run. Every caller must treat a non-zero return as "do nothing for this
# team", never as "continue with what was printed".
#
# ZITADEL holds one grant per user per project, carrying a list of role keys --
# "grant"/"revoke" here mean "add/remove this team's role on that grant", never
# "create/delete the whole grant". plan_user_changes turns these per-team
# intents into per-user grant updates.
reconcile_team() {
    local team="$1" members="$2" grants="$3"

    # GUARD 1 -- an unreadable group is not an empty group.
    #
    # This is the guard that stops a Google outage becoming a lockout. Treating
    # a failed list as "nobody is in this group" would revoke every grant on the
    # platform, and every downstream consumer would start denying at once.
    #
    # Anything that is not a JSON array of strings is unreadable too: `not-json`
    # would otherwise read as an empty group, and an error body such as
    # {"error":"quota"} as a member named `quota`.
    if [ "$members" = "__UNREADABLE__" ] \
       || ! jq -e 'type == "array" and all(.[]; type == "string")' \
                >/dev/null 2>&1 <<<"$members"; then
        echo "GUARD unreadable: could not list the Workspace group for ${team}; making no change"
        return 1
    fi

    # Lowercased on BOTH sides. Compared as-is, Workspace `A@x` against a
    # ZITADEL holder `a@x` makes a@x a revoke and A@x a grant that resolves to
    # no user -- and the person silently loses the role.
    local current want to_grant to_revoke n_revoke n_current
    want="$(jq -r '.[] | ascii_downcase' <<<"$members" | sort -u)"
    current="$(jq -r '.[].email // empty | ascii_downcase' <<<"$grants" | sort -u)"

    to_grant="$(comm -23 <(printf '%s\n' "$want") <(printf '%s\n' "$current"))"
    to_revoke="$(comm -13 <(printf '%s\n' "$want") <(printf '%s\n' "$current"))"

    # --grants-only computes no revocations at all. Guards 2 and 3 are
    # revocation guards, so they become moot; guard 1 above still applied,
    # because an unreadable group cannot yield trustworthy grants either.
    [ "${GRANTS_ONLY:-false}" = true ] && to_revoke=""

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
        local allowed
        if [ -n "${MAX_REVOCATIONS:-}" ]; then
            allowed="$MAX_REVOCATIONS"
        else
            allowed=$(( n_current / MAX_REVOKE_FRACTION ))
            [ "$allowed" -lt "$MIN_REVOKE_FLOOR" ] && allowed="$MIN_REVOKE_FLOOR"
        fi
        if [ "$n_revoke" -gt "$allowed" ] || [ "$n_revoke" -ge "$n_current" ]; then
            echo "GUARD blast-radius: ${n_revoke} of ${n_current} grants for ${team} would be revoked (max ${allowed}); making no change"
            return 1
        fi
    fi

    # GUARD 4 -- a member with no ZITADEL user is normal, not an error. A user
    # exists only after their first login, so the grant simply lands on a later
    # run. An email naming MORE than one user is not that: it is emitted as a
    # grant, which plan_user_changes drops as ambiguous -- failing the run.
    local email found
    while read -r email; do
        [ -z "$email" ] && continue
        zitadel_user_id "$email" >/dev/null 2>&1; found=$?
        if [ "$found" -eq 1 ]; then
            echo "skip-no-user ${email}"
        else
            echo "grant ${email}"
        fi
    done <<<"$to_grant"

    while read -r email; do
        [ -z "$email" ] && continue
        echo "revoke ${email}"
    done <<<"$to_revoke"

    return 0
}

# zitadel_user_id <email> -- the userId for an email, from the preloaded users
# map USERS_JSON (see load_users). No network: reconcile_team calls this per
# member, and its purity is load-bearing. Matches userName or email,
# case-insensitively -- the lookup grant_admin_role in zitadel-oidc-clients.sh
# already uses in production. An email naming more than one user resolves to
# NOBODY: granting a role to the wrong person is worse than granting it late.
# Returns 1 when no user has the email (first login pending), 2 when more than
# one does -- reconcile_team tells the two apart.
zitadel_user_id() {
    local ids
    ids="$(jq -r --arg e "${1,,}" \
        '[.[] | select(.email == $e or .userName == $e) | .userId] | unique | .[]' \
        <<<"${USERS_JSON:-[]}")" || return 3
    case "$(grep -c . <<<"$ids")" in
        0) return 1 ;;
        1) printf '%s\n' "$ids" ;;
        *) return 2 ;;
    esac
}

# For log lines only.
zitadel_user_email() {
    jq -r --arg u "$1" 'first(.[] | select(.userId == $u) | .email) // "?"' \
        <<<"${USERS_JSON:-[]}"
}

# team_holders <team> <grants-json> <users-json> -- reconcile_team's
# grants_json: [{email, userId}] for the users holding <team>'s role, with the
# email mapped through the users list, never taken from the grant. A holder
# with no entry there is EXCLUDED and logged. That is safe both ways: excluded
# from `current` they cannot be revoked, and a grant intent for them resolves
# to no user and is skipped.
team_holders() {
    local team="$1" grants="$2" users="$3"
    jq -r --arg t "$team" --argjson users "$users" '
        .[] | select(any(.roleKeys[]?; . == $t)) | .userId as $u
        | select(all($users[]; .userId != $u))
        | "[exclude] \($t): holder \($u) has no user in the users list; not a member, never revoked"' \
        <<<"$grants" >&2
    jq -c --arg t "$team" --argjson users "$users" '
        [.[] | select(any(.roleKeys[]?; . == $t)) | .userId as $u
         | (first($users[] | select(.userId == $u)) // null) as $user
         | select($user != null) | {email: $user.email, userId: $u}]' <<<"$grants"
}

# plan_user_changes <intents> <grants-json> <users-json>
#
# PURE: no network, no globals. <intents> is lines of
# "<grant|revoke> <team> <email>". Prints one line per user an intent names:
#
#   <op> <userId> <grantId|-> <roleKeys-json>      op: post | put | delete | none
#
#   new = the user's CURRENT roleKeys + every team granted - every team revoked
#
#   no grant, new non-empty -> post         grant, new == current -> none
#   grant, new empty        -> delete       grant, new differs    -> put
#
# Starting from the current roles is what makes it safe: a role no intent names
# -- a legacy `admin`, or the role of a team whose guard tripped, since a
# tripped team emits no intent -- is carried through untouched, and a user in
# two teams gets ONE write carrying both. roleKeys are sorted and de-duplicated
# so `none` is detected reliably.
#
# A grant and a revoke of one team for one user (two aliases of one person)
# resolve to the grant: this errs toward keeping access.
#
# An intent the planner cannot place is DROPPED, on its own line:
#
#   drop <verb> <team> <email>: <reason>
#
# -- an email naming more than one user, or a user holding more than one grant
# on the project (which one to write would be a guess). apply_user_changes
# fails the run on it, after applying everything else: a revoke the guards
# approved must never vanish behind a green run. An email naming NO user is a
# first login still pending -- normal, logged, not a drop.
plan_user_changes() {
    local intents="$1" grants="$2" users="$3" line
    jq -rn --arg intents "$intents" --argjson grants "$grants" --argjson users "$users" '
      def ids($e): [$users[] | select(.email == $e or .userName == $e) | .userId] | unique;
      [ $intents | split("\n")[] | select(length > 0) | split(" ")
        | {verb: .[0], team: .[1], email: (.[2] | ascii_downcase)}
        | . + {ids: ids(.email)} ]
      | (.[] | select(.ids | length == 0)
         | "# no ZITADEL user for \(.email) (first login pending); \(.verb) \(.team) skipped"),
        (.[] | select(.ids | length > 1)
         | "drop \(.verb) \(.team) \(.email): the email names \(.ids | length) ZITADEL users (\(.ids | join(", ")))"),
        (map(select(.ids | length == 1) | . + {userId: .ids[0]}) | group_by(.userId)[]
         | .[0].userId as $u
         | [$grants[] | select(.userId == $u)] as $g
         | if ($g | length) > 1 then
             .[] | "drop \(.verb) \(.team) \(.email): user \($u) holds \($g | length) grants on the project; which one to change would be a guess"
           else
             ($g[0].roleKeys // [] | unique) as $cur
             | (map(select(.verb == "grant")  | .team) | unique) as $add
             | (map(select(.verb == "revoke") | .team) | unique) as $rem
             | (($cur + $add | unique) - ($rem - $add)) as $new
             | if ($g | length) == 0 then
                 (if ($new | length) > 0 then "post" else "none" end) + " \($u) - \($new | tojson)"
               elif $new == $cur then "none \($u) \($g[0].grantId) \($cur | tojson)"
               elif ($new | length) == 0 then "delete \($u) \($g[0].grantId) []"
               else "put \($u) \($g[0].grantId) \($new | tojson)"
               end
           end)' \
    | while IFS= read -r line; do
          case "$line" in
              '# '*) printf '%s\n' "${line#\# }" >&2 ;;
              *)     printf '%s\n' "$line" ;;
          esac
      done
}

# write_grant <op> <userId> <grantId> <roleKeys-json> -- one plan line's write.
write_grant() {
    case "$1" in
        post)   zitadel_post_grant "$2" "$4" ;;
        put)    zitadel_put_grant "$2" "$3" "$4" ;;
        delete) zitadel_delete_grant "$2" "$3" ;;
        *)      echo "unknown plan op: $1" >&2; return 1 ;;
    esac
}

# apply_user_changes, reading plan lines on stdin.
#
# Dry run (the default) prints what it would do and writes nothing. With
# --apply a failed write is reported and the run moves on to the next user --
# one user's failure must not strand everybody else's change -- but the return
# status is non-zero.
apply_user_changes() {
    local line op user_id grant_id roles who failed=0 n_change=0 n_none=0 n_failed=0 n_dropped=0
    while IFS= read -r line; do
        read -r op user_id grant_id roles <<<"$line"
        [ -z "$op" ] && continue
        case "$op" in
            none) n_none=$((n_none + 1)); continue ;;
            # An intent the planner could not place. Everything else still
            # applies; the run still fails -- in a dry run too -- so an approved
            # revoke that never happened cannot hide behind a green CronJob.
            drop) echo "[DROPPED] ${line#drop }"
                  failed=1; n_dropped=$((n_dropped + 1)); continue ;;
        esac
        n_change=$((n_change + 1))
        who="$(zitadel_user_email "$user_id") (${user_id})"
        if [ "$APPLY" != true ]; then
            echo "[dry-run] would ${op} the grant of ${who}: roles -> ${roles}"
            continue
        fi
        if write_grant "$op" "$user_id" "$grant_id" "$roles"; then
            echo "[${op}] the grant of ${who}: roles -> ${roles}"
        else
            echo "[FAILED ] ${op} the grant of ${who}: roles -> ${roles}"
            failed=1; n_failed=$((n_failed + 1))
        fi
    done
    echo "summary: ${n_change} to change, ${n_none} unchanged, ${n_dropped} dropped, ${n_failed} failed ($([ "$APPLY" = true ] && echo applied || echo dry run))"
    return "$failed"
}

# ── the network halves ────────────────────────────────────────────────────────
#
# zitadel_api is defined here rather than reused: api() lives inside
# scripts/zitadel-oidc-clients.sh, which parses --cluster/--cloud at the top of
# the file and so cannot be sourced -- the same constraint
# scripts/test-zitadel-idp-convergence.sh documents for its own restatement.
# The authentication half is reused via scripts/lib/zitadel-pat.sh.
#
# curl -K reads the credential from a file descriptor rather than argv, so the
# PAT never appears in the process table. scripts/test-no-secret-argv.sh gates
# this class of mistake repo-wide.
zitadel_api() {
    local method="$1" path="$2"
    shift 2
    curl -fsS -X "$method" "${IDP_URL}${path}" \
        -K <(printf 'header = "Authorization: Bearer %s"\n' "$ZITADEL_PAT") \
        -H "Content-Type: application/json" \
        "$@"
}

zitadel_post_grant() {   # <userId> <roleKeys-json>
    zitadel_api POST "/management/v1/users/${1}/grants" \
        -d "$(jq -nc --arg p "$ZITADEL_PROJECT_ID" --argjson r "$2" \
              '{projectId: $p, roleKeys: $r}')" >/dev/null
}

zitadel_put_grant() {    # <userId> <grantId> <roleKeys-json> -- REPLACES the list
    zitadel_api PUT "/management/v1/users/${1}/grants/${2}" \
        -d "$(jq -nc --argjson r "$3" '{roleKeys: $r}')" >/dev/null
}

zitadel_delete_grant() { # <userId> <grantId>
    zitadel_api DELETE "/management/v1/users/${1}/grants/${2}" >/dev/null
}

# refuse_truncated <search-response> <what> -- non-zero, with a message, if the
# response may hold only part of the result set: a page that came back full,
# or fewer results than the server's own totalResult (a server-side cap below
# our limit). A missing user or grant makes a real holder look absent. An
# unparseable response is refused too.
refuse_truncated() {
    if ! jq -e --argjson limit "$ZITADEL_SEARCH_LIMIT" '
            (.result // []) as $r
            | ($r | length) < $limit
              and ($r | length) >= ((.details.totalResult // 0) | tonumber)' \
            >/dev/null 2>&1 <<<"$1"; then
        echo "[FAILED ] the ZITADEL $2 search may be truncated, or is unreadable; changing nothing" >&2
        return 1
    fi
}

# ONE search for the whole run; every lookup after it is local. Prints the
# users map, [{userId, email, userName}], lowercased, HUMAN users only: a
# machine user is never a Workspace member, so leaving it out makes a machine
# holder EXCLUDED (never revoked) rather than revoked for being in no group.
# The email is .human.email.email, falling back to .userName.
load_users() {
    local resp
    resp="$(zitadel_api POST /management/v1/users/_search \
        -d "{\"query\":{\"limit\":${ZITADEL_SEARCH_LIMIT}}}")" \
        || { echo "[FAILED ] the ZITADEL user search failed" >&2; return 1; }
    refuse_truncated "$resp" user || return 1
    jq -c '[.result // [] | .[] | select(.human != null)
            | {userId: .id,
               email: ((.human.email.email // .userName) | ascii_downcase),
               userName: (.userName | ascii_downcase)}]' <<<"$resp"
}

# ONE search for the project's grants: [{userId, grantId, roleKeys}]. Any email
# on the grant object is NOT used -- userId is mapped through the users list
# (team_holders). Filtered to this project client-side too: a grant of another
# project must never be PUT with this project's roles.
load_grants() {
    local resp
    if [ -z "${ZITADEL_PROJECT_ID:-}" ]; then
        echo "[FAILED ] ZITADEL_PROJECT_ID is empty; the grant search would span every project" >&2
        return 1
    fi
    resp="$(zitadel_api POST /management/v1/users/grants/_search \
        -d "$(jq -nc --arg p "$ZITADEL_PROJECT_ID" --argjson limit "$ZITADEL_SEARCH_LIMIT" \
              '{query: {limit: $limit}, queries: [{projectIdQuery: {projectId: $p}}]}')")" \
        || { echo "[FAILED ] the ZITADEL grant search failed" >&2; return 1; }
    refuse_truncated "$resp" grant || return 1
    jq -c --arg p "$ZITADEL_PROJECT_ID" \
        '[.result // [] | .[] | select(.projectId == $p)
          | {userId, grantId: .id, roleKeys: (.roleKeys // [])}]' <<<"$resp"
}

# Sets ZITADEL_PROJECT_ID, by name when it is not given -- the way
# ensure_project in zitadel-oidc-clients.sh finds it. A fresh bootstrap mints a
# new project id no manifest could know in advance; the name survives.
resolve_project_id() {
    [ -n "${ZITADEL_PROJECT_ID:-}" ] && return 0
    local name="${ZITADEL_PROJECT_NAME:-platform}" resp id
    resp="$(zitadel_api POST /management/v1/projects/_search -d '{"queries":[]}')" \
        || { echo "[FAILED ] the ZITADEL project search failed" >&2; return 1; }
    id="$(jq -r --arg n "$name" '[.result // [] | .[] | select(.name == $n) | .id]
          | if length == 1 then .[0] else empty end' <<<"$resp")"
    if [ -z "$id" ]; then
        echo "[FAILED ] expected exactly one ZITADEL project named '${name}'; set ZITADEL_PROJECT_ID or ZITADEL_PROJECT_NAME" >&2
        return 1
    fi
    ZITADEL_PROJECT_ID="$id"
}

# Keyless delegated token -- see the Task 6 note for why there is no key file.
google_token() {
    local now claim assertion
    now="$(date +%s)"
    claim="$(jq -nc --arg iss "$GOOGLE_SA" --arg sub "$GOOGLE_SUBJECT" \
        --arg scope "https://www.googleapis.com/auth/admin.directory.group.readonly" \
        --argjson iat "$now" --argjson exp "$((now + 3600))" \
        '{iss:$iss, sub:$sub, scope:$scope,
          aud:"https://oauth2.googleapis.com/token", iat:$iat, exp:$exp}')"
    assertion="$(gcloud iam service-accounts sign-jwt --quiet \
        --iam-account="$GOOGLE_SA" <(printf '%s' "$claim") /dev/stdout)" || return 1
    [ -n "$assertion" ] || return 1
    # The signed assertion is a bearer credential for its hour, so it goes to
    # curl on stdin, not argv.
    printf 'grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer&assertion=%s' "$assertion" \
        | curl -fsS -X POST https://oauth2.googleapis.com/token --data-binary @- \
        | jq -er '.access_token // empty'
}

# Prints a JSON array of lowercased ACTIVE member emails, or the literal
# __UNREADABLE__ on any failure. The sentinel is load-bearing: reconcile_team's
# first guard turns it into "change nothing", and returning an empty array here
# instead would revoke the whole team.
#
# ONE PAGE ONLY, and a response carrying nextPageToken is __UNREADABLE__. A
# truncated list makes real members look absent and gets them revoked, and a
# PARTIAL truncation -- a few members past the page -- stays under the
# blast-radius cap, so that guard would not catch it. Fail closed; paginate if
# a team ever outgrows a page.
#
# USER MEMBERS ONLY, for the same reason. A GROUP member is a nested group
# whose people never appear on this page (includeDerivedMembership is not
# requested: its live response shape is unproven), and a CUSTOMER member is
# everyone in the domain. Either way people holding the role look absent and
# get REVOKED, under the blast-radius cap. So any member whose type is not
# USER -- a missing type included -- makes the group __UNREADABLE__, logged
# with the member an operator has to change.
list_group_members() {
    local group="$1" body non_users
    body="$(curl -fsS "https://admin.googleapis.com/admin/directory/v1/groups/${group}/members" \
        -K <(printf 'header = "Authorization: Bearer %s"\n' "$GOOGLE_TOKEN"))" \
        || { printf '__UNREADABLE__'; return 0; }
    non_users="$(jq -r '[.members // [] | .[] | select(.type != "USER")
                         | "\(.email // .id // "?") (type \(.type // "missing"))"] | join(", ")' \
                 <<<"$body" 2>/dev/null)"
    if [ -n "$non_users" ]; then
        echo "[unreadable] ${group}: non-USER member(s) ${non_users} -- a nested group or customer entry hides people this reconciler cannot see; add those people to ${group} directly" >&2
        printf '__UNREADABLE__'
        return 0
    fi
    jq -ce 'if has("nextPageToken") then error("paginated")
            else [.members // [] | .[] | select(.status == "ACTIVE") | .email | ascii_downcase]
            end' <<<"$body" 2>/dev/null \
        || printf '__UNREADABLE__'
}

# "<team> <googleGroup>" per line, through access_matrix.load() -- the one
# module that reads the matrix -- which validates every row before printing any.
# A plain assignment, never `mapfile < <(...)`: a process substitution's exit
# status is lost, and a matrix failing validation must fail the run rather than
# yield a partial team list.
matrix_teams() {
    local out
    out="$(python3 -c '
import sys
sys.path.insert(0, sys.argv[2])
import access_matrix
for t in access_matrix.load(sys.argv[1]):
    print(t.team, t.google_group)
' "$ACCESS_MATRIX" "$_SCRIPTS_DIR")" || return 1
    printf '%s\n' "$out"
}

# sync_teams <pairs> -- one pass over "<team> <group>" lines, against the
# USERS_JSON and GRANTS_JSON main already loaded. Non-zero if ANY team tripped
# or ANY write failed, so the CronJob surfaces a partial failure rather than
# averaging it away. A tripped team contributes no intent, so it writes
# nothing, while the run carries on to the others.
sync_teams() {
    local pairs="$1" team group members holders actions rc verb email plan
    local intents="" failed=0
    while read -r team group <&3; do
        [ -z "$team" ] && continue
        members="$(list_group_members "$group")"
        if ! holders="$(team_holders "$team" "$GRANTS_JSON" "$USERS_JSON")"; then
            echo "[TRIPPED] ${team}: could not derive the current holders; making no change"
            failed=1; continue
        fi
        # Captured, never piped: a pipeline's status is its LAST command's, so
        # `reconcile_team | ...` would lose a tripped guard. No `set -e` here,
        # so $? after the assignment is reconcile_team's own.
        actions="$(reconcile_team "$team" "$members" "$holders")"; rc=$?
        if [ "$rc" -ne 0 ]; then
            echo "[TRIPPED] ${team}: ${actions}"
            failed=1; continue
        fi
        while read -r verb email; do
            case "$verb" in
                grant|revoke)
                    echo "[${team}] ${verb} ${email}"
                    intents+="${verb} ${team} ${email}"$'\n' ;;
                skip-no-user)
                    echo "[skip   ] ${team}: ${email} has no ZITADEL user yet (first login pending)" ;;
            esac
        done <<<"$actions"
    done 3<<<"$pairs"

    if ! plan="$(plan_user_changes "$intents" "$GRANTS_JSON" "$USERS_JSON")"; then
        echo "[FAILED ] could not plan the per-user changes; writing nothing" >&2
        return 1
    fi
    apply_user_changes <<<"$plan" || failed=1
    return "$failed"
}

usage() {
    cat <<'EOF'
Usage: access-matrix-sync.sh [--apply] [--team <name>] [--max-revocations <n>] [--grants-only]

Make ZITADEL's project-role grants match Google Workspace group membership, as
the access matrix maps teams to groups. DRY RUN unless --apply.

  --apply                write; without it, print what would change, write nothing
  --team <name>          reconcile one team only
  --max-revocations <n>  allow up to n revocations per team, replacing the default
                         limit of max(holders/2, 2). It never lets a team lose
                         EVERY holder, never empties `platform`, and never acts on
                         an unreadable group.
  --grants-only          add missing roles; compute no revocations at all

Environment:
  IDP_URL, GOOGLE_SA, GOOGLE_SUBJECT      required, no defaults
  ZITADEL_PROJECT_ID                      or ZITADEL_PROJECT_NAME (default: platform)
  ZITADEL_PAT                             or CLOUD (aws|gcp): read the admin PAT from
                                          that cloud's secret store
  ACCESS_MATRIX                           default: the repo's matrix.yaml

Exit status: 0 every team reconciled; 1 a team tripped a guard, a read failed
or a write failed; 2 a usage or configuration error.

A team with ONE holder cannot swap its holder in a single run: revoking 1 of 1
always trips. Add the new member first, let a run grant them, then remove the
old one. To retire a team, delete its matrix row: its role then becomes
unmanaged and stays in place. It is never mass-revoked.
EOF
}

main() {
    APPLY=false
    GRANTS_ONLY=false
    MAX_REVOCATIONS=""
    local only_team="" pairs v
    while [ $# -gt 0 ]; do
        case "$1" in
            --apply)       APPLY=true; shift ;;
            --grants-only) GRANTS_ONLY=true; shift ;;
            --team)
                [ -n "${2:-}" ] || { echo "--team needs a team name" >&2; return 2; }
                only_team="$2"; shift 2 ;;
            --max-revocations)
                [[ "${2:-}" =~ ^[0-9]+$ ]] \
                    || { echo "--max-revocations needs a non-negative integer" >&2; return 2; }
                MAX_REVOCATIONS="$2"; shift 2 ;;
            -h|--help) usage; return 0 ;;
            *) echo "unknown argument: $1" >&2; usage >&2; return 2 ;;
        esac
    done

    if ! pairs="$(matrix_teams)"; then
        echo "[FAILED ] cannot read the access matrix at ${ACCESS_MATRIX}" >&2
        return 2
    fi
    if [ -n "$only_team" ]; then
        pairs="$(awk -v t="$only_team" '$1 == t' <<<"$pairs")"
        [ -n "$pairs" ] || { echo "--team ${only_team}: no such team in the access matrix" >&2; return 2; }
    fi

    # Never defaulted to an empty string: an empty IDP_URL or service account
    # fails later, further from its cause.
    for v in IDP_URL GOOGLE_SA GOOGLE_SUBJECT; do
        [ -n "${!v:-}" ] || { echo "[FAILED ] ${v} is required and has no default" >&2; return 2; }
    done

    # Resolved once per run, not per call. An injected ZITADEL_PAT is used as-is.
    if [ -z "${ZITADEL_PAT:-}" ]; then
        if [ -z "${CLOUD:-}" ]; then
            echo "[FAILED ] set ZITADEL_PAT, or CLOUD (aws|gcp) to read the admin PAT from that cloud's secret store" >&2
            return 2
        fi
        # zitadel-pat.sh's OWN dry-run signal. On a dry run it must not persist
        # a freshly read PAT into the secret store: that would be a write.
        ZITADEL_PAT_DRY_RUN=true
        [ "$APPLY" = true ] && ZITADEL_PAT_DRY_RUN=false
        ZITADEL_PAT="$(resolve_zitadel_pat)" || return 1
    fi

    resolve_project_id || return 1

    if ! GOOGLE_TOKEN="$(google_token)"; then
        echo "[FAILED ] could not get a Google token, so every group is unreadable; changing nothing" >&2
        return 1
    fi
    USERS_JSON="$(load_users)" || return 1
    GRANTS_JSON="$(load_grants)" || return 1

    [ "$APPLY" = true ] || echo "DRY RUN: nothing will be written. Pass --apply to write."
    sync_teams "$pairs"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
    exit $?
fi
