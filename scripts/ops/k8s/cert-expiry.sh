#!/usr/bin/env bash
#
# Report the cert-manager Certificates expiring within N days. READ-ONLY.
#
# One "<namespace>/<name> <notAfter> <days left>" line per Certificate whose
# spec.notAfter falls within the window (default 30 days, --days N to widen
# it), soonest first. An already-expired Certificate is inside every window
# and prints with a negative days-left; a Certificate with no spec.notAfter
# yet -- just created, still issuing -- has no expiry to report and is
# skipped.
#
# It is a report, not a gate: exit 0 whatever the count, and exit 0 with a
# warning on stderr when the cluster is unreachable or cert-manager is not
# installed, so it never breaks whatever runs it.
#
# Usage:
#   scripts/ops/k8s/cert-expiry.sh [--days N]

set -uo pipefail

usage() { echo "usage: scripts/ops/k8s/cert-expiry.sh [--days N]" >&2; }

DAYS=30
while [ $# -gt 0 ]; do
    case "$1" in
        --days)
            [ $# -ge 2 ] || { echo "--days needs a value" >&2; usage; exit 2; }
            DAYS="$2"; shift 2 ;;
        --days=*) DAYS="${1#--days=}"; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown argument: $1" >&2; usage; exit 2 ;;
    esac
done

case "$DAYS" in
    ''|*[!0-9]*) echo "--days wants a non-negative integer, got: $DAYS" >&2; exit 2 ;;
esac

raw="$(mktemp)"
trap 'rm -f "$raw"' EXIT

if ! kubectl get certificates.cert-manager.io --all-namespaces --request-timeout=20s \
        -o json >"$raw" 2>/dev/null; then
    echo "could not list Certificates (cluster unreachable or cert-manager not installed)" >&2
    exit 0
fi

jq -r --argjson now "$(date -u +%s)" --argjson window "$DAYS" '
    [ .items[]
      | select(.spec.notAfter != null)
      | (.spec.notAfter | fromdateiso8601) as $exp
      | (($exp - $now) / 86400 | floor) as $days
      | select($days <= $window)
      | {line: "\(.metadata.namespace)/\(.metadata.name) \(.spec.notAfter) \($days)",
         days: $days}
    ]
    | sort_by(.days)[]
    | .line
' "$raw" || echo "could not parse the Certificate list as JSON" >&2

exit 0
