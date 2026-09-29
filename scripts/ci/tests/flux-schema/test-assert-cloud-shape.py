#!/usr/bin/env python3
"""assert-cloud-shape.py (GCP parity GP-14) against fixture bundles and trees."""
import importlib.util
import pathlib
import sys
import tempfile

try:
    import yaml  # noqa: F401
except ImportError:
    print("PyYAML is not installed")
    sys.exit(77)

ROOT = pathlib.Path(__file__).resolve().parents[4]
spec = importlib.util.spec_from_file_location("acs", ROOT / "scripts/ci/flux-schema/assert-cloud-shape.py")
if spec is None or not (ROOT / "scripts/ci/flux-schema/assert-cloud-shape.py").exists():
    print("FAIL assert-cloud-shape.py does not exist")
    sys.exit(1)
acs = importlib.util.module_from_spec(spec)
spec.loader.exec_module(acs)

GKE = "https://container.googleapis.com/v1/projects/p/locations/z/clusters/gcp-0"
GOOD = f"""apiVersion: gateway.envoyproxy.io/v1alpha1
kind: SecurityPolicy
metadata: {{name: agent-router-public, namespace: agent-system}}
spec:
  jwt:
    providers:
      - name: p
        issuer: {GKE}
        remoteJWKS:
          uri: {GKE}/jwks
"""
fails = []


def bundle(files):
    d = pathlib.Path(tempfile.mkdtemp())
    for name, text in files.items():
        (d / name).write_text(text)
    return d


if acs.check_bundle(bundle({"overlay-infrastructure-gcp-0-agent-router.yaml": GOOD})):
    fails.append("a GKE-shaped gcp-0 agent-router must pass")
if not acs.check_bundle(bundle({"overlay-infrastructure-gcp-0-agent-router.yaml": GOOD.replace("/jwks", "/keys")})):
    fails.append("an EKS-shaped JWKS path on gcp-0 must fail")
if not acs.check_bundle(bundle({"overlay-security-gcp-0-octo-sts.yaml": "toFQDNs:\n  - matchName: oidc.eks.europe-west4.amazonaws.com\n"})):
    fails.append("an amazonaws.com host in a gcp-0 agent overlay must fail")
if not acs.check_bundle(bundle({"overlay-infrastructure-gcp-0-agent-router.yaml": GOOD.replace(GKE + "\n", "https://oidc.eks.x/id/Y\n", 1)})):
    fails.append("an EKS issuer on gcp-0 must fail")
if not acs.check_bundle(bundle({"overlay-infrastructure-aws-0-agent-router.yaml": GOOD})):
    fails.append("a bundle with no gcp-0 agent overlay is vacuous and must fail")
if acs.check_bundle(bundle({"overlay-infrastructure-gcp-0-agent-router.yaml": GOOD, "overlay-security-gcp-0-cert-manager-public.yaml": "region: eu-west-3\nrole: arn:aws:iam::1:role/x\nsts.amazonaws.com\n"})):
    fails.append("an out-of-scope gcp-0 overlay (Route53 federation) must not be judged")
if not acs.check_bundle(bundle({"overlay-infrastructure-gcp-0-agent-router.yaml": GOOD, "overlay-security-gcp-0-agent-secrets.yaml": "remoteRef:\n  key: certificates/priv.gcp.cluster.local/ca-chain\n  property: ca\n"})):
    fails.append("an AWS-shaped CA key in gcp-0's agent-secrets must fail")
if not acs.check_bundle(bundle({"overlay-infrastructure-gcp-0-agent-router.yaml": GOOD, "overlay-infrastructure-gcp-0-envoy-ai-gateway.yaml": "remoteRef:\n  key: platform-llm-api-keys\n"})):
    fails.append("the hand-made gateway-keys entry on gcp-0 must fail")

tree = pathlib.Path(tempfile.mkdtemp())
(tree / "clusters/gcp-0-agent-platform").mkdir(parents=True)
child = """apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata: {{name: agent-router, namespace: flux-system}}
spec:
  path: {path}
  postBuild:
    substituteFrom:
      - {{kind: ConfigMap, name: gke-gcp-0-vars}}
"""
(tree / "clusters/gcp-0-agent-platform/infrastructure-agent-router.yaml").write_text(child.format(path="./infrastructure/gcp-0/agent-router"))
if acs.check_umbrellas(tree):
    fails.append("a substituted child on a gcp-0 overlay must pass")
(tree / "clusters/gcp-0-agent-platform/infrastructure-agent-router.yaml").write_text(child.format(path="./infrastructure/base/agent-router"))
if not acs.check_umbrellas(tree):
    fails.append("a substituted child on a base/ path must fail")

for f in fails:
    print("FAIL", f)
if fails:
    sys.exit(1)
print("PASS")
