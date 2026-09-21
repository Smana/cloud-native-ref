#!/usr/bin/env bash
#
# Contract guards and library tests for the OpenBao OIDC client rotation
# (#2045). This suite starts with scripts/lib/openbao-api.sh -- the curl
# helper that keeps OpenBao's root token off argv -- and the two contract
# guards that pin facts reconcile_openbao_oidc depends on but does not own.
# Task 2 extends this file with openbao_oidc_config_payload and
# reconcile_openbao_oidc itself.
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
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../../.." && pwd)"
fail=0
check() { if [ "$2" = "$3" ]; then printf '  ok   %s\n' "$1"
          else printf '  FAIL %s: expected %q got %q\n' "$1" "$2" "$3"; fail=1; fi }
contains() { if grep -qF -- "$2" <<< "$1"; then printf '  ok   %s\n' "$3"
             else printf '  FAIL %s: %q not found in %q\n' "$3" "$2" "$1"; fail=1; fi }

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
if grep -qF '${local.openbao_address}/ui/vault/auth/oidc/oidc/callback' "$OIDC_TF_SRC"; then
    callback_found=yes
else
    callback_found=no
fi
check "oidc.tf pins the UI callback path" "yes" "$callback_found"

# ── library: scripts/lib/openbao-api.sh ─────────────────────────────────────
echo
echo "== library: openbao_token_config_write / openbao_req =="

LIB_SRC="${OPENBAO_API_LIB:-$HERE/../../lib/openbao-api.sh}"
if [ ! -f "$LIB_SRC" ]; then
    echo "  FAIL library tests: $LIB_SRC does not exist yet" >&2
    fail=1
else
    # shellcheck source=scripts/lib/openbao-api.sh
    . "$LIB_SRC"

    # store_read stubbed directly, the same technique
    # test-zitadel-oidc-clients-redirects.sh uses for the identical function:
    # this suite is proving openbao_token_config_write's OWN contract, not
    # re-testing cloud-secret-store.sh's CLOUD dispatch (already covered by
    # test-cloud-secret-store.sh).
    STUB_STORE_VALUE=""
    store_read() { printf '%s' "$STUB_STORE_VALUE"; }

    # curl stub: logs every call (argv, plus the -K file's mode and contents
    # AT CALL TIME, since a caller's own trap may have already removed the
    # file by the time an assertion runs). Overridden as a shell FUNCTION --
    # the technique test-openbao-pki-verify.sh and
    # test-openbao-seal-status-tls.sh already use for this exact binary: it
    # shadows the command for every caller in THIS shell, with no PATH/tempdir
    # plumbing needed.
    CURL_LOG="$(mktemp)"
    reset_curl_log() { : > "$CURL_LOG"; }
    curl() {
        {
            printf 'CALL:'
            printf ' %q' "$@"
            printf '\n'
            local args=("$@") i kfile
            for ((i = 0; i < $#; i++)); do
                if [ "${args[$i]}" = "-K" ]; then
                    kfile="${args[$((i + 1))]}"
                    printf 'KFILE_MODE:%s\n' "$(stat -c '%a' "$kfile" 2>/dev/null)"
                    printf 'KFILE_CONTENTS:\n'
                    cat "$kfile" 2>/dev/null
                    printf 'KFILE_CONTENTS_END:\n'
                fi
            done
            # Only read stdin when a caller actually asked curl to (a request
            # body, e.g. --data-binary @-): blindly `cat`-ing stdin here would
            # hang whenever a call carries none.
            for a in "$@"; do
                if [ "$a" = "@-" ]; then
                    printf 'STDIN:\n'
                    cat
                    printf 'STDIN_END:\n'
                    break
                fi
            done
        } >> "$CURL_LOG"
        return "${STUB_CURL_RC:-0}"
    }
    calls() { grep '^CALL:' "$CURL_LOG"; }
    trap 'rm -f "$CURL_LOG"' EXIT

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
    case "$call_line" in
        *" -k"*|*"--insecure"*) echo "  FAIL curl never uses -k: found in $call_line" >&2; fail=1 ;;
        *)                      echo "  ok   curl never uses -k" ;;
    esac
    case "$call_line" in
        *"s3cr3t-token"*) echo "  FAIL the token appears on argv: $call_line" >&2; fail=1 ;;
        *)                echo "  ok   the token appears in no argv" ;;
    esac
    kfile_contents="$(sed -n '/^KFILE_CONTENTS:/,/^KFILE_CONTENTS_END:/p' "$CURL_LOG" | sed '1d;$d')"
    check "the -K file held the header at call time" 'header = "X-Vault-Token: s3cr3t-token"' "$kfile_contents"
    kfile_mode="$(grep '^KFILE_MODE:' "$CURL_LOG" | head -1 | cut -d: -f2)"
    check "the -K file was mode 600 at call time" "600" "$kfile_mode"

    reset_curl_log
    openbao_req POST some/path --data-binary @- <<< '{}' >/dev/null
    call_line="$(calls)"
    contains "$call_line" '-X POST'                       "extra args forwarded: -X POST"
    contains "$call_line" "${OPENBAO_URL}/v1/some/path"   "extra args forwarded: path"
    contains "$call_line" '--data-binary @-'              "extra args forwarded verbatim"

    rm -f "$TOKEN_FILE"
fi

echo
if [ "$fail" -eq 0 ]; then echo "PASS"; else echo "==> ${fail} failure(s)"; fi
exit "$fail"
