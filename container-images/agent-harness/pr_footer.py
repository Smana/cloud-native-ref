#!/agent-server/.venv/bin/python
"""gh pr create, then this run's provenance footer on the pull request (SP2 design §5).

Appended after the create, so every way of writing the body (--body,
--body-file, --fill, a template) gets it. Guidance, not a control, like the
commit-msg hook: a pull request opened through `gh api`, or a body rewritten by
a later `gh pr edit`, has none.

The footer is the harness's, never the model's. It is always the last
paragraph, and any line of the body a line-anchored reader would take for one
of its keys, in any case, is prefixed with MARK first: the model's text stays
readable, but no longer reads as provenance, and cannot pre-empt the real
footer by containing it.
"""
import os
import re
import subprocess
import sys

GH = "/usr/local/lib/gh-real"
PR_URL = re.compile(r"https://github\.com/[^/\s]+/[^/\s]+/pull/[0-9]+")
# SP3 ruling SW: Agent-Task is the task id everywhere; the issue or PR URL has its own key.
FIELDS = (("Agent-Room", "ROOM_ID"), ("Agent-Run", "RUN_ID"), ("Agent-Role", "ROLE"),
          ("Agent-Task", "TASK_ID"), ("Agent-Task-URL", "TASK_URL"), ("Agent-Model", "MODEL"))
OWNED = re.compile(r"^[ \t]*(?:%s)[ \t]*:" % "|".join(re.escape(key) for key, _ in FIELDS),
                   re.IGNORECASE | re.MULTILINE)
MARK = "(agent-written) "
# A line break in a value would write a footer line of its own.
PRINTABLE = re.compile(r"[^\x00-\x1f\x7f]+\Z")


def value(env: dict, var: str) -> str:
    v = env.get(var) or ""
    return v if PRINTABLE.match(v) else ""


def neutralise(text: str) -> str:
    return OWNED.sub(lambda m: MARK + m.group(0), text)


def footer(env: dict) -> str:
    return "\n".join("%s: %s" % (key, value(env, var)) for key, var in FIELDS if value(env, var))


def with_footer(body: str, env: dict) -> str | None:
    """The body ending with the footer, or None when it already does and nothing above forges it."""
    tail = "---\n" + footer(env)
    text = body.replace("\r\n", "\n").rstrip()
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
        # The pull request exists: a missing footer must not fail the agent's step.
        print("gh: the provenance footer was not added: %s" % (exc.stderr or exc), file=sys.stderr)
    return created.returncode


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:], dict(os.environ)))
