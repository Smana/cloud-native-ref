#!/usr/bin/env bash
# requires: docker python3 curl
#
# The agent trace collector's filter, run for real (observability plan O2, O4, O18; SO-3's
# offline half). The HelmRelease's own agents pipeline, with k8s_attributes swapped for a
# stub that stamps the run id a pod label would, and the exporter swapped for `debug`. A
# span carrying a prompt, a completion, tool input, headers, an exception message and a
# spoofed run id must come out with metadata only; a span that no run sent is dropped.
# Links and tracestate are cleared, and names are capped on a UTF-8 boundary (AK5, I1').
# A second run without the HelmRelease's extraArgs proves the link check can fail: on
# 0.160, set(span.links, nil) is a no-op unless ottl.set.allowNil is on.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
fails=0
fail() { printf 'FAIL  %s\n' "$*" >&2; fails=$((fails + 1)); }
python3 -c 'import yaml' 2>/dev/null || { echo "SKIP: pyyaml not installed"; exit 77; }
docker info >/dev/null 2>&1 || { echo "SKIP: no docker daemon"; exit 77; }

tmp="$(mktemp -d)"
name="agent-traces-filter-$$"
trap 'docker rm -f "$name" "$name-nogate" >/dev/null 2>&1; rm -rf "$tmp"' EXIT

image="$(ROOT="$ROOT" OUT="$tmp/relay.yaml" ARGS="$tmp/args" python3 - <<'PY'
import os
import yaml

path = os.path.join(os.environ["ROOT"], "observability/base/agent-platform/agent-traces-collector.yaml")
hr = next(d for d in yaml.safe_load_all(open(path)) if d and d["kind"] == "HelmRelease")
values = hr["spec"]["values"]
# Flux turns $${...} into ${...} before the chart sees it.
c = yaml.safe_load(yaml.safe_dump(values["alternateConfig"]).replace("$${", "${"))
# No API server here: the stub stamps what k8s_attributes reads from a run pod's labels.
c["processors"]["transform/stub-k8s"] = {"error_mode": "ignore", "trace_statements": [{"statements": [
    'set(resource.attributes["agent.run_id"], "testrun1") where resource.attributes["test.pod"] == "run"',
    'set(resource.attributes["k8s.pod.name"], "xplane-run-testrun1") where resource.attributes["test.pod"] == "run"']}]}
del c["processors"]["k8s_attributes"]
procs = c["service"]["pipelines"]["traces/agents"]["processors"]
procs[procs.index("k8s_attributes")] = "transform/stub-k8s"
# debug prints no span tracestate, so `file` writes the OTLP JSON beside it.
c["exporters"] = {"debug": {"verbosity": "detailed"}, "file": {"path": "/out/spans.json", "flush_interval": "100ms"}}
for pipeline in c["service"]["pipelines"].values():
    pipeline["exporters"] = ["debug", "file"]
c["receivers"]["otlp/agents"]["protocols"]["http"]["endpoint"] = "0.0.0.0:4318"
c["receivers"]["otlp/router"]["protocols"]["grpc"]["endpoint"] = "0.0.0.0:4317"
c["extensions"]["health_check"]["endpoint"] = "0.0.0.0:13133"
c["service"]["telemetry"] = {"metrics": {"level": "none"}}
yaml.safe_dump(c, open(os.environ["OUT"], "w"), sort_keys=False)
# The control: no tracestate statement, and (run without extraArgs) no allowNil gate.
cap = c["processors"]["transform/cap"]["trace_statements"]
for group in cap:
    group["statements"] = [s for s in group["statements"] if "span.trace_state" not in s]
yaml.safe_dump(c, open(os.environ["OUT"].replace(".yaml", "-control.yaml"), "w"), sort_keys=False)
# The chart appends command.extraArgs after --config; so does this replay.
with open(os.environ["ARGS"], "w") as f:
    f.writelines(a + "\n" for a in values.get("command", {}).get("extraArgs", []))
print("%s@%s" % (values["image"]["repository"], values["image"]["digest"]))
PY
)" || { echo "cannot build the test config" >&2; exit 1; }
mapfile -t extra <"$tmp/args"

# Three spans from a run (content, links, caps) and one from no run. The caps span's name is
# "a" then 100 two-byte "é": a byte cut at 128 would split a rune, a safe cut keeps 127 bytes.
ENEE="$(python3 -c 'print("a" + "é" * 100)')"
N300="$(printf 'n%.0s' $(seq 300))"
V300="$(printf 'v%.0s' $(seq 300))"
E300="$(printf 'e%.0s' $(seq 300))"
R300="$(printf 'r%.0s' $(seq 300))"
cat >"$tmp/spans.json" <<EOF
{"resourceSpans":[
 {"resource":{"attributes":[{"key":"test.pod","value":{"stringValue":"run"}},{"key":"agent.run_id","value":{"stringValue":"spoofed1"}},{"key":"service.name","value":{"stringValue":"/agent-server/.venv/bin/python"}}]},
  "scopeSpans":[{"scope":{"name":"lmnr"},"spans":[
   {"traceId":"11111111111111111111111111111111","spanId":"2222222222222222","name":"llm.openai/agent-default","kind":1,"startTimeUnixNano":"1700000000000000000","endTimeUnixNano":"1700000001000000000",
    "attributes":[{"key":"gen_ai.input.messages","value":{"stringValue":"[{\"role\":\"user\",\"content\":\"PROMPT-MARKER-Z7\"}]"}},
                  {"key":"gen_ai.output.messages","value":{"stringValue":"COMPLETION-MARKER-Z7"}},
                  {"key":"lmnr.span.input","value":{"stringValue":"TOOL-INPUT-MARKER-Z7"}},
                  {"key":"lmnr.span.output","value":{"stringValue":"TOOL-OUTPUT-MARKER-Z7"}},
                  {"key":"llm.headers","value":{"stringValue":"{'X-Title': 'HEADER-MARKER-Z7'}"}},
                  {"key":"agent.run_id","value":{"stringValue":"spoofed1"}},
                  {"key":"gen_ai.usage.input_tokens","value":{"intValue":"11"}},
                  {"key":"gen_ai.request.model","value":{"stringValue":"agent-default"}}],
    "events":[{"timeUnixNano":"1700000000500000000","name":"exception","attributes":[{"key":"exception.type","value":{"stringValue":"ValueError"}},{"key":"exception.message","value":{"stringValue":"EVENT-MARKER-Z7"}}]}],
    "status":{"code":2,"message":"STATUS-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx-TAIL"}},
   {"traceId":"11111111111111111111111111111111","spanId":"5555555555555555","name":"linked-span","kind":1,"startTimeUnixNano":"1700000000000000000","endTimeUnixNano":"1700000001000000000",
    "traceState":"vendor=STATE-MARKER-Z7",
    "links":[{"traceId":"66666666666666666666666666666666","spanId":"7777777777777777","traceState":"k=LINK-MARKER-Z7",
              "attributes":[{"key":"link.note","value":{"stringValue":"LINK-MARKER-Z7"}}]}]}]},
  {"scope":{"name":"$N300","version":"$V300"},"spans":[
   {"traceId":"11111111111111111111111111111111","spanId":"8888888888888888","name":"$ENEE","kind":1,"startTimeUnixNano":"1700000000000000000","endTimeUnixNano":"1700000001000000000",
    "attributes":[{"key":"gen_ai.response.id","value":{"stringValue":"$R300"}}],
    "events":[{"timeUnixNano":"1700000000500000000","name":"$E300"}]}]}]},
 {"resource":{"attributes":[{"key":"test.pod","value":{"stringValue":"other"}}]},
  "scopeSpans":[{"spans":[{"traceId":"33333333333333333333333333333333","spanId":"4444444444444444","name":"UNATTRIBUTED-SPAN","kind":1,"startTimeUnixNano":"1700000000000000000","endTimeUnixNano":"1700000001000000000"}]}]}
]}
EOF

# replay <container> <config> [collector args…]: start the collector, POST the fixture, and
# once both exporters hold all three run spans, leave $tmp/<container>.log (debug's text)
# and $tmp/<container>/spans.json (file's OTLP JSON).
replay() {
  local c="$1" conf="$2" port code=""
  shift 2
  mkdir -p "$tmp/$c" && chmod 0777 "$tmp/$c"   # the image runs as uid 10001
  docker run -d --name "$c" -p 127.0.0.1::4318 -v "$conf:/conf/relay.yaml:ro" -v "$tmp/$c:/out" "$image" \
    --config=/conf/relay.yaml "$@" >/dev/null || { fail "cannot start $image"; return 1; }
  port="$(docker port "$c" 4318/tcp | head -1 | sed 's/.*://')"
  for _ in $(seq 1 120); do
    code="$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' --data @"$tmp/spans.json" "http://127.0.0.1:$port/v1/traces")"
    [ "$code" = 200 ] && break
    [ "$(docker inspect -f '{{.State.Running}}' "$c")" = true ] || break
    sleep 0.25
  done
  [ "$code" = 200 ] || { fail "$c: POST /v1/traces answered '$code'"; docker logs "$c" 2>&1 | tail -20 >&2; return 1; }
  [ "$c" = "$name" ] && { [ "$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' -d '{}' "http://127.0.0.1:$port/v1/logs")" = 404 ] \
    || fail "the collector serves no logs path"; }
  for _ in $(seq 1 80); do
    docker logs "$c" >"$tmp/$c.log" 2>&1
    [ "$(grep -c '^Span #' "$tmp/$c.log")" -ge 3 ] && grep -q 8888888888888888 "$tmp/$c/spans.json" 2>/dev/null && return 0
    sleep 0.25
  done
  fail "$c: the exporters did not both hold the 3 run spans within 20s ($(grep -c '^Span #' "$tmp/$c.log") printed)"
}

replay "$name" "$tmp/relay.yaml" "${extra[@]}"
out="$(cat "$tmp/$name.log" "$tmp/$name/spans.json" 2>/dev/null)"

for m in PROMPT COMPLETION TOOL-INPUT TOOL-OUTPUT HEADER EVENT LINK STATE; do
  grep -q "$m-MARKER-Z7" <<<"$out" && fail "$m content reached the exporter"
done
grep -q 'SpanLink #' <<<"$out" && fail "a span link reached the exporter"
grep -q '"links"' <<<"$out" && fail "a span link reached the file exporter"
grep -q '"traceState"' <<<"$out" && fail "a span's tracestate reached the file exporter"
grep -q 'spoofed1' <<<"$out" && fail "a span's own agent.run_id survived"
grep -q 'UNATTRIBUTED-SPAN' <<<"$out" && fail "a span that no run sent was exported"
grep -q -- '-TAIL' <<<"$out" && fail "the status message was not capped"
[ "$(grep -c 'agent.run_id: Str(testrun1)' <<<"$out")" -eq 4 ] || fail "the run id is on the resource and on each of the 3 spans"
for keep in 'service.name: Str(agent-harness)' 'gen_ai.usage.input_tokens: Int(11)' 'gen_ai.request.model: Str(agent-default)' 'exception.type: Str(ValueError)'; do
  grep -qF "$keep" <<<"$out" || fail "metadata dropped: $keep"
done
# Lengths in bytes, read from the raw log so a split rune shows up as one.
while IFS= read -r problem; do fail "$problem"; done < <(LOG="$tmp/$name.log" python3 - <<'PY'
import os
import re

log = open(os.environ["LOG"], "rb").read()


def one(pattern, what):
    found = re.findall(pattern, log, re.M)
    if len(found) != 1:
        print(f"{what}: expected one match, found {len(found)}")
        return None
    return found[0]


checks = [
    (rb"^    Name\s+: (a\S*)$", "span.name", 127),
    (rb"^InstrumentationScope (n+) v+", "scope.name", 256),
    (rb"^InstrumentationScope n+ (v+)", "scope.version", 256),
    (rb"-> Name: (e+)$", "spanevent.name", 256),
    (rb"gen_ai\.response\.id: Str\((r+)\)", "an allowlisted attribute", 256),
]
for pattern, what, want in checks:
    got = one(pattern, what)
    if got is None:
        continue
    if len(got) != want:
        print(f"{what} is {len(got)} bytes, want {want}")
    try:
        got.decode("utf-8")
    except UnicodeDecodeError:
        print(f"{what} was cut inside a UTF-8 rune")
PY
)

# The control must leak both, or the link and tracestate checks above prove nothing.
replay "$name-nogate" "$tmp/relay-control.yaml"
control="$(cat "$tmp/$name-nogate.log" "$tmp/$name-nogate/spans.json" 2>/dev/null)"
grep -q 'LINK-MARKER-Z7' <<<"$control" \
  || fail "without ${extra[*]:-its extraArgs} the link still vanished: the link checks cannot fail"
grep -q 'STATE-MARKER-Z7' <<<"$control" \
  || fail "without set(span.trace_state, \"\") the tracestate still vanished: that check cannot fail"

if [ "$fails" -ne 0 ]; then
  printf '%s\n' "$out" | tail -80 >&2
  exit 1
fi
echo PASS
