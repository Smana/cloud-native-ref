#!/bin/sh
# MCP over streamable HTTP from the agent probe, with its token of one class.
# usage: agent-probe-mcp.sh <public|internal|internal-reviewer> <method> [params-json] [port]
# The 4th arg overrides the listener port -- e.g. point an internal-class
# token at 8080 to prove the cross-class 401 (review M9).
set -eu
CLASS=$1 METHOD=$2 PARAMS=${3:-"{}"}
case "$CLASS" in
  public) PORT=8080 ;;
  *) PORT=8081 ;;
esac
PORT=${4:-$PORT}
URL=http://agent-router.envoy-gateway-system.svc.cluster.local:$PORT/mcp

# mktemp, not a fixed path: two classes probed in parallel must not clobber
# each other's token or session headers (review M9).
AUTH=$(mktemp /tmp/agent-probe-auth.XXXXXX)
HDRS=$(mktemp /tmp/agent-probe-hdrs.XXXXXX)
trap 'rm -f "$AUTH" "$HDRS"' EXIT

# The token reaches curl through a header file, never its argv (the class
# test-no-secret-argv.sh guards), and is re-read on every run.
{ printf 'Authorization: Bearer '; cat "/var/run/secrets/probe/$CLASS/token"; } > "$AUTH"
ACCEPT='accept: application/json, text/event-stream'
INIT_STATUS=$(curl -s -m 20 -D "$HDRS" -o /dev/null -w '%{http_code}' -H @"$AUTH" -H "$ACCEPT" -H 'content-type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"agent-probe","version":"1"}}}' "$URL")
# Printed even on success: a 401 here would otherwise surface only as a
# confusing empty session ID on the next call (review M9).
echo "initialize: HTTP $INIT_STATUS" >&2
SID=$(grep -i '^mcp-session-id:' "$HDRS" | cut -d' ' -f2 | tr -d '\r' || true)
curl -s -m 20 -o /dev/null -H @"$AUTH" -H "$ACCEPT" -H "mcp-session-id: $SID" -H 'content-type: application/json' \
  -d '{"jsonrpc":"2.0","method":"notifications/initialized"}' "$URL"
curl -s -m 20 -w '\nHTTP %{http_code}\n' -H @"$AUTH" -H "$ACCEPT" -H "mcp-session-id: $SID" -H 'content-type: application/json' \
  -d "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"$METHOD\",\"params\":$PARAMS}" "$URL"
# Best-effort: terminate the session (MCP Streamable HTTP transport, DELETE).
# Never fails the probe -- server support for it isn't load-bearing here.
curl -s -m 20 -o /dev/null -X DELETE -H @"$AUTH" -H "mcp-session-id: $SID" "$URL" || true
