#!/usr/bin/env bash
# Truth table for the TM_CLOUD selector.
G="$(dirname "$0")/tm-provisioner.sh"
fail=0
check() { # want_env lane expected
    local out
    if TM_CLOUD="$1" bash "$G" --tm-check "$2"; then out=yes; else out=no; fi
    if [ "$out" = "$3" ]; then printf '  ok   TM_CLOUD=%-10s lane=%-6s -> %s\n' "${1:-<unset>}" "$2" "$out"
    else printf '  FAIL TM_CLOUD=%-10s lane=%-6s -> %s (expected %s)\n' "${1:-<unset>}" "$2" "$out" "$3"; fail=1; fi
}

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

exit $fail
