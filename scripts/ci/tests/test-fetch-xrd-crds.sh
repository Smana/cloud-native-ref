#!/usr/bin/env bash
#
# fetch-xrd-crds.sh (SP2 ruling P40, review B2): a release pin needs no artifact, and a
# pre-release pin pulls its PR's OCI artifact. flux is stubbed on PATH.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUBJECT="$HERE/../fetch-xrd-crds.sh"
fails=0
fail() { printf 'FAIL  %s\n' "$*" >&2; fails=$((fails + 1)); }

d="$(mktemp -d)"
mkdir -p "$d/bin" "$d/out"
cat >"$d/bin/flux" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"$FLUX_CALLS"
out="${*: -1}"
[ -n "${FLUX_EMPTY:-}" ] || printf 'apiVersion: apiextensions.k8s.io/v1\nkind: CustomResourceDefinition\n' >"$out/xrd-crds.yaml"
EOF
chmod +x "$d/bin/flux"
pin() { printf '    package: ghcr.io/smana/crossplane-configuration-aws:%s\n' "$1" >"$d/pkgs.yaml"; }
run() { PATH="$d/bin:$PATH" FLUX_CALLS="$d/calls" XPKG_SOURCE="$d/pkgs.yaml" XRD_CRDS_DIR="$d/out" bash "$SUBJECT"; }

pin v0.8.0
[ -z "$(run)" ] || fail "a release pin prints nothing"
[ ! -e "$d/calls" ] || fail "a release pin pulls nothing"

pin v0.7.2-pr35.abcdef1
got="$(run)" || fail "a pre-release pin succeeds"
[ "$got" = "$d/out/xrd-crds.yaml" ] || fail "it prints the file, got '$got'"
grep -q 'pull artifact oci://ghcr.io/smana/crossplane-configuration-xrd-crds:v0.7.2-pr35.abcdef1 --output' "$d/calls" \
  || fail "it pulls the pinned version's artifact"

rm -f "$d/out/xrd-crds.yaml"
FLUX_EMPTY=1 run >/dev/null 2>&1 && fail "an artifact without the file fails"

[ "$fails" -eq 0 ] || exit 1
echo PASS
