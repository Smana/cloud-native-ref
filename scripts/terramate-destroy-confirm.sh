#!/usr/bin/env bash
#
# Single y/n prompt for `terramate script run --reverse destroy`.
#
# Each stack's `destroy` script calls this as its first command. The first
# invocation prompts the user; subsequent invocations within ~10 minutes
# read the cached answer from a marker file, so a `--reverse destroy`
# across N stacks asks once.
#
# Usage in workflows.tm.hcl:
#   commands = [
#     ["bash", "${terramate.root.path.absolute}/scripts/terramate-destroy-confirm.sh"],
#     [global.provisioner, "destroy", ...],
#   ]
#
# Bypass for non-interactive contexts (CI, scripts):
#   TM_DESTROY_CONFIRMED=true terramate script run --reverse destroy
#
set -euo pipefail

# CI / non-interactive escape hatch — explicit env var consents on the
# caller's behalf and skips the prompt entirely.
if [ "${TM_DESTROY_CONFIRMED:-false}" = "true" ]; then
  exit 0
fi

MARKER="/tmp/.terramate-destroy-confirmed-${USER:-$(id -u)}"
TTL_SECONDS=600

if [ -f "$MARKER" ]; then
  age=$(( $(date +%s) - $(stat -c %Y "$MARKER" 2>/dev/null || stat -f %m "$MARKER") ))
  if [ "$age" -lt "$TTL_SECONDS" ]; then
    # Recent confirmation — propagate silently.
    exit 0
  fi
  rm -f "$MARKER"
fi

# Interactive prompt. Read from /dev/tty so this works under terramate's
# stdout pipe (terramate captures stdout for log shaping but leaves /dev/tty
# attached to the user's terminal).
if [ ! -e /dev/tty ]; then
  echo "[destroy-confirm] no /dev/tty available — refusing to destroy non-interactively." >&2
  echo "                  set TM_DESTROY_CONFIRMED=true to bypass." >&2
  exit 1
fi

cat >&2 <<'EOF'

╔════════════════════════════════════════════════════════════════╗
║                       DESTRUCTIVE OPERATION                    ║
╠════════════════════════════════════════════════════════════════╣
║  About to run `tofu destroy` across one or more stacks.       ║
║  This will delete AWS resources (cluster, networking, IAM,     ║
║  storage). State is non-recoverable for resources that don't   ║
║  back to a managed source (e.g., generated secrets).           ║
║                                                                ║
║  Confirmation is cached for 10 minutes so a `--reverse`        ║
║  destroy across multiple stacks asks once.                     ║
╚════════════════════════════════════════════════════════════════╝

EOF

read -r -p "Proceed with destroy? [y/N]: " answer < /dev/tty

case "$answer" in
  [yY]|[yY][eE][sS])
    touch "$MARKER"
    echo "[destroy-confirm] confirmed; cached for ${TTL_SECONDS}s." >&2
    ;;
  *)
    echo "[destroy-confirm] aborted." >&2
    exit 1
    ;;
esac
