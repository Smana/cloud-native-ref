#!/usr/bin/env bash
#
# reclaim-csi-volumes.sh with kubectl, flux and sleep stubbed on PATH. The script
# has no dry run: every invocation is the destructive path, so each case below
# runs it against a fake cluster and asserts on the recorded calls.
#   - unreachable cluster: exit 0, nothing touched
#   - full reclaim: Flux suspended BEFORE any delete, PVs patched to Delete, CNPG
#     Clusters deleted, only PVC-mounting workloads scaled (never the CSI
#     controller), only PVC-mounting pods deleted, PVCs deleted, PVs drained
#   - no Flux / no CNPG API: those steps are skipped, the reclaim still runs
#   - PVs that never drain: warning names the volume handle, still exit 0
#   - an explicit kube-context reaches every kubectl and flux call
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"

# Calls go to $CALLS, one per line. `get pv --no-headers` reports one PV until
# `delete pvc` has run, unless STUB_PV_STUCK keeps it bound.
cat >"$T/bin/kubectl" <<'EOF'
#!/usr/bin/env bash
echo "kubectl $*" >>"$CALLS"
case "$*" in
  *"get ns"*) [ -z "${STUB_UNREACHABLE:-}" ] || exit 1 ;;
  *"api-resources --api-group=kustomize.toolkit.fluxcd.io"*) [ -z "${STUB_NO_FLUX:-}" ] || exit 1 ;;
  *"api-resources --api-group=postgresql.cnpg.io"*)
    [ -n "${STUB_NO_CNPG:-}" ] || echo "clusters   postgresql.cnpg.io/v1   true   Cluster" ;;
  *"get pv -o jsonpath={.items[*].metadata.name}"*) echo "pv-a pv-b" ;;
  *"get pv -o jsonpath={range"*) echo "pv-a -> vol-0123abcd" ;;
  *"get pv --no-headers"*)
    if [ -n "${STUB_PV_STUCK:-}" ] || ! grep -q "delete pvc" "$CALLS"; then echo "pv-a 10Gi"; fi ;;
  *"get deploy,statefulset"*) cat <<'JSON' ;;
{"items":[
 {"kind":"Deployment","metadata":{"namespace":"kube-system","name":"ebs-csi-controller"},
  "spec":{"template":{"spec":{"volumes":[{"name":"socket","emptyDir":{}}]}}}},
 {"kind":"Deployment","metadata":{"namespace":"harbor","name":"registry"},
  "spec":{"template":{"spec":{"volumes":[{"name":"data","persistentVolumeClaim":{"claimName":"registry"}}]}}}},
 {"kind":"StatefulSet","metadata":{"namespace":"obs","name":"vlogs"},
  "spec":{"template":{"spec":{}},"volumeClaimTemplates":[{"metadata":{"name":"data"}}]}}
]}
JSON
  *"get pods"*) cat <<'JSON' ;;
{"items":[
 {"metadata":{"namespace":"kube-system","name":"ebs-csi-controller-0"},"spec":{"volumes":[{"name":"x","emptyDir":{}}]}},
 {"metadata":{"namespace":"batch","name":"backup-job-xyz"},"spec":{"volumes":[{"name":"d","persistentVolumeClaim":{"claimName":"backup"}}]}}
]}
JSON
esac
exit 0
EOF
cat >"$T/bin/flux" <<'EOF'
#!/usr/bin/env bash
echo "flux $*" >>"$CALLS"
EOF
printf '#!/usr/bin/env bash\nexit 0\n' >"$T/bin/sleep"
chmod +x "$T/bin/kubectl" "$T/bin/flux" "$T/bin/sleep"

# run CASE [env...] [-- args...]: output to $T/CASE.out, calls to $T/CASE.calls, rc to $T/CASE.rc.
run() {
  local name="$1"; shift
  local envs=() args=()
  while [ $# -gt 0 ]; do
    [ "$1" = "--" ] && { shift; args=("$@"); break; }
    envs+=("$1"); shift
  done
  : >"$T/$name.calls"
  env CALLS="$T/$name.calls" PATH="$T/bin:$PATH" "${envs[@]}" \
    bash "$ROOT/scripts/ops/k8s/reclaim-csi-volumes.sh" "${args[@]}" >"$T/$name.out" 2>&1
  echo $? >"$T/$name.rc"
}
# Line number of the first call matching $2 in case $1, or 0.
line() { local n; n="$(grep -nE -- "$2" "$T/$1.calls" | head -1 | cut -d: -f1)"; echo "${n:-0}"; }

run down STUB_UNREACHABLE=1
run full
run bare STUB_NO_FLUX=1 STUB_NO_CNPG=1
run stuck STUB_PV_STUCK=1
run ctx -- my-ctx

fails=0
check() { if eval "$2"; then echo "  ok   $1"; else echo "  FAIL $1"; fails=1; fi; }

check "unreachable: exit 0" '[ "$(cat "$T/down.rc")" -eq 0 ]'
check "  ...says the cloud-side sweep is the backstop" 'grep -q "cloud-side sweep is the backstop" "$T/down.out"'
check "  ...makes no call after the reachability probe" '[ "$(wc -l <"$T/down.calls")" -eq 1 ]'

check "full: exit 0" '[ "$(cat "$T/full.rc")" -eq 0 ]'
check "  ...suspends every Flux kustomization" 'grep -qx "flux suspend kustomization --all" "$T/full.calls"'
check "  ...before the first delete, patch or scale" '[ "$(line full "flux suspend")" -gt 0 ] && [ "$(line full "flux suspend")" -lt "$(line full " (delete|patch|scale) ")" ]'
check "  ...patches every PV to reclaimPolicy Delete" '[ "$(grep -c "patch pv pv-[ab] --type=merge -p .*\"persistentVolumeReclaimPolicy\":\"Delete\"" "$T/full.calls")" -eq 2 ]'
check "  ...deletes CNPG Clusters cluster-wide" 'grep -q "delete clusters.postgresql.cnpg.io --all --all-namespaces" "$T/full.calls"'
check "  ...scales the PVC-mounting Deployment to 0" 'grep -q "scale deployment -n harbor registry --replicas=0" "$T/full.calls"'
check "  ...scales the claim-template StatefulSet to 0" 'grep -q "scale statefulset -n obs vlogs --replicas=0" "$T/full.calls"'
check "  ...never scales the CSI controller" '! grep -q "scale .*ebs-csi-controller" "$T/full.calls"'
check "  ...exactly two scales" '[ "$(grep -c " scale " "$T/full.calls")" -eq 2 ]'
check "  ...deletes the PVC-mounting pod" 'grep -q "delete pod -n batch backup-job-xyz" "$T/full.calls"'
check "  ...never deletes the CSI controller pod" '! grep -q "delete pod .*ebs-csi-controller" "$T/full.calls"'
check "  ...deletes every PVC" 'grep -q "delete pvc --all --all-namespaces" "$T/full.calls"'
check "  ...after the workloads holding them are gone" '[ "$(line full "delete pod")" -lt "$(line full "delete pvc")" ]'
check "  ...reports every PV reclaimed" 'grep -q "All PersistentVolumes reclaimed" "$T/full.out"'

check "no Flux/CNPG API: exit 0" '[ "$(cat "$T/bare.rc")" -eq 0 ]'
check "  ...does not call flux" '! grep -q "^flux " "$T/bare.calls"'
check "  ...does not delete CNPG Clusters" '! grep -q "delete clusters.postgresql.cnpg.io" "$T/bare.calls"'
check "  ...still deletes every PVC" 'grep -q "delete pvc --all --all-namespaces" "$T/bare.calls"'

check "stuck PVs: exit 0, the caller is never failed" '[ "$(cat "$T/stuck.rc")" -eq 0 ]'
check "  ...polls for the full 300s" '[ "$(grep -c "get pv --no-headers" "$T/stuck.calls")" -eq 60 ]'
check "  ...warns, naming the volume handle" 'grep -q "WARNING: 1 PV(s) not reclaimed" "$T/stuck.out" && grep -q "pv-a -> vol-0123abcd" "$T/stuck.out"'
check "  ...does not claim success" '! grep -q "All PersistentVolumes reclaimed" "$T/stuck.out"'

check "context: exit 0" '[ "$(cat "$T/ctx.rc")" -eq 0 ]'
check "  ...every kubectl call carries --context my-ctx" '! grep "^kubectl " "$T/ctx.calls" | grep -qv "^kubectl --context my-ctx "'
check "  ...flux too" 'grep -qx "flux --context my-ctx suspend kustomization --all" "$T/ctx.calls"'
check "  ...and the PVCs are still deleted" 'grep -q "^kubectl --context my-ctx delete pvc --all --all-namespaces" "$T/ctx.calls"'

[ "$fails" -eq 0 ] && echo "all checks passed"
exit "$fails"
