#!/usr/bin/env python3
"""Tests for render-bundle.py's `spec.valuesFrom` resolution.

The second test harness in scripts/flux-schema/, and it exists for the same
reason as the first: `resolve_values` is what stands between the repo and a
SILENT skip.

Until 2026-09-12 the renderer read `spec.values` and nothing else, so six
HelmReleases -- vlsingle, vlcluster, vmsingle, vmcluster, harbor, flux-operator
-- were rendered with chart DEFAULTS and passed both gates. Nothing failed,
because a value the bundle never saw cannot be invalid. A regression here would
not break the build; it would quietly shrink what the build checks, which is the
one failure mode no gate downstream can report.

So these cases pin behaviour, and they pin the LOUD-FAILURE contract with it:
a missing values source is an error, an `optional` one is a note on stderr, and
a Secret -- unresolvable by construction -- is named on every run rather than
skipped. A `resolve_values` that returned `{}` and swallowed its notes would
still render every chart, still pass every gate, and undo the whole fix.

Run: python3 scripts/flux-schema/test-render-bundle.py
"""
import contextlib
import importlib.util
import io
import pathlib
import sys

HERE = pathlib.Path(__file__).resolve().parent
# render-bundle.py imports yamlcompat from beside it.
sys.path.insert(0, str(HERE))
spec = importlib.util.spec_from_file_location("render_bundle", HERE / "render-bundle.py")
rb = importlib.util.module_from_spec(spec)
spec.loader.exec_module(rb)

FAILURES = []


def check(name, condition, detail=""):
    if condition:
        print(f"  ok   {name}")
    else:
        print(f"  FAIL {name}{(' -- ' + detail) if detail else ''}")
        FAILURES.append(name)


def configmap(name, data, namespace="observability"):
    return {"kind": "ConfigMap", "metadata": {"name": name, "namespace": namespace}, "data": data}


def secret(name, namespace="observability"):
    # stringData/data deliberately absent: a Secret's keys are written by an
    # ExternalSecret at runtime, so the committed manifest has none. That is the
    # state resolve_values has to cope with.
    return {"kind": "Secret", "metadata": {"name": name, "namespace": namespace}}


def resolve(spec_dict, objects, cluster=None):
    """Call under test, with stderr captured. Returns (values, error, notes)."""
    index = rb.index_values_objects((doc, "observability") for doc in objects)
    buf = io.StringIO()
    with contextlib.redirect_stderr(buf):
        values, error = rb.resolve_values(
            spec_dict, "observability", "release", index, cluster, "test-stem"
        )
    return values, error, buf.getvalue()


# --- valuesKey: the default, and an override ----------------------------------

print("valuesKey:")

values, error, _ = resolve(
    {"valuesFrom": [{"kind": "ConfigMap", "name": "cm"}]},
    [configmap("cm", {"values.yaml": "alpha: 1\n"})],
)
check("defaults to values.yaml", error is None and values == {"alpha": 1}, f"{error!r} {values!r}")

values, error, _ = resolve(
    {"valuesFrom": [{"kind": "ConfigMap", "name": "cm", "valuesKey": "custom.yaml"}]},
    [configmap("cm", {"values.yaml": "alpha: 1\n", "custom.yaml": "beta: 2\n"})],
)
check("an explicit valuesKey wins", error is None and values == {"beta": 2}, f"{error!r} {values!r}")

# The default is a real default, not "whatever single key is present": a
# ConfigMap without values.yaml is an error, never a lucky guess at its one key.
values, error, _ = resolve(
    {"valuesFrom": [{"kind": "ConfigMap", "name": "cm"}]},
    [configmap("cm", {"other.yaml": "alpha: 1\n"})],
)
check("no values.yaml key is an error, not a fallback", error is not None, f"{error!r}")


# --- Precedence: valuesFrom in list order, then spec.values on top -------------

print("precedence:")

values, error, _ = resolve(
    {
        "valuesFrom": [{"kind": "ConfigMap", "name": "cm"}],
        "values": {"shared": "from-spec-values", "only-inline": True},
    },
    [configmap("cm", {"values.yaml": "shared: from-configmap\nonly-cm: true\n"})],
)
check(
    "spec.values wins over valuesFrom",
    error is None and values.get("shared") == "from-spec-values",
    f"{values!r}",
)
check(
    "keys unique to each side both survive",
    values.get("only-cm") is True and values.get("only-inline") is True,
    f"{values!r}",
)

values, error, _ = resolve(
    {
        "valuesFrom": [
            {"kind": "ConfigMap", "name": "first"},
            {"kind": "ConfigMap", "name": "second"},
        ]
    },
    [
        configmap("first", {"values.yaml": "shared: first\na: 1\n"}),
        configmap("second", {"values.yaml": "shared: second\nb: 2\n"}),
    ],
)
check(
    "later valuesFrom entries win over earlier ones",
    error is None and values == {"shared": "second", "a": 1, "b": 2},
    f"{values!r}",
)

# Helm/Flux semantics, and the same deep_merge the renderer already used for
# CHART_RENDER_OVERRIDES: maps merge key-wise, lists are REPLACED wholesale.
values, error, _ = resolve(
    {"values": {"nested": {"b": 2}, "list": ["inline"]}},
    [],
)
check("spec.values alone still works", error is None and values["nested"] == {"b": 2}, f"{values!r}")

values, error, _ = resolve(
    {
        "valuesFrom": [{"kind": "ConfigMap", "name": "cm"}],
        "values": {"nested": {"b": 2}, "list": ["inline"]},
    },
    [configmap("cm", {"values.yaml": "nested:\n  a: 1\nlist:\n  - from-cm\n  - second\n"})],
)
check(
    "maps deep-merge across the two sources",
    error is None and values["nested"] == {"a": 1, "b": 2},
    f"{values!r}",
)
check("lists are replaced, not concatenated", values["list"] == ["inline"], f"{values!r}")


# --- targetPath ---------------------------------------------------------------
# No ConfigMap entry in the repo uses this today (all three that do name
# Secrets, which cannot be resolved), so these cases are the only thing holding
# the path honest.

print("targetPath:")

values, error, _ = resolve(
    {
        "valuesFrom": [
            {
                "kind": "ConfigMap",
                "name": "cm",
                "valuesKey": "clientID",
                "targetPath": "web.config.auth.clientID",
            }
        ]
    },
    [configmap("cm", {"clientID": "abc123"})],
)
check(
    "places the raw value at a dotted path",
    error is None and values == {"web": {"config": {"auth": {"clientID": "abc123"}}}},
    f"{error!r} {values!r}",
)

values, error, _ = resolve(
    {
        "valuesFrom": [
            {"kind": "ConfigMap", "name": "cm", "valuesKey": "k", "targetPath": r"a.b\.c.d"}
        ]
    },
    [configmap("cm", {"k": "x"})],
)
check(
    r"an escaped \. is one key, not a separator",
    error is None and values == {"a": {"b.c": {"d": "x"}}},
    f"{values!r}",
)

# helm's strvals never coerces a targetPath value, so "true" stays a string.
# Getting this wrong would silently flip a chart's boolean.
values, error, _ = resolve(
    {"valuesFrom": [{"kind": "ConfigMap", "name": "cm", "valuesKey": "k", "targetPath": "flag"}]},
    [configmap("cm", {"k": "true"})],
)
check("the value stays a string, never coerced", values == {"flag": "true"}, f"{values!r}")


# --- optional: present vs absent object, present vs absent key ----------------

print("optional:")

values, error, notes = resolve(
    {"valuesFrom": [{"kind": "ConfigMap", "name": "missing"}]},
    [],
)
check("a missing ConfigMap is an ERROR when not optional", error is not None, f"{error!r}")

values, error, notes = resolve(
    {"valuesFrom": [{"kind": "ConfigMap", "name": "missing", "optional": True}], "values": {"a": 1}},
    [],
)
check(
    "a missing ConfigMap is skipped when optional",
    error is None and values == {"a": 1},
    f"{error!r} {values!r}",
)
check("...and says so on stderr", "missing" in notes and "optional" in notes, repr(notes))

values, error, notes = resolve(
    {"valuesFrom": [{"kind": "ConfigMap", "name": "cm", "valuesKey": "absent.yaml"}]},
    [configmap("cm", {"values.yaml": "a: 1\n"})],
)
check("a missing KEY is an ERROR when not optional", error is not None, f"{error!r}")

values, error, notes = resolve(
    {
        "valuesFrom": [
            {"kind": "ConfigMap", "name": "cm", "valuesKey": "absent.yaml", "optional": True}
        ]
    },
    [configmap("cm", {"values.yaml": "a: 1\n"})],
)
check("a missing KEY is skipped when optional", error is None and values == {}, f"{error!r}")
check("...and says so on stderr", "absent.yaml" in notes, repr(notes))


# --- Secrets are named, never silently skipped --------------------------------

print("Secrets:")

values, error, notes = resolve(
    {
        "valuesFrom": [
            {
                "kind": "Secret",
                "name": "flux-ui-oidc",
                "valuesKey": "clientID",
                "targetPath": "web.config.auth.clientID",
            }
        ],
        "values": {"a": 1},
    },
    [secret("flux-ui-oidc")],
)
check(
    "a Secret reference is not an error -- the release is fine, the bundle is smaller",
    error is None and values == {"a": 1},
    f"{error!r} {values!r}",
)
check("the note names the release", "HelmRelease/observability/release" in notes, repr(notes))
check("the note names the Secret and key", "flux-ui-oidc" in notes and "clientID" in notes, repr(notes))
check("the note says it was NOT resolved", "NOT RESOLVED" in notes, repr(notes))
check(
    "a Secret that happens to exist in the repo is STILL not resolved",
    # Guard against someone "fixing" this by reading committed stringData: a
    # Secret with a literal value in git would be a different bug.
    error is None and "web" not in values,
    f"{values!r}",
)


# --- Substitution happens before parsing --------------------------------------

print("substitution:")

values, error, _ = resolve(
    {"valuesFrom": [{"kind": "ConfigMap", "name": "cm"}]},
    [configmap("cm", {"values.yaml": "name: ${cluster_name}\n"})],
)
check(
    "a ${var} is substituted, not passed through to helm",
    error is None and values == {"name": rb.FIXTURE_VARS["cluster_name"]},
    f"{values!r}",
)

# Compared against substitute() itself rather than a hardcoded region, so this
# cannot rot when CLUSTER_FIXTURE_VARS changes.
aws, _, _ = resolve(
    {"valuesFrom": [{"kind": "ConfigMap", "name": "cm"}]},
    [configmap("cm", {"values.yaml": "region: ${region}\n"})],
    cluster="aws-0",
)
gcp, _, _ = resolve(
    {"valuesFrom": [{"kind": "ConfigMap", "name": "cm"}]},
    [configmap("cm", {"values.yaml": "region: ${region}\n"})],
    cluster="gcp-0",
)
check(
    "per-cluster overrides apply",
    aws["region"] == rb.substitute("${region}", "aws-0")
    and gcp["region"] == rb.substitute("${region}", "gcp-0"),
    f"{aws!r} {gcp!r}",
)
check("and the two clusters actually differ", aws["region"] != gcp["region"], f"{aws!r} {gcp!r}")

values, error, _ = resolve(
    {"valuesFrom": [{"kind": "ConfigMap", "name": "cm"}]},
    [configmap("cm", {"values.yaml": "dashboard: $${escaped}\n"})],
)
check(
    "Flux's $${...} escape survives",
    error is None and values == {"dashboard": "$${escaped}"},
    f"{values!r}",
)


# --- Content that is not a values mapping -------------------------------------

print("malformed content:")

values, error, _ = resolve(
    {"valuesFrom": [{"kind": "ConfigMap", "name": "cm"}]},
    [configmap("cm", {"values.yaml": "- just\n- a\n- list\n"})],
)
check("a non-mapping document is an error", error is not None, f"{error!r}")

values, error, _ = resolve(
    {"valuesFrom": [{"kind": "ConfigMap", "name": "cm"}], "values": {"a": 1}},
    [configmap("cm", {"values.yaml": "\n"})],
)
check(
    "an empty document contributes nothing, without erroring",
    error is None and values == {"a": 1},
    f"{error!r} {values!r}",
)

values, error, _ = resolve(
    {"valuesFrom": [{"kind": "ConfigMap", "name": "cm"}]},
    [configmap("cm", {"values.yaml": "a: [unterminated\n"})],
)
check("unparseable YAML is an error", error is not None, f"{error!r}")


# --- The index keys on kind as well as name -----------------------------------

print("index:")

index = rb.index_values_objects(
    [(configmap("shared", {"values.yaml": "a: 1\n"}), "ns"), (secret("shared"), "ns")]
)
check(
    "a ConfigMap and a Secret may share a name",
    index.get(("ns", "ConfigMap", "shared"), {}).get("kind") == "ConfigMap"
    and ("ns", "Secret", "shared") in index,
    f"{sorted(index)!r}",
)
check(
    "namespace is part of the key",
    ("other-ns", "ConfigMap", "shared") not in index,
    f"{sorted(index)!r}",
)
check(
    "kinds that cannot be a values source are not indexed",
    rb.index_values_objects([({"kind": "Deployment", "metadata": {"name": "x"}}, "ns")]) == {},
)


# --- The repo's own wiring still resolves -------------------------------------
# Guards the contract end-to-end: these four are the ConfigMap-backed entries
# the fix exists for, and a rename on either side must fail here rather than
# quietly shrink the bundle.

print("real HelmReleases:")

import yaml  # noqa: E402 - after the module load above, deliberately

real = []
for path in sorted(pathlib.Path("observability/base").rglob("*.yaml")):
    try:
        docs = [d for d in yaml.safe_load_all(path.read_text()) if isinstance(d, dict)]
    except yaml.YAMLError:
        continue
    for doc in docs:
        if doc.get("kind") == "HelmRelease" and (doc.get("spec") or {}).get("valuesFrom"):
            real.append((path, doc))

check("found the observability HelmReleases that use valuesFrom", len(real) == 4, f"got {len(real)}")

for path, doc in real:
    objects = []
    for sibling in sorted(path.parent.glob("*.yaml")):
        try:
            objects += [d for d in yaml.safe_load_all(sibling.read_text()) if isinstance(d, dict)]
        except yaml.YAMLError:
            continue
    values, error, _ = resolve(doc["spec"], objects, cluster="aws-0")
    check(
        f"{path.name} resolves against its sibling ConfigMap",
        error is None and len(values) > 1,
        f"{error!r}",
    )

print()
if FAILURES:
    print(f"FAIL: {len(FAILURES)} case(s): {', '.join(FAILURES)}", file=sys.stderr)
    sys.exit(1)
print("==> all cases passed")
