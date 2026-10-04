#!/usr/bin/env bash
# requires: jq
#
# scripts/ops/k8s/agent-run.sh against PATH-stubbed roomctl and curl: the body it sends has the
# fields asked for and never a principal or a branch, the token is roomctl's, and each refusal
# of the API reads as a sentence. No test contacts the factory.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUBJECT="$HERE/../../ops/k8s/agent-run.sh"
fails=0
fail() { printf 'FAIL  %s\n' "$*" >&2; fails=$((fails + 1)); }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
printf '#!/usr/bin/env bash\necho tok-123\n' >"$tmp/bin/roomctl"
cat >"$tmp/bin/curl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$STUB_ARGS"
while [ $# -gt 0 ]; do [ "$1" = "--data-binary" ] && { cat >"$STUB_BODY"; }; shift; done
printf '%s\n%s' "${STUB_RESPONSE:-{\"runId\":\"7f3cq2xz\",\"branch\":\"agent/7f3cq2xz\"}}" "${STUB_CODE:-201}"
STUB
chmod +x "$tmp/bin/roomctl" "$tmp/bin/curl"
export PATH="$tmp/bin:$PATH" STUB_ARGS="$tmp/args" STUB_BODY="$tmp/body" AGENT_FACTORY_URL=https://factory.example

out="$(bash "$SUBJECT" --role implementer --class public --task 'Fix "the" link' --profiles pypi,npm 2>"$tmp/err")" || fail "a valid call exits 0"
[ "$out" = "7f3cq2xz" ] || fail "prints only the run id on stdout, got $out"
jq -e '.role == "implementer" and .dataClass == "public" and .repository == "Smana/cloud-native-ref"' "$tmp/body" >/dev/null || fail "role, class, repository"
jq -e '.task == {"text":"Fix \"the\" link"} and .egressProfiles == ["pypi","npm"]' "$tmp/body" >/dev/null || fail "task text survives quoting; profiles split"
jq -e 'has("principal") or has("branch") | not' "$tmp/body" >/dev/null || fail "never sends a principal or a branch (SC-13, C3)"
grep -qx 'Authorization: Bearer tok-123' "$tmp/args" || fail "the token is roomctl's"
grep -qx 'https://factory.example/v1/runs' "$tmp/args" || fail "posts to the factory"
grep -q 'agent/7f3cq2xz' "$tmp/err" || fail "tells the human the branch"

bash "$SUBJECT" --role reviewer --class public --task-url https://github.com/Smana/cloud-native-ref/pull/1 --room 3kq7x2ma >/dev/null 2>&1 || fail "task-url with a room exits 0"
jq -e '.task == {"url":"https://github.com/Smana/cloud-native-ref/pull/1"} and .roomRef == "3kq7x2ma"' "$tmp/body" >/dev/null || fail "task url, room"

STUB_CODE=429 STUB_RESPONSE='{"error":"over_budget"}' bash "$SUBJECT" --role implementer --class public --task x >/dev/null 2>"$tmp/err" && fail "a 429 exits non-zero"
grep -q "daily token budget" "$tmp/err" || fail "a 429 reads as the daily budget"
bash "$SUBJECT" --role implementer --task x >/dev/null 2>&1 && fail "no default data class: classifying data is a decision"
bash "$SUBJECT" --role implementer --class public --branch agent/x --task x >/dev/null 2>&1 && fail "--branch takes agent/<8 chars> only"
bash "$SUBJECT" --role implementer --class public --branch agent/aaaaaaaa --task x >/dev/null 2>&1 || fail "--branch resumes a stopped run"
jq -e '.resumeBranch == "agent/aaaaaaaa" and (has("branch") | not)' "$tmp/body" >/dev/null || fail "sent as resumeBranch, which the factory checks (R35)"
bash "$SUBJECT" --role implementer --class public --task x --dry-run >/dev/null 2>&1 || fail "--dry-run exits 0"

# Fold-in from the kubectl-era suite: a gone flag must read as gone and an
# unknown one as unknown — never a crash, never silence.
bash "$SUBJECT" --role implementer --class public --task x --bogus >/dev/null 2>"$tmp/err" && fail "an unknown argument exits non-zero"
grep -q "unknown argument: --bogus" "$tmp/err" || fail "an unknown argument reads as the unknown argument"
bash "$SUBJECT" --role implementer --class public --task x --minutes 5 >/dev/null 2>"$tmp/err" && fail "--minutes exits non-zero"
grep -q "is gone: the factory sizes the run" "$tmp/err" || fail "--minutes is gone, not silently ignored"
bash "$SUBJECT" --role implementer --class public --task x --size small >/dev/null 2>"$tmp/err" && fail "--size exits non-zero"
grep -q "is gone: the factory sizes the run" "$tmp/err" || fail "--size is gone, not silently ignored"

[ "$fails" -eq 0 ] || exit 1
echo "PASS"
