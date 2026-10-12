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
