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
#   4. Uploads scripts/zitadel-actions/groups-from-roles.js as a v1 Action.
#   5. Wires that Action into flow 2 (CustomiseToken) on BOTH triggers.
#
# Usage:
#   zitadel-idp.sh sync --cluster gcp-0 --cloud gcp [--project ID] [--apply]
#   zitadel-idp.sh sync --cluster aws-0 --cloud aws [--region R]  [--apply]
#
# Dry-run unless --apply. The client secret is never printed.
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

PAT="$(resolve_zitadel_pat)" || exit 1

: "${IDP_URL:?set IDP_URL to the ZITADEL base URL, e.g. https://auth.gcp.cloud.ogenki.io}"

# Same split-DNS escape hatch as zitadel-oidc-clients.sh: pins the host for curl
# only, keeping SNI and certificate verification intact.
CURL_RESOLVE=()
[ -n "${IDP_RESOLVE:-}" ] && CURL_RESOLVE=(--resolve "$IDP_RESOLVE")

api() {
    local method="$1" path="$2"
    shift 2
    curl -fsS -X "$method" "${IDP_URL}${path}" \
        ${CURL_RESOLVE[@]+"${CURL_RESOLVE[@]}"} \
        -H "Authorization: Bearer ${PAT}" \
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
        | jq -c --arg n "$IDP_NAME" '.result[]? | select(.name == $n)' | head -1
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
    template="$(idp_template_by_name || true)"
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

    blob="$(store_read "$IDP_SECRET_KEY")"
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
ensure_flow() {
    local action_id="$1" flow trigger bound

    if [ "$action_id" = "DRYRUN-ACTION" ]; then
        # Nothing real to compare the flow against yet -- the action itself is
        # still only a dry-run plan.
        for trigger in 4 5; do
            echo "[dry-run] would bind action to flow 2 trigger ${trigger}"
        done
        return 0
    fi

    flow="$(api GET /management/v1/flows/2 2>/dev/null || true)"
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
        jq -n --arg a "$action_id" '{actionIds: [$a]}' \
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

# Re-read rather than threading a return value out of ensure_idp: that function
# has several exit paths (ok / stale dry-run / stale updated / create dry-run /
# created) and reports the id inconsistently across them. Looking it up once
# here is the same answer in every case.
ensure_login_policy_idp "$(idp_id_by_name || true)"

# Fails the run if the action name and the JS function disagree -- see ACTION_NAME.
assert_action_name_matches_function

ACTION_ID="$(ensure_action | tail -1)"
if [ -n "$ACTION_ID" ]; then
    ensure_flow "$ACTION_ID"
elif [ "$APPLY" = "true" ]; then
    echo "[FAILED ] no action id; flow not wired" >&2
    exit 1
fi

echo
echo "Google-side, once per cluster -- this script cannot do it:"
echo "  add this to the OAuth client's Authorized redirect URIs"
echo "    ${IDP_URL}/ui/login/login/externalidp/callback"
echo
if [ "$APPLY" != "true" ]; then
    echo "This was a DRY RUN. Re-run with --apply."
fi
