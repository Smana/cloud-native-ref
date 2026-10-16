#!/usr/bin/env python3
"""The v2 cohort's decision inputs (ai-native-ref docs/superpowers/specs/2026-10-12-v2-hard-task-cohort-design.md §6).

Reads the results sheet that cohort-row.py appends to and prints, per arm, what the §6 rules need.
"""
import argparse
import collections
import csv
import importlib.util
import pathlib
import statistics
import sys

_spec = importlib.util.spec_from_file_location("cohort_row", pathlib.Path(__file__).with_name("cohort-row.py"))
_cr = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_cr)
ENDED = sorted(_cr.ENDED)
ACCEPTED = {"merged-as-is", "merged-after-edits"}


def summarize(rows):
    out = {}
    for arm in "ABC":
        rs = [r for r in rows if r["arm"] == arm]
        accepted = sum(r["verdict"] in ACCEPTED for r in rs)
        # §6: every task-arm's USD, failures included; an empty cell is a timeout not yet backfilled.
        usd = round(sum(float(r["usd"] or 0) for r in rs), 4)
        mins = [int(r["label_to_pr_min"]) for r in rs if r["label_to_pr_min"]]
        out[arm] = {
            "rows": len(rs),
            "accepted": accepted,
            "usd": usd,
            "usd_per_accepted": round(usd / accepted, 4) if accepted else None,
            "ended": {e: sum(r["ended"] == e for r in rs) for e in ENDED},
            "median_label_to_pr_min": statistics.median(mins) if mins else None,
            "unpriced": sum(not r["usd"] for r in rs),
        }
    esc = [r for r in rows if r["arm"] == "A" and r["ended"] == "escalated"]
    out["A"]["escalations_by_counter"] = dict(collections.Counter(r["counter_exhausted"] or "?" for r in esc))
    out["A"]["fixable_escalations"] = sum(1 for r in esc if r["counter_exhausted"] and r["still_fixable"] == "yes")
    return out


def render(s):
    lines = ["arm  rows  accepted  usd      usd/accepted  median_label_to_pr_min  unpriced"]
    for arm in "ABC":
        a = s[arm]
        per = "n/a" if a["usd_per_accepted"] is None else f"{a['usd_per_accepted']:.2f}"
        med = "n/a" if a["median_label_to_pr_min"] is None else f"{a['median_label_to_pr_min']:g}"
        lines.append(f"{arm:<4} {a['rows']:<5} {a['accepted']:<9} {a['usd']:<8.2f} {per:<13} {med:<23} {a['unpriced']}")
    lines.append("")
    lines.append("ended  " + "  ".join(f"{e:>16}" for e in ENDED))
    for arm in "ABC":
        lines.append(f"{arm:<6} " + "  ".join(f"{s[arm]['ended'][e]:>16}" for e in ENDED))
    lines.append("")
    by = ", ".join(f"{k} {v}" for k, v in sorted(s["A"]["escalations_by_counter"].items())) or "none"
    lines.append(f"A escalations by counter_exhausted: {by}")
    lines.append(f"A escalations with a counter out on a still-fixable PR: {s['A']['fixable_escalations']}")
    return "\n".join(lines)


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    # The sheet moved to ai-native-ref with the cohort design (AI split S4).
    p.add_argument("csv", help="docs/superpowers/specs/2026-10-12-v2-hard-task-cohort-results.csv in ai-native-ref")
    a = p.parse_args(argv)
    with open(a.csv, newline="") as fh:
        rows = list(csv.DictReader(fh))
    print(render(summarize(rows)))


if __name__ == "__main__":
    sys.exit(main())
