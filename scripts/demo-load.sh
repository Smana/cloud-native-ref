#!/usr/bin/env bash
# Run an image-gallery load-generator scenario in-cluster, from the suspended
# image-gallery-loadgen CronJob's template. The Job exports its traces and
# metrics like the app does, so each trace starts at the load generator.
#
#   scripts/demo-load.sh <browse|upload|mixed|steady|incident> [duration] [rate]
#   scripts/demo-load.sh incident          # ~10 min scripted incident; resets the demo controls on exit
#   scripts/demo-load.sh mixed 15m 25      # the soak: the 25 req/s cap for 15 minutes
set -euo pipefail

usage() { sed -n '2,8p' "$0"; }

scenario="${1:-}"
duration="${2:-15m}"
rate="${3:-10}"
case "$scenario" in
  browse | upload | mixed | steady | incident) ;;
  *) usage; exit 2 ;;
esac

ns=apps
name="image-gallery-loadgen-${scenario}-$(date +%s)"
kubectl create job "$name" -n "$ns" --from=cronjob/image-gallery-loadgen --dry-run=client -o json |
  jq --arg s "$scenario" --arg d "$duration" --arg r "$rate" '
    .spec.template.spec.containers[0].args = [
      "loadgen", "--target", "http://xplane-image-gallery.apps.svc.cluster.local:8080",
      "--scenario", $s, "--duration", $d, "--rate", $r, "--concurrency", "10"]' |
  kubectl apply -f -
echo "Started job/$name in $ns. Follow it with: kubectl logs -n $ns -f job/$name"
