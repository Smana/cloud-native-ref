#!/usr/bin/env bash
#
# sweep-lb-orphans.sh (GP-22) with gcloud stubbed on PATH: the dry run deletes
# nothing, --apply deletes rules, then pools, then k8s-* firewalls, each in its
# own scope, and a failed delete is reported and fails the run without stopping
# the rest. Any cluster in the project, or a cluster list that fails, refuses
# the sweep; so does a missing or unknown argument.
#
# --apply runs real deletes if the stub does not resolve, so every invocation
# first proves gcloud is the stub (require_stub).
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
S="$ROOT/scripts/ops/gcp/sweep-lb-orphans.sh"
set -e
T="$(cd "$(mktemp -d)" && pwd -P)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"
cat >"$T/bin/gcloud" <<EOF
#!/usr/bin/env bash
[ "\$1" != --stub-probe ] || { echo stub; exit 0; }
echo "\$*" >>"$T/calls"
case "\$*" in
  *"print-access-token"*) echo fake-token ;;
  *"container clusters list"*)
    [ -z "\${CLUSTERS_FAIL:-}" ] || exit 1
    for c in \${CLUSTERS:-}; do printf '%s\teurope-west4-a\tRUNNING\n' "\$c"; done ;;
  *" delete "*)
    echo "\$*" >>"$T/deletes"
    [ -z "\${DELETE_FAIL:-}" ] || [[ "\$*" != *"\$DELETE_FAIL"* ]] || exit 1 ;;
  *"forwarding-rules list"*) [ -n "\${EMPTY:-}" ] || printf 'a2c53478\teurope-west4\nglobalfr\t\n' ;;
  *"target-pools list"*) [ -n "\${EMPTY:-}" ] || printf 'a2c53478\teurope-west4\n' ;;
  *"firewall-rules list"*) [ -n "\${EMPTY:-}" ] || printf '%s\n' k8s-fw-a2c53478 k8s-a6e2efd9258d71a1-node-http-hc ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$T/bin/gcloud"
set +e
export PATH="$T/bin:$PATH"

require_stub() {
  if [ "$(command -v gcloud)" != "$T/bin/gcloud" ] || [ "$(gcloud --stub-probe 2>/dev/null)" != stub ]; then
    echo "ABORT: gcloud resolves to '$(command -v gcloud)', not the stub; refusing to run the sweep" >&2
    exit 1
  fi
}
args=(--project ogenki-435905 --network vpc-europe-west4-dev --cluster gcp-0)
# Sets out, err and rc, which check's eval strings read; clears the call and
# delete logs first.
# shellcheck disable=SC2034
sweep() {
  : >"$T/calls"; : >"$T/deletes"
  require_stub
  out="$(bash "$S" "$@" 2>"$T/err")"; rc=$?
  err="$(cat "$T/err")"
}
fails=0
check() { if eval "$2"; then echo "  ok   $1"; else echo "  FAIL $1"; fails=1; fi; }
deleted() { grep -c . "$T/deletes"; }

# The dry run.
sweep "${args[@]}"
check "dry run: exit 0" '[ "$rc" -eq 0 ]'
check "dry run: deletes nothing" '[ ! -s "$T/deletes" ]'
check "dry run: names all five objects" '[ "$(grep -c "^\[dry-run\] would delete" <<<"$out")" -eq 5 ]'
check "dry run: names the global rule" 'grep -q "would delete forwarding rule globalfr" <<<"$out"'
for kind in forwarding-rules target-pools; do
  check "the $kind list is scoped to GKE's description marker" \
    'grep "$kind list" "$T/calls" | grep -q "description~kubernetes.io/service-name"'
done
check "the firewall list is scoped to k8s-* on the network" \
  'grep "firewall-rules list" "$T/calls" | grep -q "name~^k8s- AND network~/vpc-europe-west4-dev\\$"'

# --apply.
sweep "${args[@]}" --apply
check "apply: exit 0" '[ "$rc" -eq 0 ]'
check "apply: five deletes" '[ "$(deleted)" -eq 5 ]'
check "apply: every delete is --quiet in the project" '[ "$(grep -c -- "--project ogenki-435905 --quiet$" "$T/deletes")" -eq 5 ]'
check "apply: the regional rule in its region" 'grep -q "forwarding-rules delete a2c53478 --region europe-west4 " "$T/deletes"'
check "apply: the global rule with --global" 'grep -q "forwarding-rules delete globalfr --global " "$T/deletes"'
check "apply: the pool in its region" 'grep -q "target-pools delete a2c53478 --region europe-west4 " "$T/deletes"'
check "apply: both firewall rules" '[ "$(grep -c "firewall-rules delete k8s-" "$T/deletes")" -eq 2 ]'
check "apply: rules, then pools, then firewalls" \
  '[ "$(sed "s/ delete .*//" "$T/deletes" | uniq | tr "\n" " ")" = "compute forwarding-rules compute target-pools compute firewall-rules " ]'
check "apply: reports each deletion" '[ "$(grep -c "^\[deleted\]" <<<"$out")" -eq 5 ]'

# A failed delete.
DELETE_FAIL="target-pools delete" sweep "${args[@]}" --apply
check "failed delete: exit 1" '[ "$rc" -eq 1 ]'
check "failed delete: reported on stderr" 'grep -q "^\[FAILED \] target pool a2c53478" <<<"$err"'
check "failed delete: the firewalls are still swept" '[ "$(grep -c "firewall-rules delete" "$T/deletes")" -eq 2 ]'

# Nothing to sweep.
EMPTY=1 sweep "${args[@]}" --apply
check "empty: exit 0, nothing deleted" '[ "$rc" -eq 0 ] && [ ! -s "$T/deletes" ]'

# The cluster guard: any cluster refuses, as does a list that fails.
refuses() { # $1 = case, then env assignments
  local what="$1"; shift
  : >"$T/calls"; : >"$T/deletes"
  require_stub
  env "$@" bash "$S" "${args[@]}" --apply >/dev/null 2>"$T/err"; rc=$?
  err="$(cat "$T/err")"
  check "$what: exit 3" '[ "$rc" -eq 3 ]'
  check "$what: deletes nothing" '[ ! -s "$T/deletes" ]'
  check "$what: lists no LB object" '! grep -qE "(forwarding-rules|target-pools|firewall-rules) list" "$T/calls"'
}
refuses "the named cluster alive" CLUSTERS=gcp-0
check "  ...naming the live cluster" 'grep -q "^  gcp-0" <<<"$err"'
# The rule and pool lists are project-wide, so another cluster's LBs are in them.
refuses "another cluster alive" CLUSTERS=gcp-1
refuses "a failed cluster list" CLUSTERS_FAIL=1
check "  ...saying it will not sweep blind" 'grep -q "refusing to sweep blind" <<<"$err"'

# Argument guards.
for drop in --project --network --cluster; do
  a=(); set -- "${args[@]}"
  while [ $# -gt 0 ]; do [ "$1" = "$drop" ] || a+=("$1" "$2"); shift 2; done
  sweep "${a[@]}" --apply
  check "without $drop: exit 2, no gcloud call" '[ "$rc" -eq 2 ] && [ ! -s "$T/calls" ]'
done
sweep "${args[@]}" --aply
check "an unknown argument: exit 2, no gcloud call" '[ "$rc" -eq 2 ] && [ ! -s "$T/calls" ]'

check "no token is ever printed" '! grep -q fake-token <<<"$out$err"'
[ "$fails" -eq 0 ] && echo "all checks passed"
exit "$fails"
