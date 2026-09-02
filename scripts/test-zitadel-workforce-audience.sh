#!/usr/bin/env bash
#
# The workforce provider's audience is the ZITADEL PROJECT id. That value is
# committable while AWS is primary -- its ZITADEL restores from a seed and keeps
# its ids -- but a GCP-primary bootstrap mints a new instance with a generated
# id, so the committed value is wrong and the failure is
# `token exchange 400: invalid_grant` with every component reporting healthy.
#
# reconcile_workforce_audience() closes that loop. What this test protects is
# mostly its SKIP paths: it runs inside a script that configures every OIDC
# consumer, so a misfire here (or a hard failure) would take the rest with it.
#
# The function is LIFTED verbatim out of zitadel-oidc-clients.sh via sed, the
# same technique test-zitadel-oidc-clients-project.sh uses -- the script itself
# is not sourceable, since it parses argv and demands --cluster/--cloud at the
# top of the file. A change there is therefore a change under test.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
fail=0
check() { if [ "$2" = "$3" ]; then printf '  ok   %s\n' "$1"
          else printf '  FAIL %s: expected %q got %q\n' "$1" "$2" "$3"; fail=1; fi }

SRC="${ZITADEL_OIDC_CLIENTS_SCRIPT:-$HERE/zitadel-oidc-clients.sh}"
body="$(sed -n '/^reconcile_workforce_audience() {/,/^}/p' "$SRC")"
[ -n "$body" ] || { echo "could not extract reconcile_workforce_audience() from $SRC" >&2; exit 1; }
eval "$body"

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
calls() { cat "$CALLS" 2>/dev/null; }
reset_calls() { : > "$CALLS"; }

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

# ── 3. audience already correct -> no update ───────────────────────────────
WORKFORCE_POOL="ogenki-zitadel"; APPLY="true"; reset_calls
STUB_CURRENT_AUDIENCE="proj-123"
out="$(reconcile_workforce_audience "proj-123" 2>&1)"; rc=$?
check "already correct: returns success"    "0"  "$rc"
case "$(calls)" in
    *update-oidc*) check "already correct: does NOT update" "no-update" "updated" ;;
    *)             check "already correct: does NOT update" "no-update" "no-update" ;;
esac

# ── 4. audience differs, but not --apply -> report only ────────────────────
# The whole script is dry-run by default; this must respect that or a plan
# would mutate the platform.
WORKFORCE_POOL="ogenki-zitadel"; APPLY="false"; reset_calls
STUB_CURRENT_AUDIENCE="old-proj"
out="$(reconcile_workforce_audience "proj-123" 2>&1)"
case "$(calls)" in
    *update-oidc*) check "dry-run: does NOT update" "no-update" "updated" ;;
    *)             check "dry-run: does NOT update" "no-update" "no-update" ;;
esac
case "$out" in
    *"old-proj -> proj-123"*) check "dry-run: reports the change" "reported" "reported" ;;
    *)                        check "dry-run: reports the change" "reported" "$out" ;;
esac

# ── 5. audience differs under --apply -> update ────────────────────────────
WORKFORCE_POOL="ogenki-zitadel"; APPLY="true"; reset_calls
STUB_CURRENT_AUDIENCE="old-proj"
out="$(reconcile_workforce_audience "proj-123" 2>&1)"; rc=$?
check "apply: returns success"              "0"  "$rc"
case "$(calls)" in
    *"update-oidc"*"--client-id=proj-123"*) check "apply: updates to the new id" "updated" "updated" ;;
    *)                                      check "apply: updates to the new id" "updated" "$(calls)" ;;
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
STUB_CURRENT_AUDIENCE="old-proj"; STUB_UPDATE_RC=1
out="$(reconcile_workforce_audience "proj-123" 2>&1)"; rc=$?
check "update fails: still returns success" "0"  "$rc"
case "$out" in
    *invalid_grant*) check "update fails: names the consequence" "named" "named" ;;
    *)               check "update fails: names the consequence" "named" "$out" ;;
esac

[ "$fail" -eq 0 ] && echo "==> reconcile_workforce_audience behaves" || echo "==> ${fail} failure(s)"
exit "$fail"
