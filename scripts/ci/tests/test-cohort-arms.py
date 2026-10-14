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
    claude = next((s for s in job["steps"] if s.get("id") == "claude"), {})
    # The env scrub's sandbox needs bwrap and socat; ubuntu-latest ships neither and blocks bwrap by default.
    # `task check` needs what ci.yaml's kubernetes-validation installs, which --allowedTools keeps the arm from installing.
    before = job["steps"][: job["steps"].index(claude)] if claude in job["steps"] else []
    deps = " ".join(s.get("run", "") for s in before)
    if not any("mise-action" in s.get("uses", "") for s in before):
        fails.append(f"{name}: mise-action must run before the claude step")
    for needle in ("apt-get install -y -qq bubblewrap socat", "kernel.apparmor_restrict_unprivileged_userns=0",
                   "bwrap --ro-bind / /", "command -v socat", "flux plugin install schema@",
                   "pip install --quiet --disable-pip-version-check pyyaml", "install -y -qq jq","./scripts/ci/fetch-xrd-crds.sh"):
        if needle not in deps:
            fails.append(f"{name}: a step before the claude step must run `{needle}`")
    w = claude.get("with") or {}
    if "--max-turns 60" not in w.get("claude_args", ""):
        fails.append(f"{name}: claude_args must cap the run with --max-turns 60")
    prompt = " ".join(w.get("prompt", "").split())
    arm = name.split("-")[1]
    for needle in (f"Push only to `cohort/arm-{arm}/", "never to `agent/**`", "stop and report instead of retrying",
                   "Run `task check` in the foreground and wait for it, never in the background",
                   "Commit and push before anything optional"):
        if needle not in prompt:
            fails.append(f"{name}: the prompt must say `{needle}`")
    env = claude.get("env") or {}
    if str(env.get("CLAUDE_CODE_SUBPROCESS_ENV_SCRUB")) != "1":
        fails.append(f"{name}: the claude step must set CLAUDE_CODE_SUBPROCESS_ENV_SCRUB: \"1\"")
    if not claude.get("timeout-minutes", 0) or claude["timeout-minutes"] >= job.get("timeout-minutes", 0):
        fails.append(f"{name}: the claude step needs a timeout below the job's, so the upload still runs")
    upload = [s for s in job["steps"] if "upload-artifact" in s.get("uses", "")]
    if not upload or " ".join(upload[0].get("if", "").split()) != "always() && steps.claude.outputs.execution_file != ''":
        fails.append(f"{name}: upload must run always() and only with an execution file")
    if name == "arm-c":
        for slot in ("HAIKU", "SONNET", "OPUS"):
            if env.get(f"ANTHROPIC_DEFAULT_{slot}_MODEL") != "glm-5.3":
                fails.append(f"arm-c: ANTHROPIC_DEFAULT_{slot}_MODEL must be glm-5.3")
text = f.read_text()
if re.search(r"(sk-ant-|api_key:\s*['\"]?[A-Za-z0-9])", text):
    fails.append("a key literal is in the workflow")
if "${{ github.event.issue.body }}" in text:
    fails.append("the issue body must not be interpolated: the agent reads it with gh")
if fails:
    print("FAIL\n  " + "\n  ".join(fails))
    sys.exit(1)
print("PASS: cohort-arms")
