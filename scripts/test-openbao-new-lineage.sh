#!/usr/bin/env bash
#
# May OPENBAO_NEW_LINEAGE=true start a NEW lineage? And is the switch wired where
# it has to be?
#
# WHY THIS MATTERS. GCP's snapshot bucket also holds the AWS mirror, whose every
# object is AWS-sealed. A gcpckms node that finds no object under its own seal
# has no path in: rehydrate refuses the foreign seal, and -- with
# OPENBAO_SNAPSHOT_SKIP_FOREIGN_SEAL=true -- refuses a plain init, correctly,
# because that overwrites a lineage's stored keys on a guess. The switch is the
# operator saying "start this lineage" out loud. Getting its rule wrong in the
# permissive direction discards a lineage's history; in the strict direction a
# GCP-only platform cannot boot at all.
#
# new_lineage_verdict() is lifted out of the script rather than restated, so this
# tests the code that ships. Everything around it in rehydrate needs a live node.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
fail=0
check() {
    if [ "$2" = "$3" ]; then printf '  ok   %s\n' "$1"
    else printf '  FAIL %s: expected %q got %q\n' "$1" "$2" "$3"; fail=1; fi
}
contains() {
    if printf '%s' "$2" | grep -qF -- "$3"; then printf '  ok   %s\n' "$1"
    else printf '  FAIL %s: %q not found\n' "$1" "$3"; fail=1; fi
}
for _h in check contains; do
    declare -F "$_h" >/dev/null || { echo "harness incomplete: $_h() is not defined" >&2; exit 2; }
done

SRC="${OPENBAO_CONFIG_SCRIPT:-$HERE/openbao-config.sh}"
body="$(sed -n '/^new_lineage_verdict() {/,/^}/p' "$SRC")"
[ -n "$body" ] || { echo "could not extract new_lineage_verdict() from $SRC" >&2; exit 1; }
eval "$body"

echo "== the case the switch exists for: a GCP node beside an AWS-only mirror"
check "proceeds" "proceed" "$(new_lineage_verdict gcpckms awskms "" "" "")"

echo "== an object under this node's seal exists: restore it, never start over"
check "refuses" "refuse-own-seal-exists" \
    "$(new_lineage_verdict gcpckms awskms "2026-09-01T000000Z-gcpckms.snap" "" "")"

echo "== the newest object is already restorable here"
check "refuses" "refuse-same-seal" \
    "$(new_lineage_verdict gcpckms gcpckms "2026-09-01T000000Z-gcpckms.snap" "" "")"

echo "== a named object contradicts a new lineage"
check "refuses" "refuse-named-key" \
    "$(new_lineage_verdict gcpckms awskms "" "2026-09-05T092947Z-awskms.snap" "")"

echo "== a legacy object with no seal segment: its seal is UNKNOWN, not 'none' -- refuse"
check "refuses" "refuse-unsealed-object" \
    "$(new_lineage_verdict gcpckms "" "" "" "2026-09-02T041500Z.snap")"

echo "== the newest object is a foreign mirror, but an older legacy object's seal is unknown too"
check "refuses" "refuse-unsealed-object" \
    "$(new_lineage_verdict gcpckms awskms "" "" "2026-09-02T041500Z.snap")"

echo "== wiring inside rehydrate_openbao"
fn="$(sed -n '/^rehydrate_openbao() {/,/^}/p' "$SRC")"
contains "reads the switch" "$fn" 'OPENBAO_NEW_LINEAGE:-false'
contains "asks the verdict with the node's own-seal listing" "$fn" \
    'new_lineage_verdict "$node_seal" "$snap_seal" "$own_latest"'
contains "the call site never combines with a named OPENBAO_SNAPSHOT_KEY" "$fn" \
    'new_lineage_verdict "$node_seal" "$snap_seal" "$own_latest" "${OPENBAO_SNAPSHOT_KEY:-}"'
contains "the call site passes the legacy (unsealed) listing as the 5th argument" "$fn" \
    'new_lineage_verdict "$node_seal" "$snap_seal" "$own_latest" "${OPENBAO_SNAPSHOT_KEY:-}" "$unsealed_latest"'
arm="$(printf '%s\n' "$fn" | sed -n '/^[[:space:]]*proceed)/,/;;/p')"
contains "the proceed arm initialises" "$arm" 'init_openbao'
contains "the proceed arm returns before falling into the seal gate" "$arm" 'return 0'
for v in refuse-named-key refuse-same-seal refuse-own-seal-exists refuse-unsealed-object; do
    varm="$(printf '%s\n' "$fn" | sed -n "/^[[:space:]]*${v})/,/;;/p")"
    contains "the ${v} arm exits non-zero" "$varm" 'exit 1'
done
switch_line=$(printf '%s\n' "$fn" | grep -nF 'OPENBAO_NEW_LINEAGE:-false' | head -1 | cut -d: -f1)
gate_line=$(printf '%s\n' "$fn" | grep -nF '"${OPENBAO_SNAPSHOT_SKIP_FOREIGN_SEAL:-false}" != "true"' | head -1 | cut -d: -f1)
if [ -n "$switch_line" ] && [ -n "$gate_line" ] && [ "$switch_line" -lt "$gate_line" ]; then
    printf '  ok   the switch is consulted before the foreign-seal refusal\n'
else
    printf '  FAIL the switch must be consulted before the foreign-seal refusal (switch=%s gate=%s)\n' "$switch_line" "$gate_line"; fail=1
fi
cannot_list_line=$(printf '%s\n' "$fn" | grep -nF 'Refusing to initialise: cannot prove' | head -1 | cut -d: -f1)
if [ -n "$switch_line" ] && [ -n "$cannot_list_line" ] && [ "$cannot_list_line" -lt "$switch_line" ]; then
    printf '  ok   the switch comes after the cannot-list refusal\n'
else
    printf '  FAIL the switch must come after the cannot-list refusal (cannot_list=%s switch=%s)\n' "$cannot_list_line" "$switch_line"; fail=1
fi
recovery_preflight_line=$(printf '%s\n' "$fn" | grep -nF 'secret_read "$RECOVERY_KEYS_SECRET_NAME"' | head -1 | cut -d: -f1)
if [ -n "$switch_line" ] && [ -n "$recovery_preflight_line" ] && [ "$recovery_preflight_line" -lt "$switch_line" ]; then
    printf '  ok   the switch comes after the recovery-keys pre-flight\n'
else
    printf '  FAIL the switch must come after the recovery-keys pre-flight (preflight=%s switch=%s)\n' "$recovery_preflight_line" "$switch_line"; fail=1
fi

echo "== documented"
usage_fn="$(sed -n '/^usage() {/,/^}/p' "$SRC")"
contains "usage names the switch" "$usage_fn" 'OPENBAO_NEW_LINEAGE=true'

echo
if [ "$fail" -eq 0 ]; then echo "all checks passed"; else echo "FAILURES"; fi
exit "$fail"
