#!/usr/bin/env python3
# requires: python3
"""The agent factory's chart and image pins move together, and both by digest.

The chart's appVersion names the image it was built with, so the values' image
tag must be that version (chart `<ver>-pr<N>.g<sha>` ships image
`v<ver>-pr<N>.<sha>`; a release `<ver>` ships `v<ver>`). A tag alone is not a
pin: any same-repo agent-platform PR's CI can re-push it with a valid signature,
so the OCIRepository carries `ref.digest`, which Flux resolves before the tag.
Renovate groups the two (.github/renovate.json); this is what fails when one is
bumped without the other.
"""
import json
import pathlib
import re
import sys

import yaml

ROOT = pathlib.Path(__file__).resolve().parents[3]
DIGEST = re.compile(r"^sha256:[a-f0-9]{64}$")
problems = []

source = yaml.safe_load((ROOT / "flux/sources/ocirepo-agent-factory.yaml").read_text())
ref = source["spec"]["ref"]
chart_tag = ref.get("tag", "")
if not DIGEST.match(ref.get("digest", "")):
    problems.append(f"OCIRepository agent-factory ref.digest {ref.get('digest')!r} is not sha256:<64 hex>")

cm = yaml.safe_load((ROOT / "tooling/base/agent-factory/helm-values-configmap.yaml").read_text())
image = yaml.safe_load(cm["data"]["values.yaml"])["image"]
version, _, digest = image["tag"].partition("@")
if not DIGEST.match(digest):
    problems.append(f"image tag {image['tag']!r} is not <version>@sha256:<64 hex>")

expected = "v" + re.sub(r"\.g([0-9a-f]+)$", r".\1", chart_tag)
if version != expected:
    problems.append(f"image {version!r} is not chart {chart_tag!r}'s appVersion {expected!r}: bump both")

rules = json.loads((ROOT / ".github/renovate.json").read_text())["packageRules"]
names = {"ghcr.io/smana/charts/agent-factory", "ghcr.io/smana/agent-factory"}
if not any(names <= set(r.get("matchPackageNames") or []) and r.get("groupName") for r in rules):
    problems.append("no Renovate packageRule groups the factory's chart and image")

for p in problems:
    print(f"FAIL: {p}")
print(f"==> agent-factory pins: chart {chart_tag}, image {version}, {len(problems)} problem(s)")
sys.exit(1 if problems else 0)
