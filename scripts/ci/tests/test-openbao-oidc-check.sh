#!/usr/bin/env bash
#
# Offline tests for scripts/openbao-oidc-check.sh (design E, #2045): the
# post-deploy check that proves OpenBao's auth/oidc client agrees with the
# secret store and with ZITADEL, one test per exit-code case in the plan's
# Task 5 brief.
#
# WHY END-TO-END, RATHER THAN LIFTED FUNCTIONS. Every other suite in this
# directory that tests a big script lifts one function out with sed, because
# the script itself parses argv at the top and is not sourceable. This
# subject IS that shape too, but it has no internal function worth lifting in
# isolation: the whole point under test is the SEQUENCE of decisions --
# secret vs. mount, then id agreement, then a live probe -- so the suite runs
# the real script as a subprocess, with `aws` and `curl` replaced by small
# fakes on PATH. A function lifted out and eval'd would still need this exact
# fixture machinery to drive it; running the real binary means the argv
# parsing and the `--ca-file` existence check are exercised for free.
#
# WHY PATH STUBS. Same reasoning as test-zitadel-oidc-clients-openbao.sh: a
# stub function would be bypassed by `command`/`env`, and it is the only way
# to prove secrets travel where the design says without contacting anything
# real. `aws` fakes Secrets Manager with flat files; `curl` fakes OpenBao's
# /v1 API from those same files, AND fakes the authorize URL's first hop
# (identified by having no `-K`: it is the one call in this script that must
# NOT carry the root token, because it goes to ZITADEL, not OpenBao).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
fail=0
check() { if [ "$2" = "$3" ]; then printf '  ok   %s\n' "$1"
          else printf '  FAIL %s: expected %q got %q\n' "$1" "$2" "$3"; fail=1; fi }
contains() { if grep -qF -- "$2" <<< "$1"; then printf '  ok   %s\n' "$3"
             else printf '  FAIL %s: %q not found in %q\n' "$3" "$2" "$1"; fail=1; fi }
absent() { if grep -qF -- "$2" <<< "$1"; then printf '  FAIL %s: %q found\n' "$3" "$2"; fail=1
           else printf '  ok   %s\n' "$3"; fi }

# The subject is still at scripts/ root. When it moves, this path moves with it.
SUBJECT="${OPENBAO_OIDC_CHECK_SCRIPT:-$HERE/../../openbao-oidc-check.sh}"
[ -f "$SUBJECT" ] || { echo "  FAIL $SUBJECT does not exist" >&2; exit 1; }
REAL_JQ="$(command -v jq)"
rjq() { "$REAL_JQ" "$@"; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
STUB_BIN="$WORK/bin"
mkdir -p "$STUB_BIN"
STORE="$WORK/store"
CURL_STATE="$WORK/bao"
CURL_LOG="$WORK/curl.log"
export STORE CURL_STATE CURL_LOG REAL_JQ

# A tiny Secrets Manager: one file per secret id, sanitised the same way
# store_file() does in the other suites (cloud-secret-store.sh's own tests
# cover CLOUD dispatch and eventual-consistency; this only needs the two
# calls openbao-oidc-check.sh actually makes).
cat > "$STUB_BIN/aws" <<'EOF'
#!/usr/bin/env bash
service="$1" action="$2"; shift 2
secret_id=""
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
    [ "${args[$i]}" = "--secret-id" ] && secret_id="${args[$((i + 1))]}"
done
file="$STORE/${secret_id//\//_}"
case "$service $action" in
    "secretsmanager describe-secret")   [ -f "$file" ] ;;
    "secretsmanager get-secret-value")  [ -f "$file" ] && cat "$file" ;;
    *) echo "aws stub: unhandled $service $action" >&2; exit 1 ;;
esac
EOF

# A small fake OpenBao, plus the authorize URL's first hop.
#
# The first hop is told apart from every OpenBao call by having no `-K`:
# openbao-oidc-check.sh never sends the root token to ZITADEL, so that is the
# one call in the whole script this stub can identify structurally rather
# than by inspecting the URL. It fills the -w format from $AUTHORIZE_HTTP_CODE
# (default 302) and $AUTHORIZE_LOCATION (default ZITADEL's login page) or,
# with $AUTHORIZE_CURL_FAIL=1, fails the connection outright -- the
# "OpenBao unreachable" shape reused for "ZITADEL unreachable", since both
# collapse to the same exit 2 in this script.
#
# $CFG_READ_FAIL / $ROLE_READ_FAIL fail their one GET each (a permission
# error, not a connection drop -- --fail-with-body's shape); $AUTH_URL_ERROR
# does the same for the auth_url POST. Each drives one of this script's own
# "cannot tell" branches independently of the others.
#
# $AUTH_URL_EMPTY_TIMES / $AUTHORIZE_FAIL_TIMES make the first N auth_url
# POSTs answer an empty auth_url, or the first N first hops fail to connect,
# then recover: the transient shapes the probe's retry exists for.
cat > "$STUB_BIN/curl" <<'EOF'
#!/usr/bin/env bash
args=("$@") method=GET url="" kfile="" has_body=no wants_code=no wfmt=""
for ((i = 0; i < ${#args[@]}; i++)); do
    case "${args[$i]}" in
        -X) method="${args[$((i + 1))]}" ;;
        -K) kfile="${args[$((i + 1))]}" ;;
        -w) wfmt="${args[$((i + 1))]}"; [ "${wfmt#%\{http_code\}}" != "$wfmt" ] && wants_code=yes ;;
        @-) has_body=yes ;;
        http://*|https://*) url="${args[$i]}" ;;
    esac
done
{ printf 'CALL:'; printf ' %q' "$@"; printf '\n'; } >> "$CURL_LOG"

body="$WORK_BODY"
[ "$has_body" = yes ] && cat > "$body"
nth() { local f="$CURL_STATE/$1.count" n; n=$(( $(cat "$f" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$f"; echo "$n"; }

if [ "$wants_code" = yes ] && [ -z "$kfile" ]; then
    if [ "${AUTHORIZE_CURL_FAIL:-0}" = 1 ] || [ "$(nth first_hop)" -le "${AUTHORIZE_FAIL_TIMES:-0}" ]; then
        echo "curl: (7) Failed to connect to host" >&2
        exit 7
    fi
    # Quoted replacements: bash 5.2's patsub_replacement expands a bare `&`.
    out="${wfmt//"%{http_code}"/"${AUTHORIZE_HTTP_CODE:-302}"}"
    printf '%s' "${out//"%{redirect_url}"/"${AUTHORIZE_LOCATION-https://auth.cloud.ogenki.io/ui/login/login?authRequestID=1}"}"
    exit 0
fi

if [ "${BAO_UNREACHABLE:-0}" = 1 ]; then
    echo "curl: (7) Failed to connect to host" >&2
    exit 7
fi

path="${url#*/v1/}"
case "$method $path" in
    "GET sys/auth")               cat "$CURL_STATE/sys_auth.json" 2>/dev/null || echo '{"data":{}}' ;;
    "GET auth/oidc/config")
        if [ "${CFG_READ_FAIL:-0}" = 1 ]; then
            echo '{"errors":["permission denied"]}' >&2
            exit 22
        fi
        "$REAL_JQ" -c '{data: (del(.oidc_client_secret) + {status: "valid"})}' "$CURL_STATE/config.json" ;;
    "GET auth/oidc/role/default")
        if [ "${ROLE_READ_FAIL:-0}" = 1 ]; then
            echo '{"errors":["permission denied"]}' >&2
            exit 22
        fi
        "$REAL_JQ" -c '{data: .}' "$CURL_STATE/role.json" ;;
    "POST auth/oidc/oidc/auth_url")
        if [ -n "${AUTH_URL_ERROR:-}" ]; then
            printf '%s' "$AUTH_URL_ERROR" >&2
            exit 22
        fi
        u="${AUTH_URL_VALUE-https://auth.cloud.ogenki.io/authorize?client_id=x}"
        [ "$(nth auth_url)" -le "${AUTH_URL_EMPTY_TIMES:-0}" ] && u=""
        "$REAL_JQ" -cn --arg u "$u" '{data: {auth_url: $u}}' ;;
    *) echo "curl stub: unhandled $method $path" >&2; exit 1 ;;
esac
exit 0
EOF
chmod +x "$STUB_BIN/aws" "$STUB_BIN/curl"
WORK_BODY="$WORK/last-body"
export WORK_BODY
PATH="$STUB_BIN:$PATH"
export OPENBAO_CHECK_RETRY_SLEEP=0

calls() { grep '^CALL:' "$CURL_LOG"; }
count_calls() { grep -cF -- "$1" "$CURL_LOG"; }  # needle -> how many curl calls carried it
tls_verified() { # label, call lines
    if grep -qE -- '(^| )(-[A-Za-z]*k[A-Za-z]*|--insecure)( |$)' <<< "$2"; then
        printf '  FAIL %s: an insecure flag in %s\n' "$1" "$2"; fail=1
    else
        printf '  ok   %s\n' "$1"
    fi
}

CA_FILE="$WORK/ca.pem"
: > "$CA_FILE"
BAO_URL="https://bao.priv.aws.ogenki.io:8200"
OIDC_SECRET_NAME="openbao-oidc"  # pragma: allowlist secret -- a store KEY name, not a secret value
ROOT_SECRET_NAME="openbao/cloud-native-ref/tokens/root"  # pragma: allowlist secret
REDIRECT_URI="http://localhost:8250/oidc/callback"
ID="222222222222222222"
CS="CS-SENTINEL-4b1d"
ROOT="ROOT-TOKEN-SENTINEL-9e7c"

# A fully consistent, bootstrapped platform: the store, the config, the role
# and the live probe all agree on $ID. Each test starts here and un-converges
# exactly the one thing it means to exercise.
world() {
    rm -rf "$CURL_STATE" "$STORE"
    mkdir -p "$CURL_STATE" "$STORE"
    : > "$CURL_LOG"
    unset AUTHORIZE_CURL_FAIL AUTH_URL_ERROR CFG_READ_FAIL ROLE_READ_FAIL AUTH_URL_EMPTY_TIMES AUTHORIZE_FAIL_TIMES AUTHORIZE_LOCATION
    export AUTHORIZE_HTTP_CODE=302
    export AUTH_URL_VALUE="https://auth.cloud.ogenki.io/authorize?client_id=${ID}"
    echo '{"data":{"oidc/":{"type":"oidc"},"token/":{"type":"token"}}}' > "$CURL_STATE/sys_auth.json"
    rjq -cn --arg id "$ID" '{
        oidc_discovery_url: "https://auth.cloud.ogenki.io", oidc_discovery_ca_pem: "",
        oidc_client_id: $id, oidc_client_secret: "OLD-SECRET", default_role: "default",
        bound_issuer: "https://auth.cloud.ogenki.io", namespace_in_state: true,
        provider_config: {}}' > "$CURL_STATE/config.json"
    rjq -cn --arg id "$ID" --arg cb "$BAO_URL/ui/vault/auth/oidc/oidc/callback" '{
        role_type: "oidc", bound_audiences: [$id], user_claim: "email", groups_claim: "groups",
        allowed_redirect_uris: [$cb, "http://localhost:8250/oidc/callback"]}' > "$CURL_STATE/role.json"
    printf '{"client_id":"%s","client_secret":"%s","endpoint":"https://auth.cloud.ogenki.io"}' "$ID" "$CS" \
        > "$STORE/${OIDC_SECRET_NAME//\//_}"
    printf '{"token":"%s"}' "$ROOT" > "$STORE/${ROOT_SECRET_NAME//\//_}"
}

run_check() {
    out="$(bash "$SUBJECT" --url "$BAO_URL" --root-token-secret-name "$ROOT_SECRET_NAME" \
        --ca-file "$CA_FILE" --cloud aws --oidc-secret "$OIDC_SECRET_NAME" \
        --redirect-uri "$REDIRECT_URI" 2>&1)"
    rc=$?
}

echo "== exit 0: consistent =="
world; run_check
check "consistent: returns 0" "0" "$rc"
contains "$out" "[ok     ]" "consistent: says [ok     ]"
contains "$out" "$ID" "consistent: names the client id"

echo
echo "== exit 0: not bootstrapped =="
world
rm -f "$STORE/${OIDC_SECRET_NAME//\//_}"
echo '{"data":{"token/":{"type":"token"}}}' > "$CURL_STATE/sys_auth.json"
run_check
check "not bootstrapped: returns 0" "0" "$rc"
contains "$out" "not bootstrapped" "not bootstrapped: says so"
absent "$out" "[FAILED" "not bootstrapped: no failure line"

echo
echo "== exit 1: the secret exists but the mount doesn't =="
world
echo '{"data":{"token/":{"type":"token"}}}' > "$CURL_STATE/sys_auth.json"
run_check
check "secret, no mount: returns 1" "1" "$rc"
contains "$out" "no oidc/ auth mount yet" "secret, no mount: names the gap"
contains "$out" "terramate -C opentofu/aws/openbao/management script run deploy" \
    "secret, no mount: prints the management apply command"

echo
echo "== exit 1: the mount exists but the secret doesn't =="
world
rm -f "$STORE/${OIDC_SECRET_NAME//\//_}"
run_check
check "mount, no secret: returns 1" "1" "$rc"
contains "$out" "DESTROY the mount" "mount, no secret: warns the next apply destroys it"

echo
echo "== exit 2: cannot read auth/oidc/config =="
world
export CFG_READ_FAIL=1
run_check
check "config unreadable: returns 2" "2" "$rc"
contains "$out" "cannot read auth/oidc/config" "config unreadable: says so"
unset CFG_READ_FAIL

echo
echo "== exit 2: cannot read auth/oidc/role/default =="
world
export ROLE_READ_FAIL=1
run_check
check "role unreadable: returns 2" "2" "$rc"
contains "$out" "cannot read auth/oidc/role/default" "role unreadable: says so"
unset ROLE_READ_FAIL

echo
echo "== exit 1: the config id doesn't match the store =="
world
rjq '.oidc_client_id = "111111111111111111"' "$CURL_STATE/config.json" > "$WORK/c.json" && mv "$WORK/c.json" "$CURL_STATE/config.json"
run_check
check "config id mismatch: returns 1" "1" "$rc"
contains "$out" "does not match the store" "config id mismatch: names the mismatch"
contains "$out" "store:            ${ID}" "config id mismatch: prints the store id"
contains "$out" "auth/oidc/config: 111111111111111111" "config id mismatch: prints the config id"
contains "$out" "role audience:" "config id mismatch: prints the role audience"
contains "$out" "sync --apply" "config id mismatch: prints the fix command"
check "config id mismatch: not retried -- one config read" "1" "$(count_calls auth/oidc/config)"
check "config id mismatch: not retried -- no auth_url POST" "0" "$(count_calls auth/oidc/oidc/auth_url)"

echo
echo "== exit 1: the role audience doesn't match the store =="
world
rjq '.bound_audiences = ["111111111111111111"]' "$CURL_STATE/role.json" > "$WORK/r.json" && mv "$WORK/r.json" "$CURL_STATE/role.json"
run_check
check "role audience mismatch: returns 1" "1" "$rc"
contains "$out" "does not match the store" "role audience mismatch: names the mismatch"
contains "$out" '["111111111111111111"]' "role audience mismatch: prints the stale audience"

echo
echo "== exit 2: liveness -- auth_url keeps returning no URL =="
# OpenBao v2.6.2 answers 200 with an empty auth_url both when discovery fails
# (ZITADEL briefly unreachable) and when the redirect_uri is not allowed --
# it cannot say which, so neither can this script.
world
export AUTH_URL_VALUE=""
run_check
check "persistent empty auth_url: returns 2" "2" "$rc"
contains "$out" "returned no auth_url" "persistent empty auth_url: says so"
contains "$out" "OpenBao cannot fetch ZITADEL's discovery document, or the redirect_uri is not in the role's allowed_redirect_uris" \
    "persistent empty auth_url: names both causes"
check "persistent empty auth_url: tried 5 times" "5" "$(count_calls auth/oidc/oidc/auth_url)"

echo
echo "== exit 0: liveness -- an empty auth_url that recovers is retried =="
world
export AUTH_URL_EMPTY_TIMES=2
run_check
check "transient empty auth_url: returns 0" "0" "$rc"
check "transient empty auth_url: third attempt succeeds" "3" "$(count_calls auth/oidc/oidc/auth_url)"

echo
echo "== exit 1: liveness -- the first hop returns 400 (App.NotFound) =="
world
export AUTHORIZE_HTTP_CODE=400
run_check
check "first hop 400: returns 1" "1" "$rc"
contains "$out" "App.NotFound" "first hop 400: names App.NotFound"
contains "$out" "$ID" "first hop 400: names the client id"
check "first hop 400: not retried" "1" "$(count_calls auth.cloud.ogenki.io/authorize)"
# A 400 is also ZITADEL's answer for a known client asked for a redirect_uri
# it never registered -- the message must not claim App.NotFound alone.
contains "$out" "$REDIRECT_URI" "first hop 400: names the redirect_uri as the other cause"

echo
echo "== exit 1: liveness -- a 302 straight back to the redirect_uri is an error =="
# ZITADEL knows the client but refused the request, so it redirected to the
# redirect_uri with ?error= rather than to its login page.
world
export AUTHORIZE_LOCATION="${REDIRECT_URI}?error=invalid_scope&state=STATE-SENTINEL"
run_check
check "302 back with ?error=: returns 1" "1" "$rc"
contains "$out" "ZITADEL redirected back with an error" "302 back with ?error=: says so"
contains "$out" "error=invalid_scope" "302 back with ?error=: names the error"
absent "$out" "STATE-SENTINEL" "302 back with ?error=: prints the error, not the whole query"
check "302 back with ?error=: not retried" "1" "$(count_calls auth.cloud.ogenki.io/authorize)"

echo
echo "== exit 2: liveness -- the auth_url POST itself cannot be reached =="
world
export AUTH_URL_ERROR='{"errors":["permission denied"]}'
run_check
check "auth_url unreachable: returns 2" "2" "$rc"
contains "$out" "cannot reach auth/oidc/oidc/auth_url" "auth_url unreachable: says so"
unset AUTH_URL_ERROR

echo
echo "== exit 2: liveness -- the authorize URL's first hop cannot be reached =="
world
export AUTHORIZE_CURL_FAIL=1
run_check
check "first hop unreachable: returns 2" "2" "$rc"
contains "$out" "cannot reach the authorize URL's first hop" "first hop unreachable: says so"
unset AUTHORIZE_CURL_FAIL

echo
echo "== exit 0: liveness -- a first hop that fails, then connects, is retried =="
world
export AUTHORIZE_FAIL_TIMES=2
run_check
check "transient first hop: returns 0" "0" "$rc"
check "transient first hop: third attempt succeeds" "3" "$(count_calls auth.cloud.ogenki.io/authorize)"

echo
echo "== the auth_url POST body carries the role and the configured redirect_uri =="
world; run_check
body_json="$(cat "$WORK_BODY")"
check "auth_url body: role" "default" "$(rjq -r '.role' <<< "$body_json")"
check "auth_url body: redirect_uri" "$REDIRECT_URI" "$(rjq -r '.redirect_uri' <<< "$body_json")"

echo
echo "== exit 2: OpenBao unreachable =="
world
export BAO_UNREACHABLE=1
run_check
check "OpenBao unreachable: returns 2" "2" "$rc"
contains "$out" "cannot reach OpenBao" "OpenBao unreachable: says so"
unset BAO_UNREACHABLE

echo
echo "== exit 2: the root token is unreadable =="
world
rm -f "$STORE/${ROOT_SECRET_NAME//\//_}"
run_check
check "unreadable token: returns 2" "2" "$rc"
contains "$out" "no root token readable" "unreadable token: says so"

echo
echo "== exit 2: the first hop returns neither 302 nor 400 =="
world
export AUTHORIZE_HTTP_CODE=500
run_check
check "first hop 500: returns 2" "2" "$rc"
contains "$out" "neither 302 nor 400" "first hop 500: says cannot tell"
contains "$out" "T0" "first hop 500: names T0 as unverified"
check "first hop 500: tried 5 times" "5" "$(count_calls auth.cloud.ogenki.io/authorize)"

echo
echo "== exit 2: a non-map sys/auth answer is cannot-tell, never 'no mount' =="
world
echo '{}' > "$CURL_STATE/sys_auth.json"
run_check
check "ambiguous sys/auth: returns 2" "2" "$rc"
contains "$out" "no mount map" "ambiguous sys/auth: says cannot tell"
absent "$out" "not bootstrapped" "ambiguous sys/auth: never says not bootstrapped"

echo
echo "== flags: required, and the --oidc-secret default =="
world
out="$(bash "$SUBJECT" --root-token-secret-name "$ROOT_SECRET_NAME" --ca-file "$CA_FILE" --cloud aws --redirect-uri "$REDIRECT_URI" 2>&1)"
rc=$?
check "no --url: returns 2" "2" "$rc"
contains "$out" "--url is required" "no --url: names it"

out="$(bash "$SUBJECT" --url "$BAO_URL" --ca-file "$CA_FILE" --cloud aws --redirect-uri "$REDIRECT_URI" 2>&1)"
rc=$?
check "no --root-token-secret-name: returns 2" "2" "$rc"

out="$(bash "$SUBJECT" --url "$BAO_URL" --root-token-secret-name "$ROOT_SECRET_NAME" --cloud aws --redirect-uri "$REDIRECT_URI" 2>&1)"
rc=$?
check "no --ca-file: returns 2" "2" "$rc"

out="$(bash "$SUBJECT" --url "$BAO_URL" --root-token-secret-name "$ROOT_SECRET_NAME" --ca-file "$WORK/missing.pem" --cloud aws --redirect-uri "$REDIRECT_URI" 2>&1)"
rc=$?
check "a --ca-file that does not exist: returns 2" "2" "$rc"

out="$(bash "$SUBJECT" --url "$BAO_URL" --root-token-secret-name "$ROOT_SECRET_NAME" --ca-file "$CA_FILE" --cloud azure --redirect-uri "$REDIRECT_URI" 2>&1)"
rc=$?
check "an invalid --cloud: returns 2" "2" "$rc"

out="$(bash "$SUBJECT" --url "$BAO_URL" --root-token-secret-name "$ROOT_SECRET_NAME" --ca-file "$CA_FILE" --cloud aws 2>&1)"
rc=$?
check "no --redirect-uri: returns 2" "2" "$rc"

# The default is exercised by every other test above (none pass --oidc-secret
# down a different path than "openbao-oidc"); this pins the literal default
# by omitting the flag explicitly rather than relying on that coincidence.
world
out="$(bash "$SUBJECT" --url "$BAO_URL" --root-token-secret-name "$ROOT_SECRET_NAME" \
    --ca-file "$CA_FILE" --cloud aws --redirect-uri "$REDIRECT_URI" 2>&1)"
rc=$?
check "--oidc-secret defaults to openbao-oidc: returns 0" "0" "$rc"

echo
echo "== the root token and the client secret are on no argv, and TLS is verified =="
world; run_check
absent "$(calls)" "$ROOT" "curl's argv never carries the root token"
absent "$(calls)" "$CS"   "curl's argv never carries the client secret"
absent "$out"      "$ROOT" "stdout never carries the root token"
absent "$out"      "$CS"   "stdout never carries the client secret"
tls_verified "every call verifies TLS" "$(calls)"
contains "$(calls)" "--cacert $CA_FILE" "the OpenBao calls pass --cacert"

echo
echo "== the authorize URL's first hop never carries the root token =="
world; run_check
first_hop="$(grep -F "auth.cloud.ogenki.io/authorize" "$CURL_LOG" || true)"
check "the first hop was made" "yes" "$([ -n "$first_hop" ] && echo yes || echo no)"
absent "$first_hop" "-K " "the first hop carries no -K (no root token to ZITADEL)"

echo
if [ "$fail" -eq 0 ]; then echo "PASS"; else echo "==> failure(s) above"; fi
exit "$fail"
