#!/usr/bin/env python3
"""One row of the v2 hard-task cohort sheet (ai-native-ref docs/superpowers/specs/2026-10-12-v2-hard-task-cohort-design.md §5).

Fetches what it can (gh, the Task, the gateway meter, the action's execution log) and takes the
maintainer's judgements as flags. Appends to the CSV; never rewrites earlier rows.
"""
import argparse
import csv
import json
import os
import ssl
import subprocess
import sys
import urllib.parse
import urllib.request
from datetime import datetime, timezone

COLUMNS = ["issue", "arm", "pr", "tokens_in", "tokens_cached", "tokens_out", "usd",
           "label_to_pr_min", "label_to_verdict_min", "review_rounds", "fix_runs", "ended",
           "counter_exhausted", "still_fixable", "verdict", "review_min"]
VERDICTS = {"merged-as-is", "merged-after-edits", "rejected-fixable", "rejected-wrong", ""}
ENDED = {"pr", "escalated", "timeout", "budget-exhausted", "no-pr"}
ARM_LABEL = {"A": "factory/ready", "B": "cohort/arm-b", "C": "cohort/arm-c"}
# USD per 1M. 1.40 in, 4.40 out: vmrule-llm-gateway.yaml. 0.26 cached: Z.ai list price; the gateway's
# VMRule prices input and output only.
GLM = {"in": 1.40, "cached": 0.26, "out": 4.40}
REPO = "Smana/cloud-native-ref"
MAINTAINER = "Smana"


def tls_context():
    # Python >=3.13 sets VERIFY_X509_STRICT, which rejects the private root CA for lacking keyUsage
    # (#2350). Drop only that flag; chain and hostname verification stay on.
    ctx = ssl.create_default_context()
    ctx.verify_flags &= ~ssl.VERIFY_X509_STRICT
    return ctx


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
    cost = float(r.get("total_cost_usd", 0.0))
    # `usage` covers the main loop only; `modelUsage` adds subagents on other model slots.
    models = [m for m in (r.get("modelUsage") or {}).values() if "inputTokens" in m or "outputTokens" in m]
    if models:
        cached = sum(m.get("cacheReadInputTokens", 0) for m in models)
        tokens_in = sum(m.get("inputTokens", 0) + m.get("cacheCreationInputTokens", 0) for m in models) + cached
        return tokens_in, cached, sum(m.get("outputTokens", 0) for m in models), cost
    u = r.get("usage", {})
    cached = u.get("cache_read_input_tokens", 0)
    # Anthropic's input_tokens excludes both cache counters.
    tokens_in = u.get("input_tokens", 0) + u.get("cache_creation_input_tokens", 0) + cached
    return tokens_in, cached, u.get("output_tokens", 0), cost


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
    # Fix runs are the agent's own pushes: not the maintainer's edits, not merges of main.
    def counts(c):
        merge = len(c.get("parents") or []) > 1 or c.get("messageHeadline", "").startswith("Merge ")
        return not merge and MAINTAINER not in {a.get("login") for a in c.get("authors", [])}
    return sum(1 for c in commits if _ts(c["committedDate"]) > _ts(since) and counts(c))


def build_row(**fields):
    if fields.get("verdict", "") not in VERDICTS:
        raise ValueError(f"verdict {fields['verdict']!r} not in {sorted(VERDICTS - {''})}")
    if fields.get("ended") not in ENDED:
        raise ValueError(f"ended {fields.get('ended')!r} not in {sorted(ENDED)}")
    return {c: "" if fields.get(c) is None else str(fields.get(c, "")) for c in COLUMNS}


def concat_json_arrays(text):
    # `gh api --paginate` (without --slurp, which needs gh >= 2.48) prints one array per page.
    dec, i, out = json.JSONDecoder(), 0, []
    while True:
        while i < len(text) and text[i].isspace():
            i += 1
        if i >= len(text):
            return out
        page, i = dec.raw_decode(text, i)
        out.extend(page)


def _gh_text(*args):
    return subprocess.run(["gh", *args], check=True, capture_output=True, text=True).stdout


def _gh(*args):
    return json.loads(_gh_text(*args))


def main():
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("--issue", type=int, required=True)
    p.add_argument("--arm", choices="ABC", required=True)
    p.add_argument("--pr", type=int)
    p.add_argument("--task-json", help="arm A: kubectl get tasks.agents.ogenki.io -o json, one Task")
    p.add_argument("--vm-url", help="arm A: VictoriaMetrics base URL")
    p.add_argument("--exec-log", help="arms B, C: the action's execution file; absent after a timeout")
    p.add_argument("--ended", required=True, choices=sorted(ENDED))
    p.add_argument("--verdict", default="", choices=sorted(VERDICTS - {""}))
    p.add_argument("--review-min", default="")
    p.add_argument("--counter-exhausted", default="")
    p.add_argument("--still-fixable", default="")
    p.add_argument("--out", required=True)
    a = p.parse_args()

    task = None
    if a.arm == "A":
        with open(a.task_json) as fh:
            task = json.load(fh)
        if not task.get("status", {}).get("runs"):
            raise SystemExit("task has no status.runs: nothing to meter, refusing to record 0 tokens")

    events = concat_json_arrays(_gh_text("api", "--paginate", f"repos/{REPO}/issues/{a.issue}/events"))
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
        st = task["status"]
        f["review_rounds"], f["fix_runs"] = st.get("reviewRounds", 0), st.get("fixRuns", 0)
        window = minutes(start, end or datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")) + 15
        q = urllib.parse.urlencode({"query": vm_query([r["id"] for r in st.get("runs", [])], window),
                                    **({"time": end} if end else {})})
        with urllib.request.urlopen(f"{a.vm_url.rstrip('/')}/api/v1/query?{q}", context=tls_context()) as resp:
            tin, cached, out = vm_tokens(json.load(resp))
        f.update(tokens_in=tin, tokens_cached=cached, tokens_out=out, usd=glm_usd(tin, cached, out))
    else:
        f.update(review_rounds=0, fix_runs=commits_after(pr["commits"], pr["createdAt"]) if a.pr else "")
        if a.exec_log:  # else cost cells stay empty, backfilled from the provider console
            with open(a.exec_log) as fh:
                tin, cached, out, cost = exec_log_usage(fh.read())
            # Arm C's log prices GLM tokens as Claude; recompute at GLM's list.
            f.update(tokens_in=tin, tokens_cached=cached, tokens_out=out,
                     usd=round(cost, 4) if a.arm == "B" else glm_usd(tin, cached, out))

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
