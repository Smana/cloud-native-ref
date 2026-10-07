#!/usr/bin/env python3
"""The docs page's timeline and diagram come from the walkthrough transcript, minutes computed, the
diagram in the order things happened."""
import json
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
SUBJECT = os.path.join(HERE, "..", "..", "docs", "factory-journey.py")


def started(at, run):
    return {"at": at, "body": f"Agent factory task `3buqdlot` started run `{run}` (implementer) on branch `agent/3buqdlot`."}


t = {"issue": 2199, "task": "3buqdlot", "pr": 2200, "template": "pair", "tier": "standard", "tokens": 812000,
     "room": "https://rooms.example/r/3buqdlot",
     "runs": [{"id": "aaaaaaaa", "role": "implementer", "trigger": "initial"}, {"id": "bbbbbbbb", "role": "reviewer", "trigger": "review"},
              {"id": "cccccccc", "role": "implementer", "trigger": "human"}, {"id": "dddddddd", "role": "implementer", "trigger": "resume"}],
     "comments": [started("2026-10-06T09:01:00Z", "aaaaaaaa"), started("2026-10-06T09:13:00Z", "bbbbbbbb"),
                  started("2026-10-06T09:21:00Z", "cccccccc"),
                  {"at": "2026-10-06T09:25:00Z", "body": "Agent factory task `3buqdlot`: run `cccccccc` stopped because the sandbox "
                   "was lost (spot reclaim or eviction); resuming automatically (1/2)."},
                  started("2026-10-06T09:25:02Z", "dddddddd")],
     "timestamps": {"labelled": "2026-10-06T09:00:00Z", "started_comment": "2026-10-06T09:01:00Z",
                    "pr_opened": "2026-10-06T09:12:00Z", "changes_requested": "2026-10-06T09:20:00Z",
                    "revision_done": "2026-10-06T09:31:00Z", "approved": "2026-10-06T09:38:00Z", "ended": "2026-10-06T09:40:00Z"}}
with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as f:
    json.dump(t, f)
out = subprocess.run([sys.executable, SUBJECT, f.name], capture_output=True, text=True, check=True).stdout
fails = [m for m in ["sequenceDiagram", "| PR opened | 09:12 | 12 |", "reviewer", "812k tokens",
                     "| A maintainer requests changes | 09:20 | 20 |", "| A maintainer approves | 09:38 | 38 |"] if m not in out]
# The human review came between the reviewer run and the revision, and the reclaim before its resume.
order = ["implementer run aaaaaaaa (initial)", "A->>GH: PR #2200", "reviewer run bbbbbbbb (review)", "M->>GH: Request changes",
         "implementer run cccccccc (human)", "resuming automatically (1/2)", "implementer run dddddddd (resume)", "M->>GH: approve"]
at = [out.find(m) for m in order]
if -1 in at or at != sorted(at):
    fails.append("diagram order " + str(dict(zip(order, at))))
if fails:
    print("FAIL:", fails, "\n" + out)
    sys.exit(1)
print("PASS")
