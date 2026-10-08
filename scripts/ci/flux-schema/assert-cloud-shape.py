#!/usr/bin/env python3
"""Fail when gcp-0's agent and AI-gateway renders carry AWS-shaped values (GCP parity GP-14).

render-bundle.py substitutes a */gcp-0/* overlay with CLUSTER_FIXTURE_VARS["gcp-0"],
so these files show what gcp-0 will receive. A same-named variable holding an AWS
value -- ${region} inside oidc.eks.<region>.amazonaws.com, an EKS /keys JWKS --
renders schema-valid and fails only on the cluster (memory
flux_render_fixture_cross_cloud_blindspot). check-substitution.py catches a
MISSING key; this catches a wrong-shaped one, and a child that bypasses the
gcp-0 overlay so the render never sees gcp-0's values at all.

Scope is the agent platform and the AI gateway. Other gcp-0 overlays legitimately
name AWS (the Route53 federation) and are not judged here. Two checks reach past
that scope because they are GKE-shape too: gcp-0's envoy-gateway must carry the
rate-limit KVStore once llm-gateway's budgets are deployed, no gcp-0 chart CNP
may reach the metadata server through `toEntities: host`, and no pod off the host
network in a gcp-0 or base render may tolerate Cilium's startup taint (F2).
"""
import pathlib
import re
import sys

import yaml

SCOPED = re.compile(r"^overlay-(infrastructure|security|observability)-gcp-0-(agent-[a-z-]+|room-broker|octo-sts|envoy-ai-gateway|envoy-gateway|vllm-semantic-router)\.yaml$")
# Only run tokens are judged by issuer: another gcp-0 policy may trust ZITADEL.
RUN_TOKEN = re.compile(r"-gcp-0-agent-(router|mcp)\.yaml$")
# By name, so a renamed overlay directory fails instead of silently leaving scope.
EXPECTED = (
    "overlay-infrastructure-gcp-0-agent-router.yaml",
    "overlay-infrastructure-gcp-0-agent-mcp.yaml",
    "overlay-infrastructure-gcp-0-room-broker.yaml",
    "overlay-infrastructure-gcp-0-envoy-ai-gateway.yaml",
    "overlay-infrastructure-gcp-0-envoy-gateway.yaml",
    "overlay-infrastructure-gcp-0-vllm-semantic-router.yaml",
    "overlay-security-gcp-0-octo-sts.yaml",
    "overlay-security-gcp-0-agent-secrets.yaml",
    "overlay-observability-gcp-0-agent-platform.yaml",
)
FORBIDDEN = [
    (re.compile(r"amazonaws\.com"), "an amazonaws.com host"),
    (re.compile(r"oidc\.eks\."), "an EKS issuer host"),
    # AWS Secrets Manager key shapes: GCP forbids `/` in names (GP-26), and the
    # gateway's keys are generated on gcp-0 (GP-24).
    (re.compile(r"key:\s*certificates/"), "an AWS-shaped CA secret key"),
    (re.compile(r"platform-llm-api-keys"), "the hand-made AWS gateway-keys entry"),
]
GKE_ISSUER = "https://container.googleapis.com/"
UMBRELLAS = ("clusters/gcp-0-agent-platform", "clusters/gcp-0-ai-gateway")
CLUSTER_VARS = "gke-gcp-0-vars"  # flux_cluster_vars in opentofu/gcp/gke/configure/kubernetes.tf


def _walk(node, key):
    if isinstance(node, dict):
        for k, v in node.items():
            if k == key:
                yield v
            yield from _walk(v, key)
    elif isinstance(node, list):
        for v in node:
            yield from _walk(v, key)


def check_bundle(bundle_dir):
    problems, seen = [], 0
    for name in EXPECTED:
        if not (pathlib.Path(bundle_dir) / name).is_file():
            problems.append(f"{name} is not in the bundle: its checks would silently stop running")
    for f in sorted(pathlib.Path(bundle_dir).glob("overlay-*.yaml")):
        if not SCOPED.match(f.name):
            continue
        seen += 1
        text = f.read_text()
        for pattern, what in FORBIDDEN:
            if pattern.search(text):
                problems.append(f"{f.name}: {what} on gcp-0")
        if not RUN_TOKEN.search(f.name):
            continue
        gke = 0
        for doc in yaml.safe_load_all(text):
            if not doc or doc.get("kind") not in ("SecurityPolicy", "MCPRoute"):
                continue
            for iss in _walk(doc, "issuer"):
                gke += isinstance(iss, str) and iss.startswith(GKE_ISSUER)
                if isinstance(iss, str) and not iss.startswith(GKE_ISSUER):
                    problems.append(f"{f.name}: {doc['kind']} {doc['metadata']['name']} issuer {iss} is not GKE's")
            for uri in _walk(doc, "uri"):
                if isinstance(uri, str) and uri.startswith(GKE_ISSUER) and not uri.endswith("/jwks"):
                    problems.append(f"{f.name}: {doc['kind']} {doc['metadata']['name']} JWKS {uri} is not <issuer>/jwks")
        if not gke:
            problems.append(f"{f.name}: no SecurityPolicy or MCPRoute with a GKE issuer: the issuer check would be vacuous")
    if seen == 0:
        problems.append("no gcp-0 agent or AI-gateway overlay in the bundle: the gate would be vacuous")
    return problems


def check_umbrellas(root):
    problems = []
    for d in UMBRELLAS:
        children = substituting = 0
        for f in sorted((pathlib.Path(root) / d).glob("*.yaml")):
            for doc in yaml.safe_load_all(f.read_text()):
                if not doc or doc.get("kind") != "Kustomization" or "toolkit.fluxcd.io" not in doc.get("apiVersion", ""):
                    continue
                children += 1
                subs = ((doc.get("spec") or {}).get("postBuild") or {}).get("substituteFrom") or []
                substituting += any(s.get("name") == CLUSTER_VARS for s in subs)
                # Keyed on any substitution, not the name: a renamed ConfigMap must still be judged.
                if subs and "/gcp-0/" not in doc["spec"].get("path", ""):
                    names = ", ".join(str(s.get("name")) for s in subs)
                    problems.append(f"{f.relative_to(root)}: substitutes {names} into {doc['spec']['path']}, "
                                    "which CI renders with AWS values; point it at a */gcp-0/* overlay")
        if not children:
            problems.append(f"{d}: missing or holds no Flux Kustomization: the umbrella check would be vacuous")
        elif not substituting:
            problems.append(f"{d}: no child substitutes {CLUSTER_VARS}; was the ConfigMap renamed? "
                            "gcp-0's values would never reach these children")
    return problems


def _docs(path):
    if not path.is_file():
        return []
    return [d for d in yaml.safe_load_all(path.read_text()) if isinstance(d, dict)]


def _named(docs, kind, name):
    return next((d for d in docs if d.get("kind") == kind and d["metadata"]["name"] == name), None)


def check_gcp0_secrets(bundle_dir):
    """The GP-24 and GP-26 patches applied: FORBIDDEN proves the AWS entry is gone, not what replaced it."""
    problems = []
    f = pathlib.Path(bundle_dir) / "overlay-infrastructure-gcp-0-envoy-ai-gateway.yaml"
    docs = _docs(f)
    es = _named(docs, "ExternalSecret", "ai-gateway-api-keys")
    if es is None:
        problems.append(f"{f.name}: no ExternalSecret ai-gateway-api-keys rendered")
    else:
        spec = es.get("spec") or {}
        if "secretStoreRef" in spec or spec.get("data"):
            problems.append(f"{f.name}: ai-gateway-api-keys still reads a secret store; gcp-0 generates its keys (GP-24)")
        # Any other policy regenerates the keys on refresh and locks every client out.
        if spec.get("refreshPolicy") != "CreatedOnce":
            problems.append(f"{f.name}: ai-gateway-api-keys refreshPolicy is {spec.get('refreshPolicy')}, not CreatedOnce")
        refs = [((s.get("sourceRef") or {}).get("generatorRef") or {}) for s in spec.get("dataFrom") or []]
        passwords = {d["metadata"]["name"] for d in docs if d.get("kind") == "Password"}
        if not refs:
            problems.append(f"{f.name}: ai-gateway-api-keys has no generator")
        for r in refs:
            if r.get("kind") != "Password" or r.get("name") not in passwords:
                problems.append(f"{f.name}: ai-gateway-api-keys generator {r.get('kind')}/{r.get('name')} "
                                "is not a Password rendered beside it")
    for overlay, name in (("overlay-security-gcp-0-agent-secrets.yaml", "openbao-ca"),
                          ("overlay-infrastructure-gcp-0-room-broker.yaml", "room-broker-ca")):
        f = pathlib.Path(bundle_dir) / overlay
        es = _named(_docs(f), "ExternalSecret", name)
        keys = [((d.get("remoteRef") or {}).get("key")) for d in ((es or {}).get("spec") or {}).get("data") or []]
        if keys != ["openbao-priv-gcp-ca-chain"]:
            problems.append(f"{f.name}: {name} reads {keys or 'nothing'}, not Secret Manager's openbao-priv-gcp-ca-chain (GP-26)")
    return problems


def check_ratelimit(bundle_dir, root):
    """llm-gateway's token budgets need the rate-limit service, whose backend is the KVStore."""
    # Keyed on the path, not the name: renaming the child must not drop the check.
    children = [d for f in sorted((pathlib.Path(root) / "clusters/gcp-0-ai-gateway").glob("*.yaml"))
                for d in _docs(f) if d.get("kind") == "Kustomization"
                and str((d.get("spec") or {}).get("path", "")).rstrip("/").endswith("/llm-gateway")]
    f = pathlib.Path(bundle_dir) / "overlay-infrastructure-gcp-0-envoy-gateway.yaml"
    if children and not any(d.get("kind") == "KVStore" for d in _docs(f)):
        return [f"{f.name}: llm-gateway is an ai-gateway child but gcp-0's envoy-gateway renders no KVStore; "
                "point infrastructure/gcp-0/envoy-gateway at base/envoy-gateway-ratelimit"]
    return []


def reaches_port_80(rule):
    """No ports, port 0 (Cilium's "any"), 80, or a range spanning 80."""
    ports = [p for tp in rule.get("toPorts") or [] for p in tp.get("ports") or []]
    if not ports:
        return True
    for p in ports:
        port = str(p.get("port") or "0")
        if not port.isdigit():  # a named port
            continue
        start, end = int(port), int(p.get("endPort") or 0)
        if start in (0, 80) or start < 80 <= end:
            return True
    return False


def check_metadata_egress(bundle_dir):
    """test-gcp-metadata-server-cidr.py covers kustomize paths; a chart's CNP exists only in the render.

    On GKE `toEntities: host` never matches 169.254.169.254. Base-slug charts
    have no cluster in their name and are left to that test's source view.
    """
    problems, seen = [], False
    for f in sorted(pathlib.Path(bundle_dir).glob("chart-*-gcp-0-*.yaml")):
        for doc in _docs(f):
            if doc.get("kind") not in ("CiliumNetworkPolicy", "CiliumClusterwideNetworkPolicy"):
                continue
            for i, rule in enumerate((doc.get("spec") or {}).get("egress") or []):
                seen |= "169.254.169.254/32" in (rule.get("toCIDR") or [])
                if "host" not in (rule.get("toEntities") or []):
                    continue
                if reaches_port_80(rule):
                    problems.append(f"{f.name}: CNP {doc['metadata']['name']} egress[{i}] reaches the metadata "
                                    "server via `host`; use toCIDR 169.254.169.254/32 on TCP 80")
    # Coupled to the runlore chart's toCIDR rule: a runlore bump that changes it turns this red.
    if not seen:
        problems.append("no gcp-0 chart CNP reaches 169.254.169.254/32: the metadata check would be vacuous")
    return problems


POD_KINDS = ("Deployment", "DaemonSet", "StatefulSet", "ReplicaSet", "Job", "CronJob", "Pod")
CILIUM_VALUES = "opentofu/gcp/gke/init/helm_values/cilium.yaml"
# Non-hostNetwork pods allowed a blanket toleration anyway. Keep it empty unless one truly must.
STARTUP_TAINT_ALLOW = set()


def _pod_spec(doc):
    spec = doc.get("spec") or {}
    if doc["kind"] == "Pod":
        return spec
    if doc["kind"] == "CronJob":
        spec = (spec.get("jobTemplate") or {}).get("spec") or {}
    return (spec.get("template") or {}).get("spec") or {}


def check_startup_taint(bundle_dir, root):
    """F2: a gcp-0 pod that tolerates Cilium's agent-not-ready taint runs unpoliced until the agent is up.

    GKE's autoscaler ignores the key, so no pod needs the toleration. A hostNetwork
    pod has no CiliumEndpoint to wait for, so node agents may tolerate everything.
    Every render except aws-0's is judged: gcp-0 applies several charts and overlays
    straight from base (agent-sandbox, agent-runtime, ...), whose names carry no cluster.
    """
    values = _docs(pathlib.Path(root) / CILIUM_VALUES)
    key = (values[0] if values else {}).get("agentNotReadyTaintKey")
    if not key:
        return [f"{CILIUM_VALUES}: no agentNotReadyTaintKey: the startup-taint check has no key to judge"]
    problems, seen = [], 0
    for f in sorted(pathlib.Path(bundle_dir).glob("*.yaml")):
        if "-aws-0-" in f.name:
            continue
        for doc in _docs(f):
            if doc.get("kind") not in POD_KINDS:
                continue
            seen += 1
            pod = _pod_spec(doc)
            name = f"{doc['kind']}/{doc['metadata'].get('name')}"
            if pod.get("hostNetwork") is True or name in STARTUP_TAINT_ALLOW:
                continue
            for t in pod.get("tolerations") or []:
                blanket = not t.get("key") and t.get("operator") == "Exists" and t.get("effect") in (None, "NoSchedule")
                if blanket or t.get("key") == key:
                    problems.append(f"{f.name}: {name} tolerates {'every taint' if blanket else key}, so it can "
                                    "start before Cilium on a fresh node, with no network policy (F2)")
    if not seen:
        problems.append("no gcp-0 or base pod template in the bundle: the startup-taint check would be vacuous")
    return problems


def main():
    bundle_dir = sys.argv[1] if len(sys.argv) > 1 else ".bundle"
    root = sys.argv[2] if len(sys.argv) > 2 else pathlib.Path(__file__).resolve().parents[3]
    problems = (check_bundle(bundle_dir) + check_umbrellas(root) + check_gcp0_secrets(bundle_dir)
                + check_ratelimit(bundle_dir, root) + check_metadata_egress(bundle_dir)
                + check_startup_taint(bundle_dir, root))
    for p in problems:
        print(f"FAIL: {p}")
    scoped = sum(1 for f in pathlib.Path(bundle_dir).glob("overlay-*.yaml") if SCOPED.match(f.name))
    children = sum(1 for d in UMBRELLAS for f in (pathlib.Path(root) / d).glob("*.yaml") if f.name != "kustomization.yaml")
    print(f"==> cloud shape: {scoped} gcp-0 overlay(s), {children} umbrella child(ren), {len(problems)} problem(s)")
    sys.exit(1 if problems else 0)


if __name__ == "__main__":
    main()
