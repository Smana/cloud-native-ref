#!/usr/bin/env python3
# requires: python3
"""The identity proxy's upstreams must match an agent router that exists.

The ConfigMap's envoy.yaml names its three upstream clusters by hand, so a
rename of the Gateway, its namespace or a listener port renders fine and passes
every manifest gate, then breaks each new run at its first model call: Envoy
resolves a dead hostname and nothing retries elsewhere. Nothing derives one
side from the other (the Envoy composition predates the Gateway, ADR-0053),
which is why the equality has to be pinned by a test rather than a template.

Until phase H deletes Envoy's agent-router, either router is a valid target, so
that rolling back the cutover is a plain revert (G.4's drill). All three
upstreams must name the same router."""
import pathlib
import sys

try:
    import yaml
except ImportError:
    print("SKIP: pyyaml not installed")
    sys.exit(77)

ROOT = pathlib.Path(__file__).resolve().parents[3]
CONFIGMAP = ROOT / "infrastructure/base/agent-runtime/identity-proxy-configmap.yaml"
AGW_GATEWAY = ROOT / "infrastructure/base/agent-gateway/gateway.yaml"
# Envoy Gateway puts every data-plane Service in its own namespace, named by the EnvoyProxy.
ENVOY_GATEWAY = ROOT / "infrastructure/base/agent-router/gateway.yaml"
ENVOY_PROXY = ROOT / "infrastructure/base/agent-router/envoyproxy.yaml"
ENVOY_NAMESPACE = "envoy-gateway-system"
CLUSTERS = ("agent_router_public", "agent_router_internal", "agent_router_sts")

fails = []


def load_docs(path):
    return [d for d in yaml.safe_load_all(path.read_text()) if isinstance(d, dict)]


def gateway_of_class(path, cls):
    found = [d for d in load_docs(path) if d.get("kind") == "Gateway" and d.get("spec", {}).get("gatewayClassName") == cls]
    if len(found) != 1:
        fails.append(f"{path.relative_to(ROOT)}: expected 1 Gateway of class {cls}, found {len(found)}")
        return None
    return found[0]


def ports(gateway):
    return {listener["port"] for listener in gateway["spec"]["listeners"]}


# address -> (description, listener ports)
routers = {}
agw = gateway_of_class(AGW_GATEWAY, "agentgateway")
if agw:
    meta = agw["metadata"]
    address = f"{meta['name']}.{meta.get('namespace', 'default')}.svc.cluster.local"
    routers[address] = (f"agentgateway Gateway {meta.get('namespace')}/{meta['name']}", ports(agw))
if ENVOY_GATEWAY.exists():
    eg = gateway_of_class(ENVOY_GATEWAY, "envoy-ai-gateway")
    services = [
        d["spec"]["provider"]["kubernetes"]["envoyService"].get("name")
        for d in load_docs(ENVOY_PROXY)
        if d.get("kind") == "EnvoyProxy"
    ]
    if eg and len(services) == 1 and services[0]:
        address = f"{services[0]}.{ENVOY_NAMESPACE}.svc.cluster.local"
        routers[address] = (f"Envoy Gateway {eg['metadata'].get('namespace')}/{eg['metadata']['name']}", ports(eg))
    elif eg:
        fails.append(f"{ENVOY_PROXY.relative_to(ROOT)}: expected 1 EnvoyProxy naming its envoyService")

configmaps = [
    d for d in load_docs(CONFIGMAP) if d.get("kind") == "ConfigMap" and "envoy.yaml" in d.get("data", {})
]
if len(configmaps) != 1:
    fails.append(f"{CONFIGMAP.relative_to(ROOT)}: expected 1 ConfigMap with an envoy.yaml key, found {len(configmaps)}")
    envoy = {}
else:
    envoy = yaml.safe_load(configmaps[0]["data"]["envoy.yaml"])

upstream_clusters = {
    cluster.get("name"): cluster
    for cluster in envoy.get("static_resources", {}).get("clusters", [])
    if isinstance(cluster, dict)
}
used = set()
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
        address = socket.get("address")
        used.add(address)
        if address not in routers:
            fails.append(f"{name}: address {address!r} is no agent router (expected one of {sorted(routers)})")
            continue
        what, listener_ports = routers[address]
        if socket.get("port_value") not in listener_ports:
            fails.append(f"{name}: port {socket.get('port_value')} is not a listener port of {what} ({sorted(listener_ports)})")
if len(used) > 1:
    fails.append(f"the upstreams name {len(used)} routers, expected one: {sorted(used)}")

for fail in fails:
    print("FAIL", fail)
if fails:
    sys.exit(1)
print(f"PASS: {', '.join(CLUSTERS)} -> {', '.join(sorted(used))}")
