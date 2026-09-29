#!/usr/bin/env python3
# requires: python3
"""Every command in the agent-factory runbooks targets gcp-0 (GCP parity).
Only fenced code is judged: past rounds' prose and results stay as history."""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[3]
AWSISMS = re.compile(r"priv\.aws\.ogenki\.io|opentofu/aws/|eks-aws-0|jwt/aws-0|\baws (sts|secretsmanager|ssm)\b|karpenter_nodepools|auth\.cloud\.ogenki\.io")
fails = []
files = sorted((ROOT / "docs/runbooks/agent-factory").glob("*.md"))
# Ruling W2: an empty glob (wrong ROOT, a moved directory) must not pass silently.
if len(files) < 9:
    print(f"FAIL only found {len(files)} runbook files under docs/runbooks/agent-factory (expected at least 9)")
    sys.exit(1)
for f in files:
    fenced = False
    for n, line in enumerate(f.read_text().splitlines(), 1):
        if line.lstrip().startswith("```"):
            fenced = not fenced
            continue
        if fenced and AWSISMS.search(line):
            fails.append(f"{f.name}:{n}: {line.strip()}")
for x in fails:
    print("FAIL", x)
if fails:
    sys.exit(1)
print("PASS")
