#!/usr/bin/env bash
# shellcheck disable=SC2034
# (file-wide: CLUSTER/CLOUD/IDP_URL/PRIVATE_DOMAIN/ZITADEL_PROJECT_NAME/
# GRANT_ADMIN/CONSUMERS/APPLY/APP_SUFFIX/HEADLAMP_OIDC_SCOPES below are read
# only by the eval'd bodies of the functions lifted out of the script, and
# those uses are invisible to static analysis.)
#
# NB: do not start a comment line here with the word "shellcheck" after the
# hash -- it is then parsed as a directive and fails with SC1072/SC1073, which
# is how this very paragraph broke the shellcheck gate once.
#
# Regression test for the MULTI-REDIRECT consumer (ADR-0034).
#
# OpenBao is the first consumer here needing two callbacks: the UI completes at
# /ui/vault/auth/<mount>/oidc/callback, the CLI at http://localhost:8250/oidc/callback.
# Before this, `redirect` was one URI and cmd_sync's staleness check was a single
# `grep -Fxq`, so registering a pair was not expressible.
#
# What makes this worth a test rather than an inspection: BOTH failure shapes are
# quiet. Register only one URI and the app exists, the client id and secret are
# right, and exactly one of the two entry points works -- an operator using the
# other gets ZITADEL's "The requested redirect_uri is missing in the client
# configuration" while a colleague on the other reports it working. And a
# staleness check that passes when ANY wanted URI is present would report
# `[ok] redirect correct` forever over a half-registered app.
#
# The single-URI consumers are covered here too. Splitting on comma is a change
# to the path all five of them take, and "openbao works, harbor silently stopped
# converging" is the obvious way to get this wrong.
#
# cmd_sync() and app_set_redirect() are lifted verbatim out of
# zitadel-oidc-clients.sh via sed, the same technique the sibling suites use,
# rather than restated here -- a restatement tests the copy, not the script.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
fail=0
check() { if [ "$2" = "$3" ]; then printf '  ok   %s\n' "$1"
          else printf '  FAIL %s: expected %q got %q\n' "$1" "$2" "$3"; fail=1; fi }
contains() { if grep -Fq "$2" <<< "$1"; then printf '  ok   %s\n' "$3"
          else printf '  FAIL %s: %q not found in %q\n' "$3" "$2" "$1"; fail=1; fi }

# Every function this suite lifts is one it asserts on, so a missing one is a
# setup error rather than something to tolerate -- unlike the sibling
# convergence suite, which must also run against a pre-fix script that
# legitimately lacks converge_secret. Failing here names the function; letting
# it through surfaces later as a bare "command not found".
load_function() {
    local body
    body="$(sed -n "/^${1}() {/,/^}/p" "$2")"
    [ -n "$body" ] || { echo "could not extract ${1}() from $2" >&2; exit 1; }
    eval "$body"
}

SRC="${ZITADEL_OIDC_CLIENTS_SCRIPT:-$HERE/zitadel-oidc-clients.sh}"
# oidc_config_payload builds the PUT body app_set_redirect sends, so the
# assertions below on redirectUris run against the real one.
load_function oidc_config_payload "$SRC"
load_function cmd_sync "$SRC"
load_function app_set_redirect "$SRC"
load_function merge_secret "$SRC"
load_function converge_secret "$SRC"

UI_CB="https://bao.priv.aws.ogenki.io:8200/ui/vault/auth/oidc/oidc/callback"
CLI_CB="http://localhost:8250/oidc/callback"
BOTH="${UI_CB},${CLI_CB}"

# ── stubs ─────────────────────────────────────────────────────────────────────
ensure_project() { echo "proj-1"; }
ensure_project_role_assertion() { :; }
ensure_project_roles() { :; }
grant_admin_role() { :; }
app_id_by_name() { echo "app-1"; }
# cmd_sync's last step, unrelated to redirects (it fixes the workforce-identity
# audience). Stubbed rather than exercised -- but stubbed EXPLICITLY, because
# cmd_sync runs under errexit here and an undefined function aborts it after the
# redirect work has printed nothing, which reads as "no output" rather than as a
# missing stub.
reconcile_workforce_audience() { :; }

# REGISTERED is what ZITADEL currently holds, one URI per line.
REGISTERED=""
app_get() {
    jq -n --argjson uris "$(printf '%s' "$REGISTERED" | jq -Rs 'split("\n") | map(select(length > 0))')" \
          --arg cid "existing-client-id" \
        '{app: {oidcConfig: {redirectUris: $uris, clientId: $cid}}}'
}
app_redirect_uris() { printf '%s\n' "$REGISTERED"; }

# app_set_redirect is the REAL one; `api` is stubbed to capture its payload so
# the jq that builds redirectUris is exercised rather than assumed.
#
# Captured to a FILE, not a variable, for the same reason the store below is
# real files: cmd_sync is driven inside `( set -o errexit ...; cmd_sync )`, a
# subshell, so anything it assigns to a variable in this shell is discarded when
# that subshell exits. An earlier version of this test captured into
# SET_PAYLOAD and every assertion about the repair payload read empty while the
# repair had visibly happened.
SET_FILE="$(mktemp)"
api() { printf '%s' "$4" > "$SET_FILE"; }
set_payload() { cat "$SET_FILE" 2>/dev/null; }
clear_payload() { : > "$SET_FILE"; }

STORE_DIR="$(mktemp -d)"
store_exists() { [ -f "$STORE_DIR/$1" ]; }
store_read()   { cat "$STORE_DIR/$1" 2>/dev/null || true; }
store_write()  { cat > "$STORE_DIR/$1"; }

CLUSTER="aws-0"; CLOUD="aws"
IDP_URL="https://auth.priv.aws.ogenki.io"
PRIVATE_DOMAIN="priv.aws.ogenki.io"
ZITADEL_PROJECT_NAME="platform"
GRANT_ADMIN=""; APP_SUFFIX=""
HEADLAMP_OIDC_SCOPES="profile,email,groups"
APPLY=true

OUT_FILE="$(mktemp)"
trap 'rm -f "$OUT_FILE" "$SET_FILE"; rm -rf "$STORE_DIR"' EXIT

run_sync() { ( set -o errexit -o nounset -o pipefail; cmd_sync ) > "$OUT_FILE" 2>&1; cat "$OUT_FILE"; }

echo "== app_set_redirect builds an ARRAY, not a one-element list =="
app_set_redirect proj-1 app-1 "$BOTH"
check "payload is valid JSON" "0" "$(jq -e . >/dev/null 2>&1 <<< "$(set_payload)"; echo $?)"
check "two redirectUris sent" "2" "$(jq '.redirectUris | length' <<< "$(set_payload)")"
check "UI callback sent"  "$UI_CB"  "$(jq -r '.redirectUris[0]' <<< "$(set_payload)")"
check "CLI callback sent" "$CLI_CB" "$(jq -r '.redirectUris[1]' <<< "$(set_payload)")"
# The role-assertion flags are what carry the groups claim ADR-0034 authorises
# on; a PUT that drops them reverts them to false and empties the claim while
# every login still succeeds.
check "accessTokenRoleAssertion kept" "true" "$(jq -r '.accessTokenRoleAssertion' <<< "$(set_payload)")"
check "idTokenRoleAssertion kept"     "true" "$(jq -r '.idTokenRoleAssertion' <<< "$(set_payload)")"

clear_payload
app_set_redirect proj-1 app-1 "$UI_CB"
check "single URI still yields one entry" "1" "$(jq '.redirectUris | length' <<< "$(set_payload)")"
check "single URI value preserved" "$UI_CB" "$(jq -r '.redirectUris[0]' <<< "$(set_payload)")"

echo
echo "== both registered: not stale =="
CONSUMERS=("openbao|${BOTH}|openbao-oidc")
printf '%s' '{"client_id":"existing-client-id","client_secret":"keep-me","endpoint":"https://auth.priv.aws.ogenki.io"}' > "$STORE_DIR/openbao-oidc"  # pragma: allowlist secret
REGISTERED="${UI_CB}
${CLI_CB}"
out="$(run_sync)"
contains "$out" "redirect correct" "reported correct"
check "not reported stale" "" "$(grep -o 'STALE' <<< "$out" | head -1)"

echo
echo "== only the UI callback registered: STALE, and repaired with BOTH =="
REGISTERED="$UI_CB"
clear_payload
out="$(run_sync)"
contains "$out" "STALE" "reported stale"
contains "$out" "missing: ${CLI_CB}" "names the missing URI, not just the pair"
check "repair sent two URIs" "2" "$(jq '.redirectUris | length' <<< "$(set_payload)")"

echo
echo "== only the CLI callback registered: also STALE =="
# The half that is easy to get wrong: a check written as \"is the first wanted
# URI present\" passes here, because the CLI callback is present and the UI one
# is the missing half.
REGISTERED="$CLI_CB"
out="$(run_sync)"
contains "$out" "STALE" "reported stale"
contains "$out" "missing: ${UI_CB}" "names the UI callback as missing"

echo
echo "== neither registered: STALE, both named missing =="
REGISTERED=""
out="$(run_sync)"
contains "$out" "STALE" "reported stale"
contains "$out" "$UI_CB" "names the UI callback"
contains "$out" "$CLI_CB" "names the CLI callback"

echo
echo "== an EXTRA registered URI is left alone =="
# Converging the login is this script's job; narrowing what else somebody
# registered is a different decision, and silently deleting a URI would break
# whatever depends on it.
REGISTERED="${UI_CB}
${CLI_CB}
https://bao.priv.aws.ogenki.io:8200/some/other/callback"
out="$(run_sync)"
contains "$out" "redirect correct" "extra URI does not make it stale"

echo
echo "== single-URI consumers still converge (regression) =="
HARBOR_CB="https://harbor.${PRIVATE_DOMAIN}/c/oidc/callback"
CONSUMERS=("harbor|${HARBOR_CB}|harbor-oidc")
printf '%s' '{"client_id":"existing-client-id","client_secret":"keep-me","endpoint":"https://auth.priv.aws.ogenki.io"}' > "$STORE_DIR/harbor-oidc"  # pragma: allowlist secret
REGISTERED="$HARBOR_CB"
out="$(run_sync)"
contains "$out" "redirect correct" "harbor unaffected by the split"

REGISTERED="https://harbor.priv.cloud.ogenki.io/c/oidc/callback"
clear_payload
out="$(run_sync)"
contains "$out" "STALE" "harbor with a stale domain still detected"
check "harbor repair sends one URI" "1" "$(jq '.redirectUris | length' <<< "$(set_payload)")"

echo
echo "== the openbao payload is not the empty jq fallthrough =="
# Every consumer needs a branch in merge_secret/converge_secret's jq. A missing
# one falls to `else empty`, and the store write that follows fails with
# "Secret Payload cannot be empty" -- AFTER the app was created in ZITADEL,
# stranding a client secret ZITADEL only ever returns once.
payload="$(merge_secret openbao-oidc openbao new-id new-secret)"
check "merge_secret: client_id"     "new-id"     "$(jq -r '.client_id' <<< "$payload")"
check "merge_secret: client_secret" "new-secret" "$(jq -r '.client_secret' <<< "$payload")"
check "merge_secret: endpoint"      "$IDP_URL"   "$(jq -r '.endpoint' <<< "$payload")"

converged="$(converge_secret openbao converged-id '{"client_id":"old","client_secret":"keep-me","endpoint":"old"}')"  # pragma: allowlist secret
check "converge_secret: client_id updated" "converged-id" "$(jq -r '.client_id' <<< "$converged")"
check "converge_secret: endpoint updated"  "$IDP_URL"     "$(jq -r '.endpoint' <<< "$converged")"
# The secret must survive convergence: ZITADEL returns it once, so a converge
# that dropped it could never put it back.
check "converge_secret: client_secret preserved" "keep-me" "$(jq -r '.client_secret' <<< "$converged")"

echo
if [ "$fail" -eq 0 ]; then echo "PASS"; else echo "FAIL"; fi
exit "$fail"
