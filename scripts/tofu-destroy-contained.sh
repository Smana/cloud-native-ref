#!/usr/bin/env bash
#
# `tofu destroy`, but a stack whose only remaining blockers live INSIDE
# infrastructure that is about to be destroyed anyway does not halt the sweep.
#
# THE PROBLEM THIS SOLVES
#
# Some stacks manage resources whose entire lifetime is contained by another
# stack's infrastructure:
#
#   aws/openbao/management   vault_*           policies, mounts, approles, PKI
#   gcp/openbao/management   vault_*           inside the OpenBao cluster
#   gcp/gke/configure        kubectl_manifest  Gateway API CRDs, flux-system, vars
#
# In a `--reverse destroy` the very next stack destroys the vault or the cluster
# that contains them. Deleting a Vault policy seconds before deleting the Vault
# is meaningless work -- and it usually CANNOT be done, because by then the
# endpoint is already unreachable:
#
#   Error: failed to lookup token ... dial tcp: lookup bao.priv.aws.ogenki.io
#          on 127.0.0.53:53: no such host
#   Error: gatewayclasses.gateway.networking.k8s.io failed to delete kubernetes
#          resource: Unauthorized
#
# terramate's `--reverse` walk HALTS on that failure, so everything downstream --
# the OpenBao cluster, the network, the shared stacks -- is never attempted.
#
# Measured 2026-09-02/03 (#1964): two full teardowns reported success while an
# AWS NAT gateway, two t3.micro instances and the ENTIRE gcp-0 GKE cluster with
# three e2-standard-4 nodes kept running. gcp-0 survived three attempts. The
# manual unblock was three `tofu state rm` invocations reconstructed from error
# messages.
#
# WHY FAILURE-DRIVEN RATHER THAN A REACHABILITY PROBE
#
# Probing "is the vault up?" first means writing a second, different piece of
# logic that can disagree with what tofu actually experiences -- and a probe that
# says "reachable" while the provider still fails leaves the halt in place.
# The destroy attempt IS the probe: it uses the provider's own credentials, its
# own endpoint resolution, its own timeouts.
#
# WHY THIS IS SAFE EVEN IF THE FAILURE HAD ANOTHER CAUSE
#
# Only the resource classes named by --contained-prefix are ever dropped, and
# those are exactly the ones whose backing objects disappear with the next stack.
# No real cloud resource is ever removed from state here: the AWS Secrets Manager
# secrets in openbao/management, the Bucket in a cloudnative-pg claim, the EC2
# instances -- none match, none are touched, and tofu must still delete them for
# the retry to succeed. If the failure was something else entirely, the retry
# fails again and the real error surfaces, with the same exit code it would have
# had.
#
# Usage (through tm-provisioner.sh --tm-run, so it inherits the cloud gate):
#   tofu-destroy-contained.sh --contained-prefix vault_ -- -auto-approve -var-file=variables.tfvars
#   tofu-destroy-contained.sh --contained-prefix kubectl_manifest -- -auto-approve
#
# --contained-prefix may be repeated. Matching is on the START of the state
# address, so `vault_` matches `vault_policy.admin` and
# `module.x.vault_mount.y` is matched by `module.x.vault_` only -- deliberately
# literal, because a regex here would eventually match something real.
set -o nounset
set -o pipefail

PREFIXES=()
while [ $# -gt 0 ]; do
  case "$1" in
    --contained-prefix)
      [ $# -ge 2 ] || { echo "--contained-prefix needs a value" >&2; exit 2; }
      PREFIXES+=("$2"); shift 2 ;;
    --)
      shift; break ;;
    *)
      echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

[ "${#PREFIXES[@]}" -gt 0 ] || { echo "at least one --contained-prefix is required" >&2; exit 2; }
[ $# -gt 0 ] || { echo "no destroy arguments given after --" >&2; exit 2; }

echo "==> tofu destroy $*"
tofu destroy "$@"
rc=$?
[ "$rc" -eq 0 ] && exit 0

echo
echo "[warn] destroy failed (exit ${rc})."
echo "[warn] Checking whether the blockers are resources contained by infrastructure"
echo "[warn] this sweep destroys next -- see the header of $(basename "$0")."

# Collect the contained entries. A state-list failure is NOT "there are none":
# treat it as a real failure and surface the original destroy error.
if ! state_list="$(tofu state list 2>&1)"; then
  echo "[error] could not read the state to look for contained resources:" >&2
  printf '%s\n' "$state_list" >&2
  exit "$rc"
fi

contained=()
while IFS= read -r addr; do
  [ -n "$addr" ] || continue
  for p in "${PREFIXES[@]}"; do
    case "$addr" in
      "$p"*) contained+=("$addr"); break ;;
    esac
  done
done <<< "$state_list"

if [ "${#contained[@]}" -eq 0 ]; then
  echo "[error] no contained resources in state (prefixes: ${PREFIXES[*]})."
  echo "[error] This failure is not the one this wrapper handles. Original error stands."
  exit "$rc"
fi

echo "[info ] dropping ${#contained[@]} contained resource(s) from state:"
printf '         %s\n' "${contained[@]}"
echo "[info ] their backing objects live inside infrastructure destroyed by the"
echo "[info ] next stack in the reverse walk, so deleting them individually is"
echo "[info ] both impossible now and unnecessary."

# One call: each `state rm` rewrites and re-uploads state, and a partial sequence
# interrupted halfway is a worse mess than the one being cleaned up.
if ! tofu state rm "${contained[@]}"; then
  echo "[error] failed to drop contained resources from state." >&2
  exit "$rc"
fi

echo
echo "==> retrying: tofu destroy $*"
tofu destroy "$@"
retry_rc=$?
if [ "$retry_rc" -ne 0 ]; then
  echo "[error] destroy still failing after dropping contained resources." >&2
  echo "[error] The blocker is something else; this is the real error." >&2
fi
exit "$retry_rc"
