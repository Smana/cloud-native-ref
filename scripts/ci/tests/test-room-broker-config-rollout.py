#!/usr/bin/env python3
# requires: python3 kustomize
"""#2274: the room broker reads its config once at startup, so a config change must
change the App's pod template, or nothing rolls. In each cloud's render, the App's
config volume must name the generated ConfigMap, and an edit to config.yaml alone
must move that name. A plain ConfigMap, or a lost nameReference for the App CRD,
fails here."""
import pathlib
import shutil
import subprocess
import sys
import tempfile

try:
    import yaml
except ImportError:
    print("PyYAML is not installed")
    sys.exit(77)

ROOT = pathlib.Path(__file__).resolve().parents[3]


def config_refs(infra, cloud):
    out = subprocess.run(["kustomize", "build", str(infra / cloud / "room-broker")],
                         capture_output=True, text=True, check=True).stdout
    docs = [d for d in yaml.safe_load_all(out) if d]
    cms = [d["metadata"]["name"] for d in docs if d["kind"] == "ConfigMap"
           and d["metadata"]["name"].startswith("room-broker-config")]
    app = next(d for d in docs if d["kind"] == "App" and d["metadata"]["name"] == "room-broker")
    vol = next(v for v in app["spec"]["extraVolumes"] if v["name"] == "config")
    return cms, vol["configMap"]["name"]


fails = 0
with tempfile.TemporaryDirectory() as tmp:
    infra = pathlib.Path(tmp)
    for cloud in ("base", "aws-0", "gcp-0"):
        shutil.copytree(ROOT / "infrastructure" / cloud / "room-broker", infra / cloud / "room-broker")
    before = {c: config_refs(infra, c) for c in ("aws-0", "gcp-0")}
    with open(infra / "base/room-broker/config.yaml", "a") as f:
        f.write("# a config-only change\n")
    for cloud, (cms, ref) in before.items():
        _, after = config_refs(infra, cloud)
        checks = {
            "one generated ConfigMap with a hash suffix": len(cms) == 1 and cms[0] != "room-broker-config",
            "the App's config volume names it": cms == [ref],
            "a config edit moves the name": after != ref,
        }
        for desc, ok in checks.items():
            print(f"  {'ok  ' if ok else 'FAIL'} {cloud}: {desc}")
            fails += not ok
sys.exit(1 if fails else 0)
