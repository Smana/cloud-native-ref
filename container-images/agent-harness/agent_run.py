#!/agent-server/.venv/bin/python
"""agent-run: the harness entrypoint of an AgentRun sandbox (SP1 design, section 5).

Five steps: start agent-server, POST the conversation, wait for it to end,
revoke the GitHub token, exit 0 or 1. Nothing here is a control (design
section 4): every rule it passes to the agent is enforced outside the sandbox.
"""
import json
import os
import re
import secrets
import signal
import subprocess
import sys
import time
import urllib.error
import urllib.request
import uuid

AGENT_SERVER = "http://127.0.0.1:8000"
# Loopback only (plan P13): the API is unauthenticated, and agent-server
# itself switches to 0.0.0.0 by default once a session key is set.
SERVER_CMD = ["/agent-server/.venv/bin/python", "-m", "openhands.agent_server", "--host", "127.0.0.1", "--port", "8000"]
REPO_DIR = "/workspace/repo"
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
    try:
        wait_ready()
        clone(env)
        with open(env["TASK_FILE"]) as t, open(env["RULES_FILE"]) as r:
            request = build_request(env, t.read(), r.read())
        conversation = http("POST", "/api/conversations", request)
        steps = StepLog(conversation["id"], trace_id)
        try:
            code = poll(conversation["id"], on_tick=steps)
        finally:
            steps()
            steps.summary()
        # Never on SIGTERM: the close can outlast the grace period and the revoke must not wait.
        if span:
            close_conversation(conversation["id"])
        return code
    finally:
        # A second SIGTERM during cleanup must not abort the revoke, and
        # agent-server must be stopped BEFORE the token is revoked so it
        # cannot mint a fresh one between the revoke and its own exit.
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        server.terminate()
        try:
            server.wait(10)
        except subprocess.TimeoutExpired:
            server.kill()
        subprocess.run(["/usr/local/bin/git-credential-agent", "revoke"], check=False)
        if span:
            span.end()
            provider.shutdown()


if __name__ == "__main__":
    sys.exit(main())
