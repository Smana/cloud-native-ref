#!/usr/bin/env python3
"""Fail on a reference across the host/AI boundary that the host contract does not list.

ADR-0057 moves the AI platform to its own repository. A host path that names an AI path
breaks the default deploy the day the AI paths leave; an AI path that names a host object
outside the contract (design §2) breaks at reconcile in the new repository, where no
render can see it. ai-boundary.yaml holds the AI paths (design §1) and the contract.

Reads the source tree, not the bundle: every reference checked here is a path or a name
that rendering resolves away. Both directions:
  * kustomize file references (resources, components, bases, patches, generators)
  * Flux Kustomization spec.path, dependsOn, sourceRef, postBuild.substituteFrom
  * HelmRelease chart sourceRef, chartRef and valuesFrom
  * ${var} in AI files, against H3's keys
A reference to a name defined on both sides, or on neither, is not a crossing.
"""
import os
import pathlib
import re
import sys

import yaml

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from yamlcompat import YAML_LOADER  # noqa: E402

AREAS = ["clusters", "infrastructure", "security", "observability", "tooling", "apps", "flux", "namespaces", "crds"]
FLUX_KS = "kustomize.toolkit.fluxcd.io/"
SOURCE_KINDS = ("GitRepository", "OCIRepository", "HelmRepository", "Bucket")
VAR_RE = re.compile(r"(?<!\$)\$\{([a-zA-Z_][a-zA-Z0-9_]*)\}")
VARS_CM = re.compile(r"^(eks|gke)-[a-z0-9-]+-vars$")


def load_docs(path):
    try:
        return [d for d in yaml.load_all(path.read_text(), Loader=YAML_LOADER) if isinstance(d, dict)]
    except yaml.YAMLError:
        return []


class Boundary:
    def __init__(self, root, contract):
        self.root, self.c = pathlib.Path(root), contract
        self.ai_res = [re.compile(p) for p in contract["ai_paths"]]
        self.errors = []
        self.files = [
            (p.relative_to(self.root).as_posix(), load_docs(p))
            for area in AREAS if (self.root / area).is_dir()
            for p in sorted((self.root / area).rglob("*.yaml"))
        ]

    def side(self, rel, is_dir=False):
        rel = rel.rstrip("/") + ("/" if is_dir else "")
        return "ai" if any(r.search(rel) for r in self.ai_res) else "host"

    def fail(self, rel, msg):
        self.errors.append(f"{rel}: {msg}")

    def index(self):
        self.ks, self.sources, self.objects = {}, {}, {}
        for rel, docs in self.files:
            s = self.side(rel)
            for d in docs:
                kind, name = d.get("kind"), (d.get("metadata") or {}).get("name")
                spec = d.get("spec") or {}
                if not name:
                    continue
                if kind == "Kustomization" and str(d.get("apiVersion", "")).startswith(FLUX_KS):
                    self.ks.setdefault(name, set()).add(s)
                elif kind in SOURCE_KINDS:
                    self.sources.setdefault(f"{kind}/{name}", set()).add(s)
                elif kind == "ArtifactGenerator":
                    for a in spec.get("artifacts") or []:
                        self.sources.setdefault(f"ExternalArtifact/{a.get('name')}", set()).add(s)
                elif kind in ("ConfigMap", "Secret"):
                    self.objects.setdefault(f"{kind}/{name}", set()).add(s)
                elif kind == "ExternalSecret":
                    target = (spec.get("target") or {}).get("name") or name
                    self.objects.setdefault(f"Secret/{target}", set()).add(s)

    def check_kustomize_files(self, rel, doc):
        here = rel.rsplit("/", 1)[0]
        entries = [(f, e) for f in ("resources", "components", "bases", "patchesStrategicMerge")
                   for e in doc.get(f) or [] if isinstance(e, str)]
        entries += [("patches", p["path"]) for p in doc.get("patches") or [] if isinstance(p, dict) and p.get("path")]
        for gen in ("configMapGenerator", "secretGenerator"):
            for g in doc.get(gen) or []:
                for f in (g.get("files") or []) + (g.get("envs") or []) + ([g["env"]] if g.get("env") else []):
                    entries.append((gen, f.split("=", 1)[-1]))
        for field, entry in entries:
            if "://" in entry or entry.startswith("github.com/"):
                continue
            target = os.path.normpath(os.path.join(here, entry))
            to = self.side(target, (self.root / target).is_dir())
            if to != self.side(rel):
                self.fail(rel, f"{field} entry {entry} crosses {self.side(rel)} -> {to} ({target})")

    def check_source(self, rel, owner, ref):
        if not ref or not ref.get("name"):
            return
        key, s = f"{ref.get('kind')}/{ref['name']}", self.side(rel)
        sides = self.sources.get(key, set())
        if s == "host" and sides == {"ai"}:
            self.fail(rel, f"{owner} uses the AI source {key}")
        if s == "ai" and sides == {"host"} and key not in self.c["host_sources"]:
            self.fail(rel, f"{owner} uses the host source {key}, outside the contract (H1)")

    def check_flux_kustomization(self, rel, doc):
        name, spec, s = doc["metadata"]["name"], doc.get("spec") or {}, self.side(rel)
        owner = f"Kustomization/{name}"
        path = (spec.get("path") or "").removeprefix("./").rstrip("/")
        if path:
            to = self.side(path, True)
            umbrella = re.fullmatch(r"clusters/([^/]+)/([^/]+)\.yaml", rel)
            is_umbrella = (bool(umbrella) and name in self.c["umbrellas"] and umbrella.group(2) == name
                           and path == f"clusters/{umbrella.group(1)}-{name}")
            if s == "host" and to == "ai" and not is_umbrella:
                self.fail(rel, f"{owner} applies the AI path {path}")
            if s == "ai" and to == "host":
                self.fail(rel, f"{owner} applies the host path {path}")
        for dep in spec.get("dependsOn") or []:
            sides = self.ks.get(dep.get("name"), set())
            if s == "host" and sides == {"ai"}:
                self.fail(rel, f"{owner} depends on the AI Kustomization {dep['name']}")
            if s == "ai" and sides == {"host"} and dep["name"] not in self.c["host_kustomizations"]:
                self.fail(rel, f"{owner} depends on the host Kustomization {dep['name']}, outside the contract (H2)")
        self.check_source(rel, owner, spec.get("sourceRef"))
        if s == "ai":
            for ref in (spec.get("postBuild") or {}).get("substituteFrom") or []:
                if not (ref.get("kind") == "ConfigMap" and VARS_CM.match(ref.get("name", ""))):
                    self.fail(rel, f"{owner} substitutes from {ref.get('kind')}/{ref.get('name')}, outside the contract (H3)")

    def check_helmrelease(self, rel, doc):
        spec, s = doc.get("spec") or {}, self.side(rel)
        owner = f"HelmRelease/{(doc.get('metadata') or {}).get('name')}"
        self.check_source(rel, owner, ((spec.get("chart") or {}).get("spec") or {}).get("sourceRef"))
        self.check_source(rel, owner, spec.get("chartRef"))
        for ref in spec.get("valuesFrom") or []:
            key = f"{ref.get('kind')}/{ref.get('name')}"
            sides = self.objects.get(key, set())
            if s == "host" and sides == {"ai"}:
                if key not in self.c["ai_objects_host_reads"]:
                    self.fail(rel, f"{owner} reads {key}, which an AI path defines (H8 lists the only one allowed)")
                elif not ref.get("optional"):
                    self.fail(rel, f"{owner} reads {key} (H8) without optional: true; the host must deploy without the AI paths")
            if s == "ai" and sides == {"host"}:
                self.fail(rel, f"{owner} reads {key}, which a host path defines")

    def check_vars(self, rel):
        for var in sorted(set(VAR_RE.findall((self.root / rel).read_text())) - set(self.c["substitution_keys"])):
            self.fail(rel, f"${{{var}}} is not an H3 substitution key")

    def run(self):
        # A move-list entry that matches nothing is a typo or a path that moved: either way the
        # boundary it draws is not the one the design names.
        for pattern in self.ai_res:
            if not any(pattern.search(rel) for rel, _ in self.files):
                self.fail("ai-boundary.yaml", f"ai_paths entry {pattern.pattern} matches no file")
        self.index()
        for rel, docs in self.files:
            for d in docs:
                kind, api = d.get("kind"), str(d.get("apiVersion", ""))
                if kind == "Kustomization" and api.startswith(FLUX_KS):
                    self.check_flux_kustomization(rel, d)
                elif kind == "Kustomization" and rel.endswith("/kustomization.yaml"):
                    self.check_kustomize_files(rel, d)
                elif kind == "HelmRelease":
                    self.check_helmrelease(rel, d)
            if self.side(rel) == "ai":
                self.check_vars(rel)
        return self.errors


def main():
    here = pathlib.Path(__file__).resolve().parent
    root = pathlib.Path(os.environ.get("REPO_ROOT", here.parents[2]))
    contract = yaml.safe_load((here / "ai-boundary.yaml").read_text())
    b = Boundary(root, contract)
    errors = b.run()
    for e in errors:
        print(f"FAIL: {e}", file=sys.stderr)
    ai = sum(1 for rel, _ in b.files if b.side(rel) == "ai")
    print(f"AI BOUNDARY: files={len(b.files)} ai={ai} crossings={len(errors)}")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
