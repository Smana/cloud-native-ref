#!/usr/bin/env python3
"""Diff two rendered bundles (base vs PR head) into a PR-friendly markdown report.

GitOps: git is the source of truth, so the useful PR signal is what a change does
to the DESIRED state — rendered (`kustomize build` + `helm template`) so it is
meaningful — not a diff against a possibly-drifted live cluster (drift is Flux's
job and is alerted on separately). This is what flux-local/flate/konflate do, and
it needs no cluster access. Because render-bundle.py expands every HelmRelease
(chart and chartRef) into its workloads, this diff covers Helm-rendered resources
too — the thing `flux diff` cannot do.

Reads two bundle dirs produced by render-bundle.py, groups every document by its
Kubernetes identity, redacts Secret payloads, canonicalizes (sorted keys), and
prints a unified diff + summary as GitHub-flavored markdown on stdout.

Usage: diff-bundles.py <base-bundle-dir> <head-bundle-dir>
"""
import difflib
import os
import pathlib
import sys

import yaml

# Same PyYAML workaround render-bundle.py registers: a bare `=` scalar (the
# prometheus-operator-crds AlertmanagerConfig matchType enum `!=`,`=`,`=~`,`!~`)
# is the reserved tag:yaml.org,2002:value, which SafeLoader refuses to construct.
# Without this, safe_load_all raises and load_bundle() would silently drop the
# whole document from the diff. Keep in lockstep with render-bundle.py.
yaml.SafeLoader.add_constructor(
    "tag:yaml.org,2002:value", lambda loader, node: loader.construct_scalar(node)
)

REDACTED = "<redacted by diff-bundles>"
MAX_TOTAL = int(os.environ.get("DIFF_MAX_CHARS", "58000"))  # GitHub comment cap is 65536
MARKERS = {"added": "🟢 added", "removed": "🔴 removed", "changed": "🟡 changed"}


def load_bundle(directory):
    """Every rendered document keyed by apiVersion/kind/namespace/name."""
    resources = {}
    base = pathlib.Path(directory)
    if not base.is_dir():
        return resources
    for path in sorted(base.rglob("*.yaml")):
        try:
            docs = list(yaml.safe_load_all(path.read_text()))
        except (yaml.YAMLError, OSError):
            continue
        for doc in docs:
            if not isinstance(doc, dict) or not doc.get("kind"):
                continue
            meta = doc.get("metadata") or {}
            key = "{}/{}/{}/{}".format(
                doc.get("apiVersion", "?"), doc["kind"],
                meta.get("namespace", "-"), meta.get("name", "?"),
            )
            resources[key] = doc
    return resources


def canonical(doc):
    """Stable, secret-safe YAML for diffing: sorted keys, redacted Secret data."""
    doc = dict(doc)
    if doc.get("kind") == "Secret":
        for field in ("data", "stringData"):
            if isinstance(doc.get(field), dict):
                doc[field] = {k: REDACTED for k in doc[field]}
    return yaml.safe_dump(doc, sort_keys=True, default_flow_style=False, width=10 ** 6)


def main():
    if len(sys.argv) != 3:
        print("usage: diff-bundles.py <base-bundle-dir> <head-bundle-dir>", file=sys.stderr)
        return 2
    base, head = load_bundle(sys.argv[1]), load_bundle(sys.argv[2])

    chunks, counts = [], {"added": 0, "removed": 0, "changed": 0}
    for key in sorted(set(base) | set(head)):
        in_base, in_head = key in base, key in head
        before = canonical(base[key]) if in_base else ""
        after = canonical(head[key]) if in_head else ""
        if before == after:
            continue
        tag = "changed" if in_base and in_head else "added" if not in_base else "removed"
        counts[tag] += 1
        diff = "".join(difflib.unified_diff(
            before.splitlines(keepends=True), after.splitlines(keepends=True),
            fromfile=f"a/{key}", tofile=f"b/{key}",
        ))
        chunks.append((key, tag, diff))

    lines = ["### 🔍 Rendered manifest diff — this PR vs `main` (desired state)", ""]
    if not chunks:
        lines.append("No changes to the rendered desired state. ✅")
        sys.stdout.write("\n".join(lines) + "\n")
        return 0
    lines += [
        f"**{counts['changed']} changed · {counts['added']} added · {counts['removed']} removed**",
        "",
        "> Rendered with `kustomize build` + `helm template` (source of truth = git), "
        "so Helm-expanded workloads are included. Shows what Flux will apply — not a diff "
        "against live cluster state (drift is alerted on separately), and not "
        "CRD-defaulted / webhook-mutated output. Secret values are redacted.",
        "",
    ]
    body = "\n".join(lines) + "\n"

    truncated = False
    for key, tag, diff in chunks:
        section = (
            f"<details><summary>{MARKERS[tag]} — <code>{key}</code></summary>\n\n"
            f"```diff\n{diff}```\n</details>\n\n"
        )
        if len(body) + len(section) > MAX_TOTAL:
            truncated = True
            break
        body += section
    if truncated:
        body += "\n> ⚠️ Diff truncated to fit the comment size limit — see the workflow artifact for the full diff.\n"

    sys.stdout.write(body)
    return 0


if __name__ == "__main__":
    sys.exit(main())
