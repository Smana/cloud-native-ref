#!/usr/bin/env bash
# Store I/O against stub CLIs, so no cloud call is made.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
STUB="$(mktemp -d)"; trap 'rm -rf "$STUB"' EXIT
fail=0
check() { # label expected actual
    if [ "$2" = "$3" ]; then printf '  ok   %s\n' "$1"
    else printf '  FAIL %s: expected %q got %q\n' "$1" "$2" "$3"; fail=1; fi
}
# label pattern logfile
check_log() {
    if grep -qF -- "$2" "$3"; then printf '  ok   %s\n' "$1"
    else printf '  FAIL %s: %q not found in log\n' "$1" "$2"; fail=1; fi
}
check_log_absent() {
    if grep -qF -- "$2" "$3"; then printf '  FAIL %s: %q found in log, expected absent\n' "$1" "$2"; fail=1
    else printf '  ok   %s\n' "$1"; fi
}

# aws stub: logs every call to $STUB_LOG (argv, plus the body of any
# --cli-input-json file so the test can inspect the JSON payload without a
# real AWS call). describe-secret reports "not found" only for a secret
# named notfound-secret, so store_write's create-vs-put branch is exercised
# both ways while the pre-existing checks (which use "any") keep seeing
# "exists".
cat > "$STUB/aws" <<'EOF'
#!/usr/bin/env bash
{
    printf 'CALL:'
    printf ' %q' "$@"
    printf '\n'
    args=("$@")
    for ((i = 0; i < $#; i++)); do
        if [ "${args[$i]}" = "--cli-input-json" ]; then
            f="${args[$((i + 1))]#file://}"
            printf 'BODY:\n'
            cat "$f"
        fi
    done
} >> "$STUB_LOG"

for a in "$@"; do [ "$a" = "get-secret-value" ] && { echo '{"token":"aws-secret"}'; exit 0; }; done
for a in "$@"; do
    if [ "$a" = "describe-secret" ]; then
        case " $* " in
            *" notfound-secret "*) exit 1 ;;
            *) exit 0 ;;
        esac
    fi
done
exit 0
EOF

# gcloud stub: same call-logging, "describe" reports "not found" only for
# notfound-secret.
cat > "$STUB/gcloud" <<'EOF'
#!/usr/bin/env bash
printf 'CALL:'   >> "$STUB_LOG"
printf ' %q' "$@" >> "$STUB_LOG"
printf '\n'       >> "$STUB_LOG"

for a in "$@"; do [ "$a" = "access" ] && { echo '{"token":"gcp-secret"}'; exit 0; }; done
for a in "$@"; do
    if [ "$a" = "describe" ]; then
        case " $* " in
            *" notfound-secret "*) exit 1 ;;
            *) exit 0 ;;
        esac
    fi
done
exit 0
EOF
chmod +x "$STUB/aws" "$STUB/gcloud"
PATH="$STUB:$PATH"
export STUB_LOG="$STUB/calls.log"

# shellcheck source=scripts/lib/cloud-secret-store.sh
. "$HERE/lib/cloud-secret-store.sh"

CLOUD=aws REGION=eu-west-3 GCP_PROJECT=""
check "aws read"    '{"token":"aws-secret"}' "$(store_read any)"
store_exists any && r=yes || r=no
check "aws exists"  yes "$r"

CLOUD=gcp REGION="" GCP_PROJECT=proj
check "gcp read"    '{"token":"gcp-secret"}' "$(store_read any)"

# --- store_write: AWS ---
# store_write's aws branch pipes the payload through `jq . | tostring`
# (matching zitadel-oidc-clients.sh), so the payload on stdin must be valid
# JSON, same as every real caller sends.
CLOUD=aws REGION=eu-west-3 GCP_PROJECT=""

: > "$STUB_LOG"
echo -n '{"v":"secretvalue"}' | store_write existing-secret
check_log "aws write existing -> put-secret-value" 'put-secret-value' "$STUB_LOG"
check_log_absent "aws write existing -> no create-secret" 'create-secret' "$STUB_LOG"

: > "$STUB_LOG"
echo -n '{"v":"secretvalue"}' | store_write notfound-secret
check_log "aws write new -> create-secret" 'create-secret' "$STUB_LOG"
check_log_absent "aws write new -> no put-secret-value" 'put-secret-value' "$STUB_LOG"
check_log "aws write new -> default description" '"Description": "Written by cloud-secret-store.sh"' "$STUB_LOG"

: > "$STUB_LOG"
( STORE_WRITE_DESCRIPTION="unit test description"
  echo -n '{"v":"secretvalue"}' | store_write notfound-secret )
check_log "aws write new -> STORE_WRITE_DESCRIPTION honoured" '"Description": "unit test description"' "$STUB_LOG"

# --- store_write: GCP ---
CLOUD=gcp REGION="" GCP_PROJECT=proj

: > "$STUB_LOG"
echo -n secretvalue | store_write existing-secret
check_log "gcp write existing -> versions add" 'secrets versions add' "$STUB_LOG"
check_log_absent "gcp write existing -> no secrets create" 'secrets create' "$STUB_LOG"

: > "$STUB_LOG"
echo -n secretvalue | store_write notfound-secret
check_log "gcp write new -> secrets create" 'secrets create' "$STUB_LOG"
check_log "gcp write new -> versions add" 'secrets versions add' "$STUB_LOG"
check_log "gcp write new -> default label" '--labels=managed-by=cloud-secret-store' "$STUB_LOG"

: > "$STUB_LOG"
( STORE_WRITE_LABEL="unit-test"
  echo -n secretvalue | store_write notfound-secret )
check_log "gcp write new -> STORE_WRITE_LABEL honoured" '--labels=managed-by=unit-test' "$STUB_LOG"

# --- store_write: no plaintext survives a failed write (round-1 fix) -------
#
# Under a caller's `set -o errexit`, a failing cloud CLI aborts the shell
# from INSIDE store_write -- the function never "returns", so a bare RETURN
# trap never fires and the payload temp file is left on disk with the secret
# still in it. Exercised in a nested `bash -c` with errexit on, matching how
# every real caller (zitadel-oidc-clients.sh, zitadel-idp.sh) actually runs
# this: both set errexit, nounset AND pipefail. All three options matter --
# two fixes for this leak passed a version of this test
# that set errexit alone, because it is `nounset` that turns the trap's own
# variable expansion into a fatal error. Do not weaken this line.
FAILSTUB="$(mktemp -d)"
cat > "$FAILSTUB/aws" <<'EOF'
#!/usr/bin/env bash
for a in "$@"; do
    case "$a" in
        describe-secret) exit 1 ;;            # "not found" -> create path
        create-secret|put-secret-value) exit 254 ;;   # simulate a live failure
    esac
done
exit 0
EOF
chmod +x "$FAILSTUB/aws"
FAILTMP="$(mktemp -d)"

set +e
PATH="$FAILSTUB:$PATH" TMPDIR="$FAILTMP" bash -c '
    set -o errexit -o nounset -o pipefail
    # shellcheck source=scripts/lib/cloud-secret-store.sh
    . "'"$HERE"'/lib/cloud-secret-store.sh"
    CLOUD=aws REGION=eu-west-3 GCP_PROJECT=""
    printf "%s" "{\"pat\":\"should-never-survive-on-disk\"}" | store_write probe-secret
'
fail_exit=$?
set -e
check "failed write still propagates the CLI's exit code" "254" "$fail_exit"

leftover="$(find "$FAILTMP" -maxdepth 1 -name 'cloud-secret*' | head -1)"
check "failed write leaves no temp file behind" "" "$leftover"
# Same failed write, called with a herestring instead of a pipe. A pipeline runs
# store_write in its own subshell, which keeps the function's locals alive long
# enough for an EXIT trap to expand them -- so the pipe case above passes even
# against a trap that is broken. A herestring does not: errexit pops the locals
# first, and a trap expanding $payload at fire time then dies under nounset,
# taking its own `|| rm -f` fallback with it. zitadel-pat.sh seeds the admin PAT
# with exactly this call form, so it is the one that matters most here.
FAILTMP2="$(mktemp -d)"
set +e
PATH="$FAILSTUB:$PATH" TMPDIR="$FAILTMP2" bash -c '
    set -o errexit -o nounset -o pipefail
    # shellcheck source=scripts/lib/cloud-secret-store.sh
    . "'"$HERE"'/lib/cloud-secret-store.sh"
    CLOUD=aws REGION=eu-west-3 GCP_PROJECT=""
    store_write probe-secret <<< "{\"pat\":\"should-never-survive-on-disk\"}"
'
fail_exit2=$?
set -e
check "herestring write propagates the CLI's exit code" "254" "$fail_exit2"
leftover2="$(find "$FAILTMP2" -maxdepth 1 -name 'cloud-secret*' | head -1)"
check "herestring write leaves no temp file behind" "" "$leftover2"
rm -rf "$FAILTMP2"

rm -rf "$FAILSTUB" "$FAILTMP"

exit $fail
