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

Usage: diff-bundles.py <base-bundle-dir> <head-bundle-dir> [full-report-path]
(stdout is capped for the PR comment; the optional path gets the full report)
"""
import difflib
import os
import pathlib
import re
import sys

import yaml

from yamlcompat import YAML_DUMPER, YAML_LOADER

REDACTED = "<redacted by diff-bundles>"
MAX_TOTAL = int(os.environ.get("DIFF_MAX_CHARS", "58000"))  # GitHub comment cap is 65536
MARKERS = {"added": "🟢 added", "removed": "🔴 removed", "changed": "🟡 changed"}

# `helm template` regenerates some values on every render, so they differ
# between the base and head renders even when nothing changed — pure noise
# that crowds real changes out of the size-capped PR comment. Measured on a
# real bundle pair, all three classes below appeared and the single genuine
# change did not fit in the comment:
#   * webhook clientConfig.caBundle (genSignedCert: aws-load-balancer-
#     controller, victoria-metrics-operator admission webhooks)
#   * checksum/* pod annotations over per-render-random Secrets (harbor,
#     grafana)
#   * a render timestamp embedded in a resource NAME (oncall's migrate Job),
#     which otherwise shows as an added+removed pair of full manifests
# Trade-off: a genuine change to a static caBundle/checksum, or a change
# only distinguishable by such a timestamp, is masked — acceptable for an
# informational diff, same deal as Secret redaction.
TIMESTAMP_RE = re.compile(r"\d{4}-\d{2}-\d{2}-\d{2}-\d{2}-\d{2}")


def scrub(node):
    """Blank the per-render nondeterministic fields listed above."""
    if isinstance(node, dict):
        out = {}
        for key, value in node.items():
            if key == "caBundle" and isinstance(value, str):
                out[key] = REDACTED
            elif key == "annotations" and isinstance(value, dict):
                out[key] = {
                    k: (REDACTED if k.startswith("checksum/") else v) for k, v in value.items()
                }
            else:
                out[key] = scrub(value)
        return out
    if isinstance(node, list):
        return [scrub(item) for item in node]
    return node


def load_bundle(directory):
    """Every rendered document keyed by apiVersion/kind/namespace/name."""
    resources = {}
    base = pathlib.Path(directory)
    if not base.is_dir():
        return resources
    for path in sorted(base.rglob("*.yaml")):
        try:
            docs = list(yaml.load_all(path.read_text(), Loader=YAML_LOADER))
        except (yaml.YAMLError, OSError):
            continue
        for doc in docs:
            if not isinstance(doc, dict) or not doc.get("kind"):
                continue
            meta = doc.get("metadata") or {}
            # Timestamped names (oncall's migrate Job) are normalized in the
            # grouping key too, so the two sides line up as one "changed"
            # candidate instead of an added+removed pair of full manifests.
            key = TIMESTAMP_RE.sub("<render-timestamp>", "{}/{}/{}/{}".format(
                doc.get("apiVersion", "?"), doc["kind"],
                meta.get("namespace", "-"), meta.get("name", "?"),
            ))
            resources[key] = doc
    return resources


def canonical(doc):
    """Stable, secret-safe, noise-free YAML for diffing: sorted keys, redacted
    Secret data, per-render nondeterminism scrubbed (see TIMESTAMP_RE above)."""
    doc = scrub(doc)
    if doc.get("kind") == "Secret":
        for field in ("data", "stringData"):
            if isinstance(doc.get(field), dict):
                doc[field] = {k: REDACTED for k in doc[field]}
    text = yaml.dump(doc, Dumper=YAML_DUMPER, sort_keys=True, default_flow_style=False, width=10 ** 6)
    return TIMESTAMP_RE.sub("<render-timestamp>", text)


def _truncation_note():
    """Point at the full diff. In CI, a clickable link to the workflow run
    page, where the full diff is readable as the job summary and downloadable
    as the `rendered-diff` artifact; plain text outside CI."""
    repo, run_id = os.environ.get("GITHUB_REPOSITORY"), os.environ.get("GITHUB_RUN_ID")
    if repo and run_id:
        server = os.environ.get("GITHUB_SERVER_URL", "https://github.com")
        return (
            "\n> ⚠️ Diff truncated to fit the comment size limit — "
            f"[full human-readable diff]({server}/{repo}/actions/runs/{run_id}) "
            "(job summary on the run page; also downloadable as the `rendered-diff` artifact).\n"
        )
    return "\n> ⚠️ Diff truncated to fit the comment size limit — see the workflow artifact for the full diff.\n"


def render_report(chunks, counts, cap=None):
    """Assemble the markdown report; `cap` bounds the total size (the PR
    comment), None renders everything (the artifact / job summary)."""
    lines = ["### 🔍 Rendered manifest diff — this PR vs `main` (desired state)", ""]
    if not chunks:
        lines.append("No changes to the rendered desired state. ✅")
        return "\n".join(lines) + "\n"
    lines += [
        f"**{counts['changed']} changed · {counts['added']} added · {counts['removed']} removed**",
        "",
        "> Rendered with `kustomize build` + `helm template` (source of truth = git), "
        "so Helm-expanded workloads are included. Shows what Flux will apply — not a diff "
        "against live cluster state (drift is alerted on separately), and not "
        "CRD-defaulted / webhook-mutated output. Secret values are redacted; "
        "per-render noise (webhook `caBundle`s, `checksum/*` annotations, render "
        "timestamps) is normalized out.",
        "",
    ]
    body = "\n".join(lines) + "\n"

    truncated = False
    for key, tag, diff in chunks:
        section = (
            f"<details><summary>{MARKERS[tag]} — <code>{key}</code></summary>\n\n"
            f"```diff\n{diff}```\n</details>\n\n"
        )
        if cap is not None and len(body) + len(section) > cap:
            truncated = True
            break
        body += section
    if truncated:
        body += _truncation_note()
    return body


def main():
    if len(sys.argv) not in (3, 4):
        print(
            "usage: diff-bundles.py <base-bundle-dir> <head-bundle-dir> [full-report-path]",
            file=sys.stderr,
        )
        return 2
    base, head = load_bundle(sys.argv[1]), load_bundle(sys.argv[2])

    chunks, counts = [], {"added": 0, "removed": 0, "changed": 0}
    for key in sorted(set(base) | set(head)):
        in_base, in_head = key in base, key in head
        # Fast path: equal parsed docs can't produce a diff (canonical() is a
        # pure function of the doc), and in a typical PR ~99% of resources are
        # unchanged - canonicalizing all of them dominated this script's runtime.
        # repr() rather than == because Python's == conflates True/1/1.0 across
        # types, which would silently skip a genuine `true` -> `1` manifest
        # change; repr is type-faithful for YAML-representable data and stays
        # C-speed. Docs differing only in redacted/scrubbed values fall through
        # to the canonical comparison below, which still treats them as unchanged.
        if in_base and in_head and repr(base[key]) == repr(head[key]):
            continue
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

    # stdout is the size-capped PR comment; the optional third argument gets
    # the untruncated report (previously the artifact was a tee of the capped
    # stdout, so "see the artifact for the full diff" pointed at the same
    # truncated content).
    sys.stdout.write(render_report(chunks, counts, cap=MAX_TOTAL))
    if len(sys.argv) == 4:
        pathlib.Path(sys.argv[3]).write_text(render_report(chunks, counts))
    return 0


if __name__ == "__main__":
    sys.exit(main())
