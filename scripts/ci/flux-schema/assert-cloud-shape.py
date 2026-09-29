#!/usr/bin/env python3
"""Fail when gcp-0's agent and AI-gateway renders carry AWS-shaped values (GCP parity GP-14).

render-bundle.py substitutes a */gcp-0/* overlay with CLUSTER_FIXTURE_VARS["gcp-0"],
so these files show what gcp-0 will receive. A same-named variable holding an AWS
value -- ${region} inside oidc.eks.<region>.amazonaws.com, an EKS /keys JWKS --
renders schema-valid and fails only on the cluster (memory
flux_render_fixture_cross_cloud_blindspot). check-substitution.py catches a
MISSING key; this catches a wrong-shaped one, and a child that bypasses the
gcp-0 overlay so the render never sees gcp-0's values at all.

Scope is the agent platform and the AI gateway. Other gcp-0 overlays legitimately
name AWS (the Route53 federation) and are not judged here.
"""
import pathlib
import re
import sys

import yaml

SCOPED = re.compile(r"^overlay-(infrastructure|security|observability)-gcp-0-(agent-[a-z-]+|octo-sts|envoy-ai-gateway|envoy-gateway|vllm-semantic-router)\.yaml$")
# Only run tokens are judged by issuer: another gcp-0 policy may trust ZITADEL.
RUN_TOKEN = re.compile(r"-gcp-0-agent-(router|mcp)\.yaml$")
FORBIDDEN = [
    (re.compile(r"amazonaws\.com"), "an amazonaws.com host"),
    (re.compile(r"oidc\.eks\."), "an EKS issuer host"),
    # AWS Secrets Manager key shapes: GCP forbids `/` in names (GP-26), and the
    # gateway's keys are generated on gcp-0 (GP-24).
    (re.compile(r"key:\s*certificates/"), "an AWS-shaped CA secret key"),
    (re.compile(r"platform-llm-api-keys"), "the hand-made AWS gateway-keys entry"),
]
GKE_ISSUER = "https://container.googleapis.com/"
UMBRELLAS = ("clusters/gcp-0-agent-platform", "clusters/gcp-0-ai-gateway")


def _walk(node, key):
    if isinstance(node, dict):
        for k, v in node.items():
            if k == key:
                yield v
            yield from _walk(v, key)
    elif isinstance(node, list):
        for v in node:
            yield from _walk(v, key)


def check_bundle(bundle_dir):
    problems, seen = [], 0
    for f in sorted(pathlib.Path(bundle_dir).glob("overlay-*.yaml")):
        if not SCOPED.match(f.name):
            continue
        seen += 1
        text = f.read_text()
        for pattern, what in FORBIDDEN:
            if pattern.search(text):
                problems.append(f"{f.name}: {what} on gcp-0")
        if not RUN_TOKEN.search(f.name):
            continue
        for doc in yaml.safe_load_all(text):
            if not doc or doc.get("kind") not in ("SecurityPolicy", "MCPRoute"):
                continue
            for iss in _walk(doc, "issuer"):
                if isinstance(iss, str) and not iss.startswith(GKE_ISSUER):
                    problems.append(f"{f.name}: {doc['kind']} {doc['metadata']['name']} issuer {iss} is not GKE's")
            for uri in _walk(doc, "uri"):
                if isinstance(uri, str) and uri.startswith(GKE_ISSUER) and not uri.endswith("/jwks"):
                    problems.append(f"{f.name}: {doc['kind']} {doc['metadata']['name']} JWKS {uri} is not <issuer>/jwks")
    if seen == 0:
        problems.append("no gcp-0 agent or AI-gateway overlay in the bundle: the gate would be vacuous")
    return problems


def check_umbrellas(root):
    problems = []
    for d in UMBRELLAS:
        for f in sorted((pathlib.Path(root) / d).glob("*.yaml")):
            for doc in yaml.safe_load_all(f.read_text()):
                if not doc or doc.get("kind") != "Kustomization" or "toolkit.fluxcd.io" not in doc.get("apiVersion", ""):
                    continue
                subs = ((doc.get("spec") or {}).get("postBuild") or {}).get("substituteFrom") or []
                if any(s.get("name") == "gke-gcp-0-vars" for s in subs) and "/gcp-0/" not in doc["spec"].get("path", ""):
                    problems.append(f"{f.relative_to(root)}: substitutes gke-gcp-0-vars into {doc['spec']['path']}, "
                                    "which CI renders with AWS values; point it at a */gcp-0/* overlay")
    return problems


def main():
    bundle_dir = sys.argv[1] if len(sys.argv) > 1 else ".bundle"
    root = sys.argv[2] if len(sys.argv) > 2 else pathlib.Path(__file__).resolve().parents[3]
    problems = check_bundle(bundle_dir) + check_umbrellas(root)
    for p in problems:
        print(f"FAIL: {p}")
    scoped = sum(1 for f in pathlib.Path(bundle_dir).glob("overlay-*.yaml") if SCOPED.match(f.name))
    children = sum(1 for d in UMBRELLAS for f in (pathlib.Path(root) / d).glob("*.yaml") if f.name != "kustomization.yaml")
    print(f"==> cloud shape: {scoped} gcp-0 overlay(s), {children} umbrella child(ren), {len(problems)} problem(s)")
    sys.exit(1 if problems else 0)


if __name__ == "__main__":
    main()
