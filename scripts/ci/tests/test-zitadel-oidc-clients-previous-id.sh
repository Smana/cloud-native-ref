#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2329
# (MIRROR_OPENBAO and the store/mirror stubs are used by the function bodies eval'd out of
# the script, which static analysis cannot see.)
#
# A created client is a rotation when its consumers already run with another id.
# They read that id from the managed store or, on a mirrored key, from OpenBao. A
# lineage whose OpenBao was restored while the store was not (aws-0, 2026-10-06:
# no agents-rooms-proxy in Secrets Manager, the restored agents/rooms-proxy holding
# the 10-04 client) must count as a rotation, or the env readers keep the dead
# client ("App not found") while the sync reports "nothing to restart".
# The function is lifted out of the script, so this tests the code that ships.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
cd "$REPO_ROOT" || exit 1
S="${ZITADEL_OIDC_CLIENTS_SCRIPT:-scripts/provision/zitadel-oidc-clients.sh}"
fail=0
ok()  { printf '  ok   %s\n' "$1"; }
bad() { printf '  FAIL %s\n' "$1"; fail=1; }

for f in stored_client_id previous_client_id; do
    body="$(sed -n "/^${f}() {/,/^}/p" "$S")"
    [ -n "$body" ] || { echo "could not extract ${f}() from $S" >&2; exit 1; }
    eval "$body"
done

# The store and the mirror, as each scenario sets them; called by the lifted body.
STORE=""; MIRROR=""
store_exists() { [ -n "$STORE" ]; }
store_read()   { printf '%s' "$STORE"; }
mirror_read()  { printf '%s' "$MIRROR"; }

check() { # name, want, store, mirror, mirror flag
    STORE="$3" MIRROR="$4" MIRROR_OPENBAO="$5"
    got="$(previous_client_id agents-rooms-proxy)"
    if [ "$got" = "$2" ]; then ok "$1"; else bad "$1: got '${got}', want '$2'"; fi
}

check "the store's id wins"                       store-id '{"client-id":"store-id"}' '{"client-id":"bao-id"}' true
check "a restored mirror stands in for an empty store" bao-id ''                         '{"client-id":"bao-id"}' true
check "no mirroring: the mirror is not read"      ''       ''                            '{"client-id":"bao-id"}' false
check "neither holds a client: a first bootstrap" ''       ''                            ''                       true
check "a store payload without an id falls through" bao-id '{"other":"x"}'              '{"client-id":"bao-id"}' true

exit "$fail"
