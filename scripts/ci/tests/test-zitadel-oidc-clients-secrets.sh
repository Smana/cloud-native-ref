#!/usr/bin/env bash
# shellcheck disable=SC2034
# (STORE_PROBE_ERR and HEADLAMP_OIDC_SCOPES are read by merge_secret's eval'd body.)
#
# Unit-tests zitadel-oidc-clients.sh's merge_secret -- specifically the round-2
# fix that took client_secret, the existing secret blob (--argjson base) and
# the headlamp-proxy cookie secret off jq's argv. $existing matters as much as
# the client secret here: for grafana it also carries the generated Grafana
# admin credentials, so leaking it the same way leaked those too.
#
# merge_secret is lifted verbatim with sed, like the sibling suites: an earlier
# restatement here had drifted from the script it claimed to test.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="${ZITADEL_OIDC_CLIENTS_SCRIPT:-$HERE/../../provision/zitadel-oidc-clients.sh}"
fail=0
check() { if [ "$2" = "$3" ]; then printf '  ok   %s\n' "$1"
          else printf '  FAIL %s: expected %q got %q\n' "$1" "$2" "$3"; fail=1; fi }

body="$(sed -n '/^merge_secret() {/,/^}/p' "$SRC")"
[ -n "$body" ] || { echo "could not extract merge_secret() from $SRC" >&2; exit 1; }
eval "$body"

# ── store stubs -- no cloud call, canned "existing" blob ───────────────────
# __NONE__ is absent, __THROTTLED__ a describe that failed, __UNREADABLE__ a
# describe that worked and a read that did not.
EXISTING_BLOB='{}'
store_probe() {
    STORE_PROBE_ERR=""
    case "$EXISTING_BLOB" in
        __NONE__) return 1 ;;
        __THROTTLED__) STORE_PROBE_ERR="An error occurred (ThrottlingException) when calling the DescribeSecret operation: Rate exceeded"; return 2 ;;
    esac
}
# Like the real one, false for "absent" and "cannot tell" alike.
store_exists() { store_probe "$1"; }
store_read() { [ "$EXISTING_BLOB" = __UNREADABLE__ ] && return 254; printf '%s' "$EXISTING_BLOB"; }

IDP_URL="https://auth.priv.aws.ogenki.io"
HEADLAMP_OIDC_SCOPES="openid,profile,email"

tricky_secret='we!rd"secret\1`with`backtick\and\\backslash'

# ── grafana: existing admin credentials must survive the merge untouched ───
EXISTING_BLOB='{"GF_SECURITY_ADMIN_USER":"admin","GF_SECURITY_ADMIN_PASSWORD":"correct-horse-battery-staple"}'  # pragma: allowlist secret
out="$(merge_secret grafana-envvars grafana client-abc "$tricky_secret")"
check "grafana: admin user preserved"     "admin" "$(jq -r '.GF_SECURITY_ADMIN_USER' <<< "$out")"
check "grafana: admin password preserved" "correct-horse-battery-staple" "$(jq -r '.GF_SECURITY_ADMIN_PASSWORD' <<< "$out")"
check "grafana: client id set"            "client-abc" "$(jq -r '.GF_AUTH_GENERIC_OAUTH_CLIENT_ID' <<< "$out")"
check "grafana: tricky client secret round-trips" "$tricky_secret" "$(jq -r '.GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET' <<< "$out")"

# ── headlamp: OIDC_* fields, issuer URL, no unrelated key dropped ──────────
EXISTING_BLOB='{"UNRELATED_KEY":"keep-me"}'
out="$(merge_secret headlamp-envvars headlamp client-def "$tricky_secret")"
check "headlamp: unrelated key preserved" "keep-me" "$(jq -r '.UNRELATED_KEY' <<< "$out")"
check "headlamp: issuer URL set"          "$IDP_URL" "$(jq -r '.OIDC_ISSUER_URL' <<< "$out")"
check "headlamp: tricky client secret round-trips" "$tricky_secret" "$(jq -r '.OIDC_CLIENT_SECRET' <<< "$out")"

# ── flux-ui / harbor: minimal shape check ───────────────────────────────────
EXISTING_BLOB='__NONE__'
out="$(merge_secret flux-ui-oidc flux-ui client-ghi "$tricky_secret")"
check "flux-ui: clientSecret round-trips" "$tricky_secret" "$(jq -r '.clientSecret' <<< "$out")"

out="$(merge_secret harbor-oidc harbor client-jkl "$tricky_secret")"
check "harbor: endpoint set from IDP_URL" "$IDP_URL" "$(jq -r '.endpoint' <<< "$out")"
check "harbor: client_secret round-trips" "$tricky_secret" "$(jq -r '.client_secret' <<< "$out")"

# ── headlamp-proxy: cookie secret is generated once, then PRESERVED ────────
EXISTING_BLOB='__NONE__'
out="$(merge_secret headlamp-proxy-oidc headlamp-proxy client-mno "$tricky_secret")"
first_cookie="$(jq -r '."cookie-secret"' <<< "$out")"
check "headlamp-proxy: generated cookie is exactly 32 chars" "32" "${#first_cookie}"
check "headlamp-proxy: client-secret round-trips" "$tricky_secret" "$(jq -r '."client-secret"' <<< "$out")"

EXISTING_BLOB="$out"   # simulate a second run reading back what the first wrote
out2="$(merge_secret headlamp-proxy-oidc headlamp-proxy client-mno "$tricky_secret")"
check "headlamp-proxy: cookie secret preserved across runs" "$first_cookie" "$(jq -r '."cookie-secret"' <<< "$out2")"

# ── a failed read is not an absent secret (#2086) ──────────────────────────
# Merged into {}, a throttled describe dropped every field this script does not
# own -- grafana's admin credentials -- and the caller stored the result.
ERR="$(mktemp)"; trap 'rm -f "$ERR"' EXIT
for blob in __THROTTLED__ __UNREADABLE__; do
    EXISTING_BLOB="$blob" rc=0
    out="$(merge_secret grafana-envvars grafana client-abc "$tricky_secret" 2>"$ERR")" || rc=$?
    check "${blob}: merge_secret fails" "1" "$rc"
    check "${blob}: no payload for the caller to store" "" "$out"
    check "${blob}: names the unreadable key" yes "$(grep -qF "cannot read grafana-envvars" "$ERR" && echo yes || echo no)"
done
EXISTING_BLOB=__THROTTLED__
merge_secret grafana-envvars grafana client-abc x >/dev/null 2>"$ERR"
check "__THROTTLED__: shows the store error" yes "$(grep -q ThrottlingException "$ERR" && echo yes || echo no)"

# ── the client secret, the existing blob and the cookie secret must not ────
# ── reach jq's argv (three separate leak sites, one fix each) ──────────────
#
# Static, not behavioural: a functional round-trip test can't tell "the
# value went in via stdin" from "it went in via --arg/--argjson" -- both jq
# constructions produce byte-identical JSON for a normal secret. Only reading
# the source distinguishes them, so that's what this checks, against the real
# file rather than a restatement of it.
code_grep() { grep -n -- "$1" "$SRC" | grep -v '^[0-9]\+:[[:space:]]*#' || true; }

check "no existing-blob passed as jq --argjson"    "" "$(code_grep '--argjson[[:space:]]\+base\b')"
check "no client secret passed as a jq --arg"      "" "$(code_grep '--arg[[:space:]]\+sec\b')"
check "no cookie secret passed as a jq --arg"      "" "$(code_grep '--arg[[:space:]]\+ck\b')"

exit "$fail"
