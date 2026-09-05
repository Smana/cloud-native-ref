#!/usr/bin/env bash
#
# validate-vmrules.sh — parse the PromQL inside every repo-authored VMRule.
#
# The repo authors its alerting rules as `VMRule` custom resources, and until
# this script existed nothing had ever parsed the expressions inside them.
# `flux schema validate` proves a VMRule's *structure* and its CEL: that
# `spec.groups[].rules[].expr` is a string in the right place. Whether that
# string is a syntactically valid query is invisible to it — an unbalanced
# paren, a misspelled function or a malformed label matcher is still a string.
# The cost is paid at runtime: vmalert logs a parse error and the rule group
# never evaluates, so the alert simply never fires. A silent gap in alerting is
# the worst possible failure mode for an alert, because nothing tells you.
#
# A `VMRule`'s `.spec` is already the shape of a Prometheus rules file
# (`groups: [{name, interval, rules: [...]}]`), so `promtool check rules` on
# the extracted `.spec` is the whole check. promtool parses every `expr` with
# the real PromQL parser and type-checks the alert/record fields.
#
# ---------------------------------------------------------------------------
# What is skipped, and why — read this before trusting a green run
# ---------------------------------------------------------------------------
# A rule group may declare a query language other than PromQL. From the vmalert
# documentation, the group-level `type` field is an:
#
#     "Optional type for expressions inside rules to override the
#      -rule.defaultRuleType(default is "prometheus") cmd-line flag."
#
# with three supported values: `prometheus`, `graphite` and `vlogs`.
# (https://docs.victoriametrics.com/victoriametrics/vmalert/)
#
# So the skip predicate is read from the data, not from a filename: a group is
# checkable when its `type` is unset, empty, or `prometheus` — the documented
# default — and skipped otherwise. Today that skips exactly one group,
# `loggen` in observability/base/loggen/demo-vmrule.yaml, whose `type: vlogs`
# expressions are LogsQL against VictoriaLogs and which promtool cannot parse
# and must not try to. A `graphite` group would be skipped by the same rule
# without anyone editing this script.
#
# Every skipped group is printed by name with its reason on every run, and the
# summary states the skipped count separately from the checked count. That is
# deliberate and it is the repo's standing discipline: `validate-manifests.sh`
# reports `Skipped: 0` because the kubeconform setup it replaced ran with
# `-ignore-missing-schemas` and silently validated nothing for the life of the
# project. A green run here means "the groups named as checked parse" — never
# "everything was checked".
#
# Note that `type` is not a Prometheus rulefmt field, so promtool rejects it as
# an unknown field even when it is set to `prometheus`. It is therefore stripped
# from the groups that survive the predicate. Nothing else is stripped: field
# checking stays strict, so a typo (`fore:` for `for:`) still fails. If a group
# later needs a genuine VictoriaMetrics-only field (`concurrency`, `tenant`,
# `params`, `eval_offset`, …), promtool will fail with
# `field <x> not found in type rulefmt.RuleGroup`. The fix is to add that field
# to STRIP_GROUP_KEYS below — not to pass `--ignore-unknown-fields`, which would
# also stop catching typos, and not to delete the gate.
#
# ---------------------------------------------------------------------------
# Source files, not the rendered bundle — a deliberate limitation
# ---------------------------------------------------------------------------
# This reads the `kind: VMRule` documents that are committed to this repo, and
# not `.bundle/` as the SPEC-007 gates do. Two reasons, and one real gap.
#
# 1. Actionability. The bundle also contains VMRules shipped by upstream Helm
#    charts, which we neither author nor can fix. VictoriaMetrics accepts
#    MetricsQL, so an upstream chart is entitled to ship an expression promtool
#    rejects; the only remedies would be pinning an older chart or maintaining
#    an ignore list. A gate that can go red on something the repo cannot fix
#    gets switched off, which is worse than a narrower gate.
# 2. Attribution and speed. A failure names a committed file an author can open
#    and edit, and the check needs no bundle render — so, like
#    check-substitution.py, it can run first and fail fast.
#
# Measured 2026-09-02, so the tradeoff is on the record rather than assumed:
# the rendered bundle held 22 VMRule documents / 26 checkable groups, and all
# of them passed promtool. A bundle-wide check would therefore be green today
# too — the argument above is about what happens on the first upstream chart
# bump that is not, not about present breakage.
#
# The real gap this leaves: rules authored in this repo but *not* as a
# `kind: VMRule` document — e.g. alert rules written inline in a HelmRelease
# `values:` block (`additionalVictoriaMetricsMap` and friends). Those are
# repo-authored, are our responsibility, and this scan does not see them. There
# are none today (grepped for `- alert:`/`- record:` inside every HelmRelease:
# no hits). If one is ever added, either move it to a VMRule or extend this
# script — do not assume it is covered.
#
# ---------------------------------------------------------------------------
# PromQL is a subset of MetricsQL — what to do when this gate is wrong
# ---------------------------------------------------------------------------
# VictoriaMetrics evaluates MetricsQL, a strict superset of PromQL. This gate
# uses a PromQL parser, so it can in principle reject an expression that is
# perfectly valid on our own stack: `keep_metric_names`, `WITH(...)` templates,
# `rollup_*`, `range_*`, `median_over_time`, `alias()`, `label_set()` and the
# other MetricsQL-only extensions all parse here as errors.
#
# Nothing in the repo relies on MetricsQL-only syntax today. That is verified,
# not assumed, and by construction: every checkable expression below passes a
# PromQL parser, which is only possible if all of them are also valid PromQL.
#
# If you are the first person to hit this — you wrote a deliberate MetricsQL
# expression and this script rejected it — the fix is NOT to delete the gate,
# which would take all the other rules back to unparsed. In order of
# preference:
#   1. Rewrite it in PromQL if an equivalent exists (usually it does).
#   2. If MetricsQL is genuinely required, move that rule into its own group and
#      give the group an explicit `type` this script skips, or add a narrow,
#      commented per-group allowlist here naming the group and the construct.
# Either way the skip is then visible in this script's output, which is the
# point: an unparsed expression should be something the repo says out loud.

set -euo pipefail
cd "$(dirname "$0")/.."

REPO_ROOT="$(pwd)"
MODE="${1:-check}"

# Resolution precedence matches scripts/flux-schema/preflight.sh: explicit
# override > mise scoped to this repo's mise.toml > bare PATH. A stale promtool
# from some other install must not be picked up silently — the pin in mise.toml
# is what makes "it parses" reproducible between a laptop and CI.
if [ -n "${PROMTOOL_BIN:-}" ]; then
  if [ ! -x "${PROMTOOL_BIN}" ]; then
    echo "error: \$PROMTOOL_BIN='${PROMTOOL_BIN}' is set but is not an executable file." >&2
    echo "       Fix: point it at a real promtool, or unset it to auto-resolve via mise/PATH." >&2
    exit 2
  fi
else
  PROMTOOL_BIN=""
  if command -v mise >/dev/null 2>&1 && [ -f "${REPO_ROOT}/mise.toml" ]; then
    PROMTOOL_BIN="$(mise which -C "${REPO_ROOT}" promtool 2>/dev/null || true)"
  fi
  if [ -z "${PROMTOOL_BIN}" ]; then
    PROMTOOL_BIN="$(command -v promtool 2>/dev/null || true)"
  fi
fi

if [ -z "${PROMTOOL_BIN}" ]; then
  echo "error: promtool not found (checked \$PROMTOOL_BIN, mise, PATH)." >&2
  echo "       promtool ships inside the prometheus release archive and is pinned" >&2
  echo "       in mise.toml. Fix: mise install  (or set PROMTOOL_BIN)" >&2
  exit 2
fi

if ! python3 -c 'import yaml' >/dev/null 2>&1; then
  echo "error: the Python 'yaml' module (PyYAML) is not installed." >&2
  echo "       Fix: python3 -m pip install pyyaml" >&2
  exit 2
fi

python3 - "${PROMTOOL_BIN}" "${MODE}" <<'PY'
import os
import subprocess
import sys
import tempfile

import yaml

promtool, mode = sys.argv[1], sys.argv[2]
listing = mode == "--list"

# `type` is a VictoriaMetrics extension to the group schema and is not a
# Prometheus rulefmt field, so promtool rejects it as unknown even when it
# holds the default value. It is consumed by the skip predicate, then dropped.
STRIP_GROUP_KEYS = ("type",)

# The documented default is "prometheus"; unset and empty both mean the same
# thing. Anything else ("vlogs", "graphite") is a different query language.
PROMQL_TYPES = (None, "", "prometheus")


def vmrule_files():
    """Committed YAML holding at least one `kind: VMRule` document.

    git ls-files rather than a filesystem walk: it excludes the generated,
    gitignored trees (.bundle/, .schemas/) by construction, so the scan can
    never drift onto rendered output.
    """
    out = subprocess.run(
        ["git", "ls-files", "-z", "*.yaml", "*.yml"],
        capture_output=True, text=True, check=True,
    ).stdout
    found = []
    for path in filter(None, out.split("\0")):
        try:
            text = open(path, encoding="utf-8", errors="replace").read()
        except OSError:
            continue
        # Cheap prefilter: parsing every YAML file in the repo is both slow and
        # fragile (chart templates are not valid YAML).
        if "kind: VMRule" in text:
            found.append((path, text))
    return found


checked_groups = []   # (path, rule_name, group_name, n_rules)
skipped_groups = []   # (path, rule_name, group_name, why, n_rules)
failures = []         # (path, detail)
n_docs = 0

for path, text in vmrule_files():
    try:
        docs = list(yaml.safe_load_all(text))
    except yaml.YAMLError as exc:
        failures.append((path, "file is not parseable YAML: %s" % exc))
        continue

    for doc in docs:
        if not isinstance(doc, dict) or doc.get("kind") != "VMRule":
            continue
        n_docs += 1
        name = (doc.get("metadata") or {}).get("name", "<unnamed>")
        groups = (doc.get("spec") or {}).get("groups") or []

        keep = []
        for group in groups:
            if not isinstance(group, dict):
                failures.append((path, "group in %s is not a mapping" % name))
                continue
            gname = group.get("name", "<unnamed>")
            gtype = group.get("type")
            n_rules = len(group.get("rules") or [])
            if gtype not in PROMQL_TYPES:
                skipped_groups.append((
                    path, name, gname,
                    'type: %s — expressions are not PromQL, so promtool cannot '
                    'parse them' % gtype,
                    n_rules,
                ))
                continue
            group = {k: v for k, v in group.items() if k not in STRIP_GROUP_KEYS}
            keep.append(group)
            checked_groups.append((path, name, gname, n_rules))

        if listing or not keep:
            # Nothing checkable in this document: do not hand promtool an empty
            # rules file, which would report a meaningless "SUCCESS: 0 rules".
            continue

        with tempfile.NamedTemporaryFile(
            "w", suffix=".yaml", delete=False, encoding="utf-8",
        ) as fh:
            yaml.safe_dump({"groups": keep}, fh, default_flow_style=False,
                           sort_keys=False, allow_unicode=True)
            tmp = fh.name
        try:
            proc = subprocess.run(
                [promtool, "check", "rules", "--lint-fatal", tmp],
                capture_output=True, text=True,
            )
            if proc.returncode != 0:
                # promtool names the temp file it was handed; rewrite it to the
                # committed path so the message points at something editable.
                detail = ((proc.stdout or "") + (proc.stderr or "")).replace(tmp, path)
                detail = "\n".join(
                    line for line in detail.splitlines()
                    if line.strip() and not line.startswith("Checking ")
                )
                failures.append((path, "VMRule %s\n%s" % (name, detail)))
        finally:
            os.unlink(tmp)

n_files = len({p for p, _, _, _ in checked_groups} |
              {p for p, _, _, _, _ in skipped_groups})
n_checked_rules = sum(n for _, _, _, n in checked_groups)
n_skipped_rules = sum(n for _, _, _, _, n in skipped_groups)

if listing:
    print("%-8s %-58s %-22s %s" % ("STATUS", "FILE", "GROUP", "RULES"))
    for path, _, gname, n in sorted(checked_groups):
        print("%-8s %-58s %-22s %d" % ("check", path, gname, n))
    for path, _, gname, why, n in sorted(skipped_groups):
        print("%-8s %-58s %-22s %d  (%s)" % ("skip", path, gname, n, why))
    sys.exit(0)

print("==> Parsed %d VMRule document(s) in %d file(s)" % (n_docs, n_files))

# Printed on success as well as failure. A skipped group is not validated, it
# is ignored, and that has to be visible in a green run.
if skipped_groups:
    print()
    for path, name, gname, why, n in sorted(skipped_groups):
        print("    SKIPPED  %s" % path)
        print("             VMRule %s, group %r (%d rule(s)) — NOT checked" % (name, gname, n))
        print("             %s" % why)

if failures:
    print()
    for path, detail in failures:
        print("INVALID  %s" % path)
        for line in detail.splitlines():
            print("    %s" % line)
        print()
    print(
        "%d VMRule file(s) contain expressions promtool could not parse.\n"
        "vmalert would log a parse error and never evaluate the group, so the\n"
        "alert would silently never fire. Fix the expression.\n"
        "If the expression is deliberate MetricsQL, read the header of\n"
        "scripts/validate-vmrules.sh — do not delete the gate."
        % len(failures)
    )
    sys.exit(1)

print()
print(
    "==> %d PromQL expression(s) in %d group(s) parse. "
    "%d group(s) / %d rule(s) skipped and NOT checked%s."
    % (
        n_checked_rules, len(checked_groups),
        len(skipped_groups), n_skipped_rules,
        " (listed above)" if skipped_groups else "",
    )
)
PY
