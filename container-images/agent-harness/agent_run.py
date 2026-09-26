#!/agent-server/.venv/bin/python
"""agent-run: the harness entrypoint of an AgentRun sandbox (SP1 design, section 5).

Five steps: start agent-server, POST the conversation, wait for it to end,
revoke the GitHub token, exit 0 or 1. Nothing here is a control (design
section 4): every rule it passes to the agent is enforced outside the sandbox.
"""
import json
import os
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


def main() -> int:
    signal.signal(signal.SIGTERM, _on_sigterm)
    env = dict(os.environ)
    server = subprocess.Popen(SERVER_CMD)
    try:
        wait_ready()
        clone(env)
        with open(env["TASK_FILE"]) as t, open(env["RULES_FILE"]) as r:
            request = build_request(env, t.read(), r.read())
        conversation = http("POST", "/api/conversations", request)
        cid = conversation["id"]
        while True:
            code = outcome(http("GET", "/api/conversations/" + cid).get("execution_status", ""))
            if code is not None:
                return code
            time.sleep(15)
    finally:
        subprocess.run(["/usr/local/bin/git-credential-agent", "revoke"], check=False)
        server.terminate()


if __name__ == "__main__":
    sys.exit(main())
