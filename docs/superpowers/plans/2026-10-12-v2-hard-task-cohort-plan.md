# v2 hard-task cohort Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Run 15 frozen issues through three arms (the factory, Claude Code Action on Claude,
Claude Code Action on GLM-5.3), record one measured row per task-arm, and apply the decision rules
fixed in the spec.

**Architecture:** No factory code changes. Two settings in the factory's values, one temporary
workflow carrying arms B and C, one collector script that turns `gh`, the Task status, the gateway
meter and the action's execution log into a CSV row. The run itself is a per-issue procedure the
maintainer drives.

**Tech Stack:** GitHub Actions, `anthropics/claude-code-action`, Python 3 (stdlib only), `gh`,
`kubectl`, VictoriaMetrics' query API.

**Spec:** [`docs/superpowers/specs/2026-10-12-v2-hard-task-cohort-design.md`](../specs/2026-10-12-v2-hard-task-cohort-design.md)

## Global Constraints

- Budget: $150 in total, $50 per arm. Arm A by its `standard` task budget (3 M tokens); B and C by
  their keys' provider spend limits.
- GLM-5.3 list price, USD per 1 M tokens: input 1.40, cached input 0.26, output 4.40.
- Labels: arm A `factory/ready` + `class:<scripts|tests|dashboards>`; arm B `cohort/arm-b`; arm C
  `cohort/arm-c`. Only the maintainer (`Smana`) applies them.
- Verdicts: `merged-as-is`, `merged-after-edits`, `rejected-fixable`, `rejected-wrong`.
  *Accepted* = the first two.
- `ended`: `pr`, `escalated`, `timeout`, `budget-exhausted`, `no-pr`.
- One issue at a time, in the frozen order of spec §2; nothing re-run.
- Every action is pinned by a 40-character SHA with its version in a comment. No secret literal in
  any file.
- Gate paths (`.policy.yml`): `tooling/base/agent-factory/` and `.github/` changes are committed
  by the maintainer, never by an agent.

## File map

| File | Responsibility | Task |
|---|---|---|
| `tooling/base/agent-factory/helm-values-configmap.yaml` | `scripts` class; `controlPercent: 0` | 1 |
| `scripts/ops/github/cohort-row.py` | Builds one sheet row from fetched data | 2 |
| `scripts/ci/tests/test-cohort-row.py` | Its tests, run by `scripts/ci/tests/run.sh` | 2 |
| `.github/workflows/cohort-arms.yaml` | Arms B and C, temporary | 3 |
| `scripts/ci/tests/test-cohort-arms.py` | The workflow's fences, temporary | 3 |
| `docs/superpowers/specs/2026-10-12-v2-hard-task-cohort-results.csv` | The sheet | 4 |

---

### Task 1: The factory's cohort settings

**Files:**
- Modify: `tooling/base/agent-factory/helm-values-configmap.yaml` (the `triage:` block at
  `controlPercent: 10  # OD-14`, and the `classes:` block)

**Interfaces:**
- Produces: class `scripts`, admitted from an issue label `class:scripts`; no control group while
  the cohort runs.

- [ ] **Step 1: Edit the values**

In `triage:` replace `controlPercent: 10  # OD-14` with:

```yaml
        # 0 while the v2 cohort runs: the control group's frontier tier runs `trio`, not the `pair`
        # the cohort measures. Back to 10 when it ends (docs/superpowers/specs/2026-10-12-v2-hard-task-cohort-design.md).
        controlPercent: 0  # OD-14
```

In `classes:` add after `dashboards: {}`:

```yaml
        scripts: {}
```

- [ ] **Step 2: Validate the render**

Run: `./scripts/ci/validate-manifests.sh`
Expected: exit 0. Do not run it concurrently with another render (`.bundle/` race).

- [ ] **Step 3: Create the labels**

```bash
gh label create class:scripts --repo Smana/cloud-native-ref --color 0e8a16 --description "Factory class: scripts"
gh label create cohort/arm-b  --repo Smana/cloud-native-ref --color 5319e7 --description "v2 cohort: arm B (Claude Code Action, Claude)"
gh label create cohort/arm-c  --repo Smana/cloud-native-ref --color 5319e7 --description "v2 cohort: arm C (Claude Code Action, GLM-5.3)"
```

Expected: three labels listed by `gh label list --repo Smana/cloud-native-ref --search cohort` and
`--search class:scripts`.

- [ ] **Step 4: Commit (maintainer: gate path)**

```bash
git add tooling/base/agent-factory/helm-values-configmap.yaml
git commit -m "🔧 chore(agent-factory): scripts class and no control group for the v2 cohort"
```

---

### Task 2: The row collector

Superseded in review: the committed `cohort-row.py` and its test are the reference (no `--slurp`; argparse choices; runs guard; optional `--exec-log`; modelUsage).

**Files:**
- Create: `scripts/ops/github/cohort-row.py`
- Test: `scripts/ci/tests/test-cohort-row.py`

**Interfaces:**
- Produces, in `cohort-row.py`: `COLUMNS: list[str]`; `glm_usd(tokens_in: int, cached: int, out: int) -> float`;
  `exec_log_usage(text: str) -> tuple[int, int, int, float]` (in, cached, out, cost);
  `vm_query(run_ids: list[str], window_min: int) -> str`; `vm_tokens(resp: dict) -> tuple[int, int, int]`;
  `label_time(events: list[dict], label: str) -> str`; `minutes(start: str, end: str) -> int`;
  `commits_after(commits: list[dict], since: str) -> int`;
  `build_row(**fields) -> dict[str, str]` raising `ValueError` on an unknown `verdict` or `ended`.
  CLI: `cohort-row.py --issue N --arm A|B|C [--pr N] [--task-json F --vm-url U | --exec-log F]
  --ended E [--verdict V --review-min M] [--counter-exhausted C --still-fixable yes|no] --out CSV`.

- [ ] **Step 1: Write the failing tests**

```python
#!/usr/bin/env python3
# requires: python3
"""cohort-row.py: the v2 cohort's sheet rows (spec §5). Pure functions only; no network."""
import importlib.util
import json
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parents[3]
spec = importlib.util.spec_from_file_location("cohort_row", ROOT / "scripts/ops/github/cohort-row.py")
cr = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cr)

fails = []
def check(name, got, want):
    if got != want:
        fails.append(f"{name}: got {got!r}, want {want!r}")

# GLM-5.3 list: 1.40 in, 0.26 cached, 4.40 out per 1M; tokens_in includes the cached ones.
check("glm_usd no cache", cr.glm_usd(1_000_000, 0, 100_000), 1.84)
check("glm_usd cached", cr.glm_usd(1_000_000, 900_000, 0), round((100_000 * 1.40 + 900_000 * 0.26) / 1e6, 4))

result = {"type": "result", "total_cost_usd": 0.4211,
          "usage": {"input_tokens": 1200, "cache_creation_input_tokens": 3000,
                    "cache_read_input_tokens": 50000, "output_tokens": 800}}
array = json.dumps([{"type": "system"}, {"type": "assistant"}, result])
check("exec log array", cr.exec_log_usage(array), (54200, 50000, 800, 0.4211))
check("exec log jsonl", cr.exec_log_usage("\n".join(json.dumps(m) for m in [{"type": "system"}, result])),
      (54200, 50000, 800, 0.4211))
try:
    cr.exec_log_usage(json.dumps([{"type": "system"}]))
    fails.append("exec log without result: no ValueError")
except ValueError:
    pass

q = cr.vm_query(["impl-1", "rev-1"], 95)
for part in ['xplane-run-(impl-1|rev-1)"', 'gen_ai_token_type=~"input|cached_input|output"',
             "[95m]", "sum by (gen_ai_token_type)"]:
    if part not in q:
        fails.append(f"vm_query lacks {part!r}: {q}")

resp = {"data": {"result": [
    {"metric": {"gen_ai_token_type": "input"}, "value": [0, "600000.4"]},
    {"metric": {"gen_ai_token_type": "cached_input"}, "value": [0, "500000"]},
    {"metric": {"gen_ai_token_type": "output"}, "value": [0, "20000"]}]}}
check("vm_tokens", cr.vm_tokens(resp), (600000, 500000, 20000))
check("vm_tokens empty", cr.vm_tokens({"data": {"result": []}}), (0, 0, 0))

events = [{"event": "labeled", "label": {"name": "class:tests"}, "created_at": "2026-10-13T08:00:00Z"},
          {"event": "labeled", "label": {"name": "cohort/arm-b"}, "created_at": "2026-10-13T08:01:00Z"},
          {"event": "unlabeled", "label": {"name": "cohort/arm-b"}, "created_at": "2026-10-13T09:00:00Z"},
          {"event": "labeled", "label": {"name": "cohort/arm-b"}, "created_at": "2026-10-13T10:00:00Z"}]
check("label_time first", cr.label_time(events, "cohort/arm-b"), "2026-10-13T08:01:00Z")
check("minutes", cr.minutes("2026-10-13T08:01:00Z", "2026-10-13T09:31:30Z"), 90)
commits = [{"committedDate": "2026-10-13T08:20:00Z"}, {"committedDate": "2026-10-13T08:40:00Z"},
           {"committedDate": "2026-10-13T09:10:00Z"}]
check("commits_after", cr.commits_after(commits, "2026-10-13T08:30:00Z"), 2)

row = cr.build_row(issue=7, arm="B", pr=2400, tokens_in=54200, tokens_cached=50000, tokens_out=800,
                   usd=0.4211, label_to_pr_min=20, label_to_verdict_min=90, review_rounds=0,
                   fix_runs=2, ended="pr", counter_exhausted="", still_fixable="",
                   verdict="merged-as-is", review_min=12)
check("row columns", list(row), cr.COLUMNS)
check("row usd", row["usd"], "0.4211")
for bad in ({"verdict": "lgtm"}, {"ended": "done"}):
    try:
        cr.build_row(**{**dict(issue=7, arm="B", ended="pr", verdict=""), **bad})
        fails.append(f"build_row accepted {bad}")
    except ValueError:
        pass

if fails:
    print("FAIL\n  " + "\n  ".join(fails))
    sys.exit(1)
print("PASS: cohort-row")
```

- [ ] **Step 2: Run it to see it fail**

Run: `python3 scripts/ci/tests/test-cohort-row.py`
Expected: FAIL, `FileNotFoundError` on `scripts/ops/github/cohort-row.py`.

- [ ] **Step 3: Write the collector**

```python
#!/usr/bin/env python3
"""One row of the v2 hard-task cohort sheet (docs/superpowers/specs/2026-10-12-v2-hard-task-cohort-design.md §5).

Fetches what it can (gh, the Task, the gateway meter, the action's execution log) and takes the
maintainer's judgements as flags. Appends to the CSV; never rewrites earlier rows.
"""
import argparse
import csv
import json
import os
import subprocess
import sys
import urllib.parse
import urllib.request
from datetime import datetime

COLUMNS = ["issue", "arm", "pr", "tokens_in", "tokens_cached", "tokens_out", "usd",
           "label_to_pr_min", "label_to_verdict_min", "review_rounds", "fix_runs", "ended",
           "counter_exhausted", "still_fixable", "verdict", "review_min"]
VERDICTS = {"merged-as-is", "merged-after-edits", "rejected-fixable", "rejected-wrong", ""}
ENDED = {"pr", "escalated", "timeout", "budget-exhausted", "no-pr"}
ARM_LABEL = {"A": "factory/ready", "B": "cohort/arm-b", "C": "cohort/arm-c"}
GLM = {"in": 1.40, "cached": 0.26, "out": 4.40}  # USD per 1M, glm-5.3 list (vmrule-llm-gateway.yaml)
REPO = "Smana/cloud-native-ref"


def glm_usd(tokens_in, cached, out):
    # tokens_in includes the cached ones, as the gateway's `input` includes `cached_input`.
    return round(((tokens_in - cached) * GLM["in"] + cached * GLM["cached"] + out * GLM["out"]) / 1e6, 4)


def exec_log_usage(text):
    text = text.strip()
    msgs = json.loads(text) if text.startswith("[") else [json.loads(l) for l in text.splitlines() if l.strip()]
    results = [m for m in msgs if m.get("type") == "result"]
    if not results:
        raise ValueError("no result message in the execution file")
    r = results[-1]
    u = r.get("usage", {})
    cached = u.get("cache_read_input_tokens", 0)
    # Anthropic's input_tokens excludes both cache counters.
    tokens_in = u.get("input_tokens", 0) + u.get("cache_creation_input_tokens", 0) + cached
    return tokens_in, cached, u.get("output_tokens", 0), float(r.get("total_cost_usd", 0.0))


def vm_query(run_ids, window_min):
    runs = "|".join(run_ids)
    return ('sum by (gen_ai_token_type) (increase(gen_ai_client_token_usage_sum{'
            f'ar_agent=~"system:serviceaccount:agents:xplane-run-({runs})", '
            f'gen_ai_token_type=~"input|cached_input|output"}}[{window_min}m]))')


def vm_tokens(resp):
    by = {s["metric"].get("gen_ai_token_type"): float(s["value"][1]) for s in resp["data"]["result"]}
    return int(by.get("input", 0)), int(by.get("cached_input", 0)), int(by.get("output", 0))


def _ts(s):
    return datetime.fromisoformat(s.replace("Z", "+00:00"))


def label_time(events, label):
    for e in events:
        if e.get("event") == "labeled" and e.get("label", {}).get("name") == label:
            return e["created_at"]
    raise ValueError(f"label {label} never applied")


def minutes(start, end):
    return round((_ts(end) - _ts(start)).total_seconds() / 60)


def commits_after(commits, since):
    return sum(1 for c in commits if _ts(c["committedDate"]) > _ts(since))


def build_row(**fields):
    if fields.get("verdict", "") not in VERDICTS:
        raise ValueError(f"verdict {fields['verdict']!r} not in {sorted(VERDICTS - {''})}")
    if fields.get("ended") not in ENDED:
        raise ValueError(f"ended {fields.get('ended')!r} not in {sorted(ENDED)}")
    return {c: "" if fields.get(c) is None else str(fields.get(c, "")) for c in COLUMNS}


def _gh(*args):
    return json.loads(subprocess.run(["gh", *args], check=True, capture_output=True, text=True).stdout)


def main():
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("--issue", type=int, required=True)
    p.add_argument("--arm", choices="ABC", required=True)
    p.add_argument("--pr", type=int)
    p.add_argument("--task-json", help="arm A: kubectl get tasks.agents.ogenki.io -o json, one Task")
    p.add_argument("--vm-url", help="arm A: VictoriaMetrics base URL")
    p.add_argument("--exec-log", help="arms B, C: the action's execution file")
    p.add_argument("--ended", required=True)
    p.add_argument("--verdict", default="")
    p.add_argument("--review-min", default="")
    p.add_argument("--counter-exhausted", default="")
    p.add_argument("--still-fixable", default="")
    p.add_argument("--out", required=True)
    a = p.parse_args()

    events = _gh("api", "--paginate", "--slurp", f"repos/{REPO}/issues/{a.issue}/events")
    events = [e for page in events for e in page]
    start = label_time(events, ARM_LABEL[a.arm])
    f = dict(issue=a.issue, arm=a.arm, pr=a.pr, ended=a.ended, verdict=a.verdict,
             review_min=a.review_min, counter_exhausted=a.counter_exhausted, still_fixable=a.still_fixable)

    end = None
    if a.pr:
        pr = _gh("pr", "view", str(a.pr), "--repo", REPO, "--json", "createdAt,closedAt,mergedAt,commits")
        end = pr["mergedAt"] or pr["closedAt"]
        f["label_to_pr_min"] = minutes(start, pr["createdAt"])
        f["label_to_verdict_min"] = minutes(start, end) if end else ""
    if a.arm == "A":
        task = json.load(open(a.task_json))
        st = task.get("status", {})
        f["review_rounds"], f["fix_runs"] = st.get("reviewRounds", 0), st.get("fixRuns", 0)
        window = minutes(start, end or datetime.utcnow().isoformat() + "Z") + 15
        q = urllib.parse.urlencode({"query": vm_query([r["id"] for r in st.get("runs", [])], window),
                                    **({"time": end} if end else {})})
        with urllib.request.urlopen(f"{a.vm_url.rstrip('/')}/api/v1/query?{q}") as resp:
            tin, cached, out = vm_tokens(json.load(resp))
        f.update(tokens_in=tin, tokens_cached=cached, tokens_out=out, usd=glm_usd(tin, cached, out))
    else:
        tin, cached, out, cost = exec_log_usage(open(a.exec_log).read())
        # Arm C's log prices GLM tokens as Claude; recompute at GLM's list.
        f.update(tokens_in=tin, tokens_cached=cached, tokens_out=out,
                 usd=round(cost, 4) if a.arm == "B" else glm_usd(tin, cached, out),
                 review_rounds=0, fix_runs=commits_after(pr["commits"], pr["createdAt"]) if a.pr else "")

    row = build_row(**f)
    new = not os.path.exists(a.out) or os.path.getsize(a.out) == 0
    with open(a.out, "a", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=COLUMNS)
        if new:
            w.writeheader()
        w.writerow(row)
    print(json.dumps(row))


if __name__ == "__main__":
    sys.exit(main())
```

- [ ] **Step 4: Run the test to see it pass**

Run: `chmod +x scripts/ops/github/cohort-row.py && python3 scripts/ci/tests/test-cohort-row.py`
Expected: `PASS: cohort-row`

- [ ] **Step 5: Run the suite**

Run: `bash scripts/ci/tests/run.sh 2>&1 | tail -3`
Expected: no `FAIL` line; `test-cohort-row` among the passes.

- [ ] **Step 6: Commit**

```bash
git add scripts/ops/github/cohort-row.py scripts/ci/tests/test-cohort-row.py
git commit -m "✨ feat(scripts): cohort-row.py builds the v2 cohort's sheet rows"
```

---

### Task 3: Arms B and C

**Files:**
- Create: `.github/workflows/cohort-arms.yaml`
- Test: `scripts/ci/tests/test-cohort-arms.py`

**Interfaces:**
- Consumes: labels `cohort/arm-b`, `cohort/arm-c` (Task 1); repository secrets
  `COHORT_ARM_B_API_KEY`, `COHORT_ARM_C_API_KEY` (Task 6).
- Produces: per run, a PR from `cohort/arm-<b|c>/<issue>` with `Cohort-Arm: <B|C>` in its body, and
  an artifact `cohort-arm-<b|c>-<issue>` holding the execution file (read by Task 2's `--exec-log`).

- [ ] **Step 1: Write the failing test**

```python
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
text = f.read_text()
if re.search(r"(sk-ant-|api_key:\s*['\"]?[A-Za-z0-9])", text):
    fails.append("a key literal is in the workflow")
if "${{ github.event.issue.body }}" in text:
    fails.append("the issue body must not be interpolated: the agent reads it with gh")
if fails:
    print("FAIL\n  " + "\n  ".join(fails))
    sys.exit(1)
print("PASS: cohort-arms")
```

- [ ] **Step 2: Run it to see it fail**

Run: `python3 scripts/ci/tests/test-cohort-arms.py`
Expected: FAIL, `FileNotFoundError` on `cohort-arms.yaml`.

- [ ] **Step 3: Write the workflow**

```yaml
---
# v2 hard-task cohort, arms B and C (docs/superpowers/specs/2026-10-12-v2-hard-task-cohort-design.md §3).
# TEMPORARY: deleted when the cohort ends. Started only by the maintainer's label on an issue, never
# by PR code, so check-workflow-secrets.sh (pull_request workflows) does not apply.
name: Cohort arms 🧪

on:
  issues:
    types: [labeled]

permissions: {}

jobs:
  arm-b:
    name: Arm B (Claude Code Action, Claude)
    if: github.event.sender.login == 'Smana' && github.event.label.name == 'cohort/arm-b'
    runs-on: ubuntu-latest
    timeout-minutes: 90
    concurrency:
      group: cohort-arm-b
      cancel-in-progress: false
    permissions:
      contents: write
      pull-requests: write
      issues: write
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7
        with:
          fetch-depth: 0
      - uses: jdx/mise-action@2d8d4cafcbd33be2ea37d2b6f5ad595363d1f1ca # v5
      - id: claude
        uses: anthropics/claude-code-action@1d6de8cb0c237e7c15e9e1bdf973826ebae490cc # v1
        with:
          anthropic_api_key: ${{ secrets.COHORT_ARM_B_API_KEY }}
          github_token: ${{ secrets.GITHUB_TOKEN }}
          prompt: |
            Resolve issue #${{ github.event.issue.number }} of ${{ github.repository }}.
            Read it with `gh issue view ${{ github.event.issue.number }}`; its acceptance criteria are the target.
            Work on a new branch `cohort/arm-b/${{ github.event.issue.number }}` from `main`.
            Run `task check` and fix what it reports before every push.
            Open one pull request with `gh pr create --base main`; its body must contain
            `Closes #${{ github.event.issue.number }}` and a line `Cohort-Arm: B`. Never merge.
          claude_args: |
            --allowedTools "Bash(gh:*),Bash(git:*),Bash(task:*),Bash(mise:*),Edit,Write,Read,Glob,Grep"
      - if: always()
        uses: actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a # v7
        with:
          name: cohort-arm-b-${{ github.event.issue.number }}
          path: ${{ steps.claude.outputs.execution_file }}
          retention-days: 90

  arm-c:
    name: Arm C (Claude Code Action, GLM-5.3)
    if: github.event.sender.login == 'Smana' && github.event.label.name == 'cohort/arm-c'
    runs-on: ubuntu-latest
    timeout-minutes: 90
    concurrency:
      group: cohort-arm-c
      cancel-in-progress: false
    permissions:
      contents: write
      pull-requests: write
      issues: write
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7
        with:
          fetch-depth: 0
      - uses: jdx/mise-action@2d8d4cafcbd33be2ea37d2b6f5ad595363d1f1ca # v5
      - id: claude
        uses: anthropics/claude-code-action@1d6de8cb0c237e7c15e9e1bdf973826ebae490cc # v1
        env:
          # Z.ai's Anthropic-compatible endpoint: same harness as arm B, arm A's model.
          ANTHROPIC_BASE_URL: https://api.z.ai/api/anthropic
        with:
          anthropic_api_key: ${{ secrets.COHORT_ARM_C_API_KEY }}
          github_token: ${{ secrets.GITHUB_TOKEN }}
          prompt: |
            Resolve issue #${{ github.event.issue.number }} of ${{ github.repository }}.
            Read it with `gh issue view ${{ github.event.issue.number }}`; its acceptance criteria are the target.
            Work on a new branch `cohort/arm-c/${{ github.event.issue.number }}` from `main`.
            Run `task check` and fix what it reports before every push.
            Open one pull request with `gh pr create --base main`; its body must contain
            `Closes #${{ github.event.issue.number }}` and a line `Cohort-Arm: C`. Never merge.
          claude_args: |
            --model glm-5.3
            --allowedTools "Bash(gh:*),Bash(git:*),Bash(task:*),Bash(mise:*),Edit,Write,Read,Glob,Grep"
      - if: always()
        uses: actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a # v7
        with:
          name: cohort-arm-c-${{ github.event.issue.number }}
          path: ${{ steps.claude.outputs.execution_file }}
          retention-days: 90
```

- [ ] **Step 4: Run the test and the linters**

Run: `python3 scripts/ci/tests/test-cohort-arms.py && actionlint .github/workflows/cohort-arms.yaml && ./scripts/ci/check-workflow-secrets.sh`
Expected: `PASS: cohort-arms`, no actionlint output, the secrets check exits 0.

- [ ] **Step 5: Commit (maintainer: gate path)**

```bash
git add .github/workflows/cohort-arms.yaml scripts/ci/tests/test-cohort-arms.py
git commit -m "👷 ci: temporary workflow for the v2 cohort's arms B and C"
```

---

### Task 4: The sheet

**Files:**
- Create: `docs/superpowers/specs/2026-10-12-v2-hard-task-cohort-results.csv`

- [ ] **Step 1: Write the header from the collector's columns**

Run:

```bash
python3 -c 'import importlib.util as u; s=u.spec_from_file_location("c","scripts/ops/github/cohort-row.py"); m=u.module_from_spec(s); s.loader.exec_module(m); print(",".join(m.COLUMNS))' > docs/superpowers/specs/2026-10-12-v2-hard-task-cohort-results.csv
cat docs/superpowers/specs/2026-10-12-v2-hard-task-cohort-results.csv
```

Expected: `issue,arm,pr,tokens_in,tokens_cached,tokens_out,usd,label_to_pr_min,label_to_verdict_min,review_rounds,fix_runs,ended,counter_exhausted,still_fixable,verdict,review_min`

- [ ] **Step 2: Commit**

```bash
git add docs/superpowers/specs/2026-10-12-v2-hard-task-cohort-results.csv
git commit -m "📝 docs(agents): the v2 cohort's results sheet, header only"
```

---

### Task 5: The nine new issues

**Interfaces:**
- Produces: issue numbers for list rows 7–15, recorded in the spec's §2 table.

- [ ] **Step 1: Check the dashboards' metrics exist on aws-0**

```bash
VM="https://vm.$(kubectl -n flux-system get cm eks-aws-0-vars -o jsonpath='{.data.private_domain_name}')"
for re in 'crossplane_.*' 'certmanager_.*' 'vault_.*' 'externalsecret_.*'; do
  n=$(curl -sG "$VM/api/v1/query" --data-urlencode "query=count(count by (__name__) ({__name__=~\"$re\"}))" | jq -r '.data.result[0].value[1] // "0"')
  echo "$re $n"
done
```

Expected: a non-zero count for each. A zero means the component is not scraped: skip that
dashboard issue and take the next reserve (spec §2).

- [ ] **Step 2: Create the five test issues**

For each `(script, path)` in `sweep-lb-orphans scripts/ops/gcp`, `reclaim-csi-volumes scripts/ops/k8s`,
`purge-dns-records scripts/ops/gcp`, `sweep-controller-orphans scripts/ops/aws`,
`helm-release-present scripts/provision`, run:

```bash
gh issue create --repo Smana/cloud-native-ref --title "tests: cover $script.sh" --body "$(cat <<EOF
\`$path/$script.sh\` has no test. Add \`scripts/ci/tests/test-$script.sh\`, run by \`scripts/ci/tests/run.sh\`.

## Acceptance criteria
- Every cloud and cluster CLI the script calls is stubbed on \`PATH\` (the pattern in
  \`scripts/ci/tests/test-adopt-custom-roles.sh\`); the test needs no credentials or network.
- It covers the dry run, the \`--apply\` path where the script has one, and each refusal or guard
  the script's header describes.
- It fails if the script's destructive call is removed or its guard is bypassed (check by editing
  the script locally, then reverting).
- \`bash scripts/ci/tests/run.sh\` passes and the script itself is unchanged, unless the test exposes
  a bug, which the PR then fixes and names.
EOF
)"
```

Expected: five issue URLs.

- [ ] **Step 3: Create the four dashboard issues**

For each `(component, prefix, namespace)` in `Crossplane crossplane_ infrastructure/base/crossplane`,
`cert-manager certmanager_ security/base/cert-manager`, `OpenBao vault_ security/base/openbao`,
`"External Secrets" externalsecret_ security/base/external-secrets` (check each directory exists
with `ls`; use the directory that holds the component's HelmRelease if it differs), run:

```bash
gh issue create --repo Smana/cloud-native-ref --title "dashboards: a $component dashboard" --body "$(cat <<EOF
$component has no Grafana dashboard. Add a \`GrafanaDashboard\` beside its manifests under \`$dir\`.

## Acceptance criteria
- Shape and conventions as \`infrastructure/base/cloudnative-pg\`'s dashboard: the grafana-operator
  CRD, \`\$\${datasource}\` escaping for Flux substitution, the folder the other platform dashboards use.
- Every panel queries only \`$prefix*\` metrics that VictoriaMetrics holds on aws-0 today; no panel
  is empty over the last 24 h.
- Panels answer: is it healthy, is it doing work, is anything failing or about to (expiry,
  sealed state, sync errors, as fits the component).
- \`./scripts/ci/validate-manifests.sh\` passes.
EOF
)"
```

Expected: four issue URLs.

- [ ] **Step 4: Record the numbers in the spec**

Replace rows 7–15's "new" source with the issue numbers, e.g. `#2401: Tests for …`.

- [ ] **Step 5: Commit**

```bash
git add docs/superpowers/specs/2026-10-12-v2-hard-task-cohort-design.md
git commit -m "📝 docs(agents): the cohort's new issues, numbered"
```

---

### Task 6: Keys, wallet, and the pilot (maintainer)

- [ ] **Step 1: Keys and limits.** Create one Anthropic Console key for arm B, in its own workspace
  with a $50 spend limit, and one Z.ai open-platform key for arm C on the account that holds the
  platform's Z.ai key (Z.ai has no per-key limit; C is capped by hand, Task 7). Store
  both in OpenBao (`bao kv put platform/cohort arm_b=… arm_c=…`) for the record, then:

```bash
gh secret set COHORT_ARM_B_API_KEY --repo Smana/cloud-native-ref
gh secret set COHORT_ARM_C_API_KEY --repo Smana/cloud-native-ref
```

- [ ] **Step 2: Top up the Z.ai API wallet $100**: A's and C's shares combined, since both keys
  draw from the account's one wallet (the coding plan does not cover the API; error 1113 = empty
  wallet).

- [ ] **Step 3: Pilot issue.** Create a throwaway issue fixing a typo in a comment of a file under
  `scripts/` (a real one; a wording slip in a comment will do), so the
  pilot exercises the `scripts` class. Then apply `factory/ready` + `class:scripts`, `cohort/arm-b`,
  `cohort/arm-c` at once.

- [ ] **Step 4: Check every arm.**
  - Arm A: `kubectl get tasks.agents.ogenki.io -A -o json | jq '.items[] | select(.spec.issue==<N>) | {phase: .status.phase, template: .spec.template, runs: [.status.runs[].id]}'`
    shows `pair`, and the meter answers for its runs:
    `curl -sG "$VM/api/v1/query" --data-urlencode 'query=count(gen_ai_client_token_usage_sum{ar_agent=~".*xplane-run-<first run id>"})'`
    is non-zero. If zero, find the run's ServiceAccount (`kubectl -n agents get sa | grep <id>`)
    and fix `vm_query`'s pattern, with its test, before going on. Save that Task for step 5:
    `kubectl -n <namespace> get tasks.agents.ogenki.io <name> -o json > taskA.json`, with the name
    and namespace from the same `jq` projection (add `name: .metadata.name, ns: .metadata.namespace`).
  - Arms B and C: each opens a PR with `Cohort-Arm:` in its body. A PR opened with `GITHUB_TOKEN`
    starts no `pull_request` CI: close and reopen it to start CI (`createdAt` is unchanged, so the
    timings hold). The artifact downloads with
    `gh run download <run-id> -n cohort-arm-b-<N> -D cohort-arm-b-<N>` (and `cohort-arm-c-<N>`), so
    step 5's `--exec-log cohort-arm-b-<N>/<file>` resolves.
  - Both arms run with `CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=1`: the run log shows the agent's
    `gh issue view` and `gh pr create` succeeding, i.e. `gh` still authenticates with it set. If it
    does not, stop and fix the workflow before the cohort.
  - On arm B's log, compare the two token sources the collector chooses between:
    `jq 'if type == "array" then .[] else . end | select(.type == "result") | {usage, modelUsage}' cohort-arm-b-<N>/<file>`.
    `modelUsage` summed (what `cohort-row.py` records when present) should be at least `usage`;
    more means subagents ran, which `usage` alone would have missed.

- [ ] **Step 5: Collect the three pilot rows into a scratch file and check every column fills**

```bash
python3 scripts/ops/github/cohort-row.py --issue <N> --arm A --pr <prA> --task-json taskA.json --vm-url "$VM" --ended pr --verdict merged-as-is --review-min 2 --out /tmp/pilot.csv
python3 scripts/ops/github/cohort-row.py --issue <N> --arm B --pr <prB> --exec-log cohort-arm-b-<N>/<file> --ended pr --verdict rejected-fixable --review-min 1 --out /tmp/pilot.csv
python3 scripts/ops/github/cohort-row.py --issue <N> --arm C --pr <prC> --exec-log cohort-arm-c-<N>/<file> --ended pr --verdict rejected-fixable --review-min 1 --out /tmp/pilot.csv
```

Expected: three rows, no empty token or `usd` column. Merge one pilot PR, close the others.
Pilot rows are discarded.

---

### Task 7: Run the cohort (maintainer, one issue at a time)

For each issue in spec §2's order. Every factory class is `shadow: true` for the cohort's duration
(Task 8, step 4 reverts it), so arm A's PR is never auto-merged before your verdict.

- [ ] Before labelling a backlog issue, check its label history for an earlier `factory/ready`:
  `gh api repos/Smana/cloud-native-ref/issues/<n>/events --jq '.[] | select(.event == "labeled") | [.label.name, .created_at]'`.
  If one is there, note it: `label_time` takes the first event, so arm A's minutes would start then.
- [ ] Apply at once: `factory/ready` + `class:<class>`, `cohort/arm-b`, `cohort/arm-c`.
- [ ] Wait for each arm to end: a PR, an escalation (`needsYou`), a timeout or a budget stop.
- [ ] When a B or C PR opens, close and reopen it: a PR opened with `GITHUB_TOKEN` starts no
  `pull_request` CI otherwise. `createdAt` is unchanged, so the timings hold.
- [ ] Read arm C's spend on Z.ai's per-key usage page; at $50, stop labelling `cohort/arm-c` and
  record C's remaining tasks as `budget-exhausted`. An error 1113 is the shared wallet empty: record
  A's and C's remaining tasks as `budget-exhausted`, not as a factory failure.
- [ ] Review every PR. **Record each verdict and your minutes before choosing which to merge.**
- [ ] For an arm A escalation: note which counter ran out (`reviewRounds` 2, `fixRuns` 2,
  `resumes` 2) and whether the PR was still fixable.
- [ ] Merge the best accepted PR; close the others with a comment naming their verdict.
- [ ] Append three rows with `cohort-row.py` (Task 6, step 5 commands, `--out` the results CSV).
  A B or C run that timed out uploads no execution file: run without `--exec-log`, then backfill the
  empty `tokens_*` and `usd` cells by editing the CSV, from the provider console (Anthropic or Z.ai
  usage for that arm's key, over that run's time window).
- [ ] Commit the CSV: `git commit -m "📝 docs(agents): cohort rows for #<N>"`.

---

### Task 8: Results and close-out

- [ ] **Step 1: Compute the decision inputs**

```bash
python3 - <<'EOF'
import csv, collections
rows = list(csv.DictReader(open("docs/superpowers/specs/2026-10-12-v2-hard-task-cohort-results.csv")))
acc = collections.Counter(r["arm"] for r in rows if r["verdict"] in ("merged-as-is", "merged-after-edits"))
usd = collections.defaultdict(float)
for r in rows: usd[r["arm"]] += float(r["usd"] or 0)
fixable = sum(1 for r in rows if r["arm"] == "A" and r["counter_exhausted"] and r["still_fixable"] == "yes")
for arm in "ABC":
    print(arm, "accepted", acc[arm], "usd", round(usd[arm], 2), "usd/accepted", round(usd[arm] / acc[arm], 2) if acc[arm] else "n/a")
print("A escalations with a counter out on a fixable PR:", fixable)
EOF
```

- [ ] **Step 2: Append a `## Results` section to the spec** applying each rule of spec §6 to these
  numbers, one row per question, and stating the sample's limit.

- [ ] **Step 3: Update the status page's cohort row** (`website/content/docs/platform/ai-platform/status.md`)
  with the outcome and a link to the results section.

- [ ] **Step 4: Close-out (maintainer)**: delete `.github/workflows/cohort-arms.yaml` and
  `scripts/ci/tests/test-cohort-arms.py`; `gh secret delete COHORT_ARM_B_API_KEY` and `…_C_…`;
  revoke both keys; restore `controlPercent: 10` and its original comment; set `docs`, `tests`,
  `dashboards` and `scripts` back to `{}` and drop their shadow comment; remove `refs/heads/cohort/**`
  and `refs/heads/cohort/*/*` (a ruleset `**` matches one segment) from the `agent-branches`
  ruleset's exclude list, added 2026-10-14 so the arms' `GITHUB_TOKEN` can
  push `cohort/arm-*/<N>` (`gh api repos/Smana/cloud-native-ref/rulesets/24063626`); turn "Allow
  GitHub Actions to create and approve pull requests" back off, enabled 2026-10-14 so the arms open
  their PRs with `GITHUB_TOKEN` (`gh api -X PUT repos/Smana/cloud-native-ref/actions/permissions/workflow
  -f default_workflow_permissions=read -F can_approve_pull_request_reviews=false`).

- [ ] **Step 5: Validate and commit**

Run: `./scripts/ci/validate-links.sh && ./scripts/ci/validate-manifests.sh && bash scripts/ci/tests/run.sh`
Expected: all exit 0.

```bash
git commit -am "📝 docs(agents): v2 cohort results; close out its arms"
```
