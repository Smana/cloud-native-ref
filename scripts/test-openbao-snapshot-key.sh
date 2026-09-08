#!/usr/bin/env bash
# shellcheck disable=SC2034
# (file-wide: err/warn/BUCKET_NAME/SNAPSHOT_KEY are read by the body of
# select_snapshot(), which is eval'd in from the script under test, so static
# analysis cannot see those uses. Same reason as test-openbao-fallback-address.sh.)
#
# Which snapshot does `restore` take?
#
# WHY THIS MATTERS. Until 2026-09-08 the answer was always "the newest", with no
# way to ask for another. That is right for the case the script was written for --
# the platform is destroyed nightly and rebuilt from its own newest backup -- and
# it cannot express the case that arrives with Stage 2, when OpenBao becomes the
# store of record for application secrets and the disaster is "today's value is
# wrong, give me yesterday's". The bucket is versioned and keeps 120 days
# precisely so that is possible; nothing could reach any of it.
#
# A selector that picks the wrong object is silent data loss on the
# disaster-recovery path, so it is worth testing on its own. select_snapshot() is
# lifted out of the script rather than restated -- the same technique the
# fallback-address and zitadel suites use -- so this tests the code that ships.
#
# It has to be tested this way. Everything around the selector in restore()
# needs a live node and real credentials: a first attempt to drive it end to end
# never reached the selection at all, dying at the auth gate, and the attempt
# after that was refused by the script's own server-version check.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
fail=0
check() {
    if [ "$2" = "$3" ]; then printf '  ok   %s\n' "$1"
    else printf '  FAIL %s: expected %q got %q\n' "$1" "$2" "$3"; fail=1; fi
}
contains() {
    if printf '%s' "$2" | grep -qF -- "$3"; then printf '  ok   %s\n' "$1"
    else printf '  FAIL %s: %q not found in output\n' "$1" "$3"; fail=1; fi
}

SRC="${OPENBAO_SNAPSHOT_SCRIPT:-$HERE/openbao-snapshot.sh}"
body="$(sed -n '/^select_snapshot() {/,/^}/p' "$SRC")"
[ -n "$body" ] || { echo "could not extract select_snapshot() from $SRC" >&2; exit 1; }
eval "$body"

err="ERROR"
warn="WARN"
BUCKET_NAME="test-bucket"

# Oldest first, the order restore() builds (sorted by LastModified, not by name).
CANDIDATES="2026-09-05T092947Z-awskms.snap
2026-09-05T135753Z-awskms.snap
2026-09-05T151536Z-awskms.snap
2026-09-05T214320Z-awskms.snap"
NEWEST="2026-09-05T214320Z-awskms.snap"
OLDEST="2026-09-05T092947Z-awskms.snap"

echo "== default: no key set means the newest object"
SNAPSHOT_KEY=""
out=$(select_snapshot "$CANDIDATES" 2>/dev/null); rc=$?
check "returns the newest" "$NEWEST" "$out"
check "exit 0" "0" "$rc"
stderr=$(select_snapshot "$CANDIDATES" 2>&1 >/dev/null)
check "silent on the default path" "" "$stderr"

echo
echo "== a named object is honoured"
SNAPSHOT_KEY="$OLDEST"
out=$(select_snapshot "$CANDIDATES" 2>/dev/null); rc=$?
check "returns the named object" "$OLDEST" "$out"
check "exit 0" "0" "$rc"

echo
echo "== choosing a non-newest object announces what it discards"
stderr=$(select_snapshot "$CANDIDATES" 2>&1 >/dev/null)
contains "warns it is point-in-time" "$stderr" "POINT-IN-TIME RESTORE"
contains "names what it restores"    "$stderr" "restoring : $OLDEST"
contains "names what it skips"       "$stderr" "newest    : $NEWEST"
contains "states the consequence"    "$stderr" "is discarded"

echo
echo "== naming the newest object explicitly is not a point-in-time restore"
SNAPSHOT_KEY="$NEWEST"
out=$(select_snapshot "$CANDIDATES" 2>/dev/null)
stderr=$(select_snapshot "$CANDIDATES" 2>&1 >/dev/null)
check "returns it" "$NEWEST" "$out"
check "no discard warning, because nothing is discarded" "" "$stderr"

echo
echo "== an object that is not in the bucket is refused, before anything destructive"
SNAPSHOT_KEY="2026-01-01T000000Z-awskms.snap"
out=$(select_snapshot "$CANDIDATES" 2>/dev/null); rc=$?
check "exit 1" "1" "$rc"
check "emits no object name on stdout" "" "$out"
stderr=$(select_snapshot "$CANDIDATES" 2>&1 >/dev/null)
contains "names the bad key"     "$stderr" "is not in test-bucket"
contains "lists the real ones"   "$stderr" "available objects, oldest first"
contains "  and actually lists"  "$stderr" "$OLDEST"

echo
echo "== a near-miss is refused too: substrings must not match"
SNAPSHOT_KEY="092947Z-awskms.snap"
out=$(select_snapshot "$CANDIDATES" 2>/dev/null); rc=$?
check "partial name rejected" "1" "$rc"

echo
echo "== a single-object bucket still works"
SNAPSHOT_KEY=""
out=$(select_snapshot "$NEWEST" 2>/dev/null)
check "returns the only object" "$NEWEST" "$out"
SNAPSHOT_KEY="$NEWEST"
out=$(select_snapshot "$NEWEST" 2>/dev/null)
check "named, and it is also the newest" "$NEWEST" "$out"

echo
if [ "$fail" -eq 0 ]; then echo "all checks passed"; else echo "FAILURES"; fi
exit "$fail"
