#!/usr/bin/env python3
# requires: python3
"""Every ConfigMap a HelmRelease reads through `valuesFrom` carries
`reconcile.fluxcd.io/watch: Enabled`, and so does every Secret an ExternalSecret
renders for one (through `spec.target.template.metadata.labels`).

Without the label, helm-controller sees a values change only on the release's
next `interval`. agent-factory's chart (flux/sources) and its image tag (the
values ConfigMap, in tooling) arrive through different Kustomizations, so the
release upgraded to the new chart with the old tag and stayed there for 30m
(#2276). With it, helm-controller re-reconciles the moment the ConfigMap
changes, whichever lands first.

A Secret is the same failure with a credential in it: after an OIDC rotation
the Flux UI kept the dead client secret, because helm-controller never
re-rendered flux-operator-web-config (2026-10-17). A Secret no ExternalSecret
in the repo renders is not checked.
"""
import pathlib
import sys

import yaml

ROOT = pathlib.Path(__file__).resolve().parents[3]
SKIP = {".git", ".bundle", "node_modules", "website", "docs", ".claude", ".agents"}
LABEL = "reconcile.fluxcd.io/watch"


def docs():
    for path in ROOT.rglob("*.yaml"):
        if SKIP.intersection(path.relative_to(ROOT).parts):
            continue
        try:
            for doc in yaml.safe_load_all(path.read_text()):
                if isinstance(doc, dict):
                    yield path, doc
        except yaml.YAMLError:
            continue


refs = {}        # ConfigMap name -> [(HelmRelease file, optional)]
configmaps = {}  # ConfigMap name -> [(file, labels)]
secret_refs = set()
rendered = {}    # Secret name -> [(ExternalSecret file, its template's labels)]
for path, doc in docs():
    kind, meta = doc.get("kind"), doc.get("metadata") or {}
    if kind == "HelmRelease":
        for ref in (doc.get("spec") or {}).get("valuesFrom") or []:
            if ref.get("kind") == "ConfigMap":
                refs.setdefault(ref["name"], []).append((path, bool(ref.get("optional"))))
            elif ref.get("kind") == "Secret":
                secret_refs.add(ref["name"])
    elif kind == "ConfigMap" and meta.get("name"):
        configmaps.setdefault(meta["name"], []).append((path, meta.get("labels") or {}))
    elif kind == "ExternalSecret" and meta.get("name"):
        target = (doc.get("spec") or {}).get("target") or {}
        labels = ((target.get("template") or {}).get("metadata") or {}).get("labels") or {}
        rendered.setdefault(target.get("name") or meta["name"], []).append((path, labels))

problems = []
if not refs:
    problems.append("no HelmRelease valuesFrom ConfigMap found: the scan is broken")
for name, users in sorted(refs.items()):
    defs = configmaps.get(name)
    if not defs:
        if not all(optional for _, optional in users):
            problems.append(f"ConfigMap {name} (valuesFrom of {users[0][0].relative_to(ROOT)}) is defined nowhere in the repo")
        continue
    for path, labels in defs:
        if labels.get(LABEL) != "Enabled":
            problems.append(f"{path.relative_to(ROOT)}: ConfigMap {name} lacks {LABEL}: Enabled")

for name in sorted(secret_refs):
    for path, labels in rendered.get(name, []):
        if labels.get(LABEL) != "Enabled":
            problems.append(f"{path.relative_to(ROOT)}: ExternalSecret rendering {name} lacks {LABEL}: Enabled in spec.target.template.metadata.labels")

if problems:
    print("\n".join(problems))
    sys.exit(1)
watched = sum(len(rendered.get(n, [])) for n in secret_refs)
print(f"{len(refs)} valuesFrom ConfigMap(s) and {watched} ExternalSecret-rendered Secret(s), all watched")
