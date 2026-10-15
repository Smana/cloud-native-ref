#!/usr/bin/env bash
#
# The crossplane-configuration release is pinned in four places that must name
# the same tag: the -core, -aws and -gcp Configuration packages, and the App
# Wizard's clone. Crossplane never upgrades an installed -core on its own
# (#2275), so a cloud pin that moves alone leaves its package Healthy=False.
#
# Also holds the two properties of the -core object that make adopting it safe:
# its registry-derived name and its prune opt-out.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
XP="$ROOT/infrastructure/base/crossplane"
CORE="$XP/configuration-core/configuration-core.yaml"
fails=0
fail() { printf 'FAIL  %s\n' "$*" >&2; fails=$((fails + 1)); }

# tag FILE REGEX: the tag after the first match of REGEX, empty if none.
tag() { sed -nE "s#^[[:space:]]*-?[[:space:]]*$2([^\"[:space:]]+).*#\1#p" "$1" | head -n1; }

declare -A pins=(
  [core]="$(tag "$CORE" 'package:[[:space:]]*ghcr\.io/smana/crossplane-configuration-core:')"
  [aws]="$(tag "$XP/configuration-aws/configuration-packages.yaml" 'package:[[:space:]]*ghcr\.io/smana/crossplane-configuration-aws:')"
  [gcp]="$(tag "$XP/configuration-gcp/configuration-packages.yaml" 'package:[[:space:]]*ghcr\.io/smana/crossplane-configuration-gcp:')"
  [app-wizard]="$(tag "$ROOT/apps/platform/app-wizard/app.yaml" '--branch=v')"
)
# The wizard's other clone tracks --branch=main; only a v-tag is this pin.
[ -n "${pins[app-wizard]}" ] && pins[app-wizard]="v${pins[app-wizard]}"

for k in "${!pins[@]}"; do
  [ -n "${pins[$k]}" ] || fail "no crossplane-configuration pin found for $k"
done
for k in aws gcp app-wizard; do
  [ "${pins[$k]}" = "${pins[core]}" ] || fail "$k pins ${pins[$k]}, core pins ${pins[core]}: bump all four in one PR"
done

grep -qE '^[[:space:]]+name:[[:space:]]*smana-crossplane-configuration-core[[:space:]]*$' "$CORE" \
  || fail "core Configuration must be named smana-crossplane-configuration-core, the name Crossplane gives the dependency"
grep -qE '^[[:space:]]+kustomize\.toolkit\.fluxcd\.io/prune:[[:space:]]*disabled[[:space:]]*$' "$CORE" \
  || fail "core Configuration must carry kustomize.toolkit.fluxcd.io/prune: disabled"

for c in aws gcp; do
  grep -qE '^[[:space:]]*-[[:space:]]*\.\./configuration-core[[:space:]]*$' "$XP/configuration-$c/kustomization.yaml" \
    || fail "configuration-$c does not include ../configuration-core"
done

[ "$fails" -eq 0 ] || exit 1
echo "crossplane-configuration pins agree on ${pins[core]}"
