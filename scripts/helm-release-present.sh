#!/usr/bin/env bash
#
# helm-release-present.sh — a `data "external"` helper: is a Helm release installed?
#
# Reads {"name": "...", "namespace": "..."} on stdin, prints {"present":"true"}
# or {"present":"false"}.
#
# Why this exists: terraform BOOTSTRAPS flux-operator on a bare cluster and then
# hands the release to Flux, which re-manages it from flux/operator/. Terraform
# drops it from state at the end of the deploy (see the eks/configure and
# gke/configure workflows), because the two owners cannot share it -- Flux
# upgrades the release to a chart whose version carries build metadata
# (0.59.0+ae962f87e043), terraform's provider writes that string back into its
# own `version` attribute, and no later plan can resolve it: `+` is not legal in
# an OCI tag. Every apply then dies in the read, before any diff.
#
# Once terraform has forgotten the release, a deploy against a LIVE cluster would
# try to create it again and hit "cannot re-use a name that is still in use".
# This check is what makes that a no-op instead.
#
# It NEVER fails. A broken kubeconfig, a missing helm, an unreachable API server
# -- all answer "false", which makes terraform attempt the create and lets helm
# itself report a real conflict with a real message. Failing here would block a
# plan on a diagnostic, which is the wrong place to learn about it.
set -uo pipefail

# `cat`, not `read`: terraform sends the query JSON with NO trailing newline,
# so `read` returns non-zero at EOF even though it populated the variable --
# and any `|| default` then throws the real input away. Manual tests with
# `echo` pass, because echo adds the newline. Cost an hour on 2026-09-08.
input=$(cat)

name=$(printf '%s' "$input" | jq -r '.name // empty' 2>/dev/null)
namespace=$(printf '%s' "$input" | jq -r '.namespace // empty' 2>/dev/null)

if [ -z "$name" ] || [ -z "$namespace" ]; then
    printf '{"present":"false"}\n'
    exit 0
fi

if command -v helm >/dev/null 2>&1 && helm status "$name" -n "$namespace" >/dev/null 2>&1; then
    printf '{"present":"true"}\n'
else
    printf '{"present":"false"}\n'
fi
