#!/usr/bin/env python3
# requires: python3
"""The v2 cohort's arm workflow stays fenced: maintainer-only trigger, pinned actions, least
permissions, one run per arm. Deleted with the workflow when the cohort ends."""
import pathlib
import re
import sys

import yaml

ROOT = pathlib.Path(__file__).resolve().parents[3]
f = ROOT / ".github/workflows/cohort-arms.yaml"
doc = yaml.safe_load(f.read_text())
fails = []
on = doc.get("on", doc.get(True))
if on != {"issues": {"types": ["labeled"]}}:
    fails.append(f"trigger must be issues: labeled only, got {on}")
if doc.get("permissions") != {}:
    fails.append("workflow-level permissions must be {}")
jobs = doc["jobs"]
if set(jobs) != {"arm-b", "arm-c"}:
    fails.append(f"jobs must be arm-b and arm-c, got {sorted(jobs)}")
for name, job in jobs.items():
    label = f"cohort/{name}"
    cond = " ".join(job.get("if", "").split())
    if "github.event.sender.login == 'Smana'" not in cond or f"github.event.label.name == '{label}'" not in cond:
        fails.append(f"{name}: if must require the maintainer and {label}: {cond}")
    if job.get("permissions") != {"contents": "write", "pull-requests": "write", "issues": "write"}:
        fails.append(f"{name}: permissions must be contents/pull-requests/issues write only")
    conc = job.get("concurrency", {})
    if conc.get("group") != f"cohort-{name}" or conc.get("cancel-in-progress") is not False:
        fails.append(f"{name}: concurrency must be cohort-{name}, not cancelling")
    for step in job["steps"]:
        uses = step.get("uses")
        if uses and not re.fullmatch(r"[\w.-]+/[\w.-]+@[0-9a-f]{40}", uses):
            fails.append(f"{name}: {uses} is not pinned by SHA")
text = f.read_text()
if re.search(r"(sk-ant-|api_key:\s*['\"]?[A-Za-z0-9])", text):
    fails.append("a key literal is in the workflow")
if "${{ github.event.issue.body }}" in text:
    fails.append("the issue body must not be interpolated: the agent reads it with gh")
if fails:
    print("FAIL\n  " + "\n  ".join(fails))
    sys.exit(1)
print("PASS: cohort-arms")
