"""agent-server's start-up hook: agent-run puts this directory first on agent-server's PYTHONPATH
(server_env), and Python imports sitecustomize from it before anything else.

F29: a backend's `ping` reaches agent-server through agent-router with its numeric id unrewritten,
so agent-router answers the client's reply 400 "invalid response ID type" (envoyproxy/ai-gateway#2715).
mcp 1.28.1 sends a reply inline from StreamableHTTPTransport.post_writer: _handle_post_request's
raise_for_status() ends post_writer, which closes both session streams, while fastmcp's
is_connected() stays True. Every later tool call then fails with an empty ClosedResourceError and
the SDK's reconnect-once never fires. A refused reply costs the run nothing, so it is logged and
dropped; requests and notifications are untouched. Belt and braces: agent-router is being fixed to
answer client replies 202 itself (F29's gateway half); the harness does not depend on it.
"""
import logging
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
log = logging.getLogger("agent-harness.mcp")


def patch(transport, httpx, replies) -> bool:
    """Wraps transport._handle_post_request so a 4xx to one of `replies` is logged, not raised."""
    original = getattr(transport, "_handle_post_request", None)
    if original is None:
        print("agent-harness: F29 patch NOT applied: %s has no _handle_post_request (an mcp upgrade?); "
              "a refused reply to a server ping will end the MCP session" % transport.__name__,
              file=sys.stderr, flush=True)
        return False

    async def _handle_post_request(self, ctx):
        try:
            await original(self, ctx)
        except httpx.HTTPStatusError as exc:
            if not (isinstance(ctx.session_message.message.root, replies) and 400 <= exc.response.status_code < 500):
                raise
            log.warning("F29: the MCP server refused this client's reply to its request (HTTP %d); "
                        "the session is kept", exc.response.status_code)

    transport._handle_post_request = _handle_post_request
    return True


def _install() -> None:
    # agent-server's children, the agent's own commands, must not load this.
    rest = [p for p in os.environ.get("PYTHONPATH", "").split(os.pathsep) if p and os.path.abspath(p) != HERE]
    if rest:
        os.environ["PYTHONPATH"] = os.pathsep.join(rest)
    else:
        os.environ.pop("PYTHONPATH", None)
    try:
        import httpx
        from mcp.client.streamable_http import StreamableHTTPTransport
        from mcp.types import JSONRPCError, JSONRPCResponse
    except ImportError as exc:
        print("agent-harness: F29 patch NOT applied: %s" % exc, file=sys.stderr, flush=True)
        return
    patch(StreamableHTTPTransport, httpx, (JSONRPCResponse, JSONRPCError))


if __name__ == "sitecustomize":
    _install()
