#!/agent-server/.venv/bin/python
"""gh pr create, then this run's provenance footer on the pull request (SP2 design §5).

Appended after the create, so every way of writing the body (--body,
--body-file, --fill, a template) gets it. A provenance hint, never
authorisation (SP3 ruling TB): a pull request opened through `gh api`, or a
body rewritten by a later `gh pr edit`, has none, and the merge gate binds
commits to a run by push identity, not by this text.

The footer is still the harness's, never the model's. It is always the last
paragraph, and every line of the body a line-anchored reader would take for an
`Agent-*` key, in any case, is prefixed with MARK first: the model's text
stays readable, but no longer reads as provenance, and cannot pre-empt the
real footer by containing it.
"""
import os
import re
import subprocess
import sys
from urllib.parse import urlsplit

GH = "/usr/local/lib/gh-real"
PR_URL = re.compile(r"https://github\.com/[^/\s]+/[^/\s]+/pull/[0-9]+")
# SP3 ruling SW: Agent-Task is the task id everywhere; the issue or PR URL has its own key.
FIELDS = (("Agent-Room", "ROOM_ID"), ("Agent-Run", "RUN_ID"), ("Agent-Role", "ROLE"),
          ("Agent-Task", "TASK_ID"), ("Agent-Task-URL", "TASK_URL"), ("Agent-Model", "MODEL"))
# The whole namespace, so a prefix reader never takes `Agent-Run-Id:` for Agent-Run.
OWNED = re.compile(r"^[ \t]*agent-[a-z0-9-]*[ \t]*:", re.IGNORECASE | re.MULTILINE)
MARK = "(agent-written) "
# No C0/C1 control or Unicode line separator: each would start a line of its own.
PRINTABLE = re.compile(r"[^\x00-\x1f\x7f-\x9f\u2028\u2029]{1,256}\Z")


def value(env: dict, var: str) -> str:
    v = env.get(var) or ""
    if not PRINTABLE.match(v):
        return ""
    if var == "TASK_URL":
        url = urlsplit(v)
        if url.scheme != "https" or url.netloc != "github.com":
            return ""
    return v


def lines(text: str) -> str:
    """Every line break a renderer or a reader might honour (lone CR, VT, FF, NEL, U+2028...) as \\n."""
    return "\n".join(text.splitlines())


def neutralise(text: str) -> str:
    return OWNED.sub(lambda m: MARK + m.group(0), lines(text))


def footer(env: dict) -> str:
    return "\n".join("%s: %s" % (key, value(env, var)) for key, var in FIELDS if value(env, var))


def with_footer(body: str, env: dict) -> str | None:
    """The body ending with the footer, or None when it already does and nothing above forges it."""
    tail = "---\n" + footer(env)
    text = lines(body).rstrip()
    ends = text == tail or text.endswith("\n\n" + tail)
    head = text[:-len(tail)].rstrip() if ends else text
    clean = neutralise(head)
    if ends and clean == head:
        return None
    return (clean + "\n\n" if clean else "") + tail + "\n"


def main(argv: list, env: dict) -> int:
    created = subprocess.run([GH] + argv, stdout=subprocess.PIPE, text=True)
    sys.stdout.write(created.stdout or "")
    sys.stdout.flush()
    match = PR_URL.search(created.stdout or "")
    if created.returncode != 0 or not match or not value(env, "RUN_ID"):
        return created.returncode
    url = match.group(0)
    try:
        body = subprocess.run([GH, "pr", "view", url, "--json", "body", "--jq", ".body"],
                              check=True, capture_output=True, text=True).stdout
        new = with_footer(body, env)
        if new is not None:
            subprocess.run([GH, "pr", "edit", url, "--body-file", "-"], input=new,
                           check=True, capture_output=True, text=True)
    except subprocess.CalledProcessError as exc:
        # Fail closed: an unedited body may end with a footer the model wrote.
        print("gh: %s was created, but its provenance footer could not be written, so its body "
              "is not trustworthy; fix or close it before going on: %s" % (url, (exc.stderr or str(exc)).strip()),
              file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:], dict(os.environ)))
