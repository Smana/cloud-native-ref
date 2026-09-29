#!/usr/bin/env bash
# shellcheck disable=SC2034
# (CLOUD, STORE, APPLY, GENERATABLE, REGION and PROJECT are read by the
# bodies of cmd_seed()/store_create()/aws_sm()/gcp_sm(), which are eval'd in
# from the script under test, so static analysis cannot see that use. Same
# reason as test-secret-store-migrate-keys.sh.)
#
# Regression test for `secret-store.sh seed`'s create-before-value bug.
#
# THE BUG: cmd_seed ran `seed_body "$name" | store_create "$name"`. GCP's
# store_create creates the Secret Manager secret, THEN adds a version from
# stdin -- two calls. AWS's buffers stdin into a temp file unconditionally
# before its one create-secret call. Either way, if seed_body failed or
# produced nothing, store_create still ran: a secret with no version on GCP,
# or one holding an empty string on AWS. `set -o pipefail` does not catch
# this -- under pipefail the pipeline's exit status is the RIGHTMOST failing
# command, so a failing seed_body piped into a succeeding store_create
# reports success. Worse, once the secret exists, every later run's
# store_has sees it and skips it -- broken forever.
#
# Exercises the real cmd_seed and store_create as shipped, against stub aws/
# gcloud binaries. seed_body is stubbed per case so failure/empty/good
# bodies are each exercised without needing a real generator to fail.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE/../../.." || exit 1

STUB="$(mktemp -d)"; trap 'rm -rf "$STUB"' EXIT
fail=0
check() { # label expected actual
    if [ "$2" = "$3" ]; then printf '  ok   %s\n' "$1"
    else printf '  FAIL %s: expected %q got %q\n' "$1" "$2" "$3"; fail=1; fi
}

# aws stub: logs every call (argv, plus the content of any --secret-string
# file:// payload) to $STUB_LOG. describe-secret always reports "not found"
# so store_has treats every test key as absent and cmd_seed proceeds to
# create it.
cat > "$STUB/aws" <<'EOF'
#!/usr/bin/env bash
{
    printf 'CALL:'; printf ' %q' "$@"; printf '\n'
    args=("$@")
    for ((i = 0; i < $#; i++)); do
        if [ "${args[$i]}" = "--secret-string" ]; then
            f="${args[$((i + 1))]#file://}"
            printf 'BODY:%s\n' "$(cat "$f" 2>/dev/null)"
        fi
    done
} >> "$STUB_LOG"
for a in "$@"; do
    [ "$a" = "describe-secret" ] && { echo "ResourceNotFoundException" >&2; exit 254; }
done
exit 0
EOF

# gcloud stub: same call-logging. "describe" always reports "not found".
# "versions add --data-file=-" is the only call that reads stdin in the real
# script, so only that branch consumes it.
cat > "$STUB/gcloud" <<'EOF'
#!/usr/bin/env bash
printf 'CALL:'   >> "$STUB_LOG"
printf ' %q' "$@" >> "$STUB_LOG"
printf '\n'       >> "$STUB_LOG"
for a in "$@"; do [ "$a" = "auth" ] && exit 0; done
for a in "$@"; do
    if [ "$a" = "describe" ]; then
        echo "ERROR: NOT_FOUND" >&2
        exit 1
    fi
done
for a in "$@"; do
    [ "$a" = "add" ] && { printf 'BODY:%s\n' "$(cat)" >> "$STUB_LOG"; exit 0; }
done
exit 0
EOF
chmod +x "$STUB/aws" "$STUB/gcloud"
PATH="$STUB:$PATH"
export STUB_LOG="$STUB/calls.log"

# Lift the real functions out of the script under test, so a change there is
# a change under test. Order matters: cmd_seed calls store_has and
# store_create, which call aws_sm/gcp_sm.
for fn in aws_sm gcp_sm store_has store_create cmd_seed; do
    body="$(sed -n "/^${fn}() {/,/^}/p" scripts/provision/secret-store.sh)"
    [ -n "$body" ] || { echo "could not extract ${fn}() from scripts/provision/secret-store.sh" >&2; exit 1; }
    eval "$body"
done

# shellcheck source=scripts/lib/gcloud-adc.sh
. "$HERE/../../lib/gcloud-adc.sh"

REGION="" PROJECT=""

# run_seed <cloud> <seed_body-override> -> logs to $STUB_LOG, returns cmd_seed's rc
run_seed() {
    local cloud="$1"
    : > "$STUB_LOG"
    CLOUD="$cloud" STORE="$cloud" APPLY="true"
    GENERATABLE=("test-key")
    local rc=0
    cmd_seed >"$STUB/seed-out" 2>&1 || rc=$?
    cat "$STUB/seed-out"
    return "$rc"
}

create_call_count() { # <cloud>
    if [ "$1" = "aws" ]; then grep -c 'create-secret' "$STUB_LOG"
    else grep -c 'CALL:.*secrets create ' "$STUB_LOG"; fi
}
version_call_count() { # <cloud>
    if [ "$1" = "aws" ]; then grep -c 'create-secret' "$STUB_LOG"  # aws: one call does both
    else grep -c 'CALL:.*secrets versions add ' "$STUB_LOG"; fi
}

for cloud in aws gcp; do
    # --- a failing seed_body leads to no create -----------------------------
    seed_body() { echo "derive step failed" >&2; return 1; }
    out="$(run_seed "$cloud")"; rc=$?
    check "$cloud: failing seed_body -> no create call" "0" "$(create_call_count "$cloud")"
    check "$cloud: failing seed_body -> cmd_seed reports non-zero" "1" "$rc"
    if printf '%s' "$out" | grep -q '\[FAILED \] test-key'; then
        printf '  ok   %s\n' "$cloud: failing seed_body -> [FAILED] names the key"
    else
        printf '  FAIL %s: failing seed_body -> [FAILED] line missing:\n%s\n' "$cloud" "$out"; fail=1
    fi

    # --- an empty (but successful) seed_body leads to no create ------------
    seed_body() { printf ''; return 0; }
    run_seed "$cloud" >/dev/null; rc=$?
    check "$cloud: empty seed_body -> no create call" "0" "$(create_call_count "$cloud")"
    check "$cloud: empty seed_body -> cmd_seed reports non-zero" "1" "$rc"

    # --- a good body leads to exactly one create + one version add ---------
    seed_body() { printf '{"password":"s3cr3t-do-not-print"}'; return 0; } # pragma: allowlist secret
    out="$(run_seed "$cloud")"; rc=$?
    check "$cloud: good body -> exactly one create call" "1" "$(create_call_count "$cloud")"
    check "$cloud: good body -> exactly one version-add call" "1" "$(version_call_count "$cloud")"
    check "$cloud: good body -> cmd_seed reports success" "0" "$rc"
    if grep -q 'BODY:{"password":"s3cr3t-do-not-print"}' "$STUB_LOG"; then # pragma: allowlist secret
        printf '  ok   %s\n' "$cloud: good body -> value reaches the store on stdin"
    else
        printf '  FAIL %s: good body -> value never reached the store via stdin\n' "$cloud"; fail=1
    fi
    if grep -q 's3cr3t-do-not-print' <(grep '^CALL:' "$STUB_LOG"); then
        printf '  FAIL %s: value appeared on a CLI argv\n' "$cloud"; fail=1
    else
        printf '  ok   %s: value never appears on argv\n' "$cloud"
    fi
    if printf '%s' "$out" | grep -q '\[created\] test-key'; then
        printf '  ok   %s\n' "$cloud: good body -> [created] reported"
    else
        printf '  FAIL %s: good body -> [created] line missing\n' "$cloud"; fail=1
    fi
done

echo
if [ "$fail" -eq 0 ]; then echo "all checks passed"; else echo "FAILURES"; fi
exit "$fail"
