#!/usr/bin/env bash
#
# Report the Flux Kustomizations and HelmReleases that are not Ready. READ-ONLY.
#
# flux-not-ready.sh covers the Kustomizations only, and on gcp-0 the
# HelmReleases are just as load-bearing: a chart that fails to reconcile looks
# identical from the outside — the error lands in the object's Ready condition
# and everything around it keeps reporting green.
#
# This prints one "<kind> <namespace>/<name>: <reason>" line per Kustomization
# or HelmRelease whose Ready condition is not True — including one with no
# Ready condition at all yet (just created, or the status never arrived).
#
# It is a report, not a gate: exit 0 whatever the count, and exit 0 with a
# warning on stderr when the cluster is unreachable or the Flux CRDs are
# absent, so it never breaks whatever runs it.
#
# Usage:
#   scripts/ops/k8s/flux-health.sh

set -uo pipefail

raw="$(mktemp)"
trap 'rm -f "$raw"' EXIT

# One list call per kind, not a kubectl get across both: the kinds live in
# different API groups, so no single resource string selects them both.
report() {
    local kind="$1" resource="$2"

    if ! kubectl get "$resource" --all-namespaces --request-timeout=20s \
            -o json >"$raw" 2>/dev/null; then
        echo "could not list ${kind}s (cluster unreachable or Flux not installed)" >&2
        return 0
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
        | "'"${kind}"' \(.metadata.namespace)/\(.metadata.name): \($ready | ready_msg)"
    ' "$raw" || echo "could not parse the ${kind} list as JSON" >&2
    return 0
}

report Kustomization kustomizations.kustomize.toolkit.fluxcd.io
report HelmRelease helmreleases.helm.toolkit.fluxcd.io

exit 0
