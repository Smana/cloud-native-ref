#!/usr/bin/env bash
#
# memory gke_lb_orphans_block_vpc_delete: a deleted GKE cluster leaves a target
# pool and k8s-* firewall rules behind, and the firewall rules block the VPC
# delete. teardown.sh --verify-only must report both, and fail while they exist.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"
cat >"$T/bin/gcloud" <<EOF
#!/usr/bin/env bash
case "\$*" in
  "projects describe"*) exit 0 ;;
  *"print-access-token"*) echo fake-token ;;
  *"container clusters list"*) printf '%s' "\${CLUSTERS:-}" ;;
  *" delete "*) echo "\$*" >>"$T/deletes" ;;
  *"forwarding-rules list"*) echo "a2c53478 europe-west4" ;;
  *"target-pools list"*) echo "a2c53478 europe-west4" ;;
  *"firewall-rules list"*) printf '%s\n' k8s-fw-a2c53478 k8s-a6e2efd9258d71a1-node-http-hc ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$T/bin/gcloud"
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
: >"$T/deletes"
PATH="$T/bin:$PATH" bash "$S" "${args[@]}" --apply >/dev/null 2>&1 || f "the sweep failed"
[ "$(wc -l <"$T/deletes")" -eq 4 ] || f "expected 4 deletes (rule, pool, 2 firewalls), got: $(cat "$T/deletes")"
grep -q 'forwarding-rules delete a2c53478 --region europe-west4' "$T/deletes" || f "the forwarding rule was not deleted in its region"
: >"$T/deletes"
CLUSTERS=gcp-0 PATH="$T/bin:$PATH" bash "$S" "${args[@]}" --apply >/dev/null 2>&1; rc=$?
[ "$rc" -eq 3 ] || f "a live cluster must refuse with exit 3, got $rc"
[ ! -s "$T/deletes" ] || f "a live cluster's LBs were deleted"

[ "$fails" -eq 0 ] && echo PASS
exit "$fails"
