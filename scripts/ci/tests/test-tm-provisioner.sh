#!/usr/bin/env bash
# Truth table for the TM_CLOUD selector, against a fixture primary_cloud so the
# table does not change with the repository's own config.tm.hcl.
HERE="$(cd "$(dirname "$0")" && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/scripts/provision" "$tmp/opentofu"
cp "$HERE/../../provision/tm-provisioner.sh" "$tmp/scripts/provision/"
G="$tmp/scripts/provision/tm-provisioner.sh"
primary() { printf 'globals {\n  primary_cloud = "%s"\n}\n' "$1" >"$tmp/opentofu/config.tm.hcl"; }
fail=0
check() { # want_env lane expected
    local out
    if TM_CLOUD="$1" bash "$G" --tm-check "$2"; then out=yes; else out=no; fi
    if [ "$out" = "$3" ]; then printf '  ok   TM_CLOUD=%-10s lane=%-6s -> %s\n' "${1:-<unset>}" "$2" "$out"
    else printf '  FAIL TM_CLOUD=%-10s lane=%-6s -> %s (expected %s)\n' "${1:-<unset>}" "$2" "$out" "$3"; fail=1; fi
}
check_rc() { # want_env lane expected_rc
    local rc
    TM_CLOUD="$1" bash "$G" --tm-check "$2" 2>/dev/null; rc=$?
    if [ "$rc" = "$3" ]; then printf '  ok   TM_CLOUD=%-10s lane=%-6s -> exit %s\n' "${1:-<unset>}" "$2" "$rc"
    else printf '  FAIL TM_CLOUD=%-10s lane=%-6s -> exit %s (expected %s)\n' "${1:-<unset>}" "$2" "$rc" "$3"; fail=1; fi
}

primary aws
# default: aws alone
check ""          aws    yes
check ""          gcp    no
check ""          shared yes
# explicit single
check "gcp"       gcp    yes
check "gcp"       aws    no
# list
check "aws,gcp"   aws    yes
check "aws,gcp"   gcp    yes
# list with spaces
check "aws, gcp"  gcp    yes
# all
check "all"       aws    yes
check "all"       gcp    yes
# a future third cloud needs no new keyword
check "azure"     azure  yes
check "aws"       azure  no
check "all"       azure  yes
# shared always runs
check "gcp"       shared yes
# near-miss must not match a substring
check "gcp"       gc     no
check "awsx"      aws    no

# GCP primary (ADR-0052): an unset TM_CLOUD is refused with exit 3 on every
# lane, shared included, rather than silently meaning aws. Exit 1 stays "skip".
primary gcp
check_rc ""       aws    3
check_rc ""       gcp    3
check_rc ""       shared 3
check_rc "gcp"    gcp    0
check_rc "gcp"    aws    1
check_rc "aws"    aws    0

exit $fail
