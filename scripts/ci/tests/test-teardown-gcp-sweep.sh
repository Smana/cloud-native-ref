#!/usr/bin/env bash
#
# memory gke_lb_orphans_block_vpc_delete: a deleted GKE cluster leaves a target
# pool and k8s-* firewall rules behind, and the firewall rules block the VPC
# delete. teardown.sh --verify-only must report both, and fail while they exist.
# The sweep lists LBs project-wide, so ANY live cluster must block it, and the
# destroy is retried only while the network still stands (GP-22).
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"
cat >"$T/bin/gcloud" <<EOF
#!/usr/bin/env bash
echo "\$*" >>"$T/calls"
case "\$*" in
  "projects describe"*) exit 0 ;;
  *"print-access-token"*) echo fake-token ;;
  *"container clusters list"*)
    [ -z "\${CLUSTERS_FAIL:-}" ] || exit 1
    # Honour a name filter, as gcloud does: a guard that filters on one name
    # must not see the other clusters.
    want="\$(printf '%s\n' "\$@" | sed -n 's/^--filter=name=//p')"
    for c in \${CLUSTERS:-}; do
      [ -z "\$want" ] || [ "\$c" = "\$want" ] || continue
      printf '%s\teurope-west4-a\tRUNNING\n' "\$c"
    done ;;
  *"networks describe"*) [ -n "\${NETWORK_UP:-}" ] || exit 1 ;;
  *" delete "*) echo "\$*" >>"$T/deletes" ;;
  *"forwarding-rules list"*) [ -n "\${EMPTY:-}" ] || echo "a2c53478 europe-west4" ;;
  *"target-pools list"*) [ -n "\${EMPTY:-}" ] || echo "a2c53478 europe-west4" ;;
  *"firewall-rules list"*) [ -n "\${EMPTY:-}" ] || printf '%s\n' k8s-fw-a2c53478 k8s-a6e2efd9258d71a1-node-http-hc ;;
  *) exit 0 ;;
esac
EOF
cat >"$T/bin/terramate" <<EOF
#!/usr/bin/env bash
echo "\$*" >>"$T/destroys"
EOF
chmod +x "$T/bin/gcloud" "$T/bin/terramate"
fails=0
f() { echo "FAIL $*"; fails=1; }

# The report (--verify-only).
out="$(TM_CLOUD=gcp PATH="$T/bin:$PATH" bash "$ROOT/scripts/ops/teardown/teardown.sh" --verify-only 2>&1)"; rc=$?
grep -q 'Target pools' <<<"$out" || f "no Target pools row"
grep -q 'k8s-\* firewall rules' <<<"$out" || f "no k8s-* firewall rules row"
[ "$rc" -ne 0 ] || f "leftovers must fail the verify"

# The sweep (GP-22): dry-run deletes nothing, --apply deletes the four, a live cluster blocks it.
S="$ROOT/scripts/ops/gcp/sweep-lb-orphans.sh"
args=(--project ogenki-435905 --network vpc-europe-west4-dev --cluster gcp-0)
[ -f "$S" ] || f "no $S"
: >"$T/deletes"
PATH="$T/bin:$PATH" bash "$S" "${args[@]}" >/dev/null 2>&1 || f "the dry run failed"
[ ! -s "$T/deletes" ] || f "the dry run deleted something"
: >"$T/deletes"; : >"$T/calls"
PATH="$T/bin:$PATH" bash "$S" "${args[@]}" --apply >/dev/null 2>&1 || f "the sweep failed"
[ "$(wc -l <"$T/deletes")" -eq 4 ] || f "expected 4 deletes (rule, pool, 2 firewalls), got: $(cat "$T/deletes")"
grep -q 'forwarding-rules delete a2c53478 --region europe-west4' "$T/deletes" || f "the forwarding rule was not deleted in its region"
# The filters are the whole scoping: without them the sweep deletes by project.
grep 'firewall-rules list' "$T/calls" | grep -q 'network~/vpc-europe-west4-dev\$' \
  || f "the firewall list is not scoped to the network"
for kind in forwarding-rules target-pools; do
  grep "$kind list" "$T/calls" | grep -q 'description~kubernetes.io/service-name' \
    || f "the $kind list is not scoped to GKE's description marker"
done

refuses() { # $1 = case, then env assignments
  local what="$1" rc; shift
  : >"$T/deletes"
  env "$@" PATH="$T/bin:$PATH" bash "$S" "${args[@]}" --apply >/dev/null 2>&1; rc=$?
  [ "$rc" -eq 3 ] || f "$what must refuse with exit 3, got $rc"
  [ ! -s "$T/deletes" ] || f "$what, yet LBs were deleted"
}
refuses "the named cluster alive" CLUSTERS=gcp-0
# The rule and pool lists are project-wide, so another cluster's LBs are in them.
refuses "another cluster alive" CLUSTERS=gcp-1
refuses "a failed cluster list" CLUSTERS_FAIL=1

# teardown (GP-22): the destroy is retried only while the network stands.
destroys() { # $1 = expected terramate runs, $2 = case, then env assignments
  local want="$1" what="$2"; shift 2
  : >"$T/destroys"
  env "$@" TM_CLOUD=gcp TM_DESTROY_CONFIRMED=true PATH="$T/bin:$PATH" \
    bash "$ROOT/scripts/ops/teardown/teardown.sh" >/dev/null 2>&1
  [ "$(wc -l <"$T/destroys")" -eq "$want" ] \
    || f "$what: expected $want destroy run(s), got $(wc -l <"$T/destroys")"
}
destroys 1 "a clean teardown with the network gone" EMPTY=1
destroys 2 "a teardown with the network still standing" NETWORK_UP=1

[ "$fails" -eq 0 ] && echo PASS
exit "$fails"
