#!/usr/bin/env bash
#
# teardown.sh destroys the network stacks last, and skips aws/network while an
# OpenBao node still stands: on 2026-10-16 the network destroy ran after a
# failed openbao/cluster destroy, deleted the private Route53 zone, then failed
# on the VPC. A failed node lookup must block it too, and gcp/network gets the
# same gate on GCP's OpenBao. --verify-only must also report target groups,
# which outlive their load balancer and VPC, and the target-group sweep must
# run after a retry, whose destroy may be the one that deletes the VPC.
#
# Runs the REAL teardown.sh with TM_DESTROY_CONFIRMED=true, kept offline only by
# PATH shadowing, so every invocation first proves the stubs are what runs.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
set -e
# Absolute: teardown.sh cd's before calling terramate.
T="$(cd "$(mktemp -d)" && pwd -P)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"
cat >"$T/bin/aws" <<EOF
#!/usr/bin/env bash
[ "\$1" != --stub-probe ] || { echo stub; exit 0; }
echo "\$*" >>"$T/aws-calls"
case "\$*" in
  *"eks describe-cluster"*) exit 1 ;;
  *"ec2 describe-instances"*OpenBaoInstance*) [ -z "\${BAO_FAIL:-}" ] || exit 1; echo "\${BAO_NODES:-}" ;;
  *"ec2 describe-vpcs"*)
    # VPC_UNTIL_RETRY=1: the VPC stands until the retry walk (destroys 3-4) deletes it.
    [ -n "\${VPC_UNTIL_RETRY:-}" ] && [ "\$(wc -l <"$T/destroys")" -lt 3 ] && echo vpc-0abc
    exit 0 ;;
  *"elbv2 describe-target-groups"*TargetGroupArn*) echo "after \$(wc -l <"$T/destroys") destroys" >>"$T/tg-sweeps"; echo "\${TGS:-}" ;;
  *"elbv2 describe-target-groups"*) echo "\${TGS:-}" ;;
  *"elbv2 delete-"*|*"ec2 delete-"*|*"ec2 terminate-"*) echo "\$*" >>"$T/deletes" ;;
  *) exit 0 ;;
esac
EOF
cat >"$T/bin/terramate" <<EOF
#!/usr/bin/env bash
[ "\$1" != --stub-probe ] || { echo stub; exit 0; }
echo "\$*" >>"$T/destroys"
EOF
# With TM_CLOUD=aws only the stub probe; with TM_CLOUD=gcp the OpenBao lookup.
cat >"$T/bin/gcloud" <<EOF
#!/usr/bin/env bash
[ "\$1" != --stub-probe ] || { echo stub; exit 0; }
case "\$*" in
  *"compute instances list"*labels.app=openbao*) [ -z "\${GBAO_FAIL:-}" ] || exit 1; echo "\${GBAO_NODES:-}" ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$T/bin/aws" "$T/bin/terramate" "$T/bin/gcloud"
set +e
export PATH="$T/bin:$PATH"
# These stubs are not the pinned tofu/terramate; the pin check has its own suite (test-tool-pins.sh).
export TM_SKIP_TOOL_PIN_CHECK=true

require_stubs() {
  local tool
  for tool in aws terramate gcloud; do
    if [ "$(command -v "$tool")" != "$T/bin/$tool" ] \
       || [ "$("$T/bin/$tool" --stub-probe 2>/dev/null)" != stub ]; then
      echo "ABORT: $tool resolves to '$(command -v "$tool")', not the stub in $T/bin" >&2
      exit 1
    fi
  done
}
fails=0
f() { echo "FAIL $*"; fails=1; }

teardown() { # env assignments; TM_CLOUD=aws unless one of them overrides it
  : >"$T/destroys"; : >"$T/deletes"; : >"$T/tg-sweeps"
  require_stubs
  out="$(env TM_CLOUD=aws "$@" TM_DESTROY_CONFIRMED=true bash "$ROOT/scripts/ops/teardown/teardown.sh" 2>&1)"; rc=$?
}

teardown
grep -q -- '--reverse --continue-on-error --no-tags=network destroy$' "$T/destroys" || f "phase 1 does not exclude the network stacks"
grep -q -- '--reverse --continue-on-error --tags=network destroy$' "$T/destroys" || f "with OpenBao gone, the network stacks are not destroyed"
[ "$(sed -n 1p "$T/destroys")" = "script run --reverse --continue-on-error --no-tags=network destroy" ] \
  || f "the network stacks are not destroyed last: $(cat "$T/destroys")"
[ "$rc" -eq 0 ] || f "a clean teardown must exit 0, got $rc: $out"

for case in BAO_NODES=i-0bao BAO_FAIL=1; do
  teardown "$case"
  grep -q -- '--tags=network --no-tags=aws,tailscale destroy$' "$T/destroys" || f "$case: aws/network is not skipped"
  ! grep -q -- '--tags=network destroy$' "$T/destroys" || f "$case: aws/network was destroyed anyway"
  grep -q 'Skipping aws/network' <<<"$out" || f "$case: no skip message"
  grep -q 'aws/network was NOT destroyed' <<<"$out" || f "$case: the summary does not say so"
  [ "$rc" -ne 0 ] || f "$case: must exit non-zero"
done

# GCP's OpenBao gates gcp/network the same way.
for case in GBAO_NODES=openbao-dev-x1z2 GBAO_FAIL=1; do
  teardown TM_CLOUD=gcp "$case"
  grep -q -- '--tags=network --no-tags=gcp,tailscale destroy$' "$T/destroys" || f "gcp $case: gcp/network is not skipped"
  ! grep -q -- '--tags=network destroy$' "$T/destroys" || f "gcp $case: gcp/network was destroyed anyway"
  grep -q 'Skipping gcp/network' <<<"$out" || f "gcp $case: no skip message"
  grep -q 'gcp/network was NOT destroyed' <<<"$out" || f "gcp $case: the summary does not say so"
  [ "$rc" -ne 0 ] || f "gcp $case: must exit non-zero"
done
teardown TM_CLOUD=gcp
grep -q -- '--tags=network destroy$' "$T/destroys" || f "gcp: with OpenBao gone, the network stacks are not destroyed"
# Both lanes standing: one network walk that skips both.
teardown TM_CLOUD=all BAO_NODES=i-0bao GBAO_NODES=openbao-dev-x1z2
grep -q -- '--tags=network --no-tags=aws,gcp,tailscale destroy$' "$T/destroys" || f "all: both networks are not skipped: $(cat "$T/destroys")"

# The VPC goes only in the retry: target groups are swept again after it.
teardown VPC_UNTIL_RETRY=1
[ "$(grep -c -- '--no-tags=network destroy$' "$T/destroys")" -eq 2 ] || f "a standing VPC must trigger one retry: $(cat "$T/destroys")"
grep -q '^after 4 destroys$' "$T/tg-sweeps" || f "no target-group sweep after the retry: $(cat "$T/tg-sweeps")"

require_stubs
out="$(TM_CLOUD=aws TGS=k8s-infrastr-ciliumga-871e7ed24f bash "$ROOT/scripts/ops/teardown/teardown.sh" --verify-only 2>&1)"; rc=$?
grep -q 'LEFT Target groups .*k8s-infrastr-ciliumga-871e7ed24f' <<<"$out" || f "--verify-only does not report target groups: $out"
[ "$rc" -ne 0 ] || f "a leftover target group must fail the verify"

[ "$fails" -eq 0 ] && echo PASS
exit "$fails"
