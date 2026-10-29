#!/usr/bin/env python3
# requires: python3
"""A "Storage" Grafana dashboard under observability/, provisioned like every
other dashboard in the repo: a GrafanaDashboard CR whose `spec.json` block is
valid JSON (not a YAML string -- the inline block is the repo's convention, so
a dashboard that silently drifted to a string would stop being provisioned as
JSON the operator expects), with the instanceSelector every other dashboard
carries and a folderRef that names an existing GrafanaFolder.

The panels are pinned by query, not by title: the task asks for a table of
claims not Bound from kube_persistentvolumeclaim_status_phase, and requested
capacity by storage class from
kube_persistentvolumeclaim_resource_requests_storage_bytes. A dashboard that
only mentions the metric in a description proves nothing.
"""
import json
import pathlib
import re
import sys

import yaml

ROOT = pathlib.Path(__file__).resolve().parents[3]
STATUS_PHASE = "kube_persistentvolumeclaim_status_phase"
REQUESTS_STORAGE = "kube_persistentvolumeclaim_resource_requests_storage_bytes"

# Skip exactly what the repo's other whole-repo walkers skip (see
# test-helmrelease-values-watched.py): build outputs and vendored trees that
# are not dashboards we author.
SKIP = {".git", ".bundle", "node_modules", "docs", ".claude", ".agents"}


def dashboards():
    for path in (ROOT / "observability").rglob("*.yaml"):
        if any(part in SKIP for part in path.parts):
            continue
        try:
            docs = list(yaml.safe_load_all(path.read_text()))
        except yaml.YAMLError:
            continue
        for doc in docs:
            if isinstance(doc, dict) and doc.get("kind") == "GrafanaDashboard":
                yield path, doc


def main() -> int:
    fails = 0

    def check(desc: str, ok: bool) -> None:
        nonlocal fails
        print(f"  {'ok  ' if ok else 'FAIL'} {desc}")
        if not ok:
            fails += 1

    found = [(path, doc) for path, doc in dashboards()
             if (doc.get("spec", {}).get("json") is not None
                 and re.search(r"storage", json.loads(doc["spec"]["json"]).get("title", ""), re.I))]
    check(f"exactly one 'Storage' dashboard under observability/ (found {len(found)})",
          len(found) == 1)

    if len(found) != 1:
        return fails

    path, doc = found[0]
    spec = doc.get("spec", {})
    check(f"its spec.json is valid JSON ({path.relative_to(ROOT)})", True)  # parsed above
    dash = json.loads(spec["json"])

    selector = spec.get("instanceSelector")
    check("it selects the same Grafana instance as every other dashboard "
          "(instanceSelector.matchLabels dashboards: grafana)",
          selector == {"matchLabels": {"dashboards": "grafana"}})

    folder = spec.get("folderRef")
    # Provisioned like the other dashboards also means listed in the directory's
    # kustomization: an unlisted GrafanaDashboard is never rendered.
    kustomization = path.parent / "kustomization.yaml"
    listed = False
    if kustomization.is_file():
        try:
            kdoc = yaml.safe_load(kustomization.read_text())
            listed = path.name in (kdoc or {}).get("resources", [])
        except yaml.YAMLError:
            pass
    check(f"it is listed in {kustomization.relative_to(ROOT)} resources", listed)

    folders = (ROOT / "observability").rglob("folders/*.yaml")
    folder_names = set()
    for fpath in folders:
        try:
            fdoc = yaml.safe_load(fpath.read_text())
        except yaml.YAMLError:
            continue
        if isinstance(fdoc, dict) and fdoc.get("kind") == "GrafanaFolder":
            folder_names.add(fdoc["metadata"]["name"])
    check(f"its folderRef '{folder}' names an existing GrafanaFolder", folder in folder_names)

    panels = [p for p in dash.get("panels", []) if isinstance(p, dict)]
    targets = [t for p in panels for t in p.get("targets", []) if isinstance(t, dict)]
    exprs = [t.get("expr") or "" for t in targets]

    def panel_for(metric: str):
        for p in panels:
            if any(metric in (t.get("expr") or "") for t in p.get("targets", [])):
                return p
        return None

    phase_panel = panel_for(STATUS_PHASE)
    check(f"a panel queries {STATUS_PHASE}", phase_panel is not None)
    if phase_panel is not None:
        phase_expr = next(e for e in exprs if STATUS_PHASE in e)
        check("the claims panel filters to the not-Bound phase "
              "(phase!=\"Bound\" or equivalent)",
              bool(re.search(r'phase\s*(?:!=|=~)\s*"?[^"]*Bound', phase_expr)))
        check("the claims panel is a table", phase_panel.get("type") == "table")

    cap_panel = panel_for(REQUESTS_STORAGE)
    check(f"a panel queries {REQUESTS_STORAGE}", cap_panel is not None)
    if cap_panel is not None:
        cap_expr = next(e for e in exprs if REQUESTS_STORAGE in e)
        check("the capacity query is grouped by storage class "
              "(a 'by' clause with storageclass)",
              bool(re.search(r"\bby\s*\([^)]*storageclass", cap_expr, re.I)))

    # The repo's dashboards go through Flux postBuild substitution: a raw
    # ${var} in the JSON is substituted (or rejected) at apply time, while
    # $$ is what survives into Grafana. Any variable the dashboard itself
    # defines is free to use single dollars.
    templating = [v.get("name", "") for v in dash.get("templating", {}).get("list", [])]
    raw = spec["json"]
    stray = re.findall(r"(?<!\$)\$\{?[a-zA-Z_][a-zA-Z0-9_]*\}?", raw)
    stray = [s for s in stray if s.strip("${}") not in templating]
    check("no un-escaped ${var} outside the dashboard's own variable names "
          f"(found {stray})", not stray)

    return fails


if __name__ == "__main__":
    rc = main()
    print("all checks passed" if rc == 0 else "FAILURES above")
    sys.exit(rc)
