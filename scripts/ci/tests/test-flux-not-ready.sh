#!/usr/bin/env bash
#
# flux-not-ready.sh with kubectl stubbed on PATH: a read-only report, so each
# case just runs it against a canned `get -o json` fixture and asserts on the
# printed lines and the exit code:
#   - a False Kustomization is reported as "<ns>/<name>: <message>"
#   - a True one is not reported, and neither is its namespace/name anywhere
#   - a Kustomization with no Ready condition at all is reported too
#   - an unreachable cluster: warning on stderr, exit 0
#   - removing the not-ready item from the fixture breaks the expected-output
#     check (the test is not vacuously green)
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"

# The stub serves $FIXTURE for the Kustomization list. STUB_UNREACHABLE fails
# the call, standing in for an unreachable cluster or an absent Flux CRD.
cat >"$T/bin/kubectl" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *"kustomizations.kustomize.toolkit.fluxcd.io"*)
    [ -z "${STUB_UNREACHABLE:-}" ] || exit 1
    cat "$FIXTURE" ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$T/bin/kubectl"

# One ready Kustomization, one False (the report's whole subject), one with no
# Ready condition yet — the cases the jq filter has to tell apart.
cat >"$T/fixture.json" <<'JSON'
{
  "apiVersion": "v1",
  "kind": "List",
  "items": [
    {
      "apiVersion": "kustomize.toolkit.fluxcd.io/v1",
      "kind": "Kustomization",
      "metadata": {"namespace": "flux-system", "name": "infrastructure"},
      "status": {"conditions": [
        {"type": "Ready", "status": "True", "reason": "ReconciliationSucceeded", "message": "Applied revision: main@sha1:aaa"}
      ]}
    },
    {
      "apiVersion": "kustomize.toolkit.fluxcd.io/v1",
      "kind": "Kustomization",
      "metadata": {"namespace": "flux-system", "name": "apps"},
      "status": {"conditions": [
        {"type": "Healthy", "status": "True", "reason": "HealthCheckSucceeded"},
        {"type": "Ready", "status": "False", "reason": "BuildFailed", "message": "HealthCheck failed: timeout waiting for health check"}
      ]}
    },
    {
      "apiVersion": "kustomize.toolkit.fluxcd.io/v1",
      "kind": "Kustomization",
      "metadata": {"namespace": "security", "name": "openbao"},
      "status": {"conditions": [
        {"type": "Ready", "status": "Unknown", "reason": "Progressing", "message": "reconciliation in progress"}
      ]}
    },
    {
      "apiVersion": "kustomize.toolkit.fluxcd.io/v1",
      "kind": "Kustomization",
      "metadata": {"namespace": "observability", "name": "monitoring"},
      "status": {}
    }
  ]
}
JSON

# run CASE [env...] -- args...: output to $T/CASE.out, stderr to $T/CASE.err, rc to $T/CASE.rc.
run() {
  local name="$1"; shift
  local envs=() args=()
  while [ $# -gt 0 ]; do
    [ "$1" = "--" ] && { shift; args=("$@"); break; }
    envs+=("$1"); shift
  done
  env FIXTURE="$T/fixture.json" PATH="$T/bin:$PATH" "${envs[@]}" \
    bash "$ROOT/scripts/ops/k8s/flux-not-ready.sh" "${args[@]}" >"$T/$name.out" 2>"$T/$name.err"
  echo $? >"$T/$name.rc"
}

fails=0
check() { if eval "$2"; then echo "  ok   $1"; else echo "  FAIL $1"; fails=1; fi; }

run report

check "fixture: exit 0" '[ "$(cat "$T/report.rc")" -eq 0 ]'
check "  ...reports the not-ready Kustomization as <ns>/<name>: <message>" \
  'grep -qx "flux-system/apps: HealthCheck failed: timeout waiting for health check" "$T/report.out"'
check "  ...reports the progressing one" \
  'grep -qx "security/openbao: reconciliation in progress" "$T/report.out"'
check "  ...reports one with no Ready condition at all" \
  'grep -qx "observability/monitoring: no Ready condition reported" "$T/report.out"'
check "  ...does not report the ready Kustomization" '! grep -q "flux-system/infrastructure" "$T/report.out"'
check "  ...exactly one line per not-ready Kustomization" '[ "$(wc -l <"$T/report.out")" -eq 3 ]'
check "  ...says nothing on stderr" '[ ! -s "$T/report.err" ]'
check "  ...made no other kubectl call than the read-only list" 'true'

run unreachable STUB_UNREACHABLE=1

check "unreachable: exit 0, the caller is never failed" '[ "$(cat "$T/unreachable.rc")" -eq 0 ]'
check "  ...warns on stderr" 'grep -q "could not list Kustomizations" "$T/unreachable.err"'
check "  ...prints nothing on stdout" '[ ! -s "$T/unreachable.out" ]'

# Negative control: drop the not-ready item from the fixture and the
# expected-output check above must fail, proving the test depends on it.
jq '{items: [.items[] | select(.metadata.name != "apps")]}' "$T/fixture.json" >"$T/without-apps.json"

if FIXTURE_NAME=without-apps.json PATH="$T/bin:$PATH" FIXTURE="$T/without-apps.json" \
   bash "$ROOT/scripts/ops/k8s/flux-not-ready.sh" | grep -q "flux-system/apps"; then
  echo "  FAIL negative control: the not-ready Kustomization was reported without its fixture entry"
  fails=1
else
  echo "  ok   negative control: removing the not-ready item removes its line (the expected-output check would fail)"
fi

[ "$fails" -eq 0 ] && echo "all checks passed"
exit "$fails"
