#!/usr/bin/env bash
# T8 (SP3 §8): agent branches live in this repository, so their PRs run pull_request workflows
# with its secrets. Only GITHUB_TOKEN may appear in such a workflow; a new secret-bearing
# workflow must fence agent heads first.
# External review R01: such a workflow also grants no write permission — write scopes live
# only in allowlisted jobs that run no PR code. The allowlist below is a gate path (R17).
set -euo pipefail
DIR="${WORKFLOWS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/.github/workflows}"
DIR="$DIR" python3 - <<'PY'
import glob, os, re, sys, yaml

# job -> the write scopes it may hold. build-and-push's split out of the PR path is its
# own fix(ci) PR; until it lands the lint flags the job's run steps, and the entry stays
# so the split cannot quietly widen it again.
ALLOWLIST = {
    "sarif-upload": {"security-events"},
    "render-diff-comment": {"pull-requests"},
    "build-and-push": {"packages", "security-events"},
    # notify-main-broken: push-gated if:, no checkout by design, run: only opens the tracking issue
    "notify-main-broken": {"issues"},
}

def write_scopes(perms):
    # GitHub's all-scopes shorthand is `write-all` (`read-all` is read-only and
    # correctly yields no write). A bare `write` is not valid syntax; keep
    # treating it as all-scopes — it can only ever tighten the lint.
    if perms in ("write", "write-all"):
        return None
    if isinstance(perms, dict):
        return {k for k, v in perms.items() if v == "write"}
    return set()

bad = []
for f in sorted(glob.glob(os.path.join(os.environ["DIR"], "*.y*ml"))):
    text = open(f).read()
    doc = yaml.safe_load(text) or {}
    on = doc.get("on", doc.get(True, {}))  # PyYAML reads the key `on` as True
    events = on if isinstance(on, (dict, list)) else [on]
    triggers = {e for e in events if e in ("pull_request", "pull_request_target")}
    if not triggers:
        continue
    name = os.path.basename(f)
    # Only ${{ … secrets.NAME }} template expressions are secret references; a bare
    # `secrets.foo` substring also matches script filenames (check-workflow-secrets.sh).
    for secret in sorted(set(re.findall(r"\$\{\{[^}]*\bsecrets\.([A-Za-z0-9_]+)", text)) - {"GITHUB_TOKEN"}):
        bad.append(f"{name}: secrets.{secret} in a pull_request workflow")
    scopes = write_scopes(doc.get("permissions"))
    if scopes is None:
        bad.append(f"{name}: workflow-level permissions: write (every scope)")
    else:
        for scope in sorted(scopes):
            bad.append(f"{name}: workflow-level {scope}: write")
    for job, spec in (doc.get("jobs") or {}).items():
        if not isinstance(spec, dict):
            continue
        held = write_scopes(spec.get("permissions"))
        if held is None:
            bad.append(f"{name}: job '{job}' holds write on every scope")
            continue
        for scope in sorted(held - ALLOWLIST.get(job, set())):
            bad.append(f"{name}: job '{job}' holds {scope}: write and is not in the allowlist")
        if job in ALLOWLIST:
            # An allowlisted job runs no PR code. pull_request's default checkout ref is
            # the PR merge commit; pull_request_target's is the base, so only an explicit
            # pull_request ref counts there.
            steps = [s for s in (spec.get("steps") or []) if isinstance(s, dict)]
            # a push-gated if: means the job's run: steps never execute on a pull_request event
            job_if = str(spec.get("if") or "")
            push_gated = "github.event_name == 'push'" in job_if or "!= 'pull_request'" in job_if
            if any("run" in s for s in steps) and not push_gated:
                bad.append(f"{name}: allowlisted job '{job}' has a run: step")
            for s in steps:
                if str(s.get("uses") or "").split("@")[0] != "actions/checkout":
                    continue
                ref = str((s.get("with") or {}).get("ref") or "")
                if "github.event.pull_request" in ref or "github.head_ref" in ref \
                        or (not ref and "pull_request" in triggers):
                    bad.append(f"{name}: allowlisted job '{job}' checks out the PR head")
for b in bad:
    print("FAIL:", b, file=sys.stderr)
sys.exit(1 if bad else 0)
PY
