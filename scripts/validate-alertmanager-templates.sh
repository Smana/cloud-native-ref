#!/usr/bin/env bash
#
# validate-alertmanager-templates.sh — render the Slack notification templates.
#
# `flux schema validate` proves the Alertmanager config is a well-shaped
# Secret; polaris never looks at it. Neither one parses the Go templates
# inside, and a template that fails to parse or execute does not degrade
# gracefully: Alertmanager drops the notification. Every alert, silently, for
# as long as the template is broken. That is the same failure mode
# validate-vmrules.sh exists to prevent, one layer further out.
#
# What is rendered, and why it comes from the bundle rather than the source:
# the message is assembled from TWO places. The Go templates live in
# alertmanager.templateFiles (-> a ConfigMap), but `fallback`, every
# `fields[].value` and all four button URLs are templated strings inside the
# receiver in the Alertmanager config Secret. Reading the rendered bundle gets
# both, already Flux-substituted -- so an unsubstituted ${var} or a typo in a
# field value fails here too.
#
# Durations are not golden-compared: `since` measures against wall-clock now,
# so the Duration field is asserted against a regex instead and masked in the
# golden output. Everything else is byte-compared.
#
#   ./scripts/validate-alertmanager-templates.sh                 # check
#   ./scripts/validate-alertmanager-templates.sh --update-golden # rewrite goldens
#
# Requires a rendered bundle. validate-manifests.sh runs this after the render;
# standalone, run that script first or set BUNDLE_DIR to an existing bundle.
set -euo pipefail
cd "$(dirname "$0")/.."
REPO_ROOT="$(pwd)"

BUNDLE_DIR="${BUNDLE_DIR:-.bundle}"
MODE="${1:-check}"

if [ ! -d "${BUNDLE_DIR}" ]; then
  echo "error: no bundle at ${BUNDLE_DIR}." >&2
  echo "       Fix: ./scripts/validate-manifests.sh  (renders it), or set BUNDLE_DIR." >&2
  exit 2
fi

# Same resolution precedence as validate-vmrules.sh: explicit override > mise
# scoped to this repo > bare PATH. The pin is what makes "it renders" mean the
# same thing on a laptop and in CI.
if [ -n "${AMTOOL_BIN:-}" ]; then
  if [ ! -x "${AMTOOL_BIN}" ]; then
    echo "error: \$AMTOOL_BIN='${AMTOOL_BIN}' is set but is not an executable file." >&2
    exit 2
  fi
else
  AMTOOL_BIN=""
  if command -v mise >/dev/null 2>&1 && [ -f "${REPO_ROOT}/mise.toml" ]; then
    AMTOOL_BIN="$(mise which -C "${REPO_ROOT}" amtool 2>/dev/null || true)"
    if [ -z "${AMTOOL_BIN}" ]; then
      _where="$(mise where -C "${REPO_ROOT}" aqua:prometheus/alertmanager 2>/dev/null || true)"
      [ -n "${_where}" ] && AMTOOL_BIN="$(find "${_where}" -name amtool -type f -perm -u+x | head -1)"
    fi
  fi
  [ -z "${AMTOOL_BIN}" ] && AMTOOL_BIN="$(command -v amtool 2>/dev/null || true)"
fi

if [ -z "${AMTOOL_BIN}" ]; then
  echo "error: amtool not found (checked \$AMTOOL_BIN, mise, PATH)." >&2
  echo "       amtool ships inside the alertmanager release archive and is pinned" >&2
  echo "       in mise.toml. Fix: mise install  (or set AMTOOL_BIN)" >&2
  exit 2
fi

if ! python3 -c 'import yaml' >/dev/null 2>&1; then
  echo "error: the Python 'yaml' module (PyYAML) is not installed." >&2
  exit 2
fi

python3 - "${AMTOOL_BIN}" "${BUNDLE_DIR}" "${MODE}" <<'PY'
import difflib
import pathlib
import re
import subprocess
import sys
import tempfile

import yaml

amtool, bundle_dir, mode = sys.argv[1], sys.argv[2], sys.argv[3]
update = mode == "--update-golden"

FIXTURE_DIR = pathlib.Path("scripts/alertmanager-fixtures")
GOLDEN_DIR = FIXTURE_DIR / "golden"
TEMPLATE_KEY = "ogenki.tmpl"
RECEIVER = "slack-monitoring"
# The one field whose rendered value moves with wall-clock time.
VOLATILE_FIELD = "field:Duration"
DURATION_RE = re.compile(r"^(\d|resolved after).*")

tmpl_text = None
slack = None

for path in sorted(pathlib.Path(bundle_dir).rglob("*.yaml")):
    try:
        docs = list(yaml.safe_load_all(path.read_text(encoding="utf-8", errors="replace")))
    except yaml.YAMLError:
        continue
    for doc in docs:
        if not isinstance(doc, dict):
            continue
        if doc.get("kind") == "ConfigMap":
            data = doc.get("data") or {}
            if TEMPLATE_KEY in data:
                tmpl_text = data[TEMPLATE_KEY]
        if doc.get("kind") == "Secret":
            raw = (doc.get("stringData") or {}).get("alertmanager.yaml")
            if not raw:
                continue
            try:
                cfg = yaml.safe_load(raw)
            except yaml.YAMLError:
                continue
            for recv in (cfg or {}).get("receivers") or []:
                if recv.get("name") != RECEIVER:
                    continue
                for sc in recv.get("slack_configs") or []:
                    slack = sc

if tmpl_text is None:
    print("error: no ConfigMap in %s carries a %r key." % (bundle_dir, TEMPLATE_KEY))
    print("       The Slack templates ship via alertmanager.templateFiles in")
    print("       observability/base/victoria-metrics-k8s-stack/vm-common-helm-values-configmap.yaml.")
    sys.exit(1)

if slack is None:
    print("error: no receiver %r with a slack_configs entry in the rendered "
          "Alertmanager config." % RECEIVER)
    sys.exit(1)

# Every templated string the receiver hands to Slack, in render order.
targets = []
for key in ("color", "fallback", "title", "title_link", "text"):
    if key in slack:
        targets.append((key, slack[key]))
for field in slack.get("fields") or []:
    targets.append(("field:%s" % field.get("title", "<untitled>"), field.get("value", "")))
for action in slack.get("actions") or []:
    targets.append(("action:%s" % action.get("text", "<untitled>"), action.get("url", "")))

BAD = (("<no value>", "a template referenced a field that does not exist"),
       ("${", "a Flux variable was never substituted"),
       ("%!", "a Go format verb failed"))

with tempfile.NamedTemporaryFile("w", suffix=".tmpl", delete=False, encoding="utf-8") as fh:
    fh.write(tmpl_text)
    tmpl_path = fh.name

failures = []
rendered_files = 0

try:
    for fixture in sorted(FIXTURE_DIR.glob("*.json")):
        chunks = []
        for label, text in targets:
            proc = subprocess.run(
                [amtool, "template", "render",
                 "--template.glob", tmpl_path,
                 "--template.text", text,
                 "--template.data", str(fixture)],
                capture_output=True, text=True,
            )
            if proc.returncode != 0:
                failures.append((fixture.name, label,
                                 "amtool failed to render:\n%s" % (proc.stderr.strip() or proc.stdout.strip())))
                chunks.append("==> %s\n<RENDER FAILED>" % label)
                continue
            out = proc.stdout.rstrip("\n")
            for needle, why in BAD:
                if needle in out:
                    failures.append((fixture.name, label,
                                     "output contains %r — %s:\n%s" % (needle, why, out)))
            if not out.strip():
                failures.append((fixture.name, label, "rendered empty"))
            if label == VOLATILE_FIELD:
                if not DURATION_RE.match(out.strip()):
                    failures.append((fixture.name, label,
                                     "does not look like a duration: %r" % out))
                out = "<DURATION>"
            chunks.append("==> %s\n%s" % (label, out))

        actual = "\n\n".join(chunks) + "\n"
        golden = GOLDEN_DIR / (fixture.stem + ".txt")
        if update:
            GOLDEN_DIR.mkdir(parents=True, exist_ok=True)
            golden.write_text(actual, encoding="utf-8")
            rendered_files += 1
            continue
        if not golden.exists():
            failures.append((fixture.name, "-", "no golden file at %s — run with --update-golden" % golden))
            continue
        expected = golden.read_text(encoding="utf-8")
        if expected != actual:
            diff = "\n".join(difflib.unified_diff(
                expected.splitlines(), actual.splitlines(),
                fromfile=str(golden), tofile="rendered", lineterm="",
            ))
            failures.append((fixture.name, "-", "output changed:\n%s" % diff))
        rendered_files += 1
finally:
    pathlib.Path(tmpl_path).unlink()

if update:
    print("==> Rewrote %d golden file(s) in %s" % (rendered_files, GOLDEN_DIR))
    print("    Read the diff before committing: it IS the Slack message.")
    sys.exit(0)

if failures:
    print()
    for fixture, label, detail in failures:
        print("INVALID  %s  [%s]" % (fixture, label))
        for line in detail.splitlines():
            print("    %s" % line)
        print()
    print("%d problem(s) rendering the Slack templates.\n"
          "Alertmanager drops a notification whose template fails, so this would\n"
          "be a silent, total loss of alerting. If the change is intentional,\n"
          "re-render with --update-golden and review the diff."
          % len(failures))
    sys.exit(1)

print("==> %d templated string(s) render across %d fixture(s); all match their golden files"
      % (len(targets), rendered_files))
PY
