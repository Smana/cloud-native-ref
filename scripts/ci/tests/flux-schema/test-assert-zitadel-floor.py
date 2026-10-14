#!/usr/bin/env python3
"""Tests for assert-zitadel-floor.py, the gate on the ZITADEL version ADR-0056 depends on.

A ZITADEL below the floor runs fine and logs nothing; the forgeable IdP link is
only visible to someone who goes looking. So both directions are pinned: a
release at or above v4.17.3 passes, and every way below it fails.

Run: python3 scripts/ci/tests/flux-schema/test-assert-zitadel-floor.py
"""
import contextlib
import importlib.util
import io
import pathlib
import sys
import tempfile

import yaml

HERE = pathlib.Path(__file__).resolve().parent
SUBJECT_DIR = HERE.parent.parent / "flux-schema"
sys.path.insert(0, str(SUBJECT_DIR))
spec = importlib.util.spec_from_file_location("assert_zitadel_floor", SUBJECT_DIR / "assert-zitadel-floor.py")
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)

FAILURES = []
DIGEST = "@sha256:" + "0" * 64


def check(name, condition, detail=""):
    if condition:
        print(f"  ok   {name}")
    else:
        print(f"  FAIL {name}{(' -- ' + detail) if detail else ''}")
        FAILURES.append(name)


def workload(image, kind="Deployment", name="zitadel", init=False):
    pod = {"containers": [{"name": "zitadel", "image": image}]}
    if init:
        pod = {"initContainers": [{"name": "init", "image": image}],
               "containers": [{"name": "app", "image": "busybox:1.37"}]}
    template = {"spec": pod}
    spec = {"jobTemplate": {"spec": {"template": template}}} if kind == "CronJob" else {"template": template}
    return {"apiVersion": "apps/v1", "kind": kind, "metadata": {"name": name, "namespace": "security"},
            "spec": spec}


def errors_for(*objs):
    return gate.check(list(objs))


print("passing releases")
for tag in ("v4.17.3", "v4.18.0", "v4.19.4" + DIGEST, "v5.0.0", "4.17.10"):
    errs = errors_for(workload(f"ghcr.io/zitadel/zitadel:{tag}"))
    check(f"{tag} passes", errs == [], str(errs))

print("failing pins")
for tag, word in (("v4.17.2", "below"), ("v4.16.9" + DIGEST, "below"), ("v3.4.0", "below"),
                  ("v4.18.0-rc.1", "pre-release"), ("v4.18.0-beta.2" + DIGEST, "pre-release"),
                  ("latest", "not a semver"), ("v4.18", "not a semver")):
    errs = errors_for(workload(f"ghcr.io/zitadel/zitadel:{tag}"))
    check(f"{tag} fails as {word}", len(errs) == 1 and word in errs[0], str(errs))

errs = errors_for(workload("ghcr.io/zitadel/zitadel" + DIGEST))
check("a digest with no tag fails", len(errs) == 1 and "no tag" in errs[0], str(errs))

print("where the image hides")
errs = errors_for(workload("ghcr.io/zitadel/zitadel:v4.17.2", kind="Job", name="zitadel-init", init=True))
check("an init container on a Job is checked", len(errs) == 1 and "Job security/zitadel-init" in errs[0], str(errs))
errs = errors_for(workload("ghcr.io/zitadel/zitadel:v4.17.2", kind="CronJob"))
check("a CronJob is checked", len(errs) == 1 and "CronJob" in errs[0], str(errs))
errs = errors_for(workload("ghcr.io/zitadel/zitadel:v4.19.4"), workload("ghcr.io/zitadel/zitadel:v4.17.0",
                                                                         kind="Job", name="zitadel-setup"))
check("one stale container among good ones fails", len(errs) == 1 and "zitadel-setup" in errs[0], str(errs))

print("scope")
errs = errors_for(workload("ghcr.io/zitadel/zitadel-login:v1.0.0"), workload("ghcr.io/zitadel/zitadel:v4.19.4"))
check("the login image is out of scope", errs == [], str(errs))
errs = errors_for(workload("ghcr.io/zitadel/zitadel-login:v4.19.4"))
check("no ZITADEL container at all fails", len(errs) == 1 and "no ghcr.io/zitadel/zitadel" in errs[0], str(errs))

print("main")
with tempfile.TemporaryDirectory() as tmp:
    bundle = pathlib.Path(tmp)
    (bundle / "chart-zitadel.yaml").write_text(yaml.safe_dump_all(
        [workload("ghcr.io/zitadel/zitadel:v4.17.2"), workload("ghcr.io/zitadel/zitadel:v4.17.2")]))
    err = io.StringIO()
    with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(err):
        code = gate.main([str(bundle)])
    check("main exits 1 below the floor", code == 1)
    check("main reports a duplicated defect once", err.getvalue().count("FAIL") == 1, err.getvalue())
    with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
        check("main exits 2 on a missing bundle", gate.main([str(bundle / "absent")]) == 2)

if FAILURES:
    print(f"{len(FAILURES)} failed")
    sys.exit(1)
print("all passed")
