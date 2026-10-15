#!/usr/bin/env bash
#
# purge-dns-records.sh with gcloud stubbed on PATH. The script has no dry run:
# every run that finds records deletes them, so the cases are the header's
# guards. Missing arguments refuse, an absent or apex-only zone exits 0 without
# deleting, apex NS/SOA are never deleted, every other record is, a failed
# delete exits 1, and every call runs as the ADC identity.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
T="$(cd "$(mktemp -d)" && pwd -P)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"
cat >"$T/bin/gcloud" <<EOF
#!/usr/bin/env bash
[ "\$1" != --stub-probe ] || { echo stub; exit 0; }
echo "\${CLOUDSDK_AUTH_ACCESS_TOKEN:-none} \$*" >>"$T/calls"
case "\$*" in
  *"print-access-token"*) echo fake-token ;;
  *"managed-zones describe"*) [ -z "\${ZONE_ABSENT:-}" ] ;;
  *"record-sets list"*) printf '%b' "\${RECORDS:-}" ;;
  *"record-sets delete"*)
    case "\$*" in *"\${DELETE_FAIL:-<none>}"*) exit 1 ;; esac
    echo "\$*" >>"$T/deletes" ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$T/bin/gcloud"
export PATH="$T/bin:$PATH"
# A stub that failed to land would let the real gcloud delete live records.
if [ "$(command -v gcloud)" != "$T/bin/gcloud" ] || [ "$(gcloud --stub-probe)" != stub ]; then
  echo "ABORT: gcloud resolves to '$(command -v gcloud)', not the stub" >&2
  exit 1
fi

APEX='priv.example.\tNS\npriv.example.\tSOA\n'
LIVE='app.priv.example.\tA\na-app.priv.example.\tTXT\napi.priv.example.\tCNAME\n'
purge() { rm -f "$T/calls" "$T/deletes"; bash "$ROOT/scripts/ops/gcp/purge-dns-records.sh" "$@" 2>&1; }
deletes() { [ -f "$T/deletes" ] && wc -l <"$T/deletes" || echo 0; }

fails=0
check() { if eval "$2"; then echo "  ok   $1"; else echo "  FAIL $1"; fails=1; fi; }

# out and rc are read inside check's eval strings, where the linter cannot see them.
# shellcheck disable=SC2034
{
out="$(purge private-zone)"; rc=$?
check "a missing project is refused with exit 2" '[ "$rc" -eq 2 ] && grep -q usage <<<"$out"'
check "  ...before any gcloud call" '[ ! -f "$T/calls" ]'

out="$(ZONE_ABSENT=1 purge private-zone my-project)"; rc=$?
check "an absent zone exits 0" '[ "$rc" -eq 0 ] && grep -q "does not exist" <<<"$out"'
check "  ...deleting nothing" '[ "$(deletes)" -eq 0 ]'

out="$(RECORDS="$APEX" purge private-zone my-project)"; rc=$?
check "an apex-only zone exits 0" '[ "$rc" -eq 0 ] && grep -q "no deletable records" <<<"$out"'
check "  ...deleting nothing" '[ "$(deletes)" -eq 0 ]'

out="$(RECORDS="$APEX$LIVE" purge private-zone my-project)"; rc=$?
check "a populated zone exits 0" '[ "$rc" -eq 0 ] && grep -q "Purging 3 record set" <<<"$out"'
check "  ...deleting the A, TXT and CNAME" '[ "$(deletes)" -eq 3 ]'
check "  ...by name and type, in the zone and project" 'grep -qs "delete a-app.priv.example. --type TXT --zone private-zone --project my-project" "$T/deletes"'
check "  ...never the apex NS or SOA" '[ -f "$T/deletes" ] && ! grep -Eq -- "--type (NS|SOA)" "$T/deletes"'
check "every gcloud call runs as the ADC identity" '! grep -v "print-access-token" "$T/calls" | grep -qv "^fake-token "'

out="$(RECORDS="$APEX$LIVE" DELETE_FAIL=api.priv.example. purge private-zone my-project)"; rc=$?
check "a failed delete exits 1" '[ "$rc" -eq 1 ] && grep -q "FAILED   CNAME api.priv.example." <<<"$out"'
check "  ...after still deleting the rest" '[ "$(deletes)" -eq 2 ]'
check "  ...warning that the zone destroy will fail" 'grep -q containerNotEmpty <<<"$out"'
}

[ "$fails" -eq 0 ] && echo "all checks passed"
exit "$fails"
