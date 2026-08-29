#!/usr/bin/env bash
# Repo-wide guard against the argv-leak class fixed in zitadel-idp.sh,
# zitadel-oidc-clients.sh, secret-store.sh and openbao-config.sh (also fixed,
# at the time, in harbor-oidc.sh -- since removed in favour of a declarative
# CONFIG_OVERWRITE_JSON, ADR-0028): a secret handed to jq via
# --arg/--argjson lands on jq's argv, readable by any process on the box via
# /proc/<pid>/cmdline for as long as jq runs.
#
# Each fixed site also has its own file-scoped assertion (grepping for the
# EXACT flag/variable name that leaked, in test-zitadel-idp-convergence.sh
# and test-zitadel-oidc-clients-secrets.sh) -- necessary because a
# functional round-trip test cannot tell "went in via stdin" from "went in
# via --arg" apart; both produce byte-identical JSON. Those are file-scoped
# by construction, and that is exactly how zitadel-oidc-clients.sh's three
# leaks went unnoticed while the other two scripts were being fixed: the
# guard only ever looked at the file someone had already opened.
#
# This is the pattern-level guard instead: it scans every scripts/*.sh for a
# jq --arg/--argjson whose VALUE is a variable with a credential-shaped NAME,
# so a script making the same mistake with a differently-named variable is
# still caught -- not just a byte-for-byte repeat of a site already found.
#
# KNOWN GAP, not silently: this only recognises a plain `"$var"`/"${var}"`
# value. `--arg p "$(gen_password)"` and `--arg ck "$(openssl rand ...)"` --
# both real, both found and fixed by hand in this same session
# (secret-store.sh's seed_body, openbao-config.sh's root token/recovery
# keys) -- bind no named variable at all, so there is no name here to judge.
# Flagging every `$(...)` on an --arg was tried and rejected: most of them
# are ordinary (a timestamp, a resolved id) and the false-positive rate
# would make the guard noise people learn to ignore. This catches the named-
# variable shape reliably; it is not a proof that no argv leak exists.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
fail=0

# Case-insensitive, whole underscore-separated token: a name matches if ANY
# part of it (split on "_") equals one of these words. "key"/"keys" is broad
# -- generic enough that a future script naming an ordinary map key
# `--arg key ...` would trip it -- but it is what caught OpenBao's
# recovery_keys (Shamir key material, not a password or a token) during this
# guard's own development, with zero false positives anywhere else in the
# repo at the time it was added. Loosen it if that changes.
CRED_TOKENS="secret|password|passwd|token|credential|cookie|pat|apikey|privatekey|key|keys"

is_cred_shaped() { # $1: variable name
    local part
    IFS='_' read -ra parts <<< "${1,,}"
    for part in "${parts[@]}"; do
        [[ "$part" =~ ^(${CRED_TOKENS})$ ]] && return 0
    done
    return 1
}

while IFS= read -r -d '' file; do
    rel="scripts/${file#"$HERE"/}"
    while IFS=: read -r lineno line; do
        [ -z "${lineno:-}" ] && continue
        # Skip comment lines -- a fix's own explanation quoting the old,
        # now-removed pattern verbatim as documentation is not a leak (same
        # convention this repo's other file-scoped argv-leak assertions use,
        # e.g. test-zitadel-oidc-clients-secrets.sh's code_grep).
        [[ "$line" =~ ^[[:space:]]*# ]] && continue

        # A source line can carry more than one --arg/--argjson (e.g.
        # `--arg id "$a" --arg sec "$b"` on the same line), so extract every
        # occurrence rather than just the first.
        while IFS= read -r hit; do
            [ -z "$hit" ] && continue
            varname="$(sed -E 's/.*"\$\{?([A-Za-z_][A-Za-z0-9_]*).*/\1/' <<< "$hit")"
            if is_cred_shaped "$varname"; then
                printf '  FAIL %s:%s: jq --arg/--argjson exposes credential-shaped $%s on argv\n' \
                    "$rel" "$lineno" "$varname"
                fail=1
            fi
        done < <(grep -oE -- \
            '--arg(json)?[[:space:]]+[A-Za-z0-9_]+[[:space:]]+"\$\{?[A-Za-z_][A-Za-z0-9_]*[^"]*"' \
            <<< "$line")
    done < <(grep -nE -- '--arg(json)?[[:space:]]' "$file")
done < <(find "$HERE" -maxdepth 1 -name '*.sh' -print0; find "$HERE/lib" -maxdepth 1 -name '*.sh' -print0)

if [ "$fail" -eq 0 ]; then
    echo "  ok   no scripts/*.sh passes a credential-shaped variable to jq --arg/--argjson"
fi
exit "$fail"
