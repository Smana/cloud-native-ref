"""agent-run's contract with agent-server 1.49.5, checked against the SDK's own models.

Needs the openhands SDK, so it runs inside the image: docker build --target test.
"""
import http.server
import json
import os
import signal
import subprocess
import sys
import tempfile
import threading
import time
import unittest

HERE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
sys.path.insert(0, HERE)
import agent_run  # noqa: E402

ENV = {
    "MODEL": "agent-default",
    "LLM_BASE_URL": "http://127.0.0.1:4000/v1",
    "MCP_URL": "http://127.0.0.1:4000/mcp",
    "CONVERSATION_ID": "0b3c6f0e-5d1a-4b8e-9f41-2a7c3e9d8b10",
}


class BuildRequestTest(unittest.TestCase):
    def setUp(self):
        self.body = agent_run.build_request(ENV, "fix the link", "rules text")

    def test_model_goes_through_the_proxy_with_a_placeholder_key(self):
        llm = self.body["agent"]["llm"]
        self.assertEqual(llm["model"], "openai/agent-default")
        self.assertEqual(llm["base_url"], "http://127.0.0.1:4000/v1")
        self.assertEqual(llm.get("api_key"), agent_run.PLACEHOLDER_KEY, "litellm refuses to call without a key")
        self.assertEqual(llm["num_retries"], 0, "a budget 429 is terminal")

    def test_mcp_task_and_rules_are_wired(self):
        self.assertEqual(self.body["agent"]["mcp_config"]["platform"]["url"], "http://127.0.0.1:4000/mcp")
        self.assertEqual(self.body["initial_message"]["content"][0]["text"], "fix the link")
        self.assertTrue(self.body["initial_message"]["run"])
        self.assertEqual(self.body["agent_launch_additions"]["system_message_suffix_append"], "rules text")
        self.assertEqual(self.body["conversation_id"], ENV["CONVERSATION_ID"])
        self.assertEqual(self.body["workspace"]["working_dir"], "/workspace/repo")


class OutcomeTest(unittest.TestCase):
    def test_terminal_statuses(self):
        self.assertEqual(agent_run.outcome("finished"), 0)
        self.assertEqual(agent_run.outcome("error"), 1)
        self.assertEqual(agent_run.outcome("stuck"), 1)
        self.assertIsNone(agent_run.outcome("running"))
        self.assertIsNone(agent_run.outcome("waiting_for_confirmation"))


class AgentServerTest(unittest.TestCase):
    def test_stays_on_loopback(self):
        cmd = agent_run.SERVER_CMD
        self.assertEqual(cmd[cmd.index("--host") + 1], "127.0.0.1", "its API is unauthenticated (P13)")


class GitHub(http.server.BaseHTTPRequestHandler):
    revoked = []

    def do_DELETE(self):
        GitHub.revoked.append((self.path, self.headers.get("Authorization")))
        self.send_response(204)
        self.end_headers()

    def log_message(self, *args):
        pass


class SigtermTest(unittest.TestCase):
    """Deleting the pod must still revoke the run's token and stop agent-server."""

    def test_sigterm_runs_the_cleanup(self):
        github = http.server.HTTPServer(("127.0.0.1", 0), GitHub)
        threading.Thread(target=github.serve_forever, daemon=True).start()
        self.addCleanup(github.server_close)
        self.addCleanup(github.shutdown)
        tmp = tempfile.mkdtemp()
        cache, started, stopped = (os.path.join(tmp, n) for n in ("token.json", "started", "stopped"))
        with open(cache, "w") as f:
            json.dump({"token": "ghs_run", "expires_at": time.time() + 3600}, f)
        # A stand-in agent-server that never answers /ready, so the driver is
        # still waiting when the signal lands, and that records being stopped.
        stand_in = (
            "import signal, sys, time\n"
            "signal.signal(signal.SIGTERM, lambda *_: (open(sys.argv[2], 'w').close(), sys.exit(0)))\n"
            "open(sys.argv[1], 'w').close()\n"
            "time.sleep(60)\n"
        )
        driver = subprocess.Popen(
            [sys.executable, "-c",
             "import sys, agent_run\n"
             "agent_run.AGENT_SERVER = 'http://127.0.0.1:1'\n"
             "agent_run.SERVER_CMD = [sys.executable, '-c', sys.argv[1], sys.argv[2], sys.argv[3]]\n"
             "sys.exit(agent_run.main())\n",
             stand_in, started, stopped],
            cwd=HERE,
            env={**os.environ, "GIT_TOKEN_CACHE": cache, "GITHUB_API": "http://127.0.0.1:%d" % github.server_port},
        )
        self.addCleanup(lambda: driver.poll() is None and driver.kill())
        deadline = time.monotonic() + 30
        while not os.path.exists(started) and time.monotonic() < deadline:
            time.sleep(0.1)
        self.assertTrue(os.path.exists(started), "the driver never started agent-server")

        driver.send_signal(signal.SIGTERM)
        driver.wait(timeout=30)

        self.assertEqual(GitHub.revoked, [("/installation/token", "Bearer ghs_run")])
        self.assertFalse(os.path.exists(cache))
        deadline = time.monotonic() + 10
        while not os.path.exists(stopped) and time.monotonic() < deadline:
            time.sleep(0.1)
        self.assertTrue(os.path.exists(stopped), "agent-server was left running")


if __name__ == "__main__":
    unittest.main()
