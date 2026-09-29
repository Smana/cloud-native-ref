#!/usr/bin/env python3
# requires: python3 kustomize
"""GCP parity GP-27 (09-11 bug 6): gcp-0's private external-dns must not wait on
aws-load-balancer-controller, which gcp-0 never runs. With the edge, the release
never installs and no *.priv.gcp record is written, while the parent
Kustomization (no `wait`) still reports Ready."""
import pathlib
import subprocess
import sys

try:
    import yaml
except ImportError:
    print("PyYAML is not installed")
    sys.exit(77)

ROOT = pathlib.Path(__file__).resolve().parents[3]
out = subprocess.run(["kustomize", "build", str(ROOT / "infrastructure/gcp-0/external-dns"),
                      "--load-restrictor=LoadRestrictionsNone"], capture_output=True, text=True, check=True).stdout
hrs = [d for d in yaml.safe_load_all(out) if d and d.get("kind") == "HelmRelease" and d["metadata"]["name"] == "external-dns"]
if len(hrs) != 1:
    print(f"FAIL expected one external-dns HelmRelease, found {len(hrs)}")
    sys.exit(1)
deps = hrs[0]["spec"].get("dependsOn") or []
if any(d.get("name") == "aws-load-balancer-controller" for d in deps):
    print("FAIL gcp-0's external-dns depends on aws-load-balancer-controller, which gcp-0 never runs")
    sys.exit(1)
print("PASS")
