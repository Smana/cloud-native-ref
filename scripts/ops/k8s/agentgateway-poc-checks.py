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


def llm():
    code, _, body = call("POST", "/v1/chat/completions", OA)
    u = json.loads(body).get("usage") if code == 200 else None
    check("L1", "GLM-5.3 chat completion, buffered", code == 200 and bool(u), f"HTTP {code} usage={u} {body[:160]}")
    code, _, body = call("POST", "/v1/chat/completions", dict(OA, stream=True, stream_options={"include_usage": True}))
    u = usage_of_stream(body)
    check("L1", "GLM-5.3 chat completion, streamed with usage", code == 200 and "[DONE]" in body and bool(u),
          f"HTTP {code} usage={u}")
    code, _, body = call("POST", "/anthropic/v1/messages", AN, headers=AV)
    check("L2", "Anthropic Messages -> Chat Completions conversion, buffered",
          code == 200 and '"type":"message"' in body.replace(" ", ""), f"HTTP {code} {body[:240]}")
    code, _, body = call("POST", "/anthropic/v1/messages", dict(AN, stream=True), headers=AV)
    check("L2", "Anthropic Messages conversion, streamed", code == 200 and "message_stop" in body,
          f"HTTP {code} {body[-200:]}")
    code, _, body = call("POST", "/zai-anthropic/v1/messages", AN, headers=AV)
    check("L2", "Anthropic Messages to Z.ai's native /api/anthropic, buffered",
          code == 200 and '"type":"message"' in body.replace(" ", ""), f"HTTP {code} {body[:240]}")


class Mcp:
    H = {"Accept": "application/json, text/event-stream", "MCP-Protocol-Version": "2025-06-18"}

    def __init__(self):
        code, hdr, body = call("POST", "/mcp", {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
            "protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "agw-poc", "version": "1"}}},
            headers=self.H)
        self.h = dict(self.H)
        if hdr.get("mcp-session-id"):
            self.h["Mcp-Session-Id"] = hdr["mcp-session-id"]
        call("POST", "/mcp", {"jsonrpc": "2.0", "method": "notifications/initialized"}, headers=self.h)
        self.init = code

    def rpc(self, method, params=None):
        code, _, body = call("POST", "/mcp", {"jsonrpc": "2.0", "id": 2, "method": method, "params": params or {}},
                             headers=self.h)
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
        m = Mcp.__new__(Mcp)
        m.h = dict(Mcp.H, **{"Mcp-Session-Id": open("/tmp/mcp-session").read()})
    _, r = m.rpc("tools/call", {"name": "echo_echo_headers", "arguments": {}})
    text = (r.get("result", {}).get("content") or [{}])[0].get("text", "{}")
    seen = json.loads(text) if text.startswith("{") else {}
    check("L3/P4", f"[{phase}] per-target key injected, no Authorization on the MCP hop",
          "x-echo-mcp-key" in seen and "authorization" not in seen,
          f"x-echo-mcp-key={seen.get('x-echo-mcp-key')} authorization={'authorization' in seen}")
    names = m.tools()
    check("L3", f"[{phase}] the session still lists both in-cluster servers' tools",
          {"victoriametrics_documentation", "victorialogs_documentation"} <= set(names), f"tools/list = {names}")


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
{"identity": identity, "sts": sts, "rogue": rogue, "models": models, "llm": llm}.get(cmd, lambda: None)()
if cmd == "mcp":
    mcp(sys.argv[2])
elif cmd == "drain":
    drain(int(sys.argv[2]))
sys.exit(0 if all(RESULTS) else 1)
