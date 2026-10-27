#!/usr/bin/env bash
# verify_tool_pins: tofu and terramate on PATH must match the mise.toml pins.
# Offline: stub binaries on PATH and a stub pin file.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
T="$(cd "$(mktemp -d)" && pwd -P)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"
fails=0
f() { echo "FAIL $*"; fails=1; }

cat >"$T/mise.toml" <<'EOF2'
[tools]
opentofu = "1.13.2"
"ubi:terramate-io/terramate" = "0.17.3"
EOF2
stub() { printf '#!/usr/bin/env bash\n%s\n' "$2" >"$T/bin/$1"; chmod +x "$T/bin/$1"; }

run() { # env assignments; prints output, returns rc
  env -u TM_SKIP_TOOL_PIN_CHECK PATH="$T/bin:$PATH" TM_MISE_TOML="$T/mise.toml" "$@" \
    bash -c ". '$ROOT/scripts/lib/tool-pins.sh'; verify_tool_pins" 2>&1
}

stub tofu 'echo "OpenTofu v1.13.2"; echo "on linux_amd64"'
# Real terramate prints the bare version, then an update notice naming OTHER versions.
stub terramate 'printf "0.17.3\n\nYour version of Terramate is out of date!\nThe latest version\nis 0.99.0 (released on Tue)\n"'
out="$(run)"; rc=$?
[ "$rc" -eq 0 ] || f "matching versions must pass, got rc=$rc: $out"

stub tofu 'echo "OpenTofu v1.12.0"'
out="$(run)"; rc=$?
[ "$rc" -ne 0 ] || f "a tofu mismatch must fail"
grep -q 'tofu version mismatch: 1.12.0 installed, mise.toml pins 1.13.2' <<<"$out" || f "unclear tofu message: $out"

stub tofu 'echo "OpenTofu v1.13.2"'
stub terramate 'echo 0.16.0'
out="$(run)"; rc=$?
[ "$rc" -ne 0 ] || f "a terramate mismatch must fail"
grep -q 'terramate version mismatch: 0.16.0 installed, mise.toml pins 0.17.3' <<<"$out" || f "unclear terramate message: $out"

out="$(run TM_SKIP_TOOL_PIN_CHECK=true)"; rc=$?
[ "$rc" -eq 0 ] || f "TM_SKIP_TOOL_PIN_CHECK=true must bypass, got rc=$rc"

# The real pins are readable (a renamed key must not turn the check into a no-op).
out="$(env -u TM_MISE_TOML PATH="$T/bin:$PATH" bash -c ". '$ROOT/scripts/lib/tool-pins.sh'; _tool_pin opentofu; _tool_pin '\"ubi:terramate-io/terramate\"'")"
[ "$(wc -l <<<"$out")" -eq 2 ] || f "mise.toml pins not found: $out"

# Both entry points call it.
grep -q 'verify_tool_pins' "$ROOT/scripts/provision/tm-provisioner.sh" || f "tm-provisioner.sh does not call it"
grep -q 'verify_tool_pins' "$ROOT/scripts/ops/teardown/teardown.sh" || f "teardown.sh does not call it"

[ "$fails" -eq 0 ] && echo PASS
exit "$fails"
