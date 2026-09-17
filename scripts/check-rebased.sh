#!/usr/bin/env bash
#
# check-rebased.sh — refuse to push a branch that is behind origin/main.
#
# A branch behind the base produces a diff that no longer describes what will
# merge: reviewers read the wrong merge base, CI passes against code nobody
# will ship, and conflicts surface at merge time instead of now. The
# `sync-branch` skill asks an agent to rebase first; this is the same rule
# below the agent, so it holds for every agent and for a human typing
# `git push`.
#
# Runs from pre-commit's pre-push stage, NOT from core.hooksPath. Setting
# core.hooksPath would make git ignore .git/hooks/ entirely, silently
# disabling the pre-commit hook already installed there.
#
# Escape hatches, in order of preference:
#   SKIP=check-rebased git push    # skip this hook only
#   git push --no-verify           # skip every pre-push hook
#
# Both are legitimate — pushing a WIP branch nobody will review, or adding a
# commit to someone else's branch that you must not rebase.
#
# KNOWN GAP, and it is pre-commit's, not this script's. The pre-push stage only
# runs when the push carries commits that are not already on some remote
# (`git rev-list <local> --not --remotes`); when that set is empty pre-commit
# returns before running any hook, and `always_run: true` does not override it.
# So pushing a branch whose commits are all already published — pointing a new
# branch name at an old commit, say — is not checked. Verified 2026-09-17 by
# pushing a branch at `origin/main~2`: it went through untouched.
#
# That gap is accepted rather than worked around: such a push carries no work to
# review, which is the only thing a stale merge base can misrepresent. Every
# real feature branch has commits of its own, and a rebase gives them new SHAs,
# so both the ordinary push and the post-rebase force-push are covered.

set -euo pipefail

BASE_BRANCH="${BASE_BRANCH:-main}"
REMOTE="${PRE_COMMIT_REMOTE_NAME:-origin}"
ZERO_SHA="0000000000000000000000000000000000000000"

# pre-commit exports these for pre-push hooks. Fall back to the working tree so
# the script is also runnable by hand.
local_branch="${PRE_COMMIT_LOCAL_BRANCH:-$(git rev-parse --abbrev-ref HEAD)}"
remote_branch="${PRE_COMMIT_REMOTE_BRANCH:-}"
to_ref="${PRE_COMMIT_TO_REF:-HEAD}"

# pre-commit hands these over as full refs (`refs/heads/foo`), the fallback as a
# bare name. Normalise both, or the base-branch comparison below misses and the
# refusal message reads `refs/heads/foo`.
local_branch="${local_branch#refs/heads/}"

# A branch deletion pushes the zero sha and has nothing to rebase.
if [ "$to_ref" = "$ZERO_SHA" ]; then
    exit 0
fi

# Pushing the base branch itself, or a tag, is not a feature-branch push.
case "${remote_branch:-refs/heads/$local_branch}" in
    refs/tags/*) exit 0 ;;
esac
if [ "$local_branch" = "$BASE_BRANCH" ] ||
    [ "$remote_branch" = "refs/heads/$BASE_BRANCH" ]; then
    exit 0
fi

# The fetch is the point. Comparing against a local ref that was last updated
# hours ago reports "up to date" on a branch that is not -- the exact failure
# this guard exists to catch. If the network is down we cannot know, so warn
# and allow rather than block offline work.
if ! git fetch --quiet "$REMOTE" "$BASE_BRANCH" 2>/dev/null; then
    echo "check-rebased: could not fetch ${REMOTE}/${BASE_BRANCH}; skipping the check." >&2
    exit 0
fi

base_sha="$(git rev-parse FETCH_HEAD)"

if git merge-base --is-ancestor "$base_sha" "$to_ref"; then
    exit 0
fi

behind="$(git rev-list --count "${to_ref}..${base_sha}")"

cat >&2 <<EOF

  Push refused: '${local_branch}' is ${behind} commit(s) behind ${REMOTE}/${BASE_BRANCH}.

  Pushing now would open or update a pull request whose diff is measured
  against a stale merge base, and whose CI result describes code that will
  not merge.

    git rebase ${REMOTE}/${BASE_BRANCH}
    git push --force-with-lease

  Use --force-with-lease, never bare --force: it refuses when someone else
  has pushed to the branch since you last fetched.

  To push anyway:  SKIP=check-rebased git push

EOF

exit 1
