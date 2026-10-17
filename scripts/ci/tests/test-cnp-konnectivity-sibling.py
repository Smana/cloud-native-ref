#!/usr/bin/env python3
# requires: python3
"""A GKE private control plane reaches webhook and APIService pods through konnectivity-agent,
an ordinary kube-system pod, so Cilium attributes the connection to that pod and an ingress
`fromEntities: [kube-apiserver]` never matches: the SYN is dropped and the caller times out
(`failed calling webhook ... i/o timeout`). Every such rule therefore needs a sibling ingress
rule from the konnectivity-agent endpoints with the same toPorts. The sibling is inert on EKS.
The measurement is in infrastructure/base/keda/network-policy.yaml."""
import pathlib
import subprocess
import sys

try:
    import yaml
except ImportError:
    print("PyYAML is not installed")
    sys.exit(77)

ROOT = pathlib.Path(__file__).resolve().parents[3]
KINDS = {"CiliumNetworkPolicy", "CiliumClusterwideNetworkPolicy"}
KONNECTIVITY = {"io.kubernetes.pod.namespace": "kube-system", "k8s-app": "konnectivity-agent"}


def tracked_yaml():
    out = subprocess.run(["git", "ls-files", "*.yaml", "*.yml"], cwd=ROOT, capture_output=True, text=True, check=True)
    return [ROOT / p for p in out.stdout.split()]


def from_konnectivity(rule):
    return any((e or {}).get("matchLabels") == KONNECTIVITY for e in rule.get("fromEndpoints") or [])


def specs(doc):
    if doc.get("spec"):
        yield doc["spec"]
    yield from doc.get("specs") or []


failures, seen = [], 0
for path in tracked_yaml():
    text = path.read_text()
    if "kube-apiserver" not in text:
        continue
    try:
        docs = list(yaml.safe_load_all(text))
    except yaml.YAMLError:
        continue  # templated, not a manifest
    for doc in docs:
        if not isinstance(doc, dict) or doc.get("kind") not in KINDS:
            continue
        name = f"{path.relative_to(ROOT)}: {doc['metadata'].get('namespace', '-')}/{doc['metadata']['name']}"
        for spec in specs(doc):
            ingress = spec.get("ingress") or []
            siblings = [r.get("toPorts") for r in ingress if from_konnectivity(r)]
            for rule in ingress:
                if "kube-apiserver" in (rule.get("fromEntities") or []):
                    seen += 1
                    if rule.get("toPorts") not in siblings:
                        failures.append(f"{name}: ingress from kube-apiserver {rule.get('toPorts')} has no konnectivity-agent sibling with the same toPorts")

for f in failures:
    print(f"  FAIL {f}")
print(f"{seen} ingress rules from kube-apiserver, {len(failures)} without a konnectivity-agent sibling")
sys.exit(1 if failures else 0)
