#!/usr/bin/env bash
# shellcheck disable=SC2034
# (KEYS and KEYS_SET are read by the body of migrate_keys(), which is eval'd
# in from the script under test, so static analysis cannot see that use. Same
# reason as test-openbao-new-lineage.sh.)
#
# Which source keys does `secret-store.sh migrate` walk?
#
# WHY. Normally the keys this cluster's ExternalSecrets ask for. But once the
# shared ExternalSecrets were repointed at OpenBao (Stage 2), gcp-0's ask for
# OpenBao paths such as `zitadel/envvars`, which bao_target_for does not map --
# so a cluster-derived walk skips every key and migrates nothing, while
# reporting success. --keys names the managed-store keys explicitly.
#
# `--keys ""` (or a KEYS_SET but blank/all-separators list) is NOT "no --keys":
# an operator interpolating an unset or empty shell variable into --keys would
# otherwise silently fall back to the same cluster-derived walk that gcp-0's
# migrate --keys is meant to bypass, and still report success. So --keys given
# but resolving to zero keys is refused (exit 2), never a fallback.
#
# migrate_keys() is lifted out of the script, so this tests the code that ships.
set -uo pipefail
cd "$(dirname "$0")/.." || exit
fail=0
check() {
    if [ "$2" = "$3" ]; then printf '  ok   %s\n' "$1"
    else printf '  FAIL %s: expected %q got %q\n' "$1" "$2" "$3"; fail=1; fi
}

# check_refuses <name>: asserts migrate_keys(), called with the KEYS/KEYS_SET
# already set by the caller, exits 2, prints nothing on stdout, and explains
# itself on stderr.
check_refuses() {
    local name="$1" out err rc
    out="$(migrate_keys 2>/dev/null)"; rc=$?
    err="$(migrate_keys 2>&1 1>/dev/null)"
    if [ "$rc" -eq 2 ] && [ -z "$out" ] && printf '%s' "$err" | grep -qF "refusing rather than falling back"; then
        printf '  ok   %s\n' "$name"
    else
        printf '  FAIL %s: rc=%s out=%q err=%q\n' "$name" "$rc" "$out" "$err"
        fail=1
    fi
}

body="$(sed -n '/^migrate_keys() {/,/^}/p' scripts/secret-store.sh)"
[ -n "$body" ] || { echo "could not extract migrate_keys() from scripts/secret-store.sh" >&2; exit 1; }
eval "$body"
migrate_source_keys() { printf 'from-the-cluster\n'; }

KEYS_SET="false"
KEYS=""
check "no --keys: the cluster's ExternalSecrets decide" "from-the-cluster" "$(migrate_keys)"

KEYS_SET="true"
KEYS="zitadel-envvars,harbor-oidc"
check "commas separate, output sorted" $'harbor-oidc\nzitadel-envvars' "$(migrate_keys)"
KEYS_SET="true"
KEYS="zitadel-envvars harbor-oidc"
check "spaces separate" $'harbor-oidc\nzitadel-envvars' "$(migrate_keys)"
KEYS_SET="true"
KEYS="a,, b ,a"
check "blanks dropped, duplicates collapsed" $'a\nb' "$(migrate_keys)"

KEYS_SET="true"
KEYS=""
check_refuses "--keys \"\" refuses rather than falling back to the cluster"
KEYS_SET="true"
KEYS="  , ,"
check_refuses "--keys of only separators/blanks refuses"

fn="$(sed -n '/^cmd_migrate() {/,/^}/p' scripts/secret-store.sh)"
if printf '%s' "$fn" | grep -qF 'keys="$(migrate_keys)" || exit 2'; then
    printf '  ok   cmd_migrate captures migrate_keys and exits 2 on failure\n'
else
    printf '  FAIL cmd_migrate must capture migrate_keys and exit 2 on failure\n'; fail=1
fi
if printf '%s' "$fn" | grep -qF 'done <<<"$keys"'; then
    printf '  ok   cmd_migrate loops over the captured keys\n'
else
    printf '  FAIL cmd_migrate must loop over the captured $keys\n'; fail=1
fi
if printf '%s' "$fn" | grep -qF 'migrate_source_keys'; then
    printf '  FAIL cmd_migrate must not call migrate_source_keys directly\n'; fail=1
else
    printf '  ok   cmd_migrate does not call migrate_source_keys directly\n'
fi
if grep -qE '^[[:space:]]+--keys\)[[:space:]]+KEYS="\$2"; KEYS_SET="true"; shift 2 ;;' scripts/secret-store.sh; then
    printf '  ok   --keys is parsed and marks KEYS_SET\n'
else
    printf '  FAIL --keys is not parsed correctly\n'; fail=1
fi

echo
if [ "$fail" -eq 0 ]; then echo "all checks passed"; else echo "FAILURES"; fi
exit "$fail"
