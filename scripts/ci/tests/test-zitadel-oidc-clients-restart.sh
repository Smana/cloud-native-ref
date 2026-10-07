#!/usr/bin/env bash
# shellcheck disable=SC2034
# (APPLY, CLUSTER and the OIDC_CONSUMER_* knobs are read by function bodies
# eval'd out of the script, which static analysis cannot see.)
#
# After a rotation, the Deployments that read a client id from env at start must
# restart, or they keep the dead directory's client ("App not found" from
# headlamp-oauth2-proxy). Restarts only the readers of a rotated key's Secret,
# only once that Secret carries the new id, and only with kubectl on $CLUSTER.
# The functions are lifted out of the script, so this tests the code that ships.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
cd "$REPO_ROOT" || exit 1
S="${ZITADEL_OIDC_CLIENTS_SCRIPT:-scripts/provision/zitadel-oidc-clients.sh}"
fail=0
ok()  { printf '  ok   %s\n' "$1"; }
bad() { printf '  FAIL %s\n' "$1"; fail=1; }

for f in stored_client_id restart_rotated_consumers; do
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
          "target":{"name":"grafana-envvars"}}}
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
 {"metadata":{"name":"mounts-it"},"spec":{"template":{"spec":{"containers":[{}]}}}}
]}
EOF
jq '.items[3].spec.template.spec.volumes = [{secret: {secretName: "headlamp-oauth2-proxy"}}]' "$T/deploy.json" > "$T/d.json" && mv "$T/d.json" "$T/deploy.json"  # pragma: allowlist secret

CM="gke-gcp-0-vars"
SECRET_ID="new-id"
kubectl() {
    printf '%s\n' "$*" >>"$T/calls"
    case "$1 $2" in
        "get configmap") printf 'configmap/%s\n' "$CM" ;;
        "get externalsecrets") cat "$T/es.json" ;;
        "get secret") jq -n --arg v "$(printf '%s' "$SECRET_ID" | base64)" '{data:{"client-id":$v,GF_AUTH_GENERIC_OAUTH_CLIENT_ID:$v}}' ;;
        "get deployments") cat "$T/deploy.json" ;;
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

grep -A1 '^    force_sync_mirrored "' "$S" | grep -q 'restart_rotated_consumers' \
    && ok "cmd_sync restarts right after the force-sync" || bad "restart_rotated_consumers not wired after force_sync_mirrored"

exit "$fail"
