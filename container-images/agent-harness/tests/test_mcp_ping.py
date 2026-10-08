"""F29: a refused reply to a server's ping must not end agent-server's MCP session.

Runs the real MCP client (fastmcp over mcp's streamable HTTP, as the SDK does) against a stand-in
for agent-router that pings the client on its standalone stream and answers the reply 400, as
envoyproxy/ai-gateway#2715 does.
"""
import http.server
import importlib.util
import io
import json
import os
import subprocess
import sys
import tempfile
import threading
import unittest
from unittest import mock

HERE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
sys.path.insert(0, HERE)

import agent_run  # noqa: E402

SITE = os.path.join(HERE, "site", "sitecustomize.py")
PING = b'{"jsonrpc": "2.0", "id": 1, "method": "ping"}'


class Router(http.server.BaseHTTPRequestHandler):
    """agent-router with ai-gateway#2715: the client's reply to a backend ping is a 400."""
    replies, marker, pinged = [], "", False
    done = threading.Event()

    def answer(self, code, body=b"", headers=()):
        self.send_response(code)
        for key, value in (("Content-Type", "application/json"), *headers):
            self.send_header(key, value)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        msg = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        if "method" not in msg:
            Router.replies.append(msg)
            self.answer(400, b"invalid response ID type: 1")
            open(Router.marker, "w").close()
            return
        result = {"initialize": {"protocolVersion": "2025-06-18", "capabilities": {"tools": {}},
                                 "serverInfo": {"name": "router", "version": "0"}},
                  "tools/list": {"tools": [{"name": "echo", "inputSchema": {"type": "object"}}]},
                  "tools/call": {"content": [{"type": "text", "text": "pong"}], "isError": False}}.get(msg["method"], {})
        if "id" not in msg:
            return self.answer(202)
        self.answer(200, json.dumps({"jsonrpc": "2.0", "id": msg["id"], "result": result}).encode(),
                    [("mcp-session-id", "s1")])

    def do_GET(self):
        # The standalone stream: one ping, then held open, as a backend's keepalive arrives.
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.end_headers()
        if not Router.pinged:
            Router.pinged = True
            self.wfile.write(b"event: message\ndata: " + PING + b"\n\n")
            self.wfile.flush()
        Router.done.wait(20)

    def do_DELETE(self):
        self.answer(200)

    def log_message(self, *args):
        pass


# The client as agent-server's SDK drives it: connect, wait for the ping's reply to be refused,
# then call a tool. Prints one JSON line; os._exit skips a teardown a dead session can hang.
CLIENT = r"""
import asyncio, json, os, sys, time
from fastmcp import Client
from fastmcp.client.transports import StreamableHttpTransport

async def main(url, marker):
    out = {"pythonpath": os.environ.get("PYTHONPATH", "")}
    async with Client(StreamableHttpTransport(url)) as client:
        deadline = time.monotonic() + 10
        while not os.path.exists(marker) and time.monotonic() < deadline:
            await asyncio.sleep(0.05)
        await asyncio.sleep(0.3)
        try:
            result = await asyncio.wait_for(client.call_tool_mcp("echo", {}), 5)
            out.update(ok=True, text=result.content[0].text)
        except BaseException as exc:
            out.update(ok=False, error="%s: %s" % (type(exc).__name__, exc))
        print(json.dumps(out), flush=True)
        os._exit(0)

asyncio.run(main(sys.argv[1], sys.argv[2]))
"""


class RefusedPingReplyTest(unittest.TestCase):
    def call_after_a_refused_ping(self, env):
        Router.replies, Router.pinged = [], False
        Router.done.clear()
        self.addCleanup(Router.done.set)
        Router.marker = os.path.join(tempfile.mkdtemp(), "refused")
        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Router)
        server.daemon_threads = True
        threading.Thread(target=server.serve_forever, daemon=True).start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        url = "http://127.0.0.1:%d/mcp" % server.server_port
        done = subprocess.run([sys.executable, "-c", CLIENT, url, Router.marker], env=env, cwd="/",
                              capture_output=True, text=True, timeout=60)
        self.assertEqual([r.get("id") for r in Router.replies], [1], "the client replied to the ping: " + done.stderr)
        return json.loads(done.stdout.strip().splitlines()[-1]), done.stderr

    def env(self):
        env = dict(os.environ)
        env.pop("PYTHONPATH", None)
        return env

    def test_agent_server_keeps_its_session(self):
        out, err = self.call_after_a_refused_ping(agent_run.server_env(self.env()))
        self.assertEqual((out["ok"], out.get("text")), (True, "pong"), out)
        self.assertEqual(err.count("F29"), 1, "one warning per refused reply: " + err)
        self.assertNotIn(os.path.dirname(SITE), out["pythonpath"], "the agent's own commands never load the patch")

    def test_unpatched_the_session_dies_with_an_empty_error(self):
        # mcp 1.28.1's behaviour the patch exists for; once this fails, the patch can go.
        out, _ = self.call_after_a_refused_ping(self.env())
        self.assertFalse(out["ok"], out)
        self.assertRegex(out["error"], r"^\w+: $", "the SDK reports it as 'Error calling MCP tool …: '")


class PatchTest(unittest.TestCase):
    def load(self):
        spec = importlib.util.spec_from_file_location("harness_sitecustomize", SITE)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module

    def test_a_missing_method_is_said_loudly(self):
        with mock.patch("sys.stderr", new=io.StringIO()) as err:
            self.assertFalse(self.load().patch(type("Transport", (), {}), None, ()))
        self.assertIn("F29 patch NOT applied", err.getvalue())

    def test_server_env_loads_it_first(self):
        path = agent_run.server_env({"PYTHONPATH": "/x"})["PYTHONPATH"].split(os.pathsep)
        self.assertEqual(path, [os.path.dirname(os.path.realpath(SITE)), "/x"])


if __name__ == "__main__":
    unittest.main()
