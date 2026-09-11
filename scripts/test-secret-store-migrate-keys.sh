#!/usr/bin/env bash
# shellcheck disable=SC2034
# (KEYS is read by the body of migrate_keys(), which is eval'd in from the
# script under test, so static analysis cannot see that use. Same reason as
# test-openbao-new-lineage.sh.)
#
# Which source keys does `secret-store.sh migrate` walk?
#
# WHY. Normally the keys this cluster's ExternalSecrets ask for. But once the
# shared ExternalSecrets were repointed at OpenBao (Stage 2), gcp-0's ask for
# OpenBao paths such as `zitadel/envvars`, which bao_target_for does not map --
# so a cluster-derived walk skips every key and migrates nothing, while
# reporting success. --keys names the managed-store keys explicitly.
#
# migrate_keys() is lifted out of the script, so this tests the code that ships.
set -uo pipefail
cd "$(dirname "$0")/.." || exit
fail=0
check() {
    if [ "$2" = "$3" ]; then printf '  ok   %s\n' "$1"
    else printf '  FAIL %s: expected %q got %q\n' "$1" "$2" "$3"; fail=1; fi
}

body="$(sed -n '/^migrate_keys() {/,/^}/p' scripts/secret-store.sh)"
[ -n "$body" ] || { echo "could not extract migrate_keys() from scripts/secret-store.sh" >&2; exit 1; }
eval "$body"
migrate_source_keys() { printf 'from-the-cluster\n'; }

KEYS=""
check "no --keys: the cluster's ExternalSecrets decide" "from-the-cluster" "$(migrate_keys)"
KEYS="zitadel-envvars,harbor-oidc"
check "commas separate, output sorted" $'harbor-oidc\nzitadel-envvars' "$(migrate_keys)"
KEYS="zitadel-envvars harbor-oidc"
check "spaces separate" $'harbor-oidc\nzitadel-envvars' "$(migrate_keys)"
KEYS="a,, b ,a"
check "blanks dropped, duplicates collapsed" $'a\nb' "$(migrate_keys)"

fn="$(sed -n '/^cmd_migrate() {/,/^}/p' scripts/secret-store.sh)"
if printf '%s' "$fn" | grep -qF 'done <<<"$(migrate_keys)"'; then
    printf '  ok   cmd_migrate walks migrate_keys\n'
else
    printf '  FAIL cmd_migrate must read its keys from migrate_keys\n'; fail=1
fi
if grep -qE '^[[:space:]]+--keys\)[[:space:]]+KEYS="\$2"; shift 2 ;;' scripts/secret-store.sh; then
    printf '  ok   --keys is parsed\n'
else
    printf '  FAIL --keys is not parsed\n'; fail=1
fi

echo
if [ "$fail" -eq 0 ]; then echo "all checks passed"; else echo "FAILURES"; fi
exit "$fail"
