#!/usr/bin/env python3
# requires: python3 kustomize
"""On GKE, 169.254.169.254 is never a node-local address: iptables DNATs it to
gke-metadata-server after Cilium has already classified it as `world`, so a
`toEntities: [host]` rule never matches it and the Workload Identity token call
times out. The rule that works, live-proven by runlore (#1862) and image-gallery
(#2022), is `toCIDR: 169.254.169.254/32` on TCP 80.

Builds every path a gcp-0 Flux Kustomization applies and fails on any
CiliumNetworkPolicy that reaches host:80 there; nothing else on gcp-0 listens
on the node's port 80. Charts rendered by a HelmRelease are out of reach here
(runlore's comes from its chart's gcpWorkloadIdentity option); assert-cloud-shape.py
checks those in the rendered bundle."""
import importlib.util
import pathlib
import subprocess
import sys

try:
    import yaml
except ImportError:
    print("PyYAML is not installed")
    sys.exit(77)

ROOT = pathlib.Path(__file__).resolve().parents[3]
# One definition of "reaches port 80", shared with the rendered-bundle check.
_spec = importlib.util.spec_from_file_location("acs", ROOT / "scripts/ci/flux-schema/assert-cloud-shape.py")
_acs = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_acs)
reaches_port_80 = _acs.reaches_port_80
CNP_KINDS = {"CiliumNetworkPolicy", "CiliumClusterwideNetworkPolicy"}
MUST_SEE = {"barman-cloud-plugin", "openbao-snapshot"}  # the two GCP metadata-server consumers built from source


def load(text):
    return [d for d in yaml.safe_load_all(text) if isinstance(d, dict)]


paths = set()
for f in [*(ROOT / "clusters/gcp-0").rglob("*.yaml"), *ROOT.glob("clusters/gcp-0-*/**/*.yaml")]:
    for d in load(f.read_text()):
        if d.get("kind") == "Kustomization" and d.get("apiVersion", "").startswith("kustomize.toolkit.fluxcd.io"):
            paths.add(d["spec"]["path"].lstrip("./").rstrip("/"))

fails, seen = [], {}
for p in sorted(paths):
    d = ROOT / p
    if (d / "kustomization.yaml").is_file():
        r = subprocess.run(["kustomize", "build", str(d), "--load-restrictor=LoadRestrictionsNone"],
                           capture_output=True, text=True)
        if r.returncode != 0:
            fails.append(f"kustomize build {p} failed: {r.stderr.strip().splitlines()[-1:]}")
            continue
        docs = load(r.stdout)
    else:
        docs = [x for f in sorted(d.rglob("*.yaml")) for x in load(f.read_text())]
    for doc in docs:
        if doc.get("kind") not in CNP_KINDS:
            continue
        name = doc["metadata"]["name"]
        for i, rule in enumerate((doc.get("spec") or {}).get("egress") or []):
            if "host" not in (rule.get("toEntities") or []):
                continue
            if reaches_port_80(rule):
                fails.append(f"{p}: CNP {name} egress[{i}] reaches the metadata server via `host`; "
                             "use toCIDR 169.254.169.254/32 on TCP 80")
        if name in MUST_SEE:
            seen[name] = any("169.254.169.254/32" in (r.get("toCIDR") or [])
                             for r in (doc.get("spec") or {}).get("egress") or [])

for name in sorted(MUST_SEE):
    if name not in seen:
        fails.append(f"CNP {name} not found in any gcp-0 build: the check is vacuous")
    elif not seen[name]:
        fails.append(f"CNP {name} has no toCIDR 169.254.169.254/32 rule")

for f in fails:
    print(f"FAIL {f}")
if fails:
    sys.exit(1)
print(f"PASS ({len(paths)} gcp-0 paths built)")
