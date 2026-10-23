#!/usr/bin/env python3
# requires: python3
"""The sandbox checks' declaration mirrors the CI (v3 feature 3, RC2, RC3, offline proof 1).

.github/agent-checks.yaml is what an agent runs in its sandbox before it pushes, read by the harness
from the default branch. This suite holds it to the same schema the harness enforces, and to the
CI: every job of a workflow that runs on pull_request is named by a step's `ci` or by a `ciOnly`
entry, every name the declaration uses is such a job, every tool is a key mise.toml pins, every
definedBy path exists. A job is named by its check name (its `name`, else its id; a static matrix
adds `name (value, ...)`) or as `<workflow file stem>/<job id>`. The same file runs in
cloud-native-ref and ai-native-ref, on the repository the working directory is in.

Run: python3 scripts/ci/tests/test-agent-checks.py
"""
import itertools
import pathlib
import re
import subprocess
import sys
import tomllib

try:
    import yaml
except ImportError:
    print("SKIP: pyyaml not installed")
    sys.exit(77)

# The working directory's repository: ai-native-ref runs its suites from .composite/ with the
# working directory in this repository (scripts/ci/run-tests.sh); the host from its root.
ROOT = pathlib.Path(subprocess.run(["git", "rev-parse", "--show-toplevel"], capture_output=True, text=True).stdout.strip() or ".")
DECL = ROOT / ".github/agent-checks.yaml"
STEP_NAME = re.compile(r"^[a-z0-9][a-z0-9-]{0,39}$")
MAX_MINUTES = 15
fails = []


def fail(msg):
    fails.append(msg)


def step_has_ci(step):
    return isinstance(step.get("ci"), str) and bool(step["ci"].strip())


# Self-test: a step without a non-empty `ci` must fail, as the harness's validate() has it.
assert not step_has_ci({"name": "x", "run": "true"}) and not step_has_ci({"ci": " "}) and step_has_ci({"ci": "job"}), "step_has_ci"


def pr_jobs():
    """{identifier: job key} for every job of a workflow triggered by pull_request, and the job keys."""
    ids, keys = {}, set()
    for wf in sorted((ROOT / ".github/workflows").glob("*.y*ml")):
        doc = yaml.safe_load(wf.read_text()) or {}
        on = doc.get("on", doc.get(True)) or {}
        events = [on] if isinstance(on, str) else list(on)
        if not {"pull_request", "pull_request_target"} & set(events):
            continue
        for jid, job in (doc.get("jobs") or {}).items():
            key = "%s/%s" % (wf.stem, jid)
            keys.add(key)
            name = str(job.get("name") or jid)
            names = {key, name}
            matrix = (job.get("strategy") or {}).get("matrix")
            if isinstance(matrix, dict) and "${{" not in name:
                axes = [v for k, v in matrix.items() if k not in ("include", "exclude") and isinstance(v, list)]
                if axes:
                    names |= {"%s (%s)" % (name, ", ".join(map(str, combo))) for combo in itertools.product(*axes)}
            for n in names:
                ids.setdefault(n, set()).add(key)
    return ids, keys


if not DECL.is_file():
    print("FAIL .github/agent-checks.yaml: missing")
    sys.exit(1)
doc = yaml.safe_load(DECL.read_text())
if not isinstance(doc, dict):
    print("FAIL .github/agent-checks.yaml: not a mapping")
    sys.exit(1)

# The schema the harness enforces (agent-platform images/agent-harness/agent_checks.py, validate).
if extra := set(doc) - {"version", "timeoutMinutes", "tools", "definedBy", "steps", "ciOnly"}:
    fail("unknown keys %s" % sorted(extra))
if doc.get("version") != 1:
    fail("version must be 1")
minutes = doc.get("timeoutMinutes", 8)
if not (isinstance(minutes, int) and 1 <= minutes <= MAX_MINUTES):
    fail("timeoutMinutes must be 1 to %d" % MAX_MINUTES)
    minutes = MAX_MINUTES
try:
    pinned = tomllib.loads((ROOT / "mise.toml").read_text()).get("tools", {})
except (OSError, tomllib.TOMLDecodeError) as exc:
    pinned = {}
    fail("mise.toml: %s" % exc)
for t in doc.get("tools", []):
    if t not in pinned:
        fail("tool %s is not a key of mise.toml's [tools]" % t)
for p in doc.get("definedBy", []):
    if not (ROOT / p).exists() or (p.endswith("/") and not (ROOT / p).is_dir()):
        fail("definedBy %s does not exist" % p)
steps = doc.get("steps") or []
if not steps:
    fail("steps must be a non-empty list")
seen = set()
for s in steps:
    name = s.get("name") if isinstance(s, dict) else None
    if not isinstance(name, str) or not STEP_NAME.match(name) or name in seen:
        fail("step %r: names are unique and match %s" % (name, STEP_NAME.pattern))
        continue
    seen.add(name)
    if extra := set(s) - {"name", "run", "ci", "timeoutMinutes", "stopOnFailure"}:
        fail("step %s: unknown keys %s" % (name, sorted(extra)))
    if not (isinstance(s.get("run"), str) and s["run"].strip()):
        fail("step %s: no run" % name)
    if not step_has_ci(s):
        fail("step %s: no ci, the CI job it mirrors" % name)
    t = s.get("timeoutMinutes", minutes)
    if not (isinstance(t, int) and 1 <= t <= minutes):
        fail("step %s: timeoutMinutes must be 1 to %d" % (name, minutes))
    if not isinstance(s.get("stopOnFailure", False), bool):
        fail("step %s: stopOnFailure is a boolean" % name)
ci_only = doc.get("ciOnly") or []
for c in ci_only:
    if not (isinstance(c, dict) and set(c) == {"check", "part", "why"} and all(isinstance(v, str) and v for v in c.values())):
        fail("ciOnly entry %r: exactly check, part and why, each a string" % (c,))

# The coverage rule (RC3): every pull_request job is mirrored or listed, every name is a job.
ids, keys = pr_jobs()
named = [("step %s" % s.get("name"), s.get("ci")) for s in steps if isinstance(s, dict)]
named += [("ciOnly entry %s" % c.get("check"), c.get("check")) for c in ci_only if isinstance(c, dict)]
covered = set()
for where, n in named:
    if n not in ids:
        fail("%s names %r, which is no job of a pull_request workflow" % (where, n))
    else:
        covered |= ids[n]
for key in sorted(keys - covered):
    fail("job %s runs on pull_request and is neither a step's ci nor a ciOnly entry" % key)

for msg in fails:
    print("FAIL", msg)
if fails:
    sys.exit(1)
print("PASS %d steps, %d CI-only entries, %d pull_request jobs covered" % (len(steps), len(ci_only), len(keys)))
