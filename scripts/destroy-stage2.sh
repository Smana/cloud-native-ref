#!/usr/bin/env bash
#
# Stage-2 (<cloud>/*/configure) teardown helper. Shared by the EKS and GKE
# destroy workflows -- the problem it solves is identical on both, and so is
# every line of the solution: it is pure `tofu`, with nothing cloud-specific.
#
# Everything a configure stack manages -- the Gateway API CRDs, Cilium, the
# Flux Operator and the Flux Instance -- lives INSIDE the cluster that stage 1
# deletes moments later. A graceful `tofu destroy` is preferred: on a healthy
# cluster it uninstalls the Helm releases cleanly and leaves state empty.
#
# But it must never GATE the cluster teardown. Both the helm and the kubectl
# provider need a reachable API server, and the usual reason to be running
# destroy at all is that the cluster is broken, or its PRIVATE endpoint is
# unreachable because the tailnet is down. When stage 2 is a hard prerequisite,
# that combination leaves the one billable resource -- the cluster -- running
# with no workflow path to remove it.
#
# Both clouds have now proved it:
#
#   2026-08-23, GKE: the helm and kubectl providers held a GCP access token
#   acquired at plan time; it expired mid-destroy and stage 2 failed with
#   `Unauthorized`. The cluster and both nodes were still RUNNING afterwards.
#   Finished by hand with gcloud, which diverged state and needed `tofu state rm`.
#
#   2026-08-29, EKS: a teardown that had already deleted the cluster still had
#   in-cluster objects to remove, so every delete came back `the server has
#   asked for the client to provide credentials` -- against an API endpoint that
#   no longer resolved in DNS. Errors for objects that had ceased to exist,
#   reported as a failed run.
#
# Hence two modes, deliberately split around the cluster deletion:
#
#   attempt <dir> [tofu args...]
#       Try the graceful destroy. Never fails the caller -- a failure is
#       reported and deferred to `reconcile`. Does NOT touch state: at this
#       point the cluster may still exist, so state may still be accurate.
#
#   reconcile <dir>
#       Run AFTER stage 1 has provably deleted the cluster. Any entries still
#       in the configure stack's state describe objects that lived in that
#       cluster and therefore no longer exist, so they are dropped.
#
# The ordering matters. Clearing state in `attempt` would be wrong: if the
# cluster destroy then failed, state would have been emptied for resources that
# still exist. Clearing only after the cluster is confirmed gone is safe in
# both directions.

set -euo pipefail

usage() {
  echo "usage: $(basename "$0") attempt   <configure-stack-dir> [tofu args...]" >&2
  echo "       $(basename "$0") reconcile <configure-stack-dir>" >&2
  exit 2
}

mode="${1:-}"
dir="${2:-}"
[ -n "${mode}" ] && [ -n "${dir}" ] || usage
shift 2

[ -d "${dir}" ] || { echo "[error] not a directory: ${dir}" >&2; exit 1; }
cd "${dir}"

case "${mode}" in
attempt)
  tofu init -lock-timeout=5m

  # -refresh=false, for a reason on each cloud:
  #
  #   GKE: this stack reads gke/init through terraform_remote_state, and
  #   refreshing that requires the upstream state object to exist. Once
  #   gke/init is destroyed its state is empty and no object is written, so
  #   the read fails hard.
  #
  #   EKS: eks/configure reads `data.aws_eks_cluster`, which refreshing
  #   resolves against a cluster that may already be deleted -- the exact
  #   situation this helper exists to survive.
  #
  # A destroy needs only this stack's own state, where the data source's last
  # value is already cached.
  if tofu destroy -refresh=false -auto-approve -var-file=variables.tfvars "$@"; then
    echo "[ok] stage 2 destroyed gracefully"
    exit 0
  fi

  echo "[warn] ---------------------------------------------------------------"
  echo "[warn] stage 2 destroy FAILED -- the cluster API is likely unreachable"
  echo "[warn] (private endpoint + no tailnet, or the cluster is already broken)."
  echo "[warn]"
  echo "[warn] NOT treating this as fatal. Everything this stack tracks lives"
  echo "[warn] inside the cluster that the next job deletes, so it goes with it."
  echo "[warn] Leftover state is cleaned by the 'reconcile' mode afterwards,"
  echo "[warn] once the cluster is provably gone."
  echo "[warn] ---------------------------------------------------------------"
  exit 0
  ;;

reconcile)
  # No init here: `attempt` already ran one in this same directory. If it did
  # not, reading state fails, and that must be loud.
  #
  # Deliberately NOT `mapfile < <(tofu state list)`: process substitution hides
  # the exit status, so a backend error would arrive as an empty list and be
  # reported as "already empty" -- silently leaving behind exactly the drift
  # this mode exists to remove.
  if ! state_out="$(tofu state list)"; then
    echo "[error] could not read the stage-2 state." >&2
    echo "[error] Refusing to assume it is empty: that would leave real drift" >&2
    echo "[error] behind and report success. Fix the backend, then re-run:" >&2
    echo "[error]   bash scripts/destroy-stage2.sh reconcile ${dir}" >&2
    exit 1
  fi

  addrs=()
  while IFS= read -r line; do
    [ -n "${line}" ] && addrs+=("${line}")
  done <<<"${state_out}"

  if [ "${#addrs[@]}" -eq 0 ]; then
    echo "[ok] stage 2 state already empty -- graceful destroy succeeded"
    exit 0
  fi

  echo "[warn] stage 2 left ${#addrs[@]} entries in state, and the cluster that"
  echo "[warn] held them has been deleted. Dropping them so state stops"
  echo "[warn] claiming resources that no longer exist:"
  printf '         %s\n' "${addrs[@]}"

  tofu state rm "${addrs[@]}"
  echo "[ok] stage 2 state cleared"
  ;;

*)
  usage
  ;;
esac
