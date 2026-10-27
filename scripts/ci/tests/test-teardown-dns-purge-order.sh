#!/usr/bin/env bash
#
# external-dns records must be gone BEFORE the load balancers they point at are
# released. On AWS those LBs are released inside eks-prepare-destroy.sh (the
# Gateway Services are deleted there) -- the first job of eks/init's destroy --
# while the Route53 records used to be removed only by sweep-teardown-blockers.sh
# AFTER the whole walk. So this checks, offline:
#   1. sweep-teardown-blockers.sh --dns-only clears records and touches no EC2;
#   2. eks-prepare-destroy.sh stops external-dns and purges the records before it
#      deletes any Gateway or Gateway Service.
# (GCP is already ordered: gcp/network's destroy purges the zone before tofu
# destroys it, and the GKE LBs are only swept after the walk.)
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
T="$(cd "$(mktemp -d)" && pwd -P)"; trap 'rm -rf "$T"' EXIT
fails=0
f() { echo "FAIL $*"; fails=1; }

mkdir -p "$T/bin"
cat >"$T/bin/aws" <<STUB
#!/usr/bin/env bash
echo "\$*" >>"$T/aws-calls"
case "\$*" in
  *"route53 list-hosted-zones"*) printf 'Z1\tpriv.example.\tTrue\n' ;;
  *"route53 list-resource-record-sets"*) echo '[{"Name":"a.priv.example.","Type":"A"}]' ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$T/bin/aws"

PATH="$T/bin:$PATH" bash "$ROOT/scripts/ops/aws/sweep-teardown-blockers.sh" \
  --cluster-name c --region eu-west-3 --dns-only --apply >"$T/out" 2>&1 || f "--dns-only failed: $(cat "$T/out")"
grep -q 'change-resource-record-sets' "$T/aws-calls" 2>/dev/null || f "--dns-only did not delete the records"
! grep -q ' ec2 ' "$T/aws-calls" 2>/dev/null || f "--dns-only touched EC2"

P="$ROOT/scripts/ops/aws/eks-prepare-destroy.sh"
line() { grep -n -- "$1" "$P" | grep -v "^[0-9]*:[[:space:]]*#" | head -1 | cut -d: -f1; }
purge="$(line 'sweep-teardown-blockers.sh')"
stop="$(line 'scale .*external-dns')"
gw="$(line 'kubectl delete gateways')"
svc="$(line 'kubectl delete svc -l gateway.networking.k8s.io')"
# shellcheck disable=SC2016  # literal text to find, not an expansion
rt="$(line 'kubectl delete "${route_kind}"')"
for v in purge stop gw svc rt; do [ -n "${!v}" ] || f "eks-prepare-destroy.sh: no line found for $v"; done
if [ -n "$purge$stop$gw$svc$rt" ]; then
  [ "${stop:-999}" -lt "${purge:-0}" ] || f "external-dns must be stopped before the purge"
  for later in gw svc rt; do
    [ "${purge:-999}" -lt "${!later:-0}" ] || f "the DNS purge (line ${purge:-?}) must precede the $later delete (line ${!later:-?})"
  done
fi

[ "$fails" -eq 0 ] && echo PASS
exit "$fails"
