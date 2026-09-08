#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2329
# (file-wide, and for the same reason test-openbao-fallback-address.sh carries
# the first of these: ROOT_TOKEN_SECRET_NAME/SECRET_PAYLOAD/SECRET_RC are read,
# and secret_read() is called, only from the body of stored_root_token_works(),
# which is eval'd in from the script under test. Static analysis cannot see
# across the eval, so it reports every one of them as dead.)
#
# Offline tests for stored_root_token_works() in openbao-config.sh.
#
# WHY THIS EXISTS. Two branches now decide, from this one function's answer,
# whether a deploy tells the operator "your node restored correctly, continue"
# or "destroy the cluster with TM_OPENBAO_SKIP_SNAPSHOT=true". The second of
# those discards every write since the restore and suppresses the pre-destroy
# snapshot, so there is nothing to go back to. A wrong answer here is data loss,
# and the two callers are only reachable on a real cluster in a state that takes
# a full bootstrap to produce -- which is exactly how the bug these branches
# replace shipped: the claim was asserted in prose and never executed.
#
# So the function is driven directly, offline. It is lifted out of the script
# rather than restated (the technique the fallback-address and zitadel suites
# use) so this tests the code that ships.
#
# The failure mode being guarded is asymmetric and the tests are weighted for
# it: a FALSE POSITIVE -- claiming the lineage's token works when it does not --
# waves through a genuinely stranded node, but a FALSE NEGATIVE sends a
# correctly restored node to be destroyed. Every "must return 1" case below is
# therefore a case where returning 0 would be the dangerous direction, and the
# single "must return 0" case is pinned down to the exact argv and environment.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
fail=0
check() { if [ "$2" = "$3" ]; then printf '  ok   %s\n' "$1"
          else printf '  FAIL %s: expected %q got %q\n' "$1" "$2" "$3"; fail=1; fi }

SRC="${OPENBAO_CONFIG_SCRIPT:-$HERE/openbao-config.sh}"
body="$(sed -n '/^stored_root_token_works() {/,/^}/p' "$SRC")"
[ -n "$body" ] || {
    echo "could not extract stored_root_token_works() from $SRC" >&2
    echo "(renamed or reformatted? this suite asserts nothing if it cannot find it)" >&2
    exit 1
}
eval "$body"
# An eval that silently produced no function would let every case below "pass".
declare -f stored_root_token_works >/dev/null || {
    echo "stored_root_token_works did not define after eval" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"

# `bao` stub. Records the token it was handed IN THE ENVIRONMENT and its full
# argv, so the success case can assert both what it received and what it did
# not. Exits per $TMP/bao.rc, which each case sets.
cat > "$TMP/bin/bao" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "${VAULT_TOKEN-<unset>}" > "$BAO_ENV_LOG"
printf '%s\n' "$*" > "$BAO_ARGV_LOG"
exit "$(cat "$BAO_RC")"
STUB
chmod +x "$TMP/bin/bao"
export PATH="$TMP/bin:$PATH"
export BAO_ENV_LOG="$TMP/bao.env" BAO_ARGV_LOG="$TMP/bao.argv" BAO_RC="$TMP/bao.rc"

# Each case sets SECRET_PAYLOAD / SECRET_RC; secret_read replays them and
# records that it ran, so "never called" is testable rather than assumed.
secret_read() {
    printf 'called\n' >> "$TMP/secret_read.calls"
    [ "${SECRET_RC:-0}" = 0 ] || return "${SECRET_RC}"
    printf '%s' "${SECRET_PAYLOAD-}"
}

reset() {
    : > "$TMP/secret_read.calls"; rm -f "$TMP/bao.env" "$TMP/bao.argv"
    echo 0 > "$BAO_RC"
    ROOT_TOKEN_SECRET_NAME="openbao/cloud-native-ref/root-token"  # pragma: allowlist secret
    SECRET_PAYLOAD=''; SECRET_RC=0
}
run() { stored_root_token_works; echo $?; }
calls() { wc -l < "$TMP/secret_read.calls" | tr -d ' '; }

echo "== the secret name is unset: refuse without calling anything"
reset; ROOT_TOKEN_SECRET_NAME=""
check "returns 1"                    1 "$(run)"
check "secret_read never called"     0 "$(calls)"
check "bao never invoked"            "absent" "$([ -f "$TMP/bao.argv" ] && echo present || echo absent)"

echo "== the secret cannot be read (deleted, denied, wrong region)"
reset; SECRET_RC=1
check "returns 1"                    1 "$(run)"
check "bao never invoked"            "absent" "$([ -f "$TMP/bao.argv" ] && echo present || echo absent)"

echo "== the secret is not JSON"
reset; SECRET_PAYLOAD='not-json-at-all'  # pragma: allowlist secret
check "returns 1"                    1 "$(run)"
check "bao never invoked"            "absent" "$([ -f "$TMP/bao.argv" ] && echo present || echo absent)"

echo "== the secret is JSON but carries no .token key"
reset; SECRET_PAYLOAD='{"recovery_keys":["a","b"]}'
check "returns 1"                    1 "$(run)"
check "bao never invoked"            "absent" "$([ -f "$TMP/bao.argv" ] && echo present || echo absent)"

echo "== .token is present but empty"
reset; SECRET_PAYLOAD='{"token":""}'
check "returns 1"                    1 "$(run)"
check "bao never invoked"            "absent" "$([ -f "$TMP/bao.argv" ] && echo present || echo absent)"

echo "== .token is JSON null"
reset; SECRET_PAYLOAD='{"token":null}'
check "returns 1"                    1 "$(run)"
check "bao never invoked"            "absent" "$([ -f "$TMP/bao.argv" ] && echo present || echo absent)"

echo "== a real token the node REJECTS -- the genuinely stranded node"
reset; SECRET_PAYLOAD='{"token":"hvs.stale"}'; echo 2 > "$BAO_RC"  # pragma: allowlist secret
check "returns 1"                    1 "$(run)"
check "bao was actually consulted"   "token lookup" "$(cat "$TMP/bao.argv")"

echo "== a real token the node ACCEPTS -- restored, snapshot predates the PKI"
reset; SECRET_PAYLOAD='{"token":"hvs.good"}'  # pragma: allowlist secret
check "returns 0"                    0 "$(run)"
check "secret_read called once"      1 "$(calls)"
check "bao token lookup, nothing more" "token lookup" "$(cat "$TMP/bao.argv")"
check "token reached bao by ENV"     "hvs.good" "$(cat "$TMP/bao.env")"

echo "== the token never lands on bao's argv"
# Same class of leak scripts/test-no-secret-argv.sh guards repo-wide: anything
# on argv is readable via /proc/<pid>/cmdline by any process on the box for as
# long as the command runs. VAULT_TOKEN= as a command prefix keeps it in the
# environment, which is per-process.
reset; SECRET_PAYLOAD='{"token":"hvs.secret-value"}'  # pragma: allowlist secret
run > /dev/null
check "argv carries no token"        "clean" \
    "$(grep -q 'hvs.secret-value' "$TMP/bao.argv" && echo LEAKED || echo clean)"

echo "== the caller's VAULT_TOKEN is not clobbered"
# Both callers run mid-deploy; a probe that exported VAULT_TOKEN would silently
# re-authenticate everything after it as root.
reset; SECRET_PAYLOAD='{"token":"hvs.probe"}'  # pragma: allowlist secret
VAULT_TOKEN="hvs.caller"  # pragma: allowlist secret
run > /dev/null
check "VAULT_TOKEN unchanged after"  "hvs.caller" "${VAULT_TOKEN}"

echo
if [ "$fail" -eq 0 ]; then echo "all checks passed"; else echo "FAILURES"; fi
exit "$fail"
