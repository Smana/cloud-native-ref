#!/usr/bin/env bash
#
# sweep-controller-orphans.sh with aws stubbed on PATH. The guard that matters
# is the first one: while the EKS cluster exists nothing is an orphan, so the
# script must exit before it lists, let alone deletes, anything. Past it, a dry
# run deletes nothing and --apply deletes exactly the load balancers, instances
# and security groups a controller of THIS cluster created, in the one VPC it
# scoped to. The VPC is shared: OpenBao's NLB, node and security group sit in it
# too, and the 2026-10-16 teardown swept the first two (OpenTofu owns them).
# Target groups are the one region-wide sweep: they outlive their VPC, so they
# are swept even when no VPC is left -- still only this cluster's.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SCRIPT="$ROOT/scripts/ops/aws/sweep-controller-orphans.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"

LB=arn:aws:elasticloadbalancing:eu-west-3:111111111111:loadbalancer/net
cat >"$T/lb-tags.json" <<EOF
{"TagDescriptions": [
  {"ResourceArn": "$LB/gw-a/aaa", "Tags": [{"Key": "elbv2.k8s.aws/cluster", "Value": "aws-0"}, {"Key": "service.k8s.aws/stack", "Value": "infrastructure/cilium-gateway-platform"}]},
  {"ResourceArn": "$LB/gw-b/bbb", "Tags": [{"Key": "elbv2.k8s.aws/cluster", "Value": "aws-0"}]},
  {"ResourceArn": "$LB/eu-west-3-dev-ogenki-openbao/ccc", "Tags": [{"Key": "app", "Value": "openbao"}]},
  {"ResourceArn": "$LB/gw-other/ddd", "Tags": [{"Key": "elbv2.k8s.aws/cluster", "Value": "aws-1"}]}
]}
EOF
TG=arn:aws:elasticloadbalancing:eu-west-3:111111111111:targetgroup
cat >"$T/tg-tags.json" <<EOF
{"TagDescriptions": [
  {"ResourceArn": "$TG/k8s-infrastr-ciliumga-aaa/1a", "Tags": [{"Key": "elbv2.k8s.aws/cluster", "Value": "aws-0"}]},
  {"ResourceArn": "$TG/k8s-security-ciliumga-bbb/2b", "Tags": [{"Key": "elbv2.k8s.aws/cluster", "Value": "aws-0"}]},
  {"ResourceArn": "$TG/eu-west-3-dev-ogenki-openbao/3c", "Tags": []},
  {"ResourceArn": "$TG/k8s-other-ciliumga-ddd/4d", "Tags": [{"Key": "elbv2.k8s.aws/cluster", "Value": "aws-1"}]}
]}
EOF
cat >"$T/instances.json" <<'EOF'
[
  {"id": "i-0aaa", "tags": [{"Key": "karpenter.sh/nodepool", "Value": "default"}, {"Key": "kubernetes.io/cluster/aws-0", "Value": "owned"}]},
  {"id": "i-0bbb", "tags": [{"Key": "eks:cluster-name", "Value": "aws-0"}, {"Key": "aws:autoscaling:groupName", "Value": "eks-bootstrap-1234"}]},
  {"id": "i-0bao", "tags": [{"Key": "OpenBaoInstance", "Value": "eu-west-3-dev-ogenki-openbao"}, {"Key": "app", "Value": "openbao"}, {"Key": "aws:autoscaling:groupName", "Value": "eu-west-3-dev-ogenki-openbao-2026"}]},
  {"id": "i-0asg", "tags": [{"Key": "kubernetes.io/cluster/aws-0", "Value": "owned"}, {"Key": "aws:autoscaling:groupName", "Value": "self-managed"}]},
  {"id": "i-0bare", "tags": null}
]
EOF
# Every call is logged; security groups live in a file (id key value per line)
# so a delete is visible to the next describe, which is what the multi-pass
# loop keys on.
cat >"$T/bin/aws" <<EOF
#!/usr/bin/env bash
echo "\$*" >>"$T/calls"
case "\$*" in
  *"eks describe-cluster"*) [ -n "\${STUB_CLUSTER_ALIVE:-}" ] ;;
  *"ec2 describe-vpcs"*) if [ -n "\${STUB_NO_VPC:-}" ]; then echo None; else echo vpc-0sweep; fi ;;
  *"elbv2 describe-load-balancers"*"VpcId=='vpc-0sweep'"*)
    printf '%s\t%s\t%s\t%s\n' $LB/gw-a/aaa $LB/gw-b/bbb $LB/eu-west-3-dev-ogenki-openbao/ccc $LB/gw-other/ddd ;;
  *"elbv2 describe-target-groups"*)
    printf '%s\t%s\t%s\t%s\n' $TG/k8s-infrastr-ciliumga-aaa/1a $TG/k8s-security-ciliumga-bbb/2b $TG/eu-west-3-dev-ogenki-openbao/3c $TG/k8s-other-ciliumga-ddd/4d ;;
  *"elbv2 describe-tags"*"targetgroup/"*) cat "$T/tg-tags.json" ;;
  *"elbv2 describe-tags"*) cat "$T/lb-tags.json" ;;
  *"elbv2 delete-target-group"*) [ -z "\${STUB_TG_INUSE:-}" ] || [[ "\$*" != *k8s-security* ]] ;;
  *"ec2 describe-instances"*"Values=vpc-0sweep"*) cat "$T/instances.json" ;;
  *"ec2 describe-network-interfaces"*) echo 0 ;;
  *"ec2 describe-security-groups"*"Values=vpc-0sweep"*"GroupName!=\\\`default\\\`"*)
    jq -Rn '[inputs | split(" ") | {id: .[0], tags: [{Key: .[1], Value: .[2]}]}]' "$T/sgs" ;;
  *"ec2 delete-security-group"*)
    [ -n "\${STUB_SG_STUCK:-}" ] && exit 1
    id="\${@: -1}"; grep -v "^\$id " "$T/sgs" >"$T/sgs.new"; mv "$T/sgs.new" "$T/sgs" ;;
  *"elbv2 delete-load-balancer"*|*"ec2 terminate-instances"*) ;;
  *) echo "unexpected aws call: \$*" >&2; exit 1 ;;
esac
EOF
chmod +x "$T/bin/aws"

# Each run starts from the same cloud: two cluster groups and OpenBao's, an
# empty call log.
sweep() {
  : >"$T/calls"
  printf '%s\n' "sg-0one elbv2.k8s.aws/cluster aws-0" "sg-0two kubernetes.io/cluster/aws-0 owned" \
    "sg-0bao app openbao" >"$T/sgs"
  PATH="$T/bin:$PATH" bash "$SCRIPT" "$@" 2>&1
}
calls() { grep -c -- "$1" "$T/calls"; }

# The out_*/rc_*/calls_* values are read inside check's eval strings, where the
# linter cannot see them.
# shellcheck disable=SC2034
{
out_noname="$(sweep --region eu-west-3)"; rc_noname=$?
out_noregion="$(AWS_REGION='' sweep --cluster-name aws-0)"; rc_noregion=$?
out_unknown="$(sweep --cluster-name aws-0 --region eu-west-3 --force)"; rc_unknown=$?

out_alive="$(STUB_CLUSTER_ALIVE=1 sweep --cluster-name aws-0 --region eu-west-3 --apply)"; rc_alive=$?
calls_alive="$(cat "$T/calls")"

out_novpc="$(STUB_NO_VPC=1 sweep --cluster-name aws-0 --region eu-west-3 --apply)"; rc_novpc=$?
calls_novpc="$(cat "$T/calls")"

out_dry="$(sweep --cluster-name aws-0 --region eu-west-3 --profile ops)"; rc_dry=$?
calls_dry="$(cat "$T/calls")"

out_apply="$(sweep --cluster-name aws-0 --region eu-west-3 --apply)"; rc_apply=$?
calls_apply="$(cat "$T/calls")"; sgs_apply="$(cut -d' ' -f1 "$T/sgs")"

out_vpc="$(sweep --cluster-name aws-0 --region eu-west-3 --vpc-id vpc-0sweep)"; rc_vpc=$?
calls_vpc="$(cat "$T/calls")"

out_stuck="$(STUB_SG_STUCK=1 sweep --cluster-name aws-0 --region eu-west-3 --apply)"; rc_stuck=$?

out_inuse="$(STUB_TG_INUSE=1 sweep --cluster-name aws-0 --region eu-west-3 --apply)"; rc_inuse=$?
}

fails=0
check() { if eval "$2"; then echo "  ok   $1"; else echo "  FAIL $1"; fails=1; fi; }
# Read inside check's eval strings, where the linter cannot see them.
# shellcheck disable=SC2034
{
vpc_deletes='delete-load-balancer|terminate-instances|delete-security-group'
deletes="${vpc_deletes}|delete-target-group"
}

check "no --cluster-name exits 2" '[ "$rc_noname" -eq 2 ] && grep -q -- "--cluster-name is required" <<<"$out_noname"'
check "no --region and no AWS_REGION exits 2" '[ "$rc_noregion" -eq 2 ] && grep -q -- "--region is required" <<<"$out_noregion"'
check "an unknown argument exits 2" '[ "$rc_unknown" -eq 2 ] && grep -q "unknown argument: --force" <<<"$out_unknown"'

check "a live cluster is refused, even with --apply" '[ "$rc_alive" -eq 1 ] && grep -q "still EXISTS" <<<"$out_alive"'
check "  ...after asking EKS about that cluster only" '[ "$calls_alive" = "--region eu-west-3 eks describe-cluster --name aws-0" ]'

check "no non-default VPC exits 0" '[ "$rc_novpc" -eq 0 ] && grep -q "nothing VPC-scoped to sweep" <<<"$out_novpc"'
check "  ...deleting nothing VPC-scoped" '! grep -Eq "$vpc_deletes" <<<"$calls_novpc"'
check "  ...but still sweeps the cluster's target groups" '[ "$(grep -c "elbv2 delete-target-group" <<<"$calls_novpc")" -eq 2 ] && grep -q "swept 2 controller-created resource(s)" <<<"$out_novpc"'
check "the VPC lookup excludes the default VPC" 'grep "describe-vpcs" <<<"$calls_dry" | grep -q "Name=isDefault,Values=false"'
check "  ...and matches the network stack naming" 'grep "describe-vpcs" <<<"$calls_dry" | grep -q "Name=tag:Name,Values=vpc-eu-west-3-\*"'

check "dry run exits 0" '[ "$rc_dry" -eq 0 ]'
check "  ...deletes nothing" '! grep -Eq "$deletes" <<<"$calls_dry"'
check "  ...lists both load balancers by name" 'grep -q "would delete load balancer net/gw-a$" <<<"$out_dry" && grep -q "would delete load balancer net/gw-b$" <<<"$out_dry"'
check "  ...lists both instances" 'grep -q "would delete instance i-0aaa" <<<"$out_dry" && grep -q "would delete instance i-0bbb" <<<"$out_dry"'
check "  ...keeps OpenBao's NLB" 'grep -q "keep   \] load balancer net/eu-west-3-dev-ogenki-openbao " <<<"$out_dry" && ! grep -q "would delete load balancer net/eu-west-3-dev-ogenki-openbao" <<<"$out_dry"'
check "  ...keeps another cluster's load balancer" 'grep -q "keep   \] load balancer net/gw-other " <<<"$out_dry"'
check "  ...keeps OpenBao's node" 'grep -q "keep   \] instance i-0bao " <<<"$out_dry" && ! grep -q "would delete instance i-0bao" <<<"$out_dry"'
check "  ...keeps a cluster-tagged instance of a non-EKS autoscaling group" 'grep -q "keep   \] instance i-0asg " <<<"$out_dry"'
check "  ...keeps an untagged instance" 'grep -q "keep   \] instance i-0bare " <<<"$out_dry"'
check "  ...never lists OpenBao's security group" '! grep -q sg-0bao <<<"$out_dry"'
check "  ...lists both security groups" 'grep -q "would delete security group sg-0one" <<<"$out_dry" && grep -q "would delete security group sg-0two" <<<"$out_dry"'
check "  ...lists both cluster target groups" 'grep -q "would delete target group k8s-infrastr-ciliumga-aaa$" <<<"$out_dry" && grep -q "would delete target group k8s-security-ciliumga-bbb$" <<<"$out_dry"'
check "  ...keeps OpenBao's target group" 'grep -q "keep   \] target group eu-west-3-dev-ogenki-openbao " <<<"$out_dry"'
check "  ...keeps another cluster's target group" 'grep -q "keep   \] target group k8s-other-ciliumga-ddd " <<<"$out_dry"'
check "  ...counts eight items" 'grep -q "dry-run: 8 item(s) would be swept" <<<"$out_dry"'
check "  ...passes --profile to every call" '! grep -v -- "--profile ops" <<<"$calls_dry" | grep -q .'

check "--apply exits 0" '[ "$rc_apply" -eq 0 ]'
check "  ...deletes each load balancer by ARN" '[ "$(grep -c "elbv2 delete-load-balancer --load-balancer-arn arn:aws:elasticloadbalancing:.*loadbalancer/net/gw-[ab]/" <<<"$calls_apply")" -eq 2 ]'
check "  ...and no other load balancer" '[ "$(grep -c "elbv2 delete-load-balancer" <<<"$calls_apply")" -eq 2 ]'
check "  ...waits only on the swept ENIs" 'grep -q "describe-network-interfaces --filters Name=attachment.instance-id,Values=i-0aaa,i-0bbb " <<<"$calls_apply" && grep -q "Name=description,Values=ELB net/gw-a/aaa,ELB net/gw-b/bbb " <<<"$calls_apply"'
check "  ...terminates both instances in one call" 'grep -q "ec2 terminate-instances --instance-ids i-0aaa i-0bbb$" <<<"$calls_apply"'
check "  ...waits on ENIs before the security groups" '[ "$(grep -n -m1 describe-network-interfaces <<<"$calls_apply" | cut -d: -f1)" -lt "$(grep -n -m1 delete-security-group <<<"$calls_apply" | cut -d: -f1)" ]'
check "  ...deletes both cluster security groups, and OpenBao's survives" 'grep -q "delete-security-group --group-id sg-0one" <<<"$calls_apply" && grep -q "delete-security-group --group-id sg-0two" <<<"$calls_apply" && [ "$sgs_apply" = sg-0bao ]'
check "  ...never asks to delete OpenBao's security group" '! grep -q "delete-security-group --group-id sg-0bao" <<<"$calls_apply"'
check "  ...deletes exactly the two cluster target groups, by ARN" '[ "$(grep -c "elbv2 delete-target-group --target-group-arn arn:aws:elasticloadbalancing:.*targetgroup/k8s-\(infrastr\|security\)-" <<<"$calls_apply")" -eq 2 ] && [ "$(grep -c "elbv2 delete-target-group" <<<"$calls_apply")" -eq 2 ]'
check "  ...deletes target groups after the load balancers" '[ "$(grep -n delete-load-balancer <<<"$calls_apply" | tail -1 | cut -d: -f1)" -lt "$(grep -n -m1 delete-target-group <<<"$calls_apply" | cut -d: -f1)" ]'
check "  ...counts eight swept" 'grep -q "swept 8 controller-created resource(s)" <<<"$out_apply"'

check "--vpc-id skips the VPC lookup" '[ "$rc_vpc" -eq 0 ] && ! grep -q describe-vpcs <<<"$calls_vpc" && grep -q "scoping to vpc-0sweep" <<<"$out_vpc"'

check "security groups that will not delete stop after one pass" '[ "$rc_stuck" -eq 0 ] && grep -q "no progress; still held: sg-0one" <<<"$out_stuck" && ! grep -q "(pass 2)" <<<"$out_stuck"'
check "  ...and are not counted as swept" 'grep -q "swept 6 controller-created resource(s)" <<<"$out_stuck"'

check "a target group that will not delete is warned about" '[ "$rc_inuse" -eq 0 ] && grep -q "warn   \] target group k8s-security-ciliumga-bbb did not delete" <<<"$out_inuse"'
check "  ...and is not counted as swept" 'grep -q "swept 7 controller-created resource(s)" <<<"$out_inuse"'

[ "$fails" -eq 0 ] && echo "all checks passed"
exit "$fails"
