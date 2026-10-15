#!/usr/bin/env bash
#
# sweep-controller-orphans.sh with aws (and sleep) stubbed on PATH: no
# credentials, no network, and --apply never reaches a real CLI. The world the
# stub serves is vpc-0 -- one NLB, two instances, security groups sg-a/sg-b and
# three ENIs that release once the LB and the instances are gone -- and nothing
# at all in any other VPC.
#   - the dry run reports every orphan class and deletes nothing
#   - --apply deletes the load balancer first (its ENIs hold the subnets), then
#     terminates the instances in one call, waits for the ENIs, then deletes
#     the security groups
#   - a security group whose delete fails is retried on the next pass and never
#     counted as swept; one that never leaves is warned about once
#   - an EKS cluster that still exists refuses to sweep anything -- and so does
#     a cluster describe that fails, because "cannot tell" is not "gone"
#   - no non-default VPC: exit 0, nothing swept; an explicit --vpc-id skips the
#     discovery and scopes every call to it
#   - missing or unknown arguments: exit 2 before any aws call
#
# This is the destructive path of a teardown, so every invocation first proves
# aws resolves to the stub (require_stub). sleep is stubbed too: the ENI wait
# polls up to 300s in real time, and the real one would stall the suite.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
S="$ROOT/scripts/ops/aws/sweep-controller-orphans.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"

# Every call lands in $CALLS one per line; the destructive ones in $DELETES,
# and only those that succeeded -- a failed delete leaves the resource in the
# lists, which is what drives the retry passes.
# STUB_CLUSTER_UP: describe-cluster succeeds (the cluster still exists).
# STUB_CLUSTER_FAIL: it fails loudly (cannot tell -- must refuse, not sweep).
# STUB_NO_VPC: the tagged-VPC lookup finds nothing.
# SG_DEL_FAIL: that group's delete always fails. SG_STUCK: the groups never
# leave the list no matter how many times they are deleted.
cat >"$T/bin/aws" <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" = --stub-probe ] && { echo stub; exit 0; }
cmd="$*"
echo "aws $cmd" >>"$CALLS"
# vpc0: is this call scoped to vpc-0, the only VPC the stub serves? (vpc0 takes
# no arguments on purpose: it must see the stub's own command line, so it reads
# $cmd -- a helper reading "$*" would see its own, empty, argument list.)
vpc0() {
  case "$cmd" in
    *"VpcId=='vpc-0'"*|*"Values=vpc-0"*) return 0 ;;
    *) return 1 ;;
  esac
}
case "$*" in
  *" eks describe-cluster "*)
    if [ -n "${STUB_CLUSTER_FAIL:-}" ]; then echo "Unable to locate cluster (unauthorized)" >&2; exit 255; fi
    if [ -n "${STUB_CLUSTER_UP:-}" ]; then echo '{"cluster":{"name":"aws-0"}}'; exit 0; fi
    exit 254 ;;
  *" ec2 describe-vpcs "*)
    [ -n "${STUB_NO_VPC:-}" ] || echo "vpc-0" ;;
  *" elbv2 describe-load-balancers "*)
    vpc0 && printf 'arn:aws:elasticloadbalancing:eu-west-3:1:loadbalancer/net/gw-nlb/abc123\n' ;;
  *" elbv2 delete-load-balancer "*)
    echo "aws $*" >>"$DELETES" ;;
  *" ec2 describe-instances "*)
    vpc0 && printf 'i-0aaa i-0bbb\n' ;;
  *" ec2 terminate-instances "*)
    echo "aws $*" >>"$DELETES" ;;
  *" ec2 describe-network-interfaces "*)
    if vpc0 && ! { grep -q "elbv2 delete-load-balancer" "$DELETES" && grep -q "ec2 terminate-instances" "$DELETES"; }; then
      echo 3
    else
      echo 0
    fi ;;
  *" ec2 describe-security-groups "*)
    if vpc0 && [ -z "${STUB_NO_VPC:-}" ]; then
      g=""
      { [ -n "${SG_STUCK:-}" ] || grep -q "delete-security-group --group-id sg-a" "$DELETES"; } || g="sg-a"
      { [ -n "${SG_STUCK:-}" ] || grep -q "delete-security-group --group-id sg-b" "$DELETES"; } || g="$g sg-b"
      g="${g# }"; [ -n "$g" ] && echo "$g"
    fi ;;
  *" ec2 delete-security-group "*)
    if [ -z "${SG_DEL_FAIL:-}" ] || [[ "$*" != *"--group-id ${SG_DEL_FAIL}"* ]]; then
      echo "aws $*" >>"$DELETES"
    else
      exit 1
    fi ;;
  *) echo "UNSTUBBED: aws $*" >&2; exit 1 ;;
esac
exit 0
EOF
printf '#!/usr/bin/env bash\nexit 0\n' >"$T/bin/sleep"
chmod +x "$T/bin/aws" "$T/bin/sleep"
export PATH="$T/bin:$PATH"

require_stub() {
  if [ "$(command -v aws)" != "$T/bin/aws" ] || [ "$(aws --stub-probe 2>/dev/null)" != stub ]; then
    echo "ABORT: aws resolves to '$(command -v aws)', not the stub; refusing to run the sweep" >&2
    exit 1
  fi
}
# run CASE [env=val...] -- [script args...]: stdout/stderr/rc to $T/CASE.*,
# aws calls and destructive calls to $T/CASE.calls / $T/CASE.deletes. The env
# assignments go through env(1) so each case's world is stated at its call
# site, never inherited by the next one. AWS_REGION= keeps a developer's
# exported region from satisfying the --region guard.
run() {
  local name="$1"; shift
  local -a e=(AWS_REGION=) a=()
  while [ $# -gt 0 ] && [ "$1" != "--" ]; do e+=("$1"); shift; done
  [ "${1:-}" = "--" ] && shift
  a=("$@")
  require_stub
  : >"$T/$name.calls"; : >"$T/$name.deletes"
  CALLS="$T/$name.calls" DELETES="$T/$name.deletes" \
    env "${e[@]}" bash "$S" ${a+"${a[@]}"} >"$T/$name.out" 2>"$T/$name.err"
  echo $? >"$T/$name.rc"
}
fails=0
# The rc files are read inside check's eval strings, where the linter cannot
# see them.
check() { if eval "$2"; then echo "  ok   $1"; else echo "  FAIL $1"; fails=1; fi; }

# ---- the guard: a cluster that exists, or one nobody can tell about ----------
run alive STUB_CLUSTER_UP=1 -- --cluster-name aws-0 --region eu-west-3 --apply
check "a live cluster: exit 1" '[ "$(cat "$T/alive.rc")" -eq 1 ]'
check "  ...saying the cluster still exists" 'grep -q "EKS cluster aws-0 still EXISTS" "$T/alive.err"'
check "  ...and why: not orphans yet" 'grep -q "only orphans once their controllers are gone" "$T/alive.err"'
check "  ...and that it refuses to sweep" 'grep -q "Refusing to sweep" "$T/alive.err"'
check "  ...listing nothing, deleting nothing" '! grep -qE "describe-load-balancers|describe-instances|delete" "$T/alive.calls"'

run blind STUB_CLUSTER_FAIL=1 -- --cluster-name aws-0 --region eu-west-3 --apply
check "a failed cluster describe: exit 1" '[ "$(cat "$T/blind.rc")" -eq 1 ]'
check "  ...refusing, not sweeping blind" 'grep -q "Refusing to sweep" "$T/blind.err"'

# ---- the dry run --------------------------------------------------------------
run dry -- --cluster-name aws-0 --region eu-west-3
check "dry run: exit 0" '[ "$(cat "$T/dry.rc")" -eq 0 ]'
check "dry run: deletes nothing" '[ ! -s "$T/dry.deletes" ]'
check "dry run: counts 5 items (1 LB, 2 instances, 2 SGs)" 'grep -q "dry-run: 5 item(s) would be swept" "$T/dry.out"'
check "dry run: would delete the load balancer" 'grep -q "\[dry-run\] would delete load balancer net/gw-nlb" "$T/dry.out"'
check "dry run: would terminate both instances" 'grep -q "would delete instance i-0aaa" "$T/dry.out" && grep -q "would delete instance i-0bbb" "$T/dry.out"'
check "dry run: would delete both security groups" 'grep -q "would delete security group sg-a" "$T/dry.out" && grep -q "would delete security group sg-b" "$T/dry.out"'
check "dry run: discovers the VPC by tag, never the default" \
  'grep "ec2 describe-vpcs" "$T/dry.calls" | grep -q "Name=tag:Name,Values=vpc-eu-west-3-\*"'
check "dry run: the same, isDefault=false" 'grep "ec2 describe-vpcs" "$T/dry.calls" | grep -q "Name=isDefault,Values=false"'
check "dry run: LBs and instances listed in the VPC only" \
  'grep "describe-instances" "$T/dry.calls" | grep -q "Name=vpc-id,Values=vpc-0"'
check "dry run: the SG list excludes the default group" 'grep "describe-security-groups" "$T/dry.calls" | grep -q "GroupName!=.default."'
check "dry run: never waits for ENIs" '! grep -q "describe-network-interfaces" "$T/dry.calls"'
check "dry run: no destructive call at all" '[ ! -s "$T/dry.deletes" ]'
check "every aws call carries the region" '! grep -v "^aws --region eu-west-3 " "$T/dry.calls" | grep -q .'

# --profile threads through to every call.
run prof -- --cluster-name aws-0 --region eu-west-3 --profile ops
check "--profile: on the cluster check" 'grep -q "^aws --region eu-west-3 --profile ops eks describe-cluster --name aws-0" "$T/prof.calls"'
check "--profile: dry run still exit 0" '[ "$(cat "$T/prof.rc")" -eq 0 ]'

# ---- --apply ------------------------------------------------------------------
run apply -- --cluster-name aws-0 --region eu-west-3 --apply
check "apply: exit 0" '[ "$(cat "$T/apply.rc")" -eq 0 ]'
check "apply: 4 destructive calls (1 LB, 1 terminate, 2 SGs)" '[ "$(grep -c . "$T/apply.deletes")" -eq 4 ]'
check "apply: deletes the load balancer by its full ARN" \
  'grep -q "elbv2 delete-load-balancer --load-balancer-arn arn:aws:elasticloadbalancing:eu-west-3:1:loadbalancer/net/gw-nlb/abc123" "$T/apply.deletes"'
check "apply: terminates both instances in one call" \
  'grep -q "ec2 terminate-instances --instance-ids i-0aaa i-0bbb" "$T/apply.deletes"'
check "apply: LBs first (their ENIs hold the subnets), then instances, then SGs" \
  '[ "$(sed "s/^aws //; s/ --.*//" "$T/apply.deletes" | uniq | tr "\n" " ")" = "elbv2 delete-load-balancer ec2 terminate-instances ec2 delete-security-group " ]'
check "apply: waits for the ENIs, scoped to the VPC" \
  'grep "describe-network-interfaces" "$T/apply.calls" | grep -q "Name=vpc-id,Values=vpc-0"'
check "apply: the ENI wait sees them released and stops" '[ "$(grep -c "ENIs remaining" "$T/apply.out")" -eq 1 ] && grep -q "ENIs remaining: 0" "$T/apply.out"'
check "apply: reports each deleted security group" 'grep -q "\[delete \] security group sg-a (pass 1)" "$T/apply.out" && grep -q "security group sg-b (pass 1)" "$T/apply.out"'
check "apply: reports the swept count" 'grep -q "==> swept 5 controller-created resource(s)" "$T/apply.out"'

# ---- security groups: a delete that fails, and one that never leaves ---------
run sgfail SG_DEL_FAIL=sg-a -- --cluster-name aws-0 --region eu-west-3 --apply
check "a failed SG delete: still exit 0" '[ "$(cat "$T/sgfail.rc")" -eq 0 ]'
check "  ...the other group is swept" 'grep -q "\[delete \] security group sg-b (pass 1)" "$T/sgfail.out"'
check "  ...the failing group is retried, not skipped" '[ "$(grep -c "delete-security-group --group-id sg-a" "$T/sgfail.calls")" -ge 2 ]'
check "  ...and never counted as swept" 'grep -q "==> swept 1 controller-created resource(s)" "$T/sgfail.out"'
check "  ...with no-progress stopping the passes" 'grep -q "no progress; still held: sg-a" "$T/sgfail.out"'

run stuck SG_STUCK=1 -- --cluster-name aws-0 --region eu-west-3 --apply
check "security groups that never leave: exit 0" '[ "$(cat "$T/stuck.rc")" -eq 0 ]'
check "  ...warned about exactly once" '[ "$(grep -c "\[warn   \] no progress; still held: sg-a sg-b" "$T/stuck.out")" -eq 1 ]'

# ---- no VPC to sweep, and an explicit one -------------------------------------
run novpc STUB_NO_VPC=1 -- --cluster-name aws-0 --region eu-west-3 --apply
check "no non-default VPC: exit 0, nothing swept, nothing deleted" \
  '[ "$(cat "$T/novpc.rc")" -eq 0 ] && grep -q "nothing to sweep" "$T/novpc.out" && [ ! -s "$T/novpc.deletes" ]'

run explicit -- --cluster-name aws-0 --region eu-west-3 --vpc-id vpc-9 --apply
check "an explicit --vpc-id: no discovery call" '! grep -q "describe-vpcs" "$T/explicit.calls"'
check "  ...every list scoped to that VPC" 'grep "describe-instances" "$T/explicit.calls" | grep -q "Name=vpc-id,Values=vpc-9"'
check "  ...a VPC with no orphans sweeps nothing, exit 0" '[ "$(cat "$T/explicit.rc")" -eq 0 ] && grep -q "==> swept 0 controller-created resource(s)" "$T/explicit.out"'

# ---- argument guards ----------------------------------------------------------
run noargs --
check "no arguments: exit 2, no aws call" '[ "$(cat "$T/noargs.rc")" -eq 2 ] && [ ! -s "$T/noargs.calls" ]'
for drop in --cluster-name --region; do
  a=("--cluster-name" "aws-0" "--region" "eu-west-3")
  i=0; while [ "$i" -lt "${#a[@]}" ]; do [ "${a[$i]}" = "$drop" ] && unset "a[$i]" "a[$((i+1))]" && break; i=$((i+2)); done
  run "drop${drop#--}" -- ${a+"${a[@]}"}
  check "without $drop: exit 2, no aws call" '[ "$(cat "$T/drop${drop#--}.rc")" -eq 2 ] && [ ! -s "$T/drop${drop#--}.calls" ]'
done
run unknown -- --cluster-name aws-0 --region eu-west-3 --aply
check "an unknown argument: exit 2, no aws call" '[ "$(cat "$T/unknown.rc")" -eq 2 ] && [ ! -s "$T/unknown.calls" ]'

[ "$fails" -eq 0 ] && echo "all checks passed"
exit "$fails"
