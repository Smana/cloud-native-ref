#!/usr/bin/env bash
# requires: cosign flux git rsync python3
# ai-overlay.sh --from-git (agent-platform v3 feature 3, the checks in an agent's sandbox): it lays the
# AI paths from the pin's tag on GitHub, unverified. It must lay exactly the verified artifact's tree,
# refuse CI=true, and refuse a pre-release pin, which has no git tag.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# A throwaway repository holding what the overlay reads: the .gitignore, the pin and the script.
copy() {
  mkdir -p "$1"
  (cd "$ROOT" && cp --parents .gitignore flux/sources/ocirepo-ai-native-ref.yaml scripts/ci/ai-overlay.sh "$1/")
  git -C "$1" init -q && git -C "$1" add -A
}

copy "$tmp/ci"
if (cd "$tmp/ci" && CI=true ./scripts/ci/ai-overlay.sh --from-git) >"$tmp/out" 2>&1; then
  echo "FAIL: --from-git ran under CI=true"; exit 1
fi
grep -q "CI verifies the signed artifact" "$tmp/out" || { echo "FAIL: CI=true refused without its reason:"; cat "$tmp/out"; exit 1; }

copy "$tmp/gha"
if (cd "$tmp/gha" && env -u CI GITHUB_ACTIONS=true ./scripts/ci/ai-overlay.sh --from-git) >"$tmp/out" 2>&1; then
  echo "FAIL: --from-git ran under GITHUB_ACTIONS"; exit 1
fi
grep -q "CI verifies the signed artifact" "$tmp/out" || { echo "FAIL: GITHUB_ACTIONS refused without its reason:"; cat "$tmp/out"; exit 1; }

copy "$tmp/pre"
sed -i 's|^    tag: .*|    tag: "v0.1.17-pr12.gdeadbeef"|' "$tmp/pre/flux/sources/ocirepo-ai-native-ref.yaml"
if (cd "$tmp/pre" && env -u CI -u GITHUB_ACTIONS ./scripts/ci/ai-overlay.sh --from-git) >"$tmp/out" 2>&1; then
  echo "FAIL: --from-git took a pre-release pin"; exit 1
fi
grep -q "needs a release tag" "$tmp/out" || { echo "FAIL: a pre-release pin refused without its reason:"; cat "$tmp/out"; exit 1; }

copy "$tmp/verified"
copy "$tmp/git"
(cd "$tmp/verified" && ./scripts/ci/ai-overlay.sh >/dev/null)
(cd "$tmp/git" && env -u CI -u GITHUB_ACTIONS ./scripts/ci/ai-overlay.sh --from-git >/dev/null)
if ! diff -r --exclude=.git "$tmp/verified" "$tmp/git" >"$tmp/diff"; then
  echo "FAIL: --from-git lays another tree than the verified artifact:"; head -20 "$tmp/diff"; exit 1
fi
echo "PASS: --from-git lays the verified artifact's $(cd "$tmp/git/.ai-artifact" && find . -type f | wc -l) files, refuses CI=true, GITHUB_ACTIONS and a pre-release pin"
