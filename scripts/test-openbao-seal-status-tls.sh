#!/usr/bin/env bash
# shellcheck disable=SC2034
# (file-wide: VAULT_ADDR/VAULT_CACERT/VAULT_TLS_SERVER_NAME/VAULT_SKIP_VERIFY are
# read by the body of seal_status_raw(), which is eval'd in from the script under
# test, so static analysis cannot see those uses.)
#
# Regression test: the seal-status probe must follow --fallback-address.
#
# THE BUG THIS EXISTS FOR, measured on the 2026-09-08 teardown.
#
# A destroy removes the Route53 record before the reverse walk reaches OpenBao,
# so it arrives with the name gone and the node still up -- exactly what
# --fallback-address is for. It engaged correctly, and then the seal read went to
# the bare IP:
#
#   [WARN] https://bao.priv.aws.ogenki.io:8200 did not answer (HTTP 000);
#          retrying at the fixed address 10.0.15.250.
#   [INFO] Reached OpenBao at 10.0.15.250 presenting bao.priv.aws.ogenki.io:
#          the name is gone, the node is not.
#   ERROR: could not read https://10.0.15.250:8200/v1/sys/seal-status.
#
# The certificate carries no IP SAN by design, so that is a TLS hostname
# mismatch, not an unreachable node. pre_destroy_snapshot() refused, the teardown
# stopped with a node still billing, and the documented escape
# (TM_OPENBAO_SKIP_SNAPSHOT=true) would have discarded a snapshot that was
# obtainable the whole time -- the exact data loss the fallback prevents.
#
# The parent's $CURL_HOME/.curlrc does not cover it: it holds
# `resolve = <name>:<port>:<address>`, which only fires when curl looks up the
# NAME, and the parent has already rewritten VAULT_ADDR to the ADDRESS.
#
# This asserts the ARGUMENTS, not a live call: what matters is that curl is told
# to ask for the name and pin it to the address. A stub captures them.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
fail=0
check() {
    if [ "$2" = "$3" ]; then printf '  ok   %s\n' "$1"
    else printf '  FAIL %s:\n       expected %q\n       got      %q\n' "$1" "$2" "$3"; fail=1; fi
}
contains() {
    if printf '%s' "$2" | grep -qF -- "$3"; then printf '  ok   %s\n' "$1"
    else printf '  FAIL %s: %q not in %q\n' "$1" "$3" "$2"; fail=1; fi
}
absent() {
    if printf '%s' "$2" | grep -qF -- "$3"; then printf '  FAIL %s: %q unexpectedly in %q\n' "$1" "$3" "$2"; fail=1
    else printf '  ok   %s\n' "$1"; fi
}

SRC="${OPENBAO_SNAPSHOT_SCRIPT:-$HERE/openbao-snapshot.sh}"
body="$(sed -n '/^seal_status_raw() {/,/^}/p' "$SRC")"
[ -n "$body" ] || { echo "could not extract seal_status_raw() from $SRC" >&2; exit 1; }
eval "$body"

# The assertion point: record what curl was asked to do, run nothing.
curl() { printf '%s\n' "$*"; }

NAME=bao.priv.aws.ogenki.io
IP=10.0.15.250

echo "== the fallback case: address in VAULT_ADDR, name in VAULT_TLS_SERVER_NAME"
VAULT_ADDR="https://${IP}:8200"
VAULT_TLS_SERVER_NAME="$NAME"
VAULT_CACERT=/tmp/ca.pem
VAULT_SKIP_VERIFY=""
out=$(seal_status_raw)
contains "asks for the NAME, not the address" "$out" "https://${NAME}:8200/v1/sys/seal-status"
contains "pins the name to the address"       "$out" "--resolve ${NAME}:8200:${IP}"
absent   "does not request the bare IP URL"   "$out" "https://${IP}:8200/v1/sys/seal-status"
contains "still presents the CA"              "$out" "--cacert /tmp/ca.pem"

echo
echo "== the ordinary case: no fallback, so nothing changes"
VAULT_ADDR="https://${NAME}:8200"
VAULT_TLS_SERVER_NAME=""
out=$(seal_status_raw)
contains "uses VAULT_ADDR as given" "$out" "https://${NAME}:8200/v1/sys/seal-status"
absent   "adds no --resolve"        "$out" "--resolve"

echo
echo "== name set but equal to the address: still no --resolve"
VAULT_ADDR="https://${NAME}:8200"
VAULT_TLS_SERVER_NAME="$NAME"
out=$(seal_status_raw)
absent "no pointless --resolve" "$out" "--resolve"

echo
echo "== a non-default port is carried through"
VAULT_ADDR="https://${IP}:9200"
VAULT_TLS_SERVER_NAME="$NAME"
out=$(seal_status_raw)
contains "port preserved in the URL"     "$out" "https://${NAME}:9200/v1/sys/seal-status"
contains "port preserved in --resolve"   "$out" "--resolve ${NAME}:9200:${IP}"

echo
echo "== VAULT_SKIP_VERIFY still reaches curl alongside the resolve"
VAULT_ADDR="https://${IP}:8200"
VAULT_TLS_SERVER_NAME="$NAME"
VAULT_SKIP_VERIFY=true
out=$(seal_status_raw)
contains "keeps -k"        "$out" "-k"
contains "keeps --resolve" "$out" "--resolve ${NAME}:8200:${IP}"

echo
echo "== no CA and no skip: bare call, no empty arguments"
VAULT_ADDR="https://${NAME}:8200"
VAULT_TLS_SERVER_NAME=""
VAULT_CACERT=""
VAULT_SKIP_VERIFY=""
out=$(seal_status_raw)
check "exactly -sS and the URL, no empty args" "-sS https://${NAME}:8200/v1/sys/seal-status" "$out"

echo
if [ "$fail" -eq 0 ]; then echo "all checks passed"; else echo "FAILURES"; fi
exit "$fail"
