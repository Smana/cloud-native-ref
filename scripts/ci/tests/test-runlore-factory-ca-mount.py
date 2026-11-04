#!/usr/bin/env python3
# requires: python3
"""RunLore's factory CA (factory.ca_file, RunLore v0.20.0): the chart mounts its config ConfigMap read-only at /etc/runlore, and a
runtime cannot create a mount point inside a read-only mount, so the CA's mount is a sibling path and never under another mount.
The CA ConfigMaps (aws-0 and gcp-0) hold the same public certificate, and the one ai-native-ref ships for the tailnet policy
where the overlay has it."""
import pathlib
import sys

try:
    import yaml
except ImportError:
    print("PyYAML is not installed")
    sys.exit(77)

ROOT = pathlib.Path(__file__).resolve().parents[3]
problems = []
base = yaml.safe_load(next(d for d in yaml.safe_load_all(
    (ROOT / "observability/base/runlore/helm-values-configmap.yaml").read_text()) if d)["data"]["values.yaml"])
chart_mounts = ["/etc/runlore", "/tmp"]  # the chart's own, read-only config and the scratch dir
mounts = {m["name"]: m["mountPath"] for m in base.get("extraVolumeMounts", [])}
ca = mounts.get("factory-ca")
if not ca:
    problems.append("no factory-ca extraVolumeMount")
else:
    for other in chart_mounts + [p for n, p in mounts.items() if n != "factory-ca"]:
        if ca == other or ca.startswith(other.rstrip("/") + "/"):
            problems.append(f"factory-ca mounts at {ca}, inside {other}: the runtime cannot create a mount point in a read-only mount")


def pem(rel):
    d = next(d for d in yaml.safe_load_all((ROOT / rel).read_text()) if d)
    if d["metadata"]["name"] != "factory-ca" or d["metadata"]["namespace"] != "runlore":
        problems.append(f"{rel}: must be ConfigMap factory-ca in runlore")
    value = d["data"]["ca.crt"]
    if "BEGIN CERTIFICATE" not in value or "PRIVATE KEY" in value:
        problems.append(f"{rel}: ca.crt must be a certificate, never a key")
    return value.split()


copies = {rel: pem(rel) for rel in ("observability/aws-0/configmap-factory-ca.yaml",
                                    "observability/gcp-0/runlore/configmap-factory-ca.yaml")}
ref = next(iter(copies.values()))
for rel, v in copies.items():
    if v != ref:
        problems.append(f"{rel} differs from the other cloud's copy: one offline root signs both, rotate them together")
for a in sorted((ROOT / "tooling").glob("*/agent-factory/configmap-agent-factory-ca.yaml")):
    mine = yaml.safe_load(a.read_text())["data"]["ca.crt"].split()
    if mine != ref:
        problems.append(f"{a.relative_to(ROOT)} differs from RunLore's factory-ca: rotate both repositories together")
kz = (ROOT / "observability/gcp-0/runlore/kustomization.yaml").read_text()
if "configmap-factory-ca.yaml" not in kz:
    problems.append("gcp-0's runlore kustomization does not ship the CA ConfigMap with the switch")
if "configmap-factory-ca.yaml" not in (ROOT / "observability/aws-0/kustomization.yaml").read_text():
    problems.append("aws-0's kustomization does not name the CA ConfigMap beside the RunLore switch")
if problems:
    print("\n".join(problems))
    sys.exit(1)
print("PASS: the factory CA mounts beside /etc/runlore, and its copies are one certificate")
