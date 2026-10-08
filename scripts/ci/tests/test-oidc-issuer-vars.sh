#!/usr/bin/env bash
#
# GCP parity GP-12: the agents' issuer, JWKS URI and JWKS host are per-cloud
# variables. EKS serves <issuer>/keys at oidc.eks.<region>.amazonaws.com; GKE serves
# <issuer>/jwks at container.googleapis.com. A same-named ${region} renders a host
# that does not exist on gcp-0 while the bundle stays clean
# (memory flux_render_fixture_cross_cloud_blindspot).
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
fails=0
f() { echo "FAIL $*"; fails=$((fails + 1)); }
hits="$(grep -rnE 'oidc_issuer_url\}/keys|oidc\.eks\.\$\{region\}' "$ROOT/infrastructure" "$ROOT/security" --include=*.yaml)"
[ -z "$hits" ] || f "AWS-shaped issuer in base manifests:"$'\n'"$hits"
for cm in opentofu/aws/eks/configure/kubernetes.tf opentofu/gcp/gke/configure/kubernetes.tf; do
  for k in oidc_issuer_url oidc_jwks_uri oidc_jwks_host; do
    grep -Eq "^[[:space:]]*${k}[[:space:]]*=" "$ROOT/$cm" || f "$cm defines no $k"
  done
done
grep -q '"/jwks"\|}/jwks"' "$ROOT/opentofu/gcp/gke/configure/kubernetes.tf" || f "gcp's JWKS URI is not <issuer>/jwks"
python3 - "$ROOT/scripts/ci/flux-schema/render-bundle.py" <<'PY' || f "render-bundle.py has no GKE-shaped gcp-0 fixtures"
import re, sys
t = open(sys.argv[1]).read()
g = t[t.index('"gcp-0": {'):]
ok = all(k in g[:2000] for k in ('"oidc_issuer_url": "https://container.googleapis.com/', '"oidc_jwks_host": "container.googleapis.com"', '/jwks"'))
sys.exit(0 if ok else 1)
PY
[ "$fails" -eq 0 ] || exit 1
echo PASS
