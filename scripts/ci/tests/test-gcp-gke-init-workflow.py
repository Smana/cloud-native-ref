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
before(s3, 'zitadel-idp.sh" sync', "== registering the OIDC clients", "a hosting stage 3 configures the IdP and Action before its clients")
# One flag list per sync, expanded by both the real call and the printed
# recovery, so the recovery cannot drift from what the deploy runs.
client_args = re.search(r"CLIENT_SYNC_ARGS=\((.*?)\n\s*\)", s3, re.S)
client_args = client_args.group(1) if client_args else ""
for flag in ("--openbao-url", "--openbao-root-token-secret openbao-priv-gcp-root-token", "--openbao-ca-file", "--mirror-openbao",
             "--workforce-pool", "--cluster", "--project"):
    if flag not in client_args:
        fails.append(f"CLIENT_SYNC_ARGS carries {flag}")
if "--cluster" not in (re.search(r"IDP_SYNC_ARGS=\((.*?)\)", s3, re.S) or [None, ""])[1]:
    fails.append("IDP_SYNC_ARGS carries --cluster")


def call_line(text, script):
    """The logical line (continuations joined) that runs `script" sync`."""
    joined = re.sub(r"\\\n\s*", " ", text)
    return next((l for l in joined.splitlines() if f'{script}" sync' in l and not l.lstrip().startswith("echo")), "")


real = s3[s3.find("== registering the Google IdP"):] if "== registering the Google IdP" in s3 else ""
if "IDP_SYNC_ARGS[@]" not in call_line(real, "zitadel-idp.sh"):
    fails.append("the real IdP sync expands IDP_SYNC_ARGS")
if "CLIENT_SYNC_ARGS[@]" not in call_line(real, "zitadel-oidc-clients.sh"):
    fails.append("the real clients sync expands CLIENT_SYNC_ARGS")
m = re.search(r"ZITADEL not ready.*?\n\s*exit 0", s3, re.S)
recovery = m.group(0) if m else ""
before(recovery, "zitadel-idp.sh sync", "zitadel-oidc-clients.sh sync", "the not-ready recovery prints the IdP sync, then the clients sync")
for line_has, arr in (("zitadel-idp.sh sync", "IDP_SYNC_ARGS[@]"), ("zitadel-oidc-clients.sh sync", "CLIENT_SYNC_ARGS[@]")):
    line = next((l for l in recovery.splitlines() if line_has in l), "")
    if arr not in line or "--apply" not in line:
        fails.append(f"the not-ready recovery's {line_has} expands {arr} and passes --apply")
before(s3, "CLIENT_SYNC_ARGS=(", "ZITADEL not ready", "the flag lists exist before the recovery prints them")

# Stage 5 (item 3): the same check aws-0's deploy halts on, for a hosting gcp-0.
deploy = re.search(r'\nscript "deploy" \{(.*?)(?=\nscript "|\Z)', TEXT, re.S)
deploy = deploy.group(1) if deploy else ""
s5 = job_body(deploy, "stage5-verify-openbao-oidc")
if not s5:
    fails.append("script deploy has a stage5-verify-openbao-oidc job")
before(deploy, '"stage3-secrets-and-oidc"', '"stage5-verify-openbao-oidc"', "stage 5 runs after stage 3")
if "set -euo pipefail" not in s5:
    fails.append("stage 5 runs under errexit")
body5 = s5.split("<<-BASH", 1)[-1].split("\n      BASH", 1)[0]
logical5 = [l.strip() for l in re.sub(r"\\\n\s*", " ", body5).splitlines() if l.strip()]
last5 = logical5[-1] if logical5 else ""
if not last5.startswith('bash "$${ROOT}/scripts/provision/openbao-oidc-check.sh"') or re.search(r"\|\||&&|;|\|", last5):
    fails.append("stage 5's check is its last statement, so exit 1 and exit 2 both halt the deploy")
for arg in ("--cloud gcp", "--project", "--root-token-secret-name openbao-priv-gcp-root-token",
            "/opentofu/gcp/gke/configure/.tls/ca.pem", "/ui/vault/auth/oidc/oidc/callback"):
    if arg not in last5:
        fails.append(f"stage 5's check passes {arg}")
before(s5, 'DEPLOY_IDP}" != "true" ]', "openbao-oidc-check.sh", "stage 5 skips a consuming cluster before the check")
skip = s5[s5.find('DEPLOY_IDP}" != "true" ]'):s5.find("openbao-oidc-check.sh")]
if "exit 0" not in skip or "echo" not in skip:
    fails.append("stage 5's consumer skip says why and exits 0")

for f in fails:
    print("FAIL", f)
if fails:
    sys.exit(1)
print("PASS")
