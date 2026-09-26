#!/bin/sh
# MCP over streamable HTTP from the agent probe, with its token of one class.
# usage: agent-probe-mcp.sh <public|internal> <method> [params-json]
set -eu
CLASS=$1 METHOD=$2 PARAMS=${3:-"{}"}
PORT=8080
[ "$CLASS" = internal ] && PORT=8081
URL=http://agent-router.envoy-gateway-system.svc.cluster.local:$PORT/mcp
# The token reaches curl through a header file, never its argv (the class
# test-no-secret-argv.sh guards), and is re-read on every run.
{ printf 'Authorization: Bearer '; cat "/var/run/secrets/probe/$CLASS/token"; } > /tmp/auth
ACCEPT='accept: application/json, text/event-stream'
curl -s -D /tmp/h -o /dev/null -H @/tmp/auth -H "$ACCEPT" -H 'content-type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"agent-probe","version":"1"}}}' "$URL"
SID=$(grep -i '^mcp-session-id:' /tmp/h | cut -d' ' -f2 | tr -d '\r' || true)
curl -s -o /dev/null -H @/tmp/auth -H "$ACCEPT" -H "mcp-session-id: $SID" -H 'content-type: application/json' \
  -d '{"jsonrpc":"2.0","method":"notifications/initialized"}' "$URL"
curl -s -w '\nHTTP %{http_code}\n' -H @/tmp/auth -H "$ACCEPT" -H "mcp-session-id: $SID" -H 'content-type: application/json' \
  -d "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"$METHOD\",\"params\":$PARAMS}" "$URL"
