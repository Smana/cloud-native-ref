"""PoC probe: an HTTP echo (/echo) and a minimal stateless MCP server (/mcp).

It reports what the gateway forwarded, never a credential's value: P2 (forged
identity header), P4 (no Authorization on the MCP hop, injected key, tool,
prompt and resource filtering).
"""
import json
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

SECRET_HEADERS = {"authorization", "x-echo-mcp-key", "cookie"}

TOOLS = [
    {"name": "echo_headers", "description": "Return the headers the gateway forwarded",
     "inputSchema": {"type": "object", "properties": {}}},
    {"name": "admin_delete", "description": "A tool no role may call",
     "inputSchema": {"type": "object", "properties": {}}},
]
PROMPTS = [{"name": "p_public", "description": "allowed"}, {"name": "p_secret", "description": "denied"}]
RESOURCES = [{"uri": "res://public", "name": "public"}, {"uri": "res://secret", "name": "secret"}]


def seen_headers(headers):
    out = {}
    for k, v in headers.items():
        out[k.lower()] = f"<present len={len(v)}>" if k.lower() in SECRET_HEADERS else v
    return out


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        pass

    def _send(self, code, body, extra=None):
        data = json.dumps(body).encode() if body is not None else b""
        self.send_response(code)
        if body is not None:
            self.send_header("Content-Type", "application/json")
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _log(self, method):
        print(json.dumps({"path": self.path, "rpc": method, "headers": seen_headers(self.headers)}), flush=True)

    def do_GET(self):
        if self.path.startswith("/healthz"):
            return self._send(200, {"ok": True})
        self._log(None)
        if self.path.startswith("/mcp"):
            return self._send(405, {"error": "no SSE stream"})
        return self._send(200, {"path": self.path, "headers": seen_headers(self.headers)})

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length) if length else b"{}"
        if not self.path.startswith("/mcp"):
            self._log(None)
            return self._send(200, {"path": self.path, "headers": seen_headers(self.headers)})
        try:
            req = json.loads(raw)
        except ValueError:
            return self._send(400, {"error": "bad json"})
        method, rid, params = req.get("method"), req.get("id"), req.get("params") or {}
        self._log(method)
        if rid is None:
            return self._send(202, None)
        if method == "initialize":
            result = {"protocolVersion": params.get("protocolVersion", "2025-06-18"),
                      "capabilities": {"tools": {}, "prompts": {}, "resources": {}},
                      "serverInfo": {"name": "agw-echo", "version": "0.1.0"}}
        elif method == "tools/list":
            result = {"tools": TOOLS}
        elif method == "tools/call":
            text = json.dumps(seen_headers(self.headers))
            result = {"content": [{"type": "text", "text": text}]}
        elif method == "prompts/list":
            result = {"prompts": PROMPTS}
        elif method == "prompts/get":
            result = {"messages": [{"role": "user", "content": {"type": "text", "text": "prompt " + params.get("name", "")}}]}
        elif method == "resources/list":
            result = {"resources": RESOURCES}
        elif method == "resources/read":
            uri = params.get("uri", "")
            result = {"contents": [{"uri": uri, "text": "content of " + uri}]}
        elif method == "ping":
            result = {}
        else:
            return self._send(200, {"jsonrpc": "2.0", "id": rid, "error": {"code": -32601, "message": "not found"}})
        return self._send(200, {"jsonrpc": "2.0", "id": rid, "result": result})


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8080
    ThreadingHTTPServer(("0.0.0.0", port), Handler).serve_forever()
