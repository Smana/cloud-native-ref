#!/usr/bin/env bash
# shellcheck disable=SC2034
# (APPLY, CLUSTER and the OIDC_CONSUMER_* knobs are read by function bodies
# eval'd out of the script, which static analysis cannot see.)
#
# After a rotation, the Deployments that read a client id from env at start must
# restart, or they keep the dead directory's client ("App not found" from
# headlamp-oauth2-proxy). Restarts only the readers of a rotated key's Secret,
# only once that Secret carries the new id, and only with kubectl on $CLUSTER.
# A HelmRelease rendering the Secret through valuesFrom (flux-ui) is waited for
# instead: its release must carry the new value and its Deployment finish rolling.
# The functions are lifted out of the script, so this tests the code that ships.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
cd "$REPO_ROOT" || exit 1
S="${ZITADEL_OIDC_CLIENTS_SCRIPT:-scripts/provision/zitadel-oidc-clients.sh}"
fail=0
ok()  { printf '  ok   %s\n' "$1"; }
bad() { printf '  FAIL %s\n' "$1"; fail=1; }

for f in stored_client_id secret_sha secret_carries helm_release_carries roll_rotated_helm_releases restart_rotated_consumers; do
    body="$(sed -n "/^${f}() {/,/^}/p" "$S")"
    [ -n "$body" ] || { echo "could not extract ${f}() from $S" >&2; exit 1; }
    eval "$body"
done
# shellcheck source=scripts/lib/bao-map.sh
. "$REPO_ROOT/scripts/lib/bao-map.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
sleep() { :; }

# Two ExternalSecrets: one from the managed store under the bare key (unmapped),
# one from OpenBao at the key's mapped path.
cat >"$T/es.json" <<'EOF'
{"items":[
 {"metadata":{"namespace":"tooling","name":"headlamp-oauth2-proxy"},
  "spec":{"secretStoreRef":{"name":"clustersecretstore"},
          "dataFrom":[{"extract":{"key":"headlamp-oauth2-proxy"}}],
          "target":{"name":"headlamp-oauth2-proxy"}}},
 {"metadata":{"namespace":"observability","name":"grafana-es"},
  "spec":{"secretStoreRef":{"name":"openbao-platform"},
          "dataFrom":[{"extract":{"key":"victoria-metrics/grafana-envvars"}}],
          "target":{"name":"grafana-envvars"}}},
 {"metadata":{"namespace":"flux-system","name":"flux-ui-oidc"},
  "spec":{"secretStoreRef":{"name":"openbao-platform"},
          "dataFrom":[{"extract":{"key":"flux/ui-oidc"}}],
          "target":{"name":"flux-ui-oidc"}}}
]}
EOF
# The flux-operator release reads flux-ui-oidc through valuesFrom, and its pod
# reads the rendered config from a volume: no Deployment names the Secret.
cat >"$T/hr.json" <<'EOF'
{"items":[
 {"metadata":{"namespace":"flux-system","name":"flux-operator"},
  "spec":{"releaseName":"flux-operator","valuesFrom":[
    {"kind":"Secret","name":"flux-ui-oidc","valuesKey":"clientID"},
    {"kind":"Secret","name":"flux-ui-oidc","valuesKey":"clientSecret"}]}}
]}
EOF
# Readers by env and by envFrom, a bystander, and a volume mount (not env).
cat >"$T/deploy.json" <<'EOF'
{"items":[
 {"metadata":{"name":"headlamp-oauth2-proxy"},"spec":{"template":{"spec":{"containers":[
   {"env":[{"name":"OAUTH2_PROXY_CLIENT_ID","valueFrom":{"secretKeyRef":{"name":"headlamp-oauth2-proxy","key":"client-id"}}}]}]}}}},
 {"metadata":{"name":"grafana"},"spec":{"template":{"spec":{"containers":[
   {"envFrom":[{"secretRef":{"name":"grafana-envvars"}}]}]}}}},
 {"metadata":{"name":"headlamp"},"spec":{"template":{"spec":{"containers":[
   {"envFrom":[{"secretRef":{"name":"headlamp-envvars"}}]}]}}}},
 {"metadata":{"name":"mounts-it"},"spec":{"template":{"spec":{"containers":[{}]}}}},
 {"metadata":{"name":"flux-operator","annotations":{"meta.helm.sh/release-name":"flux-operator"}},
  "spec":{"template":{"spec":{"containers":[{}]}}}}
]}
EOF
jq '.items[3].spec.template.spec.volumes = [{secret: {secretName: "headlamp-oauth2-proxy"}}]' "$T/deploy.json" > "$T/d.json" && mv "$T/d.json" "$T/deploy.json"  # pragma: allowlist secret

CM="gke-gcp-0-vars"
SECRET_ID="new-id"
SECRET_VAL="new-secret"  # pragma: allowlist secret
# What the deployed flux-operator release was rendered with: Helm stores it
# gzipped and base64'd, and the Secret's data base64s it again.
REL_ID="new-id"
REL_SECRET="new-secret"  # pragma: allowlist secret
ROLLOUT_RC=0
kubectl() {
    printf '%s\n' "$*" >>"$T/calls"
    case "$1 $2" in
        "get configmap") printf 'configmap/%s\n' "$CM" ;;
        "get externalsecrets") cat "$T/es.json" ;;
        "get helmreleases.helm.toolkit.fluxcd.io") cat "$T/hr.json" ;;
        "get secret") if [[ "$*" == *owner=helm* ]]; then
                          jq -n --arg r "$(printf '%s' "$REL_SECRET" | jq -Rs --arg i "$REL_ID" \
                              '{config: {web: {config: {authentication: {oauth2: {clientID: $i, clientSecret: .}}}}}}' \
                              | gzip | base64 -w0 | base64 -w0)" \
                              '{items: [{metadata: {labels: {version: "3"}}, data: {release: $r}}]}'
                          return
                      fi
                      jq -n --arg v "$(printf '%s' "$SECRET_ID" | base64)" --arg s "$(printf '%s' "$SECRET_VAL" | base64)" \
                          '{data:{"client-id":$v,GF_AUTH_GENERIC_OAUTH_CLIENT_ID:$v,"client-secret":$s}}' ;;
        "get deployments") cat "$T/deploy.json" ;;
        "rollout status") return "$ROLLOUT_RC" ;;
        *) : ;;
    esac
}
run() { : >"$T/calls"; restart_rotated_consumers "$@" >"$T/out" 2>&1; }
restarts() { grep '^rollout restart' "$T/calls" | sort | tr '\n' ';'; }

APPLY=true CLUSTER=gcp-0
OIDC_CONSUMER_WAIT_SECONDS=60

# stored_client_id reads every consumer's field name.
for blob in '{"GF_AUTH_GENERIC_OAUTH_CLIENT_ID":"a"}' '{"OIDC_CLIENT_ID":"a"}' '{"clientID":"a"}' \
            '{"client_id":"a"}' '{"client-id":"a","client-secret":"s"}'; do
    [ "$(stored_client_id <<< "$blob")" = a ] && ok "stored_client_id: ${blob%%:*}}" \
        || bad "stored_client_id on $blob"
done
[ -z "$(stored_client_id <<< '{"other":"x"}')" ] && ok "stored_client_id: empty when none" || bad "stored_client_id invented an id"

run 'headlamp-oauth2-proxy=new-id'
[ "$(restarts)" = "rollout restart deployment headlamp-oauth2-proxy -n tooling;" ] \
    && ok "unmapped key: only its env reader restarts" || bad "unmapped key restarts: $(restarts)"
grep -q '^annotate externalsecret headlamp-oauth2-proxy -n tooling force-sync=' "$T/calls" \
    && ok "its ExternalSecret is force-synced first" || bad "no force-sync: $(cat "$T/calls")"

run 'observability-victoria-metrics-k8s-stack-grafana-envvars=new-id'
grep -q '^rollout restart deployment grafana -n observability$' "$T/calls" \
    && ok "mapped key: the envFrom reader restarts" || bad "mapped key restarts: $(restarts)"

run
[ ! -s "$T/calls" ] && ok "nothing rotated: no kubectl call" || bad "called kubectl with nothing rotated: $(cat "$T/calls")"

APPLY=false run 'headlamp-oauth2-proxy=new-id'
[ ! -s "$T/calls" ] && ok "dry run: no kubectl call" || bad "dry run called kubectl: $(cat "$T/calls")"

CM="eks-aws-0-vars" run 'headlamp-oauth2-proxy=new-id'
[ -z "$(restarts)" ] && grep -q 'does not point at gcp-0' "$T/out" \
    && ok "kubectl on another cluster: warns, restarts nothing" || bad "wrong context: $(restarts) $(cat "$T/out")"

SECRET_ID="old-id" OIDC_CONSUMER_WAIT_SECONDS=0 run 'headlamp-oauth2-proxy=new-id'
[ -z "$(restarts)" ] && grep -q 'does not carry client new-id' "$T/out" \
    && ok "Secret not refreshed: no restart onto the old id" || bad "stale Secret: $(restarts) $(cat "$T/out")"

# A secret rotated under an unchanged id is waited for by its sha256, never by value.
NEW_SHA="$(printf '%s' new-secret | secret_sha)"
run "headlamp-oauth2-proxy=sha256:${NEW_SHA}"
[ "$(restarts)" = "rollout restart deployment headlamp-oauth2-proxy -n tooling;" ] && grep -q 'carries the rotated client secret' "$T/out" \
    && ok "rotated secret: its reader restarts once the Secret carries it" || bad "rotated secret restarts: $(restarts) $(cat "$T/out")"
SECRET_VAL="old-secret" OIDC_CONSUMER_WAIT_SECONDS=0 run "headlamp-oauth2-proxy=sha256:${NEW_SHA}"  # pragma: allowlist secret
[ -z "$(restarts)" ] && grep -q 'does not carry the rotated client secret' "$T/out" \
    && ok "rotated secret not refreshed: no restart onto the old one" || bad "stale secret: $(restarts) $(cat "$T/out")"

# flux-ui: nothing to restart by env; the release re-renders and rolls its pod.
run 'security-flux-ui-oidc=new-id'
grep -q '^annotate helmrelease flux-operator -n flux-system reconcile.fluxcd.io/requestedAt=' "$T/calls" \
    && ok "flux-ui: its HelmRelease is asked to reconcile" || bad "flux-ui: no reconcile request: $(cat "$T/calls")"
grep -q '^rollout status deployment flux-operator -n flux-system --timeout=' "$T/calls" && [ -z "$(restarts)" ] \
    && grep -q '^\[rolled \] deployment flux-system/flux-operator -- helmrelease flux-system/flux-operator renders client new-id' "$T/out" \
    && ok "flux-ui: waits for the release's Deployment to roll, restarts nothing" || bad "flux-ui: $(restarts) $(cat "$T/out")"
run "security-flux-ui-oidc=sha256:${NEW_SHA}"
grep -q 'flux-operator renders the rotated client secret' "$T/out" \
    && ok "flux-ui: a rotated secret is matched in the release values by sha256" || bad "flux-ui sha: $(cat "$T/out")"
REL_SECRET="old-secret" OIDC_CONSUMER_WAIT_SECONDS=0 run "security-flux-ui-oidc=sha256:${NEW_SHA}"  # pragma: allowlist secret
! grep -q '^rollout status' "$T/calls" && grep -q 'helmrelease flux-system/flux-operator has not rendered the rotated client secret yet' "$T/out" \
    && ok "flux-ui: a release still on the old secret warns, waits for no rollout" || bad "flux-ui stale release: $(cat "$T/out")"
ROLLOUT_RC=1 run 'security-flux-ui-oidc=new-id'
grep -q 'flux-system/flux-operator has not finished rolling onto client new-id' "$T/out" \
    && ok "flux-ui: an unfinished rollout warns" || bad "flux-ui rollout: $(cat "$T/out")"
ROLLOUT_RC=0

grep -A1 '^    force_sync_mirrored "' "$S" | grep -q 'restart_rotated_consumers' \
    && ok "cmd_sync restarts right after the force-sync" || bad "restart_rotated_consumers not wired after force_sync_mirrored"

exit "$fail"
