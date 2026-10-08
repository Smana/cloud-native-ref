#!/usr/bin/env bash
#
# The cloud selector. One knob decides which clouds an invocation may touch:
#
#   terramate script run deploy                    # aws alone (the default)
#   TM_CLOUD=gcp     terramate script run deploy   # gcp alone
#   TM_CLOUD=aws,gcp terramate script run deploy   # both
#   TM_CLOUD=all     terramate script run deploy   # every lane there is
#
# WHY THIS IS A WRAPPER AROUND `tofu` RATHER THAN A FLAG
#
# There used to be two mechanisms for one intent: `TM_GCP_ENABLED=true` turned
# GCP on, and `--no-tags=aws` turned AWS off. Two knobs, opposite polarities,
# and a GCP deploy needed both -- get one wrong and you silently built the other
# cloud, or silently built nothing.
#
# Tags alone cannot replace them, because a tag filter has no committed default:
# `--no-tags` must be typed. A fresh clone, or CI, would get every stack. Since
# `drift reconcile` runs `tofu apply -auto-approve`, an unprotected default is
# how a cron job builds a second cloud nobody asked for.
#
# So the gate has to be something with a default, which means the environment.
# It sits in the provisioner because every stack reaches OpenTofu through
# `global.provisioner` -- one interception point covers the global scripts and
# every per-stack override at once. Gating the scripts instead would mean
# wrapping them in bash, and Terramate's cloud-sync annotations
# (sync_deployment / sync_preview) are command-level and do not survive that
# (see opentofu/gcp/network/workflows.tm.hcl). This way AWS keeps its sync.
#
# THE LANE COMES FROM THE PATH
#
# `opentofu/<lane>/...` is already the repo's layout, so the directory is the
# lane and nothing has to be threaded through Terramate to say so. Anything
# outside aws/ and gcp/ -- shared/tailscale, shared/aws-gcp-federation -- is
# `shared` and always runs, which is today's behaviour: they are owned by
# neither cloud and are cheap to apply.
#
# Usage:
#   tm-provisioner.sh <tofu args...>       gate on this directory's lane, then run tofu
#   tm-provisioner.sh --tm-run <cmd...>    gate the same way, then run any command
#   tm-provisioner.sh --tm-check <lane>    exit 0 if that lane is selected, 1 if not
#
# --tm-run is for the jobs that do not go through tofu and are the ones that
# matter most: eks-prepare-destroy.sh suspends Flux and deletes every PVC, the
# volume sweep deletes EBS volumes, openbao-config.sh writes to OpenBao. Left
# ungated, `TM_CLOUD=gcp terramate script run --reverse destroy` would tear down
# aws-0's data while claiming to be a GCP-only run.
#
# --tm-check is the same test as a plain exit status, for bash heredocs, and is
# what `${global.cloud_gate}` calls. Both exist so the selection rule is written
# once rather than copied per call site -- the gate this replaces was fifteen
# hand-copied blocks, and four scripts were missing one entirely.

set -o errexit
set -o nounset
set -o pipefail

# A lane is selected when TM_CLOUD names it, names `all`, or the lane is shared.
# TM_CLOUD is a comma list so a third cloud needs no new keyword; spaces are
# tolerated because `TM_CLOUD="aws, gcp"` is the obvious thing to type.
selected() {
    local lane="$1" want
    [ "$lane" = "shared" ] && return 0
    want="${TM_CLOUD:-aws}"
    want="${want// /}"
    case ",${want}," in
        *,all,*)       return 0 ;;
        *,"${lane}",*) return 0 ;;
    esac
    return 1
}

lane_from_path() {
    case "$PWD" in
        */opentofu/aws|*/opentofu/aws/*) echo "aws" ;;
        */opentofu/gcp|*/opentofu/gcp/*) echo "gcp" ;;
        *)                               echo "shared" ;;
    esac
}

if [ "${1:-}" = "--tm-check" ]; then
    [ $# -ge 2 ] || { echo "--tm-check needs a lane" >&2; exit 2; }
    selected "$2"
    exit $?
fi

RUN_ANY="false"
if [ "${1:-}" = "--tm-run" ]; then
    RUN_ANY="true"
    shift
    [ $# -ge 1 ] || { echo "--tm-run needs a command" >&2; exit 2; }
fi

lane="$(lane_from_path)"
if ! selected "$lane"; then
    echo "[skip] ${lane} stack — TM_CLOUD=${TM_CLOUD:-aws} does not include it."
    echo "       Set TM_CLOUD=${lane}, a list like aws,gcp, or all."
    exit 0
fi

# TF_VAR_flux_git_ref names the branch FLUX will track. It says nothing about
# which code OpenTofu is about to apply -- that comes from the checkout this
# runs in. When the two disagree, the deploy half-succeeds in a way that is very
# hard to read.
#
# Measured 2026-09-02. A dual-cloud bootstrap was launched with
# TF_VAR_flux_git_ref pointing at a feature branch, from a checkout that did not
# have the branch's changes. Flux got the branch and correctly suspended
# ZITADEL on gcp-0; OpenTofu ran the older code and wrote
# identity_provider_url=https://auth.gcp.cloud.ogenki.io into that cluster's
# vars. gcp-0 therefore ran no identity provider AND pointed every consumer at
# the one it no longer had: oauth2-proxy crash-looped on OIDC discovery, the
# gateway answered "no healthy upstream", and the Flux UI returned a generic
# internal error. Nothing named the cause, because from Flux's side everything
# reconciled and from tofu's side everything applied.
#
# A warning, not a failure: deploying a branch's manifests against older
# infrastructure code is occasionally deliberate, and this script has no way to
# tell that from a mistake. It only has to be impossible to do by accident
# without seeing it.
if [ -n "${TF_VAR_flux_git_ref:-}" ]; then
    _want_ref="${TF_VAR_flux_git_ref#refs/heads/}"
    _have_ref="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
    if [ "$_want_ref" != "$_have_ref" ]; then
        echo "[warn] ─────────────────────────────────────────────────────────────" >&2
        echo "[warn] Flux will track '${_want_ref}', but this checkout is on '${_have_ref}'." >&2
        echo "[warn] OpenTofu applies THIS checkout, not the branch Flux tracks, so" >&2
        echo "[warn] the cluster gets its manifests from one commit and its cluster" >&2
        echo "[warn] vars from another. Check out '${_want_ref}' unless you mean it." >&2
        echo "[warn] ─────────────────────────────────────────────────────────────" >&2
    fi
fi

if [ "$RUN_ANY" = "true" ]; then
    exec "$@"
fi
exec tofu "$@"
