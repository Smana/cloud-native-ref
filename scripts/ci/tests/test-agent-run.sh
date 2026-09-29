#!/usr/bin/env bash
# requires: jq python3
#
# scripts/ops/k8s/agent-run.sh against a PATH-stubbed kubectl: the claim it
# creates has a valid runId and the fields asked for, and it refuses to guess a
# data class or a task. No test contacts a cluster.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUBJECT="$HERE/../../ops/k8s/agent-run.sh"
fails=0
fail() { printf 'FAIL  %s\n' "$*" >&2; fails=$((fails + 1)); }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
# STUB_FAIL=1 simulates a cluster-side rejection: still consumes stdin (so a
# claim built before the failure is inspectable) but exits non-zero, the way
# a CEL/admission rejection would.
cat >"$tmp/bin/kubectl" <<'STUB'
#!/usr/bin/env bash
# The grafana HTTPRoute answers the Grafana host the dashboard link is built from (SO-5);
# any other `get` fails, as a wrong resource or namespace would.
if [ "$*" = "get httproute grafana -n observability -o jsonpath={.spec.hostnames[0]}" ]; then printf '%s' "${STUB_HOST:-}"; exit 0; fi
[ "$1" = get ] && exit 1
printf '%s\n' "$*" >"$STUB_ARGS"
cat >"$STUB_CLAIM"
[ "${STUB_FAIL:-0}" = "1" ] && exit 1
exit 0
STUB
chmod +x "$tmp/bin/kubectl"
export PATH="$tmp/bin:$PATH" STUB_ARGS="$tmp/args" STUB_CLAIM="$tmp/claim" AGENT_PRINCIPAL="human:312345678901234567"
unset AGENT_GRAFANA_URL

out="$(bash "$SUBJECT" --role implementer --class public --task 'Fix "the" link' --profiles pypi,npm 2>/dev/null)" || fail "a valid call exits 0"
jq -e '.metadata.name | test("^xplane-run-[a-z2-7]{8}$")' "$STUB_CLAIM" >/dev/null || fail "runId is 8 characters of [a-z2-7]"
[ "$out" = "$(jq -r .metadata.name "$STUB_CLAIM")" ] || fail "prints only the run's name on stdout"
jq -e '.metadata.namespace == "agents" and .spec.role == "implementer" and .spec.dataClass == "public"' "$STUB_CLAIM" >/dev/null || fail "namespace, role, class"
jq -e '.spec.task == {"text":"Fix \"the\" link"} and .spec.egress.profiles == ["pypi","npm"]' "$STUB_CLAIM" >/dev/null || fail "task text survives quoting; profiles split"
jq -e '.spec.principal == "human:312345678901234567" and .spec.budget.maxMinutes == 120 and (.spec | has("branch") | not)' "$STUB_CLAIM" >/dev/null || fail "principal, default minutes, no branch unless asked"
grep -qx 'create -f -' "$STUB_ARGS" || fail "creates from stdin without dry-run by default (never apply: a run must always be new)"

bash "$SUBJECT" --role reviewer --class internal --task-url https://github.com/Smana/cloud-native-ref/pull/1 --dry-run >/dev/null 2>&1 || fail "task-url call exits 0"
jq -e '.spec.task == {"url":"https://github.com/Smana/cloud-native-ref/pull/1"}' "$STUB_CLAIM" >/dev/null || fail "task url"
grep -qx 'create --dry-run=server -f -' "$STUB_ARGS" || fail "--dry-run is server-side"

bash "$SUBJECT" --role implementer --class public --task x --branch agent/7f3cq2xz --dry-run >/dev/null 2>&1 || fail "a --branch call exits 0"
jq -e '.spec.branch == "agent/7f3cq2xz"' "$STUB_CLAIM" >/dev/null || fail "--branch lands in .spec.branch"

bash "$SUBJECT" --role implementer --task x >/dev/null 2>&1; [ $? -eq 2 ] || fail "refuses a missing data class"
bash "$SUBJECT" --role implementer --class public >/dev/null 2>&1; [ $? -eq 2 ] || fail "refuses a missing task"
bash "$SUBJECT" --role implementer --class public --task x --task-url y >/dev/null 2>&1; [ $? -eq 2 ] || fail "refuses both task forms"
bash "$SUBJECT" --role implementer --class public --task x --bogus y >/dev/null 2>&1; [ $? -eq 2 ] || fail "refuses an unknown flag"

bash "$SUBJECT" --role bogus --class public --task x >/dev/null 2>&1; [ $? -eq 2 ] || fail "refuses an unknown --role"
bash "$SUBJECT" --role implementer --class bogus --task x >/dev/null 2>&1; [ $? -eq 2 ] || fail "refuses an unknown --class"
bash "$SUBJECT" --role implementer --class public --task x --size bogus >/dev/null 2>&1; [ $? -eq 2 ] || fail "refuses an unknown --size"
bash "$SUBJECT" --role implementer --class public --task x --minutes abc >/dev/null 2>&1; [ $? -eq 2 ] || fail "refuses a non-numeric --minutes"
bash "$SUBJECT" --role implementer --class public --task x --minutes 0 >/dev/null 2>&1; [ $? -eq 2 ] || fail "refuses --minutes below 1"
bash "$SUBJECT" --role implementer --class public --task x --minutes 481 >/dev/null 2>&1; [ $? -eq 2 ] || fail "refuses --minutes above 480"
bash "$SUBJECT" --role implementer --class public --task x --minutes 480 --dry-run >/dev/null 2>&1 || fail "accepts --minutes at the upper bound"
bash "$SUBJECT" --role implementer --class public --task x --minutes 99999999999999999999999999 >/dev/null 2>&1; [ $? -eq 2 ] || fail "refuses a --minutes value that overflows arithmetic"

AGENT_PRINCIPAL="bogus" bash "$SUBJECT" --role implementer --class public --task x >/dev/null 2>&1; [ $? -eq 2 ] || fail "refuses a malformed AGENT_PRINCIPAL"
AGENT_PRINCIPAL="system:Agent-Factory" bash "$SUBJECT" --role implementer --class public --task x >/dev/null 2>&1; [ $? -eq 2 ] || fail "refuses an uppercase system: principal"
AGENT_PRINCIPAL="system:agentFactory" bash "$SUBJECT" --role implementer --class public --task x >/dev/null 2>&1; [ $? -eq 2 ] || fail "refuses an uppercase character past the first in a system: principal"
AGENT_PRINCIPAL="human:a b" bash "$SUBJECT" --role implementer --class public --task x >/dev/null 2>&1; [ $? -eq 2 ] || fail "refuses a space in a human: principal"
AGENT_PRINCIPAL="system:agent-factory" bash "$SUBJECT" --role implementer --class public --task x --dry-run >/dev/null 2>&1 || fail "accepts a valid system: principal"
jq -e '.spec.principal == "system:agent-factory"' "$STUB_CLAIM" >/dev/null || fail "a valid system: principal reaches the claim"

# A cluster-side rejection (bad CEL, exhausted budget, ...) must not print a
# run name: callers pipe stdout straight into `| tail -1` to get the name.
fail_out="$(STUB_FAIL=1 bash "$SUBJECT" --role implementer --class public --task x 2>/dev/null)"
fail_rc=$?
[ "$fail_rc" -ne 0 ] || fail "a failing kubectl create still exits non-zero"
[ -z "$fail_out" ] || fail "no run name is printed when kubectl create fails"

# The claim's key fields go to stderr so a stale AGENT_PRINCIPAL or a --role
# typo is visible without a follow-up kubectl get.
err="$(bash "$SUBJECT" --role implementer --class public --task x 2>&1 >/dev/null)"
printf '%s' "$err" | grep -q 'principal=human:312345678901234567' || fail "stderr echoes the principal used"
printf '%s' "$err" | grep -q 'role=implementer' || fail "stderr echoes the role"
printf '%s' "$err" | grep -q 'dataClass=public' || fail "stderr echoes the data class"
printf '%s' "$err" | grep -q 'repository=Smana/cloud-native-ref' || fail "stderr echoes the repository"
printf '%s' "$err" | grep -q 'maxMinutes=120' || fail "stderr echoes maxMinutes"

# No AGENT_PRINCIPAL and no git user.email configured: a clean exit 2 naming
# the missing config, never bash's raw `git config` failure under set -e.
email_home="$(mktemp -d)"
email_rc=0
email_out="$(cd "$email_home" && env -u AGENT_PRINCIPAL HOME="$email_home" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null \
  bash "$SUBJECT" --role implementer --class public --task x 2>&1)" || email_rc=$?
rm -rf "$email_home"
[ "$email_rc" -eq 2 ] || fail "a missing git user.email exits 2"
printf '%s' "$email_out" | grep -qi 'user.email' || fail "the missing-email message names git config user.email"

# SO-5: the run's page goes to stderr, so `| tail -1` still yields the run's name.
out="$(AGENT_GRAFANA_URL=https://grafana.example bash "$SUBJECT" --role implementer --class public --task x 2>"$tmp/err")"
[ "$out" = "$(jq -r .metadata.name "$STUB_CLAIM")" ] || fail "stdout is still only the run's name"
run_id="$(jq -r '.metadata.name | sub("^xplane-run-"; "")' "$STUB_CLAIM")"
grep -qE "^agent-run: dashboard https://grafana\.example/d/agent-run/agent-run\?var-run=${run_id}&from=[0-9]{13}&to=now$" "$tmp/err" \
  || fail "stderr carries the run's dashboard link"
STUB_HOST=grafana.stub.example bash "$SUBJECT" --role implementer --class public --task x 2>"$tmp/err" >/dev/null
grep -q 'agent-run: dashboard https://grafana.stub.example/d/agent-run/agent-run?var-run=' "$tmp/err" \
  || fail "without AGENT_GRAFANA_URL the host comes from the grafana HTTPRoute"
bash "$SUBJECT" --role implementer --class public --task x 2>"$tmp/err" >/dev/null || fail "no Grafana host is not an error"
grep -q 'agent-run: dashboard' "$tmp/err" && fail "no host, no link"
AGENT_GRAFANA_URL=https://grafana.example bash "$SUBJECT" --role implementer --class public --task x --dry-run 2>"$tmp/err" >/dev/null
grep -q 'agent-run: dashboard' "$tmp/err" && fail "a dry run creates no run, so it prints no link"

bash "$SUBJECT" --role implementer --class public --task x --room 3kq7x2ma --dry-run >/dev/null 2>&1 || fail "a --room call exits 0"
jq -e '.spec.roomRef == "3kq7x2ma" and .spec.branch == "agent/3kq7x2ma"' "$STUB_CLAIM" >/dev/null || fail "--room sets roomRef and the room's shared branch"
bash "$SUBJECT" --role implementer --class public --task x --room 3kq7x2ma --branch agent/7f3cq2xz --dry-run >/dev/null 2>&1 || fail "--room with --branch exits 0"
jq -e '.spec.branch == "agent/7f3cq2xz"' "$STUB_CLAIM" >/dev/null || fail "an explicit --branch wins"
bash "$SUBJECT" --role implementer --class public --task x --room ROOM >/dev/null 2>&1; [ $? -eq 2 ] || fail "refuses a --room that is not a C2 id"
bash "$SUBJECT" --role implementer --class public --task x --dry-run >/dev/null 2>&1
jq -e '.spec | has("roomRef") | not' "$STUB_CLAIM" >/dev/null || fail "no roomRef unless asked"
AGENT_GRAFANA_URL=https://grafana.example bash "$SUBJECT" --role implementer --class public --task x --room 3kq7x2ma 2>"$tmp/err" >/dev/null
grep -q 'room=3kq7x2ma branch=agent/3kq7x2ma' "$tmp/err" || fail "stderr echoes the room and its branch"
grep -q '^agent-run: dashboard https://grafana.example/' "$tmp/err" || fail "a room run still prints its dashboard link"

[ "$fails" -eq 0 ] || exit 1
echo "PASS"
