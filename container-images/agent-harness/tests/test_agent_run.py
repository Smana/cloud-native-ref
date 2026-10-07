"""agent-run's contract with agent-server 1.49.6, checked against the SDK's own models.

Needs the openhands SDK, so it runs inside the image: docker build --target test.
"""
import http.server
import io
import json
import os
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest
import urllib.error
import uuid
from unittest import mock

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

    def test_calls_are_priced_without_a_litellm_lookup(self):
        llm = self.body["agent"]["llm"]
        self.assertAlmostEqual(llm["input_cost_per_token"], 1.40e-6)
        self.assertAlmostEqual(llm["output_cost_per_token"], 4.40e-6)

    def test_prices_can_be_overridden(self):
        env = {**ENV, "LLM_INPUT_USD_PER_MTOK": "2", "LLM_OUTPUT_USD_PER_MTOK": "8"}
        llm = agent_run.build_request(env, "t", "r")["agent"]["llm"]
        self.assertAlmostEqual(llm["input_cost_per_token"], 2e-6)
        self.assertAlmostEqual(llm["output_cost_per_token"], 8e-6)

    def test_reasoning_effort_is_sent_in_the_body(self):
        self.assertEqual(self.body["agent"]["llm"]["litellm_extra_body"], {"reasoning_effort": "high"})
        env = {**ENV, "LLM_REASONING_EFFORT": "low"}
        self.assertEqual(agent_run.build_request(env, "t", "r")["agent"]["llm"]["litellm_extra_body"], {"reasoning_effort": "low"})

    def test_reasoning_effort_reaches_the_wire(self):
        # The regression that cost minutes per step: litellm silently dropped it.
        from openhands.sdk import LLM, Message, TextContent

        bodies = []

        class OpenAI(http.server.BaseHTTPRequestHandler):
            def do_POST(self):
                bodies.append(json.loads(self.rfile.read(int(self.headers["content-length"]))))
                out = json.dumps({"id": "x", "object": "chat.completion", "created": 0, "model": "m",
                                  "choices": [{"index": 0, "finish_reason": "stop", "message": {"role": "assistant", "content": "ok"}}],
                                  "usage": {"prompt_tokens": 1, "completion_tokens": 1, "total_tokens": 2}}).encode()
                self.send_response(200)
                self.send_header("content-type", "application/json")
                self.send_header("content-length", str(len(out)))
                self.end_headers()
                self.wfile.write(out)

            def log_message(self, *args):
                pass

        server = http.server.HTTPServer(("127.0.0.1", 0), OpenAI)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        self.addCleanup(server.shutdown)
        spec = dict(self.body["agent"]["llm"], base_url="http://127.0.0.1:%d/v1" % server.server_port)
        LLM.model_validate(spec).completion(messages=[Message(role="user", content=[TextContent(text="hi")])])
        self.assertEqual(bodies[-1].get("reasoning_effort"), "high")

    def test_autotitle_is_disabled(self):
        # Each auto-title is an extra model call that spends the run's budget.
        self.assertFalse(self.body["autotitle"])


class ServerEnvTest(unittest.TestCase):
    def test_secret_key_is_made_per_pod_when_unset(self):
        key = agent_run.server_env({})["OH_SECRET_KEY"]
        self.assertGreaterEqual(len(key), 32)
        self.assertNotEqual(key, agent_run.server_env({})["OH_SECRET_KEY"])

    def test_a_set_secret_key_is_kept(self):
        self.assertEqual(agent_run.server_env({"OH_SECRET_KEY": "given"})["OH_SECRET_KEY"], "given")  # pragma: allowlist secret


class OutcomeTest(unittest.TestCase):
    def test_terminal_statuses(self):
        from openhands.sdk.conversation.state import ConversationExecutionStatus as Status

        self.assertEqual(agent_run.outcome(Status.FINISHED.value), 0)
        self.assertEqual(agent_run.outcome(Status.ERROR.value), 1)
        self.assertEqual(agent_run.outcome(Status.STUCK.value), 1)
        self.assertIsNone(agent_run.outcome(Status.RUNNING.value))
        self.assertIsNone(agent_run.outcome(Status.WAITING_FOR_CONFIRMATION.value))


class AgentServerTest(unittest.TestCase):
    def test_stays_on_loopback(self):
        cmd = agent_run.SERVER_CMD
        self.assertEqual(cmd[cmd.index("--host") + 1], "127.0.0.1", "its API is unauthenticated (P13)")

    def test_starts_from_the_filesystem_root(self):
        # agent-server's conversations_path and bash_events_dir are relative
        # to its cwd; pin it to "/" so they land in the intended paths no
        # matter what workingDir the pod sets.
        with mock.patch("agent_run.subprocess.Popen", side_effect=RuntimeError("stop")) as popen:
            with self.assertRaises(RuntimeError):
                agent_run.main()
        self.assertEqual(popen.call_args.kwargs.get("cwd"), "/")


class PollTest(unittest.TestCase):
    def test_tolerates_up_to_five_consecutive_poll_errors(self):
        from openhands.sdk.conversation.state import ConversationExecutionStatus as Status

        calls = {"n": 0}

        def flaky(method, path, body=None, timeout=30):
            calls["n"] += 1
            if calls["n"] <= 5:
                raise TimeoutError("simulated")
            return {"execution_status": Status.FINISHED.value}

        with mock.patch("agent_run.http", side_effect=flaky), mock.patch("agent_run.time.sleep"):
            self.assertEqual(agent_run.poll("cid"), 0)
        self.assertEqual(calls["n"], 6, "5 tolerated errors, then the successful poll")

    def test_gives_up_after_six_consecutive_poll_errors(self):
        calls = {"n": 0}

        def always_fails(method, path, body=None, timeout=30):
            calls["n"] += 1
            raise urllib.error.URLError("simulated")

        with mock.patch("agent_run.http", side_effect=always_fails), mock.patch("agent_run.time.sleep"):
            self.assertEqual(agent_run.poll("cid"), 1)
        self.assertEqual(calls["n"], 6)


class PollTickTest(unittest.TestCase):
    def test_on_tick_runs_after_each_successful_poll(self):
        from openhands.sdk.conversation.state import ConversationExecutionStatus as Status

        statuses = iter([Status.RUNNING.value, Status.RUNNING.value, Status.FINISHED.value])
        ticks = []
        with mock.patch("agent_run.http", side_effect=lambda *a, **k: {"execution_status": next(statuses)}), \
                mock.patch("agent_run.time.sleep"):
            self.assertEqual(agent_run.poll("cid", on_tick=lambda: ticks.append(1)), 0)
        self.assertEqual(len(ticks), 3)


class StepLogTest(unittest.TestCase):
    EVENTS = [
        {"id": "1", "kind": "SystemPromptEvent", "source": "agent"},
        {"id": "2", "kind": "ActionEvent", "tool_name": "terminal", "summary": "View repo state", "action": {"command": "git status"}},
        {"id": "3", "kind": "ObservationEvent", "observation": {"content": "SECRET-LOOKING OUTPUT"}},
        {"id": "4", "kind": "MessageEvent", "source": "agent", "llm_message": {"content": [{"type": "text", "text": "Done: fixed the note."}]}},
        {"id": "5", "kind": "ConversationErrorEvent", "code": "AttributeError", "detail": "boom"},
    ]

    def tick(self, log, side_effect):
        with mock.patch("agent_run.http", side_effect=side_effect), mock.patch("sys.stdout", new=io.StringIO()) as out:
            log()
        return out.getvalue()

    def test_prints_actions_messages_and_errors_never_outputs(self):
        log = agent_run.StepLog("cid")
        out = self.tick(log, [{"items": self.EVENTS, "next_page_id": None}])
        self.assertIn("agent-run step 1: terminal | View repo state | git status", out)
        self.assertIn("agent-run message: Done: fixed the note.", out)
        self.assertIn("agent-run error: AttributeError boom", out)
        self.assertNotIn("SECRET-LOOKING OUTPUT", out, "observations (command outputs) are never printed")
        self.assertNotIn("SystemPrompt", out)

    def test_each_event_is_printed_once(self):
        log = agent_run.StepLog("cid")
        page = {"items": self.EVENTS, "next_page_id": None}
        self.tick(log, [page])
        self.assertEqual(self.tick(log, [page]), "")

    def test_follows_pages_and_resumes_from_the_last_one(self):
        log = agent_run.StepLog("cid")
        paths = []

        def get(method, path, body=None, timeout=30):
            paths.append(path)
            if "page_id=p2" in path:
                return {"items": [self.EVENTS[3]], "next_page_id": None}
            return {"items": [self.EVENTS[1]], "next_page_id": "p2"}

        out = self.tick(log, get)
        self.assertIn("step 1", out)
        self.assertIn("Done: fixed the note.", out)
        self.assertEqual(log.page, "p2")
        self.tick(log, get)
        self.assertTrue(paths[-1].endswith("&page_id=p2"), "the next tick starts from the last page")

    def test_a_failure_never_raises(self):
        log = agent_run.StepLog("cid")
        with mock.patch("sys.stderr", new=io.StringIO()) as err:
            self.tick(log, urllib.error.URLError("down"))
        self.assertIn("step log unavailable", err.getvalue())

    def test_summary_prints_the_final_message_in_full(self):
        log = agent_run.StepLog("cid")
        self.tick(log, [{"items": self.EVENTS, "next_page_id": None}])
        with mock.patch("sys.stdout", new=io.StringIO()) as out:
            log.summary()
        self.assertIn("agent-run summary: 1 steps", out.getvalue())
        self.assertIn("agent-run final message:\nDone: fixed the note.", out.getvalue())

    def test_tokens_are_redacted_before_anything_is_printed(self):
        # An injected agent can print its own installation token into a command or its
        # final message, and stdout reaches VictoriaLogs. The cached value is redacted even
        # when it has no gh*_ shape; any gh*_ token is redacted even when it is not cached.
        cached, other = "tok_" + "C" * 36, "ghs_" + "S" * 36
        cache = os.path.join(tempfile.mkdtemp(), "token.json")
        with open(cache, "w") as f:
            json.dump({"token": cached, "expires_at": time.time() + 3600}, f)
        events = [
            {"id": "a", "kind": "ActionEvent", "tool_name": "terminal", "summary": "leak " + cached,
             "action": {"command": "curl -H 'Authorization: token %s' https://x" % cached}},
            {"id": "b", "kind": "AgentErrorEvent", "error": "bad credential " + other},
            {"id": "c", "kind": "MessageEvent", "source": "agent",
             "llm_message": {"content": [{"type": "text", "text": "done, token " + cached}]}},
        ]
        log = agent_run.StepLog("cid")
        with mock.patch.object(agent_run, "TOKEN_CACHE", cache):
            out = self.tick(log, [{"items": events, "next_page_id": None}])
            with mock.patch("sys.stdout", new=io.StringIO()) as summary:
                log.summary()
        printed = out + summary.getvalue()
        self.assertNotIn(cached, printed)
        self.assertNotIn(other, printed)
        # the action's summary and command, the error, the message line and the final message
        self.assertEqual(printed.count(agent_run.REDACTED), 5, printed)


class TimedTest(unittest.TestCase):
    """Disruption design §2: every shutdown step is boxed, and an overrun never holds up the next."""

    def step(self, box, fn):
        started = time.monotonic()
        with mock.patch("sys.stderr", new=io.StringIO()) as err:
            agent_run.timed("x", box, fn)
        return err.getvalue(), time.monotonic() - started

    def test_a_step_that_overruns_is_abandoned(self):
        line, took = self.step(0.2, lambda: time.sleep(5))
        self.assertLess(took, 1)
        self.assertRegex(line, r"^agent-run shutdown x overrun in 0\.2\ds \(box 0\.2s\)\n$")

    def test_a_failed_step_is_logged_redacted(self):
        def boom():
            raise RuntimeError("push refused: ghs_" + "A" * 36)

        line, _ = self.step(1, boom)
        self.assertRegex(line, r"^agent-run shutdown x failed: push refused: \[REDACTED:github-token\] in \d\.\d\ds \(box 1s\)\n$")

    def test_a_step_logs_its_result(self):
        line, _ = self.step(1, lambda: "pushed")
        self.assertRegex(line, r"^agent-run shutdown x done: pushed in 0\.\d\ds \(box 1s\)\n$")


class BudgetTest(unittest.TestCase):
    def test_the_revoke_lands_a_second_before_a_15s_window_ends(self):
        boxes = agent_run.PAUSE_S + agent_run.CHECKPOINT_S + agent_run.FINAL_READ_S + agent_run.STOP_S + agent_run.REVOKE_S
        self.assertLessEqual(boxes, 14, "a preemptible VM's SIGKILL lands at 15 s")
        self.assertLessEqual(boxes + agent_run.EXPORT_S, 15, "the root span's export takes what is left")


class StopTest(unittest.TestCase):
    def test_a_kill_that_is_not_reaped_in_time_never_holds_up_the_revoke(self):
        waits = []

        def wait(timeout=None):
            waits.append(timeout)
            raise subprocess.TimeoutExpired("agent-server", timeout)

        server = mock.Mock(wait=wait)
        self.assertEqual(agent_run.stop(server, agent_run.STOP_S), "killed, not yet reaped")
        server.kill.assert_called_once_with()
        self.assertEqual(waits, [agent_run.STOP_S - 1, 1], "terminated, then killed for the box's last second")


# The commit hook as the image installs it, found as test_pr_footer finds it.
HOOK = next(p for p in (os.path.join(HERE, "commit-msg"), "/etc/agent/git-hooks/commit-msg") if os.path.exists(p))


class CheckpointTest(unittest.TestCase):
    """The checkpoint against a bare repository standing in for GitHub, through the real commit hook."""

    BRANCH = "agent/7f3cq2xz"

    def setUp(self):
        tmp = tempfile.mkdtemp()
        hooks = os.path.join(tmp, "hooks")
        os.mkdir(hooks)
        with open(os.path.join(hooks, "commit-msg"), "w") as f:
            f.write('#!/bin/sh\nexec "%s" "%s" "$@"\n' % (sys.executable, HOOK))
        os.chmod(os.path.join(hooks, "commit-msg"), 0o700)
        gitconfig = os.path.join(tmp, "gitconfig")
        with open(gitconfig, "w") as f:
            f.write("[user]\n\tname = t\n\temail = t@t\n[core]\n\thooksPath = %s\n[init]\n\tdefaultBranch = main\n" % hooks)
        env = mock.patch.dict(os.environ, {"GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": gitconfig, "HOME": tmp,
                                           "PYTHONPATH": HERE, "RUN_ID": "7f3cq2xz"})
        env.start()
        self.addCleanup(env.stop)
        self.remote, self.repo, seed = (os.path.join(tmp, n) for n in ("remote.git", "repo", "seed"))

        def git(*args, cwd=tmp):
            subprocess.run(["git", *args], cwd=cwd, check=True, capture_output=True)

        git("init", "-q", "--bare", self.remote)
        git("clone", "-q", self.remote, seed)
        with open(os.path.join(seed, "README.md"), "w") as f:
            f.write("seed\n")
        git("add", "README.md", cwd=seed)
        git("commit", "-q", "-m", "seed", cwd=seed)
        git("push", "-q", "origin", "HEAD:main", cwd=seed)
        git("clone", "-q", self.remote, self.repo)
        git("checkout", "-q", "-B", self.BRANCH, "origin/main", cwd=self.repo)
        repo = mock.patch.object(agent_run, "REPO_DIR", self.repo)
        repo.start()
        self.addCleanup(repo.stop)
        self.env = {"BRANCH": self.BRANCH}

    def remote_head(self, fmt):
        out = subprocess.run(["git", "--git-dir", self.remote, "log", "-1", "--format=" + fmt, self.BRANCH],
                             capture_output=True, text=True)
        return out.returncode, out.stdout

    def write(self, name, text):
        with open(os.path.join(self.repo, name), "w") as f:
            f.write(text)

    def test_uncommitted_work_is_committed_with_the_trailer_and_pushed(self):
        self.write("wip.md", "half done\n")
        self.assertEqual(agent_run.checkpoint(self.env, time.monotonic() + 8), "pushed a checkpoint commit")
        code, body = self.remote_head("%B")
        self.assertEqual(code, 0, "the branch reached origin")
        self.assertEqual(body.rstrip().rsplit("\n\n", 1)[-1].split("\n"), ["Agent-Run: 7f3cq2xz", "Agent-Checkpoint: disruption"],
                         "the checkpoint trailer beside the usual provenance trailer")

    def test_ignored_files_stay_out(self):
        self.write(".gitignore", "*.log\n")
        self.write("debug.log", "noise\n")
        self.write("notes.md", "kept\n")
        agent_run.checkpoint(self.env, time.monotonic() + 8)
        files = subprocess.run(["git", "--git-dir", self.remote, "show", "--name-only", "--format=", self.BRANCH],
                               capture_output=True, text=True).stdout.split()
        self.assertEqual(sorted(files), [".gitignore", "notes.md"])

    def test_a_clean_tree_with_nothing_unpushed_pushes_nothing(self):
        self.assertEqual(agent_run.checkpoint(self.env, time.monotonic() + 8), "nothing to push")
        self.assertNotEqual(self.remote_head("%H")[0], 0, "no branch was created at origin")

    def test_an_unpushed_agent_commit_is_pushed_without_a_checkpoint(self):
        self.write("done.md", "done\n")
        subprocess.run(["git", "-C", self.repo, "add", "done.md"], check=True, capture_output=True)
        subprocess.run(["git", "-C", self.repo, "commit", "-q", "-m", "docs: done"], check=True, capture_output=True)
        self.assertEqual(agent_run.checkpoint(self.env, time.monotonic() + 8), "pushed")
        _, body = self.remote_head("%B")
        self.assertTrue(body.startswith("docs: done"))
        self.assertNotIn("Agent-Checkpoint", body)

    def test_a_staged_github_token_is_never_committed(self):
        self.write("leak.md", "token: ghs_" + "A" * 36 + "\n")
        self.assertEqual(agent_run.checkpoint(self.env, time.monotonic() + 8),
                         "checkpoint refused (a GitHub token is staged), nothing to push")
        self.assertNotEqual(self.remote_head("%H")[0], 0, "nothing reached origin")

    def test_the_cached_token_is_never_committed_whatever_its_shape(self):
        cache = os.path.join(os.path.dirname(self.repo), "token.json")
        with open(cache, "w") as f:
            json.dump({"token": "v1.0123456789abcdef0123"}, f)
        self.write("leak.md", "v1.0123456789abcdef0123\n")
        with mock.patch.object(agent_run, "TOKEN_CACHE", cache):
            self.assertEqual(agent_run.checkpoint(self.env, time.monotonic() + 8),
                             "checkpoint refused (a GitHub token is staged), nothing to push")

    def test_too_many_files_are_never_committed(self):
        for name in ("a.md", "b.md", "c.md"):
            self.write(name, "x\n")
        with mock.patch.object(agent_run, "CHECKPOINT_MAX_FILES", 2):
            self.assertEqual(agent_run.checkpoint(self.env, time.monotonic() + 8),
                             "checkpoint refused (3 files staged), nothing to push")

    def test_too_many_bytes_are_never_committed(self):
        self.write("big.bin", "x" * 11)
        with mock.patch.object(agent_run, "CHECKPOINT_MAX_BYTES", 10):
            self.assertEqual(agent_run.checkpoint(self.env, time.monotonic() + 8),
                             "checkpoint refused (11 bytes staged), nothing to push")

    def test_a_refused_checkpoint_still_pushes_the_agents_own_commits(self):
        self.write("done.md", "done\n")
        subprocess.run(["git", "-C", self.repo, "add", "done.md"], check=True, capture_output=True)
        subprocess.run(["git", "-C", self.repo, "commit", "-q", "-m", "docs: done"], check=True, capture_output=True)
        self.write("leak.md", "ghp_" + "B" * 36 + "\n")
        self.assertEqual(agent_run.checkpoint(self.env, time.monotonic() + 8),
                         "checkpoint refused (a GitHub token is staged), pushed")
        _, body = self.remote_head("%B")
        self.assertTrue(body.startswith("docs: done"))

    def test_no_time_left_is_an_error(self):
        with self.assertRaises(TimeoutError):
            agent_run.checkpoint(self.env, time.monotonic() - 1)


class GitHub(http.server.BaseHTTPRequestHandler):
    revoked = []

    def do_DELETE(self):
        GitHub.revoked.append((self.path, self.headers.get("Authorization"), time.time()))
        self.send_response(204)
        self.end_headers()

    def log_message(self, *args):
        pass


class SigtermTest(unittest.TestCase):
    """Deleting the pod must stop agent-server before revoking the run's
    token, so a still-running agent cannot mint a fresh one after the revoke."""

    def test_sigterm_stops_the_server_before_revoking_and_exits_143(self):
        github = http.server.HTTPServer(("127.0.0.1", 0), GitHub)
        threading.Thread(target=github.serve_forever, daemon=True).start()
        self.addCleanup(github.server_close)
        self.addCleanup(github.shutdown)
        tmp = tempfile.mkdtemp()
        cache, started, stopped = (os.path.join(tmp, n) for n in ("token.json", "started", "stopped"))
        with open(cache, "w") as f:
            json.dump({"token": "ghs_run", "expires_at": time.time() + 3600}, f)
        # A stand-in agent-server that never answers /ready, so the driver is
        # still waiting when the signal lands, and that records WHEN it was
        # actually stopped (not merely signalled), to check cleanup order.
        stand_in = (
            "import signal, sys, time\n"
            "signal.signal(signal.SIGTERM, lambda *_: (open(sys.argv[2], 'w').write(repr(time.time())), sys.exit(0)))\n"
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

        self.assertEqual(driver.returncode, 143, "SIGTERM is 128 + 15")
        self.assertEqual([r[:2] for r in GitHub.revoked], [("/installation/token", "Bearer ghs_run")])
        self.assertFalse(os.path.exists(cache))
        deadline = time.monotonic() + 10
        while not os.path.exists(stopped) and time.monotonic() < deadline:
            time.sleep(0.1)
        self.assertTrue(os.path.exists(stopped), "agent-server was left running")
        with open(stopped) as f:
            stopped_at = float(f.read())
        self.assertLess(
            stopped_at, GitHub.revoked[0][2],
            "agent-server must be fully stopped before the token is revoked, "
            "so it cannot mint a fresh one in between",
        )


class TraceTest(unittest.TestCase):
    """Observability plan O21-O23: the run's root span, its parent, and the step log's trace id."""

    TP = "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"

    def span(self, env):
        from opentelemetry.sdk.trace.export.in_memory_span_exporter import InMemorySpanExporter
        exporter = InMemorySpanExporter()
        span, provider, extra = agent_run.start_run_span(env, exporter=exporter)
        span.end()
        provider.shutdown()
        [got] = exporter.get_finished_spans()
        return got, extra

    def test_the_run_span_joins_the_trigger_trace(self):
        got, extra = self.span({"TRACEPARENT": self.TP})
        self.assertEqual(got.name, "agent-run")
        self.assertEqual(format(got.context.trace_id, "032x"), "4bf92f3577b34da6a3ce929d0e0e4736")
        self.assertEqual(format(got.parent.span_id, "016x"), "00f067aa0ba902b7")
        ctx = json.loads(extra["LMNR_SPAN_CONTEXT"])
        # agent-server's own root span becomes this span's child (Task 0.5)
        self.assertEqual(uuid.UUID(ctx["trace_id"]).int, got.context.trace_id)
        self.assertEqual(uuid.UUID(ctx["span_id"]).int, got.context.span_id)
        self.assertEqual(extra["OTEL_BSP_SCHEDULE_DELAY"], agent_run.BSP_DELAY_MS)

    def test_no_or_a_bad_traceparent_starts_a_fresh_trace(self):
        for env in ({}, {"TRACEPARENT": "00-zz-1"}, {"TRACEPARENT": "01" + self.TP[2:]}):
            got, _ = self.span(env)
            self.assertIsNone(got.parent, env)
            self.assertNotEqual(format(got.context.trace_id, "032x"), "4bf92f3577b34da6a3ce929d0e0e4736")

    def test_tracing_is_off_without_an_endpoint(self):
        self.assertEqual(agent_run.start_run_span({}), (None, None, {}))

    def test_step_lines_carry_the_trace_id(self):
        log = agent_run.StepLog("cid", "4bf92f3577b34da6a3ce929d0e0e4736")
        line = log.describe({"kind": "ActionEvent", "tool_name": "terminal", "summary": "s", "action": {"command": "ls"}})
        self.assertEqual(line, "agent-run step 1: terminal | s | ls | trace_id=4bf92f3577b34da6a3ce929d0e0e4736")
        self.assertEqual(agent_run.StepLog("cid").describe({"kind": "ActionEvent", "tool_name": "t", "summary": "s", "action": {}}),
                         "agent-run step 1: t | s | ")

    def test_closing_the_conversation_flushes_the_root_span(self):
        with mock.patch.object(agent_run, "http") as http, mock.patch.object(agent_run.time, "sleep") as sleep:
            agent_run.close_conversation("cid")
        # Bounded: a running conversation drains its LLM call before it closes.
        http.assert_called_once_with("DELETE", "/api/conversations/cid", timeout=5)
        sleep.assert_called_once_with(agent_run.FLUSH_WAIT_S)
        with mock.patch.object(agent_run, "http", side_effect=OSError("gone")), mock.patch.object(agent_run.time, "sleep"):
            agent_run.close_conversation("cid")  # never fails the run

    def test_the_run_span_carries_no_attributes(self):
        # agent.run_id is stamped by the collector from the pod label, which a run cannot forge;
        # the harness adds nothing to the span.
        got, _ = self.span({"TRACEPARENT": self.TP})
        self.assertEqual(dict(got.attributes), {})
        self.assertEqual(tuple(got.links), ())
        self.assertEqual(tuple(got.events), ())

    def test_an_unsampled_trigger_is_still_sampled(self):
        # lmnr's span context has no sampled flag, so agent-server's spans export regardless;
        # the run's root must land too, or they are orphaned.
        got, _ = self.span({"TRACEPARENT": self.TP[:-2] + "00"})
        self.assertEqual(format(got.context.trace_id, "032x"), self.TP.split("-")[1])
        self.assertTrue(got.context.trace_flags.sampled)

    def test_the_exporter_gives_up_fast(self):
        with mock.patch(EXPORTER) as exporter:
            _, provider, _ = agent_run.start_run_span({"OTEL_EXPORTER_OTLP_ENDPOINT": "http://c:4318/"})
            provider.shutdown()
        exporter.assert_called_once_with(endpoint="http://c:4318/v1/traces", timeout=5)

    def test_a_broken_exporter_turns_tracing_off(self):
        with mock.patch(EXPORTER, side_effect=ValueError("bad OTEL_EXPORTER_OTLP_COMPRESSION")):
            self.assertEqual(agent_run.start_run_span({"OTEL_EXPORTER_OTLP_ENDPOINT": "http://c:4318"}), (None, None, {}))


EXPORTER = "opentelemetry.exporter.otlp.proto.http.trace_exporter.OTLPSpanExporter"

# A stand-in agent-server on a real port: records the env it was started with, when the
# conversation was posted and closed, and when it was stopped. `running` never ends the
# conversation, and its DELETE drains for a minute, as agent-server's does mid-LLM-call.
STAND_IN = r"""
import http.server, json, os, signal, sys, threading, time
port, status, record = int(sys.argv[1]), sys.argv[2], sys.argv[3]
def note(name, value):
    with open(os.path.join(record, name), "w") as f:
        f.write(value)
note("env", json.dumps({k: os.environ.get(k) for k in ("LMNR_SPAN_CONTEXT", "OTEL_BSP_SCHEDULE_DELAY")}))
EVENT = {"id": "e1", "kind": "ActionEvent", "tool_name": "terminal", "summary": "s", "action": {"command": "ls"}}
class Handler(http.server.BaseHTTPRequestHandler):
    def reply(self, body):
        data = json.dumps(body).encode()
        self.send_response(200)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)
    def do_GET(self):
        if self.path == "/ready":
            return self.reply({})
        if "/events/search" in self.path:
            return self.reply({"items": [EVENT]})
        self.reply({"execution_status": status})
    def do_POST(self):
        self.rfile.read(int(self.headers.get("Content-Length", 0)))
        if self.path.endswith("/interrupt"):
            note("interrupted", repr(time.time()))
            return self.reply({"success": True})
        self.reply({"id": "cid"})
    def do_DELETE(self):
        note("closed", repr(time.time()))
        time.sleep(60 if status == "running" else 0)
        self.reply({})
    def log_message(self, *args):
        pass
server = http.server.ThreadingHTTPServer(("127.0.0.1", port), Handler)
server.daemon_threads = True
threading.Thread(target=server.serve_forever, daemon=True).start()
signal.signal(signal.SIGTERM, lambda *_: (note("stopped", repr(time.time())), os._exit(0)))
while True:
    time.sleep(1)
"""
DRIVER = (
    "import sys, agent_run\n"
    "agent_run.AGENT_SERVER = 'http://127.0.0.1:' + sys.argv[1]\n"
    "agent_run.SERVER_CMD = [sys.executable, '-c', sys.argv[2], sys.argv[1], sys.argv[3], sys.argv[4]]\n"
    "agent_run.clone = lambda env: None\n"
    "agent_run.build_request = lambda env, task, rules: {}\n"
    "agent_run.POLL_INTERVAL_S = 0.2\n"
    "agent_run.FLUSH_WAIT_S = 0\n"
    "sys.exit(agent_run.main())\n"
)
# DRIVER with a checkpoint that records when it ran, then sleeps argv[5] seconds, in a box of
# argv[6] seconds: the order and the overrun are observable, and no git remote is needed.
DISRUPTION_DRIVER = (
    "import os, sys, time, agent_run\n"
    "agent_run.AGENT_SERVER = 'http://127.0.0.1:' + sys.argv[1]\n"
    "agent_run.SERVER_CMD = [sys.executable, '-c', sys.argv[2], sys.argv[1], sys.argv[3], sys.argv[4]]\n"
    "agent_run.clone = lambda env: None\n"
    "agent_run.build_request = lambda env, task, rules: {}\n"
    "agent_run.POLL_INTERVAL_S = 0.2\n"
    "agent_run.CHECKPOINT_S = float(sys.argv[6])\n"
    "def checkpoint(env, deadline):\n"
    "    with open(os.path.join(sys.argv[4], 'checkpointed'), 'w') as f:\n"
    "        f.write(repr(time.time()))\n"
    "    time.sleep(float(sys.argv[5]))\n"
    "    return 'pushed a checkpoint commit'\n"
    "agent_run.checkpoint = checkpoint\n"
    "sys.exit(agent_run.main())\n"
)


class FakeBridge(http.server.BaseHTTPRequestHandler):
    """room-bridge's final read: records when it was asked, answers after `delay`."""
    reads = []
    delay = 0

    def do_POST(self):
        FakeBridge.reads.append((self.path, time.time()))
        time.sleep(FakeBridge.delay)
        body = b'{"events": 1, "unmirrored": 0, "sealed": false}'
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


class Collector(http.server.BaseHTTPRequestHandler):
    spans = []

    def do_POST(self):
        from opentelemetry.proto.collector.trace.v1.trace_service_pb2 import ExportTraceServiceRequest
        body = ExportTraceServiceRequest.FromString(self.rfile.read(int(self.headers["Content-Length"])))
        Collector.spans += [s for rs in body.resource_spans for ss in rs.scope_spans for s in ss.spans]
        self.send_response(200)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def log_message(self, *args):
        pass


class TracedRunTest(unittest.TestCase):
    """main() with tracing on, as every composed run has it (observability plan O21)."""

    def serve(self, handler):
        server = http.server.HTTPServer(("127.0.0.1", 0), handler)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        return server.server_port

    def start(self, status, endpoint, extra_env=None, script=DRIVER, args=()):
        GitHub.revoked.clear()
        self.addCleanup(GitHub.revoked.clear)
        github = self.serve(GitHub)
        self.tmp = tempfile.mkdtemp()
        self.cache = os.path.join(self.tmp, "token.json")
        with open(self.cache, "w") as f:
            json.dump({"token": "ghs_run", "expires_at": time.time() + 3600}, f)
        for name in ("task", "rules"):
            with open(os.path.join(self.tmp, name), "w") as f:
                f.write(name)
        probe = socket.socket()
        probe.bind(("127.0.0.1", 0))
        port = str(probe.getsockname()[1])
        probe.close()
        self.out = os.path.join(self.tmp, "stdout")
        err = os.path.join(self.tmp, "stderr")
        env = {**os.environ, "GIT_TOKEN_CACHE": self.cache, "GITHUB_API": "http://127.0.0.1:%d" % github,
               "TASK_FILE": os.path.join(self.tmp, "task"), "RULES_FILE": os.path.join(self.tmp, "rules"),
               "OTEL_EXPORTER_OTLP_ENDPOINT": endpoint, **(extra_env or {})}
        with open(self.out, "w") as out, open(err, "w") as errf:
            # Its own process group, so cleanup also reaches the stand-in agent-server, which a
            # driver killed mid-run never gets to stop.
            driver = subprocess.Popen([sys.executable, "-c", script, port, STAND_IN, status, self.tmp, *args],
                                      cwd=HERE, env=env, stdout=out, stderr=errf, start_new_session=True)
        self.addCleanup(self.kill_group, driver)
        return driver

    @staticmethod
    def kill_group(driver):
        try:
            os.killpg(driver.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        driver.wait()

    def read(self, name):
        with open(os.path.join(self.tmp, name)) as f:
            return f.read()

    def wait_for_a_step(self):
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            if "agent-run step 1" in self.read("stdout"):
                return
            time.sleep(0.1)
        self.fail("the driver never logged a step")

    def assert_handed_over(self, trace_id=None):
        env = json.loads(self.read("env"))
        self.assertEqual(env["OTEL_BSP_SCHEDULE_DELAY"], agent_run.BSP_DELAY_MS)
        ctx = uuid.UUID(json.loads(env["LMNR_SPAN_CONTEXT"])["trace_id"]).hex
        if trace_id:
            self.assertEqual(ctx, trace_id)
        # The step line links to the same trace (O22).
        self.assertIn("agent-run step 1: terminal | s | ls | trace_id=" + ctx + "\n", self.read("stdout"))

    def assert_stopped_then_revoked(self):
        self.assertEqual([r[:2] for r in GitHub.revoked], [("/installation/token", "Bearer ghs_run")])
        self.assertLess(float(self.read("stopped")), GitHub.revoked[0][2])
        return GitHub.revoked[0][2]

    def test_sigterm_revokes_within_the_grace_whatever_the_collector(self):
        driver = self.start("running", "http://127.0.0.1:1")  # nothing listens: a dead collector
        self.wait_for_a_step()
        signalled = time.time()
        driver.send_signal(signal.SIGTERM)
        driver.wait(timeout=30)

        self.assertEqual(driver.returncode, 143, "SIGTERM is 128 + 15")
        self.assert_handed_over()
        revoked = self.assert_stopped_then_revoked()
        # The close drains a running conversation, so the signal path skips it: the revoke
        # lands well inside the pod's 30 s grace, and a dead collector does not delay it.
        self.assertFalse(os.path.exists(os.path.join(self.tmp, "closed")), "the signal path must not close")
        self.assertLess(revoked - signalled, 3)
        # Exit also waits out the root span's export to the dead collector and its retry backoff.
        self.assertLess(time.time() - signalled, 15)

    def test_a_finished_run_closes_the_conversation_then_exports_its_root_span(self):
        Collector.spans = []
        collector = self.serve(Collector)
        _, trace_id, parent_id, _ = TraceTest.TP.split("-")
        driver = self.start("finished", "http://127.0.0.1:%d" % collector, {"TRACEPARENT": TraceTest.TP})
        driver.wait(timeout=60)

        self.assertEqual(driver.returncode, 0)
        self.assert_handed_over(trace_id)
        self.assert_stopped_then_revoked()
        # Closed before agent-server stops, so the SDK's root span can end and export.
        self.assertLess(float(self.read("closed")), float(self.read("stopped")))
        [span] = Collector.spans
        self.assertEqual(span.name, "agent-run")
        self.assertEqual(span.trace_id.hex(), trace_id)
        self.assertEqual(span.parent_span_id.hex(), parent_id)
        self.assertEqual(list(span.attributes), [])

    def serve_bridge(self, delay=0):
        FakeBridge.reads, FakeBridge.delay = [], delay
        self.addCleanup(setattr, FakeBridge, "reads", [])
        return "http://127.0.0.1:%d" % self.serve(FakeBridge)

    def shutdown_steps(self):
        return [line.split()[2] for line in self.read("stderr").splitlines() if line.startswith("agent-run shutdown ")]

    def disrupt(self, extra_env, args):
        driver = self.start("running", "http://127.0.0.1:1", extra_env, script=DISRUPTION_DRIVER, args=args)
        self.wait_for_a_step()
        signalled = time.time()
        driver.send_signal(signal.SIGTERM)
        driver.wait(timeout=30)
        self.assertEqual(driver.returncode, 143, "SIGTERM is 128 + 15")
        return signalled

    def test_sigterm_pauses_checkpoints_reads_stops_then_revokes_inside_15s(self):
        bridge = self.serve_bridge()
        signalled = self.disrupt({"ROLE": "implementer", "BRANCH": "agent/7f3cq2xz", "BRIDGE_URL": bridge}, ("0", str(agent_run.CHECKPOINT_S)))
        revoked = self.assert_stopped_then_revoked()
        order = [float(self.read("interrupted")), float(self.read("checkpointed")), FakeBridge.reads[0][1],
                 float(self.read("stopped")), revoked]
        self.assertEqual(order, sorted(order), "pause, checkpoint, final read, stop, revoke")
        self.assertEqual(FakeBridge.reads[0][0], "/final-read")
        self.assertEqual(self.shutdown_steps(), ["pause", "checkpoint", "final-read", "stop", "revoke"])
        self.assertLess(revoked - signalled, 15, "the whole sequence fits the 15 s budget")

    def test_a_step_that_overruns_does_not_hold_up_the_next(self):
        bridge = self.serve_bridge(delay=5)  # longer than the final read's 3 s box
        signalled = self.disrupt({"ROLE": "implementer", "BRANCH": "agent/7f3cq2xz", "BRIDGE_URL": bridge}, ("30", "1"))
        revoked = self.assert_stopped_then_revoked()
        log = self.read("stderr")
        self.assertRegex(log, r"agent-run shutdown checkpoint overrun in 1\.\d\ds \(box 1\.0s\)")
        self.assertRegex(log, r"agent-run shutdown final-read (overrun|failed: [^\n]*) in 3\.\d\ds \(box 3s\)")
        self.assertEqual(self.shutdown_steps(), ["pause", "checkpoint", "final-read", "stop", "revoke"])
        self.assertLess(revoked - signalled, 10)

    def test_a_sigterm_after_the_run_finished_keeps_its_exit_code(self):
        # C1: the composition reads this code; 143 on a finished run would have it resumed.
        for status, code in (("finished", 0), ("error", 1)):
            with self.subTest(status=status):
                bridge = self.serve_bridge(delay=2)
                driver = self.start(status, "http://127.0.0.1:1", {"ROLE": "implementer", "BRIDGE_URL": bridge})
                deadline = time.monotonic() + 30
                while not FakeBridge.reads and time.monotonic() < deadline:
                    time.sleep(0.05)
                self.assertTrue(FakeBridge.reads, "the run never reached its final read")
                driver.send_signal(signal.SIGTERM)
                driver.wait(timeout=30)
                self.assertEqual(driver.returncode, code)
                self.assertEqual(self.shutdown_steps(), ["stop", "revoke"], "nothing to pause or checkpoint")
                self.assert_stopped_then_revoked()

    def test_a_silent_collector_never_holds_the_pod_past_the_revoke(self):
        # M2: listening, never answering, the collector makes each export wait out its timeout.
        silent = socket.socket()
        silent.bind(("127.0.0.1", 0))
        silent.listen(8)
        self.addCleanup(silent.close)
        driver = self.start("running", "http://127.0.0.1:%d" % silent.getsockname()[1])
        self.wait_for_a_step()
        driver.send_signal(signal.SIGTERM)
        driver.wait(timeout=30)
        exited = time.time()
        self.assertEqual(driver.returncode, 143)
        self.assertLess(exited - self.assert_stopped_then_revoked(), 2, "the root span's export is boxed")

    def test_a_reviewer_never_checkpoints(self):
        self.disrupt({"ROLE": "reviewer", "BRANCH": "agent/7f3cq2xz"}, ("0", str(agent_run.CHECKPOINT_S)))
        self.assertFalse(os.path.exists(os.path.join(self.tmp, "checkpointed")))
        self.assertEqual(self.shutdown_steps(), ["pause", "final-read", "stop", "revoke"])


if __name__ == "__main__":
    unittest.main()
