#!/usr/bin/env python3
"""The docs page's timeline and diagram come from the walkthrough transcript, minutes computed."""
import json
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
SUBJECT = os.path.join(HERE, "..", "..", "docs", "factory-journey.py")

t = {"issue": 2199, "task": "3buqdlot", "pr": 2200, "template": "pair", "tier": "standard", "tokens": 812000,
     "room": "https://rooms.example/r/3buqdlot",
     "runs": [{"id": "aaaaaaaa", "role": "implementer", "trigger": "initial"}, {"id": "bbbbbbbb", "role": "reviewer", "trigger": "review"}],
     "timestamps": {"labelled": "2026-10-06T09:00:00Z", "started_comment": "2026-10-06T09:01:00Z",
                    "pr_opened": "2026-10-06T09:12:00Z", "changes_requested": "2026-10-06T09:20:00Z",
                    "revision_done": "2026-10-06T09:31:00Z", "ended": "2026-10-06T09:40:00Z"}}
with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as f:
    json.dump(t, f)
out = subprocess.run([sys.executable, SUBJECT, f.name], capture_output=True, text=True, check=True).stdout
fails = [m for m in ["sequenceDiagram", "| PR opened | 09:12 | 12 |", "reviewer", "812k tokens"] if m not in out]
if fails:
    print("FAIL: missing", fails, "\n" + out)
    sys.exit(1)
print("PASS")
