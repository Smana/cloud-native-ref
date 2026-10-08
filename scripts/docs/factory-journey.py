#!/usr/bin/env python3
"""Render the walkthrough transcript as the docs page's timeline table and mermaid diagram.

usage: factory-journey.py <transcript.json>
"""
import json
import re
import sys
from datetime import datetime

STEPS = [("labelled", "A maintainer labels the issue"), ("started_comment", "The factory says it started"),
         ("pr_opened", "PR opened"), ("changes_requested", "A maintainer requests changes"),
         ("revision_done", "The revision is pushed"), ("approved", "A maintainer approves"),
         ("ended", "Closed unmerged (before the wave)")]


def when(s):
    return datetime.strptime(s, "%Y-%m-%dT%H:%M:%SZ")


def main(path):
    t = json.load(open(path))
    ts = t["timestamps"]
    start = when(ts["labelled"])
    print("| Step | UTC | Minutes after the label |\n|---|---|---|")
    for key, label in STEPS:
        if key in ts:
            at = when(ts[key])
            print(f"| {label} | {at:%H:%M} | {int((at - start).total_seconds() // 60)} |")
    roles = " → ".join(f"{r['role']} ({r['trigger']})" for r in t["runs"])
    print(f"\nRuns: {roles}. Template `{t['template']}`, tier `{t['tier']}`, {t['tokens'] // 1000}k tokens in total.\n")
    print("```mermaid\nsequenceDiagram\n  actor M as Maintainer\n  participant GH as GitHub\n  participant F as agent-factory\n"
          "  participant R as room\n  participant A as agent runs")
    for _, lines in sorted(events(t), key=lambda e: e[0]):
        for line in lines:
            print("  " + line)
    print("```")


def events(t):
    """The diagram's steps in the order they happened: a run at its factory "started" comment, a
    lost sandbox at its "resuming" comment, the humans' steps at their timestamps. A run with no
    comment keeps its place after the one before it."""
    ts, comments = t["timestamps"], t.get("comments") or []
    start = when(ts["labelled"])
    out = [(start, [f"M->>GH: label #{t['issue']} factory/ready", f"F->>GH: comment: started, watch {t['room']}"])]
    prev = start
    for r in t["runs"]:
        at = next((when(c["at"]) for c in comments if f"started run `{r['id']}`" in c["body"]), prev)
        out.append((at, [f"F->>A: {r['role']} run {r['id']} ({r['trigger']})", "A->>R: events, handoff or verdict"]))
        prev = at
    for c in comments:
        m = re.search(r"run `(\w+)` stopped because (.*?); resuming automatically \((\d+/\d+)\)", c["body"])
        if m:
            out.append((when(c["at"]), [f"F->>GH: run {m[1]}: {m[2]}, resuming automatically ({m[3]})"]))
    for key, lines in (("pr_opened", [f"A->>GH: PR #{t['pr']}"]),
                       ("changes_requested", ["M->>GH: Request changes", "F->>R: the review, queued for the next run"]),
                       ("approved", ["M->>GH: approve, then close (nothing merges before the wave)"])):
        if key in ts:
            out.append((when(ts[key]), lines))
    return out


if __name__ == "__main__":
    main(sys.argv[1])
