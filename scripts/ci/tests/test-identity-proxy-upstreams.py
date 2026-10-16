#!/usr/bin/env python3
# requires: python3
"""The identity proxy's upstreams must match the agentgateway Gateway.

The ConfigMap's envoy.yaml names its three upstream clusters by hand, so a
rename of the Gateway, its namespace or a listener port renders fine and passes
every manifest gate, then breaks each new run at its first model call: Envoy
resolves a dead hostname and nothing retries elsewhere. Nothing derives one
side from the other (the Envoy composition predates the Gateway, ADR-0053),
which is why the equality has to be pinned by a test rather than a template."""
import pathlib
import sys

try:
    import yaml
except ImportError:
    print("SKIP: pyyaml not installed")
    sys.exit(77)

ROOT = pathlib.Path(__file__).resolve().parents[3]
CONFIGMAP = ROOT / "infrastructure/base/agent-runtime/identity-proxy-configmap.yaml"
GATEWAY = ROOT / "infrastructure/base/agent-gateway/gateway.yaml"
CLUSTERS = ("agent_router_public", "agent_router_internal", "agent_router_sts")

fails = []


def load_docs(path):
    return [d for d in yaml.safe_load_all(path.read_text()) if isinstance(d, dict)]


configmaps = [
    d for d in load_docs(CONFIGMAP) if d.get("kind") == "ConfigMap" and "envoy.yaml" in d.get("data", {})
]
if len(configmaps) != 1:
    fails.append(f"{CONFIGMAP.relative_to(ROOT)}: expected 1 ConfigMap with an envoy.yaml key, found {len(configmaps)}")
    envoy = {}
else:
    envoy = yaml.safe_load(configmaps[0]["data"]["envoy.yaml"])

gateways = [
    d
    for d in load_docs(GATEWAY)
    if d.get("kind") == "Gateway" and d.get("spec", {}).get("gatewayClassName") == "agentgateway"
]
if len(gateways) != 1:
    fails.append(f"{GATEWAY.relative_to(ROOT)}: expected 1 Gateway of class agentgateway, found {len(gateways)}")
    expected_address, listener_ports = None, set()
else:
    meta = gateways[0]["metadata"]
    expected_address = f"{meta['name']}.{meta.get('namespace', 'default')}.svc.cluster.local"
    listener_ports = {listener["port"] for listener in gateways[0]["spec"]["listeners"]}

upstream_clusters = {
    cluster.get("name"): cluster
    for cluster in envoy.get("static_resources", {}).get("clusters", [])
    if isinstance(cluster, dict)
}
for name in CLUSTERS:
    cluster = upstream_clusters.get(name)
    if cluster is None:
        fails.append(f"envoy.yaml: no cluster named {name}")
        continue
    sockets = []
    for zone in cluster.get("load_assignment", {}).get("endpoints", []):
        for lb in zone.get("lb_endpoints", []):
            socket = lb.get("endpoint", {}).get("address", {}).get("socket_address")
            if socket:
                sockets.append(socket)
    if not sockets:
        fails.append(f"{name}: no socket_address on any endpoint")
        continue
    for socket in sockets:
        if expected_address is not None and socket.get("address") != expected_address:
            fails.append(
                f"{name}: address {socket.get('address')!r} != {expected_address!r}"
                f" (Gateway {meta['name']} in namespace {meta.get('namespace', 'default')})"
            )
        if listener_ports and socket.get("port_value") not in listener_ports:
            ports = sorted(listener_ports)
            fails.append(
                f"{name}: port {socket.get('port_value')} is not a listener port of Gateway"
                f" {meta['name']} (listeners: {ports})"
            )

for fail in fails:
    print("FAIL", fail)
if fails:
    sys.exit(1)
print(f"PASS: {', '.join(CLUSTERS)} -> {expected_address} on ports {sorted(listener_ports)}")
