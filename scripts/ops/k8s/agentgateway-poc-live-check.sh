#!/usr/bin/env bash
# Live checks L1-L8 (open-issues research, 2026-10-15; the gap matrix's P1-P8
# adapted) against the agentgateway PoC Gateway agw-poc/agent-router-agw.
#
# usage: agentgateway-poc-live-check.sh [--skip-drain] [--skip-restart]
#
# Uses the CURRENT kube context. It creates two throwaway pods (agw-poc-clients,
# agw-poc) and deletes them on exit, makes five GLM-5.3 calls of max_tokens 16
# through the PoC's own Z.ai key, deletes the PoC proxy pods once (L4) and
# restarts the agentgateway controller and one PoC target once (L3). It touches
# nothing outside agentgateway-system, agw-poc and agw-poc-clients.
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
CHECKS="$HERE/agentgateway-poc-checks.py"
SKIP_DRAIN=false SKIP_RESTART=false
for a in "$@"; do
  case "$a" in
    --skip-drain) SKIP_DRAIN=true ;;
    --skip-restart) SKIP_RESTART=true ;;
    *) echo "unknown argument: $a" >&2; exit 2 ;;
  esac
done
K=kubectl
IMAGE="docker.io/library/python:3.13-alpine@sha256:79e7a9b9ff1cbceff819f856fb374477792a5967759d94df266de7b7b4120e6f"
echo "context: $($K config current-context)"
FAILED=0

pod() { # name namespace serviceaccount label audiences...
  local name=$1 ns=$2 sa=$3 label=$4; shift 4
  local sources=""
  for aud in "$@"; do
    sources+="          - serviceAccountToken: {audience: agw-poc.$aud, expirationSeconds: 3600, path: ${aud##*.}}"$'\n'
  done
  $K apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: $name
  namespace: $ns
  labels: {app.kubernetes.io/name: $label}
spec:
  serviceAccountName: $sa
  automountServiceAccountToken: false
  restartPolicy: Never
  securityContext: {runAsNonRoot: true, runAsUser: 65534, runAsGroup: 65534, seccompProfile: {type: RuntimeDefault}}
  containers:
    - name: c
      image: $IMAGE
      command: ["sleep", "3600"]
      resources: {requests: {cpu: 10m, memory: 32Mi}, limits: {cpu: 500m, memory: 128Mi}}
      securityContext: {allowPrivilegeEscalation: false, readOnlyRootFilesystem: false, capabilities: {drop: ["ALL"]}}
      volumeMounts: [{name: tok, mountPath: /var/run/agw, readOnly: true}]
  volumes:
    - name: tok
      projected:
        sources:
$sources
EOF
}
cleanup() {
  $K -n agw-poc-clients delete pod agw-poc-check --ignore-not-found --wait=false >/dev/null
  $K -n agw-poc delete pod agw-rogue --ignore-not-found --wait=false >/dev/null
}
trap cleanup EXIT
run() { # namespace pod check args...
  local ns=$1 p=$2; shift 2
  $K -n "$ns" exec -i "$p" -- python3 - "$@" < "$CHECKS" || FAILED=1
}

echo "== preconditions"
$K -n agw-poc wait gateway/agent-router-agw --for=condition=Programmed --timeout=60s
$K -n agent-system get agentgatewaybackend agw-poc-zai agw-poc-zai-anthropic
$K -n agentgateway-system get deploy agentgateway -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'

pod agw-poc-check agw-poc-clients implementer agw-poc-check implementer.public implementer.internal
pod agw-rogue agw-poc rogue agw-rogue implementer.public
$K -n agw-poc-clients wait pod/agw-poc-check --for=condition=Ready --timeout=120s >/dev/null
$K -n agw-poc wait pod/agw-rogue --for=condition=Ready --timeout=120s >/dev/null

echo "== L8/P1/P2 identity"; run agw-poc-clients agw-poc-check identity; run agw-poc agw-rogue rogue
echo "== L7/N3 /v1/models"; run agw-poc-clients agw-poc-check models
echo "== L1/L2 Z.ai (real GLM-5.3 calls, max_tokens 16)"; run agw-poc-clients agw-poc-check llm
echo "== L3 MCP federation"; run agw-poc-clients agw-poc-check mcp open
if ! $SKIP_RESTART; then
  $K -n agentgateway-system rollout restart deploy/agentgateway >/dev/null
  $K -n agentgateway-system rollout status deploy/agentgateway --timeout=180s >/dev/null
  run agw-poc-clients agw-poc-check mcp after-controller-restart
  $K -n agw-poc rollout restart deploy/agw-echo >/dev/null
  $K -n agw-poc rollout status deploy/agw-echo --timeout=120s >/dev/null
  run agw-poc-clients agw-poc-check mcp after-target-restart
fi

echo "== L6 gen_ai token usage by type (every proxy replica)"
port=15120
for p in $($K -n agw-poc get pod -l gateway.networking.k8s.io/gateway-name=agent-router-agw -o name); do
  $K -n agw-poc port-forward "$p" "$port:15020" >/dev/null 2>&1 &
  pf=$!
  sleep 2
  curl -s "localhost:$port/metrics" | grep '^agentgateway_gen_ai_client_token_usage_sum' \
    | sed -E 's/.*gen_ai_token_type="([a-z_]+)".*ar_agent="([^"]*)".*\} (.*)/  \1 \2 \3/' || true
  kill "$pf" 2>/dev/null || true
  port=$((port + 1))
done
echo "  expect input, output and input_cache_read for agw-poc-clients:implementer; input includes the cache"

if ! $SKIP_DRAIN; then
  echo "== L4/N1 drain: a 200s stream, every proxy pod deleted 10s in"
  $K -n agw-poc-clients exec -i agw-poc-check -- python3 - drain 200 < "$CHECKS" &
  stream=$!
  sleep 10
  $K -n agw-poc delete pod -l gateway.networking.k8s.io/gateway-name=agent-router-agw --wait=false
  wait "$stream" || FAILED=1
fi

echo "== L5: proven on kind only (no sub-less token can be minted against the EKS JWKS);"
echo "   live, listener-public requires: $($K -n agw-poc get agentgatewaypolicy listener-public \
  -o jsonpath='{.spec.traffic.jwtAuthentication.providers[0].validation.requiredClaims}')"
if [ "$FAILED" != 0 ]; then echo "SOME CHECKS FAILED"; exit 1; fi
echo "ALL CHECKS PASSED"
