# agent-harness

The AgentRun sandbox's harness (SP1 design §5): `ghcr.io/openhands/agent-server:1.49.5-python` plus

| File | Role |
|---|---|
| `agent_run.py` → `agent-run` | Entrypoint: start agent-server, clone and resume `$BRANCH`, POST the conversation, wait, revoke, exit 0/1 |
| `git_credential_agent.py` → `git-credential-agent` | git credential helper; exchanges through identity-proxy `:4001`, caches in memory, `revoke` on exit and in `preStop` |
| `gh` | gh with that token in `GH_TOKEN` |
| `commit-msg` | adds `Agent-Run: $RUN_ID` |

The harness never holds a gateway or octo-sts token: identity-proxy injects them. Test with
`docker build --target test .`; `./build.sh` tests then builds.
