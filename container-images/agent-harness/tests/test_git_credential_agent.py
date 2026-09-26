"""git-credential-agent against a stub octo-sts and a stub GitHub. Stdlib only."""
import http.server
import io
import json
import os
import sys
import tempfile
import threading
import time
import unittest
from unittest import mock

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import git_credential_agent as helper  # noqa: E402


class Stub(http.server.BaseHTTPRequestHandler):
    calls = []
    delay = 0  # artificial latency on the exchange, to expose a missing lock
    revoke_status = 204

    def do_GET(self):  # octo-sts exchange
        if Stub.delay:
            time.sleep(Stub.delay)
        Stub.calls.append(("GET", self.path, self.headers.get("Authorization")))
        body = json.dumps({"token": "ghs_stub%d" % len(Stub.calls)}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(body)

    def do_DELETE(self):  # GitHub revoke
        Stub.calls.append(("DELETE", self.path, self.headers.get("Authorization")))
        self.send_response(Stub.revoke_status)
        self.end_headers()

    def log_message(self, *args):
        pass


class HelperTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = http.server.HTTPServer(("127.0.0.1", 0), Stub)
        threading.Thread(target=cls.server.serve_forever, daemon=True).start()
        cls.base = "http://127.0.0.1:%d" % cls.server.server_port

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()

    def setUp(self):
        Stub.calls.clear()
        self.tmp = tempfile.mkdtemp()
        helper.CACHE = os.path.join(self.tmp, "token.json")
        helper.GITHUB_API = self.base
        self.env = mock.patch.dict(os.environ, {"STS_URL": self.base + "/sts/exchange", "REPOSITORY": "Smana/cloud-native-ref", "ROLE": "implementer"})
        self.env.start()

    def tearDown(self):
        self.env.stop()

    def get(self, host):
        out = io.StringIO()
        with mock.patch("sys.stdin", io.StringIO("protocol=https\nhost=%s\n" % host)), mock.patch("sys.stdout", out):
            helper.main(["git-credential-agent", "get"])
        return out.getvalue()

    def test_exchanges_for_the_run_repository_and_role(self):
        self.assertEqual(self.get("github.com"), "username=x-access-token\npassword=ghs_stub1\n")
        self.assertEqual(Stub.calls[0][1], "/sts/exchange?scope=Smana/cloud-native-ref&identity=agent-implementer")

    def test_caches_in_the_memory_volume(self):
        self.get("github.com")
        self.get("github.com")
        self.assertEqual(len(Stub.calls), 1, "the second get is served from the cache")
        self.assertEqual(os.stat(helper.CACHE).st_mode & 0o777, 0o600)

    def test_ignores_other_hosts(self):
        self.assertEqual(self.get("gitlab.com"), "")
        self.assertEqual(Stub.calls, [])

    def test_revoke_deletes_the_token_at_github_and_the_cache(self):
        self.get("github.com")
        helper.main(["git-credential-agent", "revoke"])
        self.assertEqual(Stub.calls[-1], ("DELETE", "/installation/token", "Bearer ghs_stub1"))
        self.assertFalse(os.path.exists(helper.CACHE))

    def test_revoke_without_a_token_is_a_no_op(self):
        helper.main(["git-credential-agent", "revoke"])
        self.assertEqual(Stub.calls, [])

    def test_token_action_prints_the_token(self):
        out = io.StringIO()
        with mock.patch("sys.stdout", out):
            helper.main(["git-credential-agent", "token"])
        self.assertEqual(out.getvalue(), "ghs_stub1\n")

    def test_refresh_margin_reexchanges_and_revokes_the_old_token(self):
        with open(helper.CACHE, "w") as f:
            json.dump({"token": "ghs_old", "expires_at": time.time() + 60}, f)  # < 600s left
        self.assertEqual(self.get("github.com"), "username=x-access-token\npassword=ghs_stub1\n")
        self.assertEqual(Stub.calls[0][0], "GET", "the new token is fetched before the old one is revoked")
        self.assertEqual(Stub.calls[1], ("DELETE", "/installation/token", "Bearer ghs_old"))
        with open(helper.CACHE) as f:
            self.assertEqual(json.load(f)["token"], "ghs_stub1", "the cache now points at the new token")

    def test_revoke_logs_but_does_not_raise_on_an_already_expired_token(self):
        self.get("github.com")
        Stub.revoke_status = 401
        self.addCleanup(setattr, Stub, "revoke_status", 204)
        with self.assertLogs(helper.log, level="WARNING"):
            helper.main(["git-credential-agent", "revoke"])  # must not traceback
        self.assertFalse(os.path.exists(helper.CACHE))

    def test_concurrent_token_calls_serialize_on_the_cache_lock(self):
        Stub.delay = 0.2
        self.addCleanup(setattr, Stub, "delay", 0)
        results = []
        threads = [threading.Thread(target=lambda: results.append(helper.token())) for _ in range(2)]
        for t in threads:
            t.start()
        for t in threads:
            t.join(timeout=5)
        self.assertEqual(results, ["ghs_stub1", "ghs_stub1"], "the second call must reuse the cached token")
        gets = [c for c in Stub.calls if c[0] == "GET"]
        self.assertEqual(len(gets), 1, "the flock should have serialized the two exchanges")


if __name__ == "__main__":
    unittest.main()
