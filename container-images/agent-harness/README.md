# agent-harness

The AgentRun sandbox's harness (SP1 design §5): `ghcr.io/openhands/agent-server:1.49.6-python` plus

| File | Role |
|---|---|
| `agent_run.py` → `agent-run` | Entrypoint: start agent-server, clone and resume `$BRANCH`, POST the conversation, wait, revoke, exit 0/1 |
| `git_credential_agent.py` → `git-credential-agent` | git credential helper; exchanges through identity-proxy `:4001`, caches in memory, `revoke` on exit and in `preStop` |
| `gh` | gh with that token in `GH_TOKEN`; `gh pr create` then appends the provenance footer (`pr_footer.py`, SP2 design §5) |
| `commit-msg` | adds `Agent-Run: $RUN_ID`, and `Agent-Task: $TASK_ID` when set |

The `Agent-*` keys are the harness's alone. In a commit message or a PR body, any line the model wrote
that starts with one of them, in any case, is prefixed `(agent-written) ` before the real values are added,
so it can neither suppress nor pre-empt them. The footer is always the last paragraph:

```text
---
Agent-Room: $ROOM_ID
Agent-Run: $RUN_ID
Agent-Role: $ROLE
Agent-Task: $TASK_ID
Agent-Task-URL: $TASK_URL
Agent-Model: $MODEL
```

A line whose value is empty is left out. `Agent-Task` is the task id and `Agent-Task-URL` the issue or PR
(SP3 ruling SW). Both are guidance, not a control: an agent with a shell can skip the hook, and `gh api` or a
later `gh pr edit` bypasses the footer.

The harness never holds a gateway or octo-sts token: identity-proxy injects them. Test with
`docker build --target test .`; `./build.sh` tests then builds.
