#!/usr/bin/env bash
# shellcheck disable=SC2034
# (MIRROR_OPENBAO, OPENBAO_ROOT_TOKEN_SECRET, IDP_URL and HEADLAMP_OIDC_SCOPES
# are read by function bodies eval'd out of the script, which static analysis
# cannot see.)
# requires: jq openssl
#
# --mirror-openbao (GCP parity GP-5): a fresh directory re-registers every client
# each build, and gcp-0's consumers read OpenBao. The mirror copies only the
# fields the sync owns onto an existing value (the whole payload onto an absent
# one), writes only on a change, says when it skips an unmapped key, and does
# nothing unset. The functions are lifted out of the script, so this tests the
# code that ships.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
cd "$REPO_ROOT" || exit 1
# Overridable so a mutant copy can be pointed at (see the fix-round proofs).
S="${ZITADEL_OIDC_CLIENTS_SCRIPT:-scripts/provision/zitadel-oidc-clients.sh}"
fail=0
ok()  { printf '  ok   %s\n' "$1"; }
bad() { printf '  FAIL %s\n' "$1"; fail=1; }

M="${OPENBAO_MIRROR_LIB:-scripts/lib/openbao-mirror.sh}"
body="$(sed -n '/^mirror_to_openbao() (/,/^)/p' "$M")"
[ -n "$body" ] || { echo "could not extract mirror_to_openbao() from $M" >&2; exit 1; }
# shellcheck source=scripts/lib/bao-map.sh
. "$REPO_ROOT/scripts/lib/bao-map.sh"
eval "$body"
eval "$(sed -n '/^MIRRORED_FIELDS=(/,/^)/p' "$M")"
eval "$(sed -n '/^store_write_and_mirror() {/,/^}/p' "$S")"
eval "$(sed -n '/^merge_secret() {/,/^}/p' "$S")"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
openbao_token_config_write() { : >"$1"; }
GET_BODY='{"data":{"data":{"GF_SECURITY_ADMIN_USER":"admin","GF_AUTH_GENERIC_OAUTH_CLIENT_ID":"old"}}}'
GET_CODE=200
POST_RC=0
openbao_req() {
    printf '%s %s\n' "$1" "$2" >>"$T/calls"
    local method="$1" out=/dev/null
    shift 2
    while [ $# -gt 0 ]; do case "$1" in -o) out="$2"; shift 2 ;; *) shift ;; esac; done
    case "$method" in
        GET)  printf '%s' "$GET_BODY" >"$out"; printf '%s' "$GET_CODE" ;;
        POST) cat >"$T/body"; return "$POST_RC" ;;
    esac
}
reset() { : >"$T/calls"; rm -f "$T/body"; }

MIRROR_OPENBAO=true
OPENBAO_ROOT_TOKEN_SECRET=fixture
reset
printf '%s' '{"GF_AUTH_GENERIC_OAUTH_CLIENT_ID":"new"}' \
  | mirror_to_openbao observability-victoria-metrics-k8s-stack-grafana-envvars >/dev/null
grep -qx 'POST platform/data/victoria-metrics/grafana-envvars' "$T/calls" \
  && ok "grafana-envvars is written to its mapped path" || bad "grafana-envvars path: $(cat "$T/calls")"
[ "$(jq -c '.data' "$T/body")" = '{"GF_SECURITY_ADMIN_USER":"admin","GF_AUTH_GENERIC_OAUTH_CLIENT_ID":"new"}' ] \
  && ok "merged: the admin user kept, the client id replaced" || bad "merge: $(cat "$T/body")"

# I-1: a field the sync does not own keeps OpenBao's value, even when the
# store's blob carries an older one (seed's admin password, rotated in OpenBao).
reset
GET_BODY='{"data":{"data":{"GF_SECURITY_ADMIN_PASSWORD":"rotated-in-bao","GF_AUTH_GENERIC_OAUTH_CLIENT_ID":"old"}}}'  # pragma: allowlist secret
store_blob='{"GF_SECURITY_ADMIN_PASSWORD":"stale-in-store","GF_AUTH_GENERIC_OAUTH_CLIENT_ID":"new","GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET":"fake"}'  # pragma: allowlist secret
want='{"GF_SECURITY_ADMIN_PASSWORD":"rotated-in-bao","GF_AUTH_GENERIC_OAUTH_CLIENT_ID":"new","GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET":"fake"}'  # pragma: allowlist secret
printf '%s' "$store_blob" | mirror_to_openbao observability-victoria-metrics-k8s-stack-grafana-envvars >/dev/null
[ "$(jq -c '.data' "$T/body" 2>/dev/null)" = "$want" ] \
  && ok "a field the sync does not own keeps OpenBao's value" || bad "unowned field: $(cat "$T/body" 2>/dev/null)"

# No KV version churn: nothing written when OpenBao already holds the fields.
reset
GET_BODY='{"data":{"data":{"GF_SECURITY_ADMIN_USER":"admin","GF_AUTH_GENERIC_OAUTH_CLIENT_ID":"same"}}}'
out="$(printf '%s' '{"GF_AUTH_GENERIC_OAUTH_CLIENT_ID":"same"}' \
  | mirror_to_openbao observability-victoria-metrics-k8s-stack-grafana-envvars)"; rc=$?
[ "$rc" -eq 0 ] && ! grep -q '^POST' "$T/calls" && [ ! -e "$T/body" ] \
  && ok "unchanged: no write, so no new KV version" || bad "unchanged: rc=$rc, calls $(cat "$T/calls")"

# A 404 means OpenBao holds nothing the ownership filter could protect, and
# `migrate` is additive per path: it skips a path that exists. An owned-fields
# write here would leave grafana-envvars without its admin credentials for good.
reset
GET_CODE=404 GET_BODY='{"errors":[]}'
store_blob='{"GF_SECURITY_ADMIN_USER":"admin","GF_SECURITY_ADMIN_PASSWORD":"fixture-pw","GF_AUTH_GENERIC_OAUTH_CLIENT_ID":"new"}'  # pragma: allowlist secret
printf '%s' "$store_blob" | mirror_to_openbao observability-victoria-metrics-k8s-stack-grafana-envvars >/dev/null
[ "$(jq -c '.data' "$T/body" 2>/dev/null)" = "$store_blob" ] \
  && ok "absent path (404): written fresh with the full store payload" \
  || bad "404 case: wrote keys $(jq -c '.data | keys' "$T/body" 2>/dev/null)"

reset
GET_CODE=403
printf '%s' '{"client_id":"new"}' | mirror_to_openbao harbor-oidc >/dev/null 2>&1; rc=$?
[ "$rc" -ne 0 ] && [ ! -e "$T/body" ] \
  && ok "unreadable path (403): fails and overwrites nothing" || bad "403 case: rc=$rc, wrote $(cat "$T/body" 2>/dev/null)"
GET_CODE=200

# I-3 (M1): OpenBao refusing the write is a failure, not a success.
reset
GET_BODY='{"data":{"data":{}}}'
POST_RC=22
printf '%s' '{"client_id":"new"}' | mirror_to_openbao harbor-oidc >/dev/null 2>&1; rc=$?
[ "$rc" -ne 0 ] && ok "a refused write (POST fails): mirror_to_openbao fails" || bad "a refused write returned 0"
POST_RC=0

# I-2: an unmapped key is skipped out loud, and still succeeds.
reset
err="$(printf '%s' '{"client_id":"x"}' | mirror_to_openbao openbao-oidc 2>&1 >/dev/null)"; rc=$?
[ ! -s "$T/calls" ] && ok "openbao-oidc (unmapped) never reaches OpenBao" || bad "an unmapped key reached OpenBao"
[ "$rc" -eq 0 ] && [ "$err" = "[skip   ] openbao-oidc: no OpenBao path in scripts/lib/bao-map.sh" ] \
  && ok "an unmapped key says so on stderr, exit 0" || bad "unmapped skip: rc=$rc stderr='$err'"

reset
MIRROR_OPENBAO=false
printf '%s' '{"a":"b"}' | mirror_to_openbao harbor-oidc
[ ! -s "$T/calls" ] && ok "without --mirror-openbao nothing is written" || bad "wrote without the flag"
MIRROR_OPENBAO=true

# I-3 (M2): a failed store write stops the mirror; a failed mirror is told apart.
reset
store_write() { cat >/dev/null; return 1; }
printf '%s' '{"client_id":"new"}' | store_write_and_mirror harbor-oidc >/dev/null 2>&1; rc=$?
[ "$rc" -eq 1 ] && [ ! -s "$T/calls" ] \
  && ok "a failed store write: returns 1, OpenBao never called" || bad "store write failed: rc=$rc, calls $(cat "$T/calls")"
reset
store_write() { cat >/dev/null; }
POST_RC=22
printf '%s' '{"client_id":"new"}' | store_write_and_mirror harbor-oidc >/dev/null 2>&1; rc=$?
[ "$rc" -eq 2 ] && ok "a failed mirror after a good store write: returns 2" || bad "mirror failure: rc=$rc, want 2"
POST_RC=0

# MIRRORED_FIELDS is the one list of what the sync owns: every key merge_secret
# writes must be in it, or that field never reaches OpenBao.
store_probe() { return 1; }
store_read() { :; }
IDP_URL="https://auth.example.invalid"
HEADLAMP_OIDC_SCOPES="profile,email,groups"
missing=""
for consumer in grafana headlamp flux-ui harbor openbao headlamp-proxy rooms-proxy; do
    keys="$(merge_secret k "$consumer" id-fixture fake-secret | jq -r 'keys[]')"  # pragma: allowlist secret
    [ -n "$keys" ] || missing="${missing} ${consumer}:<no output>"
    while IFS= read -r k; do
        [ -z "$k" ] && continue
        printf '%s\n' "${MIRRORED_FIELDS[@]}" | grep -qxF -- "$k" || missing="${missing} ${consumer}:${k}"
    done <<< "$keys"
done
[ -z "$missing" ] && ok "every field merge_secret writes is in MIRRORED_FIELDS" || bad "not in MIRRORED_FIELDS:${missing}"

# M-4: the ExternalSecrets reading a mirrored path are force-synced, so they do
# not wait out their refreshInterval on the dead directory's clients. Matched on
# store (openbao-<mount>) AND key, through both data and dataFrom.
fs_body="$(sed -n '/^force_sync_mirrored() {/,/^}/p' "$M")"
if [ -z "$fs_body" ]; then
    bad "could not extract force_sync_mirrored() from $M"
else
    eval "$fs_body"
    ES_JSON='{"items":[
      {"metadata":{"namespace":"observability","name":"grafana-es"},"spec":{"secretStoreRef":{"name":"openbao-platform"},"dataFrom":[{"extract":{"key":"victoria-metrics/grafana-envvars"}}]}},
      {"metadata":{"namespace":"tooling","name":"harbor-es"},"spec":{"secretStoreRef":{"name":"openbao-platform"},"data":[{"secretKey":"x","remoteRef":{"key":"harbor/oidc"}}]}},
      {"metadata":{"namespace":"apps","name":"wrong-mount"},"spec":{"secretStoreRef":{"name":"openbao-apps"},"dataFrom":[{"extract":{"key":"harbor/oidc"}}]}},
      {"metadata":{"namespace":"security","name":"gsm-es"},"spec":{"secretStoreRef":{"name":"clustersecretstore"},"dataFrom":[{"extract":{"key":"harbor-oidc"}}]}},
      {"metadata":{"namespace":"tooling","name":"find-only"},"spec":{"secretStoreRef":{"name":"openbao-platform"},"dataFrom":[{"find":{"path":"harbor"}}]}}]}'
    KGET_RC=0
    kubectl() {
        printf '%s\n' "$*" >>"$T/kubectl"
        case "$1" in
            get) printf '%s' "$ES_JSON"; return "$KGET_RC" ;;
            annotate) return 0 ;;
        esac
    }
    APPLY=true MIRROR_OPENBAO=true
    : >"$T/kubectl"
    force_sync_mirrored observability-victoria-metrics-k8s-stack-grafana-envvars harbor-oidc openbao-oidc >/dev/null 2>&1; rc=$?
    annotated="$(grep '^annotate' "$T/kubectl" | awk '{print $5"/"$3}' | sort | tr '\n' ' ')"
    [ "$rc" -eq 0 ] && [ "$annotated" = "observability/grafana-es tooling/harbor-es " ] \
      && ok "force-sync: exactly the ExternalSecrets reading a mirrored path" || bad "force-sync annotated: '$annotated' rc=$rc"
    grep '^annotate' "$T/kubectl" | grep -qv -- '--overwrite' \
      && bad "force-sync annotate without --overwrite" || ok "force-sync annotates with --overwrite"
    : >"$T/kubectl"
    APPLY=false force_sync_mirrored harbor-oidc >/dev/null 2>&1
    [ ! -s "$T/kubectl" ] && ok "force-sync: nothing on a dry run" || bad "force-sync ran on a dry run"
    : >"$T/kubectl"
    MIRROR_OPENBAO=false force_sync_mirrored harbor-oidc >/dev/null 2>&1
    [ ! -s "$T/kubectl" ] && ok "force-sync: nothing without --mirror-openbao" || bad "force-sync ran without the flag"
    KGET_RC=1
    err="$(force_sync_mirrored harbor-oidc 2>&1 >/dev/null)"; rc=$?
    [ "$rc" -eq 0 ] && grep -q 'WARN' <<< "$err" \
      && ok "force-sync: a failed listing warns and returns 0" || bad "force-sync listing failure: rc=$rc err='$err'"
    KGET_RC=0
    unset -f kubectl
fi
grep -q '^    force_sync_mirrored "\${mirrored_keys\[@\]}"' "$S" \
  && ok "cmd_sync force-syncs the mirrored keys" || bad "cmd_sync never calls force_sync_mirrored"

grep -q -- '--mirror-openbao) MIRROR_OPENBAO="true"; shift ;;' "$S" && ok "--mirror-openbao is parsed" || bad "--mirror-openbao is not parsed"
[ "$(grep -c 'store_write_and_mirror "\$key"' "$S")" -eq 2 ] \
  && ok "both consumer writes go through store_write_and_mirror" || bad "a consumer write bypasses the mirror"

# --mirror-openbao without --openbao-url is refused before any ZITADEL or cloud
# call: every CLI the script could reach is a stub that records being called.
mkdir -p "$T/bin"
for cli in curl gcloud aws kubectl bao; do
    printf '#!/usr/bin/env bash\necho %s >> "%s/cli-calls"\nexit 1\n' "$cli" "$T" > "$T/bin/$cli"
    chmod +x "$T/bin/$cli"
done
out="$(PATH="$T/bin:$PATH" timeout 10 bash "$S" sync --cluster gcp-0 --cloud gcp --mirror-openbao 2>&1)"; rc=$?
[ "$rc" -eq 2 ] && grep -qF -- '--mirror-openbao requires --openbao-url' <<< "$out" && [ ! -e "$T/cli-calls" ] \
  && ok "--mirror-openbao without --openbao-url: exit 2, no CLI called" \
  || bad "flag guard: rc=$rc, called $(cat "$T/cli-calls" 2>/dev/null | tr '\n' ' '), out: $(head -3 <<< "$out")"

[ "$fail" -eq 0 ] && echo "all checks passed"
exit "$fail"
