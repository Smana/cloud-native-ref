#!/usr/bin/env bash
# requires: python3 git
#
# Merge gate classes MC5: findings.py keeps 404, 410 and a name that does not resolve, and drops
# 403, 429, 5xx, timeouts and a refused connection; the archive is upgraded to https. A fixture
# lychee report and a stub availability API, no other network but the resolver.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUBJECT="$HERE/../../../.github/scripts/dead-links/findings.py"
fails=0
fail() { printf 'FAIL  %s\n' "$*" >&2; fails=$((fails + 1)); }
d="$(mktemp -d)"
# Under the agent checks: the stubs below are on 127.0.0.1, never through the egress proxy, and
# the image's system git config (a commit-msg hook) would refuse the fixture commits.
export NO_PROXY="127.0.0.1,localhost${NO_PROXY:+,$NO_PROXY}" no_proxy="127.0.0.1,localhost${no_proxy:+,$no_proxy}"
export GIT_CONFIG_NOSYSTEM=1
trap 'kill "$stub" 2>/dev/null; rm -rf "$d"' EXIT
# A stub listens when it accepts a connection, not after a fixed sleep: under gVisor the
# interpreter alone can take longer than a second to start.
ready() {
  python3 -c 'import socket, sys, time
for _ in range(100):
    try: socket.create_connection(("127.0.0.1", int(sys.argv[1])), 0.2).close(); break
    except OSError: time.sleep(0.1)
else: sys.exit("stub on port %s never listened" % sys.argv[1])' "$1" || fail "stub on port $1 never listened"
}

cat >"$d/lychee.json" <<'JSON'
{"error_map": {
  "docs/a.md": [
    {"url": "https://example.com/gone", "status": {"text": "Rejected status code: 404 Not Found", "code": 404}, "span": {"line": 3, "column": 4}},
    {"url": "https://example.com/removed", "status": {"text": "Rejected status code: 410 Gone", "code": 410}, "span": {"line": 4, "column": 4}},
    {"url": "https://example.com/forbidden", "status": {"text": "Rejected status code: 403 Forbidden", "code": 403}, "span": {"line": 5, "column": 4}},
    {"url": "https://example.com/limited", "status": {"text": "Rejected status code: 429 Too Many Requests", "code": 429}, "span": {"line": 6, "column": 4}},
    {"url": "https://example.com/down", "status": {"text": "Rejected status code: 503 Service Unavailable", "code": 503}, "span": {"line": 7, "column": 4}},
    {"url": "https://dead-links-fixture.invalid/x", "status": {"text": "Network error: Connection failed.", "details": "Connection failed."}, "span": {"line": 8, "column": 4}},
    {"url": "http://127.0.0.1:1/x", "status": {"text": "Network error: Connection refused", "details": "Connection refused"}, "span": {"line": 9, "column": 4}}
  ]},
 "timeout_map": {"docs/a.md": [{"url": "https://example.com/slow", "status": {"text": "Timeout"}}]}}
JSON

WAYBACK_API=off python3 "$SUBJECT" "$d/lychee.json" >"$d/out.json" || fail "findings.py exited $?"
got=$(python3 -c 'import json,sys; print(" ".join(f["status"]+"="+f["url"] for f in json.load(open(sys.argv[1]))))' "$d/out.json")
want="nxdomain=https://dead-links-fixture.invalid/x 404=https://example.com/gone 410=https://example.com/removed"
# A name that does not resolve is only told apart from a resolver that does not answer when a
# resolver answers: without one (a sandbox) the finding is rightly dropped.
if ! python3 -c 'import socket
try: socket.getaddrinfo("dead-links-fixture.invalid", 443)
except socket.gaierror as e: raise SystemExit(e.errno != socket.EAI_NONAME)' 2>/dev/null; then
  echo "note  no resolver answers here: the nxdomain case is not checked"
  want="404=https://example.com/gone 410=https://example.com/removed"
fi
[ "$got" = "$want" ] || fail "findings: got '$got', want '$want'"

keys=$(python3 -c 'import json,sys; print(sorted({",".join(sorted(f)) for f in json.load(open(sys.argv[1]))}))' "$d/out.json")
[ "$keys" = "['archive,file,line,status,url']" ] || fail "keys: got $keys, want exactly archive,file,line,status,url (the factory decodes strictly)"

port=$((20000 + RANDOM % 20000))
cat >"$d/stub.py" <<'PY'
import http.server, json, sys
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200); self.end_headers()
        self.wfile.write(json.dumps({"archived_snapshots": {"closest": {"status": "200", "available": True,
            "url": "http://web.archive.org/web/20261011195309/https://example.com/gone"}}}).encode())
    def log_message(self, *a): pass
http.server.HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
PY
python3 "$d/stub.py" "$port" & stub=$!
ready "$port"
WAYBACK_API="http://127.0.0.1:$port/" WAYBACK_PACE=0 python3 "$SUBJECT" "$d/lychee.json" >"$d/arch.json" || fail "findings.py exited $?"
# By URL, not by position: without a resolver the nxdomain finding is not there to come first.
arch=$(python3 -c 'import json,sys; print(next((f.get("archive", "") for f in json.load(open(sys.argv[1])) if f["url"] == "https://example.com/gone"), ""))' "$d/arch.json")
[ "$arch" = "https://web.archive.org/web/20261011195309/https://example.com/gone" ] || fail "archive: got '$arch', want the https snapshot"

# The factory refuses a whole run over one out-of-shape finding: such entries are never emitted,
# and an http:// snapshot (or one that is not of this URL) is dropped to "".
cat >"$d/shape.json" <<'JSON'
{"error_map": {"docs/b.md": [
  {"url": "https://en.wikipedia.org/wiki/Foo_(bar)", "status": {"code": 404}, "span": {"line": 1}},
  {"url": "https://user@example.com/x", "status": {"code": 404}, "span": {"line": 2}},
  {"url": "https://example.com/100%", "status": {"code": 404}, "span": {"line": 5}},
  {"url": "https://example.com/ok", "status": {"code": 404}, "span": {"line": 3}},
  {"url": "https://example.com/other", "status": {"code": 404}, "span": {"line": 4}}
]}}
JSON
cat >"$d/stub2.py" <<'PY'
import http.server, json, sys
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200); self.end_headers()
        self.wfile.write(json.dumps({"archived_snapshots": {"closest": {"status": "200", "available": True,
            "url": "http://web.archive.org/web/20261011195309/https://example.com/ok"}}}).encode())
    def log_message(self, *a): pass
http.server.HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
PY
port2=$((port + 1))
python3 "$d/stub2.py" "$port2" & stub2=$!
ready "$port2"
WAYBACK_API="http://127.0.0.1:$port2/" WAYBACK_PACE=0 python3 "$SUBJECT" "$d/shape.json" >"$d/shape-out.json" || fail "findings.py exited $?"
kill "$stub2" 2>/dev/null
shape=$(python3 -c 'import json,sys; print(" ".join(f["url"]+"|"+f["archive"] for f in json.load(open(sys.argv[1]))))' "$d/shape-out.json")
[ "$shape" = "https://example.com/ok|https://web.archive.org/web/20261011195309/https://example.com/ok https://example.com/other|" ] || fail "shape: got '$shape', want ok with its snapshot and other with none"

# changed-targets.sh: only the external targets a pull request adds or changes. lychee is stubbed
# (--dump prints the URLs of the file), so the suite stays offline.
mkdir "$d/bin" "$d/repo"
# shellcheck disable=SC2016
printf '#!/usr/bin/env bash\nfor f; do :; done\ngrep -oE "https?://[^ )>]+" "$f"\n' >"$d/bin/lychee"
chmod +x "$d/bin/lychee"
(
  cd "$d/repo" && git init -q -b main && git config user.email t@t && git config user.name t
  printf '[old](https://example.com/old)\n' >a.md && git add a.md && git commit -qm base
  git checkout -qb pr
  printf '[old](https://example.com/old)\n[new](https://example.com/new)\n' >a.md
  printf '[b](https://example.com/b)\n' >b.md
  git add . && git commit -qm change
) >/dev/null 2>&1
ct=$(cd "$d/repo" && PATH="$d/bin:$PATH" bash "$HERE/../../../.github/scripts/dead-links/changed-targets.sh" main | tr '\n' ' ')
[ "$ct" = "https://example.com/b https://example.com/new " ] || fail "changed-targets: got '$ct', want only the new and the added target"

[ "$fails" -eq 0 ] && echo "ok  dead-links findings" || exit 1
