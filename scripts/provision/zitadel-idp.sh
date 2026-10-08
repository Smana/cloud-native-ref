#!/usr/bin/env bash
#
# Register the Google Workspace identity provider and the groups Action in
# ZITADEL, from configuration this repository owns.
#
# WHY THIS EXISTS
#
# Both of these were configured by hand in a console, on aws-0, and lived
# nowhere else. On 2026-08-28 gcp-0 came up with its own fresh ZITADEL and had
# neither, and the credentials could not be recovered from either secret store
# because they had never been put in one -- 68 secrets in AWS Secrets Manager,
# not a Google key among them.
#
# That is worse than it sounds. aws-0's SQLInstance restores from the frozen
# `zitadel-20260719` prefix on EVERY rebuild, so anything configured in ZITADEL
# after that snapshot is discarded the next time the cluster is rebuilt. The
# Google IdP was one rebuild away from being lost on AWS too.
#
# So: the credentials go in the secret store, the Action goes in git, and this
# script applies both. Same shape as zitadel-oidc-clients.sh, deliberately --
# read that one first if this is unfamiliar.
#
# WHAT IT DOES
#
#   1. Reads the ZITADEL admin PAT from the cluster.
#   2. Reads the Google OAuth client from the secret store (`zitadel-google-idp`).
#   3. Creates the Google IdP if missing, INSTANCE-level, and if one already
#      exists corrects its client id in place should the store's differ --
#      never by recreating, which would orphan every existing user link.
#   4. Uploads scripts/provision/zitadel-actions/groups-from-roles.js as a v1 Action.
#   5. Wires that Action into flow 2 (CustomiseToken) on BOTH triggers.
#   6. If `zitadel-github-idp` is in the store: a LINK-ONLY GitHub IdP, and the
#      room broker's read-only reader -- machine user room-broker-idp-reader with
#      ORG_OWNER_VIEWER, one PAT (1 year, re-minted under 30 days) written to
#      `room-broker-zitadel-reader` as {"pat","githubIdpId"}. Without the key,
#      all of step 6 is skipped.
#
# Usage:
#   zitadel-idp.sh sync --cluster gcp-0 --cloud gcp [--project ID] [--apply]
#   zitadel-idp.sh sync --cluster aws-0 --cloud aws [--region R]  [--apply]
#
# Dry-run unless --apply. The client secret is never printed.
#
# It resolves the admin PAT as the HOSTING cloud, so run it with kubectl
# pointed at the cluster that hosts the IdP: a leftover security/iam-admin-pat
# in any other cluster would overwrite that cloud's stored PAT (GP-20).
#
# THE ONE THING TO DO BY HAND, ONCE PER CLUSTER
#
# Google OAuth clients accept MANY authorized redirect URIs -- unlike a GitHub
# OAuth app, which accepts exactly one and is why app-wizard needs a separate
# app per cluster. So one Google client serves every cluster, provided each
# cluster's callback is listed on it:
#
#   https://auth.<public_domain_name>/ui/login/login/externalidp/callback
#
# That path is ZITADEL's, verified against a live instance rather than
# constructed: it answers 200 while a nonsense path under the same prefix 404s.
# This script CANNOT add it for you -- it is a Google-side setting -- so it
# prints the URI and checks nothing about it. A missing entry fails at Google
# with redirect_uri_mismatch, naming neither ZITADEL nor the cluster.

set -o errexit
set -o nounset
set -o pipefail

# gcloud must run as the identity OpenTofu uses, not the CLI account.
# shellcheck source=scripts/lib/gcloud-adc.sh
. "$(dirname "$0")/../lib/gcloud-adc.sh"
# shellcheck source=scripts/lib/cloud-secret-store.sh
. "$(dirname "$0")/../lib/cloud-secret-store.sh"
# shellcheck source=scripts/lib/zitadel-pat.sh
. "$(dirname "$0")/../lib/zitadel-pat.sh"

COMMAND="${1:-}"
[ $# -gt 0 ] && shift

CLUSTER=""
CLOUD=""
REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-}}"
GCP_PROJECT=""
APPLY="false"

IDP_NAME="Google Workspace"
IDP_SECRET_KEY="zitadel-google-idp" # pragma: allowlist secret
# THE ACTION NAME IS NOT A LABEL. ZITADEL v1 looks up a function in the script
# BY THIS NAME and runs it, so it must be a valid JS identifier and must match
# the function in ACTION_FILE exactly.
#
# It was "groups-from-roles" for one day. Hyphens cannot appear in a JS
# identifier, so no function could ever carry that name, and ZITADEL logged
#     action run failed: function not found
# on every token request. With allowedToFail=false that FAILS TOKEN ISSUANCE --
# which surfaces in Grafana as "Failed to get token from provider" and in the
# ZITADEL UI as nothing at all. Nothing in the API rejects the mismatched name;
# it is accepted, stored, and only ever fails at runtime.
#
# assert_action_name_matches_function() below makes that unrepeatable.
ACTION_NAME="groupsFromRoles"
ACTION_FILE="$(cd "$(dirname "$0")" && pwd)/zitadel-actions/groups-from-roles.js"

# GitHub is OPTIONAL and LINK-ONLY: a developer signs in with Google and links
# GitHub once, and the room broker reads that link (ListIDPLinks) with a
# read-only machine user (spec D7). No Action, no token claim: user metadata is
# self-writable, an IdP link is not.
GITHUB_IDP_NAME="GitHub"
GITHUB_IDP_SECRET_KEY="zitadel-github-idp" # pragma: allowlist secret
GITHUB_ENABLED="false" # set by ensure_github_idp from the one read of the key
READER_USER="room-broker-idp-reader"
# ORG_OWNER_VIEWER is read-only. ZITADEL has no narrower org role that includes
# user.read, which ListIDPLinks needs.
READER_ROLE="ORG_OWNER_VIEWER"
READER_STORE_KEY="room-broker-zitadel-reader" # pragma: allowlist secret
READER_PAT_DAYS=365
READER_PAT_ROTATE_DAYS=30

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

[ "$COMMAND" = "sync" ] || { sed -n '2,60p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
[ -n "$CLUSTER" ] || { echo "--cluster is required" >&2; exit 2; }
case "$CLOUD" in aws|gcp) ;; *) echo "--cloud must be aws or gcp" >&2; exit 2 ;; esac
[ -r "$ACTION_FILE" ] || { echo "cannot read ${ACTION_FILE}" >&2; exit 1; }

# ── zitadel api ───────────────────────────────────────────────────────────────

# zitadel-pat.sh's OWN dry-run signal -- see the identical block in
# zitadel-oidc-clients.sh for why this is a variable the library owns rather
# than this script's $APPLY read directly. Same underlying bug: without this,
# a plain sync here persists the admin PAT into the cloud secret store even
# though this script's own header also promises "Dry-run unless --apply."
ZITADEL_PAT_DRY_RUN="true"
[ "$APPLY" = "true" ] && ZITADEL_PAT_DRY_RUN="false"

# This script configures the directory it runs against, so that cluster hosts it.
PAT="$(resolve_zitadel_pat hosting)" || exit 1

: "${IDP_URL:?set IDP_URL to the ZITADEL base URL, e.g. https://auth.gcp.cloud.ogenki.io}"

# Same split-DNS escape hatch as zitadel-oidc-clients.sh: pins the host for curl
# only, keeping SNI and certificate verification intact.
CURL_RESOLVE=()
[ -n "${IDP_RESOLVE:-}" ] && CURL_RESOLVE=(--resolve "$IDP_RESOLVE")

# The admin PAT never touches argv -- see the identical block in
# zitadel-oidc-clients.sh for the full reasoning (mode-at-creation, trap
# baked in at SET time, config-file escaping). Same fix, same file shape.
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

# ── the identity provider ─────────────────────────────────────────────────────
#
# INSTANCE-level (/admin/v1), not org-level (/management/v1). Both answer on
# this instance and both would work; instance scope means every org inherits the
# provider, which is what a single-tenant platform wants. Org scope would tie it
# to the `platform` org that zitadel-oidc-clients.sh creates, and a second org
# would silently have no Google login.
# TEMPLATES, not /admin/v1/idps/_search.
#
# ZITADEL carries two generations of IdP API on the same prefix. The legacy
# /admin/v1/idps/_search covers hand-rolled OIDC/JWT providers; the typed
# providers created by POST /admin/v1/idps/google are "templates" and are
# invisible to it. Both return 200, and the legacy one answers a search for a
# template-created provider with `{"details":{...}}` and no result array at all
# -- indistinguishable from "nothing exists".
#
# That is not cosmetic: this function decides whether to create or update.
# Pointed at the legacy endpoint it reported the freshly created Google
# provider as absent, so a second --apply would have added a DUPLICATE IdP,
# which is precisely what the id lookup below exists to prevent. Caught by
# re-running the dry run after an apply.
# The full template entry, not just the id: ensure_idp needs .config.google.clientId
# to check for drift. Kept separate from idp_id_by_name (below) because that one
# is also called from main() where only the id is wanted.
idp_template_by_name() {
    api POST /admin/v1/idps/templates/_search -d '{"queries":[]}' 2>/dev/null \
        | jq -c --arg n "${1:-$IDP_NAME}" '.result[]? | select(.name == $n)' | head -1
}

idp_id_by_name() {
    # "null" rather than "" when nothing matched. jq -r without -e happens to
    # accept a truly empty stdin quietly (checked against this repo's jq
    # 1.8.2: exits 0, no output) -- but that is jq being lenient, not this
    # script being correct, and it is one flag or one jq upgrade away from an
    # errexit kill on the common "doesn't exist yet" path. Feeding it valid
    # JSON either way costs nothing. Same reasoning applied everywhere else
    # this function's output gets re-parsed.
    local template
    template="$(idp_template_by_name "${1:-}" || true)"
    jq -r '.id // empty' <<< "${template:-null}"
}

# What can actually go stale on THIS object, and what can't:
#
# A Google-type IdP has no caller-set issuer -- Google's is fixed
# (accounts.google.com) and is not a field ZITADEL lets you write, so there is
# nothing here for a changed $IDP_URL to invalidate. (Confirmed against the API
# reference: AddGoogleProvider/UpdateGoogleProvider take name/clientId/
# clientSecret/scopes/providerOptions, no issuer.) What DOES drift is clientId,
# if the Google OAuth client in the secret store is ever rotated or replaced
# while an old one is still registered here.
#
# The old behaviour skipped unconditionally once an IdP existed, which is right
# for "leave the secret alone" but wrong for "never notice it changed" -- so
# this compares clientId and, on a mismatch, PUTs the update in place.
# PUT /admin/v1/idps/google/{id} updates an existing provider's config; unlike
# the delete+recreate the old comment warned against, it does not touch user
# links -- those are keyed off the IdP's id, which an in-place update leaves
# untouched.
# The secret goes in via stdin (-Rs reads it as one raw string, so `.` is the
# secret), never as a jq --arg -- argv is world-readable for the life of the
# process via /proc/<pid>/cmdline, and a Google OAuth client secret is exactly
# the kind of credential that rule exists for. Shared by CREATE and UPDATE on
# purpose: two copies of this construction is how one of them quietly stops
# matching the other.
#
# isAutoCreation/isAutoUpdate: a Workspace user logging in for the first time
# gets a ZITADEL user created from their Google profile, and later profile
# changes follow. Without them the login succeeds and then dead-ends on "user
# not found", which is the least helpful possible outcome.
#
# isLinkingAllowed lets an existing local user attach Google rather than
# ending up with two accounts for one human.
google_idp_payload() {
    local ci="$1" cs="$2"
    printf '%s' "$cs" | jq -Rs --arg n "$IDP_NAME" --arg ci "$ci" \
        '{name: $n, clientId: $ci, clientSecret: .,
          scopes: ["openid","profile","email"],
          providerOptions: {isLinkingAllowed: true, isCreationAllowed: true,
                            isAutoCreation: true, isAutoUpdate: true}}'
}

ensure_idp() {
    local blob client_id client_secret template existing existing_client_id

    blob="$(store_read "$IDP_SECRET_KEY" || true)"
    if [ -z "$blob" ]; then
        echo "[FAILED ] ${IDP_SECRET_KEY} not found in the ${CLOUD} store." >&2
        echo "           Create it from the Google OAuth client's JSON:" >&2
        echo '           jq -c "{client_id: .web.client_id, client_secret: .web.client_secret}"' >&2
        return 1
    fi
    client_id="$(jq -r '.client_id // empty' <<< "$blob")"
    client_secret="$(jq -r '.client_secret // empty' <<< "$blob")"
    if [ -z "$client_id" ] || [ -z "$client_secret" ]; then
        echo "[FAILED ] ${IDP_SECRET_KEY} has no client_id/client_secret" >&2
        return 1
    fi

    template="$(idp_template_by_name || true)"
    existing="$(jq -r '.id // empty' <<< "${template:-null}")"

    if [ -n "$existing" ]; then
        # clientId only -- ZITADEL never echoes a stored clientSecret back on
        # a GET or a search result (same reason this script never prints one),
        # so a secret-only rotation (same clientId, regenerated secret) is
        # invisible to this comparison. That is an API constraint, not a gap:
        # there is nothing here to read and compare it against.
        existing_client_id="$(jq -r '.config.google.clientId // empty' <<< "$template")"
        if [ "$existing_client_id" = "$client_id" ]; then
            echo "[ok     ] IdP '${IDP_NAME}' (${existing}), client id correct"
            return 0
        fi

        echo "[STALE  ] IdP '${IDP_NAME}' (${existing}) client id: has ${existing_client_id:-<none>}, want ${client_id}"
        if [ "$APPLY" != "true" ]; then
            echo "           would update in place (client secret untouched on screen, user links kept)"
            return 0
        fi
        google_idp_payload "$client_id" "$client_secret" \
            | api PUT "/admin/v1/idps/google/${existing}" -d @- >/dev/null
        echo "[updated] IdP '${IDP_NAME}' (${existing}) client id -> ${client_id}"
        return 0
    fi

    if [ "$APPLY" != "true" ]; then
        echo "[dry-run] would create IdP '${IDP_NAME}' (client ${client_id})"
        return 0
    fi

    local resp id
    resp="$(google_idp_payload "$client_id" "$client_secret" | api POST /admin/v1/idps/google -d @-)"
    id="$(jq -r '.id // empty' <<< "$resp")"
    if [ -z "$id" ]; then
        echo "[FAILED ] IdP creation returned no id: $(jq -c '.' <<< "$resp" | head -c 200)" >&2
        return 1
    fi
    echo "[created] IdP '${IDP_NAME}' (${id}, client ${client_id})"
}

# ── the GitHub identity provider ──────────────────────────────────────────────
#
# Same instance scope and update-in-place rule as the Google IdP. A GitHub OAuth
# App accepts exactly ONE callback URL, so there is one app per ZITADEL; its
# credentials live in the store key as {"client_id": "...", "client_secret": "..."}.
#
# LINK-ONLY: isLinkingAllowed true; isCreationAllowed, isAutoCreation and
# isAutoUpdate false; autoLinking unset. Nobody can sign up through GitHub, and
# a GitHub account never attaches itself to a user by e-mail match.
github_idp_payload() {
    local ci="$1" cs="$2"
    printf '%s' "$cs" | jq -Rs --arg n "$GITHUB_IDP_NAME" --arg ci "$ci" \
        '{name: $n, clientId: $ci, clientSecret: .,
          scopes: ["read:user"],
          providerOptions: {isLinkingAllowed: true, isCreationAllowed: false,
                            isAutoCreation: false, isAutoUpdate: false}}'
}

# Reads the store key ONCE and records the answer in GITHUB_ENABLED, which the
# login-policy step and ensure_broker_reader read instead of asking again.
ensure_github_idp() {
    local blob client_id client_secret template existing existing_client_id

    blob="$(store_read "$GITHUB_IDP_SECRET_KEY" || true)"
    if [ -z "$blob" ]; then
        echo "[skip   ] ${GITHUB_IDP_SECRET_KEY} not in the ${CLOUD} store: no GitHub IdP, no broker reader"
        return 0
    fi
    client_id="$(jq -r '.client_id // empty' <<< "$blob")"
    client_secret="$(jq -r '.client_secret // empty' <<< "$blob")"
    if [ -z "$client_id" ] || [ -z "$client_secret" ]; then
        echo "[FAILED ] ${GITHUB_IDP_SECRET_KEY} has no client_id/client_secret" >&2
        return 1
    fi
    GITHUB_ENABLED="true"

    template="$(idp_template_by_name "$GITHUB_IDP_NAME" || true)"
    existing="$(jq -r '.id // empty' <<< "${template:-null}")"

    if [ -n "$existing" ]; then
        existing_client_id="$(jq -r '.config.github.clientId // empty' <<< "$template")"
        if [ "$existing_client_id" = "$client_id" ]; then
            echo "[ok     ] IdP '${GITHUB_IDP_NAME}' (${existing}), client id correct"
            return 0
        fi
        echo "[STALE  ] IdP '${GITHUB_IDP_NAME}' (${existing}) client id: has ${existing_client_id:-<none>}, want ${client_id}"
        if [ "$APPLY" != "true" ]; then
            echo "           would update in place (user links kept)"
            return 0
        fi
        github_idp_payload "$client_id" "$client_secret" \
            | api PUT "/admin/v1/idps/github/${existing}" -d @- >/dev/null
        echo "[updated] IdP '${GITHUB_IDP_NAME}' (${existing}) client id -> ${client_id}"
        return 0
    fi

    if [ "$APPLY" != "true" ]; then
        echo "[dry-run] would create IdP '${GITHUB_IDP_NAME}' (client ${client_id})"
        return 0
    fi

    local resp id
    resp="$(github_idp_payload "$client_id" "$client_secret" | api POST /admin/v1/idps/github -d @-)"
    id="$(jq -r '.id // empty' <<< "$resp")"
    if [ -z "$id" ]; then
        echo "[FAILED ] IdP creation returned no id: $(jq -c '.' <<< "$resp" | head -c 200)" >&2
        return 1
    fi
    echo "[created] IdP '${GITHUB_IDP_NAME}' (${id}, client ${client_id})"
}

# ── the broker's link reader ──────────────────────────────────────────────────
#
# The room broker decides who may see a room from the user's GitHub IdP link
# (ListIDPLinks), so it needs a ZITADEL credential that can read users and
# nothing else: machine user + ORG_OWNER_VIEWER + a PAT. The PAT is returned
# once, at creation, so it is written to the store in the same step; a 1-year
# expiry rotated under 30 days keeps it from silently dying.
#
# Old PATs are left to expire: the broker may still hold one while it picks up
# the new store value.
ensure_broker_reader() {
    local gh_id="$1" resp user_id roles stored stored_pat stored_gh valid threshold expiry token

    resp="$(jq -nc --arg n "$READER_USER" \
        '{queries: [{userNameQuery: {userName: $n, method: "TEXT_QUERY_METHOD_EQUALS"}}]}' \
        | api POST /management/v1/users/_search -d @-)" \
        || { echo "[FAILED ] cannot search users for ${READER_USER}" >&2; return 1; }
    user_id="$(jq -r --arg n "$READER_USER" '[.result[]? | select(.userName == $n) | .id][0] // empty' <<< "$resp")"

    if [ -n "$user_id" ]; then
        echo "[ok     ] machine user '${READER_USER}' (${user_id})"
    elif [ "$APPLY" != "true" ]; then
        echo "[dry-run] would create machine user '${READER_USER}'"
    else
        user_id="$(jq -nc --arg n "$READER_USER" \
            '{userName: $n, name: "Room broker IdP link reader",
              description: "Read-only: lets the room broker read users'"'"' IdP links (ListIDPLinks).",
              accessTokenType: "ACCESS_TOKEN_TYPE_BEARER"}' \
            | api POST /management/v1/users/machine -d @- | jq -r '.userId // empty')"
        [ -n "$user_id" ] || { echo "[FAILED ] machine user creation returned no id" >&2; return 1; }
        echo "[created] machine user '${READER_USER}' (${user_id})"
    fi

    if [ -z "$user_id" ]; then
        echo "[dry-run] would grant ${READER_ROLE} to ${READER_USER}"
    else
        resp="$(jq -nc --arg u "$user_id" '{queries: [{userIdQuery: {userId: $u}}]}' \
            | api POST /management/v1/orgs/me/members/_search -d @-)" \
            || { echo "[FAILED ] cannot list org members" >&2; return 1; }
        roles="$(jq -c --arg u "$user_id" '[.result[]? | select(.userId == $u) | .roles[]?] | sort' <<< "$resp")"
        if [ "$roles" = "[\"${READER_ROLE}\"]" ]; then
            echo "[ok     ] ${READER_USER} holds exactly ${READER_ROLE}"
        elif [ "$APPLY" != "true" ]; then
            echo "[STALE  ] ${READER_USER} org roles: has ${roles}, want only ${READER_ROLE}"
            echo "[dry-run] would grant ${READER_ROLE} to ${READER_USER}"
        elif [ "$roles" = "[]" ]; then
            jq -nc --arg u "$user_id" --arg r "$READER_ROLE" '{userId: $u, roles: [$r]}' \
                | api POST /management/v1/orgs/me/members -d @- >/dev/null
            echo "[granted] ${READER_ROLE} to ${READER_USER}"
        else
            jq -nc --arg r "$READER_ROLE" '{roles: [$r]}' \
                | api PUT "/management/v1/orgs/me/members/${user_id}" -d @- >/dev/null
            echo "[updated] ${READER_USER} org roles ${roles} -> only ${READER_ROLE}"
        fi
    fi

    # The stored PAT must be one ZITADEL still lists with enough life left. The
    # token value cannot be read back, so a missing store entry means minting.
    stored="$(store_read "$READER_STORE_KEY" || true)"
    stored_pat="$(jq -r '.pat // empty' <<< "${stored:-null}" 2>/dev/null || true)"
    stored_gh="$(jq -r '.githubIdpId // empty' <<< "${stored:-null}" 2>/dev/null || true)"
    valid="false"
    if [ -n "$user_id" ] && [ -n "$stored_pat" ]; then
        resp="$(api POST "/management/v1/users/${user_id}/pats/_search" -d '{}')" \
            || { echo "[FAILED ] cannot list PATs of ${READER_USER}" >&2; return 1; }
        # RFC 3339 strings of one shape compare correctly as text.
        threshold="$(date -u -d "+${READER_PAT_ROTATE_DAYS} days" +%Y-%m-%dT%H:%M:%SZ)"
        if jq -e --arg t "$threshold" 'any(.result[]?; (.expirationDate // "") > $t)' <<< "$resp" >/dev/null; then
            valid="true"
        fi
    fi

    # Read by store_write.
    # shellcheck disable=SC2034
    local STORE_WRITE_DESCRIPTION="Room broker's read-only ZITADEL credential. Written by zitadel-idp.sh."
    # shellcheck disable=SC2034
    local STORE_WRITE_LABEL="zitadel-idp"
    if [ "$valid" = "true" ] && [ "$stored_gh" = "$gh_id" ]; then
        echo "[ok     ] ${READER_STORE_KEY}: PAT valid for over ${READER_PAT_ROTATE_DAYS} days, githubIdpId current"
    elif [ "$valid" = "true" ]; then
        echo "[STALE  ] ${READER_STORE_KEY}: githubIdpId has ${stored_gh:-<none>}, want ${gh_id:-<new IdP>}"
        if [ "$APPLY" != "true" ]; then
            echo "[dry-run] would update githubIdpId in ${READER_STORE_KEY}"
        else
            printf '%s' "$stored_pat" | jq -Rs --arg id "$gh_id" '{pat: ., githubIdpId: $id}' \
                | store_write "$READER_STORE_KEY"
            echo "[updated] ${READER_STORE_KEY} githubIdpId -> ${gh_id}"
        fi
    else
        echo "[STALE  ] ${READER_STORE_KEY}: no PAT with over ${READER_PAT_ROTATE_DAYS} days left"
        if [ "$APPLY" != "true" ]; then
            echo "[dry-run] would mint a PAT (${READER_PAT_DAYS} days) for ${READER_USER} and store it in ${READER_STORE_KEY}"
        else
            [ -n "$gh_id" ] || { echo "[FAILED ] no GitHub IdP id to store" >&2; return 1; }
            expiry="$(date -u -d "+${READER_PAT_DAYS} days" +%Y-%m-%dT%H:%M:%SZ)"
            resp="$(jq -nc --arg e "$expiry" '{expirationDate: $e}' \
                | api POST "/management/v1/users/${user_id}/pats" -d @-)"
            token="$(jq -r '.token // empty' <<< "$resp")"
            [ -n "$token" ] || { echo "[FAILED ] PAT creation returned no token" >&2; return 1; }
            # Stdin, never argv: the token is a credential.
            printf '%s' "$token" | jq -Rs --arg id "$gh_id" '{pat: ., githubIdpId: $id}' \
                | store_write "$READER_STORE_KEY" \
                || { echo "[FAILED ] PAT minted but ${READER_STORE_KEY} was not written; the next --apply mints another" >&2; return 1; }
            echo "[minted ] PAT for ${READER_USER}, expires ${expiry}, stored in ${READER_STORE_KEY}"
        fi
    fi
}

# The check that would have caught the day-long outage described at ACTION_NAME:
# a mismatch is invisible until a real user tries to log in, so it is worth
# failing the script over rather than discovering it in a browser.
assert_action_name_matches_function() {
    if ! grep -qE "^[[:space:]]*function[[:space:]]+${ACTION_NAME}[[:space:]]*\\(" "$ACTION_FILE"; then
        echo "[FAILED ] ${ACTION_FILE##*/} defines no 'function ${ACTION_NAME}('." >&2
        echo "           ZITADEL calls the function NAMED AFTER THE ACTION. If they" >&2
        echo "           disagree it stores fine and then fails every token request" >&2
        echo "           with 'action run failed: function not found'." >&2
        echo "           Found instead:" >&2
        grep -nE "^[[:space:]]*function[[:space:]]+[A-Za-z_$][A-Za-z0-9_$]*" "$ACTION_FILE" >&2 || true
        return 1
    fi
}

# -- the login policy ---------------------------------------------------------
#
# CREATING AN IDP DOES NOT ENABLE IT. This is the step whose absence produced
# "User not found" on gcp-0 while every field of the provider read correct.
#
# In ZITADEL an IdP template and the login policy are separate objects. The
# template says how to talk to Google; the LOGIN POLICY says which providers the
# login UI may offer. With the template present and the policy empty, ZITADEL
# renders no Google button, so an email typed at the login screen is resolved as
# a LOCAL username -- and on a fresh instance no such user exists. The error is
# therefore literally true and points at entirely the wrong thing: the IdP is
# fine, autoCreation is on, and the user cannot reach any of it.
#
# Nothing warns about this. `allowExternalIdp: true` is the instance default and
# stays true with zero providers attached, so the policy reads "external login
# allowed" while allowing none.
#
# INSTANCE policy (/admin/v1), matching the IdP's own scope. An org whose policy
# is still the default inherits this; an org that has overridden its login
# policy does not, and that case is reported below rather than silently assumed.
login_policy_has_idp() {
    local idp_id="$1"
    api GET /admin/v1/policies/login 2>/dev/null \
        | jq -e --arg id "$idp_id" '.policy.idps[]? | select(.idpId == $id)' >/dev/null 2>&1
}

ensure_login_policy_idp() {
    local idp_id="$1"

    if [ -z "$idp_id" ]; then
        echo "[dry-run] would add the IdP to the instance login policy"
        return 0
    fi

    if login_policy_has_idp "$idp_id"; then
        echo "[skip   ] IdP already on the instance login policy"
    elif [ "$APPLY" != "true" ]; then
        echo "[dry-run] would add IdP ${idp_id} to the instance login policy"
        return 0
    else
        jq -n --arg id "$idp_id" \
            '{idpId: $id, ownerType: "IDP_OWNER_TYPE_SYSTEM"}' \
            | api POST /admin/v1/policies/login/idps -d @- >/dev/null
        echo "[added  ] IdP ${idp_id} to the instance login policy"
    fi

    # An org that has customised its login policy does NOT inherit the instance
    # one. Report rather than guess: silently writing an org policy would create
    # the override this platform does not want.
    local is_default
    is_default="$(api GET /management/v1/policies/login 2>/dev/null | jq -r '.policy.isDefault // "unknown"')"
    if [ "$is_default" != "true" ]; then
        echo "[WARN   ] the org login policy is NOT the instance default (isDefault=${is_default})." >&2
        echo "           It will not inherit the provider added above; add it there too via" >&2
        echo "           POST /management/v1/policies/login/idps with idpId ${idp_id}" >&2
    fi
}

# ── the groups action ─────────────────────────────────────────────────────────
#
# v1 Actions are ORG-level, with no instance-level equivalent -- so unlike the
# IdP above this cannot follow the same scope. That asymmetry is ZITADEL's, not
# a choice made here.
#
# The full entry, not just the id: ListActions returns script/timeout/
# allowedToFail inline (confirmed against the API reference -- no separate GET
# needed), which is what ensure_action compares against the file on disk.
action_by_name() {
    api POST /management/v1/actions/_search -d '{"query":{}}' 2>/dev/null \
        | jq -c --arg n "$ACTION_NAME" '.result[]? | select(.name == $n)' | head -1
}

# The old version PUT the full payload on every --apply and printed "would
# UPDATE"/"[updated]" every single run, whether or not the script on disk had
# actually changed -- so a second run never reported "already correct" and
# never matched the idempotency this platform's other zitadel-*.sh scripts
# guarantee. This compares script/timeout/allowedToFail against what is
# already stored and only writes -- and only claims to have written -- on an
# actual mismatch.
ensure_action() {
    local script existing_json existing payload
    local desired_timeout="10s" desired_allowed="false"
    script="$(cat "$ACTION_FILE")"
    existing_json="$(action_by_name || true)"
    # "null" rather than "" when nothing matched -- see idp_id_by_name for why
    # re-parsing an empty string here would kill the script under errexit.
    existing="$(jq -r '.id // empty' <<< "${existing_json:-null}")"

    # allowedToFail: false. A failing Action here breaks token issuance, which
    # sounds harsh but is correct: silently issuing tokens with no groups claim
    # would authorise people at the WRONG level rather than not at all.
    payload="$(jq -n --arg n "$ACTION_NAME" --arg s "$script" \
        --arg t "$desired_timeout" --argjson f "$desired_allowed" \
        '{name: $n, script: $s, timeout: $t, allowedToFail: $f}')"

    # Everything human-readable goes to stderr, because this function's STDOUT is
    # the action id and the caller reads it through command substitution. The
    # first version printed these to stdout and they vanished into $(...) --
    # a dry run that silently reported nothing about the action at all.
    if [ -n "$existing" ]; then
        local current_script current_timeout current_allowed diffs=()
        current_script="$(jq -r '.script // empty' <<< "$existing_json")"
        current_timeout="$(jq -r '.timeout // empty' <<< "$existing_json")"
        current_allowed="$(jq -r '.allowedToFail // false' <<< "$existing_json")"

        [ "$current_script" != "$script" ] && diffs+=("script content differs from ${ACTION_FILE##*/}")
        [ "$current_timeout" != "$desired_timeout" ] && diffs+=("timeout: has ${current_timeout:-<none>}, want ${desired_timeout}")
        [ "$current_allowed" != "$desired_allowed" ] && diffs+=("allowedToFail: has ${current_allowed}, want ${desired_allowed}")

        if [ "${#diffs[@]}" -eq 0 ]; then
            echo "[ok     ] action '${ACTION_NAME}' (${existing}) matches ${ACTION_FILE##*/}" >&2
            echo "$existing"
            return 0
        fi

        local d
        echo "[STALE  ] action '${ACTION_NAME}' (${existing}):" >&2
        for d in "${diffs[@]}"; do echo "           ${d}" >&2; done
        if [ "$APPLY" != "true" ]; then
            echo "[dry-run] would UPDATE action '${ACTION_NAME}' (${existing})" >&2
            echo "$existing"
            return 0
        fi
        jq -n --argjson b "$payload" '$b' | api PUT "/management/v1/actions/${existing}" -d @- >/dev/null
        echo "[updated] action '${ACTION_NAME}' (${existing})" >&2
        echo "$existing"
        return 0
    fi

    if [ "$APPLY" != "true" ]; then
        echo "[dry-run] would create action '${ACTION_NAME}' from ${ACTION_FILE##*/}" >&2
        # A placeholder rather than the empty string, so the caller still walks
        # the flow-binding branch and a dry run shows the whole plan.
        echo "DRYRUN-ACTION"
        return 0
    fi

    local id
    id="$(jq -n --argjson b "$payload" '$b' | api POST /management/v1/actions -d @- | jq -r '.id // empty')"
    [ -n "$id" ] || { echo "[FAILED ] action creation returned no id" >&2; return 1; }
    echo "[created] action '${ACTION_NAME}' (${id})" >&2
    echo "$id"
}

# Flow 2 is CustomiseToken; 4 and 5 are PreUserinfoCreation and
# PreAccessTokenCreation. Verified against a live instance rather than taken
# from documentation: GET /management/v1/flows/2 reports
# Action.Flow.Type.CustomiseToken.
#
# BOTH triggers, because they are not interchangeable. Grafana reads the
# /userinfo response; a consumer validating the JWT itself reads the access
# token. Wiring one leaves the other silently groupless -- which presents as
# "SSO works but nobody has permissions", for only some of the tools.
#
# The old version POSTed the binding on every --apply and printed "would
# bind"/"[bound]" every run regardless of whether it was bound already --
# same non-convergent shape as the old ensure_action, and the same fix: read
# the flow once, check whether the action id is already in that trigger's
# list (GetFlow returns triggerActions[].actions[].id inline, confirmed
# against the API reference), and only POST -- and only claim to have
# written -- when it is not.
#
# SetTriggerActions REPLACES a trigger's list, so the POST sends the ids already
# bound plus this one. That is only safe if the list that was read is the real
# one: a failed GetFlow must never degrade to "nothing bound" under --apply, or
# the POST would wipe whatever was bound by hand. `{}` stands only for a
# SUCCESSFUL response that carries no flow.
ensure_flow() {
    local action_id="$1" flow trigger bound ids

    if [ "$action_id" = "DRYRUN-ACTION" ]; then
        # Nothing real to compare the flow against yet -- the action itself is
        # still only a dry-run plan.
        for trigger in 4 5; do
            echo "[dry-run] would bind action to flow 2 trigger ${trigger}"
        done
        return 0
    fi

    if ! flow="$(api GET /management/v1/flows/2 2>&1)"; then
        if [ "$APPLY" = "true" ]; then
            echo "[FAILED ] GET /management/v1/flows/2 failed: ${flow}" >&2
            echo "           not binding: the POST would replace bindings it could not read" >&2
            return 1
        fi
        echo "[WARN   ] GET /management/v1/flows/2 failed; planning as if nothing were bound" >&2
        flow='{}'
    fi
    [ -n "$flow" ] || flow='{}'

    for trigger in 4 5; do
        bound="$(jq -r --arg t "$trigger" --arg a "$action_id" \
            '.flow.triggerActions[]? | select(.triggerType.id == $t) | .actions[]?.id | select(. == $a)' \
            <<< "$flow")"
        if [ -n "$bound" ]; then
            echo "[ok     ] flow 2 (CustomiseToken) trigger ${trigger}: action already bound"
            continue
        fi

        echo "[STALE  ] flow 2 (CustomiseToken) trigger ${trigger}: has action not bound, want ${action_id} bound"
        if [ "$APPLY" != "true" ]; then
            echo "           would bind it"
            continue
        fi
        ids="$(jq -c --arg t "$trigger" --arg a "$action_id" \
            '[.flow.triggerActions[]? | select(.triggerType.id == $t) | .actions[]?.id] + [$a]' <<< "$flow")"
        jq -n --argjson ids "$ids" '{actionIds: $ids}' \
            | api POST "/management/v1/flows/2/trigger/${trigger}" -d @- >/dev/null
        echo "[bound  ] flow 2 (CustomiseToken) trigger ${trigger}"
    done
}

# ── main ──────────────────────────────────────────────────────────────────────

echo "cluster:  ${CLUSTER} (${CLOUD})"
echo "idp:      ${IDP_URL}"
echo "scope:    instance (/admin/v1) for the IdP, org (/management/v1) for the action"
echo

ensure_idp
ensure_github_idp

# Re-read rather than threading a return value out of ensure_idp: that function
# has several exit paths (ok / stale dry-run / stale updated / create dry-run /
# created) and reports the id inconsistently across them. Looking it up once
# here is the same answer in every case.
ensure_login_policy_idp "$(idp_id_by_name || true)"
if [ "$GITHUB_ENABLED" = "true" ]; then
    GITHUB_IDP_ID="$(idp_id_by_name "$GITHUB_IDP_NAME" || true)"
    ensure_login_policy_idp "$GITHUB_IDP_ID"
fi

# Fails the run if the action name and the JS function disagree -- see ACTION_NAME.
assert_action_name_matches_function

ACTION_ID="$(ensure_action | tail -1)"
if [ -n "$ACTION_ID" ]; then
    ensure_flow "$ACTION_ID" || exit 1
elif [ "$APPLY" = "true" ]; then
    echo "[FAILED ] no action id; flow not wired" >&2
    exit 1
fi

if [ "$GITHUB_ENABLED" = "true" ]; then
    ensure_broker_reader "$GITHUB_IDP_ID" || exit 1
    echo
    echo "GitHub-side, once per ZITADEL (an OAuth App takes exactly one callback URL):"
    echo "  ${IDP_URL}/ui/login/login/externalidp/callback"
fi

echo
echo "Google-side, once per cluster -- this script cannot do it:"
echo "  add this to the OAuth client's Authorized redirect URIs"
echo "    ${IDP_URL}/ui/login/login/externalidp/callback"
echo
if [ "$APPLY" != "true" ]; then
    echo "This was a DRY RUN. Re-run with --apply."
fi
