#!/usr/bin/env bash
# Asks the agent factory for one AgentRun (SP3 §4). Since SP3 the factory is the only creator
# (C3): it derives the branch, and the principal is your ZITADEL identity, proven by the token
# `roomctl token` prints (run `roomctl login` once). The body never names the principal; it names
# a branch only to resume a run the stop object ended (--branch agent/<runId>, R35).
#
# usage: agent-run.sh --role <implementer|reviewer|tester|triager> --class <public|internal>
#                     (--task "<text>" | --task-url <issue or PR URL>)
#                     [--repo <owner/name>] [--room <roomId>] [--base-ref <ref>] [--model <name>]
#                     [--max-tokens <n>] [--profiles pypi,npm,golang,crates] [--branch agent/<id>] [--dry-run]
# internal runs and triagers are for agents-admin (R37).
# AGENT_FACTORY_URL (default https://factory.priv.aws.ogenki.io) and AGENT_FACTORY_CA (default
# the private CA under opentofu/aws/openbao/management/.tls) select the endpoint.
# Only the run id goes to stdout; the branch and next steps go to stderr.
set -euo pipefail

repo=Smana/cloud-native-ref role="" class="" task="" url="" room="" base="" model="" tokens="" profiles="" dry="" resume=""
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) repo=$2; shift 2 ;;
    --role) role=$2; shift 2 ;;
    --class) class=$2; shift 2 ;;
    --task) task=$2; shift 2 ;;
    --task-url) url=$2; shift 2 ;;
    --room) room=$2; shift 2 ;;
    --base-ref) base=$2; shift 2 ;;
    --model) model=$2; shift 2 ;;
    --max-tokens) tokens=$2; shift 2 ;;
    --profiles) profiles=$2; shift 2 ;;
    --dry-run) dry=1; shift ;;
    --branch)
      [[ "$2" =~ ^agent/[a-z2-7]{8}$ ]] || { echo "--branch resumes a stopped run: agent/<its 8-character id>" >&2; exit 2; }
      resume=$2; shift 2 ;;
    --minutes|--size)
      echo "$1 is gone: the factory sizes the run (SP3)" >&2; exit 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
if [ -z "$role" ] || [ -z "$class" ]; then
  echo "--role and --class are required (no default data class: classifying data is a decision)" >&2; exit 2
fi
if { [ -n "$task" ] && [ -n "$url" ]; } || { [ -z "$task" ] && [ -z "$url" ]; }; then
  echo "give exactly one of --task or --task-url" >&2; exit 2
fi

body="$(REPO="$repo" ROLE="$role" CLASS="$class" TASK="$task" URL="$url" ROOM="$room" BASE="$base" \
  MODEL="$model" TOKENS="$tokens" PROFILES="$profiles" RESUME="$resume" jq -n '
  {role: env.ROLE, repository: env.REPO, dataClass: env.CLASS,
   task: (if env.TASK != "" then {text: env.TASK} else {url: env.URL} end)}
  + (if env.ROOM != "" then {roomRef: env.ROOM} else {} end)
  + (if env.BASE != "" then {baseRef: env.BASE} else {} end)
  + (if env.MODEL != "" then {model: env.MODEL} else {} end)
  + (if env.TOKENS != "" then {maxTokens: (env.TOKENS | tonumber)} else {} end)
  + (if env.PROFILES != "" then {egressProfiles: (env.PROFILES | split(","))} else {} end)
  + (if env.RESUME != "" then {resumeBranch: env.RESUME} else {} end)')"
if [ -n "$dry" ]; then
  printf '%s\n' "$body" >&2
  exit 0
fi

endpoint="${AGENT_FACTORY_URL:-https://factory.priv.aws.ogenki.io}/v1/runs"
ca="${AGENT_FACTORY_CA:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/opentofu/aws/openbao/management/.tls/ca.pem}"
# Without the trap, a missing roomctl or a logged-out session aborts raw under set -e
# (bash's own error, or an empty-token 401); say what to run instead, as the 401 handler does.
token="$(roomctl token)" || { echo "not authenticated: run roomctl login" >&2; exit 1; }
auth_hdr="Authorization: Bearer $token"  # argv-ok: roomctl's own short-lived token, issued per-process; not a credential leak
resp="$(printf '%s' "$body" | curl -sS --cacert "$ca" -X POST "$endpoint" \
  -H "$auth_hdr" -H "Content-Type: application/json" \
  --data-binary @- -w '\n%{http_code}')"
code="${resp##*$'\n'}"
json="${resp%$'\n'*}"
case "$code" in
  201) ;;
  429) echo "refused: your daily token budget for runs is spent (resets at 00:00 UTC)" >&2; exit 1 ;;
  403) echo "refused: $(jq -r .error <<<"$json") (agents group, admin-only internal or triager, repository allowlist, a task's branch, or not your room)" >&2; exit 1 ;;
  409) echo "refused: $(jq -r .error <<<"$json"): a running run already holds that room or branch" >&2; exit 1 ;;
  401) echo "refused: not authenticated; run roomctl login" >&2; exit 1 ;;
  *) echo "refused ($code): $(jq -r '.error // .' <<<"$json")" >&2; exit 1 ;;
esac
run="$(jq -r .runId <<<"$json")"
branch="$(jq -r .branch <<<"$json")"
printf 'agent-run: run %s on %s; watch it with kubectl get agentrun -n agents xplane-run-%s -w%s\n' \
  "$run" "$branch" "$run" "${room:+, or in the room https://rooms.priv.aws.ogenki.io/r/$room}" >&2
echo "$run"
