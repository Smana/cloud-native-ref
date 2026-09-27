#!/agent-server/.venv/bin/python
"""agent-run: the harness entrypoint of an AgentRun sandbox (SP1 design, section 5).

Five steps: start agent-server, POST the conversation, wait for it to end,
revoke the GitHub token, exit 0 or 1. Nothing here is a control (design
section 4): every rule it passes to the agent is enforced outside the sandbox.
"""
import json
import os
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
    text = " ".join(str(value or "").split())
    return text if len(text) <= limit else text[: limit - 1] + "…"


class StepLog:
    """Prints each new agent step to stdout, one line each, so `kubectl logs -c
    harness` shows what the agent is doing, and VictoriaLogs keeps it after the
    pod is gone. The final agent message is printed in full: for a read-only
    role it is the report. Actions are printed, their outputs never are. Best
    effort: a failure here is logged and never fails the run."""

    def __init__(self, cid: str):
        self.cid = cid
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
            return "agent-run step %d: %s | %s | %s" % (self.steps, tool, _short(event.get("summary"), 120), _short(target, 200))
        if kind == "MessageEvent" and event.get("source") == "agent":
            self.last_message = _text(event.get("llm_message"))
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
    server = subprocess.Popen(SERVER_CMD, cwd="/", env=server_env(env))
    try:
        wait_ready()
        clone(env)
        with open(env["TASK_FILE"]) as t, open(env["RULES_FILE"]) as r:
            request = build_request(env, t.read(), r.read())
        conversation = http("POST", "/api/conversations", request)
        steps = StepLog(conversation["id"])
        try:
            return poll(conversation["id"], on_tick=steps)
        finally:
            steps()
            steps.summary()
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


if __name__ == "__main__":
    sys.exit(main())
