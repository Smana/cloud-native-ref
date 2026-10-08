#!/usr/bin/env bash
# Resolution order and the failure path, with store and kubectl stubbed.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
fail=0
check() { if [ "$2" = "$3" ]; then printf '  ok   %s\n' "$1"
          else printf '  FAIL %s: expected %q got %q\n' "$1" "$2" "$3"; fail=1; fi }

# shellcheck source=scripts/lib/zitadel-pat.sh
. "$HERE/../../lib/zitadel-pat.sh"
# Every case below stubs store_probe; like the real one, this is false for
# "absent" and "cannot tell" alike, and it keeps the real CLI out of reach.
store_exists() { store_probe "$1"; }
THROTTLED="An error occurred (ThrottlingException) when calling the DescribeSecret operation: Rate exceeded"

CLOUD=aws REGION=eu-west-3 GCP_PROJECT=""
check "aws secret name" "zitadel/iam-admin-pat" "$(zitadel_pat_secret_name)"
CLOUD=gcp
check "gcp secret name" "zitadel-iam-admin-pat" "$(zitadel_pat_secret_name)"

CLOUD=aws
# 1. GCP parity GP-20 (owner, 2026-09-29): the cluster's PAT wins over a stored
#    one. A fresh directory every build makes a stored PAT belong to a directory
#    that no longer exists, and every call made with it gets a 401.
persisted=""
store_probe()  { return 0; }
store_read()   { printf '%s' '{"pat":"stale-token"}'; }
store_write()  { persisted="$(cat)"; }
kubectl()      { printf '%s' "dG9rZW4tZnJvbS1jbHVzdGVy"; }   # base64 of token-from-cluster
check "cluster wins over a stale store" "token-from-cluster" "$(resolve_zitadel_pat hosting 2>/dev/null)"
resolve_zitadel_pat hosting >/dev/null 2>&1
check "the stale store is overwritten" "token-from-cluster" "$(printf '%s' "$persisted" | jq -r .pat)"

# 1a. Same token in both: no rewrite (one Secret Manager version per change).
store_write_called=0
store_read()   { printf '%s' '{"pat":"token-from-cluster"}'; }
store_write()  { store_write_called=1; cat >/dev/null; }
resolve_zitadel_pat hosting >/dev/null 2>&1
check "an equal store is not rewritten" "0" "$store_write_called"

# 1b. No cluster Secret (a directory restored from a seed): the store is used.
store_read()   { printf '%s' '{"pat":"token-from-store"}'; }
kubectl()      { return 1; }
check "the store serves a restored directory" "token-from-store" "$(resolve_zitadel_pat hosting 2>/dev/null)"

# 2. Store empty, cluster has it -> used AND persisted.
persisted=""
store_probe()  { return 1; }
store_read()   { return 1; }
# A stub called via a herestring runs in the CURRENT shell, so this assignment
# is visible to the test -- called via a pipe it would run in a subshell and
# vanish, which is also why the library uses `store_write ... <<< "$json"`.
store_write()  { persisted="$(cat)"; }
kubectl()      { printf '%s' "dG9rZW4tZnJvbS1jbHVzdGVy"; }   # base64 of token-from-cluster
check "cluster seeds" "token-from-cluster" "$(resolve_zitadel_pat hosting 2>/dev/null)"
resolve_zitadel_pat hosting >/dev/null 2>&1
check "persisted"     "token-from-cluster" "$(printf '%s' "$persisted" | jq -r .pat)"

# 2a. DEFECT 2: store empty, cluster has it, caller is in a DRY RUN
#     (ZITADEL_PAT_DRY_RUN=true) -> the token is still returned (it is not
#     lost -- it is right there in the Kubernetes Secret), but store_write
#     must NOT be called. Live symptom this closes: zitadel-oidc-clients.sh
#     promises "Dry-run unless --apply" and persisted the PAT into Secrets
#     Manager anyway, on a plain sync with no --apply, because nothing told
#     this shared resolver a dry run was in progress.
#
# Same two-call shape as test 2's "persisted" check above and for the same
# reason: the first call's `$(...)` runs resolve_zitadel_pat in a subshell,
# so a mutation store_write makes there (even via a herestring, which does
# NOT fork its own subshell) is still lost when THAT subshell exits. The
# second, bare call runs resolve_zitadel_pat in the CURRENT shell, so
# store_write_called's mutation (or lack of one) is actually visible here.
store_write_called=0
store_probe()  { return 1; }
store_read()   { return 1; }
store_write()  { store_write_called=1; cat >/dev/null; }
kubectl()      { printf '%s' "dG9rZW4tZnJvbS1jbHVzdGVy"; }   # base64 of token-from-cluster
ZITADEL_PAT_DRY_RUN=true
check "dry-run: token still returned" "token-from-cluster" "$(resolve_zitadel_pat hosting 2>/dev/null)"
resolve_zitadel_pat hosting >/dev/null 2>&1
check "dry-run: store_write NOT called" "0" "$store_write_called"
err="$(resolve_zitadel_pat hosting 2>&1 >/dev/null)"
case "$err" in *'[dry-run]'*) printf '  ok   dry-run: prints [dry-run], not [persist]\n' ;;
               *) printf '  FAIL dry-run: did not print a [dry-run] line\n'; fail=1 ;; esac
case "$err" in *'[persist]'*) printf '  FAIL dry-run: also printed [persist]\n'; fail=1 ;;
               *) printf '  ok   dry-run: no [persist] line\n' ;; esac
unset ZITADEL_PAT_DRY_RUN

# Left unset entirely (no caller opts in) -> unchanged behaviour: still
# persists. This is the default every caller had before ZITADEL_PAT_DRY_RUN
# existed, and the one every caller still gets unless it explicitly sets the
# variable to "true".
store_write_called=0
store_probe()  { return 1; }
store_read()   { return 1; }
store_write()  { store_write_called=1; cat >/dev/null; }
kubectl()      { printf '%s' "dG9rZW4tZnJvbS1jbHVzdGVy"; }
check "unset ZITADEL_PAT_DRY_RUN: token returned" "token-from-cluster" "$(resolve_zitadel_pat hosting 2>/dev/null)"
resolve_zitadel_pat hosting >/dev/null 2>&1
check "unset ZITADEL_PAT_DRY_RUN: still persists (default false)" "1" "$store_write_called"

# 2b. A caller sets STORE_WRITE_DESCRIPTION/LABEL for its OWN secrets (this is
#     exactly what zitadel-oidc-clients.sh does) and THEN resolves the PAT.
#     Those globals must not leak into the PAT's write -- resolve_zitadel_pat
#     owns its own provenance via `local`, which shadows the caller's value
#     for store_write and leaves the caller's value intact afterwards.
STORE_WRITE_DESCRIPTION="caller-provenance"
STORE_WRITE_LABEL="caller-label"
CLUSTER="aws-0"
seen_desc="" seen_label=""
store_probe()  { return 1; }
store_read()   { return 1; }
store_write()  { seen_desc="$STORE_WRITE_DESCRIPTION"; seen_label="$STORE_WRITE_LABEL"; cat >/dev/null; }
kubectl()      { printf '%s' "dG9rZW4tZnJvbS1jbHVzdGVy"; }   # base64 of token-from-cluster
resolve_zitadel_pat hosting >/dev/null 2>&1
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
store_probe()  { return 1; }
store_read()   { return 1; }
store_write()  { seeded="$(cat)"; }
kubectl()      { printf '%s' "$awkward" | base64 -w0; }
check "awkward token seeds"     "$awkward" "$(resolve_zitadel_pat hosting 2>/dev/null)"
# A second, unwrapped call so store_write's assignment to $seeded (visible only
# because the library uses a herestring, not a pipe -- see above) isn't lost
# inside the command substitution's own subshell the check above just ran in.
resolve_zitadel_pat hosting >/dev/null 2>&1

store_probe()  { return 0; }
store_read()   { printf '%s' "$seeded"; }
kubectl()      { echo "KUBECTL MUST NOT BE CALLED" >&2; return 1; }
check "awkward token reads back" "$awkward" "$(resolve_zitadel_pat hosting 2>/dev/null)"

# 4. Neither -> fail, with a diagnosis, and no token on stdout.
store_probe()  { return 1; }
store_read()   { return 1; }
kubectl()      { return 1; }
out="$(resolve_zitadel_pat hosting 2>/dev/null)"; rc=$?
check "fails"         "1"  "$rc"
check "silent stdout" ""   "$out"
err="$(resolve_zitadel_pat hosting 2>&1 >/dev/null)"
case "$err" in *FIRSTINSTANCE*) printf '  ok   explains FirstInstance\n' ;;
               *) printf '  FAIL error does not explain the cause\n'; fail=1 ;; esac

# 5. Review I-1: a CONSUMING cluster (--idp-cloud differs) has kubectl on its
#    own cluster. A chart Secret left there from when it hosted belongs to a
#    dead directory; trusting it would overwrite the IdP cloud's only PAT and
#    401 every call there. The store answers, and nothing is written.
store_write_called=0
KUBECTL_MARK="$(mktemp)"; rm -f "$KUBECTL_MARK"   # kubectl runs inside $(...): a variable would not survive
store_probe()  { return 0; }
store_read()   { printf '%s' '{"pat":"token-from-idp-store"}'; }
store_write()  { store_write_called=1; cat >/dev/null; }
kubectl()      { : > "$KUBECTL_MARK"; printf '%s' "dG9rZW4tZnJvbS1jbHVzdGVy"; }   # leftover Secret
check "consuming: the IdP store's PAT, not the local Secret" "token-from-idp-store" "$(resolve_zitadel_pat consuming 2>/dev/null)"
resolve_zitadel_pat consuming >/dev/null 2>&1
check "consuming: the IdP store is never written" "0" "$store_write_called"
check "consuming: the local Secret is never read" "no" "$([ -e "$KUBECTL_MARK" ] && echo yes || echo no)"
rm -f "$KUBECTL_MARK"

# 5a. Consuming with an empty store: fail, still without trusting the local Secret.
store_probe()  { return 1; }
store_read()   { return 1; }
out="$(resolve_zitadel_pat consuming 2>/dev/null)"; rc=$?
check "consuming, empty store: fails" "1" "$rc"
check "consuming, empty store: no local token leaks out" "" "$out"

# 5b. No role is a caller bug, not a guess.
resolve_zitadel_pat >/dev/null 2>&1; rc=$?
check "no role: refused" "2" "$rc"

# 6. Review M-2: a failed overwrite warns and still returns the cluster token.
store_probe()  { return 0; }
store_read()   { printf '%s' '{"pat":"stale-token"}'; }
store_write()  { cat >/dev/null; return 1; }
kubectl()      { printf '%s' "dG9rZW4tZnJvbS1jbHVzdGVy"; }
out="$(resolve_zitadel_pat hosting 2>/dev/null)"; rc=$?
check "failed overwrite: token still returned" "token-from-cluster" "$out"
check "failed overwrite: rc 0" "0" "$rc"
err="$(resolve_zitadel_pat hosting 2>&1 >/dev/null)"
case "$err" in *"WARN: zitadel/iam-admin-pat still holds the old PAT; the next --apply retries"*)
                 printf '  ok   failed overwrite: warns on stderr\n' ;;
               *) printf '  FAIL failed overwrite: no WARN line\n'; fail=1 ;; esac

# 7. Review M-5: a dry run over a stale store returns the cluster token and writes nothing.
store_write_called=0
store_write()  { store_write_called=1; cat >/dev/null; }
ZITADEL_PAT_DRY_RUN=true
check "dry-run, stale store: cluster token returned" "token-from-cluster" "$(resolve_zitadel_pat hosting 2>/dev/null)"
resolve_zitadel_pat hosting >/dev/null 2>&1
check "dry-run, stale store: nothing written" "0" "$store_write_called"
unset ZITADEL_PAT_DRY_RUN

# 8. #2086: a failed read is not an empty store. Taken for one, the store was
#    rewritten, or the operator told to mint a PAT the store already holds.
store_probe()  { STORE_PROBE_ERR="$THROTTLED"; return 2; }
store_read()   { printf '%s' '{"pat":"token-from-store"}'; }
store_write_called=0
store_write()  { store_write_called=1; cat >/dev/null; }
kubectl()      { printf '%s' "dG9rZW4tZnJvbS1jbHVzdGVy"; }   # base64 of token-from-cluster
check "throttled, cluster has it: token returned" "token-from-cluster" "$(resolve_zitadel_pat hosting 2>/dev/null)"
ERR="$(mktemp)"
resolve_zitadel_pat hosting >/dev/null 2>"$ERR"   # bare: store_write_called must survive
check "throttled, cluster has it: store not rewritten" "0" "$store_write_called"
check "throttled, cluster has it: shows the store error" yes "$(grep -q ThrottlingException "$ERR" && echo yes || echo no)"
rm -f "$ERR"

store_write_called=0
store_probe()  { return 0; }
store_read()   { return 254; }
resolve_zitadel_pat hosting >/dev/null 2>&1
check "unreadable, cluster has it: store not rewritten" "0" "$store_write_called"

store_probe()  { STORE_PROBE_ERR="$THROTTLED"; return 2; }
kubectl()      { return 1; }
for role in hosting consuming; do
    out="$(resolve_zitadel_pat "$role" 2>/dev/null)"; rc=$?
    err="$(resolve_zitadel_pat "$role" 2>&1 >/dev/null)"
    check "throttled, $role, no cluster Secret: fails" "1" "$rc"
    check "throttled, $role, no cluster Secret: silent stdout" "" "$out"
    check "throttled, $role: shows the store error" yes "$(grep -q ThrottlingException <<< "$err" && echo yes || echo no)"
    check "throttled, $role: no mint-a-PAT advice" no "$(grep -qE 'Mint a PAT|sync --apply first' <<< "$err" && echo yes || echo no)"
done

exit $fail
