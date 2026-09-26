#!/agent-server/.venv/bin/python
"""git-credential-agent: git's credential helper inside an AgentRun sandbox.

`get` exchanges through identity-proxy :4001 for a <= 1 h installation token
scoped to $REPOSITORY and $ROLE (octo-sts, C6), and caches it in memory
(/run/agent/git is a Memory emptyDir, T3). `token` prints it for gh. `revoke`
deletes it at GitHub; preStop and agent-run both call it.
"""
import json
import os
import sys
import time
import urllib.request

CACHE = os.environ.get("GIT_TOKEN_CACHE", "/run/agent/git/token.json")
GITHUB_API = os.environ.get("GITHUB_API", "https://api.github.com")
# Installation tokens live 1 h. Refresh with 10 minutes to spare.
LIFETIME_S = 3600
REFRESH_MARGIN_S = 600


def _cached() -> str | None:
    try:
        with open(CACHE) as f:
            entry = json.load(f)
    except (OSError, ValueError):
        return None
    if entry.get("expires_at", 0) - time.time() > REFRESH_MARGIN_S:
        return entry.get("token")
    return None


def _exchange() -> str:
    url = "{}?scope={}&identity=agent-{}".format(os.environ["STS_URL"], os.environ["REPOSITORY"], os.environ["ROLE"])
    with urllib.request.urlopen(url, timeout=15) as resp:
        token = json.load(resp)["token"]
    fd = os.open(CACHE, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        json.dump({"token": token, "expires_at": time.time() + LIFETIME_S}, f)
    return token


def token() -> str:
    return _cached() or _exchange()


def revoke() -> None:
    try:
        with open(CACHE) as f:
            value = json.load(f)["token"]
    except (OSError, ValueError, KeyError):
        return
    req = urllib.request.Request(GITHUB_API + "/installation/token", method="DELETE", headers={"Authorization": "Bearer " + value})
    try:
        urllib.request.urlopen(req, timeout=10)
    finally:
        os.remove(CACHE)


def main(argv: list[str]) -> int:
    action = argv[1] if len(argv) > 1 else ""
    if action == "get":
        attrs = dict(line.split("=", 1) for line in sys.stdin.read().splitlines() if "=" in line)
        if attrs.get("host") != "github.com":
            return 0
        sys.stdout.write("username=x-access-token\npassword={}\n".format(token()))
    elif action == "token":
        sys.stdout.write(token() + "\n")
    elif action == "revoke":
        revoke()
    # `store` and `erase` are no-ops: the cache is ours, not git's.
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
