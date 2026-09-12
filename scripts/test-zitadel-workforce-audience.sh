#!/usr/bin/env bash
#
# The workforce provider's audience is the OIDC CLIENT ID of the app whose token
# is exchanged (headlamp-proxy) -- not the ZITADEL project id.
#
# It was the project id until 2026-09-12, on the reasoning that ZITADEL stamps
# the project id into the `aud` of every token the project issues. It does. But
# the project audience scope makes `aud` MULTI-VALUED, and OIDC Core 3.1.3.7
# then requires `azp` to equal the relying party's client id -- which Google STS
# enforces. `azp` is the client the token was issued TO, never the project, so
# the exchange returned `invalid_grant` on every request from the day it shipped
# while every component reported healthy. This test now pins the corrected
# contract.
#
# reconcile_workforce_audience() closes that loop. What this test protects is
# mostly its SKIP paths: it runs inside a script that configures every OIDC
# consumer, so a misfire here (or a hard failure) would take the rest with it.
#
# The function is LIFTED verbatim out of zitadel-oidc-clients.sh via sed, the
# same technique test-zitadel-oidc-clients-project.sh uses -- the script itself
# is not sourceable, since it parses argv and demands --cluster/--cloud at the
# top of the file. A change there is therefore a change under test. That lift is
# also why the function spells out the app name inline instead of reading a
# module-level constant: anything outside the body is unbound here under set -u.
# WORKFORCE_POOL, APPLY, APP_SUFFIX and the STUB_* values are read ONLY by the
# eval'''d function bodies lifted from the script under test, which shellcheck
# cannot see through. File-wide because they are set at nearly every test case;
# the same directive, for the same reason, as test-zitadel-oidc-clients-project.sh.
# shellcheck disable=SC2034
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
fail=0
check() { if [ "$2" = "$3" ]; then printf '  ok   %s\n' "$1"
          else printf '  FAIL %s: expected %q got %q\n' "$1" "$2" "$3"; fail=1; fi }

SRC="${ZITADEL_OIDC_CLIENTS_SCRIPT:-$HERE/zitadel-oidc-clients.sh}"
# BOTH halves. reconcile_workforce_audience calls reconcile_consumer_audience,
# so lifting only the first gives exit 127 -- which is how this harness caught
# the coupling when the second was added.
for f in reconcile_workforce_audience reconcile_consumer_audience; do
    body="$(sed -n "/^${f}() {/,/^}/p" "$SRC")"
    [ -n "$body" ] || { echo "could not extract ${f}() from $SRC" >&2; exit 1; }
    eval "$body"
done

# Records what the function would have done, so a skip is distinguishable from
# a silent success.
#
# A FILE, not a variable: the function under test is invoked inside $( ), which
# runs it in a subshell, so any variable it sets is lost on return. An earlier
# version of this test used a variable and three of its assertions passed
# vacuously -- they checked that no update happened against a value that could
# never have been set either way.
CALLS="$(mktemp)"
trap 'rm -f "$CALLS"' EXIT
gcloud() {
    printf '%s\n' "$*" >> "$CALLS"
    case "$*" in
        *"providers describe"*) printf '%s' "${STUB_CURRENT_AUDIENCE:-}" ;;
        *"providers update-oidc"*) return "${STUB_UPDATE_RC:-0}" ;;
    esac
}
kubectl() {
    printf 'kubectl %s\n' "$*" >> "$CALLS"
    case "$*" in
        *"get cm"*)    printf '%s' "${STUB_CM_NAME:-configmap/gke-gcp-0-vars}" ;;
        *jsonpath*)    printf '%s' "${STUB_CM_AUDIENCE:-}" ;;
        *patch*)       return "${STUB_PATCH_RC:-0}" ;;
    esac
}
# The ZITADEL side of the lookup. Empty STUB_APP_ID models "the app does not
# exist yet"; empty STUB_CLIENT_ID models an app whose OIDC config ZITADEL
# returned without one. Both must SKIP rather than pin a nonsense audience.
app_id_by_name() {
    printf 'app_id_by_name %s\n' "$*" >> "$CALLS"
    printf '%s' "${STUB_APP_ID-app-1}"
}
app_get() {
    printf 'app_get %s\n' "$*" >> "$CALLS"
    printf '{"app":{"oidcConfig":{"clientId":"%s"}}}' "${STUB_CLIENT_ID-client-abc}"
}
calls() { cat "$CALLS" 2>/dev/null; }
reset_calls() { : > "$CALLS"; }

APP_SUFFIX=""

# ── 1. no workforce pool configured -> do nothing at all ───────────────────
# This is the AWS-only case, and the common one. It must not warn, fail, or
# shell out.
WORKFORCE_POOL=""; APPLY="true"; reset_calls; out="$(reconcile_workforce_audience "proj-123" 2>&1)"; rc=$?
check "no pool: returns success"            "0"  "$rc"
check "no pool: says nothing"               ""   "$out"
check "no pool: never calls gcloud"         ""   "$(calls)"

# ── 2. dry-run project sentinel -> do nothing ──────────────────────────────
WORKFORCE_POOL="ogenki-zitadel"; APPLY="true"; reset_calls; out="$(reconcile_workforce_audience "DRYRUN-PROJECT" 2>&1)"; rc=$?
check "dry-run project: returns success"    "0"  "$rc"
check "dry-run project: never calls gcloud" ""   "$(calls)"

# ── 3. audience already correct -> no update, but still check the other end ─
# THE AUDIENCE IS THE APP CLIENT ID, not the project id: passing "proj-123" as
# the project must still pin "client-abc". If this ever passes with the project
# id again, the 2026-09-12 regression is back.
WORKFORCE_POOL="ogenki-zitadel"; APPLY="true"; reset_calls
STUB_CURRENT_AUDIENCE="client-abc"; STUB_CM_AUDIENCE="proj-123"
out="$(reconcile_workforce_audience "proj-123" 2>&1)"; rc=$?
check "already correct: returns success"    "0"  "$rc"
case "$(calls)" in
    *update-oidc*) check "already correct: does NOT update" "no-update" "updated" ;;
    *)             check "already correct: does NOT update" "no-update" "no-update" ;;
esac
# Reconciling the consumer only after an UPDATE meant a correct provider left
# the ConfigMap unexamined -- the half-fixed state that fails exactly like the
# unfixed one.
case "$(calls)" in
    *kubectl*) check "already correct: still checks the consumer" "checked" "checked" ;;
    *)         check "already correct: still checks the consumer" "checked" "$(calls)" ;;
esac

# ── 4. audience differs, but not --apply -> report only ────────────────────
# The whole script is dry-run by default; this must respect that or a plan
# would mutate the platform.
WORKFORCE_POOL="ogenki-zitadel"; APPLY="false"; reset_calls
STUB_CURRENT_AUDIENCE="old-client"
out="$(reconcile_workforce_audience "proj-123" 2>&1)"
case "$(calls)" in
    *update-oidc*) check "dry-run: does NOT update" "no-update" "updated" ;;
    *)             check "dry-run: does NOT update" "no-update" "no-update" ;;
esac
case "$out" in
    *"old-client -> client-abc"*) check "dry-run: reports the change" "reported" "reported" ;;
    *)                            check "dry-run: reports the change" "reported" "$out" ;;
esac

# ── 5. audience differs under --apply -> update to the APP CLIENT ID ───────
WORKFORCE_POOL="ogenki-zitadel"; APPLY="true"; reset_calls
STUB_CURRENT_AUDIENCE="old-client"
out="$(reconcile_workforce_audience "proj-123" 2>&1)"; rc=$?
check "apply: returns success"              "0"  "$rc"
case "$(calls)" in
    *"update-oidc"*"--client-id=client-abc"*) check "apply: pins the app client id" "updated" "updated" ;;
    *)                                        check "apply: pins the app client id" "updated" "$(calls)" ;;
esac
case "$(calls)" in
    *"--client-id=proj-123"*) check "apply: never pins the project id" "never" "pinned-the-project" ;;
    *)                        check "apply: never pins the project id" "never" "never" ;;
esac

# ── 6. provider does not exist yet -> skip, do not fail the whole sync ─────
# The pool stack may not have been applied yet. Failing here would abort a run
# that still has every OIDC client to configure.
WORKFORCE_POOL="ogenki-zitadel"; APPLY="true"; reset_calls
STUB_CURRENT_AUDIENCE=""
out="$(reconcile_workforce_audience "proj-123" 2>&1)"; rc=$?
check "missing provider: returns success"   "0"  "$rc"
case "$(calls)" in
    *update-oidc*) check "missing provider: does NOT update" "no-update" "updated" ;;
    *)             check "missing provider: does NOT update" "no-update" "no-update" ;;
esac

# ── 7. the update itself fails -> warn, but do not abort the sync ──────────
WORKFORCE_POOL="ogenki-zitadel"; APPLY="true"; reset_calls
STUB_CURRENT_AUDIENCE="old-client"; STUB_UPDATE_RC=1
out="$(reconcile_workforce_audience "proj-123" 2>&1)"; rc=$?
check "update fails: still returns success" "0"  "$rc"
case "$out" in
    *invalid_grant*) check "update fails: names the consequence" "named" "named" ;;
    *)               check "update fails: names the consequence" "named" "$out" ;;
esac
STUB_UPDATE_RC=0

# ── 7b. the app does not exist yet -> skip before touching gcloud ──────────
# A FIRST sync creates headlamp-proxy inside the consumer loop, which is why
# this function runs after it. If it is ever moved back above the loop, this is
# the assertion that catches it: no app, no audience, and no failed run.
WORKFORCE_POOL="ogenki-zitadel"; APPLY="true"; reset_calls
STUB_APP_ID=""; STUB_CURRENT_AUDIENCE="old-client"
out="$(reconcile_workforce_audience "proj-123" 2>&1)"; rc=$?
check "no app yet: returns success"         "0"  "$rc"
case "$(calls)" in
    *update-oidc*) check "no app yet: does NOT update" "no-update" "updated" ;;
    *)             check "no app yet: does NOT update" "no-update" "no-update" ;;
esac
case "$out" in
    *"does not exist yet"*) check "no app yet: says which app" "named" "named" ;;
    *)                      check "no app yet: says which app" "named" "$out" ;;
esac
STUB_APP_ID="app-1"

# ── 7c. the app exists but carries no clientId -> skip, do not pin empty ───
# Pinning an empty client id would make the provider reject every token, which
# is strictly worse than leaving the stale one in place.
WORKFORCE_POOL="ogenki-zitadel"; APPLY="true"; reset_calls
STUB_CLIENT_ID=""; STUB_CURRENT_AUDIENCE="old-client"
out="$(reconcile_workforce_audience "proj-123" 2>&1)"; rc=$?
check "no clientId: returns success"        "0"  "$rc"
case "$(calls)" in
    *update-oidc*) check "no clientId: does NOT update" "no-update" "updated" ;;
    *)             check "no clientId: does NOT update" "no-update" "no-update" ;;
esac
STUB_CLIENT_ID="client-abc"

# ── 7d. a consuming cluster's app is suffixed -> look up the suffixed name ──
# APP_SUFFIX is "-<cluster>" for a cluster that only CONSUMES this directory.
# Looking up the bare name there finds nothing and silently leaves the provider
# pinned to whatever it had.
WORKFORCE_POOL="ogenki-zitadel"; APPLY="true"; reset_calls
APP_SUFFIX="-gcp-0"; STUB_CURRENT_AUDIENCE="old-client"
out="$(reconcile_workforce_audience "proj-123" 2>&1)"
case "$(calls)" in
    *"app_id_by_name proj-123 headlamp-proxy-gcp-0"*) check "suffixed app: looked up by suffixed name" "suffixed" "suffixed" ;;
    *)                                                check "suffixed app: looked up by suffixed name" "suffixed" "$(calls)" ;;
esac
APP_SUFFIX=""

# ── 8. consumer half: scope already correct -> no patch ────────────────────
# Every AWS-primary run lands here, so a false patch would be constant churn.
reset_calls; STUB_CM_AUDIENCE="proj-123"
out="$(reconcile_consumer_audience "proj-123" 2>&1)"; rc=$?
check "consumer, already correct: success"  "0" "$rc"
case "$(calls)" in
    *patch*) check "consumer, already correct: no patch" "no-patch" "patched" ;;
    *)       check "consumer, already correct: no patch" "no-patch" "no-patch" ;;
esac

# ── 9. consumer half: scope stale -> patch it ──────────────────────────────
# THE BUG THIS EXISTS FOR. Without it the pool expects one audience while
# oauth2-proxy keeps requesting another, and every exchange 400s forever
# while every component reports healthy.
reset_calls; STUB_CM_AUDIENCE="old-proj"
out="$(reconcile_consumer_audience "proj-123" 2>&1)"; rc=$?
check "consumer, stale: success"            "0" "$rc"
case "$(calls)" in
    *patch*proj-123*) check "consumer, stale: patches to the new id" "patched" "patched" ;;
    *)                check "consumer, stale: patches to the new id" "patched" "$(calls)" ;;
esac

# ── 10. consumer half: no ConfigMap reachable -> skip, do not fail ─────────
# kubectl may be pointed at the IdP's cluster rather than the consumer's.
reset_calls; STUB_CM_NAME=""; STUB_CM_AUDIENCE=""
out="$(reconcile_consumer_audience "proj-123" 2>&1)"; rc=$?
check "consumer, no ConfigMap: success"     "0" "$rc"
case "$(calls)" in
    *patch*) check "consumer, no ConfigMap: no patch" "no-patch" "patched" ;;
    *)       check "consumer, no ConfigMap: no patch" "no-patch" "no-patch" ;;
esac
STUB_CM_NAME="configmap/gke-gcp-0-vars"

# ── 11. consumer half: patch fails -> warn, do not abort ───────────────────
reset_calls; STUB_CM_AUDIENCE="old-proj"; STUB_PATCH_RC=1
out="$(reconcile_consumer_audience "proj-123" 2>&1)"; rc=$?
check "consumer, patch fails: success"      "0" "$rc"
case "$out" in
    *"wrong audience"*) check "consumer, patch fails: names it" "named" "named" ;;
    *)                  check "consumer, patch fails: names it" "named" "$out" ;;
esac
STUB_PATCH_RC=0

[ "$fail" -eq 0 ] && echo "==> both halves of the audience contract behave" || echo "==> ${fail} failure(s)"
exit "$fail"
