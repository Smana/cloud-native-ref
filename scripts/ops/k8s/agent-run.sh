#!/usr/bin/env bash
# Creates one AgentRun (SP1). Until SP3's factory ships, the owner creates runs
# directly (C3), so this script is the creator: it generates the runId (C2).
#
# usage: agent-run.sh --role <implementer|reviewer|tester|triager> --class <public|internal>
#                     (--task "<text>" | --task-url <issue or PR URL>)
#                     [--repo <owner/name>] [--branch agent/<id>] [--size small|medium|large]
#                     [--minutes <1-480>] [--profiles pypi,npm,golang,crates] [--dry-run]
# AGENT_PRINCIPAL overrides the principal (default: human:<git user.email>).
set -euo pipefail

repo=Smana/cloud-native-ref role="" class="" task="" url="" branch="" size=small minutes=120 profiles="" dry=""
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) repo=$2; shift 2 ;;
    --role) role=$2; shift 2 ;;
    --class) class=$2; shift 2 ;;
    --task) task=$2; shift 2 ;;
    --task-url) url=$2; shift 2 ;;
    --branch) branch=$2; shift 2 ;;
    --size) size=$2; shift 2 ;;
    --minutes) minutes=$2; shift 2 ;;
    --profiles) profiles=$2; shift 2 ;;
    --dry-run) dry="--dry-run=server"; shift ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
# No default data class: classifying data is a decision (design §2).
if [ -z "$role" ] || [ -z "$class" ]; then
  echo "--role and --class are required" >&2; exit 2
fi
if { [ -n "$task" ] && [ -n "$url" ]; } || { [ -z "$task" ] && [ -z "$url" ]; }; then
  echo "give exactly one of --task or --task-url" >&2; exit 2
fi
principal="${AGENT_PRINCIPAL:-human:$(git config user.email)}"
run_id="$(python3 -c 'import secrets; print("".join(secrets.choice("abcdefghijklmnopqrstuvwxyz234567") for _ in range(8)))')"

# JSON, not YAML: task text passes through unescaped by the shell.
claim="$(RUN_ID="$run_id" REPO="$repo" ROLE="$role" CLASS="$class" TASK="$task" URL="$url" \
  BRANCH="$branch" SIZE="$size" MINUTES="$minutes" PROFILES="$profiles" PRINCIPAL="$principal" python3 -c '
import json, os
e = os.environ
spec = {"role": e["ROLE"], "repository": e["REPO"], "principal": e["PRINCIPAL"], "dataClass": e["CLASS"],
        "size": e["SIZE"], "budget": {"maxMinutes": int(e["MINUTES"])},
        "task": {"text": e["TASK"]} if e["TASK"] else {"url": e["URL"]}}
if e["BRANCH"]:
    spec["branch"] = e["BRANCH"]
if e["PROFILES"]:
    spec["egress"] = {"profiles": e["PROFILES"].split(",")}
print(json.dumps({"apiVersion": "cloud.ogenki.io/v1alpha1", "kind": "AgentRun",
                  "metadata": {"name": "xplane-run-" + e["RUN_ID"], "namespace": "agents"}, "spec": spec}))')"

# $dry is empty or one flag; unquoted on purpose.
# shellcheck disable=SC2086
printf '%s\n' "$claim" | kubectl apply $dry -f -
echo "xplane-run-$run_id"
