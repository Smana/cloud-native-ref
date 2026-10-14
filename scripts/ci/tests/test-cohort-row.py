#!/usr/bin/env python3
# requires: python3
"""cohort-row.py: the v2 cohort's sheet rows (spec §5). Functions, then main() with gh and the network stubbed."""
import importlib.util
import contextlib
import csv
import io
import json
import os
import pathlib
import tempfile
import urllib.parse
import ssl
import urllib.request
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
# Subagents on other model slots: modelUsage sums every model; usage alone covers the main loop.
multi = {**result, "modelUsage": {
    "glm-5.3": {"inputTokens": 1000, "outputTokens": 700, "cacheReadInputTokens": 40000,
                "cacheCreationInputTokens": 2000, "costUSD": 0.3},
    "glm-4.7-air": {"inputTokens": 500, "outputTokens": 300, "cacheReadInputTokens": 10000,
                    "cacheCreationInputTokens": 1000, "costUSD": 0.1}}}
check("exec log modelUsage", cr.exec_log_usage(json.dumps([multi])), (54500, 50000, 1000, 0.4211))
check("exec log empty modelUsage", cr.exec_log_usage(json.dumps([{**result, "modelUsage": {}}])),
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
def commit(date, login="github-actions[bot]", headline="fix: x"):
    return {"committedDate": date, "authors": [{"login": login}], "messageHeadline": headline}


commits = [commit("2026-10-13T08:20:00Z"), commit("2026-10-13T08:40:00Z"), commit("2026-10-13T09:10:00Z"),
           commit("2026-10-13T09:20:00Z", login="Smana"),
           commit("2026-10-13T09:25:00Z", headline="Merge branch 'main' into cohort/arm-b/7"),
           {**commit("2026-10-13T09:26:00Z", headline="sync"), "parents": [{"oid": "a"}, {"oid": "b"}]}]
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

check("concat arrays", cr.concat_json_arrays('[{"a":1}]\n [{"a":2},{"a":3}]  []\n'), [{"a": 1}, {"a": 2}, {"a": 3}])
check("concat empty", cr.concat_json_arrays(""), [])

# main(): arm A then arm B appended to one CSV, gh and the network stubbed.
EVENTS = [{"event": "labeled", "label": {"name": "factory/ready"}, "created_at": "2026-10-13T08:00:00Z"},
          {"event": "labeled", "label": {"name": "cohort/arm-b"}, "created_at": "2026-10-13T08:00:00Z"}]
PR = {"createdAt": "2026-10-13T08:20:00Z", "closedAt": None, "mergedAt": "2026-10-13T09:30:00Z",
      "commits": [commit("2026-10-13T08:10:00Z"), commit("2026-10-13T08:40:00Z"), commit("2026-10-13T09:00:00Z"),
                  commit("2026-10-13T09:05:00Z", login="Smana")]}
queries = []


def fake_gh_text(*args):
    if args[0] == "api":  # two pages, as --paginate prints them
        return json.dumps(EVENTS[:1]) + "\n" + json.dumps(EVENTS[1:])
    return json.dumps(PR)


class FakeResp(io.BytesIO):
    def __enter__(self):
        return self

    def __exit__(self, *a):
        return False


def fake_urlopen(url, context=None):
    queries.append(url)
    contexts.append(context)
    return FakeResp(json.dumps(resp).encode())


def run_main(argv):
    old = sys.argv
    sys.argv = ["cohort-row.py", *argv]
    try:
        with contextlib.redirect_stdout(io.StringIO()):
            return cr.main()
    finally:
        sys.argv = old


# The private root CA has no keyUsage (#2350): drop only the strict flag, keep chain + hostname checks.
ctx = cr.tls_context()
check("tls verify_mode", ctx.verify_mode, ssl.CERT_REQUIRED)
check("tls check_hostname", ctx.check_hostname, True)
check("tls strict flag dropped", bool(ctx.verify_flags & ssl.VERIFY_X509_STRICT), False)
check("tls other flags kept", ctx.verify_flags | ssl.VERIFY_X509_STRICT,
      ssl.create_default_context().verify_flags | ssl.VERIFY_X509_STRICT)

contexts = []
cr._gh_text = fake_gh_text
urllib.request.urlopen = fake_urlopen
with tempfile.TemporaryDirectory() as d:
    out = os.path.join(d, "sheet.csv")
    task = os.path.join(d, "task.json")
    log = os.path.join(d, "exec.json")
    with open(task, "w") as fh:
        json.dump({"status": {"reviewRounds": 1, "fixRuns": 2, "runs": [{"id": "impl-1"}, {"id": "rev-1"}]}}, fh)
    with open(log, "w") as fh:
        fh.write(array)
    run_main(["--issue", "7", "--arm", "A", "--pr", "2400", "--task-json", task, "--vm-url", "http://vm:8428/",
              "--ended", "pr", "--verdict", "merged-as-is", "--review-min", "12", "--out", out])
    run_main(["--issue", "8", "--arm", "B", "--pr", "2400", "--exec-log", log, "--ended", "pr", "--out", out])
    # A timed-out run uploads no execution file: the row is still written, cost cells left for backfill.
    run_main(["--issue", "8", "--arm", "B", "--pr", "2400", "--ended", "timeout", "--out", out])
    with open(out) as fh:
        text = fh.read()
    check("header once", text.count("issue,arm,pr"), 1)
    rows = list(csv.DictReader(io.StringIO(text)))
    check("row count", len(rows), 3)
    a_row, b_row, t_row = rows
    check("A tokens", (a_row["tokens_in"], a_row["tokens_cached"], a_row["tokens_out"]), ("600000", "500000", "20000"))
    check("A usd", a_row["usd"], str(cr.glm_usd(600000, 500000, 20000)))
    check("A minutes", (a_row["label_to_pr_min"], a_row["label_to_verdict_min"]), ("20", "90"))
    check("A rounds/fixes", (a_row["review_rounds"], a_row["fix_runs"]), ("1", "2"))
    check("A verdict", (a_row["verdict"], a_row["review_min"]), ("merged-as-is", "12"))
    check("B tokens/usd", (b_row["tokens_in"], b_row["tokens_out"], b_row["usd"]), ("54200", "800", "0.4211"))
    check("B rounds/fixes", (b_row["review_rounds"], b_row["fix_runs"]), ("0", "2"))
    check("timeout cost cells", tuple(t_row[c] for c in ("tokens_in", "tokens_cached", "tokens_out", "usd")),
          ("", "", "", ""))
    check("timeout ended/fixes", (t_row["ended"], t_row["fix_runs"]), ("timeout", "2"))
    check("VM query uses tls_context", [type(c) for c in contexts], [ssl.SSLContext])
    qs = urllib.parse.unquote_plus(queries[0]) if queries else ""
    if "xplane-run-(impl-1|rev-1)" not in qs:
        fails.append(f"VM query lacks both run ids: {qs}")
    if "[105m]" not in qs:  # 90 min label to merge, plus 15
        fails.append(f"VM query window is not 105m: {qs}")

    with open(task, "w") as fh:
        json.dump({"status": {"runs": []}}, fh)
    try:
        run_main(["--issue", "9", "--arm", "A", "--task-json", task, "--vm-url", "http://vm", "--ended", "pr", "--out", out])
        fails.append("empty runs: no SystemExit")
    except SystemExit as e:
        if "no status.runs" not in str(e):
            fails.append(f"empty runs: wrong message {e}")
    for bad in (["--ended", "done"], ["--ended", "pr", "--verdict", "lgtm"]):
        try:
            with contextlib.redirect_stderr(io.StringIO()):
                run_main(["--issue", "9", "--arm", "B", "--exec-log", log, "--out", out, *bad])
            fails.append(f"argparse accepted {bad}")
        except SystemExit:
            pass

if fails:
    print("FAIL\n  " + "\n  ".join(fails))
    sys.exit(1)
print("PASS: cohort-row")
