#!/usr/bin/env python3
# requires: python3
"""cohort-results.py: the v2 cohort's decision inputs (spec §6), on a synthetic sheet."""
import contextlib
import csv
import importlib.util
import io
import os
import pathlib
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[3]
spec = importlib.util.spec_from_file_location("cohort_results", ROOT / "scripts/ops/github/cohort-results.py")
cres = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cres)
COLUMNS = cres._cr.COLUMNS

fails = []
def check(name, got, want):
    if got != want:
        fails.append(f"{name}: got {got!r}, want {want!r}")

def row(**kw):
    return {c: str(kw.get(c, "")) for c in COLUMNS}

rows = [
    row(issue=1, arm="A", usd=0.6, ended="escalated", counter_exhausted="budget-run"),
    row(issue=2, arm="A", pr=11, usd=0.9, ended="escalated", counter_exhausted="reviewRounds",
        still_fixable="yes", label_to_pr_min=30, verdict="rejected-fixable"),
    row(issue=3, arm="A", pr=12, usd=0.5, ended="pr", label_to_pr_min=20, verdict="merged-after-edits"),
    row(issue=1, arm="B", pr=21, usd=1.0, ended="pr", label_to_pr_min=9, verdict="merged-as-is"),
    row(issue=2, arm="B", pr=22, usd=2.0, ended="pr", label_to_pr_min=13, verdict="merged-after-edits"),
    row(issue=3, arm="B", pr=23, usd=1.5, ended="pr", label_to_pr_min=10, verdict="rejected-wrong"),
    # A timeout not yet backfilled: no usd, counted as unpriced rather than as $0 silently.
    row(issue=1, arm="C", ended="timeout"),
]
s = cres.summarize(rows)

check("accepted", [s[a]["accepted"] for a in "ABC"], [1, 2, 0])
check("usd", [s[a]["usd"] for a in "ABC"], [2.0, 4.5, 0.0])
# §6: failures' spend counts in the numerator.
check("usd per accepted", [s[a]["usd_per_accepted"] for a in "ABC"], [2.0, 2.25, None])
check("ended A", s["A"]["ended"]["escalated"], 2)
check("ended keys", sorted(s["B"]["ended"]), sorted(cres._cr.ENDED))
check("ended C timeout", s["C"]["ended"]["timeout"], 1)
check("median label_to_pr", [s[a]["median_label_to_pr_min"] for a in "ABC"], [25.0, 10, None])
check("unpriced", [s[a]["unpriced"] for a in "ABC"], [0, 0, 1])
check("A by counter", s["A"]["escalations_by_counter"], {"budget-run": 1, "reviewRounds": 1})
check("A fixable", s["A"]["fixable_escalations"], 1)

text = cres.render(s)
for want in ["A escalations by counter_exhausted: budget-run 1, reviewRounds 1",
             "A escalations with a counter out on a still-fixable PR: 1"]:
    if want not in text:
        fails.append(f"render lacks {want!r}")
if not any(l.startswith("C ") and "n/a" in l for l in text.splitlines()):
    fails.append(f"render: arm C with no accepted outcome should print n/a:\n{text}")

with tempfile.TemporaryDirectory() as d:
    path = os.path.join(d, "results.csv")
    with open(path, "w", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=COLUMNS)
        w.writeheader()
        w.writerows(rows)
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        cres.main([path])
    check("main prints render", buf.getvalue().strip(), text)

if fails:
    print("FAIL\n  " + "\n  ".join(fails))
    sys.exit(1)
print("PASS: cohort-results")
