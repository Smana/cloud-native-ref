#!/usr/bin/env bash
#
# sweep-controller-orphans.sh with aws stubbed on PATH. The guard that matters
# is the first one: while the EKS cluster exists nothing is an orphan, so the
# script must exit before it lists, let alone deletes, anything. Past it, a dry
# run deletes nothing and --apply deletes exactly the load balancers, instances
# and non-default security groups of the one VPC it scoped to.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SCRIPT="$ROOT/scripts/ops/aws/sweep-controller-orphans.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"
# Every call is logged; security groups live in a file so a delete is visible
# to the next describe, which is what the multi-pass loop keys on.
cat >"$T/bin/aws" <<EOF
#!/usr/bin/env bash
echo "\$*" >>"$T/calls"
case "\$*" in
  *"eks describe-cluster"*) [ -n "\${STUB_CLUSTER_ALIVE:-}" ] ;;
  *"ec2 describe-vpcs"*) if [ -n "\${STUB_NO_VPC:-}" ]; then echo None; else echo vpc-0sweep; fi ;;
  *"elbv2 describe-load-balancers"*"VpcId=='vpc-0sweep'"*)
    printf '%s\t%s\n' arn:aws:elasticloadbalancing:eu-west-3:111111111111:loadbalancer/net/gw-a/aaa \\
                      arn:aws:elasticloadbalancing:eu-west-3:111111111111:loadbalancer/net/gw-b/bbb ;;
  *"ec2 describe-instances"*"Values=vpc-0sweep"*) printf 'i-0aaa\ti-0bbb\n' ;;
  *"ec2 describe-network-interfaces"*) echo 0 ;;
  *"ec2 describe-security-groups"*"Values=vpc-0sweep"*"GroupName!=\\\`default\\\`"*) tr '\n' '\t' <"$T/sgs" ;;
  *"ec2 delete-security-group"*)
    [ -n "\${STUB_SG_STUCK:-}" ] && exit 1
    id="\${*##* }"; grep -vx "\$id" "$T/sgs" >"$T/sgs.new"; mv "$T/sgs.new" "$T/sgs" ;;
  *"elbv2 delete-load-balancer"*|*"ec2 terminate-instances"*) ;;
  *) echo "unexpected aws call: \$*" >&2; exit 1 ;;
esac
EOF
chmod +x "$T/bin/aws"

# Each run starts from the same cloud: two groups, an empty call log.
sweep() {
  : >"$T/calls"; printf '%s\n' sg-0one sg-0two >"$T/sgs"
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
calls_apply="$(cat "$T/calls")"; sgs_apply="$(cat "$T/sgs")"

out_vpc="$(sweep --cluster-name aws-0 --region eu-west-3 --vpc-id vpc-0sweep)"; rc_vpc=$?
calls_vpc="$(cat "$T/calls")"

out_stuck="$(STUB_SG_STUCK=1 sweep --cluster-name aws-0 --region eu-west-3 --apply)"; rc_stuck=$?
}

fails=0
check() { if eval "$2"; then echo "  ok   $1"; else echo "  FAIL $1"; fails=1; fi; }
deletes='delete-load-balancer|terminate-instances|delete-security-group'

check "no --cluster-name exits 2" '[ "$rc_noname" -eq 2 ] && grep -q -- "--cluster-name is required" <<<"$out_noname"'
check "no --region and no AWS_REGION exits 2" '[ "$rc_noregion" -eq 2 ] && grep -q -- "--region is required" <<<"$out_noregion"'
check "an unknown argument exits 2" '[ "$rc_unknown" -eq 2 ] && grep -q "unknown argument: --force" <<<"$out_unknown"'

check "a live cluster is refused, even with --apply" '[ "$rc_alive" -eq 1 ] && grep -q "still EXISTS" <<<"$out_alive"'
check "  ...after asking EKS about that cluster only" '[ "$calls_alive" = "--region eu-west-3 eks describe-cluster --name aws-0" ]'

check "no non-default VPC exits 0" '[ "$rc_novpc" -eq 0 ] && grep -q "nothing to sweep" <<<"$out_novpc"'
check "  ...deleting nothing" '! grep -Eq "$deletes" <<<"$calls_novpc"'
check "the VPC lookup excludes the default VPC" 'grep "describe-vpcs" <<<"$calls_dry" | grep -q "Name=isDefault,Values=false"'
check "  ...and matches the network stack naming" 'grep "describe-vpcs" <<<"$calls_dry" | grep -q "Name=tag:Name,Values=vpc-eu-west-3-\*"'

check "dry run exits 0" '[ "$rc_dry" -eq 0 ]'
check "  ...deletes nothing" '! grep -Eq "$deletes" <<<"$calls_dry"'
check "  ...lists both load balancers by name" 'grep -q "would delete load balancer net/gw-a$" <<<"$out_dry" && grep -q "would delete load balancer net/gw-b$" <<<"$out_dry"'
check "  ...lists both instances" 'grep -q "would delete instance i-0aaa" <<<"$out_dry" && grep -q "would delete instance i-0bbb" <<<"$out_dry"'
check "  ...lists both security groups" 'grep -q "would delete security group sg-0one" <<<"$out_dry" && grep -q "would delete security group sg-0two" <<<"$out_dry"'
check "  ...counts six items" 'grep -q "dry-run: 6 item(s) would be swept" <<<"$out_dry"'
check "  ...passes --profile to every call" '! grep -v -- "--profile ops" <<<"$calls_dry" | grep -q .'

check "--apply exits 0" '[ "$rc_apply" -eq 0 ]'
check "  ...deletes each load balancer by ARN" '[ "$(grep -c "elbv2 delete-load-balancer --load-balancer-arn arn:aws:elasticloadbalancing:.*loadbalancer/net/gw-[ab]/" <<<"$calls_apply")" -eq 2 ]'
check "  ...terminates both instances in one call" 'grep -q "ec2 terminate-instances --instance-ids i-0aaa i-0bbb$" <<<"$calls_apply"'
check "  ...waits on ENIs before the security groups" '[ "$(grep -n -m1 describe-network-interfaces <<<"$calls_apply" | cut -d: -f1)" -lt "$(grep -n -m1 delete-security-group <<<"$calls_apply" | cut -d: -f1)" ]'
check "  ...deletes both security groups" 'grep -q "delete-security-group --group-id sg-0one" <<<"$calls_apply" && grep -q "delete-security-group --group-id sg-0two" <<<"$calls_apply" && [ -z "$sgs_apply" ]'
check "  ...counts six swept" 'grep -q "swept 6 controller-created resource(s)" <<<"$out_apply"'

check "--vpc-id skips the VPC lookup" '[ "$rc_vpc" -eq 0 ] && ! grep -q describe-vpcs <<<"$calls_vpc" && grep -q "scoping to vpc-0sweep" <<<"$out_vpc"'

check "security groups that will not delete stop after one pass" '[ "$rc_stuck" -eq 0 ] && grep -q "no progress; still held: sg-0one" <<<"$out_stuck" && ! grep -q "(pass 2)" <<<"$out_stuck"'
check "  ...and are not counted as swept" 'grep -q "swept 4 controller-created resource(s)" <<<"$out_stuck"'

[ "$fails" -eq 0 ] && echo "all checks passed"
exit "$fails"
