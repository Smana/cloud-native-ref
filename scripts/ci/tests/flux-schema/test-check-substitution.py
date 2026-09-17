#!/usr/bin/env python3
"""Tests for check-substitution.py's undefined-variable gate.

The first test harness any script in scripts/flux-schema/ has had.
render-bundle.py's `top_most_overlays` docstring cited a `test-flux-schema.sh`
as "a safety net" pinning known nested cases; that file has never existed here.
A docstring asserting protection that is absent reads as covered and nobody
re-checks -- the same shape as an inert Renovate annotation.

This covers the gate added in 2026-08 and, deliberately, its LOUD-FAILURE
contract. Nothing else in the repo ever runs configmap_keys' SystemExit paths,
so without these they rot silently: an extractor that returns an empty set on a
changed file would report every variable as undefined, and one that skips the
file would report every variable as fine. Both look like a working gate.

Run: python3 scripts/flux-schema/test-check-substitution.py
"""
import importlib.util
import pathlib
import sys
import tempfile

HERE = pathlib.Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("check_substitution", HERE / "check-substitution.py")
cs = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cs)

FAILURES = []


def check(name, condition, detail=""):
    if condition:
        print(f"  ok   {name}")
    else:
        print(f"  FAIL {name}{(' -- ' + detail) if detail else ''}")
        FAILURES.append(name)


def expect_systemexit(name, fn, detail=""):
    try:
        fn()
    except SystemExit:
        print(f"  ok   {name}")
        return
    except Exception as exc:  # noqa: BLE001 - any other exception is a failure here
        print(f"  FAIL {name} -- raised {type(exc).__name__}, expected SystemExit")
        FAILURES.append(name)
        return
    print(f"  FAIL {name} -- returned without raising{(' -- ' + detail) if detail else ''}")
    FAILURES.append(name)


# --- The classify_missing contract -------------------------------------------
# Synthetic key sets throughout: these must not depend on what opentofu/ happens
# to define today, or the tests break every time a real variable is added.

CM = [{"kind": "ConfigMap", "name": "fake-vars"}]
CM_AND_SECRET = CM + [{"kind": "Secret", "name": "fake-secret"}]


def keys(_name):
    return {"region", "cluster_name"}


print("classify_missing:")

failing, unattributable = cs.classify_missing(["region"], CM, keys)
check("applied and defined -> nothing reported", failing == [] and unattributable == [])

failing, unattributable = cs.classify_missing(["region", "nope"], CM, keys)
check(
    "applied and NOT defined, all-ConfigMap -> fails",
    failing == ["nope"] and unattributable == [],
    f"got failing={failing} unattributable={unattributable}",
)

failing, unattributable = cs.classify_missing([], CM, keys)
check("defined but not applied -> nothing reported", failing == [] and unattributable == [])

failing, unattributable = cs.classify_missing(["nope"], CM_AND_SECRET, keys)
check(
    "missing but a Secret ref is present -> reported, NOT failed",
    failing == [] and unattributable == ["nope"],
    f"got failing={failing} unattributable={unattributable}",
)

failing, unattributable = cs.classify_missing(["nope"], [], keys)
check(
    "no substituteFrom at all (inline substitute only) -> nothing reported",
    failing == [] and unattributable == [],
    "a Kustomization wired only via postBuild.substitute must not have every "
    "variable flagged; this was a real bug before the `if not refs` guard",
)

two_cms = [
    {"kind": "ConfigMap", "name": "a"},
    {"kind": "ConfigMap", "name": "b"},
]


def split_keys(name):
    return {"region"} if name == "a" else {"cluster_name"}


failing, _ = cs.classify_missing(["region", "cluster_name"], two_cms, split_keys)
check(
    "keys from multiple ConfigMap refs are unioned, not checked one at a time",
    failing == [],
    f"got failing={failing} -- a variable defined in the second ConfigMap "
    f"must not be reported missing from the first",
)

# --- The loud-failure contract of configmap_keys ------------------------------
# These are the paths nothing else exercises.

print("configmap_keys loud failures:")

expect_systemexit(
    "unknown ConfigMap name -> SystemExit",
    lambda: cs.configmap_keys("no-such-vars"),
)


def _with_temp_source(text, fn):
    """Point CONFIGMAP_SOURCES at a temp file, run fn, always restore."""
    with tempfile.TemporaryDirectory() as d:
        p = pathlib.Path(d) / "kubernetes.tf"
        p.write_text(text)
        saved_sources = dict(cs.CONFIGMAP_SOURCES)
        saved_root = cs.REPO_ROOT
        cs.REPO_ROOT = pathlib.Path(d)
        cs.CONFIGMAP_SOURCES["probe-vars"] = "kubernetes.tf"
        try:
            fn()
        finally:
            cs.REPO_ROOT = saved_root
            cs.CONFIGMAP_SOURCES.clear()
            cs.CONFIGMAP_SOURCES.update(saved_sources)


_with_temp_source(
    'resource "kubectl_manifest" "something_else" {\n  data = {\n    a = 1\n  }\n}\n',
    lambda: expect_systemexit(
        "flux_cluster_vars resource absent -> SystemExit",
        lambda: cs.configmap_keys("probe-vars"),
    ),
)

_with_temp_source(
    'resource "kubectl_manifest" "flux_cluster_vars" {\n  yaml_body = yamlencode({\n'
    "    data = {\n    }\n  })\n}\n",
    lambda: expect_systemexit(
        "empty data block -> SystemExit rather than 'everything undefined'",
        lambda: cs.configmap_keys("probe-vars"),
    ),
)

# --- The real extraction is non-trivial ---------------------------------------
# Guards against a parse that "succeeds" while finding two keys.

print("real ConfigMaps:")

aws = cs.configmap_keys("eks-aws-0-vars")
gcp = cs.configmap_keys("gke-gcp-0-vars")

check("aws-0 vars parsed, more than 10 keys", len(aws) > 10, f"got {len(aws)}")
check("gcp-0 vars parsed, more than 10 keys", len(gcp) > 10, f"got {len(gcp)}")
check("both define region", "region" in aws and "region" in gcp)
check(
    "project_id is GCP-only",
    "project_id" in gcp and "project_id" not in aws,
    "if this fails the two ConfigMaps have converged, or the parse is picking up "
    "the wrong block",
)

print()
if FAILURES:
    print(f"FAIL: {len(FAILURES)} case(s): {', '.join(FAILURES)}", file=sys.stderr)
    sys.exit(1)
print("==> all cases passed")
