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
#
# --from-git lays the same paths from the pin's tag, cloned from GitHub and NOT verified: an agent's
# sandbox reaches neither ghcr.io nor Sigstore (agent-platform v3 feature 3, the checks in the
# sandbox). It is a feedback loop for the sandbox only, and refuses to run under CI=true: CI always
# verifies the signed artifact. Needs git, python3 with PyYAML and rsync.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

PIN=flux/sources/ocirepo-ai-native-ref.yaml
OUT=.ai-artifact
# What ai-native-ref's scripts/ci/push-artifact.sh puts in the artifact, from the repository the
# signer identity names. tests/test-ai-overlay-from-git.sh compares the two on the pinned tag.
SOURCE=https://github.com/Smana/ai-native-ref
ARTIFACT_DIRS="clusters infrastructure security tooling observability apps flux"

die() { echo "ai-overlay: $*" >&2; exit 1; }
from_git=false
case "${1:-}" in
  "") ;;
  --from-git) from_git=true ;;
  *) die "usage: $0 [--from-git]" ;;
esac
if $from_git && [ "${CI:-}" = true ]; then
  die "--from-git lays an unverified tree; CI verifies the signed artifact (run it without --from-git)"
fi
tools="cosign flux python3 rsync"
if $from_git; then tools="git python3 rsync"; fi
for bin in $tools; do
  command -v "$bin" >/dev/null || die "$bin not found on PATH (mise install)"
done

# url, digest, issuer, and the subjects as one alternation: cosign takes a single regexp.
mapfile -t pin < <(python3 - "$PIN" <<'EOF'
import sys, yaml
spec = yaml.safe_load(open(sys.argv[1]))["spec"]
ids = spec["verify"]["matchOIDCIdentity"]
if len(ids) != 1:
    # source-controller's cosign keyless refuses more ("multiple identities are not supported").
    sys.exit(f"expected one matchOIDCIdentity entry, got {len(ids)}: put the signers in one subject regex")
issuers = {i["issuer"] for i in ids}
if len(issuers) != 1:
    sys.exit(f"expected one issuer, got {sorted(issuers)}")
print(spec["url"])
print(spec["ref"]["digest"])
print(issuers.pop())
print("|".join(f"(?:{i['subject']})" for i in ids))
print(spec["ref"].get("tag", ""))
EOF
)
[ "${#pin[@]}" -ge 4 ] || die "cannot read the pin from ${PIN}"
url=${pin[0]} digest=${pin[1]} issuer=${pin[2]} subjects=${pin[3]} tag=${pin[4]:-}
[[ $url == oci://* ]] || die "url ${url} is not oci://"
[[ $digest =~ ^sha256:[0-9a-f]{64}$ ]] || die "digest ${digest} is not a sha256 digest"
ref="${url#oci://}@${digest}"

if $from_git; then
  # A release tag only: a pre-release pin (v<x>-pr<N>.g<sha8>) is an OCI tag with no git tag.
  [[ $tag =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "--from-git needs a release tag in ${PIN}, got '${tag}'"
else
  echo "==> Verifying ${ref}"
  cosign verify "$ref" \
    --certificate-identity-regexp "$subjects" \
    --certificate-oidc-issuer-regexp "$issuer" >/dev/null
fi

if [ -d "$OUT" ]; then
  echo "==> Removing the previous overlay"
  (cd "$OUT" && find . -type f -print0) | xargs -0 -r rm -f --
  rm -rf "$OUT"
fi

mkdir -p "$OUT"
if $from_git; then
  echo "==> Cloning ${SOURCE} at ${tag} (unverified)"
  src="$(mktemp -d)"
  trap 'rm -rf "$src"' EXIT
  git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$tag" "$SOURCE" "$src"
  for d in $ARTIFACT_DIRS; do
    if [ -d "$src/$d" ]; then cp -a "$src/$d" "$OUT/"; fi
  done
  from="${tag} (git, unverified)"
else
  echo "==> Pulling ${url}@${digest}"
  flux pull artifact "${url}@${digest}" -o "$OUT" >/dev/null
  from="$digest"
fi

# Every file must land on an ignored path: anything else would overwrite a host file.
files=$(cd "$OUT" && find . -type f | sed 's|^\./||' | sort)
[ -n "$files" ] || die "the artifact is empty"
outside=$(comm -23 <(echo "$files") <(echo "$files" | git check-ignore --no-index --stdin | sort) || true)
[ -z "$outside" ] || die "artifact files outside the ignored AI paths (.gitignore):
${outside}"

rsync -a "$OUT/" ./
echo "==> Overlaid $(echo "$files" | wc -l) files from ${from}"
