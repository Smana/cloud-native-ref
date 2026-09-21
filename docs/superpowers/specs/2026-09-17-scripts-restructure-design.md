# scripts/ restructure — organise by audience, discover tests by declaration

**Status**: design · **Date**: 2026-09-17 · **Branch**: `worktree-scripts-restructure`

## Problem

`scripts/` is 55 root-level executables in one flat, alphabetical directory, mixing three
populations that share nothing but a parent:

| Population | Count | Who runs it |
|---|---|---|
| `validate-*` / `verify-*` + `flux-schema/` | 8 + 8 | CI gates, and humans before pushing |
| `test-*` | 22 | CI — 11 of them, named by hand in `ci.yaml` |
| day-2 ops (`*-sweep-*`, `*-destroy*`, `*-prepare-*`, `*-adopt-*`, `*-recycle-*`) | 18 | a human at 2am |
| config drivers (`openbao-config`, `secret-store`, `zitadel-*`, `tm-provisioner`) | 7 | terramate/tofu at apply time |

`aws-sweep-orphaned-volumes.sh` sorts next to `validate-links.sh`. Nothing in the layout says
which files gate a PR, which run during a deploy, and which are reached for only during an
incident.

Two symptoms follow from it:

**Test coverage is opt-in by hand.** `ci.yaml` runs 11 suites from a literal list, defended by 60
lines of comment explaining why the list is a list. The seven ZITADEL suites went unrun for months
for exactly this reason — writing a suite and having CI run it are separate acts, and the second
one gets forgotten.

**Nothing points at the entry points.** There is no task runner in this repo. Discovery is `ls
scripts/` and a guess.

### Non-problems

Dagger is not under evaluation. It was decommissioned from CI on 2026-07-20 (engine startup
overhead, `Smana/daggerverse` maintenance) and reaffirmed 2026-09-12; `grep -r dagger
.github/workflows/` now returns three orphaned comments and no invocation. This design closes
that out by giving the decision an ADR instead of a comment.

## Constraints

- **The repo is a reference.** Someone must be able to lift one script, or one gate, into their
  own repo without adopting this repo's tooling. Any orchestration layer is an index, never a
  dependency of the scripts themselves.
- **Repository metadata is English**; the platform constitution applies unchanged.
- **`main` is CI-gated**, six required checks, `enforce_admins`. Job *names* are required-check
  contexts — renaming a job changes the required-check list, so jobs keep their names.

## Decisions

| # | Decision | Rejected |
|---|---|---|
| 1 | Directories scoped by **audience** | by topic (`aws/`, `openbao/`) — every file has one answer to "who runs this?", many to "what is this about?" |
| 2 | **`taskfile.yaml`** (go-task v3) as the index | a bespoke `./scripts/run` dispatcher; Make; Dagger |
| 3 | Suites declare `# requires:`; the runner globs and skips | two-tier directories; per-suite `exit 77` self-skip |
| 4 | Rewrite live refs; **leave the dated archive** | rewrite all 1246; symlink shims at old paths |
| 5 | Correct each script's `/..` depth by hand, **under a gate that proves it** | a shared `repo-root.sh` resolver; `git rev-parse --show-toplevel` |

## Target layout

```
scripts/
  taskfile.yaml            # included by the root taskfile.yaml
  README.md                # what each directory is; pointer to `task --list`
  ci/                      # CI gates — also runnable by hand
    validate-manifests.sh      validate-links.sh
    validate-doc-claims.sh     validate-idp-topology.sh
    validate-vmrules.sh        validate-alertmanager-templates.sh
    validate-vector-vrl.sh     verify-doc-paths.sh
    flux-schema/           # render-bundle.py, check-substitution.py, gen-catalog.sh, …
    tests/
      run.sh               # globs, reads `# requires:`, runs or skips
      test-*.sh            # 20 suites
      flux-schema/         # test-render-bundle.py, test-check-substitution.py
      alertmanager-fixtures/  vector-vrl-tests/
  ops/                     # day-2: an operator, or a terramate destroy script
    aws/  gcp/  k8s/  teardown/  demo/
  provision/               # invoked by terramate/tofu during an apply
    openbao-config.sh  openbao-adopt-jwt-mount.sh  secret-store.sh
    zitadel-idp.sh  zitadel-oidc-clients.sh  zitadel-actions/
    tm-provisioner.sh  helm-release-present.sh
  docs/                    # docs-site generators, run by hand
    export-diagrams.sh  diagram-icons.py  build-og-card.html
  lib/                     # unchanged — already correct
```

Inside a scoped directory the now-redundant prefix drops: `ops/aws/sweep-orphaned-volumes.sh`,
not `ops/aws/aws-sweep-orphaned-volumes.sh`.

### Placements that measurement corrected

- **`helm-release-present.sh` → `provision/`, not `ops/`.** It is invoked from
  `opentofu/{aws/eks,gcp/gke}/configure/{main,versions}.tf` (6 refs) — apply-time, not day-2.
- **`k8s-reclaim-csi-volumes.sh`, `gcp-purge-dns-records.sh`, `gcp-sweep-orphaned-disks.sh`,
  `aws-sweep-*`, `eks-*`, `destroy-stage2.sh`, `tofu-destroy-contained.sh`,
  `terramate-destroy-confirm.sh`, `gcp-adopt-workforce-pool.sh` stay in `ops/`** but are
  terramate-invoked. See *Risk*, below — this is the finding that redrew the PR sequence.

### Deletions

| File | Why |
|---|---|
| `scripts/teardown.sh` | no caller in CI, opentofu, manifests or docs |
| `scripts/aws-sweep-controller-orphans.sh` | same |
| `scripts/demo-traffic-generator.sh.backup` | untracked, gitignored |
| `scripts/flux-schema/__pycache__/` | untracked, gitignored |

### `scripts/openbao-snapshot.sh` is a symlink

It points at `../container-images/openbao-snapshot/openbao-snapshot.sh`. Moving it one level
deeper breaks the relative target silently — `find -type f` does not even see a symlink, which is
why `ci.yaml`'s ShellCheck step carries an explicit `\( -type f -o -type l \)`. It gets a
re-pointed link, not a `git mv`, and the ShellCheck find must keep its `-type l`.

## The taskfile surface

Root `taskfile.yaml`, go-task v3, added to `mise.toml` as `task = "3"` so the existing
`jdx/mise-action` installs it in CI with no new action and no new pin to maintain. Same `check:`
aggregate idiom as `Smana/cilium-gateway-api`.

```yaml
version: "3"
includes:
  ci: scripts/taskfile.yaml
tasks:
  check:
    desc: Everything CI gates, locally
    cmds: [{task: "ci:validate"}, {task: "ci:test"}, {task: "ci:links"}]
```

Tasks are one line each and hold no logic:

```yaml
ci:validate:
  desc: Render the repo as Flux would, then gate it
  cmds: ["./scripts/ci/validate-manifests.sh"]
```

That is what keeps constraint 1 intact: go-task is how you *find* a gate, never how you *run*
one. An adopter who wants `validate-manifests.sh` copies one file.

`ci.yaml` steps become `run: task ci:validate` / `run: task ci:test`. Job names are unchanged, so
the required-check list on `main` is untouched.

## Test discovery contract

Each suite carries one header line. Absent means "bash and jq, nothing else":

```bash
#!/usr/bin/env bash
# requires: vector
```

Measured across the 20 suites: 18 declare nothing (every external call is stubbed onto `PATH`),
`test-flux-schema.sh` declares `flux helm kustomize python3`, `test-vector-vrl.sh` declares
`vector`.

`scripts/ci/tests/run.sh` (~40 lines) globs `test-*.sh`, parses the header, runs what the
environment satisfies, and prints the rest as `SKIP` naming the missing tool:

```
PASS  test-no-secret-argv                       (0.4s)
PASS  test-tm-provisioner                       (0.2s)
SKIP  test-vector-vrl              missing: vector
SKIP  test-flux-schema             missing: flux
18 passed, 2 skipped, 0 failed
```

Two properties the current setup lacks:

1. **A new suite is covered on the commit that adds it.** No second act to forget.
2. **A skip is output, not silence.** The failure mode the 60 comment lines are defending against
   — a suite that quietly does not run — becomes a line on the job log.

The 60 lines of justification in `ci.yaml` are deleted, not relocated. Their content is one
`# requires:` header per affected suite.

## Reference rewrite

1246 references to `scripts/…` exist. They split unevenly:

| Surface | Refs | Breaks how |
|---|---|---|
| `opentofu/**` (`.tm.hcl`, `.tf`) | 128 | **at apply time** — no gate reads these |
| `website/content/**` | 113 | red CI — `verify-doc-paths.sh` gates backticked paths |
| `.github/workflows/**` | 35 | red CI |
| manifests, `AGENTS.md`, `.agents/`, `mise.toml`, `.doc-claims.yaml` | 83 | silently wrong |
| **live subtotal** | **359** | |
| `docs/superpowers/plans/` | 692 | not at all |
| `docs/superpowers/specs/` | 102 | not at all |
| `docs/specs/` (retired SDD archive) | 93 | not at all |
| **archive subtotal** | **887** | |

**Zero archive references are Markdown links** — all are backticked prose or fenced blocks, so
`validate-links.sh` cannot see them and `verify-doc-paths.sh` reads only `website/content/`.

The 887 stay as written. A dated design or plan records what was true when it was written;
rewriting it produces a 2026-08 plan citing a 2026-09 path, and a diff in which a reviewer cannot
distinguish a retcon from a real edit. One note lands at `docs/superpowers/plans/README.md` and
`docs/specs/README.md`:

> Paths under `scripts/` in these documents predate the 2026-09-17 restructure. Current locations:
> `scripts/README.md`.

This is consistent with `verify-doc-paths.sh`'s existing no-allowlist stance — fix the path or
drop the reference — applied to the only corpus where neither is right.

### The sed hazard

`opentofu/{aws,gcp}/openbao/cluster/scripts/` are **module-local** script directories, referenced
as `${path.module}/scripts/setup-local-disks.sh` and `${path.module}/scripts/startup-script.sh`.
A rewrite anchored on the bare token `scripts/` corrupts them.

Every rewrite anchors on the repo-root form — `./scripts/<name>` or `scripts/<known-basename>`
from an enumerated list of moved files — never on `scripts/` alone. The plan carries the
enumerated list; `tofu validate` on both clouds is the check that it held.

## Internal self-location — the larger hazard

External references are the visible risk. The quiet one is that **42 of 55 scripts compute paths
from where they sit**, so a `git mv` breaks them whether or not every external reference is
rewritten correctly.

| Pattern | Count | What a move does |
|---|---|---|
| `cd "$(dirname "$0")/.."` — "my parent is the repo root" | 11 | resolves to `scripts/`. The `cd` *succeeds*; every relative path after it is wrong |
| `HERE=` / `SCRIPT_DIR=` / `ROOT=`, then paths built from it | 25 | a test suite loses the script it tests |
| `. "$(dirname "$0")/lib/…"` | 14 lines in 9 scripts | `source` fails on line 6 |

The idiom is already depth-coupled, and the repo proves it: `flux-schema/gen-catalog.sh:31` uses
`/../..` rather than `/..` purely because it sits one level deeper than its siblings.

**Six of the nine `lib/`-sourcing scripts are deploy-time invoked** — `openbao-config.sh`
(2 sources), `zitadel-idp.sh` (3), `zitadel-oidc-clients.sh` (3), `secret-store.sh`. A wrong depth
there fails during an apply, which is the PR-3 failure mode arriving through a door the reference
rewrite does not cover.

### The fix, and the gate that proves it

Each moved script gets its `/..` count corrected in the same commit that moves it — the plain
idiom stays, because `cd "$(dirname "$0")/../.."` is legible to an adopter in a way a resolver
helper is not, and constraint 1 says the scripts must stay liftable.

Hand-correcting 42 depths is not something to trust to review, so **`scripts/ci/tests/test-script-paths.sh`
ships in PR 1, before anything moves**:

- for every script, execute its self-location in a subshell and assert the resolved root contains
  a known repo marker (`AGENTS.md` and `opentofu/`);
- for every `source`/`.` line, assert the target file exists;
- for every suite's subject default — `SRC="${OPENBAO_CONFIG_SCRIPT:-$HERE/openbao-config.sh}"`
  and the 15 others like it — assert the file exists;
- fail naming the script, the line, and what the path resolved to.

That third check matters more than it looks. **16 suites point at a subject that moves in a
later phase**: `test-openbao-*` and `test-zitadel-*` read scripts that do not move until PR 3,
`test-cnpg-promote-seed.sh` one that moves in PR 2. Their subject paths are therefore edited
*twice* — once when the suite moves into `ci/tests/`, once when the subject moves — and only a
gate makes the second edit reviewable. Nine of the sixteen already read
`${VAR:-$HERE/…}`, so the override is the seam to edit.

PRs 2 and 3 then move *underneath a gate that already passes*, which converts a silent 2am failure
into a red check. Rejected: a shared `scripts/lib/repo-root.sh` (must itself be found by a
relative path, so it relocates the problem rather than removing it) and `git rev-parse
--show-toplevel` (no `.git` in the `openbao-snapshot` container image, and `scripts/openbao-snapshot.sh`
is a symlink into exactly that image).

## Risk and sequencing

The measurement that redrew this: **deploy-time invocation does not follow the directory split.**

```
invoked from opentofu/**/*.tm.hcl and *.tf
  provision/  tm-provisioner 24 · openbao-config 15 · zitadel-oidc-clients 12
              secret-store 7 · helm-release-present 6 · openbao-adopt-jwt-mount 2
  ops/        terramate-destroy-confirm 15 · destroy-stage2 5 · tofu-destroy-contained 2
              gcp-adopt-workforce-pool 2 · aws-sweep-teardown-blockers 2 · + 6 more at 1 each
  ci/         validate-idp-topology 2 · validate-doc-claims 1
```

11 of 18 `ops/` scripts and 2 CI validators are terramate-invoked. "ops is the low-risk PR" was
wrong, and the sequence names the risk rather than pretending a directory boundary removes it.

| PR | Moves | Live refs | Evidence required before merge |
|---|---|---|---|
| 1 | `ci/`, `ci/tests/`, `taskfile.yaml`, `run.sh`, **`test-script-paths.sh`**, ADR | 126 | `task check`; `validate-links.sh`; `verify-doc-paths.sh`; the 3 terramate refs rewritten and `terramate list` clean |
| 2 | `ops/`, `docs/` | 77 | the above **plus `terramate script run preview`**, both clouds |
| 3 | `provision/` | 125 | the above; `tofu validate` per stack; `terramate script run preview`, both clouds |

Three PRs, not one: a move-only diff is reviewable by reading the rename list, and mixing 300+
path rewrites with new runner logic is not.

**PR 3 is the one that can fail at 2am.** Those paths are shelled out to during an apply, nothing
in CI executes them, and `verify-doc-paths.sh` does not read `.tm.hcl`. It merges on its own, on
its own review, with a preview run cited.

## Out of scope

| Deferred | Why |
|---|---|
| Comment-to-code ratio (`mise.toml` 100:18; `ci.yaml` 205:239; `openbao-config.sh` 39%; `zitadel-oidc-clients.sh` 47%) | prose deletion inside a move-heavy diff makes both unreviewable |
| `openbao-restore-drill.yml` (672 lines), `build-container-images.yml`, `vector-config-validation.yml` | only `ci.yaml` shrinks here |
| Composite action for the repeated checkout/mise/pip/helm-cache setup | independent of the move; own PR |
| Splitting the four scripts over 900 lines | behaviour change, not relocation |

## Success criteria

1. `ls scripts/` returns 5 directories, `taskfile.yaml` and `README.md` — no loose executables.
2. `task --list` names every entry point with a one-line description.
3. `task check` passes locally and is what `ci.yaml` invokes — same command, both places.
4. `task ci:test` runs all 20 suites, skipping only on a declared-and-absent tool, and reports
   the skip with the tool named.
5. Adding `scripts/ci/tests/test-foo.sh` makes CI run it with no edit to `ci.yaml`.
6. `./scripts/ci/validate-links.sh` and `./scripts/ci/verify-doc-paths.sh` pass.
7. `terramate script run preview` succeeds on both clouds after PRs 2 and 3.
8. The required-check list on `main` is unchanged — no job renamed.
9. `grep -rn 'scripts/[a-z]' opentofu --include='*.tf' --include='*.tm.hcl'` resolves to an
   existing file for every hit, module-local paths included.
10. `test-script-paths.sh` passes after every phase: each script's self-resolved root holds
    `AGENTS.md` and `opentofu/`, and all 14 `source` targets exist.
11. `scripts/openbao-snapshot.sh` still resolves — `test -f "$(readlink -f scripts/openbao-snapshot.sh)"`.

## Gate

Per `docs/superpowers/AGENTS.md`, a technology choice with a rejected alternative needs an ADR on
the branch before the PR opens. **ADR-0039 "go-task as the local and CI entry point"** ships in
PR 1, recording go-task over a bespoke dispatcher, over Make, and over Dagger — and giving the
2026-07 Dagger decommission the durable home it currently lacks.

## Next

`writing-plans` → `docs/superpowers/plans/2026-09-17-scripts-restructure-plan.md`.
