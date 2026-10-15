#!/usr/bin/env bash
#
# helm-release-present.sh with helm stubbed on PATH: every input answers valid
# JSON and exits 0, "true" only when `helm status` succeeds. Stdin carries no
# trailing newline, as terraform sends it.
#
# The same cases then run against copies whose `input=$(cat)` is swapped for a
# `read` form, and must fail there: the header's trap is only guarded if
# reverting the fix turns this suite red.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SCRIPT="$ROOT/scripts/provision/helm-release-present.sh"
BASH_BIN="$(command -v bash)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

mkdir -p "$T/bin" "$T/nohelm"
cat >"$T/bin/helm" <<EOF
#!/usr/bin/env bash
echo "\$*" >>"$T/helm-calls"
if [ -n "\${STUB_HELM_BROKEN:-}" ]; then
  echo "Error: Kubernetes cluster unreachable: invalid configuration" >&2
  exit 1
fi
[ "\$*" = "status flux-operator -n flux-system" ] && { echo "STATUS: deployed"; exit 0; }
echo "Error: release: not found" >&2
exit 1
EOF
chmod +x "$T/bin/helm"
# Only what the script itself calls, so a helm installed on the runner stays out.
ln -s "$(command -v cat)" "$T/nohelm/cat"
ln -s "$(command -v jq)" "$T/nohelm/jq"

fails=0
# probe SCRIPT PATH STDIN EXPECTED: exit 0, valid JSON, the expected `present`.
probe() {
  local out rc
  out="$(printf '%s' "$3" | PATH="$2" "$BASH_BIN" "$1" 2>/dev/null)"
  rc=$?
  [ "$rc" -eq 0 ] && jq -e --arg p "$4" '.present == $p and (keys == ["present"])' <<<"$out" >/dev/null 2>&1
}
# run_cases SCRIPT: prints one line per case, returns the number that failed.
run_cases() {
  local s="$1" n=0 multi
  multi="$(printf '{\n  "name": "flux-operator",\n  "namespace": "flux-system"\n}')"
  # desc comes from each call's `desc=... c` prefix, which bash scopes to the call; the linter cannot follow it.
  # shellcheck disable=SC2154
  c() { if probe "$s" "$@"; then echo "  ok   $desc"; else echo "  FAIL $desc"; n=$((n + 1)); fi; }
  desc="release present"                 c "$T/bin:$PATH" '{"name":"flux-operator","namespace":"flux-system"}' true
  desc="release present, multi-line JSON" c "$T/bin:$PATH" "$multi" true
  desc="release absent"                  c "$T/bin:$PATH" '{"name":"other","namespace":"flux-system"}' false
  desc="helm missing from PATH"          c "$T/nohelm" '{"name":"flux-operator","namespace":"flux-system"}' false
  desc="broken kubeconfig"               STUB_HELM_BROKEN=1 c "$T/bin:$PATH" '{"name":"flux-operator","namespace":"flux-system"}' false
  desc="name missing"                    c "$T/bin:$PATH" '{"namespace":"flux-system"}' false
  desc="namespace missing"               c "$T/bin:$PATH" '{"name":"flux-operator"}' false
  desc="name empty"                      c "$T/bin:$PATH" '{"name":"","namespace":"flux-system"}' false
  desc="namespace empty"                 c "$T/bin:$PATH" '{"name":"flux-operator","namespace":""}' false
  desc="empty object"                    c "$T/bin:$PATH" '{}' false
  desc="empty stdin"                     c "$T/bin:$PATH" '' false
  desc="stdin not JSON"                  c "$T/bin:$PATH" 'not json' false
  return "$n"
}

echo "helm-release-present.sh:"
rm -f "$T/helm-calls"
run_cases "$SCRIPT" || fails=1
check() { if eval "$2"; then echo "  ok   $1"; else echo "  FAIL $1"; fails=1; fi; }
check "helm is asked with the queried name and namespace" 'grep -qx "status flux-operator -n flux-system" "$T/helm-calls"'
check "helm is never asked without a name and namespace" '! grep -qvE "^status (flux-operator|other) -n flux-system$" "$T/helm-calls"'

# shellcheck disable=SC2016 # the literal line being mutated, not an expansion
check "the script still reads stdin with \`input=\$(cat)\`" 'grep -qx '\''input=$(cat)'\'' "$SCRIPT"'
src="$(cat "$SCRIPT")"
for mutant in "read -r input || input='{}'" "IFS= read -r input"; do
  printf '%s\n' "${src/'input=$(cat)'/$mutant}" >"$T/mutant.sh"
  # Without this, a substitution that silently failed would make the mutant
  # "caught" for the wrong reason.
  if ! grep -qxF "$mutant" "$T/mutant.sh" || grep -qxF 'input=$(cat)' "$T/mutant.sh"; then
    echo "  FAIL the \`$mutant\` mutant was not applied"; fails=1
  elif run_cases "$T/mutant.sh" >/dev/null; then
    echo "  FAIL a \`$mutant\` read goes undetected"; fails=1
  else
    echo "  ok   a \`$mutant\` read is caught"
  fi
done

[ "$fails" -eq 0 ] && echo "all checks passed"
exit "$fails"
