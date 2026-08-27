#!/usr/bin/env bash
#
# Register this cluster's OIDC clients in ZITADEL, and store the credentials.
#
# WHY THIS EXISTS
#
# Every SSO consumer on the platform -- Grafana, Headlamp, the Flux UI -- needs
# an OIDC client whose redirect URI names THAT cluster's hostnames. The clients
# are therefore per-cluster, and since ADR-0024 made the identity provider
# deployable on either cloud, there can be two sets of them.
#
# Creating two sets by hand in a console is how they drift, and a drifted
# redirect URI fails at login with an error that names neither the cluster nor
# the client. It is also a bootstrap blocker rather than a nicety: Headlamp's
# chart mounts `headlamp-envvars` and the pod sits in CreateContainerConfigError
# until that secret exists, so a cluster with no registered clients has a
# permanently unready Kustomization.
#
# WHAT IT DOES
#
#   1. Reads the ZITADEL admin PAT from the cluster's own secret store.
#   2. Ensures a project exists to hold the apps.
#   3. For each consumer, creates the OIDC app if it is missing (never
#      recreates one that exists -- recreating rotates the secret and breaks a
#      running cluster).
#   4. Writes the client id and secret into the store under the key the
#      consumer's ExternalSecret reads.
#
# Step 4 MERGES rather than overwrites where a secret holds more than OIDC:
# grafana-envvars also carries the generated admin credentials, and clobbering
# them would lock the operator out of Grafana.
#
# Usage:
#   zitadel-oidc-clients.sh sync --cluster gcp-0 --cloud gcp [--project ID] [--apply]
#   zitadel-oidc-clients.sh sync --cluster aws-0 --cloud aws [--region R]  [--apply]
#
# Dry-run unless --apply. Client secrets are never printed: ZITADEL returns a
# client secret exactly once, at creation, so it goes straight from the API
# response into the secret store.

set -o errexit
set -o nounset
set -o pipefail

COMMAND="${1:-}"
[ $# -gt 0 ] && shift

CLUSTER=""
CLOUD=""
REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-}}"
GCP_PROJECT=""
APPLY="false"
ZITADEL_PROJECT_NAME="platform"

while [ $# -gt 0 ]; do
    case "$1" in
        --cluster) CLUSTER="$2"; shift 2 ;;
        --cloud)   CLOUD="$2"; shift 2 ;;
        --region)  REGION="$2"; shift 2 ;;
        --project) GCP_PROJECT="$2"; shift 2 ;;
        --apply)   APPLY="true"; shift ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

[ -n "$CLUSTER" ] || { echo "--cluster is required" >&2; exit 2; }
case "$CLOUD" in aws|gcp) ;; *) echo "--cloud must be aws or gcp" >&2; exit 2 ;; esac

# ── secret store ──────────────────────────────────────────────────────────────

store_read() {
    case "$CLOUD" in
        aws) aws secretsmanager get-secret-value \
                 ${REGION:+--region "$REGION"} \
                 --secret-id "$1" --query SecretString --output text 2>/dev/null ;;
        gcp) gcloud secrets versions access latest \
                 ${GCP_PROJECT:+--project "$GCP_PROJECT"} \
                 --secret="$1" 2>/dev/null ;;
    esac
}

store_exists() {
    case "$CLOUD" in
        aws) aws secretsmanager describe-secret ${REGION:+--region "$REGION"} \
                 --secret-id "$1" >/dev/null 2>&1 ;;
        gcp) gcloud secrets describe "$1" ${GCP_PROJECT:+--project "$GCP_PROJECT"} \
                 >/dev/null 2>&1 ;;
    esac
}

# Write JSON on stdin to secret $1, creating or adding a version.
# Goes through a private temp file: the AWS CLI cannot read --cli-input-json
# from a pipe (it needs a seekable file) and fails with "Invalid JSON received".
store_write() {
    local name="$1" payload
    payload=$(umask 077 && mktemp -t zitadel-oidc.XXXXXX)
    # shellcheck disable=SC2064
    trap "shred -u '${payload}' 2>/dev/null || rm -f '${payload}'" RETURN
    cat > "$payload"

    case "$CLOUD" in
        aws)
            local body
            body=$(umask 077 && mktemp -t zitadel-oidc-body.XXXXXX)
            if store_exists "$name"; then
                jq --arg id "$name" '{SecretId: $id, SecretString: (. | tostring)}' \
                    < "$payload" > "$body"
                aws secretsmanager put-secret-value ${REGION:+--region "$REGION"} \
                    --cli-input-json "file://${body}" >/dev/null
            else
                jq --arg n "$name" --arg d "OIDC client for ${CLUSTER}. Written by zitadel-oidc-clients.sh." \
                   '{Name: $n, Description: $d, SecretString: (. | tostring)}' \
                    < "$payload" > "$body"
                aws secretsmanager create-secret ${REGION:+--region "$REGION"} \
                    --cli-input-json "file://${body}" >/dev/null
            fi
            shred -u "$body" 2>/dev/null || rm -f "$body"
            ;;
        gcp)
            store_exists "$name" || gcloud secrets create "$name" \
                ${GCP_PROJECT:+--project "$GCP_PROJECT"} \
                --replication-policy=automatic \
                --labels=managed-by=zitadel-oidc-clients >/dev/null
            gcloud secrets versions add "$name" \
                ${GCP_PROJECT:+--project "$GCP_PROJECT"} \
                --data-file="$payload" >/dev/null
            ;;
    esac
}

# ── zitadel api ───────────────────────────────────────────────────────────────

ZITADEL_ENVVARS_SECRET="zitadel-envvars" # pragma: allowlist secret

PAT="$(store_read "$ZITADEL_ENVVARS_SECRET" | jq -r '.ZITADEL_FIRSTINSTANCE_ORG_LOGINCLIENT_PAT // empty')"
if [ -z "$PAT" ]; then
    echo "ERROR: no ZITADEL_FIRSTINSTANCE_ORG_LOGINCLIENT_PAT in '${ZITADEL_ENVVARS_SECRET}'." >&2
    echo "That secret is what bootstraps ZITADEL; without the PAT there is no way to" >&2
    echo "call its API. Check the secret exists in the ${CLOUD} store for ${CLUSTER}." >&2
    exit 1
fi

# The IdP base URL. Derived the same way the platform derives it, so a mismatch
# here is a mismatch everywhere.
: "${IDP_URL:?set IDP_URL to the ZITADEL base URL, e.g. https://auth.gcp.cloud.ogenki.io}"
: "${PRIVATE_DOMAIN:?set PRIVATE_DOMAIN, e.g. priv.gcp.ogenki.io}"

api() {
    local method="$1" path="$2"
    shift 2
    curl -fsS -X "$method" "${IDP_URL}${path}" \
        -H "Authorization: Bearer ${PAT}" \
        -H "Content-Type: application/json" \
        "$@"
}

# ── the consumers ─────────────────────────────────────────────────────────────
#
# name | redirect URI | secret key it lands in
#
# Redirect paths are each framework's own callback and are not interchangeable:
#   Grafana   /login/generic_oauth   (grafana.ini auth.generic_oauth)
#   Headlamp  /oidc-callback         (headlamp chart)
#   Flux UI   /oauth2/callback       (flux-operator web.config.authentication)
CONSUMERS=(
  "grafana|https://grafana.${PRIVATE_DOMAIN}/login/generic_oauth|observability-victoria-metrics-k8s-stack-grafana-envvars"
  "headlamp|https://headlamp.${PRIVATE_DOMAIN}/oidc-callback|headlamp-envvars"
  "flux-ui|https://flux-ui-${CLUSTER}.${PRIVATE_DOMAIN}/oauth2/callback|security-flux-ui-oidc"
)

ensure_project() {
    local id
    id=$(api POST /management/v1/projects/_search -d '{"queries":[]}' \
         | jq -r --arg n "$ZITADEL_PROJECT_NAME" \
             '.result[]? | select(.name == $n) | .id' | head -1)
    if [ -n "$id" ]; then
        echo "$id"
        return
    fi
    if [ "$APPLY" != "true" ]; then
        echo "DRYRUN-PROJECT"
        return
    fi
    api POST /management/v1/projects -d "$(jq -n --arg n "$ZITADEL_PROJECT_NAME" '{name:$n}')" \
        | jq -r '.id'
}

app_id_by_name() {
    api POST "/management/v1/projects/$1/apps/_search" -d '{"queries":[]}' \
        | jq -r --arg n "$2" '.result[]? | select(.name == $n) | .id' | head -1
}

# Merge OIDC fields into a secret without dropping what else is in it.
merge_secret() {
    local key="$1" name="$2" client_id="$3" client_secret="$4" existing='{}'
    store_exists "$key" && existing="$(store_read "$key")"
    [ -z "$existing" ] && existing='{}'

    case "$name" in
        grafana)
            jq -n --argjson base "$existing" --arg id "$client_id" --arg sec "$client_secret" \
               '$base + {GF_AUTH_GENERIC_OAUTH_CLIENT_ID: $id, GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET: $sec}' ;;
        headlamp)
            jq -n --argjson base "$existing" --arg id "$client_id" --arg sec "$client_secret" \
               --arg iss "$IDP_URL" \
               '$base + {OIDC_CLIENT_ID: $id, OIDC_CLIENT_SECRET: $sec, OIDC_ISSUER_URL: $iss,
                         OIDC_SCOPES: "openid,profile,email",
                         OIDC_VALIDATOR_CLIENT_ID: $id, OIDC_VALIDATOR_ISSUER_URL: $iss}' ;;
        flux-ui)
            jq -n --argjson base "$existing" --arg id "$client_id" --arg sec "$client_secret" \
               '$base + {clientID: $id, clientSecret: $sec}' ;;
    esac
}

cmd_sync() {
    echo "cluster:  ${CLUSTER} (${CLOUD})"
    echo "idp:      ${IDP_URL}"
    echo "project:  ${ZITADEL_PROJECT_NAME}"
    echo

    local project_id
    project_id="$(ensure_project)"
    [ -n "$project_id" ] || { echo "could not resolve or create the ZITADEL project" >&2; exit 1; }

    local created=0 skipped=0
    for entry in "${CONSUMERS[@]}"; do
        IFS='|' read -r name redirect key <<< "$entry"

        local existing_id=""
        [ "$project_id" != "DRYRUN-PROJECT" ] && existing_id="$(app_id_by_name "$project_id" "$name")"

        if [ -n "$existing_id" ]; then
            # Never recreate: ZITADEL returns the client secret once, so
            # recreating would rotate it and break the running consumer.
            echo "[skip   ] ${name} -- app already exists (${existing_id}); leaving it alone"
            skipped=$((skipped + 1))
            continue
        fi

        if [ "$APPLY" != "true" ]; then
            echo "[dry-run] ${name} -> ${redirect}"
            echo "           would write client id/secret into ${key}"
            created=$((created + 1))
            continue
        fi

        local resp client_id client_secret
        resp=$(api POST "/management/v1/projects/${project_id}/apps/oidc" -d "$(jq -n \
            --arg n "$name" --arg r "$redirect" '{
              name: $n,
              redirectUris: [$r],
              responseTypes: ["OIDC_RESPONSE_TYPE_CODE"],
              grantTypes: ["OIDC_GRANT_TYPE_AUTHORIZATION_CODE","OIDC_GRANT_TYPE_REFRESH_TOKEN"],
              appType: "OIDC_APP_TYPE_WEB",
              authMethodType: "OIDC_AUTH_METHOD_TYPE_BASIC",
              accessTokenType: "OIDC_TOKEN_TYPE_BEARER",
              accessTokenRoleAssertion: true,
              idTokenRoleAssertion: true,
              idTokenUserinfoAssertion: true,
              devMode: false
            }')")

        client_id=$(jq -r '.clientId // empty' <<< "$resp")
        client_secret=$(jq -r '.clientSecret // empty' <<< "$resp")
        if [ -z "$client_id" ] || [ -z "$client_secret" ]; then
            echo "[FAILED ] ${name}: ZITADEL returned no clientId/clientSecret" >&2
            echo "$resp" | jq -r '.message // .' | head -3 >&2
            exit 1
        fi

        merge_secret "$key" "$name" "$client_id" "$client_secret" | store_write "$key"
        echo "[created] ${name} -> ${key} (client ${client_id})"
        created=$((created + 1))
    done

    echo
    echo "created: ${created}, skipped (already registered): ${skipped}"
    if [ "$APPLY" != "true" ]; then
        echo
        echo "This was a DRY RUN. Nothing was created and nothing was written."
    fi
}

case "$COMMAND" in
    sync) cmd_sync ;;
    *)
        sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'
        exit 2
        ;;
esac
