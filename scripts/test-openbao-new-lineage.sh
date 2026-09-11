#!/usr/bin/env bash
# shellcheck disable=SC2034
# (file-wide: CLOUD and SNAPSHOT_BUCKET are read by the body of
# latest_unsealed_snapshot(), which is eval'd in from the script under test, so
# static analysis cannot see those uses. Same reason as
# test-openbao-fallback-address.sh.)
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
absent() {
    if printf '%s' "$2" | grep -qF -- "$3"; then printf '  FAIL %s: %q unexpectedly present\n' "$1" "$3"; fail=1
    else printf '  ok   %s\n' "$1"; fi
}
for _h in check contains absent; do
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

echo "== the newest object itself has no parseable seal (N2): unknown, not none -- refuse"
check "refuses" "refuse-unsealed-object" \
    "$(new_lineage_verdict gcpckms "" "" "" "")"

echo "== wiring inside rehydrate_openbao"
fn="$(sed -n '/^rehydrate_openbao() {/,/^}/p' "$SRC")"
contains "reads the switch" "$fn" 'OPENBAO_NEW_LINEAGE:-false'
contains "asks the verdict with the node's own-seal listing" "$fn" \
    'new_lineage_verdict "$node_seal" "$snap_seal" "$own_latest"'
contains "the call site never combines with a named OPENBAO_SNAPSHOT_KEY" "$fn" \
    'new_lineage_verdict "$node_seal" "$snap_seal" "$own_latest" "${OPENBAO_SNAPSHOT_KEY:-}"'
contains "the call site passes the legacy (unsealed) listing as the 5th argument" "$fn" \
    'new_lineage_verdict "$node_seal" "$snap_seal" "$own_latest" "${OPENBAO_SNAPSHOT_KEY:-}" "$unsealed_latest"'
contains "unsealed_latest is computed via latest_unsealed_snapshot" "$fn" \
    'unsealed_latest=$(latest_unsealed_snapshot)'
absent "latest_snapshot_sealed \"\" no longer appears (N2: it only caught the legacy shape)" "$fn" \
    'latest_snapshot_sealed ""'
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

echo "== latest_unsealed_snapshot(): what the switch's pre-flight actually lists"
# N1: the I1 fix (a legacy/manual snapshot blocking a new lineage) changed THIS
# function. Nothing exercised it directly -- the verdict tests above are all
# pure-function tests that never call it, so reverting its filter, or passing
# the wrong argument at the call site, left every test green. Lifted the same
# way new_lineage_verdict() is: sed out the function (and the SNAP_NAME_RE it
# depends on) from the script that ships, eval, drive it directly.
lat_body="$(sed -n '/^latest_unsealed_snapshot() {/,/^}/p' "$SRC")"
[ -n "$lat_body" ] || { echo "could not extract latest_unsealed_snapshot() from $SRC" >&2; exit 1; }
snap_re_line="$(grep -E '^SNAP_NAME_RE=' "$SRC" | head -1)"
[ -n "$snap_re_line" ] || { echo "could not extract SNAP_NAME_RE from $SRC" >&2; exit 1; }
log_err() { :; }  # the function under test calls this on a listing failure; silence it
eval "$snap_re_line"
eval "$lat_body"
declare -f latest_unsealed_snapshot >/dev/null || {
    echo "latest_unsealed_snapshot did not define after eval" >&2; exit 1; }

echo "-- GCP branch (gcp_gcloud storage ls gs://bucket/, non-recursive) --"
CLOUD="gcp"
SNAPSHOT_BUCKET="test"
GCLOUD_RC=0
GCLOUD_LISTING=''
gcp_gcloud() {
    if [ "$GCLOUD_RC" != 0 ]; then return 1; fi
    printf '%s\n' "$GCLOUD_LISTING"
}

GCLOUD_LISTING='gs://test/2026-09-05T092947Z-awskms.snap'
check "only sealed (AWS-mirror) objects present: nothing unsealed" "" "$(latest_unsealed_snapshot)"

GCLOUD_LISTING=$'gs://test/2026-09-05T092947Z-awskms.snap\ngs://test/README.md'
check "a non-.snap top-level object is not a snapshot, so it never blocks" "" "$(latest_unsealed_snapshot)"

GCLOUD_LISTING=$'gs://test/2026-09-05T092947Z-awskms.snap\ngs://test/manual-backup.snap'
check "a hand-named object (manual-backup.snap) counts as unsealed" \
    "manual-backup.snap" "$(latest_unsealed_snapshot)"

GCLOUD_LISTING=$'gs://test/2026-09-05T092947Z-awskms.snap\ngs://test/2026-09-02T041500Z.snap'
check "a legacy <ts>.snap object (no seal segment) counts as unsealed" \
    "2026-09-02T041500Z.snap" "$(latest_unsealed_snapshot)"

GCLOUD_LISTING='gs://test/2026-09-05T092947Z-gcpckms.snap'
check "a SEALED name is not \"unsealed\"" "" "$(latest_unsealed_snapshot)"

# A real non-recursive `gcloud storage ls` never prints the nested key under a
# prefix -- only the prefix marker itself (a trailing-slash "directory" line).
# So "moved aside" is invisible here by construction, the same way it already
# is for latest_snapshot_sealed(); the fixture below is what gcloud would
# actually emit for a bucket holding both a top-level mirror object and
# something moved aside under aside/.
GCLOUD_LISTING=$'gs://test/2026-09-05T092947Z-awskms.snap\ngs://test/aside/'
check "an object moved aside under a prefix is invisible (top-level only)" \
    "" "$(latest_unsealed_snapshot)"

GCLOUD_RC=1
latest_unsealed_snapshot >/dev/null; rc=$?
check "a GCP listing failure returns non-zero, not an empty (selectable) result" "1" "$rc"
GCLOUD_RC=0

echo "-- AWS branch (s3api list-objects-v2, newest by LastModified) --"
CLOUD="aws"
AWS_RC=0
AWS_JSON=''
fixture_aws_cmd() {
    if [ "$AWS_RC" != 0 ]; then return 1; fi
    printf '%s' "$AWS_JSON"
}
get_aws_cmd() { printf 'fixture_aws_cmd'; }

# Newest by LastModified must win, NOT lexical order (2026-09-06... sorts
# before manual-backup.snap lexically) -- and the prefixed key must be
# excluded even though it is the most recently modified of all four.
AWS_JSON='{"Contents":[
  {"Key":"2026-09-05T092947Z-awskms.snap","LastModified":"2026-09-05T09:29:47.000Z"},
  {"Key":"manual-backup.snap","LastModified":"2026-09-01T00:00:00.000Z"},
  {"Key":"2026-09-06T041500Z.snap","LastModified":"2026-09-06T04:15:00.000Z"},
  {"Key":"aside/2026-09-02T041500Z.snap","LastModified":"2026-09-07T00:00:00.000Z"},
  {"Key":"README.md","LastModified":"2026-09-08T00:00:00.000Z"}
]}'
check "the newest UNSEALED key by LastModified wins; sealed and prefixed keys excluded" \
    "2026-09-06T041500Z.snap" "$(latest_unsealed_snapshot)"

AWS_RC=1
latest_unsealed_snapshot >/dev/null; rc=$?
check "an AWS listing failure returns non-zero too" "1" "$rc"
AWS_RC=0

echo "== documented"
usage_fn="$(sed -n '/^usage() {/,/^}/p' "$SRC")"
contains "usage names the switch" "$usage_fn" 'OPENBAO_NEW_LINEAGE=true'

echo
if [ "$fail" -eq 0 ]; then echo "all checks passed"; else echo "FAILURES"; fi
exit "$fail"
