#!/usr/bin/env bash
# requires: python3
#
# SC-12: the coverage check fails on an agent-platform child whose path no gate regex covers,
# and on an agent rule that drops a gate regex. Fixture trees only.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUBJECT="$HERE/../check-policy-gate-coverage.sh"
python3 -c 'import yaml' 2>/dev/null || { echo "SKIP: pyyaml not installed"; exit 77; }
fails=0
fail() { printf 'FAIL  %s\n' "$*" >&2; fails=$((fails + 1)); }

tree() {
  local d; d="$(mktemp -d)"
  mkdir -p "$d/clusters/aws-0-agent-platform" "$d/clusters/aws-0"
  cat >"$d/.policy.yml" <<'EOF'
policy:
  approval:
    - or: [human-authored, "low-risk: docs-links", agent change approved by a maintainer]
approval_rules:
  - name: human-authored
    if: {has_author_in: {users: [Smana]}}
  - name: "low-risk: docs-links"
    if:
      has_author_in: {users: ["ogenki-agents[bot]"]}
      no_changed_files: {paths: ['^\.policy\.yml$', '^tooling/base/agent-factory/', '^docs/(superpowers|specs)/']}
  - name: agent change approved by a maintainer
    if:
      has_author_in: {users: ["ogenki-agents[bot]"]}
      no_changed_files: {paths: ['^\.policy\.yml$', '^tooling/base/agent-factory/']}
    requires: {count: 1, users: [Smana]}
EOF
  cat >"$d/clusters/aws-0-agent-platform/tooling-agent-factory.yaml" <<'EOF'
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata: {name: agent-factory, namespace: flux-system}
spec: {path: ./tooling/base/agent-factory}
EOF
  echo "$d"
}

d="$(tree)"
REPO_ROOT="$d" SENTINELS=".policy.yml" bash "$SUBJECT" >/dev/null 2>&1 || fail "a covered tree passes"

cat >"$d/clusters/aws-0-agent-platform/infrastructure-new.yaml" <<'EOF'
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata: {name: new-child, namespace: flux-system}
spec: {path: ./infrastructure/base/new-child}
EOF
out="$(REPO_ROOT="$d" SENTINELS=".policy.yml" bash "$SUBJECT" 2>&1)" && fail "an uncovered child path fails (SC-12)"
grep -q 'infrastructure/base/new-child' <<<"$out" || fail "the failure names the path"

d="$(tree)"
sed -i "0,/'^tooling\/base\/agent-factory\/', '^docs/s//'^docs/" "$d/.policy.yml"
out="$(REPO_ROOT="$d" SENTINELS=".policy.yml" bash "$SUBJECT" 2>&1)" && fail "a rule missing a gate regex fails"
grep -q 'low-risk: docs-links' <<<"$out" || fail "the failure names the rule"

[ "$fails" -eq 0 ] || exit 1
echo PASS
