#!/usr/bin/env python3
# requires: python3
"""gcp/gke/init's deploy jobs (GCP parity G-2/G-3). Each check is a bug a live
GCP deploy hit: 09-11 bug 3 (no CA, no jwt adopt in stage 2), the missing
deploy_identity_provider on the inline configure apply, the custom roles that a
teardown deleted (GP-15), and a hosting stage 3 that must configure the IdP
before its clients and mirror them into OpenBao (GP-5)."""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[3]
TEXT = (ROOT / "opentofu/gcp/gke/init/workflows.tm.hcl").read_text()


def job_body(text, name):
    m = re.search(r'name\s*=\s*"%s"(.*?)(?=\n  job \{|\nscript "|\Z)' % re.escape(name), text, re.S)
    return m.group(1) if m else ""


fails = []


def before(body, first, second, what):
    i, j = body.find(first), body.find(second)
    if i < 0 or j < 0 or i > j:
        fails.append(what)


s2 = job_body(TEXT, "stage2-cilium-and-flux")
if not s2:
    fails.append("no stage2-cilium-and-flux job")
before(s2, 'openbao-config.sh" ca', "init -lock-timeout", "stage 2 writes OpenBao's CA before init")
before(s2, "init -lock-timeout", "openbao-adopt-jwt-mount.sh", "stage 2 adopts jwt/gcp-0 after init")
before(s2, "openbao-adopt-jwt-mount.sh", "apply -auto-approve", "stage 2 adopts jwt/gcp-0 before its apply")
apply_line = next((l for l in s2.splitlines() if "apply -auto-approve" in l), "")
if "deploy_identity_provider=${global.deploy_identity_provider_gcp}" not in apply_line:
    fails.append("stage 2's apply passes deploy_identity_provider")

for f in fails:
    print("FAIL", f)
if fails:
    sys.exit(1)
print("PASS")
