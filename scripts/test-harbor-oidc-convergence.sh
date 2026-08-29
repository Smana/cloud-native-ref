#!/usr/bin/env bash
# Unit-tests harbor-oidc.sh's per-field convergence check (auth_mode /
# oidc_endpoint / oidc_client_id) against fixture JSON shaped like Harbor's
# real `/api/v2.0/configurations` response -- every field is a
# StringConfigItem/BoolConfigItem object with a `.value`, which is exactly
# what the script's own jq paths (`.auth_mode.value`, `.oidc_endpoint.value`,
# `.oidc_client_id.value`) read.
#
# harbor-oidc.sh is not sourceable -- it runs its sync unconditionally at the
# bottom of the file, against a live cluster and a live secret store -- so
# this restates each filter rather than importing it. Known trade-off of
# testing inline jq in a non-library script (same one test-zitadel-idp-
# convergence.sh documents).
set -uo pipefail
fail=0
check() { if [ "$2" = "$3" ]; then printf '  ok   %s\n' "$1"
          else printf '  FAIL %s: expected %q got %q\n' "$1" "$2" "$3"; fail=1; fi }

# ── per-field convergence: auth_mode / oidc_endpoint / oidc_client_id ───────
desired_endpoint="https://auth.priv.aws.ogenki.io"
desired_client="harbor-client-id"

cfg_match="$(jq -n --arg ep "$desired_endpoint" --arg id "$desired_client" \
    '{auth_mode:{value:"oidc_auth"}, oidc_endpoint:{value:$ep}, oidc_client_id:{value:$id}}')"
cfg_stale_mode="$(jq -n --arg ep "$desired_endpoint" --arg id "$desired_client" \
    '{auth_mode:{value:"db_auth"}, oidc_endpoint:{value:$ep}, oidc_client_id:{value:$id}}')"
cfg_stale_endpoint="$(jq -n --arg id "$desired_client" \
    '{auth_mode:{value:"oidc_auth"}, oidc_endpoint:{value:"https://auth.priv.cloud.ogenki.io"}, oidc_client_id:{value:$id}}')"
cfg_stale_client="$(jq -n --arg ep "$desired_endpoint" \
    '{auth_mode:{value:"oidc_auth"}, oidc_endpoint:{value:$ep}, oidc_client_id:{value:"OLD-ROTATED-OUT"}}')"
cfg_never_configured='{"auth_mode":{"value":"db_auth"}}'

field_verdict() {
    # $1: jq path to the current value, $2: desired value, $3: fixture JSON
    local current
    current="$(jq -r "${1} // \"\"" <<< "$3")"
    [ "$current" = "$2" ] && echo ok || echo STALE
}

check "auth_mode: oidc_auth already set -> ok"   "ok"    "$(field_verdict '.auth_mode.value // "unknown"' "oidc_auth" "$cfg_match")"
check "auth_mode: db_auth -> STALE"              "STALE" "$(field_verdict '.auth_mode.value // "unknown"' "oidc_auth" "$cfg_stale_mode")"

check "oidc_endpoint: matches -> ok"             "ok"    "$(field_verdict '.oidc_endpoint.value' "$desired_endpoint" "$cfg_match")"
check "oidc_endpoint: stale domain -> STALE"     "STALE" "$(field_verdict '.oidc_endpoint.value' "$desired_endpoint" "$cfg_stale_endpoint")"

check "oidc_client_id: matches -> ok"            "ok"    "$(field_verdict '.oidc_client_id.value' "$desired_client" "$cfg_match")"
check "oidc_client_id: rotated -> STALE"         "STALE" "$(field_verdict '.oidc_client_id.value' "$desired_client" "$cfg_stale_client")"

# A cluster that never had OIDC configured at all -- auth_mode is the only
# key Harbor returns anything for; the other two must not blow up the field
# read (empty string, not a jq error under -e-less `// ""`).
check "never configured: endpoint reads empty, not error" "STALE" "$(field_verdict '.oidc_endpoint.value' "$desired_endpoint" "$cfg_never_configured")"

# ── the client secret must not reach jq's argv (either call site) ───────────
#
# Static, not behavioural: a functional round-trip test can't tell "the
# secret went in via stdin" from "the secret went in via --arg" -- both jq
# constructions produce byte-identical JSON for a normal secret. Only reading
# the source distinguishes them.
#
# Two sites existed before this fix: the payload-construction --arg, and a
# second, redundant `jq -n --argjson b "$payload"` re-parse of the already-
# built (already-secret-bearing) payload right before the curl call. Both are
# checked.
HERE="$(cd "$(dirname "$0")" && pwd)"
# Excludes comment-only lines (the fix's own explanation quotes the old,
# now-removed pattern verbatim as documentation -- that mention is not a
# leak).
code_grep() { grep -n -- "$1" "$HERE/harbor-oidc.sh" | grep -v '^[0-9]\+:[[:space:]]*#' || true; }

leaks_arg="$(code_grep '--arg[[:space:]]\+sec\b')"
check "no client secret passed as a jq --arg" "" "$leaks_arg"

leaks_argjson="$(code_grep '--argjson[[:space:]]\+b\b')"
check "no re-parse of the payload via jq --argjson" "" "$leaks_argjson"

# Functional companion: harbor_oidc_payload's actual construction (restated,
# same caveat as above) round-trips a secret containing characters that would
# be easy to mis-escape.
harbor_oidc_payload() {
    local name="$1" ep="$2" id="$3" secret="$4"
    printf '%s' "$secret" | jq -Rs --arg name "$name" --arg ep "$ep" --arg id "$id" \
        '{
            auth_mode: "oidc_auth",
            oidc_name: $name,
            oidc_endpoint: $ep,
            oidc_client_id: $id,
            oidc_client_secret: .,
            oidc_scope: "openid,profile,email,offline_access",
            oidc_groups_claim: "groups",
            oidc_user_claim: "preferred_username",
            oidc_auto_onboard: true,
            oidc_verify_cert: true
         }'
}
tricky_secret='we!rd"secret\1`with`backtick\and\\backslash$(whoami)'
payload="$(harbor_oidc_payload "ZITADEL" "$desired_endpoint" "$desired_client" "$tricky_secret")"
check "payload: oidc_client_id preserved"    "$desired_client" "$(jq -r '.oidc_client_id' <<< "$payload")"
check "payload: oidc_endpoint preserved"     "$desired_endpoint" "$(jq -r '.oidc_endpoint' <<< "$payload")"
check "payload: tricky secret round-trips"   "$tricky_secret" "$(jq -r '.oidc_client_secret' <<< "$payload")"
check "payload: offline_access scope present" "true" "$(jq '.oidc_scope | contains("offline_access")' <<< "$payload")"

exit "$fail"
