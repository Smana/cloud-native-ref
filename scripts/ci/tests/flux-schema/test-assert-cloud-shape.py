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

# GP-24 and GP-26: the gcp-0 patches must apply, not just leave no AWS string behind.
KEYS = """apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata: {name: ai-gateway-api-keys, namespace: envoy-gateway-system}
spec:
  refreshPolicy: CreatedOnce
  dataFrom:
    - sourceRef: {generatorRef: {apiVersion: generators.external-secrets.io/v1alpha1, kind: Password, name: k1}}
---
apiVersion: generators.external-secrets.io/v1alpha1
kind: Password
metadata: {name: k1, namespace: envoy-gateway-system}
spec: {length: 48}
"""
CA = """apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata: {name: openbao-ca, namespace: agent-system}
spec:
  secretStoreRef: {kind: ClusterSecretStore, name: clustersecretstore}
  data:
    - secretKey: ca.crt
      remoteRef: {key: openbao-priv-gcp-ca-chain}
"""


def secrets(keys=KEYS, ca=CA):
    return acs.check_gcp0_secrets(bundle({"overlay-infrastructure-gcp-0-envoy-ai-gateway.yaml": keys,
                                          "overlay-security-gcp-0-agent-secrets.yaml": ca}))


if secrets():
    fails.append("generated gateway keys and the GCP CA key must pass")
if not secrets(keys=KEYS.replace("  refreshPolicy: CreatedOnce\n", "")):
    fails.append("gateway keys regenerated on every refresh must fail")
if not secrets(keys=KEYS.replace("spec:\n  refreshPolicy", "spec:\n  secretStoreRef: {kind: ClusterSecretStore, name: clustersecretstore}\n  refreshPolicy")):
    fails.append("gateway keys still bound to a store must fail")
if not secrets(keys=KEYS.replace("kind: Password, name: k1", "kind: Fake, name: k1")):
    fails.append("gateway keys from a non-Password generator must fail")
if not secrets(keys=KEYS.replace("metadata: {name: k1,", "metadata: {name: k2,")):
    fails.append("gateway keys from a generator the render lacks must fail")
if not secrets(ca=CA.replace("openbao-priv-gcp-ca-chain", "openbao-priv-gcp-root-token")):
    fails.append("an openbao-ca reading any other entry must fail")
if not secrets(keys="", ca=""):
    fails.append("a render with neither ExternalSecret is vacuous and must fail")

# The ai-gateway umbrella's llm-gateway child carries the budgets; without a
# KVStore the rate-limit service has no backend.
LLM_CHILD = """apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata: {name: llm-gateway, namespace: flux-system}
spec: {path: ./infrastructure/base/llm-gateway}
"""
KV = "apiVersion: cloud.ogenki.io/v1alpha1\nkind: KVStore\nmetadata: {name: xplane-ai-gateway-ratelimit, namespace: envoy-gateway-system}\n"
rl = pathlib.Path(tempfile.mkdtemp())
(rl / "clusters/gcp-0-ai-gateway").mkdir(parents=True)
# kustomize's own Kustomization has no metadata; it sits beside every child.
(rl / "clusters/gcp-0-ai-gateway/kustomization.yaml").write_text("apiVersion: kustomize.config.k8s.io/v1beta1\nkind: Kustomization\nresources: []\n")
if acs.check_ratelimit(bundle({"overlay-infrastructure-gcp-0-envoy-gateway.yaml": ""}), rl):
    fails.append("no llm-gateway child needs no KVStore")
(rl / "clusters/gcp-0-ai-gateway/infrastructure-llm-gateway.yaml").write_text(LLM_CHILD)
if acs.check_ratelimit(bundle({"overlay-infrastructure-gcp-0-envoy-gateway.yaml": KV}), rl):
    fails.append("llm-gateway with a KVStore in gcp-0's envoy-gateway must pass")
if not acs.check_ratelimit(bundle({"overlay-infrastructure-gcp-0-envoy-gateway.yaml": ""}), rl):
    fails.append("llm-gateway without a KVStore in gcp-0's envoy-gateway must fail")

# test-gcp-metadata-server-cidr.py builds kustomize paths; charts are the part
# only the rendered bundle shows.
CNP = """apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata: {{name: runlore, namespace: observability}}
spec:
  egress:
    - {rule}
      toPorts: [{{ports: [{{port: "80", protocol: TCP}}]}}]
"""
METADATA = CNP.format(rule="toCIDR: [169.254.169.254/32]")
HOST = CNP.format(rule="toEntities: [host]")
if acs.check_metadata_egress(bundle({"chart-observability-gcp-0-runlore-runlore.yaml": METADATA})):
    fails.append("a gcp-0 chart CNP reaching the metadata server by CIDR must pass")
if not acs.check_metadata_egress(bundle({"chart-observability-gcp-0-runlore-runlore.yaml": METADATA + "---\n" + HOST})):
    fails.append("a gcp-0 chart CNP reaching host:80 must fail")
if acs.check_metadata_egress(bundle({"chart-observability-gcp-0-runlore-runlore.yaml": METADATA, "chart-observability-aws-0-runlore-runlore.yaml": HOST})):
    fails.append("aws-0's host:80 rule is correct on EKS and must not be judged")
if not acs.check_metadata_egress(bundle({"chart-observability-aws-0-runlore-runlore.yaml": METADATA})):
    fails.append("no gcp-0 chart CNP reaching the metadata server is vacuous and must fail")

for f in fails:
    print("FAIL", f)
if fails:
    sys.exit(1)
print("PASS")
