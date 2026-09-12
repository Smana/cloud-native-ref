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
# One HALF of one field is not golden-compared: `since` measures against
# wall-clock now, so the leading duration token of a firing Duration field is
# asserted against a regex and masked. The clock time it is anchored to is kept,
# and a resolved Duration is kept whole -- both are derived from the fixture's
# own timestamps. Everything else is byte-compared. See VOLATILE_FIELD below for
# why keeping that half matters.
#
#   ./scripts/validate-alertmanager-templates.sh                 # check
#   ./scripts/validate-alertmanager-templates.sh --update-golden # rewrite goldens
#
# It also asserts one thing that is NOT a template at all: that every rendered
# VMAlert has an absolute `-external.url`. That argument is the prefix of every
# alert's generatorURL, which is the Query button's href, so a button whose
# template renders perfectly is still dead if vmalert was started with
# `external.url: "http://"`. It was, on both clusters, for the life of the
# receiver -- see the failure message below for why, and note that no gate in
# this repo could fail on it: the value is a well-formed string in a valid
# field, polaris never reads extraArgs, and this script's own fixtures supply
# their own URLs.
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
import urllib.parse

import yaml

amtool, bundle_dir, mode = sys.argv[1], sys.argv[2], sys.argv[3]
update = mode == "--update-golden"

FIXTURE_DIR = pathlib.Path("scripts/alertmanager-fixtures")
GOLDEN_DIR = FIXTURE_DIR / "golden"
TEMPLATE_KEY = "ogenki.tmpl"
RECEIVER = "slack-monitoring"
# The one field whose rendered value moves with wall-clock time -- and only
# PARTLY. `ogenki.duration` renders one of two shapes:
#
#   14m 0s (since 09:06 UTC)                 firing
#   resolved after 6m 0s (at 09:11 UTC)      resolved
#
# Just the leading token of the FIRING shape is volatile: it is measured against
# `now`. Everything else is computed from the fixture's own timestamps and is
# byte-stable -- including the whole resolved shape, whose duration is
# EndsAt-StartsAt.
#
# Masking the field wholesale therefore threw away the only part that says WHICH
# alert is being described, and that is not a cosmetic loss: it made the
# `.Alerts` vs `.Alerts.Firing` selection in `ogenki.duration` untestable.
# Reverting that fix rendered a byte-identical golden on all five fixtures --
# a silent regression of the exact defect the template exists to avoid, namely
# describing a resolved group member's timing under a FIRING title.
VOLATILE_FIELD = "field:Duration"
FIRING_DURATION_RE = re.compile(r"^(\d[^(]*) (\(since \d{2}:\d{2} UTC\))$")
RESOLVED_DURATION_RE = re.compile(r"^resolved after \d[^(]* \(at \d{2}:\d{2} UTC\)$")

tmpl_text = None
slack = None
vmalerts = []

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
        if doc.get("kind") == "VMAlert":
            extra = (doc.get("spec") or {}).get("extraArgs") or {}
            vmalerts.append((
                path.name,
                (doc.get("metadata") or {}).get("name", "<unnamed>"),
                extra.get("external.url"),
                extra.get("external.alert.source"),
            ))
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

# --- vmalert's -external.url, the prefix of every Query button ----------------
#
# Not a rendered target: no fixture can catch this, because a fixture supplies
# its own generatorURL. It is checked here rather than in .doc-claims.yaml
# because this script already reads the bundle and already owns "the buttons
# must work"; doc-claims answers whether documentation is still true, which is a
# different question from whether config is still correct.

EXTERNAL_URL_CAUSE = """
    The Query button's href is the alert's generatorURL, which vmalert builds as
        <-external.url> + <-external.alert.source>
    The chart derives -external.url from `vm-k8s-stack.grafana.addr`
    (_helpers.tpl:470-482): it reads `.Values.external.grafana.host`, and falls
    back to the Grafana INGRESS host ONLY when `grafana.ingress.enabled` is true.
    Grafana here is routed through a Gateway API HTTPRoute, not an Ingress, so
    that fallback never fires -- with the key unset the address is the EMPTY
    STRING, and the helper's unconditional `http://` prefix leaves
    `external.url: "http://"`.

    Every alert then carries `http:/explore?left={...}` -- one slash, no host.
    Slack SILENTLY DROPS an attachment action whose URL is not valid http(s), so
    the button does not render wrong, it does not render at all. That shipped on
    both clusters and no gate could fail on it.

    Fix: set `external.grafana.host`, WITH a scheme (the helper prefixes
    `http://` to anything without one), in
    observability/base/victoria-metrics-k8s-stack/vm-common-helm-values-configmap.yaml
"""


def external_url_problem(value):
    """Why `value` is unusable as a generatorURL prefix, or None if it is fine."""
    if not isinstance(value, str) or not value.strip():
        return "unset or empty"
    parsed = urllib.parse.urlparse(value.strip())
    if parsed.scheme not in ("http", "https"):
        return "scheme is %r, expected http or https" % (parsed.scheme or "")
    if not parsed.netloc:
        return "no host -- this is the bare scheme that started all of this"
    return None


if not vmalerts:
    # Finding nothing is a FAILURE, never a quiet pass. A gate that checks zero
    # objects and reports success is the exact shape of hole this file exists to
    # close.
    print("error: no VMAlert found in %s." % bundle_dir)
    print("       The Query button's URL comes from vmalert's -external.url, so a")
    print("       bundle with no VMAlert means the render is broken -- not that the")
    print("       configuration is fine.")
    sys.exit(1)

# Which VMAlerts this can judge is read from the DATA, not from a hardcoded
# name -- the same reason validate-vmrules.sh derives its skip predicate from a
# group's `type` rather than a filename.
#
# A VMAlert that sets `external.alert.source` is building deep links into some
# external UI, so its `external.url` is the prefix of every generatorURL it
# emits and MUST be absolute. A VMAlert that sets neither is using vmalert's own
# built-in default (its pod address plus `vmalert/alert?...`), which is a
# different thing and not something this file can judge.
url_failures = []
skipped = []
checked = 0
for src, name, url, source in vmalerts:
    if url is None and source is None:
        skipped.append((src, name))
        continue
    checked += 1
    # Both failure shapes: a present-but-unusable URL (the bare `http://` that
    # started this), and deep links configured with no prefix to hang them on.
    why = external_url_problem(url) if url is not None else \
        "absent, while external.alert.source IS set -- the deep links have no prefix"
    if why:
        url_failures.append((src, name, url, why))

if url_failures:
    print()
    for src, name, value, why in url_failures:
        print("INVALID  VMAlert/%s  [extraArgs external.url]" % name)
        print("    value: %r — %s" % (value, why))
        print("    in %s" % src)
        print()
    print("%d VMAlert(s) would start with an unusable -external.url." % len(url_failures))
    print(EXTERNAL_URL_CAUSE)
    sys.exit(1)

for src, name in skipped:
    # Named on every run, green or red. This is a REAL pre-existing gap, not a
    # shrug: observability/base/victoria-logs/vmalert-vl{single,cluster}.yaml
    # notify the SAME Alertmanager as everything else, so their alerts reach the
    # same Slack receiver -- with a generatorURL pointing at the vmalert pod's
    # own in-cluster address, which no browser outside the cluster can open.
    # Today they evaluate exactly one rule set, the loggen demo VMRule, and
    # fixing them means choosing a VictoriaLogs Explore deep link (datasource +
    # LogsQL shape), which is a design decision rather than a value to copy.
    print("    SKIPPED  VMAlert/%s (in %s) — sets neither external.url nor" % (name, src))
    print("             external.alert.source, so it uses vmalert's built-in default:")
    print("             the pod's own address. NOT checked, and not reachable from a")
    print("             browser. See observability/base/victoria-logs/vmalert-vl*.yaml")

print("==> %d VMAlert(s) carry an absolute external.url. %d skipped and NOT checked%s"
      % (checked, len(skipped), " (listed above)." if skipped else "."))

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
                stripped = out.strip()
                firing = FIRING_DURATION_RE.match(stripped)
                if firing:
                    # Only the leading humanized duration is replaced; the clock
                    # time it is anchored to stays in the golden.
                    out = "<DURATION> %s" % firing.group(2)
                elif not RESOLVED_DURATION_RE.match(stripped):
                    failures.append((fixture.name, label,
                                     "does not look like a duration: %r" % out))
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
