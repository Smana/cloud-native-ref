#!/agent-server/.venv/bin/python
"""agent-run: the harness entrypoint of an AgentRun sandbox (SP1 design, section 5).

Five steps: start agent-server, POST the conversation, wait for it to end,
revoke the GitHub token, exit 0 or 1. On SIGTERM it first pauses the agent,
checkpoints an implementer's work to its branch and lets the room-bridge read
the log to its end, each step boxed inside 15 s (disruption design §2). Nothing
here is a control (design section 4): every rule it passes to the agent is
enforced outside the sandbox.
"""
import json
import os
import re
import secrets
import signal
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request
import uuid

AGENT_SERVER = "http://127.0.0.1:8000"
# Loopback only (plan P13): the API is unauthenticated, and agent-server
# itself switches to 0.0.0.0 by default once a session key is set.
SERVER_CMD = ["/agent-server/.venv/bin/python", "-m", "openhands.agent_server", "--host", "127.0.0.1", "--port", "8000"]
REPO_DIR = "/workspace/repo"
# agent-server's start-up hook (F29, see site/sitecustomize.py), beside this file in /opt/agent.
SITE_DIR = os.path.join(os.path.dirname(os.path.realpath(__file__)), "site")
TERMINAL_OK = {"finished"}
TERMINAL_FAIL = {"error", "stuck"}
# The model key is a placeholder: identity-proxy overwrites Authorization (S5).
PLACEHOLDER_KEY = "injected-by-identity-proxy"
POLL_INTERVAL_S = 15
# USD per 1M tokens, set on the LLM so the SDK prices calls itself instead of
# asking litellm, which does not know the `agent-default` alias and warns on
# every call. The defaults mirror GLM-5.3 behind agent-default; the gateway's
# table (infrastructure/base/llm-gateway/vmrule-llm-gateway.yaml) stays the
# source of truth, and LLM_*_USD_PER_MTOK override these.
DEFAULT_INPUT_USD_PER_MTOK = "1.40"
DEFAULT_OUTPUT_USD_PER_MTOK = "4.40"
# A blip in the loopback connection to agent-server shouldn't fail the run;
# a run that's actually gone stays gone, so this still fails fast.
MAX_POLL_ERRORS = 5
# The run's installation token as git-credential-agent caches it (T3), and every GitHub
# token shape. An injected agent can print its token into a command or its final message,
# and these lines reach VictoriaLogs, so both are redacted before any print.
TOKEN_CACHE = os.environ.get("GIT_TOKEN_CACHE", "/run/agent/git/token.json")
GITHUB_TOKEN = re.compile(r"gh[posu]_[A-Za-z0-9_]{20,}")
REDACTED = "[REDACTED:github-token]"


def redact(text: str) -> str:
    try:
        with open(TOKEN_CACHE) as f:
            cached = json.load(f).get("token")
    except (OSError, ValueError, AttributeError):
        cached = None
    if cached:
        text = text.replace(cached, REDACTED)
    return GITHUB_TOKEN.sub(REDACTED, text)


# A W3C traceparent from the factory's task span (SP3 R46), handed over by the composition.
TRACEPARENT = re.compile(r"^00-([0-9a-f]{32})-([0-9a-f]{16})-[0-9a-f]{2}$")
# agent-server exports on a 5 s batch and nothing at exit, and its root span ends only when
# the conversation closes (observability plan, Task 0.5): a 1 s batch, a close, then a wait.
BSP_DELAY_MS = "1000"
FLUSH_WAIT_S = 2
# The shutdown budget (disruption design §2): a GKE preemptible VM gives a regular pod 15 s, fixed.
# Each box is an upper bound; a step that overruns is abandoned, never waited for. The five sum to
# 14 s, so the revoke is done a second before that SIGKILL; the root span's export gets the last one.
PAUSE_S, CHECKPOINT_S, FINAL_READ_S, STOP_S, REVOKE_S = 1, 7, 3, 2, 1
EXPORT_S = 1
# What a checkpoint commits is whatever the agent left in the tree, pushed with no one looking: a
# GitHub token, or more than an agent's work plausibly is, refuses it.
CHECKPOINT_MAX_FILES, CHECKPOINT_MAX_BYTES = 200, 5 << 20
# The commit hook turns CHECKPOINT_ENV into the trailer "Agent-Checkpoint: disruption" beside
# Agent-Run, so a resumed run and its reviewers tell the platform's commit from the agent's.
CHECKPOINT_SUBJECT = "chore(agent): checkpoint, the sandbox is stopping"
CHECKPOINT_ENV = {"AGENT_CHECKPOINT": "disruption"}


def start_run_span(env: dict, exporter=None):
    """The run's root span and the env that makes agent-server's root span its child.

    Parented on TRACEPARENT when it is a valid W3C header, a fresh trace otherwise (the
    `task agent:run` path). (None, None, {}) when tracing is off or cannot start. The trace id
    is correlation only: the collector stamps the run id from the connection (observability
    plan O22).
    """
    endpoint = env.get("OTEL_EXPORTER_OTLP_ENDPOINT")
    if not endpoint and exporter is None:
        return None, None, {}
    try:
        from opentelemetry import trace
        from opentelemetry.sdk.trace import TracerProvider
        from opentelemetry.sdk.trace.export import SimpleSpanProcessor

        if exporter is None:
            from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter
            # The root span exports after the revoke; a collector that drops packets must
            # not hold the pod past its grace period.
            exporter = OTLPSpanExporter(endpoint=endpoint.rstrip("/") + "/v1/traces", timeout=5)
        provider = TracerProvider()
        provider.add_span_processor(SimpleSpanProcessor(exporter))
        parent = None
        m = TRACEPARENT.match(env.get("TRACEPARENT", ""))
        if m:
            # Always sampled, whatever the trigger's flags: lmnr's span context has
            # no flags field, so agent-server's spans export regardless, and an unsampled trigger
            # would leave them under a harness span that never lands. The factory samples 100%.
            remote = trace.SpanContext(int(m[1], 16), int(m[2], 16), is_remote=True,
                                       trace_flags=trace.TraceFlags(trace.TraceFlags.SAMPLED))
            parent = trace.set_span_in_context(trace.NonRecordingSpan(remote))
        span = provider.get_tracer("agent-run").start_span("agent-run", context=parent)
    except Exception as exc:  # noqa: BLE001 -- tracing must never fail the run
        print("agent-run: tracing off: %s" % exc, file=sys.stderr, flush=True)
        return None, None, {}
    sc = span.get_span_context()
    # lmnr's LaminarSpanContext: UUID-shaped ids; agent-server's spans parent on it.
    ctx = {"trace_id": str(uuid.UUID(int=sc.trace_id)), "span_id": str(uuid.UUID(int=sc.span_id)), "is_remote": True}
    return span, provider, {"LMNR_SPAN_CONTEXT": json.dumps(ctx), "OTEL_BSP_SCHEDULE_DELAY": BSP_DELAY_MS}


def close_conversation(cid: str) -> None:
    """Close the conversation, which ends the SDK's root span, and let the 1 s batch export it."""
    try:
        # Bounded: closing a running conversation first waits out its in-flight LLM call.
        http("DELETE", "/api/conversations/" + cid, timeout=5)
    except Exception as exc:  # noqa: BLE001 -- tracing must never fail the run
        print("agent-run: conversation not closed: %s" % exc, file=sys.stderr, flush=True)
    time.sleep(FLUSH_WAIT_S)


def build_request(env: dict, task: str, rules: str) -> dict:
    """The StartConversationRequest body, as plain JSON."""
    from openhands.sdk import LLM
    from openhands.sdk.conversation.request import StartConversationRequest
    from openhands.tools.preset.default import get_default_agent

    llm = LLM(
        model="openai/" + env["MODEL"],
        base_url=env["LLM_BASE_URL"],
        api_key=PLACEHOLDER_KEY,
        usage_id="agent",
        # A budget 429 is terminal (design section 5); never retry it.
        num_retries=0,
        input_cost_per_token=float(env.get("LLM_INPUT_USD_PER_MTOK", DEFAULT_INPUT_USD_PER_MTOK)) / 1e6,
        output_cost_per_token=float(env.get("LLM_OUTPUT_USD_PER_MTOK", DEFAULT_OUTPUT_USD_PER_MTOK)) / 1e6,
        # Sent in the body because litellm drops reasoning_effort for a model it does not
        # know (`agent-default`), even with capability_overrides. Unsent, GLM-5.3 falls back
        # to maximum thinking: measured 150 s and 1,238 reasoning tokens for a reply that
        # takes 10.8 s at "high", so every step took minutes and some hit the 300 s timeout.
        litellm_extra_body={"reasoning_effort": env.get("LLM_REASONING_EFFORT", "high")},
    )
    # The SDK redacts secrets on dump and drops the redacted value on load, so
    # without this the key never reaches agent-server and litellm refuses to
    # call. Safe to expose: it is the placeholder above.
    plain = {"expose_secrets": True}
    agent = get_default_agent(llm=llm, cli_mode=True).model_dump(mode="json", context=plain)
    agent["mcp_config"] = {"platform": {"url": env["MCP_URL"], "transport": "http"}}
    request = StartConversationRequest.model_validate({
        "conversation_id": env.get("CONVERSATION_ID") or str(uuid.uuid4()),
        "workspace": {"working_dir": REPO_DIR},
        "agent": agent,
        "initial_message": {"role": "user", "content": [{"type": "text", "text": task}], "run": True},
        "agent_launch_additions": {"system_message_suffix_append": rules},
        "max_iterations": 500,
        # Each auto-title is an extra model call that spends the run's budget.
        "autotitle": False,
    })
    return json.loads(request.model_dump_json(exclude_none=True, context=plain))


def http(method: str, path: str, body: dict | None = None, timeout: int = 30) -> dict:
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(AGENT_SERVER + path, data=data, method=method, headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return json.loads(resp.read() or b"{}")


def wait_ready(deadline_s: int = 120) -> None:
    end = time.monotonic() + deadline_s
    while time.monotonic() < end:
        try:
            urllib.request.urlopen(AGENT_SERVER + "/ready", timeout=2)
            return
        except (urllib.error.URLError, OSError):
            time.sleep(1)
    raise TimeoutError("agent-server never became ready")


def outcome(status: str) -> int | None:
    """0 on success, 1 on failure, None while the conversation runs."""
    if status in TERMINAL_OK:
        return 0
    if status in TERMINAL_FAIL:
        return 1
    return None


def poll(cid: str, on_tick=None) -> int:
    """Poll the conversation until it reaches a terminal status, tolerating
    up to MAX_POLL_ERRORS consecutive network errors so one slow or dropped
    connection to the loopback agent-server doesn't fail the run. on_tick runs
    after every successful poll."""
    status = ""
    errors = 0
    while True:
        try:
            status = http("GET", "/api/conversations/" + cid).get("execution_status", "")
        except (urllib.error.URLError, TimeoutError) as exc:
            errors += 1
            if errors > MAX_POLL_ERRORS:
                print("agent-run: giving up after %d consecutive poll errors: %s" % (errors, exc), file=sys.stderr)
                return 1
            time.sleep(POLL_INTERVAL_S)
            continue
        errors = 0
        if on_tick:
            on_tick()
        code = outcome(status)
        if code is not None:
            print("agent-run: conversation ended with execution_status=%s" % status, file=sys.stderr)
            return code
        time.sleep(POLL_INTERVAL_S)


def _text(message: dict | None) -> str:
    content = (message or {}).get("content") or []
    return " ".join(c.get("text", "") for c in content if c.get("type") == "text").strip()


def _short(value, limit: int) -> str:
    # Redact before truncating, so a token cut at the limit is still whole when matched.
    text = " ".join(redact(str(value or "")).split())
    return text if len(text) <= limit else text[: limit - 1] + "…"


class StepLog:
    """Prints each new agent step to stdout, one line each, so `kubectl logs -c
    harness` shows what the agent is doing, and VictoriaLogs keeps it after the
    pod is gone. The final agent message is printed in full: for a read-only
    role it is the report. Actions are printed, their outputs never are. Best
    effort: a failure here is logged and never fails the run. Agent-written
    text is redacted first."""

    def __init__(self, cid: str, trace_id: str = ""):
        self.cid = cid
        self.trace_id = trace_id
        self.page = None
        self.seen = set()
        self.steps = 0
        self.last_message = ""

    def __call__(self) -> None:
        try:
            page = self.page
            while True:
                path = "/api/conversations/%s/events/search?limit=100" % self.cid
                body = http("GET", path + ("&page_id=" + page if page else ""))
                for event in body.get("items") or []:
                    if event.get("id") in self.seen:
                        continue
                    self.seen.add(event.get("id"))
                    line = self.describe(event)
                    if line:
                        print(line, flush=True)
                nxt = body.get("next_page_id")
                if not nxt:
                    break
                # Resume from the last page next tick: at most one page is re-read.
                self.page = page = nxt
        except Exception as exc:  # noqa: BLE001 -- logging must never fail the run
            print("agent-run: step log unavailable: %s" % exc, file=sys.stderr, flush=True)

    def describe(self, event: dict) -> str | None:
        kind = event.get("kind")
        if kind == "ActionEvent":
            self.steps += 1
            action = event.get("action") or {}
            target = action.get("command") or action.get("path") or ""
            tool = event.get("tool_name") or action.get("kind")
            line = "agent-run step %d: %s | %s | %s" % (self.steps, tool, _short(event.get("summary"), 120), _short(target, 200))
            # Correlation only (O22): links the line to its trace in Grafana, attributes nothing.
            return line + (" | trace_id=" + self.trace_id if self.trace_id else "")
        if kind == "MessageEvent" and event.get("source") == "agent":
            self.last_message = redact(_text(event.get("llm_message")))
            return "agent-run message: " + _short(self.last_message, 400)
        if kind in ("ConversationErrorEvent", "AgentErrorEvent"):
            return "agent-run error: %s %s" % (event.get("code") or kind, _short(event.get("detail") or event.get("error"), 400))
        return None

    def summary(self) -> None:
        print("agent-run summary: %d steps" % self.steps, flush=True)
        if self.last_message:
            print("agent-run final message:\n" + self.last_message[:8000], flush=True)


def _verified(ref: str) -> bool:
    return subprocess.run(["git", "-C", REPO_DIR, "rev-parse", "--verify", "--quiet", ref], capture_output=True).returncode == 0


def clone(env: dict) -> None:
    subprocess.run(["git", "clone", "--no-tags", "https://github.com/" + env["REPOSITORY"] + ".git", REPO_DIR], check=True)
    # Resume the run's branch when an earlier run of the same task pushed it (R7).
    if _verified("origin/" + env["BRANCH"]):
        start = "origin/" + env["BRANCH"]
    elif _verified("origin/" + env["BASE_REF"]):
        start = "origin/" + env["BASE_REF"]
    else:
        start = env["BASE_REF"]  # a commit
    subprocess.run(["git", "-C", REPO_DIR, "checkout", "-B", env["BRANCH"], start], check=True)


def report(name: str, status: str, started: float, box: float) -> None:
    """One line per shutdown step: the 15 s budget is measured from these under gVisor."""
    print("agent-run shutdown %s %s in %.2fs (box %ss)" % (name, status, time.monotonic() - started, box),
          file=sys.stderr, flush=True)


def timed(name: str, box: float, step) -> bool:
    """Runs one shutdown step for at most box seconds (disruption design §2). A step that overruns
    is left behind in its thread, never waited for, so no step can hold up the next. True when it
    is done."""
    out = {}

    def run():
        try:
            out["done"] = step()
        except Exception as exc:  # noqa: BLE001 -- a failed step never stops the next
            out["error"] = exc

    started = time.monotonic()
    worker = threading.Thread(target=run, daemon=True)
    worker.start()
    worker.join(box)
    if worker.is_alive():
        status = "overrun"
    elif "error" in out:
        status = "failed: " + _short(out["error"], 200)
    else:
        status = "done" + (": " + _short(out["done"], 200) if out.get("done") else "")
    report(name, status, started, box)
    return status.startswith("done")


def pause(cid: str) -> None:
    """Stops new tool calls, so the work tree stops changing. /interrupt, not /pause: /pause waits
    out the in-flight LLM call, /interrupt cancels it (agent-server 1.49.6)."""
    http("POST", "/api/conversations/%s/interrupt" % cid, timeout=PAUSE_S)


def _unfit(git) -> str | None:
    """Why the staged tree must not be committed, or None. Never quotes what it found."""
    listed = git("diff", "--cached", "--name-only", "-z")
    if listed.returncode:
        return "git diff failed"
    names = listed.stdout.split("\0")[:-1]
    if len(names) > CHECKPOINT_MAX_FILES:
        return "%d files staged" % len(names)
    paths = [os.path.join(REPO_DIR, n) for n in names]
    size = sum(os.lstat(p).st_size for p in paths if os.path.lexists(p))
    if size > CHECKPOINT_MAX_BYTES:
        return "%d bytes staged" % size
    # --text so a binary file is searched too; what textconv or an external diff shows may differ.
    diff = git("diff", "--cached", "--text", "--irreversible-delete", "--no-textconv", "--no-ext-diff")
    if diff.returncode:
        return "git diff failed"
    return "a GitHub token is staged" if redact(diff.stdout) != diff.stdout else None


def checkpoint(env: dict, deadline: float) -> str:
    """Commits what the agent left uncommitted (.gitignore applies) and pushes the branch when it
    holds a commit origin lacks (disruption design §2). Implementer only: no other role can push.
    git-credential-agent re-exchanges through identity-proxy, a sidecar that outlives the harness.
    A refused checkpoint still pushes the agent's own commits."""
    def git(*args, env=None):
        left = deadline - time.monotonic()
        if left <= 0:
            raise TimeoutError("no time left for git " + args[0])
        return subprocess.run(["git", "-C", REPO_DIR, *args], capture_output=True, text=True, errors="replace",
                              timeout=left, env=env)

    git("add", "-A")
    staged = git("diff", "--cached", "--quiet").returncode == 1
    unfit = _unfit(git) if staged else None
    committed = staged and not unfit
    if committed:
        done = git("commit", "-q", "-m", CHECKPOINT_SUBJECT, env={**os.environ, **CHECKPOINT_ENV})
        if done.returncode:
            raise RuntimeError("commit refused: " + done.stderr.strip())
    refused = "checkpoint refused (%s), " % unfit if unfit else ""
    if not git("rev-list", "-1", "HEAD", "--not", "--remotes=origin").stdout.strip():
        return refused + "nothing to push"
    pushed = git("push", "-q", "origin", "HEAD:refs/heads/" + env["BRANCH"])
    if pushed.returncode:
        raise RuntimeError("push refused: " + pushed.stderr.strip())
    return refused + ("pushed a checkpoint commit" if committed else "pushed")


def final_read(env: dict, steps=None) -> str:
    """The room's last read of the harness log (F11, the harness half): the bridge reads the log to
    its end and mirrors it before it answers, while agent-server is still up. On SIGTERM the step
    log flushes beside it: both read agent-server."""
    flush = threading.Thread(target=steps, daemon=True) if steps else None
    if flush:
        flush.start()
    answer = ""
    url = env.get("BRIDGE_URL")
    if url:
        req = urllib.request.Request(url.rstrip("/") + "/final-read", data=b"", method="POST")
        with urllib.request.urlopen(req, timeout=FINAL_READ_S) as resp:
            answer = resp.read(512).decode(errors="replace").strip()
    if flush:
        flush.join()
    return answer


def stop(server, timeout: float) -> str:
    """Stops agent-server within timeout, killed for its last second. Always before the revoke: a
    live agent-server could mint a fresh token between the revoke and its own exit."""
    server.terminate()
    try:
        server.wait(timeout - 1)
        return "stopped"
    except subprocess.TimeoutExpired:
        server.kill()
    try:
        server.wait(1)
        return "killed"
    except subprocess.TimeoutExpired:
        # SIGKILL runs nothing more in the process, reaped or not.
        return "killed, not yet reaped"


def revoke() -> None:
    """Revokes the run's GitHub token in-process: a second Python start-up under gVisor can take
    longer than the revoke's 1 s box. The helper sits beside this file in /opt/agent, whatever
    symlink started it."""
    sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))
    import git_credential_agent

    git_credential_agent.revoke()


def disrupted(env: dict, cid: str, steps) -> None:
    """The first half of a cut-short run's shutdown (disruption design §2): pause the agent, then
    checkpoint its work (implementer only), then let the room read the log to its end. main's
    finally then stops agent-server and revokes the token."""
    timed("pause", PAUSE_S, lambda: pause(cid))
    if env.get("ROLE") == "implementer":
        timed("checkpoint", CHECKPOINT_S, lambda: checkpoint(env, time.monotonic() + CHECKPOINT_S))
    timed("final-read", FINAL_READ_S, lambda: final_read(env, steps))
    if steps:
        steps.summary()


def _on_sigterm(signum, frame):
    # Python's default SIGTERM exits without running `finally`, so deleting
    # the pod would leave the GitHub token live and agent-server running.
    raise SystemExit(128 + signum)


def server_env(env: dict) -> dict:
    """agent-server's environment, with an OH_SECRET_KEY made for this pod when unset.

    The key encrypts the secrets and MCP OAuth state agent-server stores. A run
    is single-use, so a per-pod key loses nothing and nothing is seeded by hand.
    """
    out = dict(env)
    out.setdefault("OH_SECRET_KEY", secrets.token_urlsafe(32))
    out["PYTHONPATH"] = os.pathsep.join(p for p in (SITE_DIR, env.get("PYTHONPATH")) if p)
    return out


def main() -> int:
    signal.signal(signal.SIGTERM, _on_sigterm)
    env = dict(os.environ)
    # agent-server's conversations_path and bash_events_dir are relative to
    # its cwd; pin it to "/" so its state lands in the intended paths
    # whatever workingDir the pod sets, rather than wherever agent-run itself
    # happens to be launched from.
    span, provider, trace_env = start_run_span(env)
    trace_id = format(span.get_span_context().trace_id, "032x") if span else ""
    server = subprocess.Popen(SERVER_CMD, cwd="/", env=server_env({**env, **trace_env}))
    cid, steps, code, signalled, read = None, None, None, False, False
    try:
        wait_ready()
        clone(env)
        with open(env["TASK_FILE"]) as t, open(env["RULES_FILE"]) as r:
            request = build_request(env, t.read(), r.read())
        cid = http("POST", "/api/conversations", request)["id"]
        steps = StepLog(cid, trace_id)
        code = poll(cid, on_tick=steps)
        steps()
        steps.summary()
        if env.get("BRIDGE_URL"):
            read = timed("final-read", FINAL_READ_S, lambda: final_read(env))
        # Never on SIGTERM: the close can outlast the grace period and the revoke must not wait.
        if span:
            close_conversation(cid)
        return code
    except SystemExit:
        signalled = True
        if code is None:
            raise
        # C1: the run had ended. The composition reads this exit code, and 143 would make a
        # finished run look disrupted, which the factory resumes.
        return code
    finally:
        # A second SIGTERM during cleanup must not abort the revoke.
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        if signalled and cid and code is None:
            disrupted(env, cid, steps)
        elif signalled and code is not None and env.get("BRIDGE_URL") and not read:
            # Exit 0 latches the run Succeeded at once, and the broker takes the bridge's writes only
            # while the run is live: the bridge's own flush may come too late, so this read is the
            # room's last. Nothing is paused or checkpointed on this path, which leaves it time.
            timed("final-read", FINAL_READ_S, lambda: final_read(env))
        if signalled:
            started = time.monotonic()
            report("stop", "done: " + stop(server, STOP_S), started, STOP_S)
            timed("revoke", REVOKE_S, revoke)
        else:
            stop(server, 10)
            # Boxed too, never to bound it (its urlopen gives up at 10 s) but so that a revoke
            # that raises in-process is logged instead of changing the run's exit code.
            timed("revoke", 15, revoke)
        if span:
            # Boxed on the signal path: a collector that never answers holds an export for up to two
            # 5 s connects, and the pod's grace has no room left for it after the revoke.
            end = threading.Thread(target=lambda: (span.end(), provider.shutdown()), daemon=True)
            end.start()
            end.join(EXPORT_S if signalled else None)

if __name__ == "__main__":
    sys.exit(main())
