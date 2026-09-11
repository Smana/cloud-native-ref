#!/usr/bin/env bash
# Fixture tests for access-matrix-sync.sh -- no network, ever.
#
# First the four safety guards in reconcile_team: they decide whether a Google
# outage is a non-event or a platform-wide lockout, so they are tested first and
# directly. Then the per-user planner, the write path, both network halves
# against a stubbed curl / zitadel_api, and main end to end on fixtures.
#
# access-matrix-sync.sh is sourceable: it guards its CLI behind
# `[ "${BASH_SOURCE[0]}" = "$0" ]` precisely so this file can call one function.
#
# curl, gcloud, kubectl and aws are replaced by TRIPWIRES that log any call; the
# last check asserts that log is empty. A test that reaches for the network
# fails here rather than quietly depending on one.
set -uo pipefail
fail=0
check() { if [ "$2" = "$3" ]; then printf '  ok   %s\n' "$1"
          else printf '  FAIL %s: expected %q got %q\n' "$1" "$2" "$3"; fail=1; fi }
nonzero() { [ "$1" -ne 0 ] && echo 1 || echo 0; }

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

# shellcheck source=scripts/access-matrix-sync.sh
source "$(dirname "$0")/access-matrix-sync.sh"

NET_LOG="$T/network-calls"
: >"$NET_LOG"
tripwire() {
    curl()        { echo "curl $*"        >>"$NET_LOG"; return 1; }
    gcloud()      { echo "gcloud $*"      >>"$NET_LOG"; return 1; }
    kubectl()     { echo "kubectl $*"     >>"$NET_LOG"; return 1; }
    aws()         { echo "aws $*"         >>"$NET_LOG"; return 1; }
}
tripwire

# The preloaded ZITADEL users map, in load_users' shape: a..f are users 1..6.
# ghost@ is deliberately absent -- it has no ZITADEL user (first login pending).
# This, not a stubbed lookup, is what the skip-no-user test below resolves
# against: zitadel_user_id is the real function.
USERS_JSON="$(jq -c '[to_entries[] | {userId: "\(.key + 1)",
    email: "\(.value)@ogenki.io", userName: "\(.value)@ogenki.io"}]' \
    <<<'["a","b","c","d","e","f"]')"

# Set only by main's flags. Unset here, so Task 7's tests below see exactly
# Task 7's behaviour (override case 11).
unset GRANTS_ONLY MAX_REVOCATIONS
APPLY=false

MEMBERS='["a@ogenki.io","b@ogenki.io"]'
GRANTS='[{"email":"a@ogenki.io","userId":"1"},{"email":"c@ogenki.io","userId":"3"}]'

echo "== grants what is missing, revokes what left =="
out="$(reconcile_team data "$MEMBERS" "$GRANTS" 2>&1)"; rc=$?
check "exit 0"            0 "$rc"
check "grants b"          1 "$(grep -c '^grant b@ogenki.io$'  <<<"$out")"
check "revokes c"         1 "$(grep -c '^revoke c@ogenki.io$' <<<"$out")"
check "leaves a alone"    0 "$(grep -c 'a@ogenki.io' <<<"$out")"

echo "== a member with no ZITADEL user is skipped, not fatal =="
out="$(reconcile_team data '["a@ogenki.io","ghost@ogenki.io"]' \
        '[{"email":"a@ogenki.io","userId":"1"}]' 2>&1)"; rc=$?
check "exit 0"            0 "$rc"
check "skip-no-user"      1 "$(grep -c '^skip-no-user ghost@ogenki.io$' <<<"$out")"

echo "== an UNREADABLE group never revokes =="
out="$(reconcile_team data "__UNREADABLE__" "$GRANTS" 2>&1)"; rc=$?
check "exit non-zero"     1 "$([ "$rc" -ne 0 ] && echo 1 || echo 0)"
check "zero revocations"  0 "$(grep -c '^revoke' <<<"$out")"
check "says why"          1 "$(grep -c 'GUARD unreadable' <<<"$out")"

echo "== blast radius: every holder revoked (4 of 4) stops, via the n_current clause =="
out="$(reconcile_team data '[]' \
  '[{"email":"a@ogenki.io","userId":"1"},{"email":"b@ogenki.io","userId":"2"},
    {"email":"c@ogenki.io","userId":"3"},{"email":"d@ogenki.io","userId":"4"}]' 2>&1)"; rc=$?
check "exit non-zero"     1 "$([ "$rc" -ne 0 ] && echo 1 || echo 0)"
check "zero revocations"  0 "$(grep -c '^revoke' <<<"$out")"
check "says why"          1 "$(grep -c 'GUARD blast-radius' <<<"$out")"

echo "== two members, both leaving, still trips (via the n_current clause, not the floor) =="
out="$(reconcile_team data '[]' \
  '[{"email":"a@ogenki.io","userId":"1"},{"email":"b@ogenki.io","userId":"2"}]' 2>&1)"
check "zero revocations"  0 "$(grep -c '^revoke' <<<"$out")"

echo "== blast radius fraction: 6 holders, revoke 4 (over max(6/2,2)=3) trips =="
out="$(reconcile_team data '["a@ogenki.io","b@ogenki.io"]' \
  '[{"email":"a@ogenki.io","userId":"1"},{"email":"b@ogenki.io","userId":"2"},
    {"email":"c@ogenki.io","userId":"3"},{"email":"d@ogenki.io","userId":"4"},
    {"email":"e@ogenki.io","userId":"5"},{"email":"f@ogenki.io","userId":"6"}]' 2>&1)"; rc=$?
check "exit non-zero"     1 "$([ "$rc" -ne 0 ] && echo 1 || echo 0)"
check "zero revocations"  0 "$(grep -c '^revoke' <<<"$out")"
check "says why"          1 "$(grep -c 'GUARD blast-radius' <<<"$out")"

echo "== blast radius fraction boundary: 6 holders, revoke 3 (== max(6/2,2)=3) passes =="
out="$(reconcile_team data '["a@ogenki.io","b@ogenki.io","c@ogenki.io"]' \
  '[{"email":"a@ogenki.io","userId":"1"},{"email":"b@ogenki.io","userId":"2"},
    {"email":"c@ogenki.io","userId":"3"},{"email":"d@ogenki.io","userId":"4"},
    {"email":"e@ogenki.io","userId":"5"},{"email":"f@ogenki.io","userId":"6"}]' 2>&1)"; rc=$?
check "exit 0"             0 "$rc"
check "revokes exactly 3"  3 "$(grep -c '^revoke' <<<"$out")"

echo "== blast radius floor: 3 holders, revoke 2 (== max(3/2,2)=2) passes -- the floor is why =="
out="$(reconcile_team data '["a@ogenki.io"]' \
  '[{"email":"a@ogenki.io","userId":"1"},{"email":"b@ogenki.io","userId":"2"},
    {"email":"c@ogenki.io","userId":"3"}]' 2>&1)"; rc=$?
check "exit 0"             0 "$rc"
check "revokes exactly 2"  2 "$(grep -c '^revoke' <<<"$out")"

echo "== platform is never left empty =="
out="$(reconcile_team platform '[]' '[{"email":"a@ogenki.io","userId":"1"}]' 2>&1)"; rc=$?
check "exit non-zero"     1 "$([ "$rc" -ne 0 ] && echo 1 || echo 0)"
check "zero revocations"  0 "$(grep -c '^revoke' <<<"$out")"
check "says why"          1 "$(grep -c 'GUARD zero-members' <<<"$out")"

echo "== idempotent: nothing to do =="
out="$(reconcile_team data '["a@ogenki.io"]' '[{"email":"a@ogenki.io","userId":"1"}]' 2>&1)"
check "no actions"        0 "$(grep -cE '^(grant|revoke)' <<<"$out")"

# ── Task 8 ────────────────────────────────────────────────────────────────────

FIVE='[{"email":"a@ogenki.io","userId":"1"},{"email":"b@ogenki.io","userId":"2"},
  {"email":"c@ogenki.io","userId":"3"},{"email":"d@ogenki.io","userId":"4"},
  {"email":"e@ogenki.io","userId":"5"}]'
SIX='[{"email":"a@ogenki.io","userId":"1"},{"email":"b@ogenki.io","userId":"2"},
  {"email":"c@ogenki.io","userId":"3"},{"email":"d@ogenki.io","userId":"4"},
  {"email":"e@ogenki.io","userId":"5"},{"email":"f@ogenki.io","userId":"6"}]'

echo "== reconcile_team stays network-free: every lookup above hit the preloaded map =="
check "network calls so far"   0 "$(grep -c . "$NET_LOG")"

echo "== zitadel_user_id is a lookup in USERS_JSON, case-insensitive =="
check "known email"            1 "$(zitadel_user_id a@ogenki.io)"
check "same email, other case" 1 "$(zitadel_user_id A@Ogenki.IO)"
zitadel_user_id ghost@ogenki.io >/dev/null 2>&1; rc=$?
check "unknown email fails"    1 "$(nonzero "$rc")"
out="$(USERS_JSON='[{"userId":"7","email":"x@ogenki.io","userName":"x@ogenki.io"},
                    {"userId":"8","email":"y@ogenki.io","userName":"x@ogenki.io"}]' \
       zitadel_user_id x@ogenki.io 2>/dev/null)"; rc=$?
check "an email naming two users resolves to nobody" 1 "$(nonzero "$rc")"
check "... and prints no id"   "" "$out"

echo "== case 13: malformed member JSON is UNREADABLE, never an empty group =="
for bad in 'not-json' '{"error":"quota"}'; do
    out="$(reconcile_team data "$bad" "$GRANTS" 2>&1)"; rc=$?
    check "${bad}: exit non-zero"    1 "$(nonzero "$rc")"
    check "${bad}: GUARD unreadable" 1 "$(grep -c 'GUARD unreadable' <<<"$out")"
    check "${bad}: zero revocations" 0 "$(grep -c '^revoke' <<<"$out")"
done

echo "== case 14: Workspace A@x against ZITADEL holder a@x -- no revoke, no churn =="
out="$(reconcile_team data '["A@Ogenki.io"]' '[{"email":"a@ogenki.io","userId":"1"}]' 2>&1)"; rc=$?
check "exit 0"                 0 "$rc"
check "no revoke"              0 "$(grep -c '^revoke' <<<"$out")"
check "no grant"               0 "$(grep -c '^grant' <<<"$out")"

echo "== case 9: --max-revocations 0, 5 holders, 1 pending revoke TRIPS (no floor on an explicit cap) =="
out="$(MAX_REVOCATIONS=0 reconcile_team data \
  '["a@ogenki.io","b@ogenki.io","c@ogenki.io","d@ogenki.io"]' "$FIVE" 2>&1)"; rc=$?
check "exit non-zero"          1 "$(nonzero "$rc")"
check "zero revocations"       0 "$(grep -c '^revoke' <<<"$out")"
check "says why"               1 "$(grep -c 'GUARD blast-radius' <<<"$out")"

echo "== an explicit cap IS the limit: cap 4 lets 4 of 6 through, where the default (3) trips =="
out="$(MAX_REVOCATIONS=4 reconcile_team data '["a@ogenki.io","b@ogenki.io"]' "$SIX" 2>&1)"; rc=$?
check "exit 0"                 0 "$rc"
check "revokes exactly 4"      4 "$(grep -c '^revoke' <<<"$out")"

echo "== case 12: a cap LARGER than the default still never lets a whole team go =="
out="$(MAX_REVOCATIONS=100 reconcile_team data '[]' "$FIVE" 2>&1)"; rc=$?
check "exit non-zero"          1 "$(nonzero "$rc")"
check "zero revocations"       0 "$(grep -c '^revoke' <<<"$out")"
check "says why"               1 "$(grep -c 'GUARD blast-radius' <<<"$out")"

echo "== case 12: ... never empties platform, whatever the cap =="
out="$(MAX_REVOCATIONS=100 reconcile_team platform '[]' '[{"email":"a@ogenki.io","userId":"1"}]' 2>&1)"; rc=$?
check "exit non-zero"          1 "$(nonzero "$rc")"
check "zero revocations"       0 "$(grep -c '^revoke' <<<"$out")"
check "says why"               1 "$(grep -c 'GUARD zero-members' <<<"$out")"

echo "== ... and never acts on an unreadable group, whatever the cap =="
out="$(MAX_REVOCATIONS=100 reconcile_team data __UNREADABLE__ "$GRANTS" 2>&1)"; rc=$?
check "exit non-zero"          1 "$(nonzero "$rc")"
check "says why"               1 "$(grep -c 'GUARD unreadable' <<<"$out")"

echo "== case 10: GRANTS_ONLY grants what is missing, revokes nothing, does not trip =="
out="$(GRANTS_ONLY=true reconcile_team data "$MEMBERS" "$GRANTS" 2>&1)"; rc=$?
check "exit 0"                 0 "$rc"
check "grants b"               1 "$(grep -c '^grant b@ogenki.io$' <<<"$out")"
check "no revoke c"            0 "$(grep -c '^revoke' <<<"$out")"

echo "== GRANTS_ONLY keeps a team's grants where cap 0 would drop them along with the trip =="
out="$(GRANTS_ONLY=true reconcile_team data '["f@ogenki.io"]' "$FIVE" 2>&1)"; rc=$?
check "exit 0"                 0 "$rc"
check "grants f"               1 "$(grep -c '^grant f@ogenki.io$' <<<"$out")"
check "no revoke"              0 "$(grep -c '^revoke' <<<"$out")"

echo "== GRANTS_ONLY still refuses an unreadable group =="
out="$(GRANTS_ONLY=true reconcile_team data __UNREADABLE__ "$GRANTS" 2>&1)"; rc=$?
check "exit non-zero"          1 "$(nonzero "$rc")"
check "says why"               1 "$(grep -c 'GUARD unreadable' <<<"$out")"

echo "== team_holders: role holders mapped through the users list; an unmapped holder is EXCLUDED =="
HOLDING='[{"userId":"1","grantId":"g1","roleKeys":["data"]},
  {"userId":"2","grantId":"g2","roleKeys":["backend","data"]},
  {"userId":"3","grantId":"g3","roleKeys":["admin"]},
  {"userId":"99","grantId":"g99","roleKeys":["data"]}]'
out="$(team_holders data "$HOLDING" "$USERS_JSON" 2>"$T/err")"; rc=$?
check "exit 0"                 0 "$rc"
check "data's holders, by email" \
  '[{"email":"a@ogenki.io","userId":"1"},{"email":"b@ogenki.io","userId":"2"}]' "$out"
check "the unmapped holder is logged" 1 "$(grep -c '99' "$T/err")"

echo "== plan_user_changes (pure): one line per affected user =="
plan() { plan_user_changes "$1" "$2" "$USERS_JSON" 2>"$T/err"; }
check "case 2: new user, one grant -> post with that role" \
  'post 1 - ["data"]' "$(plan 'grant data a@ogenki.io' '[]')"
check "case 3: two teams, no grant -> ONE post carrying both, sorted" \
  'post 1 - ["backend","data"]' \
  "$(plan $'grant data a@ogenki.io\ngrant backend a@ogenki.io' '[]')"
check "case 4: [admin] + platform -> put, the legacy role PRESERVED" \
  'put 1 g1 ["admin","platform"]' \
  "$(plan 'grant platform a@ogenki.io' '[{"userId":"1","grantId":"g1","roleKeys":["admin"]}]')"
check "case 5: [backend,data] - data -> put [backend], NOT delete" \
  'put 2 g2 ["backend"]' \
  "$(plan 'revoke data b@ogenki.io' '[{"userId":"2","grantId":"g2","roleKeys":["backend","data"]}]')"
check "case 6: [data] - data -> delete" \
  'delete 3 g3 []' \
  "$(plan 'revoke data c@ogenki.io' '[{"userId":"3","grantId":"g3","roleKeys":["data"]}]')"
# The planner never SEES a tripped team -- sync_teams drops it (the case 7
# check under main, below, is the one a leak would fail). What the planner
# owes case 7 is carrying the tripped team's role through another team's change.
check "case 7 (planner): a tripped team's role, with no intent, survives another team's change" \
  'put 4 g4 ["backend","data","platform"]' \
  "$(plan 'grant platform d@ogenki.io' '[{"userId":"4","grantId":"g4","roleKeys":["backend","data"]}]')"
check "case 8: already holds exactly the desired roles -> none" \
  'none 5 g5 ["data"]' \
  "$(plan 'grant data e@ogenki.io' '[{"userId":"5","grantId":"g5","roleKeys":["data"]}]')"
check "a grant and a revoke of one team for one user -> the grant wins" \
  'none 1 g1 ["data"]' \
  "$(plan $'grant data a@ogenki.io\nrevoke data a@ogenki.io' '[{"userId":"1","grantId":"g1","roleKeys":["data"]}]')"
check "an intent for an email with no user -> no line" \
  '' "$(plan 'grant data ghost@ogenki.io' '[]')"
out="$(plan $'grant data a@ogenki.io\nrevoke backend a@ogenki.io' \
        '[{"userId":"1","grantId":"g1","roleKeys":["admin"]},{"userId":"1","grantId":"g2","roleKeys":["backend"]}]')"
check "a user holding TWO grants on the project gets no write" \
  0 "$(grep -cE '^(post|put|delete) ' <<<"$out")"
check "fix 2: ... and EACH of its intents is dropped, naming user and reason" \
  2 "$(grep -c '^drop .* a@ogenki.io: user 1 holds 2 grants on the project' <<<"$out")"
out="$(plan_user_changes 'revoke data a@ogenki.io' '[{"userId":"1","grantId":"g1","roleKeys":["data"]}]' \
  '[{"userId":"1","email":"a@ogenki.io","userName":"a@ogenki.io"},{"userId":"7","email":"x@ogenki.io","userName":"a@ogenki.io"}]' \
  2>/dev/null)"
check "fix 2: an email naming two users -- its intent is dropped, naming the reason" \
  1 "$(grep -c '^drop revoke data a@ogenki.io: the email names 2 ZITADEL users' <<<"$out")"

echo "== case 1: dry run performs no writes; --apply performs them =="
WRITES="$T/writes"
zitadel_post_grant()   { echo "post $*"   >>"$WRITES"; }
zitadel_put_grant()    { echo "put $*"    >>"$WRITES"; }
zitadel_delete_grant() { echo "delete $*" >>"$WRITES"; }
PLAN='post 1 - ["data"]
put 2 g2 ["backend"]
delete 3 g3 []
none 5 g5 ["data"]'
: >"$WRITES"; APPLY=false
out="$(apply_user_changes <<<"$PLAN" 2>&1)"; rc=$?
check "dry run: exit 0"                0 "$rc"
check "dry run: zero writes"           0 "$(grep -c . "$WRITES")"
check "dry run: reports three changes" 3 "$(grep -c '^\[dry-run\]' <<<"$out")"
: >"$WRITES"; APPLY=true
out="$(apply_user_changes <<<"$PLAN" 2>&1)"; rc=$?
check "apply: exit 0"                  0 "$rc"
check "apply: three writes (none is not one)" 3 "$(grep -c . "$WRITES")"
check "apply: post"   1 "$(grep -cFx 'post 1 ["data"]'     "$WRITES")"
check "apply: put"    1 "$(grep -cFx 'put 2 g2 ["backend"]' "$WRITES")"
check "apply: delete" 1 "$(grep -cFx 'delete 3 g3'         "$WRITES")"

echo "== a failed write fails the run, and the other writes still happen =="
zitadel_put_grant() { echo "put $*" >>"$WRITES"; return 1; }
: >"$WRITES"
out="$(apply_user_changes <<<"$PLAN" 2>&1)"; rc=$?
check "exit non-zero"                  1 "$(nonzero "$rc")"
check "all three attempted"            3 "$(grep -c . "$WRITES")"
check "names the failure"              1 "$(grep -c '^\[FAILED' <<<"$out")"
zitadel_put_grant() { echo "put $*" >>"$WRITES"; }

echo "== fix 2: a DROPPED intent fails the run -- after every other write is applied =="
DPLAN="$PLAN"$'\n''drop revoke data d@ogenki.io: user 4 holds 2 grants on the project'
: >"$WRITES"
out="$(apply_user_changes <<<"$DPLAN" 2>&1)"; rc=$?
check "apply: exit non-zero"             1 "$(nonzero "$rc")"
check "apply: the other three writes still happen" 3 "$(grep -c . "$WRITES")"
check "apply: one [DROPPED] line naming user and reason" \
  1 "$(grep -c '^\[DROPPED\] revoke data d@ogenki.io: user 4 holds 2 grants' <<<"$out")"
APPLY=false
: >"$WRITES"
out="$(apply_user_changes <<<"$DPLAN" 2>&1)"; rc=$?
check "dry run: a drop still fails the run" 1 "$(nonzero "$rc")"
check "dry run: still zero writes"       0 "$(grep -c . "$WRITES")"

echo "== zitadel_api: the PAT reaches curl through -K, never argv =="
ZITADEL_PAT="fake-token"
IDP_URL="https://idp.invalid"
curl() { printf '%s\n' "$@" >"$T/curl-argv"; }
zitadel_api GET /management/v1/x
check "the request URL"        1 "$(grep -cFx 'https://idp.invalid/management/v1/x' "$T/curl-argv")"
check "the PAT is not on argv" 0 "$(grep -c 'fake-token' "$T/curl-argv")"

echo "== list_group_members: the Directory API, against a stubbed curl =="
GOOGLE_TOKEN="fake-token"
DIR_BODY=""
curl() { printf '%s\n' "$@" >"$T/curl-argv"; printf '%s' "$DIR_BODY"; }
DIR_BODY='{"members":[{"email":"A@Ogenki.io","type":"USER","status":"ACTIVE"},{"email":"z@ogenki.io","type":"USER","status":"SUSPENDED"}]}'
check "active members, lowercased" '["a@ogenki.io"]' "$(list_group_members data-eng@ogenki.io)"
check "the request names the group" 1 "$(grep -c 'groups/data-eng@ogenki.io/members' "$T/curl-argv")"
check "the token is not on argv"    0 "$(grep -c 'fake-token' "$T/curl-argv")"
DIR_BODY='{"kind":"admin#directory#members"}'
check "a genuinely empty group"     '[]' "$(list_group_members data-eng@ogenki.io)"
DIR_BODY='{"members":[{"email":"a@ogenki.io","type":"USER","status":"ACTIVE"}],"nextPageToken":"p2"}'
check "nextPageToken -> __UNREADABLE__" '__UNREADABLE__' "$(list_group_members data-eng@ogenki.io)"
DIR_BODY='not-json'
check "a body that is not JSON -> __UNREADABLE__" '__UNREADABLE__' \
  "$(list_group_members data-eng@ogenki.io 2>/dev/null)"

echo "== fix 1: a nested GROUP member is UNREADABLE -- its people never appear on the page =="
DIR_BODY='{"members":[{"email":"a@ogenki.io","type":"USER","status":"ACTIVE"},
  {"email":"sub-team@ogenki.io","type":"GROUP","status":"ACTIVE"}]}'
members="$(list_group_members data-eng@ogenki.io 2>"$T/err")"
out="$(reconcile_team data "$members" '[{"email":"c@ogenki.io","userId":"3"}]' 2>&1)"; rc=$?
check "nested group: exit non-zero"      1 "$(nonzero "$rc")"
check "nested group: GUARD unreadable"   1 "$(grep -c 'GUARD unreadable' <<<"$out")"
check "nested group: zero revocations"   0 "$(grep -c '^revoke' <<<"$out")"
check "nested group: zero grants"        0 "$(grep -c '^grant' <<<"$out")"
check "nested group: logs why, naming it" 1 "$(grep -c 'sub-team@ogenki.io (type GROUP)' "$T/err")"

echo "== fix 1: the fail-open shape -- 1 of 3 holders is inside the nested group, under the cap =="
DIR_BODY='{"members":[{"email":"a@ogenki.io","type":"USER","status":"ACTIVE"},
  {"email":"b@ogenki.io","type":"USER","status":"ACTIVE"},
  {"email":"sub-team@ogenki.io","type":"GROUP","status":"ACTIVE"}]}'
members="$(list_group_members data-eng@ogenki.io 2>/dev/null)"
out="$(reconcile_team data "$members" '[{"email":"a@ogenki.io","userId":"1"},
  {"email":"b@ogenki.io","userId":"2"},{"email":"c@ogenki.io","userId":"3"}]' 2>&1)"
check "c, inside the nested group, is not revoked" 0 "$(grep -c '^revoke c@ogenki.io$' <<<"$out")"

echo "== fix 1: a CUSTOMER member, and a member with no type, are UNREADABLE too =="
DIR_BODY='{"members":[{"email":"a@ogenki.io","type":"USER","status":"ACTIVE"},
  {"id":"C01","type":"CUSTOMER","status":"ACTIVE"}]}'
check "CUSTOMER -> __UNREADABLE__"       '__UNREADABLE__' "$(list_group_members data-eng@ogenki.io 2>"$T/err")"
check "CUSTOMER: logs why"               1 "$(grep -c 'C01 (type CUSTOMER)' "$T/err")"
DIR_BODY='{"members":[{"email":"a@ogenki.io","status":"ACTIVE"}]}'
check "no type -> __UNREADABLE__"        '__UNREADABLE__' "$(list_group_members data-eng@ogenki.io 2>"$T/err")"
check "no type: logs why"                1 "$(grep -c 'a@ogenki.io (type missing)' "$T/err")"

echo "== addendum: member status -- ACTIVE is a member, SUSPENDED is not, anything else is UNREADABLE =="
DIR_BODY='{"members":[{"email":"a@ogenki.io","type":"USER","status":"ACTIVE"},{"email":"b@ogenki.io","type":"USER"}]}'
check "no status -> __UNREADABLE__"      '__UNREADABLE__' "$(list_group_members data-eng@ogenki.io 2>"$T/err")"
check "no status: logs why"              1 "$(grep -c 'b@ogenki.io (status missing)' "$T/err")"
DIR_BODY='{"members":[{"email":"a@ogenki.io","type":"USER","status":"ACTIVE"},{"email":"b@ogenki.io","type":"USER","status":"PENDING"}]}'
check "PENDING -> __UNREADABLE__"        '__UNREADABLE__' "$(list_group_members data-eng@ogenki.io 2>"$T/err")"
check "PENDING: logs why"                1 "$(grep -c 'b@ogenki.io (status PENDING)' "$T/err")"
DIR_BODY='{"members":[{"email":"a@ogenki.io","type":"USER","status":"ACTIVE"},
  {"email":"b@ogenki.io","type":"USER","status":"ACTIVE"},
  {"email":"c@ogenki.io","type":"USER","status":"SUSPENDED"}]}'
members="$(list_group_members data-eng@ogenki.io 2>/dev/null)"
check "SUSPENDED is not a member"        '["a@ogenki.io","b@ogenki.io"]' "$members"
out="$(reconcile_team data "$members" '[{"email":"a@ogenki.io","userId":"1"},
  {"email":"b@ogenki.io","userId":"2"},{"email":"c@ogenki.io","userId":"3"}]' 2>&1)"; rc=$?
check "a SUSPENDED holder is revoked, within the guards (1 of 3)" \
  "0:1" "${rc}:$(grep -c '^revoke c@ogenki.io$' <<<"$out")"

curl() { return 22; }
check "curl fails -> __UNREADABLE__" '__UNREADABLE__' \
  "$(list_group_members data-eng@ogenki.io 2>/dev/null)"

echo "== google_token: the signed assertion goes over stdin, never argv =="
GOOGLE_SA="sync@example.iam.gserviceaccount.com"
GOOGLE_SUBJECT="admin@ogenki.io"
gcloud() { printf 'fake.jwt.sig'; }
curl() { printf '%s\n' "$@" >"$T/curl-argv"; cat >"$T/curl-stdin"; printf '{"access_token":"fake-token"}'; }
out="$(google_token)"; rc=$?
check "exit 0"                     0 "$rc"
check "prints the access token"    fake-token "$out"
check "the assertion is not on argv" 0 "$(grep -c 'fake.jwt.sig' "$T/curl-argv")"
check "the assertion is in the body" 1 "$(grep -c 'assertion=fake.jwt.sig' "$T/curl-stdin")"
curl() { cat >/dev/null; printf '{"error":"invalid_grant"}'; }
out="$(google_token 2>/dev/null)"; rc=$?
check "no access_token -> non-zero" 1 "$(nonzero "$rc")"
check "... and prints nothing"     "" "$out"
tripwire

echo "== load_users: ONE search, humans only, emails lowercased; truncation fails closed =="
ZBODY=""
zitadel_api() { printf '%s' "$ZBODY"; }
ZBODY='{"details":{"totalResult":"3"},"result":[
  {"id":"1","userName":"A@Ogenki.io","human":{"email":{"email":"A@Ogenki.io"}}},
  {"id":"2","userName":"bob","human":{"email":{"email":"b@ogenki.io"}}},
  {"id":"m1","userName":"iam-admin","machine":{"name":"iam-admin"}}]}'
out="$(load_users)"; rc=$?
check "exit 0"                 0 "$rc"
check "the users map" \
  '[{"userId":"1","email":"a@ogenki.io","userName":"a@ogenki.io"},{"userId":"2","email":"b@ogenki.io","userName":"bob"}]' \
  "$out"
ZBODY="$(jq -nc '{result: [range(1000) | {id: tostring, userName: "u\(.)@ogenki.io",
                                            human: {email: {email: "u\(.)@ogenki.io"}}}]}')"
out="$(load_users 2>/dev/null)"; rc=$?
check "exactly the limit (1000): possibly truncated -> non-zero" 1 "$(nonzero "$rc")"
check "... and no map"         "" "$out"
ZBODY='{"details":{"totalResult":"5"},"result":[{"id":"1","userName":"a@ogenki.io","human":{"email":{"email":"a@ogenki.io"}}}]}'
out="$(load_users 2>/dev/null)"; rc=$?
check "fewer than totalResult (a server-side cap) -> non-zero" 1 "$(nonzero "$rc")"
zitadel_api() { return 22; }
out="$(load_users 2>/dev/null)"; rc=$?
check "an API failure -> non-zero" 1 "$(nonzero "$rc")"

echo "== load_grants: ONE search, this project only, no email trusted; truncation fails closed =="
zitadel_api() { printf '%s' "$ZBODY"; }
ZITADEL_PROJECT_ID="p1"
ZBODY='{"result":[{"id":"g1","userId":"1","projectId":"p1","roleKeys":["admin"],"email":"not-trusted@ogenki.io"},
  {"id":"gx","userId":"2","projectId":"other","roleKeys":["data"]}]}'
out="$(load_grants)"; rc=$?
check "exit 0"                 0 "$rc"
check "this project's grants" '[{"userId":"1","grantId":"g1","roleKeys":["admin"]}]' "$out"
ZBODY="$(jq -nc '{result: [range(1000) | {id: "g\(.)", userId: tostring, projectId: "p1", roleKeys: ["data"]}]}')"
out="$(load_grants 2>/dev/null)"; rc=$?
check "exactly the limit: possibly truncated -> non-zero" 1 "$(nonzero "$rc")"
out="$(ZITADEL_PROJECT_ID="" load_grants 2>/dev/null)"; rc=$?
check "an empty project id would span every project -> non-zero" 1 "$(nonzero "$rc")"

echo "== resolve_project_id: by name, exactly one match or fail =="
ZBODY='{"result":[{"id":"p9","name":"platform"},{"id":"p8","name":"other"}]}'
out="$(unset ZITADEL_PROJECT_ID; resolve_project_id && printf '%s' "$ZITADEL_PROJECT_ID")"
check "resolved by name"       p9 "$out"
ZBODY='{"result":[{"id":"p8","name":"other"}]}'
( unset ZITADEL_PROJECT_ID; resolve_project_id 2>/dev/null ); rc=$?
check "no match -> non-zero"   1 "$(nonzero "$rc")"
ZBODY='{"result":[{"id":"p9","name":"platform"},{"id":"p7","name":"platform"}]}'
( unset ZITADEL_PROJECT_ID; resolve_project_id 2>/dev/null ); rc=$?
check "two matches -> non-zero" 1 "$(nonzero "$rc")"
zitadel_api() { echo "zitadel_api $*" >>"$NET_LOG"; return 1; }

echo "== main: end to end on fixtures, every network half stubbed =="
IDP_URL="https://idp.invalid"
ZITADEL_PAT="fake-token"
ZITADEL_PROJECT_ID="p1"
matrix_teams() { printf '%s\n' "platform platform@ogenki.io" \
                               "backend backend@ogenki.io" "data data-eng@ogenki.io"; }
google_token() { printf 'fake-token'; }
load_users()   { printf '%s' "$USERS_JSON"; }
# a (1) holds the legacy ["admin"]. backend's group is unreadable, so b (2)
# must not move. userId 99 holds `data` but is not in the users list.
load_grants()  { printf '%s' '[{"userId":"1","grantId":"g1","roleKeys":["admin"]},
  {"userId":"2","grantId":"g2","roleKeys":["backend"]},
  {"userId":"3","grantId":"g3","roleKeys":["data"]},
  {"userId":"4","grantId":"g4","roleKeys":["backend","data"]},
  {"userId":"99","grantId":"g99","roleKeys":["data"]}]'; }
list_group_members() {
    case "$1" in
        platform@ogenki.io) echo '["a@ogenki.io","e@ogenki.io"]' ;;
        backend@ogenki.io)  echo '__UNREADABLE__' ;;
        data-eng@ogenki.io) echo '["a@ogenki.io","C@Ogenki.io"]' ;;
    esac
}
run_main() { : >"$WRITES"; out="$(main "$@" 2>&1)"; rc=$?; }

run_main --apply
check "a tripped team fails the run"                  1 "$(nonzero "$rc")"
check "... and says which"                            1 "$(grep -c 'TRIPPED.*backend' <<<"$out")"
check "three writes"                                  3 "$(grep -c . "$WRITES")"
check "cases 3+4: ONE put, both teams, admin kept"    1 "$(grep -cFx 'put 1 g1 ["admin","data","platform"]' "$WRITES")"
check "case 5 via data: put [backend], not delete"    1 "$(grep -cFx 'put 4 g4 ["backend"]' "$WRITES")"
check "case 2 via platform: post"                     1 "$(grep -cFx 'post 5 ["platform"]' "$WRITES")"
check "case 7: the tripped team's holder is untouched" 0 "$(grep -cE '^[a-z]+ 2 ' "$WRITES")"
check "an unmapped holder is never revoked"           0 "$(grep -c '99' "$WRITES")"
check "... and is logged"                             1 "$(grep -c 'exclude.*99' <<<"$out")"
check "case 14: Workspace C@ keeps c@'s role"         0 "$(grep -cE '^[a-z]+ 3 ' "$WRITES")"

run_main
check "dry run: the same trip, the same exit"         1 "$(nonzero "$rc")"
check "dry run: zero writes"                          0 "$(grep -c . "$WRITES")"
check "dry run: reports the three changes"            3 "$(grep -c '^\[dry-run\]' <<<"$out")"

APPLY=true
run_main
check "APPLY=true already set does not write without --apply" 0 "$(grep -c . "$WRITES")"
APPLY=false

run_main --apply --grants-only
check "--grants-only: two writes"                     2 "$(grep -c . "$WRITES")"
check "--grants-only: nothing revoked"                0 "$(grep -c '^put 4' "$WRITES")"

run_main --apply --team data
check "--team data: exit 0"                           0 "$rc"
check "--team data: two writes"                       2 "$(grep -c . "$WRITES")"
check "--team data: only data's role moves"           1 "$(grep -cFx 'put 1 g1 ["admin","data"]' "$WRITES")"

run_main --apply --team data --max-revocations 0
check "--max-revocations 0: data trips"               1 "$(nonzero "$rc")"
check "--max-revocations 0: zero writes"              0 "$(grep -c . "$WRITES")"

run_main --team nosuch
check "unknown team: usage error"                     2 "$rc"
run_main --max-revocations x
check "non-numeric cap: usage error"                  2 "$rc"
run_main --bogus
check "unknown flag: usage error"                     2 "$rc"
run_main --help
check "--help: exit 0"                                0 "$rc"
check "--help: warns a one-holder team cannot swap its holder" 1 "$(grep -ci 'one holder' <<<"$out")"

for v in IDP_URL GOOGLE_SA GOOGLE_SUBJECT; do
    : >"$WRITES"
    out="$(unset "$v"; main --apply 2>&1)"; rc=$?
    check "missing ${v}: fails"                       1 "$(nonzero "$rc")"
    check "missing ${v}: named"                       1 "$(grep -c "$v" <<<"$out")"
    check "missing ${v}: zero writes"                 0 "$(grep -c . "$WRITES")"
done

out="$(unset ZITADEL_PAT CLOUD; main --apply 2>&1)"; rc=$?
check "no PAT and no CLOUD: fails"                    1 "$(nonzero "$rc")"
check "no PAT and no CLOUD: names CLOUD"              1 "$(grep -c 'CLOUD' <<<"$out")"

: >"$WRITES"
out="$(google_token() { return 1; }; main --apply 2>&1)"; rc=$?
check "no Google token: fails"                        1 "$(nonzero "$rc")"
check "no Google token: zero writes"                  0 "$(grep -c . "$WRITES")"

: >"$WRITES"
out="$(load_users() { return 1; }; main --apply 2>&1)"; rc=$?
check "users unreadable: fails"                       1 "$(nonzero "$rc")"
check "users unreadable: zero writes"                 0 "$(grep -c . "$WRITES")"

echo "== case 7: what a TRIPPED team printed before tripping never reaches the plan =="
# reconcile_team's contract: non-zero means "do nothing for this team", never
# "go on with what was printed". This backend run prints a revoke of d (4, who
# holds [backend,data]) and then trips -- so d's only intent is a tripped one.
: >"$WRITES"
out="$(reconcile_team() { echo "revoke d@ogenki.io"; echo "GUARD blast-radius: simulated"; return 1; }
       main --apply --team backend 2>&1)"; rc=$?
check "case 7: the tripped team fails the run"        1 "$(nonzero "$rc")"
check "case 7: d's grant is untouched -- zero writes" 0 "$(grep -c . "$WRITES")"

echo "== fix 2: main -- an approved revoke the planner must drop (multi-grant user) =="
# d (4) holds `data` on g4 and a second grant g4b. data's guards approve
# revoking d (1 of 2); the planner cannot place it.
MULTI='[{"userId":"1","grantId":"g1","roleKeys":["admin"]},
  {"userId":"3","grantId":"g3","roleKeys":["data"]},
  {"userId":"4","grantId":"g4","roleKeys":["backend","data"]},
  {"userId":"4","grantId":"g4b","roleKeys":["admin"]}]'
: >"$WRITES"
out="$(load_grants() { printf '%s' "$MULTI"; }; main --apply --team data 2>&1)"; rc=$?
check "multi-grant: exit non-zero"                    1 "$(nonzero "$rc")"
check "multi-grant: a's write still applies"          1 "$(grep -cFx 'put 1 g1 ["admin","data"]' "$WRITES")"
check "multi-grant: nothing written for d"            0 "$(grep -cE '^[a-z]+ 4 ' "$WRITES")"
check "multi-grant: the drop is reported"             1 "$(grep -c '^\[DROPPED\] revoke data d@ogenki.io' <<<"$out")"

echo "== fix 2: main -- an approved revoke of an AMBIGUOUS email =="
# user 7's userName is d@'s email, so d@ names two users.
AMBIG_D="$(jq -c '. + [{userId: "7", email: "other@ogenki.io", userName: "d@ogenki.io"}]' <<<"$USERS_JSON")"
: >"$WRITES"
out="$(load_users() { printf '%s' "$AMBIG_D"; }; main --apply --team data 2>&1)"; rc=$?
check "ambiguous revoke: exit non-zero"               1 "$(nonzero "$rc")"
check "ambiguous revoke: a's write still applies"     1 "$(grep -cFx 'put 1 g1 ["admin","data"]' "$WRITES")"
check "ambiguous revoke: the drop is reported"        1 "$(grep -c '^\[DROPPED\] revoke data d@ogenki.io' <<<"$out")"

echo "== fix 2: main -- a GRANT to an ambiguous email is a drop, not a pending first login =="
AMBIG_A="$(jq -c '. + [{userId: "7", email: "other@ogenki.io", userName: "a@ogenki.io"}]' <<<"$USERS_JSON")"
: >"$WRITES"
out="$(load_users() { printf '%s' "$AMBIG_A"; }; main --apply --team data 2>&1)"; rc=$?
check "ambiguous grant: exit non-zero"                1 "$(nonzero "$rc")"
check "ambiguous grant: reported as DROPPED"          1 "$(grep -c '^\[DROPPED\] grant data a@ogenki.io' <<<"$out")"
check "ambiguous grant: not called a pending login"   0 "$(grep -c 'skip.*a@ogenki.io' <<<"$out")"
check "ambiguous grant: d's revoke still applies"     1 "$(grep -cFx 'put 4 g4 ["backend"]' "$WRITES")"

echo "== fix 2: main -- skip-no-user alone stays exit 0 (never logged in is normal) =="
: >"$WRITES"
out="$(list_group_members() { echo '["a@ogenki.io","ghost@ogenki.io"]'; }; main --apply --team platform 2>&1)"; rc=$?
check "skip-no-user only: exit 0"                     0 "$rc"
check "skip-no-user only: reported as pending login"  1 "$(grep -c '^\[skip   \] platform: ghost@ogenki.io' <<<"$out")"
check "skip-no-user only: a's grant still applies"    1 "$(grep -cFx 'put 1 g1 ["admin","platform"]' "$WRITES")"

echo "== no test above reached the network =="
check "tripwire log is empty"  0 "$(grep -c . "$NET_LOG")"

[ "$fail" -eq 0 ] && echo "PASS" || echo "FAIL"
exit "$fail"
