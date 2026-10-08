#!/usr/bin/env bash
# SC-12 (SP3 §5.3): every path that defines an agent's authority is a gate path, and every agent
# rule in .policy.yml excludes all of them. A new agent-platform child with an uncovered path, or
# a rule that drops one, fails here, before an agent could ever widen its own autonomy there.
set -euo pipefail
ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
# Files that must always be gate paths, whatever the children say.
SENTINELS="${SENTINELS:-.policy.yml .github/rulesets/agent-merge-gate.json clusters/aws-0/agent-platform.yaml AGENTS.md security/AGENTS.md .claude/settings.json .agents/skills/x docs/platform-constitution.md scripts/ci/check-policy-gate-coverage.sh scripts/ci/check-workflow-secrets.sh container-images/agent-harness/commit-msg opentofu/aws/openbao/management/policies/external-secrets.hcl}"
ROOT="$ROOT" SENTINELS="$SENTINELS" python3 - <<'PY'
import glob, os, re, sys, yaml

root = os.environ["ROOT"]
try:
    policy = yaml.safe_load(open(os.path.join(root, ".policy.yml")))
except FileNotFoundError:
    # RED until Task 6.6 lands .policy.yml; a clean failure beats a traceback in CI.
    sys.exit(f"no {os.path.join(root, '.policy.yml')}: it holds the canonical gate list")
rules = policy.get("approval_rules", [])
canon = next((r for r in rules if r.get("name") == "agent change approved by a maintainer"), None)
if canon is None:
    sys.exit("no rule named 'agent change approved by a maintainer': it holds the canonical gate list")
gates = canon["if"]["no_changed_files"]["paths"]
errors = []

agent_logins = re.compile(r"\[bot\]$")
for r in rules:
    users = (r.get("if", {}).get("has_author_in") or {}).get("users", [])
    if not any(agent_logins.search(u) and u != "renovate[bot]" for u in users):
        continue
    have = set((r.get("if", {}).get("no_changed_files") or {}).get("paths", []))
    missing = [g for g in gates if g not in have]
    if missing:
        errors.append(f"rule '{r['name']}' lacks gate paths: {missing}")

def covered(path):
    return any(re.search(g, path) for g in gates)

for f in sorted(glob.glob(os.path.join(root, "clusters", "*-agent-platform", "*.yaml"))):
    for doc in yaml.safe_load_all(open(f)):
        if not doc or doc.get("kind") != "Kustomization" or "spec" not in doc:
            continue
        p = doc["spec"].get("path", "").removeprefix("./").rstrip("/")
        if p and not covered(p + "/kustomization.yaml"):
            errors.append(f"{os.path.relpath(f, root)}: child path {p}/ is not a gate path")

for s in os.environ["SENTINELS"].split():
    if not covered(s):
        errors.append(f"sentinel {s} is not a gate path")

for e in errors:
    print("FAIL:", e, file=sys.stderr)
sys.exit(1 if errors else 0)
PY
