#!/usr/bin/env bash
#
# pvc-unbound.sh with kubectl stubbed on PATH: a read-only report, so each
# case runs it against a canned `get pvc -A -o json` fixture and asserts on
# the printed lines and the exit code:
#   - one line per PersistentVolumeClaim whose phase is not Bound, as
#     "<namespace>/<name> <phase> <storageClass> <requested size> <age>",
#     oldest first, exit 0 whatever the count
#   - a Bound claim is not reported, even when it is the oldest of all
#   - a cluster where every claim is Bound: exit 0 and nothing printed
#   - the script-header check passes on it alone in a directory
#   - removing an unbound claim from the fixture removes its line (the test
#     is not vacuously green)
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SCRIPT="$ROOT/scripts/ops/k8s/pvc-unbound.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"

# The stub answers the one call the report makes from the fixture, like a
# real API server would. Matching on both spellings ("pvc" and
# "persistentvolumeclaims") so the script is free to name the resource either
# way.
cat >"$T/bin/kubectl" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *persistentvolumeclaim*|*pvc*)
    [ -z "${STUB_UNREACHABLE:-}" ] || exit 1
    cat "$FIXTURE" ;;
  *) echo "stub kubectl: unexpected call: $*" >&2; exit 1 ;;
esac
EOF
chmod +x "$T/bin/kubectl"

# Four claims: a Bound one older than everything else (so "oldest first" has
# to filter it, not just sort it), then the report's whole subject at three
# ages and two non-Bound phases. Ages sit far from unit boundaries so the
# expected regexes never race the clock.
oldest="$(date -u -d '500 days ago' +%Y-%m-%dT%H:%M:%SZ)"
old="$(date -u -d '400 days ago' +%Y-%m-%dT%H:%M:%SZ)"
mid="$(date -u -d '3 days ago' +%Y-%m-%dT%H:%M:%SZ)"
new="$(date -u -d '90 seconds ago' +%Y-%m-%dT%H:%M:%SZ)"
pvc() { # pvc <ns> <name> <created> <class> <size> <phase>
  printf '{
      "apiVersion": "v1", "kind": "PersistentVolumeClaim",
      "metadata": {"namespace": "%s", "name": "%s", "creationTimestamp": "%s"},
      "spec": {"storageClassName": "%s", "resources": {"requests": {"storage": "%s"}}},
      "status": {"phase": "%s"}
    }' "$1" "$2" "$3" "$4" "$5" "$6"
}
{
  printf '{"apiVersion": "v1", "kind": "List", "items": ['
  printf '%s,' "$(pvc monitoring prometheus-db "$oldest" standard-rwo 100Gi Bound)"
  printf '%s,' "$(pvc db-team data-warehouse "$old" standard-rwo 500Gi Pending)"
  printf '%s,' "$(pvc apps checkout-cache "$mid" premium-rwo 50Gi Lost)"
  printf '%s' "$(pvc apps scratch "$new" fast-rwo 1Gi Pending)"
  printf ']}\n'
} >"$T/fixture.json"

# run CASE [env...] -- args...: output to $T/CASE.out, stderr to $T/CASE.err, rc to $T/CASE.rc.
run() {
  local name="$1"; shift
  local envs=() args=()
  while [ $# -gt 0 ]; do
    [ "$1" = "--" ] && { shift; args=("$@"); break; }
    envs+=("$1"); shift
  done
  env FIXTURE="$T/fixture.json" PATH="$T/bin:$PATH" "${envs[@]}" \
    bash "$SCRIPT" "${args[@]}" >"$T/$name.out" 2>"$T/$name.err"
  echo $? >"$T/$name.rc"
}

fails=0
check() { if eval "$2"; then echo "  ok   $1"; else echo "  FAIL $1"; fails=1; fi; }

check "the script exists and is executable" '[ -x "$SCRIPT" ]'

# The header check takes a directory, so the script is copied alone into one:
# the check's verdict is then about this script only, never its neighbours.
mkdir -p "$T/headers"
if [ -f "$SCRIPT" ]; then cp "$SCRIPT" "$T/headers/"; fi
check "its first comment line states its purpose (the script-header check)" \
  '[ -x "$SCRIPT" ] && [ -z "$("$ROOT/scripts/ops/check-script-headers.sh" "$T/headers" 2>&1)" ]'

run report

check "fixture: exit 0, it is a report, not a gate" '[ "$(cat "$T/report.rc")" -eq 0 ]'
check "  ...exactly one line per unbound claim" '[ "$(wc -l <"$T/report.out")" -eq 3 ]'
check "  ...oldest unbound first, newest last" \
  '[ "$(awk "{print \$1}" "$T/report.out")" = "$(printf "db-team/data-warehouse\napps/checkout-cache\napps/scratch")" ]'
check "  ...a Pending claim as <ns>/<name> <phase> <class> <size> <age>" \
  'grep -Eq "^db-team/data-warehouse Pending standard-rwo 500Gi [0-9][0-9a-z]*$" "$T/report.out"'
check "  ...a Lost claim is reported too, not just Pending" \
  'grep -Eq "^apps/checkout-cache Lost premium-rwo 50Gi [0-9][0-9a-z]*$" "$T/report.out"'
check "  ...the newest claim is there, in seconds or minutes granularity" \
  'grep -Eq "^apps/scratch Pending fast-rwo 1Gi [0-9][0-9a-z]*$" "$T/report.out"'
check "  ...does not report the Bound claim, though it is the oldest of all" '! grep -q "monitoring/prometheus-db" "$T/report.out"'
check "  ...no Bound phase anywhere in the report" '! grep -q "Bound" "$T/report.out"'

# Every claim Bound: still exit 0, and nothing to say.
jq '{items: [.items[] | select(.status.phase != "Bound" | not)]}' "$T/fixture.json" >"$T/all-bound.json"
if FIXTURE="$T/all-bound.json" PATH="$T/bin:$PATH" bash "$SCRIPT" >"$T/all-bound.out" 2>"$T/all-bound.err"; then
  echo "  ok   all-bound fixture: exit 0 whatever the count"
else
  echo "  FAIL all-bound fixture: exit 0 whatever the count"; fails=1
fi
check "  ...prints nothing when every claim is Bound" '[ ! -s "$T/all-bound.out" ]'

# Negative control: drop the Lost claim from the fixture and its line must be
# gone, proving the expected-output checks above depend on the fixture.
jq '{items: [.items[] | select(.metadata.name != "checkout-cache")]}' "$T/fixture.json" >"$T/without-lost.json"
if FIXTURE="$T/without-lost.json" PATH="$T/bin:$PATH" \
   bash "$SCRIPT" | grep -q "apps/checkout-cache"; then
  echo "  FAIL negative control: the Lost claim was reported without its fixture entry"
  fails=1
else
  echo "  ok   negative control: removing the Lost claim removes its line (the expected-output checks would fail)"
fi

[ "$fails" -eq 0 ] && echo "all checks passed"
exit "$fails"
