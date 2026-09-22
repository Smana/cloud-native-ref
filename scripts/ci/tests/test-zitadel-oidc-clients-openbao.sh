#!/usr/bin/env bash
#
# The OpenBao OIDC client rotation (#2045): two contract guards, the curl
# helper in scripts/lib/openbao-api.sh, and the reconcile in
# zitadel-oidc-clients.sh that points OpenBao at the client ZITADEL issued.
#
# WHY A CONTRACT GUARD, NOT JUST A UNIT TEST. Both guards below protect an
# agreement between files that nothing else checks:
#   * the "openbao" CONSUMERS entry's secret key and variables.tfvars'
#     openbao_oidc_secret_id name the SAME store key by coincidence, not by
#     reference -- drift here is #2011's bug shape: the reconcile would read
#     one key while Terraform reads another, and each converges its own copy
#     while the platform stays split.
#   * the role's UI callback is a Terraform LITERAL -- oidc.tf explains why
#     (referencing the mount resource would invert the create order) -- so
#     nothing in OpenTofu stops it drifting from what the CONSUMERS table
#     registers in ZITADEL.
#
# WHY PATH STUBS. curl, jq and sleep are executables on a stub PATH, not shell
# functions: a function is bypassed by `command curl` or `env curl`, and a jq
# wrapper that logs argv before exec-ing the real jq is what proves the client
# secret reached jq on stdin rather than through --arg. The curl stub is a
# small fake OpenBao: a config write replaces; a role write merges, except four
# fields an omission resets; a read drops the secret and adds `status` (design
# facts 6 and 7).
#
# APPLY and the OPENBAO_* globals are read only by function bodies lifted out
# of the script with sed, which shellcheck cannot see through.
# shellcheck disable=SC2034
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../../.." && pwd)"
fail=0
check() { if [ "$2" = "$3" ]; then printf '  ok   %s\n' "$1"
          else printf '  FAIL %s: expected %q got %q\n' "$1" "$2" "$3"; fail=1; fi }
contains() { if grep -qF -- "$2" <<< "$1"; then printf '  ok   %s\n' "$3"
             else printf '  FAIL %s: %q not found in %q\n' "$3" "$2" "$1"; fail=1; fi }
absent() { if grep -qF -- "$2" <<< "$1"; then printf '  FAIL %s: %q found\n' "$3" "$2"; fail=1
           else printf '  ok   %s\n' "$3"; fi }

# ── contract guards against the real repo files ─────────────────────────────
#
# Overridable so a guard-failure proof can point at a temp copy instead of the
# committed file (see the plan's Task 1, Step 2). The subject is still at
# scripts/ root. When it moves, this path moves with it.
CONSUMERS_SRC="${ZITADEL_OIDC_CLIENTS_SCRIPT:-$HERE/../../zitadel-oidc-clients.sh}"
TFVARS_SRC="${OPENBAO_MANAGEMENT_TFVARS:-$REPO_ROOT/opentofu/aws/openbao/management/variables.tfvars}"
OIDC_TF_SRC="${OPENBAO_OIDC_TF:-$REPO_ROOT/opentofu/aws/openbao/management/oidc.tf}"

echo "== contract: the openbao CONSUMERS key matches variables.tfvars (#2011) =="
consumers_line="$(grep -E '^[[:space:]]*"openbao\|' "$CONSUMERS_SRC" || true)"
consumers_key="$(sed -E 's/^[[:space:]]*"(.*)"[,]?$/\1/' <<< "$consumers_line" | awk -F'|' '{print $NF}')"
# Only an UNCOMMENTED assignment matches: a line starting with "#" (a comment)
# never satisfies `^[[:space:]]*openbao_oidc_secret_id`, so commenting the
# variable out -- the shape of the #2011 regression -- turns this empty rather
# than stale.
tfvars_key="$(sed -nE 's/^[[:space:]]*openbao_oidc_secret_id[[:space:]]*=[[:space:]]*"([^"]*)".*/\1/p' "$TFVARS_SRC" | head -1)"
check "CONSUMERS declares the openbao key" "openbao-oidc" "$consumers_key"
check "tfvars key matches, uncommented"    "$consumers_key" "$tfvars_key"

echo
echo "== contract: the role's UI callback is /ui/vault/auth/oidc/oidc/callback =="
# Anchored to an ACTIVE list element, not `grep -qF`: the plain substring match
# this replaced was satisfied by the literal sitting after a `#`, so commenting
# the whole redirect_uris entry out (oidc.tf:82) still reported "pins the UI
# callback path" -- the exact shape the tfvars guard above was written to
# reject for #2011, just not applied here yet. Requiring the line to start
# (after indentation) with the opening quote and end with the closing quote
# and an optional trailing comma is what makes a comment fail to match.
if grep -qE '^[[:space:]]*"\$\{local\.openbao_address\}/ui/vault/auth/oidc/oidc/callback",?[[:space:]]*$' "$OIDC_TF_SRC"; then
    callback_found=yes
else
    callback_found=no
fi
check "oidc.tf pins the UI callback path" "yes" "$callback_found"

# The other side of the same agreement: this header claims the guard protects
# oidc.tf against CONSUMERS drifting apart, but until now nothing here ever
# read the CONSUMERS side for this path -- only for the store key above. A
# CONSUMERS callback edited to a different mount, or the plain substring lost
# entirely, must fail here rather than only failing against a live ZITADEL.
contains "$consumers_line" '/ui/vault/auth/oidc/oidc/callback' "CONSUMERS registers the same UI callback path"

echo
echo "== contract: oidc.tf ignores the fields the reconcile rotates (design facts 6, 8) =="
# Anchored to an active `ignore_changes = [...]` line, same reasoning as the
# UI-callback guard above: a plain substring match is satisfied by a comment
# that only mentions the field names, which is exactly how #2011's regression
# shape (an inert-looking line) would slip past this guard.
if grep -qE '^[[:space:]]*ignore_changes[[:space:]]*=[[:space:]]*\[oidc_client_id,[[:space:]]*oidc_client_secret\][[:space:]]*$' "$OIDC_TF_SRC"; then
    backend_ignore=yes
else
    backend_ignore=no
fi
check "vault_jwt_auth_backend.oidc ignores oidc_client_id and oidc_client_secret" "yes" "$backend_ignore"

if grep -qE '^[[:space:]]*ignore_changes[[:space:]]*=[[:space:]]*\[bound_audiences\][[:space:]]*$' "$OIDC_TF_SRC"; then
    role_ignore=yes
else
    role_ignore=no
fi
check "vault_jwt_auth_backend_role.oidc_default ignores bound_audiences" "yes" "$role_ignore"

# ── stubs ───────────────────────────────────────────────────────────────────
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
REAL_JQ="$(command -v jq)"
# The harness's own jq, which bypasses the argv-logging wrapper below.
rjq() { "$REAL_JQ" "$@"; }
STUB_BIN="$WORK/bin"
mkdir -p "$STUB_BIN"
export REAL_JQ CURL_LOG="$WORK/curl.log" CURL_STATE="$WORK/bao" \
       JQ_ARGV_LOG="$WORK/jq-argv.log" SLEEP_LOG="$WORK/sleep.log"

# Logs argv, the -K file's mode and contents AT CALL TIME (the caller's trap
# removes it right after) and the request body; then answers from $CURL_STATE.
cat > "$STUB_BIN/curl" <<'EOF'
#!/usr/bin/env bash
args=("$@") method=GET url="" kfile="" has_body=no with_body=no
for ((i = 0; i < ${#args[@]}; i++)); do
    case "${args[$i]}" in
        -X) method="${args[$((i + 1))]}" ;;
        -K) kfile="${args[$((i + 1))]}" ;;
        @-) has_body=yes ;;
        --fail-with-body) with_body=yes ;;
        http://*|https://*) url="${args[$i]}" ;;
    esac
done
path="${url#*/v1/}"
st="$CURL_STATE"
mkdir -p "$st"
n=$(( $(cat "$st/n" 2>/dev/null || echo 0) + 1 ))
echo "$n" > "$st/n"
body="$st/body.$n"
: > "$body"
[ "$has_body" = yes ] && cat > "$body"
{
    printf 'CALL:'; printf ' %q' "$@"; printf '\n'
    printf 'REQ: %s %s %s\n' "$n" "$method" "$path"
    if [ -n "$kfile" ]; then
        printf 'KFILE_MODE:%s\n' "$(stat -c '%a' "$kfile" 2>/dev/null)"
        printf 'KFILE_CONTENTS:\n'; cat "$kfile" 2>/dev/null; printf 'KFILE_CONTENTS_END:\n'
    fi
    if [ "$has_body" = yes ]; then printf 'STDIN:\n'; cat "$body"; printf '\nSTDIN_END:\n'; fi
} >> "$CURL_LOG"

# fail.<METHOD>_<path>.count answers that many calls with curl's exit 22. The
# error body reaches stdout only under --fail-with-body, as with the real curl:
# plain -f discards it.
fkey="$st/fail.${method}_${path//\//_}"
if [ -s "$fkey.count" ] && [ "$(cat "$fkey.count")" -gt 0 ]; then
    echo $(( $(cat "$fkey.count") - 1 )) > "$fkey.count"
    [ "$with_body" = yes ] && cat "$fkey.body" 2>/dev/null
    echo "curl: (22) The requested URL returned error: 400" >&2
    exit 22
fi

case "$method $path" in
    "GET sys/auth")               cat "$st/sys_auth.json" 2>/dev/null || echo '{"data":{}}' ;;
    "GET auth/oidc/config")       "$REAL_JQ" -c '{data: (del(.oidc_client_secret) + {status: "valid"})}' "$st/config.json" ;;
    "GET auth/oidc/role/default") "$REAL_JQ" -c '{data: .}' "$st/role.json" ;;
    "POST auth/oidc/config")      [ -e "$st/ignore_writes" ] || cp "$body" "$st/config.json" ;;
    # OpenBao v2.6.2 path_role.go: omitting any of these four resets it.
    "POST auth/oidc/role/default")
        if [ ! -e "$st/ignore_writes" ]; then
            "$REAL_JQ" -s '.[0] + {role_type: "oidc", bound_claims_type: "string", callback_mode: "client",
                                  oidc_disable_confirmation: false} + .[1]' \
                "$st/role.json" "$body" > "$st/role.new" && mv "$st/role.new" "$st/role.json"
        fi ;;
esac
exit 0
EOF

cat > "$STUB_BIN/jq" <<'EOF'
#!/usr/bin/env bash
{ printf 'JQ:'; printf ' %q' "$@"; printf '\n'; } >> "$JQ_ARGV_LOG"
exec "$REAL_JQ" "$@"
EOF

# Returns at once and records what it was asked to wait, so a retry is fast
# AND its delay is observable.
cat > "$STUB_BIN/sleep" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$SLEEP_LOG"
EOF
chmod +x "$STUB_BIN/curl" "$STUB_BIN/jq" "$STUB_BIN/sleep"
PATH="$STUB_BIN:$PATH"

reset_curl_log() { : > "$CURL_LOG"; rm -rf "$CURL_STATE"; mkdir -p "$CURL_STATE"; }
calls() { grep '^CALL:' "$CURL_LOG"; }

# TLS is verified on every call: no -k, alone or inside a flag cluster.
tls_verified() { # label, call lines
    if grep -qE -- '(^| )(-[A-Za-z]*k[A-Za-z]*|--insecure)( |$)' <<< "$2"; then
        printf '  FAIL %s: an insecure flag in %s\n' "$1" "$2"; fail=1
    else
        printf '  ok   %s\n' "$1"
    fi
}

# ── library: scripts/lib/openbao-api.sh ─────────────────────────────────────
echo
echo "== library: openbao_token_config_write / openbao_req =="

LIB_SRC="${OPENBAO_API_LIB:-$HERE/../../lib/openbao-api.sh}"
[ -f "$LIB_SRC" ] || { echo "  FAIL $LIB_SRC does not exist" >&2; exit 1; }
# shellcheck source=scripts/lib/openbao-api.sh
. "$LIB_SRC"

# store_read stubbed directly: this section proves openbao_token_config_write's
# own contract, not cloud-secret-store.sh's CLOUD dispatch (covered by
# test-cloud-secret-store.sh).
STUB_STORE_VALUE=""
STUB_STORE_RC=0
store_read() { printf '%s' "$STUB_STORE_VALUE"; return "$STUB_STORE_RC"; }

echo "-- openbao_token_config_write --"

TOKEN_FILE="$(umask 077 && mktemp)"

STUB_STORE_VALUE='{"token":"s3cr3t-token"}'
openbao_token_config_write "$TOKEN_FILE" any-secret
rc=$?
check "returns 0 on a real token"       "0" "$rc"
check "writes the X-Vault-Token header" 'header = "X-Vault-Token: s3cr3t-token"' "$(cat "$TOKEN_FILE")"
check "token file mode stays 600"       "600" "$(stat -c '%a' "$TOKEN_FILE")"

: > "$TOKEN_FILE"
STUB_STORE_VALUE='{"root_token":"legacy-shape"}'
openbao_token_config_write "$TOKEN_FILE" any-secret
check "falls back to .root_token" 'header = "X-Vault-Token: legacy-shape"' "$(cat "$TOKEN_FILE")"

printf 'sentinel-untouched' > "$TOKEN_FILE"
STUB_STORE_VALUE=""
openbao_token_config_write "$TOKEN_FILE" any-secret
rc=$?
check "empty store value returns 1"          "1" "$rc"
check "empty store value leaves file untouched" "sentinel-untouched" "$(cat "$TOKEN_FILE")"

printf 'sentinel-untouched' > "$TOKEN_FILE"
STUB_STORE_VALUE='{"token":""}'
openbao_token_config_write "$TOKEN_FILE" any-secret
rc=$?
check "empty .token field returns 1"           "1" "$rc"
check "empty .token field leaves file untouched" "sentinel-untouched" "$(cat "$TOKEN_FILE")"

: > "$TOKEN_FILE"
STUB_STORE_VALUE='{"token":"has\"quote\\and\\backslash"}'
openbao_token_config_write "$TOKEN_FILE" any-secret
check "escapes quote and backslash" 'header = "X-Vault-Token: has\"quote\\and\\backslash"' "$(cat "$TOKEN_FILE")"

# "Returns 1" must hold for a caller under `set -e` too. There a failing
# assignment aborts the function with ITS status instead: store_read's 3, or
# jq's 5 on a value that is not JSON.
printf 'sentinel-untouched' > "$TOKEN_FILE"
STUB_STORE_VALUE='{"token":"from-a-failed-read"}'; STUB_STORE_RC=3
( set -e; openbao_token_config_write "$TOKEN_FILE" any-secret )
rc=$?
check "set -e, store_read fails: returns 1, not store_read's 3" "1" "$rc"
check "set -e, store_read fails: file untouched" "sentinel-untouched" "$(cat "$TOKEN_FILE")"
STUB_STORE_RC=0
STUB_STORE_VALUE='not json'
( set -e; openbao_token_config_write "$TOKEN_FILE" any-secret )
rc=$?
check "set -e, unparseable value: returns 1, not jq's 5" "1" "$rc"

# A caller running under `bash -x` must not trace the token into its log, and
# must get its xtrace back afterwards (`local -`, not a bare `set +x`).
: > "$TOKEN_FILE"
STUB_STORE_VALUE='{"token":"XTRACE-SENTINEL-5d2"}'
xtrace_out="$( { set -x; openbao_token_config_write "$TOKEN_FILE" any-secret
                 [[ $- == *x* ]] && echo XTRACE-STILL-ON >&2; } 2>&1 )"
absent   "$xtrace_out" "XTRACE-SENTINEL" "xtrace never shows the token"
contains "$xtrace_out" "XTRACE-STILL-ON" "the caller's xtrace is back on after the call"
check "still writes the header under xtrace" 'header = "X-Vault-Token: XTRACE-SENTINEL-5d2"' "$(cat "$TOKEN_FILE")"

echo
echo "-- openbao_req --"
reset_curl_log
OPENBAO_URL="https://bao.example.invalid:8200"
OPENBAO_CA_FILE="/tmp/ca.pem"
STUB_STORE_VALUE='{"token":"s3cr3t-token"}'
openbao_token_config_write "$TOKEN_FILE" any-secret
OPENBAO_TOKEN_CONFIG="$TOKEN_FILE"

openbao_req GET sys/auth >/dev/null
call_line="$(calls)"
contains "$call_line" '--cacert /tmp/ca.pem'          "curl receives --cacert"
contains "$call_line" "-K ${TOKEN_FILE}"               "curl receives -K"
contains "$call_line" '-X GET'                         "curl receives -X <method>"
contains "$call_line" "${OPENBAO_URL}/v1/sys/auth"     "curl receives the full URL"
# The body of a 400 is how the reconcile tells a discovery error, worth a
# retry, from any other. Plain -f discards it.
contains "$call_line" '--fail-with-body'               "curl keeps the body of an HTTP error"
tls_verified "GET: curl never uses -k" "$call_line"
absent "$call_line" "s3cr3t-token" "GET: the token appears in no argv"
kfile_contents="$(sed -n '/^KFILE_CONTENTS:/,/^KFILE_CONTENTS_END:/p' "$CURL_LOG" | sed '1d;$d')"
check "the -K file held the header at call time" 'header = "X-Vault-Token: s3cr3t-token"' "$kfile_contents"
kfile_mode="$(grep '^KFILE_MODE:' "$CURL_LOG" | head -1 | cut -d: -f2)"
check "the -K file was mode 600 at call time" "600" "$kfile_mode"

reset_curl_log
openbao_req POST some/path --data-binary @- <<< '{"probe":"body-reached-stdin"}' >/dev/null
call_line="$(calls)"
contains "$call_line" '-X POST'                       "extra args forwarded: -X POST"
contains "$call_line" "${OPENBAO_URL}/v1/some/path"   "extra args forwarded: path"
contains "$call_line" '--data-binary @-'              "extra args forwarded verbatim"
check "the POST body reached curl's stdin" '{"probe":"body-reached-stdin"}' \
    "$(sed -n '/^STDIN:/,/^STDIN_END:/p' "$CURL_LOG" | sed '1d;$d')"
tls_verified "POST: curl never uses -k" "$call_line"
absent "$call_line" "s3cr3t-token" "POST: the token appears in no argv"

rm -f "$TOKEN_FILE"
unset OPENBAO_TOKEN_CONFIG

echo
echo "-- printf is the builtin --"
# The token file is written with printf, and the builtin never execs, so the
# token never reaches an argv. A path, `command` or `env` in front of it would
# run /usr/bin/printf with the token as an argument -- and every behavioural
# test above would still pass, since the file comes out the same.
printf_not_builtin() { # file -> the code lines that reach printf some other way
    grep -nE '(/[[:alnum:]_./-]*printf|\bcommand[[:space:]]+(-[[:alpha:]]+[[:space:]]+)*printf|\benv([[:space:]]+[^[:space:]]+)*[[:space:]]+printf)\b' "$1" \
        | grep -vE '^[0-9]+:[[:space:]]*#' || true
}
check "openbao-api.sh calls printf only as the builtin" "" "$(printf_not_builtin "$LIB_SRC")"
for mutation in '/usr/bin/printf' 'command printf' 'env printf'; do
    sed "s#^\\([[:space:]]*\\)printf 'header#\\1${mutation} 'header#" "$LIB_SRC" > "$WORK/lib-mutant.sh"
    if [ -n "$(printf_not_builtin "$WORK/lib-mutant.sh")" ]; then
        printf '  ok   the check catches "%s"\n' "$mutation"
    else
        printf '  FAIL the check misses "%s"\n' "$mutation"; fail=1
    fi
done

# ── the reconcile: zitadel-oidc-clients.sh ──────────────────────────────────
echo
echo "== reconcile: openbao_oidc_config_payload / reconcile_openbao_oidc =="

# Lifted verbatim, as the other test-zitadel-* suites do: the script parses
# argv at the top and is not sourceable. A missing function becomes a stub
# returning 127, so each case below still runs and reports its own failure.
for f in openbao_oidc_config_payload reconcile_openbao_oidc; do
    body="$(sed -n "/^${f}() {/,/^}/p" "$CONSUMERS_SRC")"
    if [ -n "$body" ]; then
        eval "$body"
        printf '%s\n' "$body" >> "$WORK/lifted.sh"
    else
        echo "  FAIL could not extract ${f}() from $CONSUMERS_SRC"; fail=1
        eval "${f}() { return 127; }"
    fi
done
# The reconcile pipes the payload, and with it the secret, through printf.
check "the reconcile calls printf only as the builtin" "" "$(printf_not_builtin "$WORK/lifted.sh")"

# The store, file-backed: the reconcile runs in a subshell, so an in-memory
# stub could not count reads across the retry. <key>.stale_reads makes the
# next N reads return <key>.stale, Secrets Manager's eventual consistency.
STORE="$WORK/store"
store_file()   { printf '%s/%s' "$STORE" "${1//\//_}"; }
store_exists() { printf 'exists %s\n' "$1" >> "$STORE/calls.log"; [ -f "$(store_file "$1")" ]; }
store_read() {
    local f n
    f="$(store_file "$1")"
    printf 'read %s\n' "$1" >> "$STORE/calls.log"
    n="$(cat "$f.stale_reads" 2>/dev/null || echo 0)"
    if [ "$n" -gt 0 ]; then
        echo $((n - 1)) > "$f.stale_reads"
        cat "$f.stale"
        return 0
    fi
    cat "$f" 2>/dev/null
}
store_put() { printf '%s' "$2" > "$(store_file "$1")"; }

IDP="https://auth.cloud.ogenki.io"
OLD_ID="111111111111111111"
NEW_ID="222222222222222222"
# Both %q-stable, so an argv grep cannot miss an escaped copy.
CS="CS-SENTINEL-4b1d"
ROOT="ROOT-TOKEN-SENTINEL-9e7c"
KEY="openbao-oidc"
BAO_URL="https://bao.priv.aws.ogenki.io:8200"
OPENBAO_URL="$BAO_URL"
OPENBAO_CA_FILE="$WORK/ca.pem"
OPENBAO_ROOT_TOKEN_SECRET="openbao/cloud-native-ref/tokens/root"  # pragma: allowlist secret
OPENBAO_RETRY_SLEEP=0
OPENBAO_DISCOVERY_RETRY_SLEEP=0

# What Terraform leaves in auth/oidc/config, as stored (a read hides the secret).
BAO_CONFIG="$(rjq -cn --arg iss "$IDP" --arg id "$OLD_ID" --arg prev "OLD-SECRET" '{
    oidc_discovery_url: $iss, oidc_discovery_ca_pem: "", oidc_client_id: $id,
    oidc_client_secret: $prev, default_role: "default", bound_issuer: $iss,
    namespace_in_state: true, provider_config: {}, jwks_url: "", jwks_ca_pem: "",
    jwt_validation_pubkeys: [], jwt_supported_algs: [], oidc_response_mode: "",
    oidc_response_types: [], override_allowed_server_names: []}')"

# The rebuild: ZITADEL issued NEW_ID and the store holds it. $1 and $2 are the
# ids OpenBao's config and role still hold (default OLD_ID).
world() {
    rm -rf "$CURL_STATE" "$STORE"
    mkdir -p "$CURL_STATE" "$STORE"
    : > "$CURL_LOG"; : > "$JQ_ARGV_LOG"; : > "$SLEEP_LOG"; : > "$STORE/calls.log"
    echo '{"data":{"oidc/":{"type":"oidc"},"token/":{"type":"token"}}}' > "$CURL_STATE/sys_auth.json"
    rjq -c --arg id "${1:-$OLD_ID}" '.oidc_client_id = $id' <<< "$BAO_CONFIG" > "$CURL_STATE/config.json"
    rjq -cn --arg id "${2:-$OLD_ID}" --arg cb "$BAO_URL/ui/vault/auth/oidc/oidc/callback" '{
        role_type: "oidc", bound_audiences: [$id], user_claim: "email", groups_claim: "groups",
        bound_claims_type: "string", callback_mode: "client", oidc_disable_confirmation: false,
        oidc_scopes: ["profile","email","groups"], token_ttl: 3600,
        allowed_redirect_uris: [$cb, "http://localhost:8250/oidc/callback"]}' > "$CURL_STATE/role.json"
    store_put "$KEY" "$(printf '{"client_id":"%s","client_secret":"%s","endpoint":"%s"}' "$NEW_ID" "$CS" "$IDP")"
    store_put "$OPENBAO_ROOT_TOKEN_SECRET" "{\"token\":\"$ROOT\"}"
    APPLY=true
}
fail_next() { # METHOD path count [error body]
    local k="$CURL_STATE/fail.${1}_${2//\//_}" body='{"errors":["permission denied"]}'
    [ $# -ge 4 ] && body="$4"
    echo "$3" > "$k.count"
    printf '%s' "$body" > "$k.body"
}
# Exactly what the server sends: no detail after the message.
DISCOVERY_ERROR='{"errors":["error checking oidc discovery URL"]}'
recon() { out="$(reconcile_openbao_oidc "$@" 2>&1)"; rc=$?; }
reqs()      { awk '$1 == "REQ:" { print $3 " " $4 }' "$CURL_LOG"; }
posts()     { reqs | grep '^POST' || true; }
n_req()     { reqs | grep -cxF -- "$1" || true; }
last_body() { # "METHOD path" -> the body of the last such call
    local n
    n="$(awk -v want="$1" '$1 == "REQ:" && ($3 " " $4) == want { n = $2 } END { print n }' "$CURL_LOG")"
    [ -n "$n" ] && cat "$CURL_STATE/body.$n"
}
sleeps()    { paste -sd' ' "$SLEEP_LOG"; }
n_reads()   { grep -cx "read $KEY" "$STORE/calls.log" || true; }
POST_CFG="POST auth/oidc/config"
POST_ROLE="POST auth/oidc/role/default"

echo "-- openbao_oidc_config_payload --"
tricky='TRICKY-SENTINEL"quote\back`tick'
cfg_in='{"oidc_discovery_url":"https://idp","oidc_client_id":"old","default_role":"default","namespace_in_state":true,"bound_issuer":"https://idp","provider_config":{},"status":"valid"}'
store_in="$(printf '%s' "$tricky" | rjq -Rsc '{client_id: "new", client_secret: ., endpoint: "https://idp"}')"
: > "$JQ_ARGV_LOG"
payload="$(printf '%s\n%s\n' "$cfg_in" "$store_in" | openbao_oidc_config_payload)"
rc=$?
check "returns 0"                        "0" "$rc"
check "carries the new id"               "new" "$(rjq -r '.oidc_client_id' <<< "$payload")"
check "carries the secret, byte for byte" "$tricky" "$(rjq -r '.oidc_client_secret' <<< "$payload")"
check "drops status"                     "false" "$(rjq 'has("status")' <<< "$payload")"
check "keeps every other field" \
    "$(rjq -cS 'del(.status) + {oidc_client_id: "new"}' <<< "$cfg_in")" \
    "$(rjq -cS 'del(.oidc_client_secret)' <<< "$payload")"
absent "$(cat "$JQ_ARGV_LOG")" "TRICKY-SENTINEL" "the secret reaches jq on stdin, never argv"

payload="$(printf '%s\n%s\n' "$(rjq -c '.provider_config = {provider: "gsuite"}' <<< "$cfg_in")" "$store_in" \
           | openbao_oidc_config_payload 2>/dev/null)"
rc=$?
check "a non-empty provider_config: returns 1" "1" "$rc"
check "a non-empty provider_config: emits nothing" "" "$payload"
err="$(printf '%s\n%s\n' "$(rjq -c '.provider_config = {provider: "gsuite"}' <<< "$cfg_in")" "$store_in" \
       | openbao_oidc_config_payload 2>&1 >/dev/null)"
contains "$err" "[FAILED ]" "a non-empty provider_config: says [FAILED ]"

payload="$(printf '%s\n%s\n' "$(rjq -c 'del(.provider_config)' <<< "$cfg_in")" "$store_in" | openbao_oidc_config_payload)"
check "no provider_config at all: merges" "new" "$(rjq -r '.oidc_client_id' <<< "$payload" 2>/dev/null)"

payload="$(printf '%s\n%s\n' "$cfg_in" '{"client_id":"new","client_secret":""}' | openbao_oidc_config_payload 2>/dev/null)"
rc=$?
check "an empty secret: returns 1, so no config is written without one" "1" "$rc"
err="$(printf '%s\n%s\n' "$cfg_in" '{"client_id":"new","client_secret":""}' | openbao_oidc_config_payload 2>&1 >/dev/null)"
contains "$err" "[FAILED ]" "an empty secret: says [FAILED ]"

echo
echo "-- no-op paths --"
world; OPENBAO_URL=""; recon "$KEY" "$NEW_ID"; OPENBAO_URL="$BAO_URL"
check "no URL: returns 0"          "0" "$rc"
check "no URL: says nothing"       ""  "$out"
check "no URL: no OpenBao call"    ""  "$(reqs)"
check "no URL: no store call"      ""  "$(cat "$STORE/calls.log")"

# A dry run of a create has no client id yet. Under --apply the loop always
# yields one, so a missing one is a wiring bug, and must not pass as a skip.
world; APPLY=false; recon "" "$NEW_ID"
check "dry run, no store key: returns 0"       "0" "$rc"
contains "$out" "[skip   ]"                    "dry run, no store key: says [skip   ]"
check "dry run, no store key: no OpenBao call" ""  "$(reqs)"
world; APPLY=false; recon "$KEY" ""
check "dry run, no client id: returns 0"       "0" "$rc"
contains "$out" "[skip   ]"                    "dry run, no client id: says [skip   ]"
check "dry run, no client id: no OpenBao call" ""  "$(reqs)"
world; recon "$KEY" ""
check "apply, no client id: returns 1"         "1" "$rc"
contains "$out" "[FAILED ]"                    "apply, no client id: says [FAILED ]"
check "apply, no client id: no OpenBao call"   ""  "$(reqs)"
world; recon "" "$NEW_ID"
check "apply, no store key: returns 1"         "1" "$rc"
contains "$out" "[FAILED ]"                    "apply, no store key: says [FAILED ]"

world; rm -f "$(store_file "$KEY")"; recon "$KEY" "$NEW_ID"
check "key not in the store: returns 0"       "0" "$rc"
contains "$out" "[skip   ]"                   "key not in the store: says [skip   ]"
check "key not in the store: no OpenBao call" ""  "$(reqs)"

world; echo '{"data":{"token/":{"type":"token"}}}' > "$CURL_STATE/sys_auth.json"; recon "$KEY" "$NEW_ID"
check "no oidc/ mount: returns 0"                 "0" "$rc"
contains "$out" "[skip   ]"                       "no oidc/ mount: says [skip   ]"
contains "$out" "opentofu/aws/openbao/management" "no oidc/ mount: names the management apply"
check "no oidc/ mount: only lists the mounts"     "GET sys/auth" "$(reqs)"

# A 200 that is not a mount map says nothing about the mount. Reading it as "no
# oidc/" would report a stale client as a first bootstrap.
for resp in "" "null" "{}"; do
    world; printf '%s' "$resp" > "$CURL_STATE/sys_auth.json"; recon "$KEY" "$NEW_ID"
    label="sys/auth answers ${resp:-an empty body}"
    check "${label}: returns 1"            "1" "$rc"
    contains "$out" "[FAILED ]"            "${label}: says [FAILED ]"
    absent "$out" "[skip   ]"              "${label}: never says [skip   ]"
    check "${label}: no write"             ""  "$(posts)"
done

echo
echo "-- idempotency --"
world "$NEW_ID" "$NEW_ID"; recon "$KEY" "$NEW_ID"
check "converged: returns 0"   "0" "$rc"
contains "$out" "[ok     ]"    "converged: says [ok     ]"
check "converged: zero POSTs"  ""  "$(posts)"
check "converged: three reads" "GET sys/auth
GET auth/oidc/config
GET auth/oidc/role/default" "$(reqs)"

echo
echo "-- dry run --"
world; APPLY=false; recon "$KEY" "$NEW_ID"
check "dry run: returns 0"  "0" "$rc"
check "dry run: zero POSTs" ""  "$(posts)"
contains "$out" "[dry-run]"                           "dry run: says [dry-run]"
contains "$out" "auth/oidc/config"                    "dry run: reports the config"
contains "$out" "$OLD_ID -> $NEW_ID"                  "dry run: reports the id change"
contains "$out" "auth/oidc/role/default"              "dry run: reports the role"
contains "$out" "[\"$OLD_ID\"] -> [\"$NEW_ID\"]"      "dry run: reports the audience change"

# A dry run wrote nothing to the store, so there is nothing to wait for.
world; APPLY=false
store_put "$KEY" "$(printf '{"client_id":"%s","client_secret":"%s"}' "$OLD_ID" "$CS")"
recon "$KEY" "$NEW_ID"
check "dry run, stale store: returns 0"     "0" "$rc"
check "dry run, stale store: one read"      "1" "$(n_reads)"
check "dry run, stale store: never sleeps"  ""  "$(sleeps)"
check "dry run, stale store: zero POSTs"    ""  "$(posts)"
contains "$out" "[dry-run]"                 "dry run, stale store: reports it"

echo
echo "-- apply: the exact POST bodies --"
world; recon "$KEY" "$NEW_ID"
check "apply: returns 0"                "0" "$rc"
contains "$out" "[reconciled]"          "apply: says [reconciled]"
check "apply: the config, then the role" "$POST_CFG
$POST_ROLE" "$(posts)"
cfg_body="$(last_body "$POST_CFG")"
check "config: the new id"              "$NEW_ID"   "$(rjq -r '.oidc_client_id' <<< "$cfg_body")"
check "config: the new secret"          "$CS"       "$(rjq -r '.oidc_client_secret' <<< "$cfg_body")"
check "config: keeps default_role"      "default"   "$(rjq -r '.default_role' <<< "$cfg_body")"
check "config: keeps the discovery URL" "$IDP"      "$(rjq -r '.oidc_discovery_url' <<< "$cfg_body")"
check "config: keeps namespace_in_state" "true"     "$(rjq -r '.namespace_in_state' <<< "$cfg_body")"
check "config: keeps bound_issuer"      "$IDP"      "$(rjq -r '.bound_issuer' <<< "$cfg_body")"
check "config: drops status"            "false"     "$(rjq 'has("status")' <<< "$cfg_body")"
check "config: never skips JWKS validation" "false" "$(rjq 'has("skip_jwks_validation")' <<< "$cfg_body")"
check "config: the whole object, nothing else dropped or added" \
    "$(rjq -cS --arg id "$NEW_ID" --arg cs "$CS" '.oidc_client_id = $id | .oidc_client_secret = $cs' <<< "$BAO_CONFIG")" \
    "$(rjq -cS . <<< "$cfg_body")"
check "role: partial, role_type and bound_audiences only" \
    "{\"bound_audiences\":[\"$NEW_ID\"],\"role_type\":\"oidc\"}" \
    "$(rjq -cS . <<< "$(last_body "$POST_ROLE")")"

echo
echo "-- the secret and the token are on no argv --"
absent "$(calls)"              "$CS"   "curl's argv never carries the client secret"
absent "$(calls)"              "$ROOT" "curl's argv never carries the root token"
absent "$(cat "$JQ_ARGV_LOG")" "$CS"   "jq's argv never carries the client secret"
absent "$(cat "$JQ_ARGV_LOG")" "$ROOT" "jq's argv never carries the root token"
tls_verified "every reconcile call verifies TLS" "$(calls)"
contains "$(calls)" "--cacert $OPENBAO_CA_FILE" "every reconcile call passes --cacert"
world
xtrace_out="$( { set -x; reconcile_openbao_oidc "$KEY" "$NEW_ID"; } 2>&1 >/dev/null )"
check "xtrace was on for this case, so the next two are not vacuous" "no" "$([ -z "$xtrace_out" ] && echo yes || echo no)"
absent "$xtrace_out" "$CS"   "under xtrace, the client secret is never traced"
absent "$xtrace_out" "$ROOT" "under xtrace, the root token is never traced"

echo
echo "-- independent writes --"
world "$OLD_ID" "$NEW_ID"; recon "$KEY" "$NEW_ID"
check "only the config stale: returns 0"        "0" "$rc"
check "only the config stale: only the config"  "$POST_CFG" "$(posts)"
world "$NEW_ID" "$OLD_ID"; recon "$KEY" "$NEW_ID"
check "only the role stale: returns 0"          "0" "$rc"
check "only the role stale: only the role"      "$POST_ROLE" "$(posts)"

echo
echo "-- a failed config write leaves the role alone --"
world; fail_next POST auth/oidc/config 1; recon "$KEY" "$NEW_ID"
check "config write refused: returns 1"         "1" "$rc"
contains "$out" "[FAILED ]"                     "config write refused: says [FAILED ]"
check "config write refused: not retried"       "1" "$(n_req "$POST_CFG")"
check "config write refused: no role write"     "0" "$(n_req "$POST_ROLE")"

world; fail_next POST auth/oidc/config 7 "$DISCOVERY_ERROR"; recon "$KEY" "$NEW_ID"
check "discovery never answers: returns 1"          "1" "$rc"
check "discovery never answers: 1 try + 6 retries"  "7" "$(n_req "$POST_CFG")"
check "discovery never answers: no role write"      "0" "$(n_req "$POST_ROLE")"
check "discovery never answers: 6 waits of \$OPENBAO_DISCOVERY_RETRY_SLEEP" "0 0 0 0 0 0" "$(sleeps)"

echo
echo "-- the discovery retry --"
world; fail_next POST auth/oidc/config 3 "$DISCOVERY_ERROR"; recon "$KEY" "$NEW_ID"
check "discovery answers on the 4th try: returns 0"  "0" "$rc"
check "discovery answers on the 4th try: 4 writes"   "4" "$(n_req "$POST_CFG")"
check "discovery answers on the 4th try: the role"   "1" "$(n_req "$POST_ROLE")"
check "discovery answers on the 4th try: 3 waits"    "0 0 0" "$(sleeps)"
world; fail_next POST auth/oidc/config 1 "$DISCOVERY_ERROR"
unset OPENBAO_DISCOVERY_RETRY_SLEEP; recon "$KEY" "$NEW_ID"; OPENBAO_DISCOVERY_RETRY_SLEEP=0
check "the discovery wait defaults to 10s"           "10" "$(sleeps)"

echo
echo "-- the store-agreement retry --"
world
printf '{"client_id":"%s","client_secret":"%s"}' "$OLD_ID" "OLD-SECRET" > "$(store_file "$KEY").stale"
echo 2 > "$(store_file "$KEY").stale_reads"
recon "$KEY" "$NEW_ID"
check "store agrees on the 3rd read: returns 0"      "0" "$rc"
check "store agrees on the 3rd read: 3 reads"        "3" "$(n_reads)"
check "store agrees on the 3rd read: 2 waits"        "0 0" "$(sleeps)"
check "store agrees on the 3rd read: writes the new secret" "$CS" "$(rjq -r '.oidc_client_secret' <<< "$(last_body "$POST_CFG")")"

world
printf '{"client_id":"%s","client_secret":"%s"}' "$OLD_ID" "OLD-SECRET" > "$(store_file "$KEY").stale"
echo 99 > "$(store_file "$KEY").stale_reads"
recon "$KEY" "$NEW_ID"
check "store never agrees: returns 1"               "1" "$rc"
contains "$out" "[FAILED ]"                         "store never agrees: says [FAILED ]"
check "store never agrees: 1 read + 6 retries"      "7" "$(n_reads)"
check "store never agrees: no OpenBao call"         ""  "$(reqs)"

world
printf '{"client_id":"%s","client_secret":"%s"}' "$OLD_ID" "OLD-SECRET" > "$(store_file "$KEY").stale"
echo 1 > "$(store_file "$KEY").stale_reads"
unset OPENBAO_RETRY_SLEEP; recon "$KEY" "$NEW_ID"; OPENBAO_RETRY_SLEEP=0
check "the store wait defaults to 5s"               "5" "$(sleeps)"

echo
echo "-- the caller's EXIT trap, and the token file --"
world
( trap 'echo caller-trap-ran > "$WORK/trap-mark"' EXIT
  reconcile_openbao_oidc "$KEY" "$NEW_ID" >/dev/null 2>&1
  trap -p EXIT > "$WORK/trap-after" )
contains "$(cat "$WORK/trap-after")" "caller-trap-ran" "the caller's EXIT trap is still set after the call"
check "the caller's EXIT trap still fires" "caller-trap-ran" "$(cat "$WORK/trap-mark" 2>/dev/null)"
kpath="$(calls | grep -oE -- '-K [^ ]+' | head -1 | cut -d' ' -f2)"
check "a token file was used"                 "yes" "$([ -n "$kpath" ] && echo yes || echo no)"
check "the token file is removed afterwards"  "gone" "$([ -e "$kpath" ] && echo present || echo gone)"
check "the token file was mode 600 at every call" "600" "$(grep '^KFILE_MODE:' "$CURL_LOG" | cut -d: -f2 | sort -u)"
contains "$(cat "$CURL_LOG")" "header = \"X-Vault-Token: $ROOT\"" "the token file held the root token header"

world; fail_next GET auth/oidc/config 1; recon "$KEY" "$NEW_ID"
kpath="$(calls | grep -oE -- '-K [^ ]+' | head -1 | cut -d' ' -f2)"
check "after a failure too, the token file is removed" "gone" "$([ -e "$kpath" ] && echo present || echo gone)"

echo
echo "-- every read is checked, and a failed one writes nothing --"
world; rm -f "$(store_file "$OPENBAO_ROOT_TOKEN_SECRET")"; recon "$KEY" "$NEW_ID"
check "no root token: returns 1"        "1" "$rc"
check "no root token: no OpenBao call"  ""  "$(reqs)"
for req in "GET sys/auth" "GET auth/oidc/config" "GET auth/oidc/role/default"; do
    world; fail_next "${req% *}" "${req#* }" 1; recon "$KEY" "$NEW_ID"
    check "${req} fails: returns 1, not a skip" "1" "$rc"
    check "${req} fails: no write"              ""  "$(posts)"
done
world; echo 'not json' > "$CURL_STATE/role.json"; recon "$KEY" "$NEW_ID"
check "an unreadable role: returns 1"   "1" "$rc"
check "an unreadable role: no write"    ""  "$(posts)"
world; rjq -c '.provider_config = {provider: "gsuite"}' <<< "$BAO_CONFIG" > "$CURL_STATE/config.json"; recon "$KEY" "$NEW_ID"
check "a provider_config: returns 1"    "1" "$rc"
contains "$out" "[FAILED ]"             "a provider_config: says [FAILED ]"
check "a provider_config: no write"     ""  "$(posts)"

echo
echo "-- the role write, and the read-back --"
world; fail_next POST auth/oidc/role/default 1; recon "$KEY" "$NEW_ID"
check "role write refused: returns 1"   "1" "$rc"
contains "$out" "[FAILED ]"             "role write refused: says [FAILED ]"
check "role write refused: the config's [reconciled] line comes first" "yes" \
    "$(awk '/^\[reconciled\] openbao -- auth\/oidc\/config/ { c = NR }
            /^\[FAILED \] openbao -- auth\/oidc\/role/     { f = NR }
            END { print (c && f && c < f) ? "yes" : "no" }' <<< "$out")"
contains "$out" "config has already moved" "role write refused: says the config has already moved"
contains "$out" "sync --apply"          "role write refused: says re-running sync --apply finishes it"
world "$NEW_ID" "$OLD_ID"; fail_next POST auth/oidc/role/default 1; recon "$KEY" "$NEW_ID"
check "only the role, refused: returns 1" "1" "$rc"
absent "$out" "already moved"           "only the role, refused: claims no config move"
world; touch "$CURL_STATE/ignore_writes"; recon "$KEY" "$NEW_ID"
check "writes that do not stick: returns 1" "1" "$rc"
contains "$out" "[FAILED ]"             "writes that do not stick: says [FAILED ]"

# ── Task 3: the flags, and cmd_sync's wiring ─────────────────────────────────
#
# WHY A STUB reconcile_openbao_oidc HERE, RATHER THAN THE REAL ONE ABOVE. This
# section proves cmd_sync CALLS the reconcile with the right (key, id) pair and
# reacts to its exit status; the reconcile's own behaviour is every case above.
# Redefining the function is safe: nothing above re-runs after this point.
#
# WHY `out="$( ( set -o errexit ...; cmd_sync ) 2>&1 )"; rc=$?`, NEVER
# `(...) || true` (design fact 14, plan Global Constraints). Measured directly:
# a subshell that is the LEFT side of `||` has bash ignore its OWN `set -o
# errexit` for every command inside it, even though the subshell set it itself
# -- an undefined function inside then prints "command not found" and EXECUTION
# CONTINUES to the next line, instead of aborting. Capturing via `$( )` and
# reading `$?` afterward is not "tested with `||`" in that sense and preserves
# errexit correctly. Reproduced with a two-line repro before writing this.
echo
echo "== cmd_sync wiring: the reconcile runs once, after the loop (Task 3) =="

for f in cmd_sync oidc_config_payload; do
    body="$(sed -n "/^${f}() {/,/^}/p" "$CONSUMERS_SRC")"
    [ -n "$body" ] || { echo "  FAIL could not extract ${f}() from $CONSUMERS_SRC" >&2; fail=1; }
    eval "$body"
done

# Every OTHER thing cmd_sync calls, stubbed: this section is about the ONE new
# call, not a restatement of the redirect/convergence suites' own coverage.
ensure_project() { echo "proj-1"; }
ensure_project_role_assertion() { :; }
ensure_project_roles() { :; }
grant_admin_role() { :; }
reconcile_workforce_audience() { :; }
app_set_redirect() { :; }
merge_secret() { echo '{}'; }
converge_secret() { echo '{}'; }
store_exists() { return 0; }
store_read()   { echo '{}'; }
store_write()  { cat >/dev/null; }

RECONCILE_LOG="$WORK/reconcile-openbao-calls.log"
RECONCILE_RC=0
reconcile_openbao_oidc() {
    printf 'CALL %s %s\n' "$1" "$2" >> "$RECONCILE_LOG"
    return "$RECONCILE_RC"
}

# Read only by cmd_sync's eval'd body above -- the file-wide SC2034 disable
# at the top of this file already covers these.
CLUSTER="aws-0"; CLOUD="aws"; IDP_URL="https://auth.priv.aws.ogenki.io"
ZITADEL_PROJECT_NAME="platform"; GRANT_ADMIN=""
WIRE_CB="https://bao.priv.aws.ogenki.io:8200/ui/vault/auth/oidc/oidc/callback"

run_cmd_sync() {
    set +e
    out="$( ( set -o errexit -o nounset -o pipefail; cmd_sync ) 2>&1 )"
    rc=$?
}

echo "-- the existing-app path --"
: > "$RECONCILE_LOG"
CONSUMERS=("openbao|${WIRE_CB}|openbao-oidc")
app_id_by_name() { echo "app-1"; }
app_get() { jq -n --arg r "$WIRE_CB" --arg cid "existing-openbao-id" \
                  '{app: {oidcConfig: {redirectUris: [$r], clientId: $cid}}}'; }
APPLY=true
run_cmd_sync
check "existing-app path: cmd_sync succeeds"     "0" "$rc"
check "existing-app path: reconcile called once" "1" "$(wc -l < "$RECONCILE_LOG")"
check "existing-app path: called with (key, id)" "CALL openbao-oidc existing-openbao-id" \
    "$(cat "$RECONCILE_LOG")"

echo
echo "-- the create path --"
: > "$RECONCILE_LOG"
app_id_by_name() { echo ""; }
api_or_fail() { printf '{"clientId":"created-openbao-id","clientSecret":"created-secret"}'; }  # pragma: allowlist secret
APPLY=true
run_cmd_sync
check "create path: cmd_sync succeeds"     "0" "$rc"
check "create path: reconcile called once" "1" "$(wc -l < "$RECONCILE_LOG")"
check "create path: called with (key, id)" "CALL openbao-oidc created-openbao-id" \
    "$(cat "$RECONCILE_LOG")"

echo
echo "-- a reconcile failure exits 1, after the summary --"
: > "$RECONCILE_LOG"
RECONCILE_RC=1
app_id_by_name() { echo "app-1"; }
run_cmd_sync
check "reconcile fails: cmd_sync exits 1"        "1" "$rc"
contains "$out" "created: "                      "reconcile fails: the summary line still prints"
RECONCILE_RC=0

echo
echo "== flags: --openbao-url requires --openbao-root-token-secret and --openbao-ca-file =="
REAL_CA="$WORK/real-ca.pem"
: > "$REAL_CA"

out="$(timeout 10 bash "$CONSUMERS_SRC" sync --cluster wiretest --cloud aws \
    --openbao-url https://bao.invalid.example:8200 2>&1)"
rc=$?
check "neither flag given: exits 2" "2" "$rc"
contains "$out" "--openbao-root-token-secret" "neither flag given: names the missing flag"

out="$(timeout 10 bash "$CONSUMERS_SRC" sync --cluster wiretest --cloud aws \
    --openbao-url https://bao.invalid.example:8200 --openbao-ca-file "$REAL_CA" 2>&1)"
rc=$?
check "a URL without a token secret: exits 2" "2" "$rc"
contains "$out" "--openbao-root-token-secret" "a URL without a token secret: names it"

out="$(timeout 10 bash "$CONSUMERS_SRC" sync --cluster wiretest --cloud aws \
    --openbao-url https://bao.invalid.example:8200 \
    --openbao-root-token-secret openbao/cloud-native-ref/tokens/root 2>&1)"  # pragma: allowlist secret
rc=$?
check "a URL without a CA file flag: exits 2" "2" "$rc"
contains "$out" "--openbao-ca-file" "a URL without a CA file flag: names it"

out="$(timeout 10 bash "$CONSUMERS_SRC" sync --cluster wiretest --cloud aws \
    --openbao-url https://bao.invalid.example:8200 \
    --openbao-root-token-secret openbao/cloud-native-ref/tokens/root \
    --openbao-ca-file "$WORK/does-not-exist.pem" 2>&1)"  # pragma: allowlist secret
rc=$?
check "a CA file that does not exist: exits 2" "2" "$rc"
contains "$out" "--openbao-ca-file" "a CA file that does not exist: names it"

echo
if [ "$fail" -eq 0 ]; then echo "PASS"; else echo "==> failure(s) above"; fi
exit "$fail"
