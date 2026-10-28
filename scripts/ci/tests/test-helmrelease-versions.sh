#!/usr/bin/env bash
#
# helmrelease_versions (scripts/ops/k8s/lib-helmrelease-versions.sh) turns the
# JSON of `kubectl get helmreleases -n <ns> -o json` on stdin into one
# "<name>@<chart version>" line per item, sorted by name: the reusable listing
# that ops scripts otherwise re-inline as jq every time they need it.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
LIB="$REPO_ROOT/scripts/ops/k8s/lib-helmrelease-versions.sh"
fails=0
ok() { echo "  ok   $1"; }
fail() { echo "  FAIL $1"; fails=1; }

[ -f "$LIB" ] || { echo "FAIL $LIB does not exist"; exit 1; }
# shellcheck source=scripts/ops/k8s/lib-helmrelease-versions.sh
. "$LIB" || { echo "FAIL cannot source $LIB"; exit 1; }
command -v helmrelease_versions >/dev/null 2>&1 \
  || { echo "FAIL sourcing $LIB does not define helmrelease_versions"; exit 1; }

# Two HelmReleases, deliberately named out of order and with versions that do
# not sort the same way as the names, so both the name sort and the
# name@version shape are pinned by the diff.
two_items='{"apiVersion":"helm.toolkit.fluxcd.io/v2","kind":"HelmReleaseList",'
two_items="$two_items"'"items":[
  {"metadata":{"name":"webapp"},"spec":{"chart":{"spec":{"chart":"podinfo","version":"9.8.7"}}}},
  {"metadata":{"name":"alertmanager"},"spec":{"chart":{"spec":{"chart":"kube-prometheus-stack","version":"1.2.3"}}}}
]}'
expected='alertmanager@1.2.3
webapp@9.8.7'
got="$(printf '%s' "$two_items" | helmrelease_versions)"
if [ "$got" = "$expected" ]; then
  ok "two items print the two name@version lines, sorted by name"
else
  fail "two items: want '$expected' got '$got'"
fi

# Exact-output diff, not just string equality on the whole stream: leading or
# trailing blank lines would otherwise slip through the comparison above.
if printf '%s' "$two_items" | helmrelease_versions \
     | diff -u <(printf '%s\n' "$expected") - >/dev/null; then
  ok "two-item output is exactly the two expected lines, nothing more"
else
  fail "two-item output is not exactly the two expected lines"
fi

# An empty List: nothing on stdout, and the function still succeeds.
empty_list='{"apiVersion":"helm.toolkit.fluxcd.io/v2","kind":"HelmReleaseList","items":[]}'
empty_out="$(printf '%s' "$empty_list" | helmrelease_versions)"
empty_rc=$?
if [ -z "$empty_out" ] && [ "$empty_rc" -eq 0 ]; then
  ok "empty list prints nothing and returns 0"
else
  fail "empty list: want empty output and rc 0, got '$empty_out' and rc $empty_rc"
fi

[ "$fails" -eq 0 ] && echo "all checks passed"
exit "$fails"
