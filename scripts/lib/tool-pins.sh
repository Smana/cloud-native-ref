# shellcheck shell=bash
#
# Fail when the tofu or terramate on PATH is not the version mise.toml pins.
#
# Source this and call verify_tool_pins:
#
#   . "$ROOT/scripts/lib/tool-pins.sh"
#   verify_tool_pins || exit 1
#
# WHY THIS EXISTS
#
# mise.toml pins opentofu and terramate, but a shell without `mise activate`
# (or a stale binary earlier on PATH) runs whatever else is installed, and
# nothing said so. A deploy or teardown on a different tofu can rewrite state
# or lock files in a format the pinned one does not read back. Callers:
# scripts/provision/tm-provisioner.sh (every tofu a deploy or destroy runs) and
# scripts/ops/teardown/teardown.sh.
#
# TM_SKIP_TOOL_PIN_CHECK=true bypasses it, for a deliberate version trial.
# TM_MISE_TOML points at another pin file (tests).

_tool_pins_file() {
  echo "${TM_MISE_TOML:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/mise.toml}"
}

# $1 = tools key in mise.toml, as written (quotes included)
_tool_pin() {
  grep -E -m1 "^${1} *= *\"" "$(_tool_pins_file)" | sed -E 's/^[^=]*= *"([^"]+)".*/\1/'
}

# $1 = label, $2 = binary, $3 = mise.toml key (regex-escaped)
_check_tool_pin() {
  local want have
  want="$(_tool_pin "$3")"
  if [ -z "$want" ]; then
    echo "[tool-pins] no pin for $1 in $(_tool_pins_file)" >&2
    return 1
  fi
  if ! command -v "$2" >/dev/null 2>&1; then
    echo "[tool-pins] $1 is not installed; mise.toml pins ${want}. Run: mise install" >&2
    return 1
  fi
  have="$("$2" version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
  if [ "$have" != "$want" ]; then
    echo "[tool-pins] $1 version mismatch: ${have:-unknown} installed, mise.toml pins ${want}." >&2
    echo "            Run \`mise install\` and use the mise-activated shell, or set TM_SKIP_TOOL_PIN_CHECK=true to override." >&2
    return 1
  fi
}

verify_tool_pins() {
  [ "${TM_SKIP_TOOL_PIN_CHECK:-false}" != "true" ] || return 0
  local rc=0
  _check_tool_pin tofu tofu 'opentofu' || rc=1
  _check_tool_pin terramate terramate '"ubi:terramate-io/terramate"' || rc=1
  return "$rc"
}
