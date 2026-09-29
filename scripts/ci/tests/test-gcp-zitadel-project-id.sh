#!/usr/bin/env bash
#
# GCP parity GP-4: a fresh directory has a new project id every build. The sync
# publishes it, and gke/configure reads it, so the standalone configure apply
# that runs after stage 3 cannot put the committed id back.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
C="$ROOT/opentofu/gcp/gke/configure"
fails=0
f() { echo "FAIL $*"; fails=$((fails + 1)); }
grep -Eq '^[[:space:]]*zitadel_project_id[[:space:]]*=[[:space:]]*local\.zitadel_project_id[[:space:]]*$' "$C/kubernetes.tf" || f "the ConfigMap does not publish local.zitadel_project_id"
grep -q 'data "google_secret_manager_secrets" "zitadel_project"' "$C/data.tf" || f "configure does not list zitadel-project-id before reading it"
grep -q 'data "google_secret_manager_secret_version" "zitadel_project"' "$C/data.tf" || f "configure does not read zitadel-project-id"
grep -Eq 'zitadel_project_id[[:space:]]*=.*var\.zitadel_project_id' "$C/locals.tf" || f "no fallback to the committed id"
S="$ROOT/scripts/provision/zitadel-oidc-clients.sh"
grep -q 'store_write zitadel-project-id' "$S" || f "the sync never publishes zitadel-project-id"

# The gate and the compare-before-write, on the function that ships (review M-1,
# M-5). A failed publish accumulating in cmd_sync (M-3) is tested in
# test-zitadel-oidc-clients-openbao.sh, which runs cmd_sync.
body="$(sed -n '/^publish_project_id() {/,/^}/p' "$S")"
[ -n "$body" ] || { f "could not extract publish_project_id()"; exit 1; }
eval "$body"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
STORED="" WRITE_RC=0
store_read()  { [ -n "$STORED" ] || return 1; printf '%s' "$STORED"; }
store_write() { printf '%s %s\n' "$1" "$(cat)" >> "$T/writes"; return "$WRITE_RC"; }
# cloud idp apply project_id stored -> "<rc> <writes>"
run() {
    : > "$T/writes"
    local rc=0
    # shellcheck disable=SC2034  # read by the eval'd publish_project_id
    CLOUD="$1" IDP_CLOUD="$2" APPLY="$3" STORED="$5"
    publish_project_id "$4" >/dev/null 2>&1 || rc=$?
    echo "$rc $(wc -l < "$T/writes")"
}
want() { [ "$2" = "$3" ] || f "$1: expected '$2' got '$3'"; }
want "hosting, changed: one write"      "0 1" "$(run gcp gcp true new-id '{"project_id":"old-id"}')"
grep -qx 'zitadel-project-id {"project_id":"new-id"}' "$T/writes" || f "payload: $(cat "$T/writes")"
want "hosting, absent: one write"       "0 1" "$(run gcp gcp true new-id '')"
want "hosting, unchanged: no write"     "0 0" "$(run gcp gcp true same-id '{"project_id":"same-id"}')"
want "dry run: no write"                "0 0" "$(run gcp gcp false new-id '')"
want "consuming (idp aws): no write"    "0 0" "$(run gcp aws true new-id '')"
want "aws hosting: no write"            "0 0" "$(run aws aws true new-id '')"
want "DRYRUN-PROJECT sentinel: no write" "0 0" "$(run gcp gcp true DRYRUN-PROJECT '')"
WRITE_RC=1
want "failed write: non-zero"           "1 1" "$(run gcp gcp true new-id '')"

[ "$fails" -eq 0 ] || exit 1
echo PASS
