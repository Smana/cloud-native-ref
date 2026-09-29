#!/usr/bin/env bash
# requires: python3
#
# External review M9: every alert the agent platform ships names its runbook and its
# dashboard, as the karpenter and openbao VMRules do. The real tree, not fixtures: SP2's
# and SP3's alerts land in the same directory and are held to the same rule.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
python3 -c 'import yaml' 2>/dev/null || { echo "SKIP: pyyaml not installed"; exit 77; }
ROOT="$ROOT" python3 - <<'PY'
import glob, os, sys, yaml

root = os.environ["ROOT"]
missing = []
for path in sorted(glob.glob(os.path.join(root, "observability/base/agent-platform/vmrule*.yaml"))):
    for doc in yaml.safe_load_all(open(path)):
        if not doc or doc.get("kind") != "VMRule":
            continue
        for group in doc["spec"]["groups"]:
            for rule in group.get("rules") or []:
                if "alert" not in rule:
                    continue
                annotations = rule.get("annotations") or {}
                for key in ("runbook_url", "dashboard"):
                    if not annotations.get(key):
                        missing.append(f"{os.path.relpath(path, root)}: {rule['alert']} has no {key}")
if missing:
    print("\n".join(missing), file=sys.stderr)
    sys.exit(1)
print("PASS")
PY
