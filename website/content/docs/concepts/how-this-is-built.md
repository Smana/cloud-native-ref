---
title: How this is built
weight: 60
description: The design method behind the platform, the gates that enforce it, and where the process is expensive.
lastVerified: 2026-08-27
---

Most reference repositories show you the result. This one also shows how it
was arrived at, because for a platform the reasoning is usually more
transferable than the YAML.

## Design before implementation

The sequence below is not homegrown. It comes from
[Superpowers](https://github.com/obra/superpowers), a plugin declared in this
repository's `.claude/settings.json`, whose skills trigger on the shape of the
work rather than on a command someone has to remember to type. That last
property is what makes it stick: a workflow you have to invoke is a workflow
you skip when you are in a hurry.

Non-trivial changes go through a fixed sequence:

1. **Brainstorm** — explore the problem and the options before committing to
   one. Ends in a design document.
2. **Design** — the options considered, the decision, and the rationale.
   Committed to the branch, not merged ahead of the work.
3. **Plan** — the design turned into ordered, individually testable tasks
   with exact file paths.
4. **Execute** — task by task, each reviewed before the next begins.
5. **Verify** — success criteria checked against the running cluster.

The artifacts are in the repository under `docs/superpowers/specs/` and
`docs/superpowers/plans/`, one pair per initiative. They are worth reading
precisely because they include the options that were rejected, which is the
part that normally evaporates.

Cross-cutting technology decisions graduate into
[decision records]({{< relref "/docs/decisions/_index.md" >}}), so a choice
made once is not relitigated per feature. A technology chosen over a named
alternative needs one before it merges — if you can say what it was picked
over, that reasoning is worth keeping.

The wider practice this sits inside — how an AI coding agent is actually wired
into a platform-engineering workflow, and where it earns its keep — is covered
at length in [Agentic Coding: concepts and hands-on Platform Engineering use
cases](https://blog.ogenki.io/post/series/agentic_ai/ai-coding-agent/).

## The constitution

Some rules are not per-design decisions. Resource naming, default-deny
network policy, EKS Pod Identity over IRSA, no hardcoded credentials,
mandatory resource limits — these are settled, and every design is checked
against them rather than re-arguing them.

That is what the
[platform constitution]({{< relref "/docs/reference/platform-constitution.md" >}})
is for. It is loaded automatically into agent sessions working in the
relevant directories, which means it functions as a working constraint
rather than a document people are supposed to remember.

## What actually gates a merge

A rule that fails a build is worth more than a rule in a document. The
enforcement here:

| Gate | What it catches |
|---|---|
| `./scripts/validate-manifests.sh` | Renders every overlay and HelmRelease as Flux would, then validates structure and CEL against the repo's own XRDs, and audits the rendered bundle with Polaris |
| `./scripts/validate-links.sh` | Every relative Markdown link in the repository, resolved rather than grepped |
| `./scripts/validate-doc-claims.sh` | Pinned prose claims still match the configuration they describe — sources and patterns in `.doc-claims.yaml`; runs inside the links CI job |
| `./scripts/verify-doc-paths.sh` | Every repository path named in the documentation still exists |
| `trivy config` | Infrastructure-as-code misconfiguration |
| pre-commit | Formatting, secret detection, Terraform validation |

Two properties of the manifest gate are load-bearing. It validates the
**rendered** output rather than source files, because the repository
contains a handful of raw workloads while the rendered bundle contains
dozens. And `skipMissingSchemas: false` in `.fluxschema.yml` means an
unknown Kind **fails the build** instead of being quietly skipped — the
previous setup skipped missing schemas, so every custom claim in the
repository went unvalidated for the life of the project without anyone
noticing.

## The evidence rule

No claim of "done", "fixed" or "passing" without a fresh command run in the
same breath, with its output cited. Not a previous run, not a confident
recollection.

This sounds pedantic until you watch how often it catches something. It is
the difference between "the manifests are valid" and "`validate-manifests.sh`
exited 0 with `Invalid: 0, Skipped: 0`", and only the second is checkable by
the person reading it.

## Where the process is expensive

An honest account has to include the cost.

**It is slow for small changes.** A version bump or a typo fix does not need
a design document, and forcing one would be theatre. The workflow is
explicitly skipped for those.

**Review is the expensive step, and it is the one that pays.** Building this
documentation site is a fair example. Every lane passed its automated gates
and still contained defects that only a reader checking claims against the
manifests could find: a page describing a teardown flag as protecting data
when it does not, a dependency graph edge that did not exist, a deploy
sequence that could not complete as written.

**The worst defect was a fabrication, not a staleness.** One page asserted
that the root CA was held offline and never present in a live secrets mount.
The repository documents the opposite, explicitly, as an accepted trade-off.
Nothing in the source said what the page said — it was written from what
sounded plausible rather than from the manifests. No linter can catch that,
and the automated gates all passed.

**Counts rot silently.** Every hand-maintained tally checked during this
migration was wrong — how many children a Kustomization aggregates, how many
sections a document has, how many folders exist. Nothing fails when a ninth
item is added, so nothing tells you the number now lies. Prose explaining
*why* something works has held up far better than any enumeration.

**Automation is not the safeguard people expect.** The gates in this
repository are good at structure — dead links, missing files, invalid
schemas — and blind to meaning. Every serious defect found while building
this site was semantic, and every one was found by a person reading source.
`validate-doc-claims.sh` narrows the gap for the specific claims someone
chose to pin, but it verifies only those — the general problem stands.

## Reading on

- [Platform constitution]({{< relref "/docs/reference/platform-constitution.md" >}})
  — the rules every design is checked against
- [CI workflows]({{< relref "/docs/reference/ci-workflows.md" >}}) — the
  gates as they run in CI
- [Decisions]({{< relref "/docs/decisions/_index.md" >}}) — the records
  themselves
