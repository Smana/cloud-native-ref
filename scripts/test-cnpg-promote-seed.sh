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
        *) : ;;
    esac
    exit 0
fi
if [ "$1" = "s3" ] && [ "$2" = "cp" ]; then
    uri=""
    for a in "$@"; do case "$a" in s3://*) uri="$a" ;; esac; done
    case "$uri" in
        s3://test-bucket/good-seed/base/20260902T123813/backup.info) cat "$FIXDIR/good-backup.info" ;;
        s3://test-bucket/bad-seed/base/20260829T195453/backup.info)  cat "$FIXDIR/bad-backup.info" ;;
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
exit 1
EOF

chmod +x "$STUB/aws" "$STUB/gcloud" "$STUB/kubectl"
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

exit $fail
