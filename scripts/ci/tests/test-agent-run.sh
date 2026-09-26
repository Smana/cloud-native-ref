#!/usr/bin/env bash
# requires: jq python3
#
# scripts/ops/k8s/agent-run.sh against a PATH-stubbed kubectl: the claim it
# applies has a valid runId and the fields asked for, and it refuses to guess a
# data class or a task. No test contacts a cluster.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUBJECT="$HERE/../../ops/k8s/agent-run.sh"
fails=0
fail() { printf 'FAIL  %s\n' "$*" >&2; fails=$((fails + 1)); }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
cat >"$tmp/bin/kubectl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >"$STUB_ARGS"
cat >"$STUB_CLAIM"
STUB
chmod +x "$tmp/bin/kubectl"
export PATH="$tmp/bin:$PATH" STUB_ARGS="$tmp/args" STUB_CLAIM="$tmp/claim" AGENT_PRINCIPAL="human:312345678901234567"

out="$(bash "$SUBJECT" --role implementer --class public --task 'Fix "the" link' --profiles pypi,npm)" || fail "a valid call exits 0"
jq -e '.metadata.name | test("^xplane-run-[a-z2-7]{8}$")' "$STUB_CLAIM" >/dev/null || fail "runId is 8 characters of [a-z2-7]"
[ "$out" = "$(jq -r .metadata.name "$STUB_CLAIM")" ] || fail "prints the run's name"
jq -e '.metadata.namespace == "agents" and .spec.role == "implementer" and .spec.dataClass == "public"' "$STUB_CLAIM" >/dev/null || fail "namespace, role, class"
jq -e '.spec.task == {"text":"Fix \"the\" link"} and .spec.egress.profiles == ["pypi","npm"]' "$STUB_CLAIM" >/dev/null || fail "task text survives quoting; profiles split"
jq -e '.spec.principal == "human:312345678901234567" and .spec.budget.maxMinutes == 120 and (.spec | has("branch") | not)' "$STUB_CLAIM" >/dev/null || fail "principal, default minutes, no branch unless asked"
grep -qx 'apply -f -' "$STUB_ARGS" || fail "applies from stdin without dry-run by default"

bash "$SUBJECT" --role reviewer --class internal --task-url https://github.com/Smana/cloud-native-ref/pull/1 --dry-run >/dev/null || fail "task-url call exits 0"
jq -e '.spec.task == {"url":"https://github.com/Smana/cloud-native-ref/pull/1"}' "$STUB_CLAIM" >/dev/null || fail "task url"
grep -qx 'apply --dry-run=server -f -' "$STUB_ARGS" || fail "--dry-run is server-side"

bash "$SUBJECT" --role implementer --task x >/dev/null 2>&1; [ $? -eq 2 ] || fail "refuses a missing data class"
bash "$SUBJECT" --role implementer --class public >/dev/null 2>&1; [ $? -eq 2 ] || fail "refuses a missing task"
bash "$SUBJECT" --role implementer --class public --task x --task-url y >/dev/null 2>&1; [ $? -eq 2 ] || fail "refuses both task forms"

[ "$fails" -eq 0 ] || exit 1
echo "PASS"
