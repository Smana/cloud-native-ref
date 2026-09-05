#!/usr/bin/env bash
#
# The supported way to tear the platform down.
#
# WHY THIS EXISTS RATHER THAN `terramate script run --reverse destroy`
#
# Two things go wrong with the bare command, and both went wrong on 2026-09-02
# (#1964):
#
#   1. The walk HALTS on the first failing stack. A stack that fails because its
#      target is ALREADY GONE -- a vault whose DNS no longer resolves, a cluster
#      whose credentials expired -- takes every downstream stack with it. Two
#      teardowns left an AWS NAT gateway, two instances, and the entire gcp-0
#      GKE cluster with three e2-standard-4 nodes running. gcp-0 survived three
#      attempts.
#
#      terramate has `--continue-on-error` and nothing was passing it.
#
#   2. Success is reported by an exit code that does not mean what it looks
#      like. The destroy can report success having destroyed nothing, and a
#      wrapper that ends in `echo` returns the echo's status rather than
#      terramate's. Both happened.
#
# So: continue past failures, then VERIFY AGAINST THE CLOUD rather than trusting
# any exit code. Nothing here is finished because a command said so; it is
# finished when the provider says there is nothing left.
#
# Usage:
#   scripts/teardown.sh                 # aws (the TM_CLOUD default)
#   TM_CLOUD=gcp     scripts/teardown.sh
#   TM_CLOUD=all     scripts/teardown.sh
#   scripts/teardown.sh --verify-only   # skip the destroy, just report what is left
#
# TM_DESTROY_CONFIRMED=true skips the interactive prompt, for unattended runs.
set -o nounset
set -o pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLOUDS="${TM_CLOUD:-aws}"
VERIFY_ONLY=0
[ "${1:-}" = "--verify-only" ] && VERIFY_ONLY=1

wants() { # $1 = lane
  case ",${CLOUDS// /}," in
    *,all,*) return 0 ;;
    *,"$1",*) return 0 ;;
  esac
  return 1
}

destroy_rc=0
if [ "$VERIFY_ONLY" -eq 0 ]; then
  echo "=== destroying (TM_CLOUD=${CLOUDS}) ==="
  # --continue-on-error is the point: one stack whose target is already gone must
  # not strand the stacks that still own billable resources.
  ( cd "${ROOT}/opentofu" && terramate script run --reverse --continue-on-error destroy )
  destroy_rc=$?
  echo "=== terramate exit: ${destroy_rc} ==="
  echo

  # SWEEP AND RETRY, because tofu cannot remove what it did not create.
  #
  # A destroy that fails almost always fails on resources an IN-CLUSTER
  # CONTROLLER created: a load balancer from a Gateway, a Karpenter instance, an
  # ExternalDNS record, an EKS security group, a CSI volume. OpenTofu has no
  # state for any of them, so it cannot delete them -- it just hits
  # DependencyViolation or HostedZoneNotEmpty on whatever they are holding.
  #
  # Sweeps for three of these already existed, but were wired as jobs INSIDE
  # eks/init's destroy. That works only if the teardown succeeds first time: once
  # eks/init is destroyed, the cleanup written for exactly this situation can
  # never run again, and every retry fails on leftovers a sweep would have
  # handled.
  #
  # Measured 2026-09-04 on a fully-reconciled aws-0: five attempts, five manual
  # interventions, five different orphan classes. The same teardown against a
  # half-built cluster had been clean first time -- the failure scales with how
  # completely the platform reconciled.
  #
  # So: if the cloud is not clean after the destroy, sweep what the controllers
  # left and destroy once more. Sweeping runs only when the EKS cluster is
  # already gone (the sweeps enforce that themselves), so this cannot touch live
  # infrastructure.
  if wants aws; then
    _region="${AWS_REGION:-eu-west-3}"
    _left="$(aws ec2 describe-vpcs --region "$_region" \
      --query 'Vpcs[?IsDefault==`false`].VpcId' --output text 2>/dev/null)"
    if [ -n "${_left//[[:space:]]/}" ]; then
      echo "=== destroy left resources behind — sweeping controller-created orphans ==="
      bash "${ROOT}/scripts/aws-sweep-teardown-blockers.sh" \
        --cluster-name "${EKS_CLUSTER_NAME:-aws-0}" --region "$_region" --apply || true
      bash "${ROOT}/scripts/aws-sweep-controller-orphans.sh" \
        --cluster-name "${EKS_CLUSTER_NAME:-aws-0}" --region "$_region" --apply || true
      bash "${ROOT}/scripts/aws-sweep-orphaned-volumes.sh" \
        --cluster-name "${EKS_CLUSTER_NAME:-aws-0}" --region "$_region" --apply || true

      echo
      echo "=== retrying the destroy after the sweep ==="
      ( cd "${ROOT}/opentofu" && terramate script run --reverse --continue-on-error destroy )
      destroy_rc=$?
      echo "=== terramate exit after retry: ${destroy_rc} ==="
      echo
    fi
  fi
fi

# ---------------------------------------------------------------------------
# Verification. This is the part that matters -- see the header.
# ---------------------------------------------------------------------------
leftovers=0
# Tracked separately from `leftovers`: "I checked and found things" and "I could
# not check" are different facts, and reporting the second as the first is the
# same conflation this whole script exists to stop. Both are non-zero exits --
# neither is "clean" -- but the operator must be able to tell them apart.
unverified=0

report() { # $1 = label, $2 = value (empty/0 means clean)
  if [ -z "${2//[[:space:]]/}" ] || [ "${2//[[:space:]]/}" = "0" ] || [ "${2//[[:space:]]/}" = "None" ]; then
    printf '  ok   %-22s none\n' "$1"
  else
    printf '  LEFT %-22s %s\n' "$1" "$(printf '%s' "$2" | tr '\n' ' ')"
    leftovers=$((leftovers + 1))
  fi
}

if wants aws; then
  region="${AWS_REGION:-eu-west-3}"
  echo "=== AWS (${region}) — verified against the provider, not the exit code ==="
  report "EC2 instances" "$(aws ec2 describe-instances --region "$region" \
    --filters Name=instance-state-name,Values=running,pending,stopping,stopped \
    --query 'Reservations[].Instances[].InstanceId' --output text 2>/dev/null)"
  report "EKS clusters" "$(aws eks list-clusters --region "$region" \
    --query 'clusters' --output text 2>/dev/null)"
  report "NAT gateways" "$(aws ec2 describe-nat-gateways --region "$region" \
    --filter Name=state,Values=available,pending \
    --query 'NatGateways[].NatGatewayId' --output text 2>/dev/null)"
  report "Load balancers" "$(aws elbv2 describe-load-balancers --region "$region" \
    --query 'LoadBalancers[].LoadBalancerName' --output text 2>/dev/null)"
  report "Non-default VPCs" "$(aws ec2 describe-vpcs --region "$region" \
    --query 'Vpcs[?IsDefault==`false`].VpcId' --output text 2>/dev/null)"
  report "Available EBS volumes" "$(aws ec2 describe-volumes --region "$region" \
    --filters Name=status,Values=available --query 'length(Volumes)' --output text 2>/dev/null)"
  echo
fi

if wants gcp; then
  project="${GCP_PROJECT:-ogenki-435905}"
  echo "=== GCP (${project}) — verified against the provider, not the exit code ==="
  # gcloud's auth expires mid-run more often than is comfortable, and an auth
  # failure here must not read as "nothing left" -- that is the same
  # empty-vs-failed conflation that #1963's promotion script had to fix.
  if ! gcloud projects describe "$project" >/dev/null 2>&1; then
    echo "  ?? cannot reach GCP (auth expired?) — CANNOT VERIFY. Run: gcloud auth login"
    unverified=$((unverified + 1))
  else
    report "GKE clusters" "$(gcloud container clusters list --project "$project" \
      --format='value(name)' 2>/dev/null)"
    report "GCE instances" "$(gcloud compute instances list --project "$project" \
      --format='value(name)' 2>/dev/null)"
    report "Forwarding rules" "$(gcloud compute forwarding-rules list --project "$project" \
      --format='value(name)' 2>/dev/null)"
    report "Disks" "$(gcloud compute disks list --project "$project" \
      --format='value(name)' 2>/dev/null)"
  fi
  echo
fi

echo "=== summary ==="
[ "$destroy_rc" -eq 0 ] && echo "  terramate:  exit 0" || echo "  terramate:  exit ${destroy_rc} (some stacks failed; see above)"
if [ "$leftovers" -eq 0 ] && [ "$unverified" -eq 0 ]; then
  echo "  cloud:      clean"
else
  [ "$leftovers" -gt 0 ] && \
    echo "  cloud:      ${leftovers} category(ies) still populated — NOT torn down"
  [ "$unverified" -gt 0 ] && \
    echo "  cloud:      ${unverified} cloud(s) COULD NOT BE CHECKED — status unknown, assume not torn down"
fi

# Exit non-zero if the destroy failed, OR anything is still standing, OR a cloud
# could not be checked. A green exit here means the provider itself reports
# nothing left -- not that a command returned 0.
[ "$destroy_rc" -eq 0 ] && [ "$leftovers" -eq 0 ] && [ "$unverified" -eq 0 ]
