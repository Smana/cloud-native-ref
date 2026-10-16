#!/usr/bin/env bash
# Lay the pinned ai-native-ref artifact over this checkout (AI split S3, design D4).
#
# The AI platform's manifests left this repository; the cluster applies them from the signed
# OCIRepository in flux/sources/ocirepo-ai-native-ref.yaml. The host gates still need them:
# the render and assert-cloud-shape.py see the whole cluster, and the docs link and name AI paths
# until S4. So this verifies the same digest the cluster pins, with the same identities, and
# copies it into the tree. Every path it writes is .gitignored, and it refuses an artifact that
# would write anywhere else, so a host file is never overwritten.
#
# Idempotent: the previous overlay's files are removed first, so a file dropped upstream does
# not linger. Needs cosign, flux and python3 with PyYAML.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

PIN=flux/sources/ocirepo-ai-native-ref.yaml
OUT=.ai-artifact

die() { echo "ai-overlay: $*" >&2; exit 1; }
for bin in cosign flux python3 rsync; do
  command -v "$bin" >/dev/null || die "$bin not found on PATH (mise install)"
done

# url, digest, issuer, and the subjects as one alternation: cosign takes a single regexp.
mapfile -t pin < <(python3 - "$PIN" <<'EOF'
import sys, yaml
spec = yaml.safe_load(open(sys.argv[1]))["spec"]
ids = spec["verify"]["matchOIDCIdentity"]
issuers = {i["issuer"] for i in ids}
if len(issuers) != 1:
    sys.exit(f"expected one issuer, got {sorted(issuers)}")
print(spec["url"])
print(spec["ref"]["digest"])
print(issuers.pop())
print("|".join(f"(?:{i['subject']})" for i in ids))
EOF
)
[ "${#pin[@]}" -eq 4 ] || die "cannot read the pin from ${PIN}"
url=${pin[0]} digest=${pin[1]} issuer=${pin[2]} subjects=${pin[3]}
[[ $url == oci://* ]] || die "url ${url} is not oci://"
[[ $digest =~ ^sha256:[0-9a-f]{64}$ ]] || die "digest ${digest} is not a sha256 digest"
ref="${url#oci://}@${digest}"

echo "==> Verifying ${ref}"
cosign verify "$ref" \
  --certificate-identity-regexp "$subjects" \
  --certificate-oidc-issuer-regexp "$issuer" >/dev/null

if [ -d "$OUT" ]; then
  echo "==> Removing the previous overlay"
  (cd "$OUT" && find . -type f -print0) | xargs -0 -r rm -f --
  rm -rf "$OUT"
fi

echo "==> Pulling ${url}@${digest}"
mkdir -p "$OUT"
flux pull artifact "${url}@${digest}" -o "$OUT" >/dev/null

# Every file must land on an ignored path: anything else would overwrite a host file.
files=$(cd "$OUT" && find . -type f | sed 's|^\./||' | sort)
[ -n "$files" ] || die "the artifact is empty"
outside=$(comm -23 <(echo "$files") <(echo "$files" | git check-ignore --no-index --stdin | sort) || true)
[ -z "$outside" ] || die "artifact files outside the ignored AI paths (.gitignore):
${outside}"

rsync -a "$OUT/" ./
echo "==> Overlaid $(echo "$files" | wc -l) files from ${digest}"
