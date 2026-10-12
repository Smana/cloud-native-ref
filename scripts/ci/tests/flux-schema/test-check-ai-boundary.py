#!/usr/bin/env python3
"""Tests for check-ai-boundary.py (AI platform split, S1).

Each case plants one crossing in a copy of this repository's manifest tree, so the
check is proven against the real layout, not a toy one: the copy must pass, and each
plant must fail with a message naming the crossing.

Run: python3 scripts/ci/tests/flux-schema/test-check-ai-boundary.py
"""
import importlib.util
import os
import pathlib
import shutil
import sys
import tempfile

import yaml

HERE = pathlib.Path(__file__).resolve().parent
SUBJECT_DIR = HERE.parent.parent / "flux-schema"
REPO = pathlib.Path(os.environ.get("REPO_ROOT", HERE.parents[3]))
spec = importlib.util.spec_from_file_location("check_ai_boundary", SUBJECT_DIR / "check-ai-boundary.py")
cab = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cab)
CONTRACT = yaml.safe_load((SUBJECT_DIR / "ai-boundary.yaml").read_text())

FAILURES = []


def check(cond, msg):
    print(("ok   " if cond else "FAIL ") + msg)
    if not cond:
        FAILURES.append(msg)


def copy_tree(dst):
    for area in cab.AREAS:
        if (REPO / area).is_dir():
            shutil.copytree(REPO / area, dst / area)


def edit(root, rel, mutate):
    """Apply `mutate` to every document of one file; comments are lost, which a copy can afford."""
    path = root / rel
    docs = [d for d in yaml.safe_load_all(path.read_text()) if d]
    for d in docs:
        mutate(d)
    path.write_text(yaml.safe_dump_all(docs, sort_keys=False))


def errors_after(plant, contract=CONTRACT):
    with tempfile.TemporaryDirectory() as tmp:
        root = pathlib.Path(tmp)
        copy_tree(root)
        if plant:
            plant(root)
        return cab.Boundary(root, contract).run()


def has(errors, *needles):
    return any(all(n in e for n in needles) for e in errors)


clean = errors_after(None)
check(clean == [], f"this repository's tree has no crossing (got {clean[:3]})")

# host -> AI
errs = errors_after(lambda r: edit(r, "infrastructure/aws-0/kustomization.yaml",
                                   lambda d: d["resources"].append("../base/kueue")))
check(has(errs, "infrastructure/aws-0/kustomization.yaml", "../base/kueue", "host -> ai"),
      "a host kustomization that lists an AI directory fails")

errs = errors_after(lambda r: edit(r, "clusters/aws-0/apps.yaml",
                                   lambda d: d["spec"]["dependsOn"].append({"name": "agent-router"})))
check(has(errs, "clusters/aws-0/apps.yaml", "Kustomization/apps depends on the AI Kustomization agent-router"),
      "a host Kustomization that depends on an AI one fails")

# AI -> host
errs = errors_after(lambda r: edit(r, "infrastructure/base/kueue/kustomization.yaml",
                                   lambda d: d["resources"].append("../keda")))
check(has(errs, "infrastructure/base/kueue/kustomization.yaml", "../keda", "ai -> host"),
      "an AI kustomization that lists a host directory fails")

errs = errors_after(lambda r: edit(r, "clusters/aws-0-agent-platform/infrastructure-agent-router.yaml",
                                   lambda d: d["spec"]["dependsOn"].append({"name": "tooling"})))
check(has(errs, "depends on the host Kustomization tooling", "(H2)"),
      "an AI Kustomization that depends on a host name outside H2 fails")


def plant_var(root):
    path = root / "infrastructure/base/kueue/helm-values-configmap.yaml"
    path.write_text(path.read_text() + "# ${aws_account_id}\n")


errs = errors_after(plant_var)
check(has(errs, "${aws_account_id} is not an H3 substitution key"), "an AI file substituting a key outside H3 fails")

stale = dict(CONTRACT, ai_paths=CONTRACT["ai_paths"] + ["^infrastructure/[^/]+/no-such-component/"])
errs = errors_after(None, stale)
check(has(errs, "no-such-component", "matches no file"), "a move-list entry that matches nothing fails")

if FAILURES:
    sys.exit(f"{len(FAILURES)} failure(s)")
print("all passed")
