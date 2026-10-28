#!/usr/bin/env bash
# shellcheck shell=bash
#
# Turn the JSON of `kubectl get helmreleases -n <ns> -o json` on stdin into one
# "<name>@<chart version>" line per item, sorted by name: the listing ops
# scripts otherwise re-inline as jq each time they need it.
#
# Sourced, never run: no shebang-guard, no main. It defines one function and
# depends only on jq being on PATH at call time.

# Chart version means the chart ref the HelmRelease asks for
# (.spec.chart.spec.version), not .status.lastAppliedChartVersion: the listing
# is "what should be deployed", which stays meaningful on a first install and
# on a reconcile that has not converged yet.
helmrelease_versions() {
    LC_ALL=C jq -r '.items | sort_by(.metadata.name) | .[] | "\(.metadata.name)@\(.spec.chart.spec.version)"'
}
