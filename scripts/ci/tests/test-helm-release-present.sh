#!/usr/bin/env bash
#
# helm-release-present.sh with a stub helm on PATH: the terraform data-external
# helper answers true for an installed release and false for everything else --
# absent release, missing helm, broken kubeconfig, empty or missing name or
# namespace -- and never exits non-zero, because a diagnostic here would block
# the plan instead of letting helm report a real conflict.
#
# Terraform sends the query JSON with NO trailing newline, so the stdin read
# must stay `input=$(cat)`: the header documents that a `read` form returns
# non-zero at EOF even though it populated the variable, and any `|| default`
# then throws the real input away. The last two checks pin that contract: a
# mutated copy using `read -r input || input=` must answer false for a release
# the real script reports present.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SUT="$ROOT/scripts/provision/helm-release-present.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"
fails=0
check() { if eval "$2"; then echo "  ok   $1"; else echo "  FAIL $1"; fails=1; fi; }

# STUB_HELM_FAIL=1 makes every call fail, as a broken kubeconfig would;
# otherwise a `status` on present-release succeeds and anything else fails.
cat >"$T/bin/helm" <<'EOF'
#!/usr/bin/env bash
if [ -n "${STUB_HELM_FAIL:-}" ]; then
  echo "Error: Kubernetes cluster unreachable: invalid configuration" >&2
  exit 1
fi
case "$*" in
  *status*present-release*) exit 0 ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$T/bin/helm"

# run <label> <expected present> <query-json> [env...] -- feeds the query (with
# no trailing newline, terraform's wire format) to the SUT and checks exit code,
# JSON validity via jq, and the present value.
run() {
  local label="$1" expected="$2" query="$3"; shift 3
  out="$(printf '%s' "$query" | env "$@" PATH="$T/bin:$PATH" bash "$SUT" 2>/dev/null)"
  rc=$?
  check "$label: exit 0" '[ "$rc" -eq 0 ]'
  check "$label: valid JSON" 'jq -e . >/dev/null 2>&1 <<<"$out"'
  check "$label: present $expected" "[ \"\$(jq -r .present <<<\"\$out\")\" = '$expected' ]"
}

run "release present (no trailing newline)" true '{"name":"present-release","namespace":"flux"}'
run "release absent" false '{"name":"absent-release","namespace":"flux"}'
run "broken kubeconfig (helm status fails)" false '{"name":"present-release","namespace":"flux"}' STUB_HELM_FAIL=1
run "empty name" false '{"name":"","namespace":"flux"}'
run "missing name" false '{"namespace":"flux"}'
run "empty namespace" false '{"name":"present-release","namespace":""}'
run "missing namespace" false '{"name":"present-release"}'
run "empty object" false '{}'
run "stdin that is not JSON" false 'not json'

# helm missing from PATH: a minimal PATH holding only bash and jq, so no host
# helm can leak in and flip the answer.
mkdir -p "$T/bin-nohelm"
ln -s "$(command -v bash)" "$T/bin-nohelm/bash"
ln -s "$(command -v jq)" "$T/bin-nohelm/jq"
out="$(printf '%s' '{"name":"present-release","namespace":"flux"}' | env PATH="$T/bin-nohelm" bash "$SUT" 2>/dev/null)"; rc=$?
check "helm missing from PATH: exit 0" '[ "$rc" -eq 0 ]'
check "helm missing from PATH: valid JSON" 'jq -e . >/dev/null 2>&1 <<<"$out"'
check "helm missing from PATH: present false" '[ "$(jq -r .present <<<"$out")" = false ]'

# The contract the header documents: `read` returns non-zero at EOF even though
# it populated the variable, so any `|| default` throws terraform's real query
# away. The mutant must therefore answer false for a release the real script
# reports present -- this is the check that fails if anyone "simplifies" the
# stdin read to a read form with a fallback.
sed 's/input=\$(cat)/read -r input || input=/' "$SUT" >"$T/mutant.sh"
mutated_out="$(printf '%s' '{"name":"present-release","namespace":"flux"}' | env PATH="$T/bin:$PATH" bash "$T/mutant.sh" 2>/dev/null)"
check "a read-with-default stdin parse answers false" '[ "$(jq -r .present <<<"$mutated_out" 2>/dev/null)" = false ]'
check "the SUT reads stdin with input=\$(cat), not a read form" 'grep -q "input=\$(cat)" "$SUT" && ! grep -qE "read (-r )?input" "$SUT"'

[ "$fails" -eq 0 ] && echo "all checks passed"
exit "$fails"
