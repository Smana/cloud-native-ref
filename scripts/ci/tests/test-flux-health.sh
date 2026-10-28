#!/usr/bin/env bash
#
# flux-health.sh with kubectl stubbed on PATH: a read-only report, so each
# case just runs it against a canned `get -o json` fixture and asserts on the
# printed lines and the exit code:
#   - a False Kustomization and a False HelmRelease are each reported as
#     "<kind> <ns>/<name>: <message>"
#   - True ones are not reported, and neither are their names anywhere
#   - an object with no Ready condition at all is reported too
#   - an unreachable cluster: warning on stderr, exit 0
#   - removing the not-ready HelmRelease from the fixture breaks the
#     expected-output check (the test is not vacuously green)
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"

# The stub answers each kind's list from the one fixture, filtered to that
# kind, like a real API server would. STUB_UNREACHABLE fails the call, standing
# in for an unreachable cluster or absent Flux CRDs. jq is on the fixtured
# path in CI and in the devcontainer, so the stub uses it freely.
cat >"$T/bin/kubectl" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *"kustomizations.kustomize.toolkit.fluxcd.io"*)
    [ -z "${STUB_UNREACHABLE_KS:-}" ] || exit 1
    jq '{items: [.items[] | select(.kind == "Kustomization")]}' "$FIXTURE" ;;
  *"helmreleases.helm.toolkit.fluxcd.io"*)
    [ -z "${STUB_UNREACHABLE:-}" ] || exit 1
    jq '{items: [.items[] | select(.kind == "HelmRelease")]}' "$FIXTURE" ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$T/bin/kubectl"

# One ready Kustomization, one False of each kind (the report's whole subject),
# one HelmRelease with no Ready condition yet — the cases the jq filter has to
# tell apart.
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
      "apiVersion": "helm.toolkit.fluxcd.io/v2",
      "kind": "HelmRelease",
      "metadata": {"namespace": "observability", "name": "victoria-metrics-k8s-stack"},
      "status": {"conditions": [
        {"type": "Ready", "status": "False", "reason": "InstallFailed", "message": "Helm install failed: context deadline exceeded"}
      ]}
    },
    {
      "apiVersion": "helm.toolkit.fluxcd.io/v2",
      "kind": "HelmRelease",
      "metadata": {"namespace": "security", "name": "openbao"},
      "status": {"conditions": [
        {"type": "Ready", "status": "True", "reason": "ReconciliationSucceeded", "message": "Helm install succeeded"}
      ]}
    },
    {
      "apiVersion": "helm.toolkit.fluxcd.io/v2",
      "kind": "HelmRelease",
      "metadata": {"namespace": "apps", "name": "image-gallery"},
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
    bash "$ROOT/scripts/ops/k8s/flux-health.sh" "${args[@]}" >"$T/$name.out" 2>"$T/$name.err"
  echo $? >"$T/$name.rc"
}

fails=0
check() { if eval "$2"; then echo "  ok   $1"; else echo "  FAIL $1"; fails=1; fi; }

run report

check "fixture: exit 0" '[ "$(cat "$T/report.rc")" -eq 0 ]'
check "  ...reports the not-ready Kustomization as <kind> <ns>/<name>: <message>" \
  'grep -qx "Kustomization flux-system/apps: HealthCheck failed: timeout waiting for health check" "$T/report.out"'
check "  ...reports the not-ready HelmRelease" \
  'grep -qx "HelmRelease observability/victoria-metrics-k8s-stack: Helm install failed: context deadline exceeded" "$T/report.out"'
check "  ...reports a HelmRelease with no Ready condition at all" \
  'grep -qx "HelmRelease apps/image-gallery: no Ready condition reported" "$T/report.out"'
check "  ...does not report the ready Kustomization" '! grep -q "flux-system/infrastructure" "$T/report.out"'
check "  ...does not report the ready HelmRelease" '! grep -q "security/openbao" "$T/report.out"'
check "  ...exactly one line per not-ready object" '[ "$(wc -l <"$T/report.out")" -eq 3 ]'
check "  ...says nothing on stderr" '[ ! -s "$T/report.err" ]'

run helm-unreachable STUB_UNREACHABLE=1

check "helm list unreachable: exit 0, the caller is never failed" '[ "$(cat "$T/helm-unreachable.rc")" -eq 0 ]'
check "  ...warns about HelmReleases on stderr" 'grep -q "could not list HelmReleases" "$T/helm-unreachable.err"'
check "  ...still reports the not-ready Kustomization" \
  'grep -qx "Kustomization flux-system/apps: HealthCheck failed: timeout waiting for health check" "$T/helm-unreachable.out"'

run unreachable STUB_UNREACHABLE=1 STUB_UNREACHABLE_KS=1

check "unreachable: exit 0, the caller is never failed" '[ "$(cat "$T/unreachable.rc")" -eq 0 ]'
check "  ...warns about Kustomizations on stderr" 'grep -q "could not list Kustomizations" "$T/unreachable.err"'
check "  ...prints nothing on stdout" '[ ! -s "$T/unreachable.out" ]'

# Negative control: drop the not-ready HelmRelease from the fixture and the
# expected-output check above must fail, proving the test depends on it.
jq '{items: [.items[] | select(.metadata.name != "victoria-metrics-k8s-stack")]}' "$T/fixture.json" >"$T/without-helm.json"

if FIXTURE="$T/without-helm.json" PATH="$T/bin:$PATH" \
   bash "$ROOT/scripts/ops/k8s/flux-health.sh" | grep -q "observability/victoria-metrics-k8s-stack"; then
  echo "  FAIL negative control: the not-ready HelmRelease was reported without its fixture entry"
  fails=1
else
  echo "  ok   negative control: removing the not-ready HelmRelease removes its line (the expected-output check would fail)"
fi

[ "$fails" -eq 0 ] && echo "all checks passed"
exit "$fails"
