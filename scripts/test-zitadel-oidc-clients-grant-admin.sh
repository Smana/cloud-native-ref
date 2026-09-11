#!/usr/bin/env bash
#
# grant_admin_role -- the --grant-admin bootstrap-recovery path -- must ADD
# `platform` to a user's EXISTING grant on the project, not POST a second one.
#
# ZITADEL keeps ONE user grant per (user, project), holding a roleKeys list:
# AddUserGrant POSTs one, UpdateUserGrant PUTs a replacement roleKeys list onto
# it. After a rebuild every operator already holds a grant on the project --
# the legacy ["admin"] one -- so a POST-only grant_admin_role fails for exactly
# the people --grant-admin exists to recover.
#
# grant_admin_role() is LIFTED verbatim out of zitadel-oidc-clients.sh via sed,
# the technique test-zitadel-oidc-clients-project.sh documents: that script
# parses argv at the top of the file and cannot be sourced. api_or_fail() and
# api() are stubbed; every write is recorded as "<method> <path> <body>".
#
# APPLY is read only by the eval'd grant_admin_role body -- shellcheck cannot
# see that use.
# shellcheck disable=SC2034
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
fail=0
check() { if [ "$2" = "$3" ]; then printf '  ok   %s\n' "$1"
          else printf '  FAIL %s: expected %q got %q\n' "$1" "$2" "$3"; fail=1; fi }

body="$(sed -n '/^grant_admin_role() {/,/^}/p' "${ZITADEL_OIDC_CLIENTS_SCRIPT:-$HERE/zitadel-oidc-clients.sh}")"
[ -n "$body" ] || { echo "could not extract grant_admin_role()" >&2; exit 1; }
eval "$body"

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
CALLS="$T/calls"

USERS='{"result":[{"id":"u1","userName":"ops@ogenki.io","human":{"email":{"email":"ops@ogenki.io"}}}]}'
GRANTS='{"result":[]}'
api_or_fail() {
    case "$2" in
        /management/v1/users/_search)        printf '%s' "$USERS" ;;
        /management/v1/users/grants/_search) printf '%s' "$GRANTS" ;;
        *) echo "unexpected read: $*" >&2; return 1 ;;
    esac
}
# A write. Its body arrives on stdin (`-d @-`).
api() { printf '%s %s %s\n' "$1" "$2" "$(jq -c .)" >>"$CALLS"; }

run() { : >"$CALLS"; out="$(grant_admin_role ops@ogenki.io p1 2>&1)"; rc=$?; }

APPLY=true

echo "== no grant on the project -> POST a new one (unchanged) =="
GRANTS='{"result":[]}'
run
check "exit 0"       0 "$rc"
check "one write"    1 "$(grep -c . "$CALLS")"
check "POST {projectId, [platform]}" 1 \
  "$(grep -cFx 'POST /management/v1/users/u1/grants {"projectId":"p1","roleKeys":["platform"]}' "$CALLS")"

echo "== an existing [admin] grant -> PUT [admin, platform] into it, no second grant =="
GRANTS='{"result":[{"id":"g1","userId":"u1","projectId":"p1","roleKeys":["admin"]}]}'
run
check "exit 0"       0 "$rc"
check "one write"    1 "$(grep -c . "$CALLS")"
check "PUT the union, the legacy role kept" 1 \
  "$(grep -cFx 'PUT /management/v1/users/u1/grants/g1 {"roleKeys":["admin","platform"]}' "$CALLS")"
check "no POST"      0 "$(grep -c '^POST' "$CALLS")"

echo "== a grant on ANOTHER project is not this project's grant -> POST =="
GRANTS='{"result":[{"id":"gx","userId":"u1","projectId":"other","roleKeys":["admin"]}]}'
run
check "POST, not a PUT into the other project's grant" 1 \
  "$(grep -cFx 'POST /management/v1/users/u1/grants {"projectId":"p1","roleKeys":["platform"]}' "$CALLS")"
check "no PUT"       0 "$(grep -c '^PUT' "$CALLS")"

echo "== already holds platform -> skip, no write =="
GRANTS='{"result":[{"id":"g1","userId":"u1","projectId":"p1","roleKeys":["admin","platform"]}]}'
run
check "no write"     0 "$(grep -c . "$CALLS")"
check "says skip"    1 "$(grep -c '^\[skip' <<<"$out")"

echo "== dry run with an existing grant -> no write =="
APPLY=false
GRANTS='{"result":[{"id":"g1","userId":"u1","projectId":"p1","roleKeys":["admin"]}]}'
run
check "no write"     0 "$(grep -c . "$CALLS")"
check "says dry-run" 1 "$(grep -c '^\[dry-run\]' <<<"$out")"

[ "$fail" -eq 0 ] && echo "PASS" || echo "FAIL"
exit "$fail"
