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
# grant_admin_role/app_set_redirect do nothing, and app_id_by_name/
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
    if [ -n "$body" ]; then
        eval "$body"
    fi
}

SRC="${ZITADEL_OIDC_CLIENTS_SCRIPT:-$HERE/zitadel-oidc-clients.sh}"
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
grant_admin_role() { :; }
app_set_redirect() { :; }
app_id_by_name() { echo "app-1"; }
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
store_exists() { [ -f "$STORE_DIR/$1" ]; }
store_read()   { cat "$STORE_DIR/$1" 2>/dev/null || true; }
store_write()  { cat > "$STORE_DIR/$1"; }

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
( set -o errexit -o nounset -o pipefail; cmd_sync ) > "$OUT_FILE" 2>&1 || true
out="$(cat "$OUT_FILE")"
after="$(store_read headlamp-envvars)"

check "converge: OIDC_SCOPES gains groups"     "profile,email,groups" "$(jq -r '.OIDC_SCOPES' <<< "$after")"
check "converge: client secret untouched"      "do-not-touch-me"      "$(jq -r '.OIDC_CLIENT_SECRET' <<< "$after")"
check "converge: client id still correct"      "existing-client-id"   "$(jq -r '.OIDC_CLIENT_ID' <<< "$after")"

case "$out" in
    *"[converged] headlamp"*) printf '  ok   converge: reported in the run output\n' ;;
    *) printf '  FAIL converge: no [converged] line in output\n'; fail=1 ;;
esac
case "$out" in
    *"converged: 1"*) printf '  ok   converge: counted in the summary line\n' ;;
    *) printf '  FAIL converge: summary line does not show converged: 1\n'; fail=1 ;;
esac

# ── second run: idempotent -- already converged, nothing written again ─────
( set -o errexit -o nounset -o pipefail; cmd_sync ) > "$OUT_FILE" 2>&1 || true
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

exit "$fail"
