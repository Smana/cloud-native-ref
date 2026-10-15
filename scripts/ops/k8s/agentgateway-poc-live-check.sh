#!/usr/bin/env bash
# Live checks L1-L8 (open-issues research, 2026-10-15; the gap matrix's P1-P8
# adapted) against an agentgateway Gateway: the PoC agw-poc/agent-router-agw
# (default), or the real agent-gateway/agent-router (--gateway real, plan B.6).
#
# usage: agentgateway-poc-live-check.sh [--gateway poc|real] [--skip-drain] [--skip-restart] [--log FILE]
#
# Uses the CURRENT kube context, and writes the whole run to a log (default
# ./agentgateway-live-check-<gateway>-<UTC time>.log): L8 needs a full captured log.
#
# poc: creates two throwaway pods (agw-poc-clients, agw-poc) and deletes them on
# exit, makes five GLM-5.3 calls of max_tokens 16 through the PoC's own Z.ai key,
# deletes the PoC proxy pods once (L4) and restarts the agentgateway controller
# and one PoC target once (L3). It touches nothing outside agentgateway-system,
# agw-poc and agw-poc-clients.
#
# real: until phase C attaches routes, the real Gateway has none, so the script
# brings a throwaway echo (labelled agw-live-check=true, deleted on exit): a
# Sandbox client in agents, an echo Deployment, Service and HTTPRoute in
# agent-system, and one additive CNP each in agents, agent-system and
# agent-gateway. It runs L8 (identity on all three listeners), L5, L4 (deletes
# the real proxy pods once: no run uses them before the cutover), the JWKS issuer
# check and the proxy's shape. L1-L3, L6 and L7 need phase C's routes and print
# NOT RUN. No model call is made.
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/../../.." && pwd)
CHECKS="$HERE/agentgateway-poc-checks.py"
# Phase H deletes the PoC: move this file next to the script then.
ECHO_SERVER="$ROOT/infrastructure/aws-0/agentgateway-poc/echo-server.py"
GATEWAY=poc SKIP_DRAIN=false SKIP_RESTART=false LOG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --gateway) GATEWAY=${2:?}; shift ;;
    --skip-drain) SKIP_DRAIN=true ;;
    --skip-restart) SKIP_RESTART=true ;;
    --log) LOG=${2:?}; shift ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done
case "$GATEWAY" in poc|real) ;; *) echo "--gateway is poc or real" >&2; exit 2 ;; esac
LOG=${LOG:-agentgateway-live-check-$GATEWAY-$(date -u +%Y%m%dT%H%M%SZ).log}
exec > >(tee -a "$LOG") 2>&1
K=kubectl
IMAGE="docker.io/library/python:3.13-alpine@sha256:79e7a9b9ff1cbceff819f856fb374477792a5967759d94df266de7b7b4120e6f"
echo "context: $($K config current-context)  gateway: $GATEWAY  log: $LOG  started: $(date -u +%FT%TZ)"
FAILED=0
fail() { echo "FAIL $*"; FAILED=1; }
pass() { echo "PASS $*"; }
assert() { # message command...
  local msg=$1; shift
  if "$@"; then pass "$msg"; else fail "$msg"; fi
}

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
run() { # namespace pod check args... (AGW_URL/AGW_SUB_NS pass through `env`)
  local ns=$1 p=$2; shift 2
  $K -n "$ns" exec -i "$p" -- env "AGW_URL=${AGW_URL:-}" "AGW_SUB_NS=${AGW_SUB_NS:-}" python3 - "$@" < "$CHECKS" || FAILED=1
}

# ---------------------------------------------------------------- the real Gateway
real_objects() { # the throwaway echo, its route and the client (all agw-live-check=true)
  $K -n agent-system create configmap agw-check-echo --from-file=echo-server.py="$ECHO_SERVER" \
    --dry-run=client -o yaml | $K label --local -f - agw-live-check=true -o yaml | $K apply -f - >/dev/null
  $K apply -f - >/dev/null <<EOF
apiVersion: v1
kind: ServiceAccount
metadata: {name: agw-check, namespace: agents, labels: {agw-live-check: "true"}}
automountServiceAccountToken: false
---
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata: {name: agw-check, namespace: agents, labels: {agw-live-check: "true"}}
spec:
  endpointSelector: {matchLabels: {agents.ogenki.io/run-id: agwcheck}}
  egress:
    - toEndpoints: [{matchLabels: {io.kubernetes.pod.namespace: kube-system, k8s-app: kube-dns}}]
      toPorts: [{ports: [{port: "53", protocol: UDP}, {port: "53", protocol: TCP}], rules: {dns: [{matchPattern: "*"}]}}]
    - toEndpoints: [{matchLabels: {io.kubernetes.pod.namespace: agent-gateway, gateway.networking.k8s.io/gateway-name: agent-router}}]
      toPorts: [{ports: [{port: "8080", protocol: TCP}, {port: "8081", protocol: TCP}, {port: "8082", protocol: TCP}]}]
---
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata: {name: agw-check-echo, namespace: agent-gateway, labels: {agw-live-check: "true"}}
spec:
  endpointSelector: {matchLabels: {gateway.networking.k8s.io/gateway-name: agent-router}}
  egress:
    - toEndpoints: [{matchLabels: {io.kubernetes.pod.namespace: agent-system, app.kubernetes.io/name: agw-check-echo}}]
      toPorts: [{ports: [{port: "8080", protocol: TCP}]}]
---
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata: {name: agw-check-echo, namespace: agent-system, labels: {agw-live-check: "true"}}
spec:
  endpointSelector: {matchLabels: {app.kubernetes.io/name: agw-check-echo}}
  ingress:
    - fromEndpoints: [{matchLabels: {io.kubernetes.pod.namespace: agent-gateway, gateway.networking.k8s.io/gateway-name: agent-router}}]
      toPorts: [{ports: [{port: "8080", protocol: TCP}]}]
    - fromEntities: [host]
      toPorts: [{ports: [{port: "8080", protocol: TCP}]}]
---
apiVersion: apps/v1
kind: Deployment
metadata: {name: agw-check-echo, namespace: agent-system, labels: {agw-live-check: "true"}}
spec:
  replicas: 1
  selector: {matchLabels: {app.kubernetes.io/name: agw-check-echo}}
  template:
    metadata: {labels: {app.kubernetes.io/name: agw-check-echo}}
    spec:
      automountServiceAccountToken: false
      securityContext: {runAsNonRoot: true, runAsUser: 65534, runAsGroup: 65534, seccompProfile: {type: RuntimeDefault}}
      containers:
        - name: echo
          image: $IMAGE
          command: ["python3", "-u", "/app/echo-server.py", "8080"]
          ports: [{name: http, containerPort: 8080, protocol: TCP}]
          readinessProbe: {httpGet: {path: /healthz, port: http}}
          livenessProbe: {httpGet: {path: /healthz, port: http}, periodSeconds: 20}
          resources: {requests: {cpu: 10m, memory: 32Mi}, limits: {cpu: 200m, memory: 64Mi}}
          securityContext: {allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: {drop: ["ALL"]}}
          volumeMounts: [{name: app, mountPath: /app, readOnly: true}]
      volumes: [{name: app, configMap: {name: agw-check-echo}}]
---
apiVersion: v1
kind: Service
metadata: {name: agw-check-echo, namespace: agent-system, labels: {agw-live-check: "true"}}
spec:
  selector: {app.kubernetes.io/name: agw-check-echo}
  ports: [{name: http, port: 8080, targetPort: http}]
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata: {name: agw-check-echo, namespace: agent-system, labels: {agw-live-check: "true"}}
spec:
  parentRefs:
    - {group: gateway.networking.k8s.io, kind: Gateway, namespace: agent-gateway, name: agent-router, sectionName: public}
    - {group: gateway.networking.k8s.io, kind: Gateway, namespace: agent-gateway, name: agent-router, sectionName: internal}
    - {group: gateway.networking.k8s.io, kind: Gateway, namespace: agent-gateway, name: agent-router, sectionName: sts}
  rules:
    - matches: [{path: {type: PathPrefix, value: /echo}}]
      backendRefs: [{name: agw-check-echo, port: 8080}]
---
# Shaped like scripts/ops/k8s/agent-probe.yaml: Kyverno admits only Sandbox pods
# under gVisor in agents, and reserves these audiences for that namespace.
apiVersion: agents.x-k8s.io/v1beta1
kind: Sandbox
metadata: {name: agw-check, namespace: agents, labels: {agw-live-check: "true"}}
spec:
  service: false
  shutdownPolicy: Delete
  shutdownTime: "$(date -u -d '+1 hour' +%FT%TZ)"
  podTemplate:
    metadata:
      labels: {agents.ogenki.io/run-id: agwcheck, agents.ogenki.io/role: implementer}
    spec:
      serviceAccountName: agw-check
      automountServiceAccountToken: false
      runtimeClassName: gvisor
      restartPolicy: Never
      activeDeadlineSeconds: 3600
      securityContext: {runAsNonRoot: true, runAsUser: 10001, runAsGroup: 10001, seccompProfile: {type: RuntimeDefault}}
      containers:
        - name: c
          image: $IMAGE
          command: ["sleep", "3600"]
          readinessProbe: {exec: {command: ["sh", "-c", "test -s /var/run/agw/public && test -s /var/run/agw/sts"]}}
          livenessProbe: {exec: {command: ["true"]}}
          resources: {requests: {cpu: 10m, memory: 32Mi}, limits: {cpu: 500m, memory: 128Mi}}
          securityContext: {allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: {drop: ["ALL"]}, seccompProfile: {type: RuntimeDefault}}
          volumeMounts: [{name: tok, mountPath: /var/run/agw, readOnly: true}]
      volumes:
        - name: tok
          projected:
            sources:
              - serviceAccountToken: {audience: agent-router.implementer.public, expirationSeconds: 3600, path: public}
              - serviceAccountToken: {audience: agent-router.implementer.internal, expirationSeconds: 3600, path: internal}
              - serviceAccountToken: {audience: octo-sts/Smana/cloud-native-ref/implementer, expirationSeconds: 3600, path: sts}
EOF
}
real_cleanup() {
  for ns in agents agent-system agent-gateway; do
    $K -n "$ns" delete sandbox,deploy,svc,httproute,configmap,ciliumnetworkpolicy,serviceaccount \
      -l agw-live-check=true --ignore-not-found --wait=false >/dev/null 2>&1 || true
  done
}

real() {
  local sel=gateway.networking.k8s.io/gateway-name=agent-router
  trap real_cleanup EXIT
  echo "== preconditions"
  $K -n agent-gateway wait gateway/agent-router --for=condition=Programmed --timeout=60s
  $K -n agentgateway-system get deploy agentgateway -o jsonpath='controller image: {.spec.template.spec.containers[0].image}{"\n"}'

  echo "== proxy shape (B.6)"
  local want got
  want=$($K -n agent-gateway get agentgatewayparameters agent-router -o jsonpath='{.spec.image.digest}')
  for p in $($K -n agent-gateway get pod -l "$sel" -o name); do
    got=$($K -n agent-gateway get "$p" -o jsonpath='{.status.containerStatuses[0].imageID}')
    assert "B.6 $p runs $got, pinned $want (else touch the Gateway)" [ "${got##*@}" = "$want" ]
  done
  got=$($K -n agent-gateway get svc agent-router -o jsonpath='{.spec.type}')
  assert "B.6 Service type $got is ClusterIP" [ "$got" = ClusterIP ]
  got=$($K -n agent-gateway get deploy agent-router -o jsonpath='{.spec.template.spec.terminationGracePeriodSeconds}')
  assert "B.6 terminationGracePeriodSeconds $got >= 660" [ "${got:-0}" -ge 660 ]
  got=$($K -n agent-gateway get deploy agent-router -o jsonpath='{.status.readyReplicas}')
  assert "B.6 ${got:-0} proxies ready, expected 2" [ "${got:-0}" -ge 2 ]
  $K -n agent-gateway get pod -l "$sel" -o custom-columns=POD:.metadata.name,NODE:.spec.nodeName --no-headers

  echo "== JWKS: the listeners trust this cluster's current issuer (it changes on every rebuild)"
  local iss
  iss=$($K get --raw /.well-known/openid-configuration | python3 -c 'import json,sys; print(json.load(sys.stdin)["issuer"])')
  for l in public internal sts; do
    got=$($K -n agent-gateway get agentgatewaypolicy "listener-$l" -o jsonpath='{.spec.traffic.jwtAuthentication.providers[0].issuer}')
    assert "JWKS listener-$l issuer $got is the cluster's $iss" [ "$got" = "$iss" ]
  done
  echo "   (a 200 below proves the controller fetched this issuer's keys and served them over xDS)"

  echo "== throwaway echo, route and client"
  real_objects
  $K -n agent-system rollout status deploy/agw-check-echo --timeout=120s >/dev/null
  $K -n agents wait sandbox/agw-check --for=condition=Ready --timeout=10m >/dev/null
  echo "   route Accepted per listener: $($K -n agent-system get httproute agw-check-echo \
    -o jsonpath='{.status.parents[*].conditions[?(@.type=="Accepted")].status}')"
  export AGW_URL=http://agent-router.agent-gateway.svc.cluster.local AGW_SUB_NS=agents

  echo "== L8/P1/P2 identity from EKS projected tokens, public and internal"
  run agents agw-check identity
  echo "== L8/AG4 sts: own audience, the bearer forwarded"
  run agents agw-check sts
  echo "== L8/P1 wrong namespace: Kyverno refuses to mint the audience outside agents"
  if $K -n agent-gateway create token default --audience agent-router.implementer.public >/dev/null 2>&1; then
    fail "L8/P1 a token for agent-router.implementer.public was minted outside agents"
  else
    pass "L8/P1 agent-router.* refused outside agents (and the data-plane CNP admits only run pods)"
  fi

  echo "== L5 requiredClaims on every listener (#3523)"
  for l in public internal sts; do
    got=$($K -n agent-gateway get agentgatewaypolicy "listener-$l" \
      -o jsonpath='{.spec.traffic.jwtAuthentication.providers[0].validation.requiredClaims}')
    assert "L5 listener-$l requires $got (exp)" grep -q 'exp' <<<"$got"
    assert "L5 listener-$l requires $got (sub)" grep -q 'sub' <<<"$got"
  done
  echo "   a sub-less token cannot be minted against the EKS JWKS; the 401 itself is proven on kind only"

  if ! $SKIP_DRAIN; then
    echo "== L4/N1 drain: a 200s stream, every real proxy pod deleted 10s in"
    $K -n agents exec -i agw-check -- env "AGW_URL=$AGW_URL" "AGW_SUB_NS=$AGW_SUB_NS" python3 - drain 200 < "$CHECKS" &
    local stream=$!
    sleep 10
    $K -n agent-gateway delete pod -l "$sel" --wait=false
    wait "$stream" || FAILED=1
  fi

  echo "== L1-L3, L6, L7: NOT RUN on the real Gateway until phase C (AGW-3) attaches its routes"
}

# ---------------------------------------------------------------- the PoC
poc_cleanup() {
  $K -n agw-poc-clients delete pod agw-poc-check --ignore-not-found --wait=false >/dev/null
  $K -n agw-poc delete pod agw-rogue --ignore-not-found --wait=false >/dev/null
}
poc() {
  trap poc_cleanup EXIT

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
}

"$GATEWAY"
echo "finished: $(date -u +%FT%TZ)  log: $LOG"
if [ "$FAILED" != 0 ]; then echo "SOME CHECKS FAILED"; exit 1; fi
echo "ALL CHECKS PASSED"
