#!/usr/bin/env bash
# Store I/O against stub CLIs, so no cloud call is made.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
STUB="$(mktemp -d)"; trap 'rm -rf "$STUB"' EXIT
fail=0
check() { # label expected actual
    if [ "$2" = "$3" ]; then printf '  ok   %s\n' "$1"
    else printf '  FAIL %s: expected %q got %q\n' "$1" "$2" "$3"; fail=1; fi
}

cat > "$STUB/aws" <<'EOF'
#!/usr/bin/env bash
for a in "$@"; do [ "$a" = "get-secret-value" ] && { echo '{"token":"aws-secret"}'; exit 0; }; done
for a in "$@"; do [ "$a" = "describe-secret" ] && exit 0; done
exit 0
EOF
cat > "$STUB/gcloud" <<'EOF'
#!/usr/bin/env bash
for a in "$@"; do [ "$a" = "access" ] && { echo '{"token":"gcp-secret"}'; exit 0; }; done
exit 0
EOF
chmod +x "$STUB/aws" "$STUB/gcloud"
PATH="$STUB:$PATH"

# shellcheck source=scripts/lib/cloud-secret-store.sh
. "$HERE/lib/cloud-secret-store.sh"

CLOUD=aws REGION=eu-west-3 GCP_PROJECT=""
check "aws read"    '{"token":"aws-secret"}' "$(store_read any)"
store_exists any && r=yes || r=no
check "aws exists"  yes "$r"

CLOUD=gcp REGION="" GCP_PROJECT=proj
check "gcp read"    '{"token":"gcp-secret"}' "$(store_read any)"

exit $fail
