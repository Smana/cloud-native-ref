#!/usr/bin/env bash
# Resolution order and the failure path, with store and kubectl stubbed.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
fail=0
check() { if [ "$2" = "$3" ]; then printf '  ok   %s\n' "$1"
          else printf '  FAIL %s: expected %q got %q\n' "$1" "$2" "$3"; fail=1; fi }

# shellcheck source=scripts/lib/zitadel-pat.sh
. "$HERE/lib/zitadel-pat.sh"

CLOUD=aws REGION=eu-west-3 GCP_PROJECT=""
check "aws secret name" "zitadel/iam-admin-pat" "$(zitadel_pat_secret_name)"
CLOUD=gcp
check "gcp secret name" "zitadel-iam-admin-pat" "$(zitadel_pat_secret_name)"

CLOUD=aws
# 1. Store has it -> used, and the cluster is never consulted. The store holds
#    a JSON object ({"pat": ...}), matching what store_write actually accepts
#    on its AWS branch (bare strings fail to parse as JSON there).
store_exists() { return 0; }
store_read()   { printf '%s' '{"pat":"token-from-store"}'; }
kubectl()      { echo "KUBECTL MUST NOT BE CALLED" >&2; return 1; }
check "store wins" "token-from-store" "$(resolve_zitadel_pat)"

# 2. Store empty, cluster has it -> used AND persisted.
persisted=""
store_exists() { return 1; }
store_read()   { return 1; }
# A stub called via a herestring runs in the CURRENT shell, so this assignment
# is visible to the test -- called via a pipe it would run in a subshell and
# vanish, which is also why the library uses `store_write ... <<< "$json"`.
store_write()  { persisted="$(cat)"; }
kubectl()      { printf '%s' "dG9rZW4tZnJvbS1jbHVzdGVy"; }   # base64 of token-from-cluster
check "cluster seeds" "token-from-cluster" "$(resolve_zitadel_pat 2>/dev/null)"
resolve_zitadel_pat >/dev/null 2>&1
check "persisted"     "token-from-cluster" "$(printf '%s' "$persisted" | jq -r .pat)"

# 2b. A caller sets STORE_WRITE_DESCRIPTION/LABEL for its OWN secrets (this is
#     exactly what zitadel-oidc-clients.sh does) and THEN resolves the PAT.
#     Those globals must not leak into the PAT's write -- resolve_zitadel_pat
#     owns its own provenance via `local`, which shadows the caller's value
#     for store_write and leaves the caller's value intact afterwards.
STORE_WRITE_DESCRIPTION="caller-provenance"
STORE_WRITE_LABEL="caller-label"
CLUSTER="aws-0"
seen_desc="" seen_label=""
store_exists() { return 1; }
store_read()   { return 1; }
store_write()  { seen_desc="$STORE_WRITE_DESCRIPTION"; seen_label="$STORE_WRITE_LABEL"; cat >/dev/null; }
kubectl()      { printf '%s' "dG9rZW4tZnJvbS1jbHVzdGVy"; }   # base64 of token-from-cluster
resolve_zitadel_pat >/dev/null 2>&1
check "PAT write ignores caller's Description" \
    "ZITADEL iam-admin PAT for aws-0. Captured by zitadel-pat.sh." "$seen_desc"
check "PAT write ignores caller's Label" "zitadel-pat" "$seen_label"
check "caller's Description survives the call" "caller-provenance" "$STORE_WRITE_DESCRIPTION"
check "caller's Label survives the call"       "caller-label"      "$STORE_WRITE_LABEL"
unset STORE_WRITE_DESCRIPTION STORE_WRITE_LABEL CLUSTER

# 3. An awkward token -- embedded double quote, backslash, tab and a newline --
#    survives the seed-then-read round trip byte-identical. This is the case a
#    hand-built JSON string (or `jq --arg`, which also puts the token in jq's
#    argv) would get wrong, and the one nobody would notice broke.
awkward=$'tok"en\\with\ttabs and\na newline in the middle'
seeded=""
store_exists() { return 1; }
store_read()   { return 1; }
store_write()  { seeded="$(cat)"; }
kubectl()      { printf '%s' "$awkward" | base64 -w0; }
check "awkward token seeds"     "$awkward" "$(resolve_zitadel_pat 2>/dev/null)"
# A second, unwrapped call so store_write's assignment to $seeded (visible only
# because the library uses a herestring, not a pipe -- see above) isn't lost
# inside the command substitution's own subshell the check above just ran in.
resolve_zitadel_pat >/dev/null 2>&1

store_exists() { return 0; }
store_read()   { printf '%s' "$seeded"; }
kubectl()      { echo "KUBECTL MUST NOT BE CALLED" >&2; return 1; }
check "awkward token reads back" "$awkward" "$(resolve_zitadel_pat 2>/dev/null)"

# 4. Neither -> fail, with a diagnosis, and no token on stdout.
store_exists() { return 1; }
store_read()   { return 1; }
kubectl()      { return 1; }
out="$(resolve_zitadel_pat 2>/dev/null)"; rc=$?
check "fails"         "1"  "$rc"
check "silent stdout" ""   "$out"
err="$(resolve_zitadel_pat 2>&1 >/dev/null)"
case "$err" in *FIRSTINSTANCE*) printf '  ok   explains FirstInstance\n' ;;
               *) printf '  FAIL error does not explain the cause\n'; fail=1 ;; esac

exit $fail
