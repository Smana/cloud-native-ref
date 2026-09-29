#!/usr/bin/env python3
# requires: python3
"""GCP parity GP-13: every agent trust policy accepts aws-0's EKS issuer AND
gcp-0's GKE issuer, and nothing wider. octo-sts >= v0.10.0 anchors each pattern
as ^(?:p)$ (pkg/octosts/pattern.go, GHSA-mwqh-2vg8-rhj3), which is why
re.fullmatch is the model (RE2 and Python agree on this subset)."""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[3]
EKS = "https://oidc.eks.eu-west-3.amazonaws.com/id/0123456789ABCDEF0123456789ABCDEF"
GKE = "https://container.googleapis.com/v1/projects/ogenki-435905/locations/europe-west4-a/clusters/gcp-0"
REJECT = [
    "https://container.googleapis.com/v1/projects/attacker/locations/europe-west4-a/clusters/gcp-0",
    "https://container.googleapis.com/v1/projects/ogenki-435905/locations/europe-west4-a/clusters/gcp-1",
    "https://oidc.eks.us-east-1.amazonaws.com/id/0123456789ABCDEF0123456789ABCDEF",
    GKE + "/extra",
    # gcp-0 is zonal, fixed at europe-west4-a (opentofu/gcp/gke/init/main.tf,
    # opentofu/gcp/network/variables.tfvars) — no other zone, and not the bare
    # region either.
    GKE.replace("europe-west4-a", "us-central1-b"),
    GKE.replace("europe-west4-a", "europe-west4"),
    # An unescaped "." in issuer_pattern would still match these next to a real
    # host, since "." matches any character — the reason re.fullmatch on the
    # literal pattern text, not a human read of it, is what has to catch this.
    GKE.replace("container.googleapis.com", "containerXgoogleapis.com"),
    GKE.replace("googleapis.com", "googleapisXcom"),
    EKS.replace("amazonaws.com", "amazonawsXcom"),
    "https://evil.example/" + GKE,
]
fails = []
files = sorted((ROOT / ".github/chainguard").glob("agent-*.sts.yaml"))
if len(files) != 4:
    fails.append(f"expected 4 agent trust policies, found {len(files)}")
for f in files:
    m = re.search(r"^issuer_pattern:\s*'([^']+)'\s*$", f.read_text(), re.M)
    if not m:
        fails.append(f"{f.name}: no single-quoted issuer_pattern")
        continue
    pat = re.compile(m.group(1))
    for iss in (EKS, GKE):
        if not pat.fullmatch(iss):
            fails.append(f"{f.name}: does not accept {iss}")
    for iss in REJECT:
        if pat.fullmatch(iss):
            fails.append(f"{f.name}: accepts {iss}")
for x in fails:
    print("FAIL", x)
if fails:
    sys.exit(1)
print("PASS")
