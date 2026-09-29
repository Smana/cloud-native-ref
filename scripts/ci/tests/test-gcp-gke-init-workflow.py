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


def job_bodies(text, name):
    return re.findall(r'name\s*=\s*"%s"(.*?)(?=\n  job \{|\nscript "|\Z)' % re.escape(name), text, re.S)


def job_body(text, name):
    return next(iter(job_bodies(text, name)), "")


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

# Two stage1-cluster jobs: `deploy` and `deploy-stage1`.
s1_jobs = job_bodies(TEXT, "stage1-cluster")
if len(s1_jobs) != 2:
    fails.append(f"expected 2 stage1-cluster jobs, found {len(s1_jobs)}")
for n, s1 in enumerate(s1_jobs, 1):
    before(s1, "adopt-custom-roles.sh", "apply -auto-approve",
           f"stage1-cluster job {n} adopts the kept custom roles before its apply")
confirm = job_body(TEXT, "confirm")
for addr in ("crossplane_dns", "crossplane_storage", "crossplane_role_reader"):
    if f"google_project_iam_custom_role.{addr}" not in confirm or "state rm" not in confirm:
        fails.append(f"the destroy keeps google_project_iam_custom_role.{addr} out of the teardown")
# A swallowed state rm (lock, backend, auth) lets the cluster destroy delete the
# roles and burn their IDs for 37 days.
state_lines = [l for l in confirm.splitlines()
               if ("state rm" in l or "state list" in l) and not l.lstrip().startswith("#")]
if any("|| true" in l or "2>/dev/null" in l for l in state_lines):
    fails.append("the destroy's custom-role state rm swallows its failures")
if not any("state rm -lock-timeout=" in l for l in state_lines):
    fails.append("the destroy's custom-role state rm waits for the state lock")

s3 = job_body(TEXT, "stage3-secrets-and-oidc")
hosting = s3[s3.find("== registering the OIDC clients"):] if "== registering the OIDC clients" in s3 else ""
before(s3, 'zitadel-idp.sh" sync', "== registering the OIDC clients", "a hosting stage 3 configures the IdP and Action before its clients")
for flag in ("--openbao-url", "--openbao-root-token-secret openbao-priv-gcp-root-token", "--openbao-ca-file", "--mirror-openbao"):
    if flag not in hosting:
        fails.append(f"the hosting clients sync passes {flag}")

for f in fails:
    print("FAIL", f)
if fails:
    sys.exit(1)
print("PASS")
