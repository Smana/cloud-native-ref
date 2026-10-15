#!/usr/bin/env python3
"""Gate the rendered bundle on the ZITADEL version floor ADR-0056 depends on.

Room access reads a user's GitHub identity from ZITADEL. Before v4.17.3 /
v4.18.0, a user could add an unverified IdP link to their own account through
the API and so forge that identity. Every ghcr.io/zitadel/zitadel container in
the bundle must therefore run a release >= v4.17.3 and not a pre-release: the
v4.18 pre-release line predates the fix.

Reads the rendered image, not the HelmRelease values, so it holds whether the
tag comes from the `image.tag` override or from the chart's appVersion. A tag
it cannot parse fails rather than passes, and so does a bundle with no ZITADEL
container at all -- zero is a layout regression, not compliance.

Usage: assert-zitadel-floor.py [BUNDLE_DIR]    (default .bundle)
Exit:  0 clean, 1 violations (each printed), 2 bundle missing.
"""
import pathlib
import re
import sys

import yaml

from yamlcompat import YAML_LOADER

REPOSITORY = "ghcr.io/zitadel/zitadel"
FLOOR = (4, 17, 3)
SEMVER = re.compile(r"^v?(\d+)\.(\d+)\.(\d+)(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$")


def ref(obj):
    meta = obj.get("metadata") or {}
    return f"{obj.get('kind')} {meta.get('namespace', '')}/{meta.get('name', '')}"


def pod_spec(obj):
    spec = obj.get("spec") or {}
    if obj.get("kind") == "Pod":
        return spec
    if obj.get("kind") == "CronJob":
        spec = (spec.get("jobTemplate") or {}).get("spec") or {}
    return (spec.get("template") or {}).get("spec") or {}


def split_image(image):
    """`repo[:tag][@digest]` -> (repo, tag or None)."""
    name = image.split("@", 1)[0]
    head, sep, tail = name.rpartition(":")
    if sep and "/" not in tail:
        return head, tail
    return name, None


def check_tag(where, tag):
    if tag is None:
        return f"{where}: no tag, so the version cannot be checked against v4.17.3"
    m = SEMVER.match(tag)
    if not m:
        return f"{where}: tag {tag!r} is not a semver release, so it cannot be checked against v4.17.3"
    if m.group(4):
        return f"{where}: {tag} is a pre-release; the IdP-link fix ships from v4.17.3 / v4.18.0 final"
    if tuple(int(g) for g in m.groups()[:3]) < FLOOR:
        return f"{where}: {tag} is below v4.17.3, which lets a user forge their GitHub identity (ADR-0056)"
    return None


def check(objs):
    errors, seen = [], 0
    for obj in objs:
        spec = pod_spec(obj)
        for container in (spec.get("initContainers") or []) + (spec.get("containers") or []):
            repo, tag = split_image(str(container.get("image") or ""))
            if repo != REPOSITORY:
                continue
            seen += 1
            error = check_tag(f"{ref(obj)} container {container.get('name')}", tag)
            if error:
                errors.append(error)
    if not seen:
        errors.append(f"no {REPOSITORY} container in the bundle; the ZITADEL render moved or vanished")
    return errors


def load_objects(bundle_dir):
    objs = []
    for path in sorted(pathlib.Path(bundle_dir).glob("*.yaml")):
        for doc in yaml.load_all(path.read_text(), Loader=YAML_LOADER):
            if isinstance(doc, dict) and doc.get("kind"):
                objs.append(doc)
    return objs


def main(argv):
    bundle = pathlib.Path(argv[0] if argv else ".bundle")
    if not bundle.is_dir():
        print(f"error: bundle directory {bundle} not found; run render-bundle.py first", file=sys.stderr)
        return 2
    # The chart renders once per cluster; report a defect once.
    errors = list(dict.fromkeys(check(load_objects(bundle))))
    for error in errors:
        print(f"FAIL {error}", file=sys.stderr)
    print(f"zitadel version floor: {len(errors)} violations")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
