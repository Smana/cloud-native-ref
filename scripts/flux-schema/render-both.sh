#!/usr/bin/env bash
# Render the PR head and the merge-base concurrently, for the render-diff CI
# job (SPEC-007). Output paths are the contract with .github/workflows/ci.yaml's
# "Compute rendered diff" step: .bundle-head (head) and /tmp/base/.bundle-base
# (merge-base, rendered from a worktree with each ref's OWN renderer so a
# change to render-bundle.py itself shows up in the diff).
#
# Both renders are best-effort: a render failure must not sink the
# informational diff job (the hard gate is the kubernetes-validation job), but
# it is surfaced as a ::warning:: annotation - a silent failure here produces
# a misleading "everything added" / "no changes" comment.
#
# helm's repository cache is not safe for concurrent writers across processes
# (index files and chart tarballs share one dir), so the base render gets its
# own seeded COPY of the cache instead of the shared one. Within one renderer
# process the same invariant is handled by per-source-URL locks in
# render-bundle.py - keep the two in sync.
set -uo pipefail

BASE_REF="${1:?usage: render-both.sh <base-ref> (e.g. origin/main)}"

python3 scripts/flux-schema/render-bundle.py .bundle-head &
head_pid=$!

(
  set -euo pipefail
  base_sha="$(git merge-base "${BASE_REF}" HEAD)"
  echo "base merge-base: ${base_sha}"
  git worktree add /tmp/base "${base_sha}"
  mkdir -p "${HOME}/.cache/helm" /tmp/helm-cache-base
  cp -r "${HOME}/.cache/helm/." /tmp/helm-cache-base/
  cd /tmp/base
  HELM_REPOSITORY_CACHE=/tmp/helm-cache-base/repository \
    python3 scripts/flux-schema/render-bundle.py /tmp/base/.bundle-base
) &
base_pid=$!

wait "${head_pid}" || echo "::warning::head render failed — the rendered diff is unreliable"
wait "${base_pid}" || echo "::warning::base render failed — the rendered diff may show everything as added"
exit 0
