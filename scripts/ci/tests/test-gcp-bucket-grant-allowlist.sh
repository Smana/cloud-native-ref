#!/usr/bin/env bash
# requires: python3
#
# GCP parity GP-23 (09-11 bug 7; memory gcp_crossplane_grant_allowlist_contract):
# every role a GCPWorkloadIdentity grants under bucketRoles must be in gke/init's
# crossplane_bucket_grantable_roles, or the IAM condition denies the grant with a
# bare 403. openbao-snapshot's objectCreator was missing, so gcp-0 never took a
# scheduled snapshot.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
python3 - "$ROOT" <<'PY'
import pathlib, re, sys
root = pathlib.Path(sys.argv[1])
iam = (root / "opentofu/gcp/gke/init/iam.tf").read_text()
m = re.search(r"crossplane_bucket_grantable_roles\s*=\s*\[(.*?)\]", iam, re.S)
if not m:
    print("FAIL no crossplane_bucket_grantable_roles in iam.tf"); sys.exit(1)
allowed = set(re.findall(r'"(roles/[^"]+)"', m.group(1)))
wanted = {}
for area in ("infrastructure", "security", "observability", "tooling", "apps"):
    for f in (root / area).glob("gcp-0/**/*.yaml"):
        text = f.read_text()
        if "kind: GCPWorkloadIdentity" not in text or "bucketRoles:" not in text:
            continue
        for role in re.findall(r"^\s+role:\s*(roles/\S+)", text.split("bucketRoles:", 1)[1], re.M):
            wanted.setdefault(role, []).append(str(f.relative_to(root)))
if not wanted:
    print("FAIL found no bucketRoles grant at all: the scan is broken"); sys.exit(1)
missing = {r: fs for r, fs in wanted.items() if r not in allowed}
for r, fs in sorted(missing.items()):
    print(f"FAIL {r} (asked by {', '.join(fs)}) is not in crossplane_bucket_grantable_roles")
if missing:
    sys.exit(1)
print("PASS")
PY
