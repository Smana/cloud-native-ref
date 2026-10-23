#!/usr/bin/env python3
"""findings.json from a lychee JSON report: the dead-links detector's verdict (merge gate MC5).

A finding is a link target that answered 404 or 410 after redirects, or whose host name does not
resolve (the resolver's EAI_NONAME, checked here: lychee reports it as a generic connection
failure). 403, 429, 5xx, timeouts and every other error are never findings. Each finding carries
the Wayback Machine's closest snapshot when one exists, as https.

    findings.py lychee.json > findings.json

The archive is best effort: archive.org answers 429 after a few requests from one address, so
lookups are paced (WAYBACK_PACE seconds apart, 5 by default), at most 20 a run, and the first
refusal ends them for the run. A finding without an archive is still a finding. WAYBACK_API
overrides the availability endpoint (tests); WAYBACK_API=off skips the lookup.
"""
import json
import os
import posixpath
import re
import socket
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

WAYBACK = os.environ.get("WAYBACK_API", "https://archive.org/wayback/available")
PACE = float(os.environ.get("WAYBACK_PACE", "5"))
GONE = {404: "404", 410: "410"}
lookups = {"left": 20}
# The factory (agent-platform internal/factory/intake/deadlinks.go, keepable) refuses a whole run
# over one finding outside these shapes, so such a finding is never emitted.
ARCHIVE_RE = re.compile(r"^https://web\.archive\.org/web/[0-9]{1,14}/https://[^\s<>()]+$")
BAD_URL_CHARS = " \t\r\n<>()"


def nxdomain(url):
    try:
        host = urllib.parse.urlsplit(url).hostname
    except ValueError:
        return False
    if not host:
        return False
    try:
        socket.getaddrinfo(host, 443)
    except socket.gaierror as e:
        return e.errno == socket.EAI_NONAME
    return False


def snapshot(url):
    if WAYBACK == "off" or lookups["left"] <= 0:
        return ""
    if lookups["left"] < 20:
        time.sleep(PACE)
    lookups["left"] -= 1
    q = WAYBACK + "?" + urllib.parse.urlencode({"url": url})
    req = urllib.request.Request(q, headers={"User-Agent": "dead-links (+https://github.com/Smana/cloud-native-ref)"})
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            closest = json.load(r).get("archived_snapshots", {}).get("closest") or {}
    except urllib.error.HTTPError:
        lookups["left"] = 0  # a 429 or worse: no more lookups this run
        return ""
    except (OSError, ValueError):
        return ""
    snap = closest.get("url", "")
    if closest.get("available") is not True or closest.get("status") != "200" or not snap:
        return ""
    if snap.startswith("http://web.archive.org/"):  # the API answers http; R52 retargets https to https only
        snap = "https://" + snap[len("http://"):]
    return snap if snap.startswith("https://web.archive.org/web/") else ""


def shaped(file, url):
    """keepable's checks: a clean relative path of at most 512 characters; an http(s) URL that,
    for https, has a host, no userinfo, at most 2048 characters and none of ` \\t\\r\\n<>()`."""
    if posixpath.normpath(file) != file or file.startswith(("/", "..")) or len(file) > 512:
        return False
    try:
        u = urllib.parse.urlsplit(url)
        u.port  # noqa: B018 - raises ValueError on a malformed port
    except ValueError:
        return False
    if u.scheme not in ("http", "https"):
        return False
    if u.scheme == "http":
        return True
    return bool(u.netloc and u.hostname) and "@" not in u.netloc and len(url) <= 2048 \
        and not any(c in url for c in BAD_URL_CHARS) \
        and not re.search(r"%(?![0-9A-Fa-f]{2})", url)  # Go's url.Parse refuses a bare %


def main(path):
    report = json.load(open(path))
    out = []
    for file, entries in sorted((report.get("error_map") or {}).items()):
        for e in entries:
            url, code = e["url"], e.get("status", {}).get("code")
            # lychee normalises a bare host to a trailing "/": the factory drops that finding as no
            # link target of its file, which is the right outcome, so no special case here.
            if not shaped(file.removeprefix("./"), url):
                continue
            status = GONE.get(code) or ("nxdomain" if code is None and nxdomain(url) else None)
            if status is None:
                continue
            f = {"file": file.removeprefix("./"), "line": max(1, (e.get("span") or {}).get("line") or 1), "url": url, "status": status,
                 "archive": ""}
            snap = snapshot(url)
            if ARCHIVE_RE.match(snap) and snap.endswith("/" + url) and len(snap) <= 2048:
                f["archive"] = snap  # the factory's decoder is strict: all five keys, archive "" when none
            out.append(f)
    out.sort(key=lambda f: (f["file"], f["url"]))
    json.dump(out, sys.stdout, indent=1)
    sys.stdout.write("\n")


if __name__ == "__main__":
    main(sys.argv[1])
