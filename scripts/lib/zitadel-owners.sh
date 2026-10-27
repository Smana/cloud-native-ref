#!/usr/bin/env bash
# Read the owners list (scripts/provision/zitadel-owners.yaml) as JSON, for
# zitadel-oidc-clients.sh (grants) and zitadel-idp.sh (GitHub links). Sourced.
#
# owners_json FILE prints a compact JSON array of {loginName, githubLogin, roles}
# and returns 1, saying why on stderr, when the file is unreadable or an entry is
# malformed. Role names are checked by the caller, which owns the role list.
# yq (mikefarah) is used when present, else python3 with PyYAML.

owners_json() {
    local file="${1:-}" raw
    [ -r "$file" ] || { echo "cannot read the owners file: ${file}" >&2; return 1; }
    if command -v yq >/dev/null 2>&1; then
        raw="$(yq -o=json '.owners // []' "$file" 2>&1)" || { echo "cannot parse ${file}: ${raw}" >&2; return 1; }
    elif command -v python3 >/dev/null 2>&1; then
        raw="$(python3 -c 'import json,sys,yaml; print(json.dumps((yaml.safe_load(open(sys.argv[1])) or {}).get("owners") or []))' "$file" 2>&1)" \
            || { echo "cannot parse ${file}: ${raw}" >&2; return 1; }
    else
        echo "reading ${file} needs yq or python3 with PyYAML" >&2; return 1
    fi
    jq -ce '
        def ok: (.loginName | type == "string" and length > 0)
            and (.githubLogin | type == "string" and test("^[A-Za-z0-9]([A-Za-z0-9-]{0,38})$"))
            and ((.roles // []) | type == "array" and all(.[]; type == "string" and length > 0));
        if type == "array" and all(.[]; type == "object" and ok)
        then map({loginName, githubLogin, roles: (.roles // [])})
        else error("each owner needs a loginName, a GitHub login and a list of roles")
        end' <<< "$raw" 2>&1 \
        || { echo "invalid owners file ${file}" >&2; return 1; }
}
