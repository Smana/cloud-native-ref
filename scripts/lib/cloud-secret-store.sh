# shellcheck shell=bash
#
# Read and write secrets in the hosting cloud's store. Both clouds, one copy.
#
# Extracted from zitadel-oidc-clients.sh, zitadel-idp.sh and harbor-oidc.sh,
# which each carried their own. A fourth copy was about to be written for the
# PAT resolver, and this repository already knows where that ends -- the GCP
# opt-in gate became fifteen hand-written copies with four scripts missing it.
#
# Reads CLOUD, REGION and GCP_PROJECT from the caller. store_write also needs
# jq on PATH.

# shellcheck source=scripts/lib/gcloud-adc.sh
. "$(dirname "${BASH_SOURCE[0]}")/gcloud-adc.sh"

store_exists() {
    case "$CLOUD" in
        aws) aws secretsmanager describe-secret ${REGION:+--region "$REGION"} \
                 --secret-id "$1" >/dev/null 2>&1 ;;
        gcp) gcp_gcloud secrets describe "$1" ${GCP_PROJECT:+--project "$GCP_PROJECT"} \
                 >/dev/null 2>&1 ;;
    esac
}

store_read() {
    case "$CLOUD" in
        aws) aws secretsmanager get-secret-value \
                 ${REGION:+--region "$REGION"} \
                 --secret-id "$1" --query SecretString --output text 2>/dev/null ;;
        gcp) gcp_gcloud secrets versions access latest \
                 ${GCP_PROJECT:+--project "$GCP_PROJECT"} \
                 --secret="$1" 2>/dev/null ;;
    esac
}

# Value arrives on STDIN so it never appears in a process listing.
#
# Copied from zitadel-oidc-clients.sh with the provenance strings parameterised.
# Three properties here are load-bearing and must not be "simplified":
#
#   * `umask 077 && mktemp` sets the mode AT CREATION. Creating then chmod-ing
#     leaves a window in which a file holding a secret is world-readable.
#   * the RETURN trap fires on EVERY exit path, and shred overwrites the bytes.
#     A trailing `rm -f` runs only when nothing failed.
#   * AWS goes through jq into --cli-input-json rather than --secret-string,
#     which is what lets the payload be an arbitrary JSON document.
store_write() {
    local name="$1" payload
    payload=$(umask 077 && mktemp -t cloud-secret.XXXXXX)
    # shellcheck disable=SC2064
    trap "shred -u '${payload}' 2>/dev/null || rm -f '${payload}'" RETURN
    cat > "$payload"

    case "$CLOUD" in
        aws)
            local body
            body=$(umask 077 && mktemp -t cloud-secret-body.XXXXXX)
            if store_exists "$name"; then
                jq --arg id "$name" '{SecretId: $id, SecretString: (. | tostring)}' \
                    < "$payload" > "$body"
                aws secretsmanager put-secret-value ${REGION:+--region "$REGION"} \
                    --cli-input-json "file://${body}" >/dev/null
            else
                jq --arg n "$name" --arg d "${STORE_WRITE_DESCRIPTION:-Written by cloud-secret-store.sh}" \
                   '{Name: $n, Description: $d, SecretString: (. | tostring)}' \
                    < "$payload" > "$body"
                aws secretsmanager create-secret ${REGION:+--region "$REGION"} \
                    --cli-input-json "file://${body}" >/dev/null
            fi
            shred -u "$body" 2>/dev/null || rm -f "$body"
            ;;
        gcp)
            store_exists "$name" || gcp_gcloud secrets create "$name" \
                ${GCP_PROJECT:+--project "$GCP_PROJECT"} \
                --replication-policy=automatic \
                --labels=managed-by="${STORE_WRITE_LABEL:-cloud-secret-store}" >/dev/null
            gcp_gcloud secrets versions add "$name" \
                ${GCP_PROJECT:+--project "$GCP_PROJECT"} \
                --data-file="$payload" >/dev/null
            ;;
    esac
}
