#!/usr/bin/env bash
#
# Sweep AWS resources created by IN-CLUSTER CONTROLLERS, which `tofu destroy`
# cannot see and therefore cannot remove.
#
# WHY THIS EXISTS
#
# OpenTofu owns what OpenTofu created. It does not own the load balancer the
# aws-load-balancer-controller created from a Gateway, the EC2 instance Karpenter
# launched, the security group EKS attached, or the EBS volume the CSI driver
# provisioned for a PVC. When the cluster is destroyed first -- which is the
# order a teardown must use -- those resources are orphaned, and they hold ENIs
# and subnets that block the network stack. `DependencyViolation` and
# `HostedZoneNotEmpty` are what that looks like from the outside, and neither
# names the controller that is actually responsible.
#
# Measured 2026-09-04 on a fully-reconciled aws-0. One teardown, five separate
# orphan classes, five manual interventions:
#
#   2 Gateway API network load balancers   (aws-load-balancer-controller)
#   2 Kubernetes nodes with no cluster     (Karpenter)
#   30 Route53 records                     (ExternalDNS)
#   5 security groups                      (EKS / controllers)
#   2 EBS volumes                          (EBS CSI driver)
#
# The same teardown against a HALF-BUILT cluster had been clean first time,
# because far fewer controller-created resources existed. The failure scales with
# how completely the platform reconciled, which is the opposite of reassuring.
#
# WHY NOT IN eks-prepare-destroy.sh
#
# Three sweeps already existed and are wired as jobs inside eks/init's destroy.
# That works only when the teardown succeeds on the first attempt. If it fails
# partway, eks/init is already destroyed -- so the cleanup written for exactly
# this situation can never run again, and every retry fails on leftovers that a
# sweep would have handled. This script is callable independently, from
# teardown.sh, keyed on what is actually in the cloud.
#
# SAFETY
#
# Refuses to run while the EKS cluster still exists. An orphan is only an orphan
# once the thing that managed it is gone; before that, deleting a load balancer
# or an instance would be destroying live infrastructure.
#
# Everything is scoped to the cluster's own VPC (`vpc-<region>-<env>`, matching
# opentofu/aws/network/network.tf), discovered by tag rather than assumed. It
# never touches the default VPC or its default security group.
#
# Dry-run unless --apply.
#
# Usage:
#   aws-sweep-controller-orphans.sh --cluster-name aws-0 --region eu-west-3 [--vpc-id V] [--apply]
set -o nounset
set -o pipefail

CLUSTER_NAME=""; REGION="${AWS_REGION:-}"; PROFILE=""; VPC_ID=""; APPLY="false"
while [ $# -gt 0 ]; do
    case "$1" in
        --cluster-name) CLUSTER_NAME="$2"; shift 2 ;;
        --region)       REGION="$2"; shift 2 ;;
        --profile)      PROFILE="$2"; shift 2 ;;
        --vpc-id)       VPC_ID="$2"; shift 2 ;;
        --apply)        APPLY="true"; shift ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done
[ -n "$CLUSTER_NAME" ] || { echo "--cluster-name is required" >&2; exit 2; }
[ -n "$REGION" ] || { echo "--region is required (or set AWS_REGION)" >&2; exit 2; }

AWS="aws --region ${REGION}"
[ -n "$PROFILE" ] && AWS="${AWS} --profile ${PROFILE}"

say() { if [ "$APPLY" = "true" ]; then echo "  [delete ] $*"; else echo "  [dry-run] would delete $*"; fi; }
SWEPT=0

# ---- refuse while the cluster is alive -------------------------------------
if $AWS eks describe-cluster --name "$CLUSTER_NAME" >/dev/null 2>&1; then
    echo "EKS cluster ${CLUSTER_NAME} still EXISTS." >&2
    echo "Refusing to sweep: these resources are only orphans once their controllers are gone." >&2
    exit 1
fi
echo "==> EKS cluster ${CLUSTER_NAME} is gone; its controllers cannot be managing anything."

# ---- find the VPC -----------------------------------------------------------
if [ -z "$VPC_ID" ]; then
    VPC_ID="$($AWS ec2 describe-vpcs \
        --filters "Name=tag:Name,Values=vpc-${REGION}-*" "Name=isDefault,Values=false" \
        --query 'Vpcs[0].VpcId' --output text 2>/dev/null)"
fi
if [ -z "$VPC_ID" ] || [ "$VPC_ID" = "None" ]; then
    echo "==> no non-default VPC found — nothing to sweep."
    exit 0
fi
echo "==> scoping to ${VPC_ID}"

# ---- 1. load balancers (aws-load-balancer-controller) -----------------------
# First, because their ENIs hold the subnets everything else needs freed.
echo
echo "== Load balancers created from Gateway/Ingress resources"
for arn in $($AWS elbv2 describe-load-balancers \
        --query "LoadBalancers[?VpcId=='${VPC_ID}'].LoadBalancerArn" --output text 2>/dev/null); do
    name="${arn##*/}"; name="${arn#*loadbalancer/}"; name="${name%/*}"
    say "load balancer ${name}"
    SWEPT=$((SWEPT + 1))
    [ "$APPLY" = "true" ] && $AWS elbv2 delete-load-balancer --load-balancer-arn "$arn" >/dev/null 2>&1
done

# ---- 2. instances (Karpenter, or node groups whose cluster is gone) ---------
echo
echo "== EC2 instances with no cluster behind them"
orphans="$($AWS ec2 describe-instances \
    --filters "Name=vpc-id,Values=${VPC_ID}" \
              "Name=instance-state-name,Values=running,pending,stopping,stopped" \
    --query 'Reservations[].Instances[].InstanceId' --output text 2>/dev/null)"
if [ -n "$orphans" ]; then
    for id in $orphans; do say "instance ${id}"; SWEPT=$((SWEPT + 1)); done
    if [ "$APPLY" = "true" ]; then
        # shellcheck disable=SC2086 # deliberate word splitting: takes a list
        $AWS ec2 terminate-instances --instance-ids $orphans >/dev/null 2>&1
    fi
fi

# ---- wait for ENIs, not for instance state ---------------------------------
# They detach asynchronously. A destroy retried on instance state alone hits the
# same DependencyViolation -- measured twice on 2026-09-03/04.
if [ "$APPLY" = "true" ]; then
    echo
    echo "== waiting for ENIs to release from ${VPC_ID} (up to 300s)"
    for _ in $(seq 1 30); do
        n="$($AWS ec2 describe-network-interfaces --filters "Name=vpc-id,Values=${VPC_ID}" \
             --query 'length(NetworkInterfaces)' --output text 2>/dev/null || echo 0)"
        echo "   ENIs remaining: ${n}"
        [ "${n:-0}" = "0" ] && break
        sleep 10
    done
fi

# ---- 3. security groups ----------------------------------------------------
# Last: they can only go once nothing references them. Several passes because
# groups reference each other and a single ordering can fail on that alone.
echo
echo "== non-default security groups"
for pass in 1 2 3 4; do
    ids="$($AWS ec2 describe-security-groups --filters "Name=vpc-id,Values=${VPC_ID}" \
           --query 'SecurityGroups[?GroupName!=`default`].GroupId' --output text 2>/dev/null)"
    [ -z "$ids" ] && break
    if [ "$APPLY" != "true" ]; then
        for id in $ids; do say "security group ${id}"; SWEPT=$((SWEPT + 1)); done
        break
    fi
    for id in $ids; do
        if $AWS ec2 delete-security-group --group-id "$id" >/dev/null 2>&1; then
            echo "  [delete ] security group ${id} (pass ${pass})"
            SWEPT=$((SWEPT + 1))
        fi
    done
    left="$($AWS ec2 describe-security-groups --filters "Name=vpc-id,Values=${VPC_ID}" \
            --query 'SecurityGroups[?GroupName!=`default`].GroupId' --output text 2>/dev/null)"
    [ "$ids" = "$left" ] && { echo "  [warn   ] no progress; still held: ${left}"; break; }
done

echo
if [ "$APPLY" = "true" ]; then
    echo "==> swept ${SWEPT} controller-created resource(s)."
else
    echo "==> dry-run: ${SWEPT} item(s) would be swept. Re-run with --apply."
fi
