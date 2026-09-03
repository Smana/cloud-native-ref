#!/usr/bin/env bash
# Regression test for cnpg-promote-seed.sh against stub CLIs -- no cloud
# call, no live cluster, no credentials needed.
#
# Fixture data reproduces the REAL object shapes and values of two seeds
# that exist in s3://eu-west-3-ogenki-cnpg-backups (under synthetic names and
# a synthetic bucket here, since this session has no credentials for that
# AWS account):
#
#   good-seed  == zitadel-20260902     (known good)
#                 newest base 20260902T123813
#                 begin_wal=00000007000000020000007E  present
#                 end_wal  =00000007000000020000007F  present (plus ...80/...81)
#
#   bad-seed   == zitadel-20260829-2   (known bad, born unrestorable)
#                 newest base 20260829T195453
#                 begin_wal=000000050000000200000041  present
#                 end_wal  =000000050000000200000042  ABSENT
#
# This does NOT replace a run against the real bucket -- see
# .superpowers/sdd/2026-09-03-cnpg-per-generation-servername-plan/task-4-report.md
# for why that run could not happen in this session, and what it still owes.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/cnpg-promote-seed.sh"
STUB="$(mktemp -d)"; FIX="$(mktemp -d)"
trap 'rm -rf "$STUB" "$FIX"' EXIT
fail=0
check() { # label expected actual
    if [ "$2" = "$3" ]; then printf '  ok   %s\n' "$1"
    else printf '  FAIL %s: expected %q got %q\n' "$1" "$2" "$3"; fail=1; fi
}
check_contains() { # label needle haystack
    if printf '%s' "$3" | grep -qF -- "$2"; then printf '  ok   %s\n' "$1"
    else printf '  FAIL %s: %q not found in output:\n%s\n' "$1" "$2" "$3"; fail=1; fi
}

# ---- fixtures ---------------------------------------------------------------
cat > "$FIX/good-base-listing.txt" <<'EOF'
                           PRE 20260902T123813/
EOF
cat > "$FIX/good-wals-listing.txt" <<'EOF'
2026-09-02 12:40:00     123456 00000007000000020000007E.bz2
2026-09-02 12:41:00     123456 00000007000000020000007F.bz2
2026-09-02 12:42:00     123456 000000070000000200000080.bz2
2026-09-02 12:43:00     123456 000000070000000200000081.bz2
EOF
cat > "$FIX/good-backup.info" <<'EOF'
backup_label=None
begin_wal=00000007000000020000007E
end_wal=00000007000000020000007F
status=DONE
timeline=7
EOF

cat > "$FIX/bad-base-listing.txt" <<'EOF'
                           PRE 20260829T195453/
EOF
cat > "$FIX/bad-wals-listing.txt" <<'EOF'
2026-08-29 19:55:00     123456 000000050000000200000041.bz2
EOF
cat > "$FIX/bad-backup.info" <<'EOF'
backup_label=None
begin_wal=000000050000000200000041
end_wal=000000050000000200000042
status=DONE
timeline=5
EOF

cat > "$FIX/gcp-good-base-listing.txt" <<'EOF'
gs://test-bucket/gcp-good-seed/base/20260902T123813/
EOF
cat > "$FIX/gcp-good-wals-listing.txt" <<'EOF'
gs://test-bucket/gcp-good-seed/wals/0000000700000002/00000007000000020000007E.gz
gs://test-bucket/gcp-good-seed/wals/0000000700000002/00000007000000020000007F.gz
EOF

# round-3 settle-loop fixture: the segment lands under a THIRD poll, and the
# rest of a successful --apply run needs a destination that verifies clean
# afterwards (same shape as good-seed, copied to a different seed name).
cat > "$FIX/settle-lands-base-listing.txt" <<'EOF'
                           PRE 20260902T123813/
EOF

# ---- stub CLIs ----------------------------------------------------------
cat > "$STUB/aws" <<'EOF'
#!/usr/bin/env bash
FIXDIR="$STUB_FIXTURES"
if [ "$1" = "s3" ] && [ "$2" = "ls" ]; then
    case "$3" in
        s3://test-bucket/good-seed/base/)                 cat "$FIXDIR/good-base-listing.txt" ;;
        s3://test-bucket/good-seed/wals/0000000700000002/) cat "$FIXDIR/good-wals-listing.txt" ;;
        s3://test-bucket/bad-seed/base/)                   cat "$FIXDIR/bad-base-listing.txt" ;;
        s3://test-bucket/bad-seed/wals/0000000500000002/)  cat "$FIXDIR/bad-wals-listing.txt" ;;
        s3://test-bucket/populated-seed/)                  echo "                           PRE existing-object/" ;;
        # round-2 fixtures: a transient CLI failure, not a real empty result.
        s3://test-bucket/flaky-wal-seed/base/)                 cat "$FIXDIR/good-base-listing.txt" ;;
        s3://test-bucket/flaky-wal-seed/wals/0000000700000002/) echo "An error occurred (SlowDown) when calling the ListObjectsV2 operation" >&2; exit 254 ;;
        s3://test-bucket/flaky-info-seed/base/)                cat "$FIXDIR/good-base-listing.txt" ;;
        s3://test-bucket/flaky-collision-seed/)                echo "An error occurred (SlowDown) when calling the ListObjectsV2 operation" >&2; exit 254 ;;
        # round-3 fixture: base/ itself fails to list (AWS-side counterpart
        # of gcp-broken-seed -- AWS has no "matched no objects" ambiguity, so
        # this is a plain non-zero-exit failure).
        s3://test-bucket/flaky-base-seed/base/) echo "An error occurred (SlowDown) when calling the ListObjectsV2 operation" >&2; exit 254 ;;
        # round-3 fixture: a benign stderr notice on an otherwise-successful
        # call (real example: AWS CLI v2's CRT-transfer-client notice) must
        # never leak into the parsed stdout.
        s3://test-bucket/noisy-seed/base/)
            echo "Note: switching to next-gen CRT-based S3 transfer client" >&2
            cat "$FIXDIR/good-base-listing.txt" ;;
        s3://test-bucket/noisy-seed/wals/0000000700000002/)
            echo "Note: switching to next-gen CRT-based S3 transfer client" >&2
            cat "$FIXDIR/good-wals-listing.txt" ;;
        # round-3 settle-loop fixtures (Backup.status.endWal = ...7F throughout).
        s3://test-bucket/settle-lands-server/wals/0000000700000002/)
            n=0
            [ -f "$FIXDIR/settle-lands-poll-count" ] && n="$(cat "$FIXDIR/settle-lands-poll-count")"
            n=$((n + 1))
            echo "$n" > "$FIXDIR/settle-lands-poll-count"
            [ "$n" -ge 3 ] && echo "2026-09-02 12:41:00     123456 00000007000000020000007F.bz2" ;;
        s3://test-bucket/settle-timeout-server/wals/0000000700000002/) : ;;  # never lands
        s3://test-bucket/settle-error-server/wals/0000000700000002/)
            echo "An error occurred (SlowDown) when calling the ListObjectsV2 operation" >&2; exit 254 ;;
        s3://test-bucket/settle-lands-seed/base/)                 cat "$FIXDIR/good-base-listing.txt" ;;
        s3://test-bucket/settle-lands-seed/wals/0000000700000002/) cat "$FIXDIR/good-wals-listing.txt" ;;
        *) : ;;
    esac
    exit 0
fi
if [ "$1" = "s3" ] && [ "$2" = "cp" ]; then
    for a in "$@"; do [ "$a" = "--recursive" ] && exit 0; done
    uri=""
    for a in "$@"; do case "$a" in s3://*) uri="$a" ;; esac; done
    case "$uri" in
        s3://test-bucket/good-seed/base/20260902T123813/backup.info)         cat "$FIXDIR/good-backup.info" ;;
        s3://test-bucket/bad-seed/base/20260829T195453/backup.info)          cat "$FIXDIR/bad-backup.info" ;;
        s3://test-bucket/flaky-wal-seed/base/20260902T123813/backup.info)    cat "$FIXDIR/good-backup.info" ;;
        s3://test-bucket/flaky-info-seed/base/20260902T123813/backup.info)   echo "An error occurred (RequestTimeout) when calling the GetObject operation" >&2; exit 254 ;;
        s3://test-bucket/noisy-seed/base/20260902T123813/backup.info)
            echo "Note: switching to next-gen CRT-based S3 transfer client" >&2
            cat "$FIXDIR/good-backup.info" ;;
        s3://test-bucket/settle-lands-seed/base/20260902T123813/backup.info) cat "$FIXDIR/good-backup.info" ;;
        *) exit 1 ;;
    esac
    exit 0
fi
exit 1
EOF

cat > "$STUB/gcloud" <<'EOF'
#!/usr/bin/env bash
FIXDIR="$STUB_FIXTURES"
if [ "$1" = "storage" ] && [ "$2" = "ls" ]; then
    case "$3" in
        gs://test-bucket/gcp-good-seed/base/)                 cat "$FIXDIR/gcp-good-base-listing.txt" ;;
        gs://test-bucket/gcp-good-seed/wals/0000000700000002/) cat "$FIXDIR/gcp-good-wals-listing.txt" ;;
        # round-2 fixtures, wording verified live against a real bucket
        # (see task-4-report.md): gcloud storage ls uses the SAME exit code
        # (1) for "genuinely nothing there" and for a real failure -- only
        # the message text tells them apart.
        gs://test-bucket/gcp-empty-seed/base/)  echo "ERROR: (gcloud.storage.ls) One or more URLs matched no objects." >&2; exit 1 ;;
        gs://test-bucket/gcp-broken-seed/base/) echo "ERROR: (gcloud.storage.ls) gs://test-bucket not found: 404." >&2; exit 1 ;;
        *) : ;;
    esac
    exit 0
fi
if [ "$1" = "storage" ] && [ "$2" = "cat" ]; then
    case "$3" in
        gs://test-bucket/gcp-good-seed/base/20260902T123813/backup.info) cat "$FIXDIR/good-backup.info" ;;
        *) exit 1 ;;
    esac
    exit 0
fi
exit 1
EOF

cat > "$STUB/kubectl" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "get" ] && [ "$2" = "cluster" ]; then
    echo "$STUB_SERVER_NAME"
    exit 0
fi
if [ "$1" = "get" ] && [ "$2" = "pod" ]; then
    echo "$STUB_PRIMARY_POD"
    exit 0
fi
if [ "$1" = "create" ]; then
    cat >/dev/null   # consume the Backup manifest on stdin
    exit 0
fi
if [ "$1" = "get" ] && [ "$2" = "backup" ]; then
    for a in "$@"; do
        case "$a" in
            *.status.phase*)  echo "completed" ; exit 0 ;;
            *.status.endWal*) echo "$STUB_END_WAL"; exit 0 ;;
        esac
    done
    exit 1
fi
if [ "$1" = "exec" ]; then
    exit 0   # pg_switch_wal
fi
exit 1
EOF

# sleep is a no-op so the settle loop's 30x10s budget and the backup-phase
# loop's polling run instantly instead of taking 5+ minutes wall-clock.
cat > "$STUB/sleep" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

chmod +x "$STUB/aws" "$STUB/gcloud" "$STUB/kubectl" "$STUB/sleep"
export STUB_FIXTURES="$FIX"
PATH="$STUB:$PATH"

# ---- 1. known-good seed verifies clean (Critical #1) -----------------------
out="$(bash "$SCRIPT" --verify-seed good-seed --cloud aws --bucket test-bucket 2>&1)"
rc=$?
check "verify-seed good-seed exit code" "0" "$rc"
check_contains "verify-seed good-seed reports both WALs present" "end_wal=00000007000000020000007F present" "$out"

# ---- 2. known-bad seed (reproduces zitadel-20260829-2) fails, naming the
#         missing end_wal -- not a bare object-count pass (Critical #1) -----
out="$(bash "$SCRIPT" --verify-seed bad-seed --cloud aws --bucket test-bucket 2>&1)"
rc=$?
check "verify-seed bad-seed exit code" "1" "$rc"
check_contains "verify-seed bad-seed names the missing end_wal" \
    "end_wal segment 000000050000000200000042 is not present" "$out"

# ---- 3. GCP listing parsing (Important #4): NEWEST is the bare timestamp,
#         not a mangled full URI -------------------------------------------
out="$(bash "$SCRIPT" --verify-seed gcp-good-seed --cloud gcp --bucket test-bucket 2>&1)"
rc=$?
check "verify-seed gcp-good-seed exit code" "0" "$rc"
check_contains "verify-seed gcp-good-seed parsed the bare timestamp" \
    "newest base backup 20260902T123813" "$out"

# ---- 4. destination collision refusal (Critical #3) ------------------------
export STUB_SERVER_NAME="live-server-name"
out="$(bash "$SCRIPT" --cluster xplane-fake --namespace ns --cloud aws --bucket test-bucket --seed populated-seed 2>&1)"
rc=$?
check "populated destination refused" "1" "$rc"
check_contains "populated destination names the reason" "already has objects in it" "$out"

# ---- 5. dry-run still succeeds against an empty destination ----------------
out="$(bash "$SCRIPT" --cluster xplane-fake --namespace ns --cloud aws --bucket test-bucket --seed empty-seed 2>&1)"
rc=$?
check "empty destination dry-run exit code" "0" "$rc"
check_contains "empty destination dry-run reports serverName" "serverName live-server-name" "$out"

# ---- round 2: a failed cloud-CLI call must never be read as "absent" -------
# (the actual defect: aws s3 ls returning a transient error was silently read
# as "the segment isn't there", making a known-good seed intermittently fail)

# ---- 6. wal_present: a listing failure on begin_wal must be reported as a
#         failure to verify, NOT as "not present" ---------------------------
out="$(bash "$SCRIPT" --verify-seed flaky-wal-seed --cloud aws --bucket test-bucket 2>&1)"
rc=$?
check "flaky wal listing: exit code" "1" "$rc"
check_contains "flaky wal listing: reports could-not-verify, not absence" \
    "could not verify begin_wal 00000007000000020000007E -- listing failed" "$out"
if printf '%s' "$out" | grep -qF "is not present under wals/"; then
    printf '  FAIL flaky wal listing: must not claim the segment is absent\n'; fail=1
else
    printf '  ok   flaky wal listing: does not claim the segment is absent\n'
fi

# ---- 7. cat_object: a failed backup.info read must be reported as a
#         failure to read, NOT as "missing/empty" ---------------------------
out="$(bash "$SCRIPT" --verify-seed flaky-info-seed --cloud aws --bucket test-bucket 2>&1)"
rc=$?
check "flaky backup.info read: exit code" "1" "$rc"
check_contains "flaky backup.info read: reports could-not-read" \
    "could not read 20260902T123813/backup.info -- see error above" "$out"

# ---- 8. destination-collision check: a listing failure must fail closed,
#         NOT be read as "the seed doesn't exist yet, go ahead" ------------
export STUB_SERVER_NAME="live-server-name"
out="$(bash "$SCRIPT" --cluster xplane-fake --namespace ns --cloud aws --bucket test-bucket --seed flaky-collision-seed 2>&1)"
rc=$?
check "flaky collision check: exit code" "1" "$rc"
check_contains "flaky collision check: reports could-not-check, not proceed" \
    "could not check whether seed flaky-collision-seed already exists" "$out"

# ---- 9. GCP: "matched no objects" IS a genuine empty result, not a failure
#         -- gcloud storage ls uses the SAME exit code (1) for both, so this
#         is the one case where the message, not the exit code, must decide -
out="$(bash "$SCRIPT" --verify-seed gcp-empty-seed --cloud gcp --bucket test-bucket 2>&1)"
rc=$?
check "gcp genuinely-empty seed: exit code" "1" "$rc"
check_contains "gcp genuinely-empty seed: reports holds-no-base-backup, not a listing failure" \
    "seed gcp-empty-seed holds no base backup" "$out"
if printf '%s' "$out" | grep -qF "could not list"; then
    printf '  FAIL gcp genuinely-empty seed: must not report this as a listing failure\n'; fail=1
else
    printf '  ok   gcp genuinely-empty seed: not reported as a listing failure\n'
fi

# ---- 10. GCP: a REAL error (same exit code as #9) must still fail closed
#          as a listing failure, not as "holds no base backup" -------------
out="$(bash "$SCRIPT" --verify-seed gcp-broken-seed --cloud gcp --bucket test-bucket 2>&1)"
rc=$?
check "gcp real listing failure: exit code" "1" "$rc"
check_contains "gcp real listing failure: reports could-not-list" \
    "could not list gs://test-bucket/gcp-broken-seed/base/ -- see error above" "$out"
if printf '%s' "$out" | grep -qF "holds no base backup"; then
    printf '  FAIL gcp real listing failure: must not be read as a genuine empty result\n'; fail=1
else
    printf '  ok   gcp real listing failure: not read as a genuine empty result\n'
fi

# ---- round 3: 2>&1 in ls_raw/cat_object corrupted the parsed stream on a
# SUCCESSFUL call, not just a failed one -- demonstrated live: a stubbed
# `aws s3 ls` printing a benign notice to stderr AND the real listing to
# stdout, both under exit 0, made list_subdir_names' unanchored
# `sort | tail -1` pick the notice's last word as the "newest" backup name.

# ---- 11. a benign stderr notice on success must not leak into the parsed
#          NEWEST name or the parsed backup.info -----------------------------
out="$(bash "$SCRIPT" --verify-seed noisy-seed --cloud aws --bucket test-bucket 2>&1)"
rc=$?
check "noisy-seed exit code" "0" "$rc"
check_contains "noisy-seed parses the real timestamp, not the stray stderr word" \
    "newest base backup 20260902T123813" "$out"
check_contains "noisy-seed still verifies both WALs present" \
    "end_wal=00000007000000020000007F present" "$out"
if printf '%s' "$out" | grep -qF "newest base backup client"; then
    printf '  FAIL noisy-seed: stderr notice leaked into the parsed NEWEST name\n'; fail=1
else
    printf '  ok   noisy-seed: stderr notice did not leak into the parsed NEWEST name\n'
fi

# ---- 12. AWS-side counterpart of case 10: base/ itself fails to list -------
out="$(bash "$SCRIPT" --verify-seed flaky-base-seed --cloud aws --bucket test-bucket 2>&1)"
rc=$?
check "aws real listing failure (base/): exit code" "1" "$rc"
check_contains "aws real listing failure (base/): reports could-not-list" \
    "could not list s3://test-bucket/flaky-base-seed/base/ -- see error above" "$out"

# ---- round 3: the archive-settle loop (the code most directly guarding
# against the 2026-08-29 bug) had zero test coverage. kubectl/sleep are now
# stubbed enough to drive a full --apply run through it.

# ---- 13. the segment lands after a couple of polls -> apply succeeds -------
export STUB_SERVER_NAME="settle-lands-server"
export STUB_PRIMARY_POD="settle-lands-server-1"
export STUB_END_WAL="00000007000000020000007F"
out="$(bash "$SCRIPT" --cluster xplane-settle-lands --namespace ns --cloud aws --bucket test-bucket \
    --seed settle-lands-seed --apply 2>&1)"
rc=$?
check "settle loop: segment lands after polling -> exit code" "0" "$rc"
check_contains "settle loop: reports the segment archived" "end_wal 00000007000000020000007F archived" "$out"
check_contains "settle loop: apply completes and verifies the copied seed" \
    "Set spec.objectStoreRecovery.path to: settle-lands-seed" "$out"

# ---- 14. the segment never lands -> genuine timeout, not a listing failure -
export STUB_SERVER_NAME="settle-timeout-server"
export STUB_PRIMARY_POD="settle-timeout-server-1"
export STUB_END_WAL="00000007000000020000007F"
out="$(bash "$SCRIPT" --cluster xplane-settle-timeout --namespace ns --cloud aws --bucket test-bucket \
    --seed settle-timeout-seed --apply 2>&1)"
rc=$?
check "settle loop: genuine timeout -> exit code" "1" "$rc"
check_contains "settle loop: genuine timeout names the real cause" \
    "end_wal 00000007000000020000007F did not land in the archive within 5 minutes" "$out"

# ---- 15. the listing keeps failing throughout -> "could not tell" timeout,
#          NOT the same message as a genuine timeout ------------------------
export STUB_SERVER_NAME="settle-error-server"
export STUB_PRIMARY_POD="settle-error-server-1"
export STUB_END_WAL="00000007000000020000007F"
out="$(bash "$SCRIPT" --cluster xplane-settle-error --namespace ns --cloud aws --bucket test-bucket \
    --seed settle-error-seed --apply 2>&1)"
rc=$?
check "settle loop: could-not-tell timeout -> exit code" "1" "$rc"
check_contains "settle loop: could-not-tell timeout names listing failure, not archive absence" \
    "could not check for end_wal 00000007000000020000007F -- listing kept failing" "$out"
if printf '%s' "$out" | grep -qF "did not land in the archive within 5 minutes"; then
    printf '  FAIL settle loop could-not-tell: must not be reported as a genuine timeout\n'; fail=1
else
    printf '  ok   settle loop could-not-tell: not reported as a genuine timeout\n'
fi

exit $fail
