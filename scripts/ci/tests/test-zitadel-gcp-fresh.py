#!/usr/bin/env python3
# requires: python3 kustomize
"""GCP parity GP-3: gcp-0's ZITADEL starts from initdb with every key generated
in-cluster, and reads its DB admin from CNPG's own superuser Secret."""
import pathlib
import subprocess
import sys

try:
    import yaml
except ImportError:
    print("PyYAML is not installed")
    sys.exit(77)

ROOT = pathlib.Path(__file__).resolve().parents[3]
out = subprocess.run(["kustomize", "build", str(ROOT / "security/gcp-0/zitadel"), "--load-restrictor=LoadRestrictionsNone"],
                     capture_output=True, text=True, check=True).stdout
docs = [d for d in yaml.safe_load_all(out) if d]
by = {(d["kind"], d["metadata"]["name"]): d for d in docs}
fails = []

for d in docs:
    if d["kind"] == "ExternalSecret" and (d["spec"].get("secretStoreRef") or {}).get("name") in ("openbao-platform", "clustersecretstore"):
        fails.append(f"ExternalSecret {d['metadata']['name']} still reads a store")
if ("ExternalSecret", "zitadel-envvars") in by:
    fails.append("zitadel-envvars must be gone on gcp-0")
for name in ("zitadel-masterkey", "zitadel-db-user", "zitadel-first-human"):
    es = by.get(("ExternalSecret", name))
    if not es:
        fails.append(f"no ExternalSecret {name}")
        continue
    ref = (((es["spec"].get("dataFrom") or [{}])[0].get("sourceRef") or {}).get("generatorRef") or {})
    if ref.get("kind") != "Password" or es["spec"].get("refreshPolicy") != "CreatedOnce":
        fails.append(f"{name} is not a CreatedOnce Password generator")
    if es["spec"]["target"].get("deletionPolicy") != "Retain":
        fails.append(f"{name} must Retain its Secret")
mk = by.get(("Password", "zitadel-masterkey"), {}).get("spec", {})
if mk.get("length") != 32 or mk.get("symbols") != 0:
    fails.append("the masterkey generator must make 32 characters without symbols")
sql = by.get(("SQLInstance", "xplane-zitadel"), {}).get("spec", {})
if "objectStoreRecovery" in sql or "backup" not in sql:
    fails.append("the SQLInstance must initdb (no objectStoreRecovery) and keep its backups")
vals = by.get(("HelmRelease", "zitadel"), {}).get("spec", {}).get("values", {})
if vals.get("envVarsSecret"):
    fails.append("envVarsSecret must be empty on gcp-0")
env = {e["name"]: e for e in vals.get("env", [])}
for var in ("ZITADEL_DATABASE_POSTGRES_ADMIN_USERNAME", "ZITADEL_DATABASE_POSTGRES_ADMIN_PASSWORD"):
    if env.get(var, {}).get("valueFrom", {}).get("secretKeyRef", {}).get("name") != "xplane-zitadel-cnpg-superuser":
        fails.append(f"{var} must come from xplane-zitadel-cnpg-superuser")
for var, secret in (("ZITADEL_DATABASE_POSTGRES_USER_PASSWORD", "zitadel-db-user"),
                    ("ZITADEL_FIRSTINSTANCE_ORG_HUMAN_PASSWORD", "zitadel-first-human")):
    if env.get(var, {}).get("valueFrom", {}).get("secretKeyRef", {}).get("name") != secret:
        fails.append(f"{var} must come from {secret}")

for f in fails:
    print("FAIL", f)
if fails:
    sys.exit(1)
print("PASS")
