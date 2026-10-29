#!/usr/bin/env bash
# requires: python3
#
# cert-expiry.sh with kubectl stubbed on PATH, plus the two standing views the
# task ships beside it: the "Certificates" GrafanaDashboard CR and the docs
# page. Each case runs the script against a canned
# `kubectl get certificates -A -o json` fixture and asserts on the printed
# lines and the exit code:
#   - one "<namespace>/<name> <notAfter> <days left>" line per Certificate
#     expiring within the window (default 30 days), soonest first
#   - an already-expired Certificate is "within" the window and shows a
#     negative days-left value
#   - a Certificate outside the window is not reported, and neither is its
#     name anywhere
#   - a Certificate with no spec.notAfter is skipped
#   - --days N widens the window to N days
#   - an unreachable cluster: warning on stderr, nothing on stdout, exit 0
#   - an empty cluster: nothing printed, exit 0
#   - the negative control (dropping an in-window Certificate from the
#     fixture) proves the expected-output check is not vacuously green
#
# The fixture's notAfter values are generated relative to the real clock at
# the moment the test runs: the script under test computes "days left" from
# the wall clock, so a canned epoch would drift. Each offset is a whole number
# of days plus one hour, so the day values stay stable for the seconds the
# test takes and floor and round agree on every one of them.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"

# One clock reading for the whole run: the fixture and the expected notAfter
# strings both come from it.
NOW="$(date -u +%s)"

# cert <offset-seconds> <namespace> <name>: a Certificate expiring at
# NOW + offset, with notAfter in the ISO form the API server reports.
cert() {
  jq -rn --argjson now "$NOW" --argjson off "$1" --arg ns "$2" --arg name "$3" \
    '{apiVersion: "cert-manager.io/v1", kind: "Certificate",
      metadata: {namespace: $ns, name: $name},
      spec: {notAfter: ($now + $off | todateiso8601)}}'
}

# a: expired 2 days ago; b: 10 days; d: 25 days (all within the default 30-day
# window, in that soonest-first order); c: 45 days (outside it); e: no
# spec.notAfter at all.
{
  cert -165600 security a-expired
  cert 867600 observability b-soon
  cert 3891600 apps c-much-later
  cert 2163600 istio-system d-in-window
  printf '{"apiVersion": "cert-manager.io/v1", "kind": "Certificate", "metadata": {"namespace": "apps", "name": "e-no-notafter"}, "spec": {}}'
} | jq -s '{apiVersion: "v1", kind: "List", items: .}' >"$T/fixture.json"

# The expected <notAfter> column, from the same clock reading.
exp() { jq -rn --argjson now "$NOW" --argjson off "$1" '$now + $off | todateiso8601'; }
A="$(exp -165600)"; B="$(exp 867600)"; C="$(exp 3891600)"; D="$(exp 2163600)"

cat >"$T/bin/kubectl" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *certificates.cert-manager.io*)
    [ -z "${STUB_UNREACHABLE:-}" ] || exit 1
    cat "$FIXTURE" ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$T/bin/kubectl"

# run CASE -- [env=val...] -- args...: stdout/stderr/rc under $T/CASE.*
run() {
  local name="$1"; shift
  local envs=() args=()
  while [ $# -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done
  [ "${1:-}" = "--" ] && { shift; args=("$@"); }
  env FIXTURE="$T/fixture.json" PATH="$T/bin:$PATH" "${envs[@]}" \
    bash "$ROOT/scripts/ops/k8s/cert-expiry.sh" "${args[@]}" >"$T/$name.out" 2>"$T/$name.err"
  echo $? >"$T/$name.rc"
}

fails=0
check() { if eval "$2"; then echo "  ok   $1"; else echo "  FAIL $1"; fails=1; fi; }

echo "scripts/ops/k8s/cert-expiry.sh:"
run default-window

check "fixture: exit 0, a report never fails the caller" '[ "$(cat "$T/default-window.rc")" -eq 0 ]'
check "  ...prints exactly one line per in-window Certificate, soonest first" \
  'printf "%s\n" "security/a-expired '"$A"' -2" "observability/b-soon '"$B"' 10" "istio-system/d-in-window '"$D"' 25" | diff - "$T/default-window.out"'
check "  ...does not report the out-of-window Certificate" '! grep -q "c-much-later" "$T/default-window.out"'
check "  ...does not report the Certificate with no spec.notAfter" '! grep -q "e-no-notafter" "$T/default-window.out"'
check "  ...says nothing on stderr" '[ ! -s "$T/default-window.err" ]'

run days-narrow -- --days 5

check "--days 5: exit 0" '[ "$(cat "$T/days-narrow.rc")" -eq 0 ]'
check "  ...reports only the expired Certificate" \
  'grep -qx "security/a-expired '"$A"' -2" "$T/days-narrow.out" && [ "$(wc -l <"$T/days-narrow.out")" -eq 1 ]'

run days-wide -- --days 60

check "--days 60: all four expiring certificates, still soonest first, exit 0" \
  'printf "%s\n" "security/a-expired '"$A"' -2" "observability/b-soon '"$B"' 10" "istio-system/d-in-window '"$D"' 25" "apps/c-much-later '"$C"' 45" | diff - "$T/days-wide.out" && [ "$(cat "$T/days-wide.rc")" -eq 0 ]'

run unreachable STUB_UNREACHABLE=1

check "unreachable cluster: exit 0, the caller is never failed" '[ "$(cat "$T/unreachable.rc")" -eq 0 ]'
check "  ...prints nothing on stdout" '[ ! -s "$T/unreachable.out" ]'
check "  ...warns on stderr" '[ -s "$T/unreachable.err" ]'

printf '{"apiVersion": "v1", "kind": "List", "items": []}' >"$T/fixture-empty.json"
run empty FIXTURE="$T/fixture-empty.json" --

check "empty cluster: exit 0, nothing printed" \
  '[ "$(cat "$T/empty.rc")" -eq 0 ] && [ ! -s "$T/empty.out" ]'

# Negative control: drop an in-window Certificate from the fixture and the
# expected-output check above must fail, proving the test depends on it. An
# absent script is a FAIL, never a vacuous ok.
jq '{items: [.items[] | select(.metadata.name != "d-in-window")]}' "$T/fixture.json" >"$T/without-d.json"
if [ ! -f "$ROOT/scripts/ops/k8s/cert-expiry.sh" ]; then
  echo "  FAIL negative control: scripts/ops/k8s/cert-expiry.sh does not exist"
  fails=1
elif env FIXTURE="$T/without-d.json" PATH="$T/bin:$PATH" \
   bash "$ROOT/scripts/ops/k8s/cert-expiry.sh" | grep -q "istio-system/d-in-window"; then
  echo "  FAIL negative control: d-in-window was reported without its fixture entry"
  fails=1
else
  echo "  ok   negative control: removing d-in-window removes its line (the expected-output check would fail)"
fi

echo "observability: the Certificates GrafanaDashboard:"
DASH="observability/base/grafana-operator/dashboards/certificates.yaml"

check "the dashboard CR exists at the scoper's path" '[ -f "$ROOT/$DASH" ]'
if [ -f "$ROOT/$DASH" ]; then
  # The parsed dashboard JSON, or an empty file when the CR is not a
  # GrafanaDashboard or spec.json does not parse -- the check below tells
  # those apart from a passing CR by reading dash.err.
  python3 -c '
import sys, json, yaml
d = yaml.safe_load(open(sys.argv[1]))
assert d.get("kind") == "GrafanaDashboard", "not a GrafanaDashboard CR"
print(json.dumps(json.loads(d["spec"]["json"])))' "$ROOT/$DASH" >"$T/dash.json" 2>"$T/dash.err"
  check "  ...is a GrafanaDashboard CR whose spec.json parses as JSON" \
    '[ -s "$T/dash.json" ] || { cat "$T/dash.err"; false; }'
  check "  ...dashboard title is Certificates" \
    'python3 -c "import json,sys; assert json.load(open(sys.argv[1]))[\"title\"] == \"Certificates\"" "$T/dash.json"'
  check "  ...a table panel driven by certmanager_certificate_expiration_timestamp_seconds" \
    'python3 -c "
import json, sys
d = json.load(open(sys.argv[1]))
tables = [p for p in d.get(\"panels\", []) if p.get(\"type\") == \"table\"]
assert tables, \"no table panel\"
targets = [t.get(\"expr\", \"\") for p in tables for t in p.get(\"targets\", [])]
assert any(\"certmanager_certificate_expiration_timestamp_seconds\" in e for e in targets), targets
" "$T/dash.json"'
  check "  ...a stat panel driven by certmanager_certificate_ready_status, not-Ready" \
    'python3 -c "
import json, sys
d = json.load(open(sys.argv[1]))
stats = [p for p in d.get(\"panels\", []) if p.get(\"type\") == \"stat\"]
assert stats, \"no stat panel\"
targets = [t.get(\"expr\", \"\") for p in stats for t in p.get(\"targets\", [])]
assert any(\"certmanager_certificate_ready_status\" in e for e in targets), targets
assert any(\"certmanager_certificate_ready_status\" in e and \"0\" in e for e in targets), targets
" "$T/dash.json"'
else
  echo "  FAIL dashboard checks: no CR to read"
  fails=1
fi
check "wired into the dashboards kustomization like the other dashboards" \
  'grep -q "certificates.yaml" "$ROOT/observability/base/grafana-operator/dashboards/kustomization.yaml"'
check "folderRef names a GrafanaFolder that exists" \
  'python3 -c "
import sys, yaml, glob
dash = yaml.safe_load(open(sys.argv[1]))
ref = dash[\"spec\"][\"folderRef\"]
hits = [p for p in glob.glob(sys.argv[2], recursive=True)
        if (yaml.safe_load(open(p)) or {}).get(\"metadata\", {}).get(\"name\") == ref]
assert hits, ref
" "$ROOT/$DASH" "$ROOT/observability/**/grafana-operator/folders/*.yaml" 2>/dev/null'

echo "website: the operations page:"
check "the page exists" '[ -f "$ROOT/website/content/docs/operations/certificate-expiry.md" ]'
check "the operations index links it" \
  'grep -q "certificate-expiry" "$ROOT/website/content/docs/operations/_index.md"'

[ "$fails" -eq 0 ] && echo "all checks passed"
exit "$fails"
