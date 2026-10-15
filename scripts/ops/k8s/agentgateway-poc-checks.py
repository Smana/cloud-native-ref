"""In-pod half of agentgateway-poc-live-check.sh. Stdlib only.

usage (inside a throwaway pod): [AGW_URL=... AGW_SUB_NS=...] python3 - <check> [args]
AGW_URL and AGW_SUB_NS pick the Gateway and the caller namespace (default: the PoC).
Tokens are read from the projected volume at /var/run/agw, never from argv.
Each check prints `PASS|FAIL <id> <what>` lines plus a short evidence excerpt.
"""
import json
import os
import sys
import time
import urllib.error
import urllib.request

GW = os.environ.get("AGW_URL") or "http://agent-router-agw.agw-poc.svc.cluster.local"
SUB = f"system:serviceaccount:{os.environ.get('AGW_SUB_NS') or 'agw-poc-clients'}:"
RESULTS = []


def tok(name):
    return open(f"/var/run/agw/{name}").read().strip() if name else None


def call(method, path, body=None, token="public", port=8080, headers=None, timeout=300):
    h = {"Content-Type": "application/json"}
    if token:
        h["Authorization"] = "Bearer " + tok(token)
    h.update(headers or {})
    data = json.dumps(body).encode() if body is not None else None
    r = urllib.request.Request(f"{GW}:{port}{path}", data=data, method=method, headers=h)
    try:
        with urllib.request.urlopen(r, timeout=timeout) as resp:
            return resp.status, {k.lower(): v for k, v in resp.headers.items()}, resp.read().decode()
    except urllib.error.HTTPError as e:
        return e.code, {k.lower(): v for k, v in e.headers.items()}, e.read().decode()


def check(cid, what, ok, evidence):
    print(f"{'PASS' if ok else 'FAIL'} {cid} {what}")
    print("     " + evidence.replace("\n", " ")[:300])
    RESULTS.append(ok)


OA = {"model": "agent-default", "max_tokens": 16,
      "messages": [{"role": "user", "content": "Reply with the single word: pong"}]}
AN = dict(OA)
AV = {"anthropic-version": "2023-06-01"}


def usage_of_stream(body):
    for line in body.splitlines():
        if line.startswith("data: {") and '"usage"' in line:
            u = json.loads(line[6:]).get("usage")
            if u:
                return u
    return None


def identity():
    code, _, body = call("GET", "/echo", token=None)
    check("L8/P1", "no token -> 401", code == 401, f"HTTP {code} {body}")
    code, _, body = call("GET", "/echo", token="internal")
    check("L8/P1", "internal-audience token on public -> 401", code == 401, f"HTTP {code} {body}")
    code, _, body = call("GET", "/echo", token="internal", port=8081)
    check("L8/P1", "internal-audience token on internal -> 200", code == 200, f"HTTP {code}")
    code, _, body = call("GET", "/echo", headers={"x-ar-agent": "forged"})
    seen = json.loads(body).get("headers", {}) if code == 200 else {}
    check("L8/P2", "public token -> 200, forged x-ar-agent replaced, no Authorization upstream",
          code == 200 and seen.get("x-ar-agent", "").startswith(SUB)
          and "authorization" not in seen, f"HTTP {code} x-ar-agent={seen.get('x-ar-agent')} authorization={'authorization' in seen}")


def sts():
    code, _, body = call("GET", "/echo", port=8082)
    check("L8/P1", "public-audience token on sts -> 401", code == 401, f"HTTP {code} {body}")
    code, _, body = call("GET", "/echo", token="sts", port=8082, headers={"x-ar-agent": "forged"})
    seen = json.loads(body).get("headers", {}) if code == 200 else {}
    check("L8/AG4", "sts token on sts -> 200, x-ar-agent verified, the bearer forwarded (preserveToken)",
          code == 200 and seen.get("x-ar-agent", "").startswith(SUB) and "authorization" in seen,
          f"HTTP {code} x-ar-agent={seen.get('x-ar-agent')} authorization={'authorization' in seen}")


def rogue():
    code, _, body = call("GET", "/echo")
    check("L8/P1", "right audience, wrong namespace -> 403", code == 403, f"HTTP {code} {body}")


def models():
    code, _, body = call("GET", "/v1/models", token=None)
    check("L7/P8", "/v1/models without token -> 401", code == 401, f"HTTP {code} {body}")
    code, _, body = call("GET", "/v1/models")
    check("L7/N3", "/v1/models with token -> 404 JSON, not a model list",
          code == 404 and "not served" in body, f"HTTP {code} {body}")


def llm(gateway="poc"):
    code, _, body = call("POST", "/v1/chat/completions", OA)
    u = json.loads(body).get("usage") if code == 200 else None
    check("L1", "GLM-5.3 chat completion, buffered", code == 200 and bool(u), f"HTTP {code} usage={u} {body[:160]}")
    code, _, body = call("POST", "/v1/chat/completions", dict(OA, stream=True, stream_options={"include_usage": True}))
    u = usage_of_stream(body)
    check("L1", "GLM-5.3 chat completion, streamed with usage", code == 200 and "[DONE]" in body and bool(u),
          f"HTTP {code} usage={u}")
    # The real Gateway sends /anthropic to Z.ai's native endpoint and converts only
    # /v1/messages; the PoC converted /anthropic and served the native one apart.
    converted, native = ("/v1/messages", "/anthropic/v1/messages") if gateway == "real" else \
        ("/anthropic/v1/messages", "/zai-anthropic/v1/messages")
    code, _, body = call("POST", converted, AN, headers=AV)
    check("L2", f"Anthropic Messages -> Chat Completions conversion on {converted}, buffered",
          code == 200 and '"type":"message"' in body.replace(" ", ""), f"HTTP {code} {body[:240]}")
    streamed = native if gateway == "real" else converted
    code, _, body = call("POST", streamed, dict(AN, stream=True), headers=AV)
    check("L2", f"Anthropic Messages on {streamed}, streamed", code == 200 and "message_stop" in body,
          f"HTTP {code} {body[-200:]}")
    code, _, body = call("POST", native, AN, headers=AV)
    check("L2", f"Anthropic Messages to Z.ai's native /api/anthropic on {native}, buffered",
          code == 200 and '"type":"message"' in body.replace(" ", ""), f"HTTP {code} {body[:240]}")


class Mcp:
    H = {"Accept": "application/json, text/event-stream", "MCP-Protocol-Version": "2025-06-18"}

    def __init__(self, token="public", port=8080, extra=None):
        self.token, self.port = token, port
        self.h = dict(self.H, **(extra or {}))
        code, hdr, body = call("POST", "/mcp", {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
            "protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "agw-poc", "version": "1"}}},
            token=token, port=port, headers=self.h)
        if hdr.get("mcp-session-id"):
            self.h["Mcp-Session-Id"] = hdr["mcp-session-id"]
        call("POST", "/mcp", {"jsonrpc": "2.0", "method": "notifications/initialized"}, token=token, port=port,
             headers=self.h)
        self.init = code

    @classmethod
    def resume(cls, extra=None):
        """The session `open` saved, as a phase after a restart reuses it."""
        m = cls.__new__(cls)
        m.token, m.port = "public", 8080
        m.h = dict(cls.H, **(extra or {}))
        sid = open("/tmp/mcp-session").read()
        if sid:
            m.h["Mcp-Session-Id"] = sid
        return m

    def rpc(self, method, params=None):
        code, _, body = call("POST", "/mcp", {"jsonrpc": "2.0", "id": 2, "method": method, "params": params or {}},
                             token=self.token, port=self.port, headers=self.h)
        for line in body.splitlines():
            if line.startswith("data: "):
                return code, json.loads(line[6:])
        try:
            return code, json.loads(body)
        except ValueError:
            return code, {"raw": body[:200]}

    def tools(self):
        names, cursor = [], None
        while True:
            _, r = self.rpc("tools/list", {"cursor": cursor} if cursor else {})
            res = r.get("result", {})
            names += [t["name"] for t in res.get("tools", [])]
            cursor = res.get("nextCursor")
            if not cursor:
                return names


def mcp(phase):
    m = Mcp() if phase == "open" else None
    if phase == "open":
        open("/tmp/mcp-session", "w").write(m.h.get("Mcp-Session-Id", ""))
        names = m.tools()
        check("L3/N5", "federated tools are prefixed <target>_<tool> and filtered by the Allow list",
              sorted(names) == ["echo_echo_headers", "victorialogs_documentation", "victoriametrics_documentation"],
              f"init HTTP {m.init}, tools/list (all pages) = {names}")
        _, r = m.rpc("tools/call", {"name": "echo_admin_delete", "arguments": {}})
        check("L3/P4", "a tool outside the Allow list is refused", "error" in r, json.dumps(r)[:200])
    else:
        m = Mcp.resume()
    _, r = m.rpc("tools/call", {"name": "echo_echo_headers", "arguments": {}})
    text = (r.get("result", {}).get("content") or [{}])[0].get("text", "{}")
    seen = json.loads(text) if text.startswith("{") else {}
    check("L3/P4", f"[{phase}] per-target key injected, no Authorization on the MCP hop",
          "x-echo-mcp-key" in seen and "authorization" not in seen,
          f"x-echo-mcp-key={seen.get('x-echo-mcp-key')} authorization={'authorization' in seen}")
    names = m.tools()
    check("L3", f"[{phase}] the session still lists both in-cluster servers' tools",
          {"victoriametrics_documentation", "victorialogs_documentation"} <= set(names), f"tools/list = {names}")


# The implementer's grants on the real Gateway (infrastructure/base/agent-gateway/mcp.yaml),
# without room-broker: the broker answers only a live AgentRun's subject (403 otherwise), so
# a throwaway client never lists room tools. The live check proves the key from the
# broker's own rejection counter instead.
VM = ["documentation", "query", "query_range", "metrics", "metrics_metadata", "labels", "label_values", "series",
      "alerts", "rules", "explain_query", "prettify_query", "metric_statistics"]
REAL_TOOLS = {
    "public": {"flux-operator-mcp_search_flux_docs", "mcp-victoriametrics_documentation",
               "mcp-victorialogs_documentation"},
    "internal": {f"flux-operator-mcp_{t}" for t in ("search_flux_docs", "get_flux_instance",
                                                     "get_kubernetes_api_versions", "get_kubernetes_metrics")}
    | {f"mcp-victoriametrics_{t}" for t in VM} | {"mcp-victorialogs_documentation"},
}
REFUSED = {"public": "mcp-victoriametrics_query", "internal": "flux-operator-mcp_get_kubernetes_logs"}
ECHO = {"x-agw-check": "mcp"}  # selects the throwaway echo MCP route on /mcp


def mcp_real(phase):
    if phase == "open":
        for cls, port in (("public", 8080), ("internal", 8081)):
            m = Mcp(cls, port)
            names = m.tools()
            check("L3/P4", f"{cls}: exactly the implementer's Allow list, named <target>_<tool>",
                  set(names) == REAL_TOOLS[cls], f"init HTTP {m.init}, tools/list (all pages) = {sorted(names)}")
            _, r = m.rpc("tools/call", {"name": REFUSED[cls], "arguments": {}})
            check("L3/P4", f"{cls}: {REFUSED[cls]} is outside the implementer's Allow list -> refused",
                  "error" in r or (r.get("result") or {}).get("isError") is True, json.dumps(r)[:200])
            _, r = m.rpc("resources/list")
            check("L3/P4", f"{cls}: no role is granted a resource",
                  not (r.get("result") or {}).get("resources"), json.dumps(r)[:200])
        _, r = Mcp().rpc("tools/call", {"name": "room-broker_room_read", "arguments": {}})
        print("     room-broker_room_read as a non-run (the broker's counter judges it): " + json.dumps(r)[:200])
        m = Mcp(extra=ECHO)
        open("/tmp/mcp-session", "w").write(m.h.get("Mcp-Session-Id", ""))
    else:
        m = Mcp.resume(ECHO)
    _, r = m.rpc("tools/call", {"name": "echo_echo_headers", "arguments": {}})
    text = (r.get("result", {}).get("content") or [{}])[0].get("text", "{}")
    seen = json.loads(text) if text.startswith("{") else {}
    check("L3/P4", f"[{phase}] a target's key injected in its own header, no Authorization on the MCP hop",
          "x-echo-mcp-key" in seen and "authorization" not in seen,
          f"x-echo-mcp-key={seen.get('x-echo-mcp-key')} authorization={'authorization' in seen}"
          + ("" if seen else f" reply={json.dumps(r)[:200]}"))
    names = Mcp().tools()
    check("L3", f"[{phase}] the federation still lists the in-cluster servers' tools",
          set(names) == REAL_TOOLS["public"], f"tools/list = {sorted(names)}")


def drain(secs):
    t0 = time.time()
    try:
        code, _, body = call("GET", f"/echo/stream?s={secs}", timeout=secs + 120)
        ok = code == 200 and body.count("tick") == secs and "[DONE]" in body
        ev = f"HTTP {code} after {time.time() - t0:.0f}s, ticks={body.count('tick')}/{secs}"
    except Exception as e:  # a cut stream surfaces as IncompleteRead or a reset
        ok, ev = False, f"stream cut after {time.time() - t0:.0f}s: {e!r}"[:300]
    check("L4/N1", f"a {secs}s stream survives deletion of every proxy pod", ok, ev)


cmd = sys.argv[1]
{"identity": identity, "sts": sts, "rogue": rogue, "models": models}.get(cmd, lambda: None)()
if cmd == "llm":
    llm(*sys.argv[2:3])
elif cmd == "mcp":
    mcp(sys.argv[2])
elif cmd == "mcp-real":
    mcp_real(sys.argv[2])
elif cmd == "drain":
    drain(int(sys.argv[2]))
sys.exit(0 if all(RESULTS) else 1)
