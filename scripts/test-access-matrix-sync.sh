#!/usr/bin/env bash
# Fixture tests for access-matrix-sync.sh's reconcile_team -- the four safety
# guards, with no network. These are the behaviours that decide whether a Google
# outage is a non-event or a platform-wide lockout, so they are tested first and
# directly.
#
# access-matrix-sync.sh is sourceable: it guards its CLI behind
# `[ "${BASH_SOURCE[0]}" = "$0" ]` precisely so this file can call one function.
set -uo pipefail
fail=0
check() { if [ "$2" = "$3" ]; then printf '  ok   %s\n' "$1"
          else printf '  FAIL %s: expected %q got %q\n' "$1" "$2" "$3"; fail=1; fi }

# shellcheck source=/dev/null
source "$(dirname "$0")/access-matrix-sync.sh"

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

echo "== blast radius: >half or >2 stops =="
out="$(reconcile_team data '[]' \
  '[{"email":"a@ogenki.io","userId":"1"},{"email":"b@ogenki.io","userId":"2"},
    {"email":"c@ogenki.io","userId":"3"},{"email":"d@ogenki.io","userId":"4"}]' 2>&1)"; rc=$?
check "exit non-zero"     1 "$([ "$rc" -ne 0 ] && echo 1 || echo 0)"
check "zero revocations"  0 "$(grep -c '^revoke' <<<"$out")"
check "says why"          1 "$(grep -c 'GUARD blast-radius' <<<"$out")"

echo "== two members, both leaving, still trips (the >2 half) =="
out="$(reconcile_team data '[]' \
  '[{"email":"a@ogenki.io","userId":"1"},{"email":"b@ogenki.io","userId":"2"}]' 2>&1)"
check "zero revocations"  0 "$(grep -c '^revoke' <<<"$out")"

echo "== platform is never left empty =="
out="$(reconcile_team platform '[]' '[{"email":"a@ogenki.io","userId":"1"}]' 2>&1)"; rc=$?
check "exit non-zero"     1 "$([ "$rc" -ne 0 ] && echo 1 || echo 0)"
check "zero revocations"  0 "$(grep -c '^revoke' <<<"$out")"
check "says why"          1 "$(grep -c 'GUARD zero-members' <<<"$out")"

echo "== idempotent: nothing to do =="
out="$(reconcile_team data '["a@ogenki.io"]' '[{"email":"a@ogenki.io","userId":"1"}]' 2>&1)"
check "no actions"        0 "$(grep -cE '^(grant|revoke)' <<<"$out")"

[ "$fail" -eq 0 ] && echo "PASS" || echo "FAIL"
exit "$fail"
