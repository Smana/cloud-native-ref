# scripts/

Organised by **who runs it**, because every file has one answer to that and several to "what is
this about?". Entry points are indexed by `task --list`; run them with `task`, or call any script
directly — none of them depend on the task runner.

| Directory | Audience |
|---|---|
| `ci/` | the gates CI runs, and you before pushing. `task check` runs every one CI runs |
| `ci/tests/` | suites `run.sh` discovers: `test-*.sh` here, `*/test-*.py` one level down. A `# requires:` tool that is absent, or an exit 77, reports `SKIP` |
| `lib/` | sourced by the others, never run directly |

Directories for day-2 operations and apply-time provisioning land in later phases of this
restructure; until then those scripts remain at the root of `scripts/`.
