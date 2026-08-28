#!/usr/bin/env bash
#
# Regression test for `secret-store.sh lint`.
#
# The bug it exists for: app-wizard's GitHub login failed on gcp-0 because the
# stored client secret began with U+00A0, pasted out of a browser. Nothing
# between the paste and the failure showed it -- Secret Manager stored it, jq
# round-tripped it, base64 hid it, and GitHub answered only
# incorrect_client_credentials.
#
# The filter is not re-declared here; it is lifted verbatim out of the script,
# so a change there is a change under test.

set -o errexit
set -o nounset
set -o pipefail

cd "$(dirname "$0")/.."

# shellcheck disable=SC2154  # LINT_JQ comes from the eval below
eval "$(sed -n "/^LINT_JQ='/,/^'$/p" scripts/secret-store.sh)"
[ -n "${LINT_JQ:-}" ] || { echo "could not lift LINT_JQ out of scripts/secret-store.sh" >&2; exit 1; }

pass=0
fail=0

# run <name> <payload> <expected-substring-or-empty>
run() {
    local name="$1" payload="$2" want="$3" got
    got=$(printf '%s' "$payload" | jq -Rrs "$LINT_JQ")
    if [ -z "$want" ]; then
        if [ -z "$got" ]; then
            echo "ok   ${name}"; pass=$((pass + 1))
        else
            echo "FAIL ${name}: expected no findings, got:"; echo "${got}" | sed 's/^/       /'
            fail=$((fail + 1))
        fi
    elif printf '%s' "$got" | grep -qF "$want"; then
        echo "ok   ${name}"; pass=$((pass + 1))
    else
        echo "FAIL ${name}: expected a finding containing '${want}', got:"
        echo "${got:-<none>}" | sed 's/^/       /'
        fail=$((fail + 1))
    fi
}

# A well-formed blob, shaped like the real apps-app-wizard-oauth.
CLEAN='{"GITHUB_CLIENT_ID":"Ov23liAAAAAAAAAAAAAA","GITHUB_CLIENT_SECRET":"0123456789abcdef0123456789abcdef01234567","SESSION_KEY":"aB3/xYz+0123456789abcdefABCDEF0123456789abcd"}'

run "clean blob is silent" "$CLEAN" ""

# The actual bug: U+00A0 in front of the client secret.
run "leading NBSP is caught" \
    "$(printf '{"GITHUB_CLIENT_SECRET":"\\u00a00123456789abcdef0123456789abcdef01234567"}')" \
    "LEADING NBSP U+00A0 at offset 0"

run "trailing newline in a field is caught" \
    '{"TOKEN":"ghp_aaaaaaaaaaaaaaaaaaaa\n"}' \
    "TRAILING LF"

run "leading plain space is caught" \
    '{"TOKEN":" ghp_aaaaaaaaaaaaaaaaaaaa"}' \
    "LEADING SPACE at offset 0"

run "zero-width space mid-value is caught" \
    "$(printf '{"TOKEN":"ghp_aaaa\\u200bbbbbbbbbbbbbbbb"}')" \
    "ZERO-WIDTH SPACE U+200B"

run "BOM is caught" \
    "$(printf '{"TOKEN":"\\ufeffghp_aaaaaaaaaaaaaaaaaaaa"}')" \
    "BOM U+FEFF"

run "empty field is caught" '{"TOKEN":""}' "EMPTY value"

# A space INSIDE a value is legitimate -- passphrases have them -- and must not
# be reported, or the lint becomes noise nobody reads.
run "inner space is not a finding" '{"PASSPHRASE":"correct horse battery staple"}' ""

# Non-ASCII that is not an invisible is a warning, not a failure: a generated
# password may legitimately contain one.
run "non-ASCII letter warns rather than fails" '{"PASSWORD":"pa55w0rd-é-xyz"}' "WARN"  # pragma: allowlist secret

# Payloads that are a bare string, not a JSON object.
# Single-backslash \u here, unlike the JSON cases above: those are read back
# through jq's fromjson, which is what turns the escape into the character. A
# bare string is probed as-is, so printf has to emit the real one.
run "bare string with leading NBSP is caught" \
    "$(printf '\u00a0hunter2')" \
    "LEADING NBSP U+00A0"

run "clean bare string is silent" "hunter2" ""

# The envelope newline the cloud CLIs append must not be reported. This is the
# blind spot documented in secret-store.sh: it is stripped before probing.
run "envelope newline is not a finding" "$(printf 'hunter2\n')" ""

# A PEM is legitimately multi-line. Reporting each newline buried the one real
# finding of the sweep this test was written for under fifty-three others.
PEM='-----BEGIN CERTIFICATE-----\nMIIBaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\nbbbbbbbbbbbbbbbbbbbbb\ncccccccccccccccccccc\n-----END CERTIFICATE-----\n'
run "multi-line PEM is silent" "{\"CA\":\"${PEM}\"}" ""

# ...but an invisible hiding inside one is still a defect.
run "NBSP inside a PEM is still caught" \
    "$(printf '{"CA":"-----BEGIN CERTIFICATE-----\\nMIIB\\u00a0aaaa\\nbbbb\\n-----END CERTIFICATE-----\\n"}')" \
    "NBSP U+00A0"

# One field repeating one defect is one thing to fix, not twenty lines.
run "repeated findings collapse" \
    "$(printf '{"T":"a b c d e f g\\u00a0h\\u00a0i\\u00a0j\\u00a0k\\u00a0l"}')" \
    "... and 2 more NBSP U+00A0"

echo
echo "passed ${pass}, failed ${fail}"
[ "$fail" -eq 0 ]
