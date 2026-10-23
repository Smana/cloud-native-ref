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
trap 'kill "$stub" 2>/dev/null; rm -rf "$d"' EXIT

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
sleep 1
WAYBACK_API="http://127.0.0.1:$port/" WAYBACK_PACE=0 python3 "$SUBJECT" "$d/lychee.json" >"$d/arch.json" || fail "findings.py exited $?"
arch=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[1].get("archive", ""))' "$d/arch.json")
[ "$arch" = "https://web.archive.org/web/20261011195309/https://example.com/gone" ] || fail "archive: got '$arch', want the https snapshot"

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
