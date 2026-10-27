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
SWEEP="${SWEEP:-$ROOT/scripts/ops/aws/sweep-teardown-blockers.sh}"
# Three private zones and a public one of the same name: only the cluster's own
# private zone may be touched, and only the records its external-dns owns.
OWN='"heritage=external-dns,external-dns/owner=aws-0,external-dns/resource=httproute/x/y"'
OTHER='"heritage=external-dns,external-dns/owner=aws-1,external-dns/resource=httproute/x/y"'
cat >"$T/bin/aws" <<STUB
#!/usr/bin/env bash
echo "\$*" >>"$T/aws-calls"
case "\$*" in
  *"route53 list-hosted-zones"*)
    printf 'Z1\tpriv.example.\tTrue\nZ2\tother.example.\tTrue\nZ3\tpriv.example.\tFalse\n' ;;
  *"route53 list-resource-record-sets"*)
    z=\$(printf '%s\n' "\$@" | sed -n '/^--hosted-zone-id\$/{n;p}')
    if [ "\$z" = Z2 ]; then
      echo '{"ResourceRecordSets":[{"Name":"a.other.example.","Type":"A","TTL":60,"ResourceRecords":[{"Value":"1.1.1.1"}]},{"Name":"a-a.other.example.","Type":"TXT","TTL":60,"ResourceRecords":[{"Value":$OWN}]}]}'
    else
      echo '{"ResourceRecordSets":[
        {"Name":"priv.example.","Type":"NS","TTL":60,"ResourceRecords":[{"Value":"ns"}]},
        {"Name":"app.priv.example.","Type":"A","TTL":60,"ResourceRecords":[{"Value":"10.0.0.1"}]},
        {"Name":"a-app.priv.example.","Type":"TXT","TTL":60,"ResourceRecords":[{"Value":$OWN}]},
        {"Name":"foreign.priv.example.","Type":"A","TTL":60,"ResourceRecords":[{"Value":"10.0.0.2"}]},
        {"Name":"a-foreign.priv.example.","Type":"TXT","TTL":60,"ResourceRecords":[{"Value":$OTHER}]},
        {"Name":"manual.priv.example.","Type":"A","TTL":60,"ResourceRecords":[{"Value":"10.0.0.3"}]},
        {"Name":"spf.priv.example.","Type":"TXT","TTL":60,"ResourceRecords":[{"Value":"\"v=spf1\""}]}]}'
    fi ;;
  *"route53 change-resource-record-sets"*)
    printf '%s\n' "\$@" >>"$T/changes" ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$T/bin/aws"
run() { : >"$T/aws-calls"; : >"$T/changes"; PATH="$T/bin:$PATH" bash "$SWEEP" --cluster-name aws-0 --region eu-west-3 "$@" >"$T/out" 2>&1; }

run --zone-name priv.example --owner-id aws-0 --dns-only --apply || f "--dns-only failed: $(cat "$T/out")"
grep -q 'change-resource-record-sets' "$T/aws-calls" || f "--dns-only did not delete the records"
grep -q 'app.priv.example' "$T/changes" && grep -q 'a-app.priv.example' "$T/changes" || f "the cluster's own records were not deleted"
grep -q 'other.example' "$T/changes" && f "a record in ANOTHER zone was deleted"
grep -q 'hosted-zone-id Z1' "$T/aws-calls" && ! grep -q 'hosted-zone-id Z[23]' "$T/aws-calls" || f "zones other than the cluster's private zone were read or changed"
for keep in foreign manual spf; do
  grep -q "${keep}.priv.example" "$T/changes" && f "the record '$keep' (not owned by aws-0) was deleted"
done
grep -q 'priv.example.*NS\|"NS"' "$T/changes" && f "the apex NS was deleted"
! grep -q ' ec2 ' "$T/aws-calls" || f "--dns-only touched EC2"

# Unscoped --dns-only must refuse and touch nothing.
for args in "--dns-only" "--dns-only --zone-name priv.example" "--dns-only --owner-id aws-0"; do
  # shellcheck disable=SC2086
  run $args --apply && f "'$args' must refuse"
  [ ! -s "$T/changes" ] && ! grep -q 'route53' "$T/aws-calls" || f "'$args' reached Route53"
done

P="$ROOT/scripts/ops/aws/eks-prepare-destroy.sh"
line() { grep -n -- "$1" "$P" | grep -v "^[0-9]*:[[:space:]]*#" | head -1 | cut -d: -f1; }
purge="$(line 'sweep-teardown-blockers.sh')"
stop="$(line 'scale .*external-dns')"
gw="$(line 'kubectl delete gateways')"
svc="$(line 'kubectl delete svc -l gateway.networking.k8s.io')"
# shellcheck disable=SC2016  # literal text to find, not an expansion
rt="$(line 'kubectl delete "${route_kind}"')"
grep -v '^[[:space:]]*#' "$P" | grep -q -- '--zone-name' || f "eks-prepare-destroy.sh does not scope the purge to a zone"
grep -v '^[[:space:]]*#' "$P" | grep -q -- '--owner-id' || f "eks-prepare-destroy.sh does not scope the purge to the owner"
# The selector and the owner id are what the HelmRelease sets, not guesses.
H="$ROOT/infrastructure/base/external-dns/helmrelease.yaml"
grep -q 'txtOwnerId: "${cluster_name}"' "$H" || f "external-dns txtOwnerId is no longer the cluster name"
grep -q '^  name: external-dns$' "$H" || f "the external-dns HelmRelease was renamed"
for v in purge stop gw svc rt; do [ -n "${!v}" ] || f "eks-prepare-destroy.sh: no line found for $v"; done
if [ -n "$purge$stop$gw$svc$rt" ]; then
  [ "${stop:-999}" -lt "${purge:-0}" ] || f "external-dns must be stopped before the purge"
  for later in gw svc rt; do
    [ "${purge:-999}" -lt "${!later:-0}" ] || f "the DNS purge (line ${purge:-?}) must precede the $later delete (line ${!later:-?})"
  done
fi

[ "$fails" -eq 0 ] && echo PASS
exit "$fails"
