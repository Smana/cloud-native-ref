#!/usr/bin/env bash
#
# List the Flux Kustomizations that are not Ready. READ-ONLY.
#
# A Kustomization that fails to reconcile does not fail anything by itself: the
# reconcile errors land in the object's Ready condition, and everything around
# it keeps reporting green. `kubectl get kustomizations -A` does show an READY
# column, but a long list scrolls it away and nothing aggregates it.
#
# This prints one "<namespace>/<name>: <message>" line per Kustomization whose
# Ready condition is not True — including one that has no Ready condition at
# all yet (just created, or the status never arrived).
#
# It is a report, not a gate: exit 0 whatever the count, and exit 0 with a
# warning on stderr when the cluster is unreachable or the Flux CRD is absent,
# so it never breaks whatever runs it.
#
# Usage:
#   scripts/ops/k8s/flux-not-ready.sh

set -uo pipefail

raw="$(mktemp)"
trap 'rm -f "$raw"' EXIT

if ! kubectl get kustomizations.kustomize.toolkit.fluxcd.io \
        --all-namespaces --request-timeout=20s -o json >"$raw" 2>/dev/null; then
    echo "could not list Kustomizations (cluster unreachable or Flux not installed)" >&2
    exit 0
fi

jq -r '
    def ready_msg:
        if . == null then "no Ready condition reported"
        else (.message // .reason // "not Ready")
        end;
    .items[]
    | (.status.conditions // []
        | map(select(.type == "Ready"))
        | last) as $ready
    | select($ready == null or $ready.status != "True")
    | "\(.metadata.namespace)/\(.metadata.name): \($ready | ready_msg)"
' "$raw" || {
    echo "could not parse the Kustomization list as JSON" >&2
    exit 0
}

exit 0
