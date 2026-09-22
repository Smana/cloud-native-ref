# scripts/

Organised by **who runs it**, because every file has one answer to that and several to "what is
this about?". Entry points are indexed by `task --list`; run them with `task`, or call any script
directly — none of them depend on the task runner.

| Directory | Audience |
|---|---|
| `ci/` | the gates CI runs, and you before pushing. `task check` runs every one CI runs |
| `ci/tests/` | suites `run.sh` discovers: `test-*.sh` and `test-*.py` here, `*/test-*.py` one level down. A `# requires:` tool that is absent, or an exit 77, reports `SKIP` |
| `ops/aws/`, `ops/gcp/`, `ops/k8s/` | day-2 operations, run by a human. Some are also called from terramate deploy or destroy scripts — `eks-recycle-bootstrap-nodes.sh` and `adopt-workforce-pool.sh` run on every deploy |
| `ops/teardown/` | `teardown.sh` is the supported way to tear the platform down (`task ops:teardown`). The other three are called by terramate destroy scripts |
| `ops/demo/` | demo load generation and cleanup |
| `docs/` | docs-site generators, run by hand. `build-og-card.html` opens in a browser |
| `lib/` | sourced by the others, never run directly |

Apply-time provisioning scripts still sit at the root of `scripts/`; they move to `provision/` in
a later phase.
