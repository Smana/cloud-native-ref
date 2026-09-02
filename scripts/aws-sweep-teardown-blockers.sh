#!/usr/bin/env bash
#
# Clear the two things that reliably block `tofu destroy` on AWS, neither of
# which Terraform owns and neither of which any existing sweep covers.
#
# WHY THIS EXISTS
#
# A teardown on 2026-09-02 needed four attempts. Two of the four blockers were
# these, and both recur on every rebuild:
#
#   1. Route53 refuses DeleteHostedZone while any record other than the zone's
#      own NS/SOA remains. ExternalDNS writes an A record and a TXT ownership
#      record per exposed service -- 30 of them that day -- and once the cluster
#      is gone nothing will ever reclaim them. The zone is not deletable again
#      without clearing them by hand.
#
#   2. EKS creates its own cluster security group (`eks-cluster-sg-<name>-*`).
#      Terraform never owned it, so `tofu destroy` does not delete it, and it
#      outlives the cluster holding the VPC hostage: DeleteVpc fails with
#      DependencyViolation naming a group nothing in the state file mentions.
#
# WHY THAT MATTERS MORE THAN IT LOOKS
#
# `terramate script run --reverse destroy` stops at the first failing stack. On
# that same run the AWS stacks failed first, so the sweep never reached the GCP
# stacks at all -- an untouched GKE cluster kept running because a leftover DNS
# record two stacks away blocked a hosted zone. A cheap sweep is worth a lot
# when the failure mode is "the other cloud silently stayed up".
#
# WHY NOT IN eks-prepare-destroy.sh
#
# Timing, and it differs per blocker. The security group does not exist as an
# orphan until AFTER the cluster is deleted, so nothing running before `tofu
# destroy` can see it. The DNS records could be cleared earlier -- ExternalDNS
# is already stopped by then -- but the zone itself is destroyed by a later
# stack, so a single sweep that can run at any point is simpler to reason about
# than two half-measures at two moments.
#
# SAFETY
#
# Both sweeps are narrowly filtered and refuse to touch anything shared:
#   * NS and SOA are never deleted -- they are the zone's own records.
#   * The `default` security group is never deleted; AWS forbids it anyway.
#   * The security group is matched by the EKS-generated name for the CLUSTER
#     YOU NAME, so another cluster's group in the same VPC is not a candidate.
#   * A security group still holding network interfaces is reported and SKIPPED,
#     because that means something is still using it and the cluster is not
#     actually gone.
#
# Usage:
#   aws-sweep-teardown-blockers.sh --cluster-name N --region R \
#       [--zone-name Z] [--profile P] [--apply]
#
# Dry-run unless --apply, and it lists exactly what it would delete.
# Idempotent: safe to run before a destroy, after a failed one, or twice.

set -o errexit
set -o nounset
set -o pipefail

CLUSTER_NAME=""
REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-}}"
ZONE_NAME=""
PROFILE=""
APPLY="false"

while [ $# -gt 0 ]; do
    case "$1" in
        --cluster-name) CLUSTER_NAME="$2"; shift 2 ;;
        --region)       REGION="$2"; shift 2 ;;
        --zone-name)    ZONE_NAME="$2"; shift 2 ;;
        --profile)      PROFILE="$2"; shift 2 ;;
        --apply)        APPLY="true"; shift ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

[ -n "$CLUSTER_NAME" ] || { echo "--cluster-name is required" >&2; exit 2; }
[ -n "$REGION" ] || { echo "--region is required (or set AWS_REGION)" >&2; exit 2; }

AWS=(aws --region "$REGION")
[ -n "$PROFILE" ] && AWS+=(--profile "$PROFILE")

swept=0 skipped=0 failed=0

# ── 1. Route53 records that block DeleteHostedZone ─────────────────────────
#
# Scoped to zones whose name matches --zone-name when given. Without it, every
# PRIVATE zone in the account is considered -- private because those are the
# ones this platform creates per cluster; a public zone is far more likely to be
# shared with something outside this repo and is left alone.
echo "== Route53: records blocking zone deletion"
if [ -n "$ZONE_NAME" ]; then
    zone_rows=$("${AWS[@]}" route53 list-hosted-zones \
        --query "HostedZones[?Name=='${ZONE_NAME%.}.'].[Id,Name,Config.PrivateZone]" \
        --output text 2>/dev/null || true)
else
    zone_rows=$("${AWS[@]}" route53 list-hosted-zones \
        --query 'HostedZones[?Config.PrivateZone==`true`].[Id,Name,Config.PrivateZone]' \
        --output text 2>/dev/null || true)
fi

if [ -z "$zone_rows" ]; then
    echo "  no candidate hosted zones"
else
    while read -r zid zname _; do
        [ -n "$zid" ] || continue
        zid="${zid##*/}"
        # NS and SOA are the zone's own; everything else blocks its deletion.
        recs=$("${AWS[@]}" route53 list-resource-record-sets --hosted-zone-id "$zid" \
            --query 'ResourceRecordSets[?Type!=`NS` && Type!=`SOA`]' --output json 2>/dev/null || echo '[]')
        n=$(python3 -c 'import json,sys; print(len(json.load(sys.stdin)))' <<<"$recs")
        if [ "$n" = "0" ]; then
            echo "  ${zname} — already clear"
            continue
        fi
        if [ "$APPLY" != "true" ]; then
            echo "  [dry-run] ${zname} — would delete ${n} record(s)"
            python3 -c '
import json,sys
for r in json.load(sys.stdin)[:5]:
    print("      ", r["Type"], r["Name"])
' <<<"$recs"
            swept=$((swept + n))
            continue
        fi
        batch=$(python3 -c '
import json,sys
rs = json.load(sys.stdin)
print(json.dumps({"Changes": [{"Action": "DELETE", "ResourceRecordSet": r} for r in rs]}))
' <<<"$recs")
        if "${AWS[@]}" route53 change-resource-record-sets --hosted-zone-id "$zid" \
             --change-batch "$batch" >/dev/null 2>&1; then
            echo "  ${zname} — deleted ${n} record(s)"
            swept=$((swept + n))
        else
            echo "  ${zname} — FAILED to delete records" >&2
            failed=$((failed + 1))
        fi
    done <<<"$zone_rows"
fi

# ── 2. the EKS-managed cluster security group ──────────────────────────────
#
# EKS names it `eks-cluster-sg-<cluster>-<id>`. It is tagged for the cluster
# too, but the name is what makes the match unambiguous when several clusters
# have shared a VPC over time.
echo
echo "== EC2: the EKS-managed cluster security group"
sg_rows=$("${AWS[@]}" ec2 describe-security-groups \
    --filters "Name=group-name,Values=eks-cluster-sg-${CLUSTER_NAME}-*" \
    --query 'SecurityGroups[].[GroupId,GroupName,VpcId]' --output text 2>/dev/null || true)

if [ -z "$sg_rows" ]; then
    echo "  none left by ${CLUSTER_NAME}"
else
    while read -r sgid sgname vpc; do
        [ -n "$sgid" ] || continue
        # A group still holding ENIs means something is USING it -- the cluster
        # is not gone, and deleting it would fail anyway. Report, do not try.
        enis=$("${AWS[@]}" ec2 describe-network-interfaces \
            --filters "Name=group-id,Values=${sgid}" \
            --query 'length(NetworkInterfaces)' --output text 2>/dev/null || echo 0)
        if [ "${enis:-0}" != "0" ]; then
            echo "  ${sgname} (${sgid}) — SKIPPED, still has ${enis} network interface(s)."
            echo "      Something is still using it; the cluster is not fully gone."
            skipped=$((skipped + 1))
            continue
        fi
        if [ "$APPLY" != "true" ]; then
            echo "  [dry-run] would delete ${sgname} (${sgid}) in ${vpc}"
            swept=$((swept + 1))
            continue
        fi
        if "${AWS[@]}" ec2 delete-security-group --group-id "$sgid" >/dev/null 2>&1; then
            echo "  deleted ${sgname} (${sgid})"
            swept=$((swept + 1))
        else
            echo "  ${sgname} (${sgid}) — FAILED to delete" >&2
            failed=$((failed + 1))
        fi
    done <<<"$sg_rows"
fi

echo
if [ "$APPLY" != "true" ]; then
    echo "==> dry-run: ${swept} item(s) would be swept, ${skipped} skipped. Re-run with --apply."
else
    echo "==> swept ${swept}, skipped ${skipped}, failed ${failed}."
fi
[ "$failed" -eq 0 ] || exit 1
