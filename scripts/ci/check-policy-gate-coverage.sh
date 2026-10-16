#!/usr/bin/env bash
# SC-12 (SP3 §5.3): every path that defines an agent's authority is a gate path, and every agent
# rule in .policy.yml excludes all of them. A new agent-platform child with an uncovered path, or
# a rule that drops one, fails here, before an agent could ever widen its own autonomy there.
set -euo pipefail
ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
# Files that must always be gate paths, whatever the children say.
SENTINELS="${SENTINELS:-.policy.yml .github/rulesets/agent-merge-gate.json clusters/aws-0/agent-platform.yaml AGENTS.md security/AGENTS.md .claude/settings.json .agents/skills/x docs/platform-constitution.md scripts/ci/check-policy-gate-coverage.sh scripts/ci/check-workflow-secrets.sh flux/sources/ocirepo-ai-native-ref.yaml clusters/aws-0/ai-gateway.yaml clusters/aws-0/llm-platform.yaml clusters/aws-0/flux/flux-sources.yaml .gitignore scripts/ci/ai-overlay.sh infrastructure/base/crossplane/configuration-aws/configuration-packages.yaml infrastructure/base/crossplane/configuration-gcp/configuration-packages.yaml infrastructure/aws-0/crossplane/configuration/kustomization.yaml infrastructure/gcp-0/crossplane/configuration/kustomization.yaml clusters/aws-0/infrastructure/crossplane-configuration.yaml clusters/gcp-0/infrastructure/crossplane-configuration.yaml opentofu/aws/openbao/management/policies/external-secrets.hcl}"
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

# The children live in ai-native-ref since AI split S3: read them from the pinned artifact that
# scripts/ci/ai-overlay.sh pulls.
children = sorted(glob.glob(os.path.join(root, ".ai-artifact", "clusters", "*-agent-platform", "*.yaml")))
if not children:
    print("note: no .ai-artifact/ (run scripts/ci/ai-overlay.sh): agent-platform child paths not checked",
          file=sys.stderr)
for f in children:
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
