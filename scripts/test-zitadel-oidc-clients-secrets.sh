#!/usr/bin/env bash
# Unit-tests zitadel-oidc-clients.sh's merge_secret -- specifically the round-2
# fix that took client_secret, the existing secret blob (--argjson base) and
# the headlamp-proxy cookie secret off jq's argv. $existing matters as much as
# the client secret here: for grafana it also carries the generated Grafana
# admin credentials, so leaking it the same way leaked those too.
#
# zitadel-oidc-clients.sh is not sourceable -- it parses argv and requires
# --cluster/--cloud unconditionally at the top of the file -- so this restates
# merge_secret rather than importing it. Same trade-off test-zitadel-idp-
# convergence.sh documents for its own script.
set -uo pipefail
fail=0
check() { if [ "$2" = "$3" ]; then printf '  ok   %s\n' "$1"
          else printf '  FAIL %s: expected %q got %q\n' "$1" "$2" "$3"; fail=1; fi }

# ── store_exists/store_read stubs -- no cloud call, canned "existing" blob ──
EXISTING_BLOB='{}'
store_exists() { [ "$EXISTING_BLOB" != "__NONE__" ]; }
store_read()   { printf '%s' "$EXISTING_BLOB"; }

IDP_URL="https://auth.priv.aws.ogenki.io"

# Restated verbatim from zitadel-oidc-clients.sh.
merge_secret() {
    local key="$1" name="$2" client_id="$3" client_secret="$4"
    local existing='{}' cookie_secret=''
    store_exists "$key" && existing="$(store_read "$key")"
    [ -z "$existing" ] && existing='{}'

    if [ "$name" = headlamp-proxy ]; then
        cookie_secret="$(jq -r '."cookie-secret" // empty' <<< "$existing")"
        [ -n "$cookie_secret" ] || cookie_secret="$(openssl rand -base64 32 | head -c 32)"
    fi

    {
        printf '%s\n' "$existing"
        printf '%s' "$client_secret" | jq -Rs .
        printf '%s' "$cookie_secret" | jq -Rs .
    } | jq -n --arg id "$client_id" --arg iss "$IDP_URL" --arg name "$name" '
        input as $base | input as $sec | input as $ck |
        if $name == "grafana" then
            $base + {GF_AUTH_GENERIC_OAUTH_CLIENT_ID: $id, GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET: $sec}
        elif $name == "headlamp" then
            $base + {OIDC_CLIENT_ID: $id, OIDC_CLIENT_SECRET: $sec, OIDC_ISSUER_URL: $iss,
                     OIDC_SCOPES: "openid,profile,email",
                     OIDC_VALIDATOR_CLIENT_ID: $id, OIDC_VALIDATOR_ISSUER_URL: $iss}
        elif $name == "flux-ui" then
            $base + {clientID: $id, clientSecret: $sec}
        elif $name == "harbor" then
            $base + {client_id: $id, client_secret: $sec, endpoint: $iss}
        elif $name == "headlamp-proxy" then
            $base + {"client-id": $id, "client-secret": $sec, "cookie-secret": $ck}
        else
            empty
        end
    '
}

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

# ── the client secret, the existing blob and the cookie secret must not ────
# ── reach jq's argv (three separate leak sites, one fix each) ──────────────
#
# Static, not behavioural: a functional round-trip test can't tell "the
# value went in via stdin" from "it went in via --arg/--argjson" -- both jq
# constructions produce byte-identical JSON for a normal secret. Only reading
# the source distinguishes them, so that's what this checks, against the real
# file rather than a restatement of it.
HERE="$(cd "$(dirname "$0")" && pwd)"
code_grep() { grep -n -- "$1" "$HERE/zitadel-oidc-clients.sh" | grep -v '^[0-9]\+:[[:space:]]*#' || true; }

check "no existing-blob passed as jq --argjson"    "" "$(code_grep '--argjson[[:space:]]\+base\b')"
check "no client secret passed as a jq --arg"      "" "$(code_grep '--arg[[:space:]]\+sec\b')"
check "no cookie secret passed as a jq --arg"      "" "$(code_grep '--arg[[:space:]]\+ck\b')"

exit "$fail"
