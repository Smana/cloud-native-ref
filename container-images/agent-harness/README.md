# agent-harness

The AgentRun sandbox's harness (SP1 design §5): `ghcr.io/openhands/agent-server:1.49.6-python` plus

| File | Role |
|---|---|
| `agent_run.py` → `agent-run` | Entrypoint: start agent-server, clone and resume `$BRANCH`, POST the conversation, wait, revoke, exit 0/1. On SIGTERM, within 15 s: pause, checkpoint an implementer's work (`Agent-Checkpoint: disruption`; never a GitHub token, never over 200 files or 5 MiB), the room-bridge's final read, stop, revoke. A SIGTERM after the run ended keeps its exit code |
| `git_credential_agent.py` → `git-credential-agent` | git credential helper; exchanges through identity-proxy `:4001`, caches in memory; `agent-run` calls its `revoke` on exit |
| `gh` | gh with that token in `GH_TOKEN`; `gh pr create` (or `new`) then appends the provenance footer (`pr_footer.py`, SP2 design §5) |
| `commit-msg` | adds `Agent-Run: $RUN_ID`, `Agent-Task: $TASK_ID` when set, and `Agent-Checkpoint: disruption` on agent-run's SIGTERM checkpoint |
| `site/sitecustomize.py` | agent-server's start-up hook (F29): a 4xx to the MCP client's reply to a server `ping` is logged instead of ending the session (envoyproxy/ai-gateway#2715) |

The `Agent-*` namespace is the harness's. In a commit message or a PR body, any line the model wrote that
starts with an `agent-…:` key, in any case and after any line break a renderer honours, is prefixed
`(agent-written) ` before the real values are added last. The footer is always the last paragraph:

```text
---
Agent-Room: $ROOM_ID
Agent-Run: $RUN_ID
Agent-Role: $ROLE
Agent-Task: $TASK_ID
Agent-Task-URL: $TASK_URL
Agent-Model: $MODEL
```

`Agent-Task` is the task id and `Agent-Task-URL` the issue or PR (SP3 ruling SW). A value that is empty, over 256
characters or holds a control character or line separator is left out, and `Agent-Task-URL` must be an
`https://github.com/` URL. If the footer cannot be written, `gh pr create` exits 1.

Trailers and footer are provenance hints, never authorisation (SP3 ruling TB). An agent with a shell can skip
or rewrite the hook, and `gh api` or a later `gh pr edit` bypasses the footer, so the merge gate binds a commit
to a run by push identity.

The harness never holds a gateway or octo-sts token: identity-proxy injects them. Test with
`docker build --target test .`; `./build.sh` tests then builds.
