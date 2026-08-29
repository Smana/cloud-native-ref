# shellcheck shell=bash
#
# Read and write secrets in the hosting cloud's store. Both clouds, one copy.
#
# Extracted from zitadel-oidc-clients.sh, zitadel-idp.sh and harbor-oidc.sh,
# which each carried their own. A fourth copy was about to be written for the
# PAT resolver, and this repository already knows where that ends -- the GCP
# opt-in gate became fifteen hand-written copies with four scripts missing it.
#
# Reads CLOUD, REGION and GCP_PROJECT from the caller.

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
store_write() {
    local name="$1" tmp
    tmp="$(mktemp)"; chmod 600 "$tmp"
    cat > "$tmp"
    case "$CLOUD" in
        aws)
            if store_exists "$name"; then
                aws secretsmanager put-secret-value ${REGION:+--region "$REGION"} \
                    --secret-id "$name" --secret-string "file://$tmp" >/dev/null
            else
                aws secretsmanager create-secret ${REGION:+--region "$REGION"} \
                    --name "$name" --secret-string "file://$tmp" >/dev/null
            fi ;;
        gcp)
            if store_exists "$name"; then
                gcp_gcloud secrets versions add "$name" \
                    ${GCP_PROJECT:+--project "$GCP_PROJECT"} --data-file="$tmp" >/dev/null
            else
                gcp_gcloud secrets create "$name" \
                    ${GCP_PROJECT:+--project "$GCP_PROJECT"} \
                    --replication-policy=automatic --data-file="$tmp" >/dev/null
            fi ;;
    esac
    rm -f "$tmp"
}
