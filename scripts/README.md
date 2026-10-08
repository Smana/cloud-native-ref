# scripts/

Organised by **who runs it**, because every file has one answer to that and several to "what is
this about?". Entry points are indexed by `task --list`; run them with `task`, or call any script
directly — none of them depend on the task runner.

| Directory | Audience |
|---|---|
| `ci/` | the gates CI runs, and you before pushing. `task check` runs every one CI runs |
| `ci/tests/` | suites `run.sh` discovers: `test-*.sh` and `test-*.py` here, `*/test-*.py` one level down. A `# requires:` tool that is absent, or an exit 77, reports `SKIP` |
| `ops/aws/`, `ops/gcp/`, `ops/k8s/` | day-2 operations, run by a human. Some are also called from terramate deploy or destroy scripts — `eks-recycle-bootstrap-nodes.sh` and `adopt-workforce-pool.sh` run on every deploy. `agent-run.sh` (`task agent:run`) creates one AgentRun; `ops/k8s/agent-probe.yaml` is the throwaway identity probe for SP1 verification, `agent-probe-mcp.sh` its MCP client |
| `ops/teardown/` | `teardown.sh` is the supported way to tear the platform down (`task ops:teardown`). The other three (`destroy-stage2.sh`, `terramate-destroy-confirm.sh` and `tofu-destroy-contained.sh`) are called by terramate destroy scripts |
| `ops/demo/` | demo load generation and cleanup |
| `ops/github/` | GitHub-side configuration, run by the owner: `task ops:github:agent-branch-ruleset` applies the agents' branch and tag rulesets |
| `docs/` | docs-site generators, run by hand. `build-og-card.html` opens in a browser |
| `lib/` | sourced by the others, never run directly |
| `provision/` | most are invoked by terramate and tofu, at plan, apply or destroy time; both deploys run `zitadel-idp.sh` (aws-0 and gcp-0), and it can be re-run by hand. Four are indexed: `task provision:secret-store`, `task provision:zitadel-oidc-clients`, `task provision:zitadel-idp` and `task provision:openbao-snapshot` |

`scripts/` root holds no loose executables.
