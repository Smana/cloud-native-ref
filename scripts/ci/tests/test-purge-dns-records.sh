#!/usr/bin/env bash
#
# purge-dns-records.sh with gcloud stubbed on PATH, no credentials or network:
# an absent zone and an empty one are reported and exit 0 (a re-run destroy must
# not fail here); a populated zone has every non-apex record deleted and NS/SOA
# never touched; a delete that fails is counted and fails the run.
#
# The script's only destructive call is the record-sets delete, and its only
# guard is the NS/SOA filter on the list. The suite must fail if either goes:
# the edits are made in a copy of the script, checked, then discarded.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
# Absolute: purge-dns-records.sh sources its library by dirname, and a relative
# PATH entry lets bash resolve a real gcloud.
T="$(cd "$(mktemp -d)" && pwd -P)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"
cat >"$T/bin/gcloud" <<EOF
#!/usr/bin/env bash
echo "\$*" >>"$T/calls"
case "\$*" in
  --stub-probe) echo stub ;;
  *"auth application-default print-access-token"*) echo fake-token ;;
  *"dns managed-zones describe"*)
    [ -z "\${ZONE_ABSENT:-}" ] || exit 1 ;;
  *"dns record-sets list"*)
    # name<TAB>type, apex NS/SOA included so the filter is what excludes them.
    # Real tabs in the format string: %s would keep the \t literal.
    [ -z "\${EMPTY_ZONE:-}" ] || exit 0
    printf 'apps.example.com.\tA\na-apps.example.com.\tTXT\nexample.com.\tNS\nexample.com.\tSOA\n' ;;
  *"dns record-sets delete"*)
    echo "\$*" >>"$T/deletes"
    [ -z "\${FAIL_RECORD:-}" ] || case "\$*" in
      *"\$FAIL_RECORD"*) exit 1 ;;
    esac ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$T/bin/gcloud"

require_stub() { # abort the whole test unless the gcloud that runs is the stub
  case "$T" in /*) ;; *) echo "ABORT: stub dir '$T' is not absolute" >&2; exit 1 ;; esac
  if [ "$(command -v gcloud)" != "$T/bin/gcloud" ] \
     || [ "$("$T/bin/gcloud" --stub-probe 2>/dev/null)" != stub ]; then
    echo "ABORT: gcloud resolves to '$(command -v gcloud)', not the stub in $T/bin;" \
         "refusing to run purge-dns-records.sh against a real cloud" >&2
    exit 1
  fi
}
export PATH="$T/bin:$PATH"

S="$ROOT/scripts/ops/gcp/purge-dns-records.sh"
fails=0
f() { echo "FAIL $*"; fails=1; }

# No arguments: usage on stderr, exit 2, and no gcloud call at all.
: >"$T/calls"
require_stub
out="$(bash "$S" 2>"$T/err")"; rc=$?
[ "$rc" -eq 2 ] || f "no args must exit 2, got $rc"
grep -q '^usage: ' "$T/err" || f "no usage line on stderr"
sed -i '/^--stub-probe$/d' "$T/calls" # the probe is not the script under test
[ ! -s "$T/calls" ] || f "no args still called gcloud"

# Absent zone: reported, exit 0, nothing listed or deleted.
: >"$T/calls"
require_stub
out="$(ZONE_ABSENT=1 bash "$S" a-zone ogenki-435905 2>&1)"; rc=$?
[ "$rc" -eq 0 ] || f "an absent zone must exit 0, got $rc"
grep -q "a-zone' does not exist" <<<"$out" || f "the absent zone is not reported"
grep -q 'record-sets list' "$T/calls" && f "an absent zone was still listed"
[ ! -e "$T/deletes" ] || f "an absent zone still deleted something"

# Empty zone: reported, exit 0, nothing deleted.
require_stub
out="$(EMPTY_ZONE=1 bash "$S" a-zone ogenki-435905 2>&1)"; rc=$?
[ "$rc" -eq 0 ] || f "an empty zone must exit 0, got $rc"
grep -q "holds no deletable records" <<<"$out" || f "the empty zone is not reported"
[ ! -e "$T/deletes" ] || f "an empty zone still deleted something"

# Populated zone: the two external-dns records go, the apex NS/SOA stays.
rm -f "$T/deletes"; : >"$T/calls"
require_stub
out="$(bash "$S" a-zone ogenki-435905 2>&1)"; rc=$?
[ "$rc" -eq 0 ] || f "a clean purge must exit 0, got $rc"
[ "$(wc -l <"$T/deletes")" -eq 2 ] || f "expected 2 deletes, got: $(cat "$T/deletes" 2>/dev/null)"
grep -q 'record-sets delete apps.example.com. --type A --zone a-zone --project ogenki-435905' "$T/deletes" \
  || f "the A record was not deleted with name, type, zone and project"
grep -q 'delete a-apps.example.com. --type TXT' "$T/deletes" || f "the TXT record was not deleted"
if grep -qE 'delete (example.com. )?--type (NS|SOA)' "$T/deletes" 2>/dev/null; then
  f "an apex NS/SOA record was deleted"
fi
grep -q 'apex NS/SOA' <<<"$out" || f "the apex note is missing"
grep -q "Purging 2 record" <<<"$out" || f "the count is wrong"

# A record that refuses to delete: counted, warned, exit 1.
rm -f "$T/deletes"
require_stub
out="$(FAIL_RECORD='a-apps.example.com.' bash "$S" a-zone ogenki-435905 2>&1)"; rc=$?
[ "$rc" -eq 1 ] || f "a failed delete must exit 1, got $rc"
grep -q 'FAILED   TXT a-apps.example.com.' <<<"$out" || f "the failed record is not reported"
grep -q 'containerNotEmpty' <<<"$out" || f "the containerNotEmpty warning is missing"

# The destructive call and its guard must not be removable in silence: apply the
# same assertions as the happy path to a mutated copy; if they all still hold,
# the mutation is undetectable and the test fails.
mutant() { # $1 = description, $2 = sed on a copy of the script
  local what="$1" sedexpr="$2" m="$T/mutant.sh"
  sed "$sedexpr" "$S" >"$m"
  rm -f "$T/deletes"
  require_stub
  local out rc
  out="$(bash "$m" a-zone ogenki-435905 2>&1)"; rc=$?
  if [ "$rc" -eq 0 ] && [ -s "$T/deletes" ] \
     && [ "$(wc -l <"$T/deletes")" -eq 2 ] \
     && ! grep -qE ' --type (NS|SOA)' "$T/deletes" \
     && grep -q 'Purging 2 record' <<<"$out"; then
    echo "MUTANT SURVIVED: $what" >&2
    fails=1
  fi
}
# The delete dropped entirely: still exit 0, nothing deleted -- must fail.
mutant "the delete call was removed" 's/dns record-sets delete/dns record-sets nodelete/'
# The guard bypassed: NS/SOA now in the deletes -- must fail.
mutant "the NS/SOA guard was bypassed" "s/&& \$2 != \"SOA\"//"

[ "$fails" -eq 0 ] && echo PASS
exit "$fails"
