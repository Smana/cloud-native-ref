#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2329
# (file-wide: OPENBAO_URL/VAULT_CACERT/HTTP_CODE/PEM_BODY are read, and curl()
# and log_message() are called, only from the body of verify_pki_present(),
# which is eval'd in from the script under test. Static analysis cannot see
# across the eval and reports all of them as dead.)
#
# Contract tests for verify_pki_present()'s THREE return codes.
#
# WHY THIS EXISTS. The function used to answer 0 or 1, and two callers in
# rehydrate_openbao() acted on "1" as though it meant "no PKI mount yet". It
# does not. It also means unreachable, sealed, non-2xx, not-a-certificate, and
# -- the one that matters -- an issuer that parses perfectly but chains to a
# DIFFERENT root than this lineage's.
#
# That last case is a node full of the WRONG lineage's data, and it is invisible
# to every other signal: the node is up, unsealed, serving a valid certificate,
# and the lineage's stored root token authenticates against it, because the
# token store restored fine and it is the ROOT that is wrong. A caller reading
# "1" as "predates the PKI" waves it through; one reading it as "empty node"
# advises destroying it with the pre-destroy snapshot suppressed. Opposite
# directions, same missing distinction, both data loss.
#
# So 404 now returns 2 and everything else returns 1, and this suite pins that
# down with REAL certificates rather than stubbed openssl -- the dangerous case
# is precisely the one where the bytes are a valid certificate, so a stub that
# says "valid" or "invalid" would be assuming the answer under test.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
fail=0
check() { if [ "$2" = "$3" ]; then printf '  ok   %s\n' "$1"
          else printf '  FAIL %s: expected %q got %q\n' "$1" "$2" "$3"; fail=1; fi }

SRC="${OPENBAO_CONFIG_SCRIPT:-$HERE/openbao-config.sh}"
body="$(sed -n '/^verify_pki_present() {/,/^}/p' "$SRC")"
[ -n "$body" ] || {
    echo "could not extract verify_pki_present() from $SRC" >&2
    echo "(renamed or reformatted? this suite asserts nothing if it cannot find it)" >&2
    exit 1
}
eval "$body"
declare -f verify_pki_present >/dev/null || {
    echo "verify_pki_present did not define after eval" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Two independent CAs, each with an intermediate. EC rather than RSA purely for
# speed -- four keypairs on every CI run.
mkca() { # mkca <prefix> <cn>
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
        -keyout "$TMP/$1.key" -out "$TMP/$1.pem" -days 1 -subj "/CN=$2" \
        -addext "basicConstraints=critical,CA:TRUE" >/dev/null 2>&1
}
mkint() { # mkint <prefix> <cn> <ca-prefix>
    openssl req -new -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
        -keyout "$TMP/$1.key" -out "$TMP/$1.csr" -subj "/CN=$2" >/dev/null 2>&1
    printf 'basicConstraints=critical,CA:TRUE\n' > "$TMP/$1.ext"
    openssl x509 -req -in "$TMP/$1.csr" -CA "$TMP/$3.pem" -CAkey "$TMP/$3.key" \
        -CAcreateserial -out "$TMP/$1.pem" -days 1 -extfile "$TMP/$1.ext" >/dev/null 2>&1
}
mkca  lineage_root "Lineage Root CA"
mkint lineage_int  "Lineage Intermediate CA" lineage_root
mkca  foreign_root "Some Other Root CA"
mkint foreign_int  "Some Other Intermediate CA" foreign_root

# Sanity: the fixtures themselves must behave, or every case below is vacuous.
openssl verify -CAfile "$TMP/lineage_root.pem" "$TMP/lineage_int.pem" >/dev/null 2>&1 || {
    echo "fixture broken: lineage intermediate does not verify against lineage root" >&2; exit 1; }
openssl verify -CAfile "$TMP/lineage_root.pem" "$TMP/foreign_int.pem" >/dev/null 2>&1 && {
    echo "fixture broken: foreign intermediate verifies against lineage root" >&2; exit 1; }

log_message() { :; }
OPENBAO_URL="https://bao.example.invalid:8200"

# The function calls `curl ... -w '\n%{http_code}' <url>`, then splits the last
# line off as the status. The stub reproduces exactly that shape.
curl() { printf '%s\n%s\n' "${PEM_BODY-}" "${HTTP_CODE-}"; }

run() { verify_pki_present; echo $?; }

echo "== 200, issuer chains to this lineage's root"
VAULT_CACERT="$TMP/lineage_root.pem"; HTTP_CODE=200; PEM_BODY="$(cat "$TMP/lineage_int.pem")"
check "returns 0"                          0 "$(run)"

echo "== 404, the mount is genuinely absent -- the only continuable failure"
VAULT_CACERT="$TMP/lineage_root.pem"; HTTP_CODE=404; PEM_BODY=""
check "returns 2, NOT 1"                   2 "$(run)"

echo "== 200, a VALID issuer under a DIFFERENT root -- the wrong-lineage restore"
# The case the split exists for. Everything looks healthy: node up, unsealed,
# serving a well-formed CA certificate. Only the chain says otherwise, and the
# stored root token would authenticate here quite happily.
VAULT_CACERT="$TMP/lineage_root.pem"; HTTP_CODE=200; PEM_BODY="$(cat "$TMP/foreign_int.pem")"
check "returns 1, NOT 2"                   1 "$(run)"

echo "== 200, but the body is not a certificate"
VAULT_CACERT="$TMP/lineage_root.pem"; HTTP_CODE=200; PEM_BODY="this is not a certificate"
check "returns 1"                          1 "$(run)"

echo "== unreachable: no status code at all"
VAULT_CACERT="$TMP/lineage_root.pem"; HTTP_CODE=""; PEM_BODY=""
check "returns 1"                          1 "$(run)"

echo "== 503, a sealed or unhealthy node"
VAULT_CACERT="$TMP/lineage_root.pem"; HTTP_CODE=503; PEM_BODY=""
check "returns 1"                          1 "$(run)"

echo "== 200 with no --ca-file: the chain check is skipped, not failed"
# Deliberate: with nothing to verify against, "does it chain" has no answer.
# The foreign intermediate is used to prove the skip is real rather than
# accidentally passing.
unset VAULT_CACERT; HTTP_CODE=200; PEM_BODY="$(cat "$TMP/foreign_int.pem")"
check "returns 0"                          0 "$(run)"

echo
if [ "$fail" -eq 0 ]; then echo "all checks passed"; else echo "FAILURES"; fi
exit "$fail"
