#!/usr/bin/env python3
"""Render the walkthrough transcript as the docs page's timeline table and mermaid diagram.

usage: factory-journey.py <transcript.json>
"""
import json
import sys
from datetime import datetime

STEPS = [("labelled", "A maintainer labels the issue"), ("started_comment", "The factory says it started"),
         ("pr_opened", "PR opened"), ("changes_requested", "The reviewer requests changes"),
         ("revision_done", "The revision is pushed"), ("ended", "Closed unmerged (before the wave)")]


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
    print(f"  M->>GH: label #{t['issue']} factory/ready")
    print(f"  F->>GH: comment: started, watch {t['room']}")
    for r in t["runs"]:
        print(f"  F->>A: {r['role']} run {r['id']} ({r['trigger']})")
        print(f"  A->>R: events, handoff or verdict")
    print(f"  A->>GH: PR #{t['pr']}")
    print("  M->>GH: Request changes")
    print("  F->>R: the review, queued for the next run")
    print("  M->>GH: approve, then close (nothing merges before the wave)")
    print("```")


if __name__ == "__main__":
    main(sys.argv[1])
