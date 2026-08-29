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

# gcloud must run as the identity OpenTofu uses, not the CLI account.
# shellcheck source=scripts/lib/gcloud-adc.sh
. "$(dirname "$0")/lib/gcloud-adc.sh"
# shellcheck source=scripts/lib/cloud-secret-store.sh
. "$(dirname "$0")/lib/cloud-secret-store.sh"
# shellcheck source=scripts/lib/zitadel-pat.sh
. "$(dirname "$0")/lib/zitadel-pat.sh"

COMMAND="${1:-}"
[ $# -gt 0 ] && shift

CLUSTER=""
CLOUD=""
REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-}}"
GCP_PROJECT=""
APPLY="false"
ZITADEL_PROJECT_NAME="platform"

# The project roles the platform's OWN RBAC already refers to. These are not a
# guess: each name is read back out of a manifest in this repo, through the
# groups/roles claim that zitadel-actions/groups-from-roles.js builds.
#
#   admin      security/base/rbac/admin.yaml   Group admin    -> cluster-admin
#              flux-ui ClusterRoleBinding       Group admin    -> cluster-admin
#              Grafana role_attribute_path      'admin'        -> Admin
#   backend    flux-ui ClusterRoleBinding       Group backend  -> edit
#              Grafana role_attribute_path      'backend'      -> Editor
#   data       flux-ui ClusterRoleBinding       Group data     -> edit
#              Grafana role_attribute_path      'data'         -> Editor
#   frontend   Grafana role_attribute_path      'frontend'     -> Editor
#
# Without them the whole chain is inert: ZITADEL has no role to grant, so the
# Action emits no claim, so every binding above matches nobody and Grafana falls
# through to Viewer. gcp-0 came up on 2026-08-28 with zero roles on the project
# and nothing anywhere said so -- login worked, authorisation silently did not.
ZITADEL_PROJECT_ROLES=(admin backend frontend data)

# --grant-admin <email>: give an EXISTING user the `admin` project role.
#
# Separate from role creation because the two cannot happen at the same time. A
# human user does not exist in ZITADEL until their FIRST LOGIN -- the Google IdP
# auto-creates them -- so there is nobody to grant to at bootstrap. The sequence
# is unavoidably: register clients -> configure the IdP -> log in once -> grant.
#
# It is here rather than in a console because a role granted by hand is a role
# nobody can reproduce, which is how gcp-0 ended up with no groups claim at all.
GRANT_ADMIN=""

while [ $# -gt 0 ]; do
    case "$1" in
        --cluster) CLUSTER="$2"; shift 2 ;;
        --cloud)   CLOUD="$2"; shift 2 ;;
        --region)  REGION="$2"; shift 2 ;;
        --project) GCP_PROJECT="$2"; shift 2 ;;
        --apply)   APPLY="true"; shift ;;
        --grant-admin) GRANT_ADMIN="$2"; shift 2 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

[ -n "$CLUSTER" ] || { echo "--cluster is required" >&2; exit 2; }
case "$CLOUD" in aws|gcp) ;; *) echo "--cloud must be aws or gcp" >&2; exit 2 ;; esac

# Provenance for secrets this script writes, read by cloud-secret-store.sh's
# store_write. Preserves what this script wrote before the store/PAT logic
# moved into shared libraries.
STORE_WRITE_DESCRIPTION="OIDC client for ${CLUSTER}. Written by zitadel-oidc-clients.sh."
STORE_WRITE_LABEL="zitadel-oidc-clients"

# ── zitadel api ───────────────────────────────────────────────────────────────

PAT="$(resolve_zitadel_pat)" || exit 1

# The IdP base URL. Derived the same way the platform derives it, so a mismatch
# here is a mismatch everywhere.
: "${IDP_URL:?set IDP_URL to the ZITADEL base URL, e.g. https://auth.gcp.cloud.ogenki.io}"
: "${PRIVATE_DOMAIN:?set PRIVATE_DOMAIN, e.g. priv.gcp.ogenki.io}"

# Optional escape hatch for split-DNS workstations. The IdP hostname is public,
# but a machine on the tailnet may resolve *.ogenki.io through a resolver that
# has not picked up a freshly created record -- 8.8.8.8 answers while the system
# resolver still returns NXDOMAIN from its negative cache. Setting
# IDP_RESOLVE=host:443:<ip> pins it for curl only, keeping SNI and certificate
# verification intact (unlike hitting the IP with a Host header).
#
#   IDP_RESOLVE=auth.gcp.cloud.ogenki.io:443:34.158.159.130
CURL_RESOLVE=()
[ -n "${IDP_RESOLVE:-}" ] && CURL_RESOLVE=(--resolve "$IDP_RESOLVE")

# The admin PAT never touches argv. `-H "Authorization: Bearer ${PAT}"` would
# put the live token in `ps`/`/proc/<pid>/cmdline` for as long as every curl
# process runs -- the same vulnerability class this repo already closed for
# jq --arg/--argjson (test-no-secret-argv.sh). curl has no stdin form for a
# header, so it goes into a `-K` config file instead, created once for this
# run:
#
#   * `umask 077 && mktemp` sets the mode AT CREATION -- creating the file and
#     chmod-ing it afterward leaves a window where it is world-readable.
#   * the path is baked into the trap STRING at trap-SET time
#     (`trap "rm -f '$path'" EXIT`), not left to expand when the trap fires.
#     Under `nounset`, a trap that expands the variable at fire time dies on
#     "unbound variable" if the variable is ever unset before it fires, and
#     cleans up nothing -- the exact bug just fixed in cloud-secret-store.sh's
#     store_write; same fix, same reasoning, applied here to the config file
#     itself rather than to a value merely passing through it.
#   * `"` and `\` in the token are escaped for curl's config-file syntax,
#     where both are otherwise significant.
API_CURL_CONFIG="$(umask 077 && mktemp -t zitadel-api-curl.XXXXXX)"
# shellcheck disable=SC2064
trap "rm -f '$API_CURL_CONFIG'" EXIT
pat_escaped="${PAT//\\/\\\\}"
pat_escaped="${pat_escaped//\"/\\\"}"
printf 'header = "Authorization: Bearer %s"\n' "$pat_escaped" > "$API_CURL_CONFIG"
unset pat_escaped

api() {
    local method="$1" path="$2"
    shift 2
    curl -fsS -X "$method" "${IDP_URL}${path}" \
        -K "$API_CURL_CONFIG" \
        ${CURL_RESOLVE[@]+"${CURL_RESOLVE[@]}"} \
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
  # gcp-0 only in practice, and harmless on aws-0 where nothing consumes it.
  # GKE cannot be told to trust ZITADEL, so Headlamp there sits behind
  # oauth2-proxy and the PROXY holds the OIDC client -- a second client for the
  # same hostname, on the proxy's own callback path. ADR-0026.
  "headlamp-proxy|https://headlamp.${PRIVATE_DOMAIN}/oauth2/callback|headlamp-oauth2-proxy"
  # Harbor's callback is /c/oidc/callback -- Harbor's own path, not guessable
  # from the others. No second imperative step applies it: Harbor stores
  # auth config in its DATABASE rather than in the chart, but the chart's
  # core.configureUserSettings renders CONFIG_OVERWRITE_JSON, which Harbor
  # writes to that database itself at startup and then locks read-only. The
  # client id/secret this script writes to the "harbor-oidc" store key reach
  # the HelmRelease via an ExternalSecret + valuesFrom, same as every other
  # consumer here. See ADR-0028.
  "harbor|https://harbor.${PRIVATE_DOMAIN}/c/oidc/callback|harbor-oidc"
)

# Roles are additive and idempotent: ZITADEL rejects a duplicate roleKey, so an
# existing role is left alone rather than rewritten. Granting a role to a USER is
# deliberately NOT done here -- a user exists only after their first login, and
# guessing who should be admin is not this script's business.
ensure_project_roles() {
    local project_id="$1" role existing
    [ -n "$project_id" ] || return 0

    if [ "$project_id" = "DRYRUN-PROJECT" ]; then
        echo "[dry-run] would ensure roles: ${ZITADEL_PROJECT_ROLES[*]}"
        return 0
    fi

    existing="$(api POST "/management/v1/projects/${project_id}/roles/_search" -d '{"query":{"limit":100}}' 2>/dev/null \
                | jq -r '.result[]?.key' || true)"

    for role in "${ZITADEL_PROJECT_ROLES[@]}"; do
        if grep -qx "$role" <<< "$existing"; then
            echo "[skip   ] role '${role}' already exists"
            continue
        fi
        if [ "$APPLY" != "true" ]; then
            echo "[dry-run] would create role '${role}'"
            continue
        fi
        jq -n --arg k "$role" --arg d "$role" '{roleKey: $k, displayName: $d}' \
            | api POST "/management/v1/projects/${project_id}/roles" -d @- >/dev/null
        echo "[created] role '${role}'"
    done
}

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
    api POST /management/v1/projects -d "$(jq -n --arg n "$ZITADEL_PROJECT_NAME" \
        '{name:$n, projectRoleAssertion:true}')" \
        | jq -r '.id'
}

# "Assert Roles on Authentication", and it is the flag every SSO consumer on this
# platform silently depends on.
#
# ZITADEL defaults it to FALSE. With it off, project roles are attached to NO
# token -- and the damage is not limited to the standard roles claim:
# `ctx.v1.user.grants` is EMPTY inside a token action, so
# zitadel-actions/groups-from-roles.js takes its no-grants early return and never
# sets `groups` or `roles` at all. The action still logs "action run succeeded".
#
# On 2026-08-28 that one flag produced three unrelated-looking failures:
#
#   Flux UI   failed to evaluate the CEL expression 'claims.groups':
#             no such key: groups
#   Headlamp  [AuthFailure] Invalid authentication via OAuth2: unauthorized
#             (oauth2-proxy's --allowed-group=admin matching nothing)
#   Grafana   every user silently landing on the Viewer fallback
#
# Every other setting looked right: the user held an ACTIVE admin grant on this
# project, the project was in the token's `aud`, and all five apps had
# idTokenUserinfoAssertion and idTokenRoleAssertion true. None of that matters
# while the project itself refuses to assert roles.
#
# Set on an EXISTING project too, not only at creation -- gcp-0's was created
# before this was understood, and a project that predates this function must be
# repaired rather than left to a manual console click nobody remembers.
grant_admin_role() {
    local email="$1" project_id="$2" user_id existing
    [ -n "$email" ] || return 0
    [ -n "$project_id" ] || return 0
    if [ "$project_id" = "DRYRUN-PROJECT" ]; then
        echo "[dry-run] would grant 'admin' to ${email}"
        return 0
    fi

    user_id="$(api POST /management/v1/users/_search -d '{"query":{"limit":200}}' 2>/dev/null \
               | jq -r --arg e "$email" '.result[]? | select((.userName == $e) or (.human.email.email == $e)) | .id' | head -1)"
    if [ -z "$user_id" ]; then
        echo "[FAILED ] no ZITADEL user for ${email}." >&2
        echo "           A human user exists only AFTER their first login through the" >&2
        echo "           Google IdP (isAutoCreation). Log in once, then re-run this." >&2
        return 1
    fi

    existing="$(api POST /management/v1/users/grants/_search -d '{"query":{"limit":200}}' 2>/dev/null \
                | jq -r --arg u "$user_id" --arg p "$project_id" \
                    '.result[]? | select(.userId == $u and .projectId == $p) | .roleKeys[]?' || true)"
    if grep -qx "admin" <<< "$existing"; then
        echo "[skip   ] ${email} already holds 'admin'"
        return 0
    fi
    if [ "$APPLY" != "true" ]; then
        echo "[dry-run] would grant 'admin' to ${email} (${user_id})"
        return 0
    fi

    jq -n --arg p "$project_id" '{projectId: $p, roleKeys: ["admin"]}' \
        | api POST "/management/v1/users/${user_id}/grants" -d @- >/dev/null
    echo "[granted] 'admin' to ${email} (${user_id})"
}

ensure_project_role_assertion() {
    local project_id="$1" current
    [ -n "$project_id" ] || return 0
    [ "$project_id" = "DRYRUN-PROJECT" ] && { echo "[dry-run] would ensure projectRoleAssertion=true"; return 0; }

    current="$(api GET "/management/v1/projects/${project_id}" 2>/dev/null \
               | jq -r '.project.projectRoleAssertion // false')"
    if [ "$current" = "true" ]; then
        echo "[skip   ] projectRoleAssertion already true"
        return 0
    fi
    if [ "$APPLY" != "true" ]; then
        echo "[dry-run] would set projectRoleAssertion=true (currently ${current})"
        return 0
    fi

    # The PUT is a full replace: omitting a field resets it to its zero value, so
    # the other three are restated at their current defaults rather than dropped.
    jq -n --arg n "$ZITADEL_PROJECT_NAME" \
        '{name:$n, projectRoleAssertion:true, projectRoleCheck:false,
          hasProjectCheck:false,
          privateLabelingSetting:"PRIVATE_LABELING_SETTING_UNSPECIFIED"}' \
        | api PUT "/management/v1/projects/${project_id}" -d @- >/dev/null
    echo "[updated] projectRoleAssertion=true"
}

app_id_by_name() {
    api POST "/management/v1/projects/$1/apps/_search" -d '{"queries":[]}' \
        | jq -r --arg n "$2" '.result[]? | select(.name == $n) | .id' | head -1
}

# The redirect URIs an existing app currently has, one per line.
app_redirect_uris() {
    api GET "/management/v1/projects/$1/apps/$2" \
        | jq -r '.app.oidcConfig.redirectUris[]? // empty'
}

# Point an existing app at the redirect URI it is supposed to have.
#
# This updates the OIDC CONFIG, not the app: ZITADEL rotates a client secret only
# through the separate `_secret` endpoint, so the running consumer keeps working
# and nothing has to be rewritten into the secret store.
#
# The update REPLACES the config rather than patching it, so every field the
# create call sets has to be sent again -- omitting one silently reverts it to
# ZITADEL's default, and `accessTokenRoleAssertion`/`idTokenRoleAssertion`
# reverting to false is the same class of failure as projectRoleAssertion being
# off: authentication keeps working and every consumer loses its groups.
app_set_redirect() {
    local project_id="$1" app_id="$2" redirect="$3"
    api PUT "/management/v1/projects/${project_id}/apps/${app_id}/oidc_config" \
        -d "$(jq -n --arg r "$redirect" '{
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
        }')" >/dev/null
}

# Merge OIDC fields into a secret without dropping what else is in it.
#
# $existing, $client_secret and (for headlamp-proxy) the cookie secret all
# travel into jq on STDIN, never as --arg/--argjson -- either would put the
# value on jq's argv, readable by any process via /proc/<pid>/cmdline for as
# long as jq runs. That matters for more than the client secret: $existing is
# the CURRENT full contents of the target secret, and for grafana that blob
# also carries the generated Grafana admin credentials, so --argjson base
# would leak those too. Only client_id and the issuer URL, neither secret, go
# in as --arg. Three concatenated JSON documents on one stream, pulled out in
# order with `input` -- the same trick jq's own manual gives for slurping more
# than one value without `--slurp` swallowing the whole stream into an array.
merge_secret() {
    local key="$1" name="$2" client_id="$3" client_secret="$4"
    local existing='{}' cookie_secret=''
    store_exists "$key" && existing="$(store_read "$key")"
    [ -z "$existing" ] && existing='{}'

    if [ "$name" = headlamp-proxy ]; then
        # Hyphenated keys, deliberately: the oauth2-proxy chart's
        # `config.existingSecret` reads exactly client-id / client-secret /
        # cookie-secret, so the blob is shaped to be consumed by a whole-blob
        # ExternalSecret extract with no remapping.
        #
        # PRESERVED across runs -- regenerating on every sync would silently
        # log every user out and look like a broken login.
        #
        # EXACTLY 32 CHARACTERS. `openssl rand -base64 32` alone emits 44,
        # and oauth2-proxy refuses to start on it:
        #   cookie_secret must be 16, 24, or 32 bytes to create an AES
        #   cipher, but is 44 bytes
        # It measures the STRING, not the decoded bytes, so the base64 has to
        # be truncated to the cipher length rather than sized to decode into
        # it. `head -c 32` is the recipe the chart's own values.yaml gives.
        cookie_secret="$(jq -r '."cookie-secret" // empty' <<< "$existing")"
        [ -n "$cookie_secret" ] || cookie_secret="$(openssl rand -base64 32 | head -c 32)"
    fi

    {
        printf '%s\n' "$existing"
        printf '%s' "$client_secret" | jq -Rs .
        printf '%s' "$cookie_secret" | jq -Rs .
    } | jq -n --arg id "$client_id" --arg iss "$IDP_URL" --arg name "$name" '
        input as $base | input as $sec | input as $ck |
        if $name == "grafana" then
            $base + {GF_AUTH_GENERIC_OAUTH_CLIENT_ID: $id, GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET: $sec}
        elif $name == "headlamp" then
            $base + {OIDC_CLIENT_ID: $id, OIDC_CLIENT_SECRET: $sec, OIDC_ISSUER_URL: $iss,
                     OIDC_SCOPES: "profile,email,groups",
                     OIDC_VALIDATOR_CLIENT_ID: $id, OIDC_VALIDATOR_ISSUER_URL: $iss}
        elif $name == "flux-ui" then
            $base + {clientID: $id, clientSecret: $sec}
        elif $name == "harbor" then
            $base + {client_id: $id, client_secret: $sec, endpoint: $iss}
        elif $name == "headlamp-proxy" then
            $base + {"client-id": $id, "client-secret": $sec, "cookie-secret": $ck}
        else
            empty
        end
    '
}

cmd_sync() {
    echo "cluster:  ${CLUSTER} (${CLOUD})"
    echo "idp:      ${IDP_URL}"
    echo "project:  ${ZITADEL_PROJECT_NAME}"
    echo

    local project_id
    project_id="$(ensure_project)"
    [ -n "$project_id" ] || { echo "could not resolve or create the ZITADEL project" >&2; exit 1; }

    ensure_project_role_assertion "$project_id"
    ensure_project_roles "$project_id"
    grant_admin_role "$GRANT_ADMIN" "$project_id"

    local created=0 skipped=0 updated=0
    for entry in "${CONSUMERS[@]}"; do
        IFS='|' read -r name redirect key <<< "$entry"

        local existing_id=""
        [ "$project_id" != "DRYRUN-PROJECT" ] && existing_id="$(app_id_by_name "$project_id" "$name")"

        if [ -n "$existing_id" ]; then
            # Never RECREATE: ZITADEL returns the client secret once, so
            # recreating would rotate it and break the running consumer.
            #
            # But do not leave it alone either. The redirect URI is derived from
            # $PRIVATE_DOMAIN, and a cluster restored from a frozen database
            # comes back with whatever domain was current when the seed was
            # taken. aws-0 restored from a 19 July seed on 2026-08-29 and every
            # client still pointed at priv.cloud.ogenki.io, months after the
            # cloud split moved it to priv.aws.ogenki.io. Every login failed with
            #   "The requested redirect_uri is missing in the client configuration"
            # and re-running this script cheerfully skipped all five.
            local current
            current="$(app_redirect_uris "$project_id" "$existing_id")"

            if grep -Fxq "$redirect" <<< "$current"; then
                echo "[ok     ] ${name} -- app exists (${existing_id}), redirect correct"
                skipped=$((skipped + 1))
                continue
            fi

            echo "[STALE  ] ${name} (${existing_id})"
            echo "           has:  ${current:-<none>}"
            echo "           want: ${redirect}"
            if [ "$APPLY" != "true" ]; then
                echo "           would update the redirect URI (client secret untouched)"
                updated=$((updated + 1))
                continue
            fi
            app_set_redirect "$project_id" "$existing_id" "$redirect"
            echo "[updated] ${name} -> ${redirect} (client secret untouched)"
            updated=$((updated + 1))
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
    echo "created: ${created}, updated: ${updated}, unchanged: ${skipped}"
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
