#!/usr/bin/env bash
# shellcheck disable=SC2034
# (file-wide: OPENBAO_URL/FALLBACK_ADDRESS/SNAPSHOT_BUCKET/ROOT_TOKEN_SECRET_NAME
# are read by the body of pre_destroy_snapshot(), which is eval'd in from the
# script under test, so static analysis cannot see those uses.)
#
# Regression test for --fallback-address reaching the GO client, not only curl.
#
# THE BUG THIS EXISTS FOR, measured on the 2026-09-05 teardown.
#
# --fallback-address was implemented by writing a `resolve` entry into
# $CURL_HOME/.curlrc, on the stated assumption that "openbao-snapshot.sh runs the
# actual snapshot through its own curl calls". It does not: the snapshot is
# `bao operator raft snapshot save`, the Go CLI, which never reads a .curlrc.
#
# So the two halves disagreed, and the logs said so plainly while still losing
# the snapshot:
#
#   [WARN] https://bao.priv.aws.ogenki.io:8200 did not answer (HTTP 000);
#          retrying at the fixed address 10.0.15.250.
#   [INFO] Reached OpenBao at 10.0.15.250 presenting bao.priv.aws.ogenki.io:
#          the name is gone, the node is not.
#   Error taking the snapshot: Get ".../v1/sys/storage/raft/snapshot":
#          dial tcp: lookup bao.priv.aws.ogenki.io ...: no such host
#
# The probe went green through the fallback and the snapshot then died on the
# name the probe had just worked around. The node was reachable the whole time,
# which makes this the exact data loss the fallback was added to prevent: the
# operator is pushed to TM_OPENBAO_SKIP_SNAPSHOT=true and discards a snapshot
# that was there for the taking.
#
# The fix hands the Go client the same substitution in the form Go expects --
# the ADDRESS in VAULT_ADDR, the NAME in VAULT_TLS_SERVER_NAME -- so TLS still
# verifies against the hostname. That last part is not optional: the server
# certificate carries no IP SAN by design, so connecting to a bare IP without
# it trades a name-resolution failure for a handshake failure.
#
# pre_destroy_snapshot() is lifted out of the script rather than restated, the
# same technique the zitadel suites use, so this tests the code that ships.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
fail=0
check() { if [ "$2" = "$3" ]; then printf '  ok   %s\n' "$1"
          else printf '  FAIL %s: expected %q got %q\n' "$1" "$2" "$3"; fail=1; fi }

SRC="${OPENBAO_CONFIG_SCRIPT:-$HERE/openbao-config.sh}"
body="$(sed -n '/^pre_destroy_snapshot() {/,/^}/p' "$SRC")"
[ -n "$body" ] || { echo "could not extract pre_destroy_snapshot() from $SRC" >&2; exit 1; }
eval "$body"

log_message() { :; }

# The node answers ONLY at the fixed address, which is the situation the flag
# exists for: the DNS name is gone, the node is not.
NAME_RESOLVES=false
openbao_health_code() {
    # Answers when the name works, or when the fallback resolve is in place.
    if [ "$NAME_RESOLVES" = true ]; then echo 200; return; fi
    if [ -n "${CURL_HOME:-}" ] && [ -f "${CURL_HOME}/.curlrc" ]; then echo 200; else echo 000; fi
}

# Everything after the reachability decision is stubbed: this test is about
# which address and name the snapshot is TOLD to use, not about taking one.
export_snapshot_env() { :; }
secret_read() { echo '{"token":"fake-root-token"}'; }  # pragma: allowlist secret

# The child is the assertion point. Capturing here rather than from an EXIT trap
# is deliberate: the fallback branch installs its own EXIT trap to clean up
# CURL_HOME, which replaces any trap this test sets, so a trap-based capture
# silently records nothing exactly in the case under test.
sh() {
    # `sh <script> save -a <url> ...` — record the -a value and the SNI env.
    while [ $# -gt 0 ]; do
        if [ "$1" = "-a" ]; then printf '%s\n%s\n' "$2" "${VAULT_TLS_SERVER_NAME:-}" > "$OUT"; return 0; fi
        shift
    done
    printf '\n%s\n' "${VAULT_TLS_SERVER_NAME:-}" > "$OUT"
    return 0
}

run_case() {
    unset VAULT_ADDR VAULT_TLS_SERVER_NAME CURL_HOME 2>/dev/null || true
    OPENBAO_URL="https://bao.priv.aws.ogenki.io:8200"
    FALLBACK_ADDRESS="$1"
    SNAPSHOT_BUCKET="test-bucket"
    ROOT_TOKEN_SECRET_NAME=""
    NAME_RESOLVES="${2:-false}"
    : > "$OUT"
    ( pre_destroy_snapshot >/dev/null 2>&1 ) || true
}

OUT="$(mktemp)"
trap 'rm -f "$OUT"' EXIT

echo "== the name is gone, the node answers at the fixed address =="
run_case "10.0.15.250"
url="$(sed -n 1p "$OUT")"; sni="$(sed -n 2p "$OUT")"
check "child is given the ADDRESS"           "https://10.0.15.250:8200" "$url"
check "VAULT_TLS_SERVER_NAME keeps the NAME" "bao.priv.aws.ogenki.io"   "$sni"

echo
echo "== the name resolves: nothing is rewritten, fallback or not =="
run_case "10.0.15.250" true
url="$(sed -n 1p "$OUT")"; sni="$(sed -n 2p "$OUT")"
check "child is given the NAME"  "https://bao.priv.aws.ogenki.io:8200" "$url"
check "no VAULT_TLS_SERVER_NAME" ""                                    "$sni"

echo
echo "== no fallback and the name is gone: refuse, do not snapshot blind =="
run_case "" false
check "child never invoked" "" "$(sed -n 1p "$OUT")"

echo
if [ "$fail" -eq 0 ]; then echo "PASS"; else echo "FAIL"; fi
exit "$fail"
