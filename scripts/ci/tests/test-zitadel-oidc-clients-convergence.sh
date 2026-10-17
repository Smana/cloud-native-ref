#!/usr/bin/env bash
# shellcheck disable=SC2034
# (file-wide: CLUSTER/CLOUD/IDP_URL/ZITADEL_PROJECT_NAME/GRANT_ADMIN/
# CONSUMERS/APPLY/HEADLAMP_OIDC_SCOPES below are read only by cmd_sync's/
# converge_secret's eval'd bodies -- shellcheck can't see those uses.)
#
# Regression test for DEFECT 4: the per-consumer secret payload only ever
# converged when an app was CREATED. On a re-run against an app that already
# existed, cmd_sync checked the redirect URI against ZITADEL and stopped
# there -- it never looked at what the secret store currently held, so a
# field this script's own literal changed (OIDC_SCOPES gaining `groups` on
# 2026-08-29) never reached a cluster whose app already existed. Every run
# printed "[ok] headlamp -- app exists, redirect correct" and wrote nothing.
#
# cmd_sync() is lifted verbatim out of zitadel-oidc-clients.sh via sed (same
# technique test-zitadel-oidc-clients-project.sh uses for ensure_project),
# not hand-restated. converge_secret() is lifted too, when present -- the
# pre-fix script this test must also run against has no such function at
# all, which is itself the defect, so its absence is tolerated rather than
# treated as a setup error.
#
# Everything cmd_sync calls OTHER than the convergence path is stubbed:
# ensure_project/ensure_project_role_assertion/ensure_project_roles/
# grant_role/app_set_redirect do nothing, and app_id_by_name/
# app_get/app_redirect_uris (old and new names, so this test runs unmodified
# against either version of the script) report ONE consumer, "headlamp",
# already existing with the CORRECT redirect URI -- so the only thing that
# can make this test's store change is convergence, not the redirect-repair
# path defect 1's test already covers.
#
# This DRIVER runs under the lenient `set -uo pipefail` every sibling test in
# this repo uses (test-zitadel-pat.sh, test-zitadel-oidc-clients-secrets.sh,
# etc.) -- NOT errexit, because this test deliberately drives cmd_sync
# through both an "already converged" and a "just converged" call and needs
# to keep running afterward to check() the result either way. cmd_sync
# ITSELF still runs under the full production triad
# (errexit+nounset+pipefail) -- see the `( set -o errexit ...; cmd_sync )`
# wrapper below -- so this reproduces how the script actually runs without
# errexit taking the test driver down with it.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
fail=0
check() { if [ "$2" = "$3" ]; then printf '  ok   %s\n' "$1"
          else printf '  FAIL %s: expected %q got %q\n' "$1" "$2" "$3"; fail=1; fi }

load_function() { # $1: function name, $2: source file. Missing is tolerated.
    local body
    body="$(sed -n "/^${1}() {/,/^}/p" "$2")"
    # NOT `[ -n "$body" ] && eval "$body"`: under this script's OWN errexit
    # (set to match production), a bare `[ ... ] && ...` statement whose left
    # side is false makes the whole statement's exit status 1 -- and since
    # nothing here tests THAT result either, errexit aborts the test right
    # here, silently, the exact first time this ran against the pre-fix
    # script (converge_secret legitimately absent there). The explicit `if`
    # is exempt from errexit by design, which is what "tolerated" requires.
    [ -n "$body" ] || body="$(sed -n "/^${1}() (/,/^)/p" "$2")"   # a subshell function
    if [ -n "$body" ]; then
        eval "$body"
    fi
}

SRC="${ZITADEL_OIDC_CLIENTS_SCRIPT:-$HERE/../../provision/zitadel-oidc-clients.sh}"
load_function cmd_sync "$SRC"
load_function converge_secret "$SRC"
if ! declare -F cmd_sync >/dev/null; then
    echo "could not extract cmd_sync() from $SRC" >&2
    exit 1
fi

# ── everything cmd_sync calls, other than the convergence path ─────────────
ensure_project() { echo "proj-1"; }
ensure_project_role_assertion() { :; }
ensure_project_roles() { :; }
grant_role() { :; }
app_set_redirect() { :; }
app_id_by_name() { echo "app-1"; }
# Explicit, not left to fall through undefined: the two reconciles cmd_sync
# calls after the loop. Their own behaviour is covered by
# test-zitadel-oidc-clients-openbao.sh (#2045) and
# test-zitadel-workforce-audience.sh.
reconcile_openbao_oidc() { :; }
reconcile_workforce_audience() { :; }
# New-shape call (defect 4): the whole app entry.
app_get() {
    jq -n --arg redirect "$REDIRECT" --arg cid "$EXISTING_CLIENT_ID" \
        '{app: {oidcConfig: {redirectUris: [$redirect], clientId: $cid}}}'
}
# Old-shape call, so this test runs unmodified against the pre-fix script too.
app_redirect_uris() { printf '%s\n' "$REDIRECT"; }

# ── the store, backed by real files rather than an in-shell array ──────────
#
# cmd_sync's own write is `printf '%s' "$desired" | store_write "$key"` --
# a PIPELINE, and bash runs every command in a pipeline (the last one
# included, absent `shopt -s lastpipe`, which nothing here enables) in its
# own subshell. An in-memory `declare -A STORE` stub would mutate a COPY
# that vanishes when that subshell exits -- caught by hand here: an earlier
# version of this stub did exactly that, store_write visibly ran (its own
# debug echo proved it), and the "converged" array entry stayed stale
# anyway. Real store_write has this same pipeline shape and is NOT affected,
# because its side effect is an external `aws`/`gcloud` call, not an
# in-process variable -- so this stub is fixed to match that: real
# filesystem I/O, which a subshell cannot make disappear.
STORE_DIR="$(mktemp -d)"
# Like the real one, false for "absent" and "cannot tell" alike.
store_exists() { store_probe "$1"; }
# $PROBE_FAIL answers "cannot tell", as a throttled describe does (#2082).
store_probe() {
    STORE_PROBE_ERR=""
    if [ -n "${PROBE_FAIL:-}" ]; then
        STORE_PROBE_ERR="An error occurred (ThrottlingException) when calling the DescribeSecret operation"
        return 2
    fi
    [ -f "$STORE_DIR/$1" ] && return 0
    return 1
}
store_read()   { cat "$STORE_DIR/$1" 2>/dev/null || true; }
store_write()  { cat > "$STORE_DIR/$1"; }
# cmd_sync writes through the real wrapper; the OpenBao mirror behind it has its
# own suite (test-zitadel-oidc-clients-mirror.sh).
load_function store_write_and_mirror "$SRC"
load_function publish_project_id "$SRC"   # a no-op here: CLOUD=aws
mirror_to_openbao() { cat >/dev/null; }
force_sync_mirrored() { :; }   # its own suite; no kubectl here
load_function stored_client_id "$SRC"
load_function stored_client_secret "$SRC"
load_function secret_sha "$SRC"
load_function merge_secret "$SRC"   # the rotation's write
# Its kubectl side has its own suite; here only WHICH keys reach it matters.
restart_rotated_consumers() { printf '%s\n' "$@" > "$STORE_DIR/.rotated"; }
# What ZITADEL says of the stored secret: 0 accepted, 1 invalid_client, 2 cannot
# tell. The real probe has its own cases at the end of this file.
PROBE_RC=0
probe_client_secret() { cat > "$STORE_DIR/.probed"; return "$PROBE_RC"; }
# Only the rotation calls the API from this path.
api_or_fail() { printf '%s %s\n' "$1" "$2" >> "$STORE_DIR/.api"; printf '{"clientSecret":"fresh-secret"}'; }  # pragma: allowlist secret

# ── globals cmd_sync / converge_secret read ─────────────────────────────────
CLUSTER="aws-0"
CLOUD="aws"
IDP_URL="https://auth.priv.aws.ogenki.io"
PRIVATE_DOMAIN="priv.aws.ogenki.io"
ZITADEL_PROJECT_NAME="platform"
GRANT_ADMIN=""
# Empty because this fixture is a HOSTING cluster (--idp-cloud would equal
# --cloud). A consuming cluster sets it to "-<cluster>" so two clusters do not
# contend for one ZITADEL app name; see the block that computes it in the
# script. It has to be declared here because these tests lift the functions out
# of the script and supply their globals by hand.
APP_SUFFIX=""
HEADLAMP_OIDC_SCOPES="profile,email,groups"
REDIRECT="https://headlamp.${PRIVATE_DOMAIN}/oidc-callback"
EXISTING_CLIENT_ID="existing-client-id"
CONSUMERS=("headlamp|${REDIRECT}|headlamp-envvars")

# The STALE payload this bug actually produced: OIDC_SCOPES missing `groups`,
# everything else (including the client secret, which ZITADEL would have
# returned only once, at creation) already correct.
stale_payload='{"OIDC_CLIENT_ID":"existing-client-id","OIDC_CLIENT_SECRET":"do-not-touch-me","OIDC_ISSUER_URL":"https://auth.priv.aws.ogenki.io","OIDC_SCOPES":"openid,profile,email","OIDC_VALIDATOR_CLIENT_ID":"existing-client-id","OIDC_VALIDATOR_ISSUER_URL":"https://auth.priv.aws.ogenki.io"}'  # pragma: allowlist secret
printf '%s' "$stale_payload" > "$STORE_DIR/headlamp-envvars"

APPLY=true
# NOT `out="$(cmd_sync)"`: command substitution runs cmd_sync in a SUBSHELL.
# Output capture is redirected to a file instead so cmd_sync itself still
# runs in THIS shell -- store_write's own pipeline (`... | store_write`)
# already puts store_write in a subshell regardless (bash forks one per
# pipeline stage without `shopt -s lastpipe`, which nothing here enables);
# that is exactly why the store above is real files, not an in-shell array
# a subshell's writes would vanish from.
OUT_FILE="$(mktemp)"
trap 'rm -f "$OUT_FILE"; rm -rf "$STORE_DIR"' EXIT
# No `|| true`: a subshell on the left of `||` runs with errexit IGNORED,
# whatever it sets, so an undefined function would fail silently mid-run.
( set -o errexit -o nounset -o pipefail; cmd_sync ) > "$OUT_FILE" 2>&1
check "converge: cmd_sync exits 0 under errexit" "0" "$?"
out="$(cat "$OUT_FILE")"
after="$(store_read headlamp-envvars)"

check "converge: OIDC_SCOPES gains groups"     "profile,email,groups" "$(jq -r '.OIDC_SCOPES' <<< "$after")"
check "converge: client secret untouched"      "do-not-touch-me"      "$(jq -r '.OIDC_CLIENT_SECRET' <<< "$after")"
check "converge: client id still correct"      "existing-client-id"   "$(jq -r '.OIDC_CLIENT_ID' <<< "$after")"
check "converge: same client id, nothing restarted" "" "$(cat "$STORE_DIR/.rotated" 2>/dev/null)"

case "$out" in
    *"[converged] headlamp"*) printf '  ok   converge: reported in the run output\n' ;;
    *) printf '  FAIL converge: no [converged] line in output\n'; fail=1 ;;
esac
case "$out" in
    *"converged: 1"*) printf '  ok   converge: counted in the summary line\n' ;;
    *) printf '  FAIL converge: summary line does not show converged: 1\n'; fail=1 ;;
esac

# ── second run: idempotent -- already converged, nothing written again ─────
( set -o errexit -o nounset -o pipefail; cmd_sync ) > "$OUT_FILE" 2>&1
check "converge: second run exits 0 under errexit" "0" "$?"
out2="$(cat "$OUT_FILE")"
check "converge: second run leaves the payload unchanged" "$after" "$(store_read headlamp-envvars)"
case "$out2" in
    *"already converged"*) printf '  ok   converge: second run reports already converged\n' ;;
    *) printf '  FAIL converge: second run does not report already converged\n'; fail=1 ;;
esac
case "$out2" in
    *"converged: 0"*) printf '  ok   converge: second run summary shows converged: 0\n' ;;
    *) printf '  FAIL converge: second run summary does not show converged: 0\n'; fail=1 ;;
esac

# ── an unreadable store is not a missing secret (#2082) ────────────────────
# The missing-secret advice is "restore it, or delete the app in ZITADEL".
# Given on a throttled describe, that deletes a working app.
rc=0
( set -o errexit -o nounset -o pipefail; PROBE_FAIL=1 cmd_sync ) > "$OUT_FILE" 2>&1 || rc=$?
out3="$(cat "$OUT_FILE")"
check "store unreadable: cmd_sync exits 1" "1" "$rc"
case "$out3" in
    *"ThrottlingException"*) printf '  ok   store unreadable: shows the store error\n' ;;
    *) printf '  FAIL store unreadable: the store error is not shown\n'; fail=1 ;;
esac
case "$out3" in
    *"delete the app"*) printf '  FAIL store unreadable: advises deleting the app\n'; fail=1 ;;
    *) printf '  ok   store unreadable: does not advise deleting the app\n' ;;
esac
check "store unreadable: the payload is untouched" "$after" "$(store_read headlamp-envvars)"

check "store unreadable: no rotation" "" "$(cat "$STORE_DIR/.api" 2>/dev/null)"

# A key with no secret is not unrecoverable any more: ZITADEL rotates one in.
rm -f "$STORE_DIR/headlamp-envvars" "$STORE_DIR/.rotated" "$STORE_DIR/.api" "$STORE_DIR/.probed"
( set -o errexit -o nounset -o pipefail; cmd_sync ) > "$OUT_FILE" 2>&1
check "secret truly absent: cmd_sync exits 0" "0" "$?"
check "secret truly absent: rotated" "POST /management/v1/projects/proj-1/apps/app-1/oidc_config/_generate_client_secret" \
    "$(cat "$STORE_DIR/.api" 2>/dev/null)"
check "secret truly absent: the new secret written" "fresh-secret existing-client-id profile,email,groups" \
    "$(jq -r '"\(.OIDC_CLIENT_SECRET) \(.OIDC_CLIENT_ID) \(.OIDC_SCOPES)"' "$STORE_DIR/headlamp-envvars")"
check "secret truly absent: never probed" "absent" "$([ -e "$STORE_DIR/.probed" ] && echo probed || echo absent)"

# ── the store holds a client ZITADEL no longer knows: a rotation ──────────
jq -c '.OIDC_CLIENT_ID = "dead-client-id"' <<< "$after" > "$STORE_DIR/headlamp-envvars"
rm -f "$STORE_DIR/.rotated"
( set -o errexit -o nounset -o pipefail; cmd_sync ) > "$OUT_FILE" 2>&1
check "rotation: cmd_sync exits 0 under errexit" "0" "$?"
check "rotation: the key and its new client id reach the restart" \
    "headlamp-envvars=existing-client-id" "$(cat "$STORE_DIR/.rotated" 2>/dev/null)"

# ── a directory restored from a seed: the stored secret is another's ──────
# gcp-0, 2026-10-17: the redirect was right, so every run printed [ok] while
# every login failed "invalid_client" "invalid secret".
reset_store() {
    jq -c '. + {UNRELATED_KEY: "keep-me"}' <<< "$after" > "$STORE_DIR/headlamp-envvars"
    rm -f "$STORE_DIR/.rotated" "$STORE_DIR/.api" "$STORE_DIR/.probed"
}
sync_rc() { rc=0; ( set -o errexit -o nounset -o pipefail; cmd_sync ) > "$OUT_FILE" 2>&1 || rc=$?; out="$(cat "$OUT_FILE")"; }
stored() { jq -r "$1" "$STORE_DIR/headlamp-envvars"; }
has_line() { grep -qF -- "$1" <<< "$out" && echo yes || echo no; }
probe_client_secret() {
    cat > "$STORE_DIR/.probed"
    [ "$PROBE_RC" -ne 2 ] || echo "token endpoint unreachable: curl: (7) Failed to connect" >&2
    return "$PROBE_RC"
}

reset_store; PROBE_RC=0; sync_rc
check "valid secret: exits 0"                          0 "$rc"
check "valid secret: probed with the stored secret"    do-not-touch-me "$(cat "$STORE_DIR/.probed" 2>/dev/null)"
check "valid secret: no rotation"                      "" "$(cat "$STORE_DIR/.api" 2>/dev/null)"
check "valid secret: nothing restarted"                "" "$(cat "$STORE_DIR/.rotated" 2>/dev/null)"
check "valid secret: the secret untouched"             do-not-touch-me "$(stored .OIDC_CLIENT_SECRET)"

reset_store; PROBE_RC=1; APPLY=false; sync_rc; APPLY=true
check "rejected, dry run: exits 0"                     0 "$rc"
check "rejected, dry run: reports it"                  yes "$(has_line '[stale  ] headlamp -- stored secret rejected, would rotate')"
check "rejected, dry run: counted"                     yes "$(has_line 'rotated: 1')"
check "rejected, dry run: no rotation"                 "" "$(cat "$STORE_DIR/.api" 2>/dev/null)"
check "rejected, dry run: nothing written"             do-not-touch-me "$(stored .OIDC_CLIENT_SECRET)"

reset_store; PROBE_RC=1; sync_rc
check "rejected: exits 0"                              0 "$rc"
check "rejected: rotated through the management API" \
    "POST /management/v1/projects/proj-1/apps/app-1/oidc_config/_generate_client_secret" "$(cat "$STORE_DIR/.api" 2>/dev/null)"
check "rejected: the new secret stored"                fresh-secret "$(stored .OIDC_CLIENT_SECRET)"
check "rejected: every other field kept"               "keep-me existing-client-id" "$(stored '"\(.UNRELATED_KEY) \(.OIDC_CLIENT_ID)"')"
check "rejected: its consumers restart, keyed on the secret's sha256" \
    "headlamp-envvars=sha256:$(printf '%s' fresh-secret | secret_sha)" "$(cat "$STORE_DIR/.rotated" 2>/dev/null)"
check "rejected: reports [rotated]"                    yes "$(has_line '[rotated] headlamp -> headlamp-envvars (stored secret rejected')"
check "rejected: the new secret is never printed"      no "$(has_line fresh-secret)"

reset_store; jq -c 'del(.OIDC_CLIENT_SECRET)' "$STORE_DIR/headlamp-envvars" > "$STORE_DIR/x" && mv "$STORE_DIR/x" "$STORE_DIR/headlamp-envvars"
PROBE_RC=0; sync_rc
check "missing secret: exits 0"                        0 "$rc"
check "missing secret: rotated without a probe"        "fresh-secret absent" \
    "$(stored .OIDC_CLIENT_SECRET) $([ -e "$STORE_DIR/.probed" ] && echo probed || echo absent)"
check "missing secret: reports why"                    yes "$(has_line '(no stored secret;')"

reset_store; PROBE_RC=2; sync_rc
check "probe fails: exits 0"                           0 "$rc"
check "probe fails: warns, with the reason"            yes "$(has_line 'curl: (7) Failed to connect); not rotating')"
check "probe fails: no rotation"                       "" "$(cat "$STORE_DIR/.api" 2>/dev/null)"
check "probe fails: the secret untouched"              do-not-touch-me "$(stored .OIDC_CLIENT_SECRET)"
PROBE_RC=0

# --mirror-openbao: the consumers read OpenBao's copy, which a restored OpenBao
# can hold apart from a valid store. The re-mirror fixes it; they must restart.
# shellcheck source=scripts/lib/bao-map.sh
. "$HERE/../../lib/bao-map.sh"
MIRROR_OPENBAO=true
mirror_read() { printf '{"OIDC_CLIENT_SECRET":"%s"}' "$MIRROR_SECRET"; }
reset_store; MIRROR_SECRET=dead-secret sync_rc
check "mirror stale: exits 0"                          0 "$rc"
check "mirror stale: reported"                         yes "$(has_line "[stale  ] headlamp -- OpenBao's copy of headlamp-envvars holds another secret, re-mirroring")"
check "mirror stale: consumers restart onto the store's secret" \
    "headlamp-envvars=sha256:$(printf '%s' do-not-touch-me | secret_sha)" "$(cat "$STORE_DIR/.rotated" 2>/dev/null)"
check "mirror stale: no rotation"                      "" "$(cat "$STORE_DIR/.api" 2>/dev/null)"
reset_store; MIRROR_SECRET=do-not-touch-me sync_rc
check "mirror agrees: nothing restarted"               "0 " "$rc $(cat "$STORE_DIR/.rotated" 2>/dev/null)"
MIRROR_OPENBAO=false

# ── the real probe: what ZITADEL's answer means, and the secret off argv ───
load_function probe_client_secret "$SRC"
CURL_RESOLVE=()
CURL_RC=0 CURL_BODY=""
curl() {
    printf '%s\n' "$@" > "$STORE_DIR/.curl-argv"
    local out="" cfg=""
    while [ $# -gt 0 ]; do case "$1" in -o) out="$2"; shift 2 ;; -K) cfg="$2"; shift 2 ;; *) shift ;; esac; done
    cp "$cfg" "$STORE_DIR/.curl-cfg"
    [ "$CURL_RC" -eq 0 ] || { echo "curl: (7) Failed to connect" >&2; return "$CURL_RC"; }
    printf '%s' "$CURL_BODY" > "$out"
    printf 400
}
probe() { rc=0; reason="$(printf "%s" "$1" | probe_client_secret existing-client-id https://headlamp.x/oidc-callback 2>&1)" || rc=$?; }
CURL_BODY='{"error":"invalid_grant","error_description":"invalid code"}'; probe 'we!rd"s\ecret'
check "probe: invalid_grant means the secret is right"  0 "$rc"
check "probe: basic auth from the -K file, both halves form-encoded" \
    'user = "existing-client-id:we%21rd%22s%5Cecret"' "$(cat "$STORE_DIR/.curl-cfg")"
check "probe: the secret is not on argv"                no "$(grep -qF 'we!rd' "$STORE_DIR/.curl-argv" && echo yes || echo no)"
check "probe: a code that cannot exist"                 yes "$(grep -qx 'code=probe-invalid' "$STORE_DIR/.curl-argv" && echo yes || echo no)"
CURL_BODY='{"error":"invalid_client","error_description":"invalid secret"}'; probe s
check "probe: invalid_client means the secret is wrong" 1 "$rc"
CURL_BODY='{"error":"server_error"}'; probe s
check "probe: any other answer cannot tell"             "2 yes" "$rc $(grep -q "HTTP 400, error 'server_error'" <<< "$reason" && echo yes || echo no)"
CURL_RC=7; probe s; CURL_RC=0
check "probe: a network failure cannot tell"            "2 yes" "$rc $(grep -q 'unreachable: curl: (7)' <<< "$reason" && echo yes || echo no)"

exit "$fail"
