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

# Every other reference kind the check covers, one plant each.
KEDA = "infrastructure/base/keda/helmrelease.yaml"
KUEUE_HR = "infrastructure/base/kueue/helmrelease.yaml"
KUEUE_KS = "clusters/aws-0-agent-platform/infrastructure-kueue.yaml"  # holds kueue and kueue-queues


def hr(mutate):
    return lambda d: mutate(d["spec"]) if d.get("kind") == "HelmRelease" else None


def ks(name, mutate):
    return lambda d: mutate(d["spec"]) if d.get("metadata", {}).get("name") == name else None


# host -> AI
errs = errors_after(lambda r: edit(r, KEDA, hr(lambda s: s["chart"]["spec"].update(
    sourceRef={"kind": "OCIRepository", "name": "kueue"}))))
check(has(errs, KEDA, "uses the AI source OCIRepository/kueue"), "a host HelmRelease that uses an AI source fails")

errs = errors_after(lambda r: edit(r, "clusters/aws-0/apps.yaml",
                                   ks("apps", lambda s: s.update(path="./infrastructure/base/kueue"))))
check(has(errs, "clusters/aws-0/apps.yaml", "applies the AI path infrastructure/base/kueue"),
      "a host Kustomization that applies an AI path fails")

errs = errors_after(lambda r: edit(r, KEDA, hr(lambda s: s.update(
    valuesFrom=[{"kind": "ConfigMap", "name": "kueue-helm-values"}]))))
check(has(errs, KEDA, "reads ConfigMap/kueue-helm-values", "H8"),
      "a host HelmRelease that reads an AI ConfigMap outside H8 fails")

errs = errors_after(lambda r: edit(r, KEDA, hr(lambda s: s.update(
    valuesFrom=[{"kind": "ConfigMap", "name": "runlore-factory-values", "optional": True}]))))
check(errs == [], f"a host HelmRelease may read H8's runlore-factory-values with optional: true (got {errs[:2]})")

errs = errors_after(lambda r: edit(r, KEDA, hr(lambda s: s.update(
    valuesFrom=[{"kind": "ConfigMap", "name": "runlore-factory-values"}]))))
check(has(errs, KEDA, "H8", "optional: true"), "a host read of H8's ConfigMap without optional: true fails")

errs = errors_after(lambda r: edit(r, "clusters/aws-0/agent-platform.yaml",
                                   ks("agent-platform", lambda s: s.update(path="./clusters/gcp-0-agent-platform"))))
check(has(errs, "clusters/aws-0/agent-platform.yaml", "applies the AI path clusters/gcp-0-agent-platform"),
      "an umbrella that points at another cluster's child directory fails")


# AI -> host
def to_host_chart(s):
    s.pop("chartRef")
    s["chart"] = {"spec": {"chart": "keda", "sourceRef": {"kind": "HelmRepository", "name": "kedacore"}}}


errs = errors_after(lambda r: edit(r, KUEUE_HR, hr(to_host_chart)))
check(has(errs, KUEUE_HR, "uses the host source HelmRepository/kedacore", "H1"),
      "an AI HelmRelease that uses a host source outside H1 fails")

errs = errors_after(lambda r: edit(r, KUEUE_HR, hr(lambda s: s.update(
    chartRef={"kind": "OCIRepository", "name": "atlas-operator"}))))
check(has(errs, KUEUE_HR, "uses the host source OCIRepository/atlas-operator", "H1"),
      "an AI HelmRelease whose chartRef is a host source outside H1 fails")

errs = errors_after(lambda r: edit(r, KUEUE_HR, hr(lambda s: s["valuesFrom"].append(
    {"kind": "ConfigMap", "name": "runlore-base-values"}))))
check(has(errs, KUEUE_HR, "reads ConfigMap/runlore-base-values, which a host path defines"),
      "an AI HelmRelease that reads a host ConfigMap fails")

errs = errors_after(lambda r: edit(r, KUEUE_KS, ks("kueue", lambda s: s["postBuild"]["substituteFrom"].append(
    {"kind": "ConfigMap", "name": "cluster-settings"}))))
check(has(errs, KUEUE_KS, "substitutes from ConfigMap/cluster-settings", "H3"),
      "an AI Kustomization that substitutes from a ConfigMap outside H3 fails")

errs = errors_after(lambda r: edit(r, KUEUE_KS, ks("kueue-queues", lambda s: s.update(
    sourceRef={"kind": "OCIRepository", "name": "atlas-operator"}))))
check(has(errs, KUEUE_KS, "uses the host source OCIRepository/atlas-operator", "H1"),
      "an AI Kustomization whose sourceRef is a host OCIRepository fails")

errs = errors_after(lambda r: edit(r, KUEUE_KS, ks("kueue-queues", lambda s: s.update(
    path="./infrastructure/base/keda"))))
check(has(errs, KUEUE_KS, "applies the host path infrastructure/base/keda"),
      "an AI Kustomization that applies a host path fails")

# What H2 allows stays allowed.
errs = errors_after(lambda r: edit(r, KUEUE_KS, ks("kueue-queues", lambda s: s["dependsOn"].append({"name": "crds"}))))
check(errs == [], f"an AI Kustomization may depend on an H2 name (got {errs[:2]})")

# The check fails on what it cannot read or reads loosely.
errs = errors_after(lambda r: edit(r, KEDA, hr(lambda s: s.update(
    valuesFrom=[{"kind": "ConfigMap", "name": "runlore-factory-values", "optional": "true"}]))))
check(has(errs, KEDA, "H8", "optional: true"), 'a host read of H8 with optional: "true" (a string) fails')

errs = errors_after(lambda r: (r / "infrastructure/aws-0/broken.yaml").write_text("a: [unclosed\n"))
check(has(errs, "infrastructure/aws-0/broken.yaml", "cannot parse"), "a malformed YAML file under an area fails")


def drop_kind(d):
    d.pop("kind", None)
    d["resources"].append("../base/kueue")


errs = errors_after(lambda r: edit(r, "infrastructure/aws-0/kustomization.yaml", drop_kind))
check(has(errs, "infrastructure/aws-0/kustomization.yaml", "../base/kueue", "host -> ai"),
      "a host kustomization.yaml without a kind that lists an AI directory fails")

if FAILURES:
    sys.exit(f"{len(FAILURES)} failure(s)")
print("all passed")
