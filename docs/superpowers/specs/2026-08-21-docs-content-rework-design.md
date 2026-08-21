# Documentation site — content rework

**Date:** 2026-08-21
**Status:** design approved, plan pending
**Branch:** `worktree-docs-adr-backfill`
**Follows:** [2026-08-20-docs-hugo-site-design.md](2026-08-20-docs-hugo-site-design.md) — the site
that this reworks the content of

---

## Why this design exists

[cnref.ogenki.io](https://cnref.ogenki.io) launched on 2026-08-20 (#1794, #1798, #1799). A read of
the published content a day later surfaced five content problems and four defects the automated
gates cannot see. None is a bug in the site; all are in what it says.

The through-line is that the site is strongest where it records **reasoning** and weakest where it
records **state**. Reasoning ages well; state rots silently, which is the exact failure mode
[How this is built](../../../website/content/docs/concepts/how-this-is-built.md) warns about in its
own "Counts rot silently" section. Three of the five content problems are the site not taking its
own advice.

## Problems, with evidence

| # | Problem | Evidence |
|---|---|---|
| P1 | The Technology Stack page is a hand-maintained version table | `website/content/docs/reference/technology-stack.md` — ~45 rows carrying a version number, gated by nothing. Its own closing section says the page exists because its version-less predecessor "drifted" |
| P2 | Six load-bearing technology choices have no ADR | `concepts/technology-choices.md` § "The ones without records" — Flux, Cilium, VictoriaMetrics, OpenBao, Crossplane, Tailscale, at 2–5 lines each |
| P3 | The homepage hero defines the project by what it isn't | `website/content/_index.md` — "Not a slide deck and not a toy cluster", then 40 words before the first concrete noun |
| P4 | `how-this-is-built` describes a method it never names | The five-step workflow is Superpowers; the page attributes it to nothing, so a reader cannot reproduce it |
| P5 | `SECURITY.md` is template-grade and partly false | "Uses development-grade certificates" (there is a three-tier private PKI); "Change all default passwords" (they are generated into AWS Secrets Manager). Only the tooling list is accurate |
| D1 | 10 dead links in published ADRs | `0002/0005/0006/0007` link `../specs/done/2024-Q1/…`, `../superpowers/specs/…`, `../../.claude/rules/…` — all pre-migration `docs/` paths |
| D2 | The gate that should catch D1 excludes the whole tree | `scripts/validate-links.sh:44` — `files = [f for f in files if not f.startswith('website/content/')]` |
| D3 | `technology-stack.md` contradicts the live site | Its closing section calls `technology-choices` "the retired page"; that page is live in Concepts |
| D4 | ADR-0001/0002 carry invented provenance | Header says `Date: 2024-01-15`, `Deciders: Platform Team`. Both files were added 2026-01-06 in `6583c0ef`; the KCL conversion they describe landed 2024-09-29 (`convert compositions to use kcl function only`). Solo-maintained repository |

## Decisions taken during design

| Question | Decision | Rationale |
|---|---|---|
| How wide is the ADR backfill? | Exactly the six choices already in prose — ADR-0008…0013 | They are the platform's most load-bearing picks and currently get its least page. Broader backfills (OpenTofu, Gateway API, Terramate, Kyverno) produce records for things nothing credible competed with |
| What replaces the version column? | `Component \| Role in the platform`, plus a per-section intro and a `**Decisions:**` line | Rejected: keeping a `Pinned in` column. It is wrong on a meaningful fraction of rows — `cilium_version` lives in `opentofu/config.tm.hcl` *and* is mirrored as a default in `opentofu/eks/configure/variables.tf`; the VictoriaMetrics stack and VictoriaLogs each span two `HelmRelease` files; GHA runners span three. A multi-file list is the same rot problem in a different column |
| What survives of `technology-choices`? | Delete the page; move its four principles into `decisions/_index.md` as a preamble | After the backfill it is four principles plus a 13-row table near-duplicating the ADR index. The principles are the meta-decision framework and belong on the Decisions index |
| Which hero voice? | The README's own opening line, tightened | Same voice on GitHub and on the site, which matters because GitHub is where most readers arrive first |
| How far does the security work go? | Rewrite `SECURITY.md`; add a Supply chain section to `platform/security/policies.md` | Rejected: renaming `concepts/zero-trust` to "Security model". It churns a URL on a site launched the week before and dilutes a page with one sharp thesis |
| What triggers the new ADR rule? | A **rejected alternative** | Rejected: "any new technology or concept" (would have demanded ~45 records, most a paragraph long) and "any load-bearing component" (still produces records for uncontested picks). Tying the trigger to a named alternative is self-limiting — an ADR with no alternatives section is a changelog entry |

## Workstream 1 — ADR-0008…0013

Six records under `website/content/docs/decisions/`, following `template.md`
(Context / Options considered / Decision / Consequences), dated 2026-08-21, `Status: Accepted`.

Every record is sourced from what this repository does, not from general knowledge about the
tools. Each must carry at least one consequence that cost something — an ADR that only lists
benefits is marketing.

| ADR | Choice | Over | Load-bearing content |
|---|---|---|---|
| 0008 | Flux | Argo CD | `dependsOn` as the ordering primitive the platform's layering needs; controller sharding (`sharding.fluxcd.io/key`); the honest "Argo CD would also have worked — this is a preference, not a verdict" |
| 0009 | Cilium | VPC CNI + kube-proxy + NetworkPolicy engine + ingress controller | Four components collapsed into one. **Consequences must include the cost**: cilium#43493 breaking the Gateway API L7 proxy under prefix delegation, `encryption.type: wireguard` as a load-bearing workaround rather than a performance choice, the manual `cniVersion` bump on every Cilium minor, and prefix delegation not applying to bootstrap nodes |
| 0010 | VictoriaMetrics / VictoriaLogs / VictoriaTraces | Prometheus + Loki + Tempo | Resource envelope at equal retention; CRDs for scrape config and rules; one query surface and one operational model across three signals |
| 0011 | OpenBao | HashiCorp Vault | The BUSL licence change as the trigger. Consequences: smaller ecosystem, and the 2.6 write-concurrency deadlock worked around with `-parallelism=1` in the management stack rather than by pinning back to 2.5.5 |
| 0012 | Crossplane **and** OpenTofu | either alone | Continuous reconciliation versus true-only-at-apply — and why the boundary falls at "below Kubernetes / above Kubernetes" rather than at a tool preference. Explicitly not a claim that Crossplane describes cloud resources better than OpenTofu |
| 0013 | Tailscale | bastion host / VPN appliance | ACL tags as the authorization primitive; the two-gateway split (`tag:k8s` vs `tag:admin`) that makes admin services unreachable rather than merely unlisted; no host to patch |

`decisions/_index.md` gains six table rows and the four principles as a preamble.

## Workstream 2 — Technology Stack

Seven sections retained (CLI tools, EKS bootstrap, Infrastructure, Security, Observability, Data
and tooling, Managed AWS services). Each becomes:

1. A short intro on what the layer does and how its pieces relate.
2. One structural sentence on where that layer's versions are declared — *"in each component's
   `HelmRelease` under `infrastructure/base/`"*, not a per-row file path.
3. A `**Decisions:**` line naming the ADRs covering that layer, where any exist.
4. A two-column `Component | Role in the platform` table.

The page lead is replaced with the freshness policy: Renovate opens a PR per upstream release and
CI renders the whole repository against it before it can merge. That is the true statement the
version table was a poor proxy for.

Removed: every version number, the `Pinned in` column, and the "What this table intentionally
omits" section (D3).

## Workstream 3 — Homepage

Hero:

> **An opinionated, production-ready Kubernetes platform, built on GitOps**
>
> Infrastructure as code with OpenTofu and Crossplane, continuous delivery with Flux, a private PKI
> and zero-trust networking, and a developer abstraction that turns one small YAML claim into a
> whole application. Deploy it into your own AWS account in about thirty minutes.

The two consecutive feature grids collapse to one six-card grid. The first grid's subtitles are
the stronger writing ("zero trust that is enforced by policy, not asserted in a README") and are
kept where they overlap with the second grid's sections.

## Workstream 4 — How this is built

Name [Superpowers](https://github.com/obra/superpowers) as the source of the five-step workflow,
and link [Agentic Coding: concepts and hands-on Platform Engineering use
cases](https://blog.ogenki.io/post/series/agentic_ai/ai-coding-agent/) at the point the page
describes the method — not only from `further-reading`, where it currently sits.

The "Where the process is expensive" section is not touched.

## Workstream 5 — Security

**`SECURITY.md`** — scope and reporting kept. The posture section is replaced with what the
repository actually enforces (least privilege, zero trust, no static credentials, private PKI,
default-deny network policy, no deletion permissions on stateful services), an enforcement table
naming the gate for each, and **real** known limitations replacing the invented ones:

- the root CA private key is present in the live OpenBao mount, accepted so the deploy stays
  unattended;
- CiliumNetworkPolicy coverage is uneven — the observability stack does not yet meet the
  constitution's bar.

Linked from `website/content/docs/platform/security/_index.md`.

**Supply chain** — a new section on `platform/security/policies.md` covering Trivy (IaC and
image), Checkov, `detect-secrets` in pre-commit, Harbor as the registry, and the image-tag policy.
This is the one security domain the site currently frames only as CI plumbing.

## Workstream 6 — Defects

- **D1**: fix the 10 links. `../platform-constitution.md` → `relref` to `/docs/reference/`;
  `../superpowers/specs/…` and `../../.claude/rules/…` → absolute GitHub URLs, since those files
  are not published on the site.
- **D2**: extend `scripts/validate-links.sh` with a narrow rule — a raw `](../…)` or `](./…)`
  Markdown link anywhere under `website/content/` is always wrong, because Hugo pages address each
  other with `relref`. This does not require the checker to understand Hugo; it only asserts the
  absence of a construct. The existing blanket exclusion at line 44 stays for every other check.
- **D4**: correct ADR-0001/0002 headers — real dates from `git log`, and a `Deciders` value that is
  true for a solo-maintained repository.

## Success criteria

| Criterion | Evidence |
|---|---|
| Six ADRs published and indexed | `decisions/_index.md` lists 0001–0013; each new file renders with Context / Options / Decision / Consequences |
| Every new ADR names a real cost | Each of 0008–0013 has at least one consequence that is a trade-off accepted, not a benefit gained |
| No version numbers left on the stack page | `grep -E '\| [0-9]+\.[0-9]+' website/content/docs/reference/technology-stack.md` returns nothing |
| `technology-choices` fully removed | File deleted, card removed from `concepts/_index.md`, principles present in `decisions/_index.md`, no inbound link anywhere |
| Dead links fixed and the class gated | `./scripts/validate-links.sh` exits 0 and fails if a raw relative link is reintroduced under `website/content/` |
| Site builds | `hugo --minify` in `website/` exits 0 with no `REF_NOT_FOUND` warnings |
| Repo paths still resolve | `./scripts/verify-doc-paths.sh` exits 0 |
| The rule is enforceable, not decorative | Present in `CLAUDE.md`, `.claude/rules/superpowers.md`, and the constitution checklist, with identical wording |

## Out of scope

- Restructuring the site's navigation or section weights.
- Any change to `platform/`, `guides/`, or `get-started/` content beyond the two security edits.
- Backfilling ADRs for uncontested picks (OpenTofu, Gateway API, Terramate, Kyverno, Karpenter).
  The new rule applies going forward; it is not retroactive beyond the six.
- Renaming or moving `concepts/zero-trust.md`.

## Delivery

Two sequential PRs. PR 2's content does not depend on PR 1, but the stack page cites the new ADRs.

| PR | Contents |
|---|---|
| 1 — Decisions | ADR-0008…0013; delete `technology-choices` and move its principles; rewrite `technology-stack`; the ADR rule in three places; D1, D2, D3 |
| 2 — Front door and security | Homepage hero and grid; `how-this-is-built`; `SECURITY.md`; the supply-chain section; D4 |

## The rule

Written once, referenced from three places verbatim:

> **A technology choice with a rejected alternative requires an ADR before merge.** If you can name
> what it was chosen over, write the record. If nothing credible competed, it is an installation
> and not a decision — say so in the PR description rather than leaving it unsaid. Version bumps,
> chart-value changes and single-file fixes never need one.

Placement:

- `CLAUDE.md` — a row in the *When a Design Is Required* table.
- `.claude/rules/superpowers.md` — the Design-phase row of the gate table.
- `docs/platform-constitution.md` — a line in the spec-compliance checklist.
