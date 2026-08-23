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
| P2 | Nine load-bearing technology choices have no ADR | `concepts/technology-choices.md` § "The ones without records" lists six — Flux, Cilium, VictoriaMetrics, OpenBao, Crossplane, Tailscale — at 2–5 lines each. Three more are recorded nowhere at all: OpenTofu, Gateway API, Kyverno |
| P3 | The homepage hero defines the project by what it isn't | `website/content/_index.md` — "Not a slide deck and not a toy cluster", then 40 words before the first concrete noun |
| P4 | `how-this-is-built` describes a method it never names | The five-step workflow is Superpowers; the page attributes it to nothing, so a reader cannot reproduce it |
| P5 | `SECURITY.md` is template-grade and partly false | "Uses development-grade certificates" (there is a three-tier private PKI); "Change all default passwords" (they are generated into AWS Secrets Manager). Only the tooling list is accurate |
| D1 | 8 dead links in published ADRs (of 10 raw relative links) | `0002/0005/0006/0007` carry 10 raw relative links. **8 are dead**: `../specs/done/2024-Q1/…`, `../superpowers/specs/…`, `../../.claude/rules/…` all resolve outside `website/content/`, so Hugo cannot rewrite them and emits the path verbatim into the `href`, where it 404s. **2 are not dead**: the `../platform-constitution.md` links render as `/docs/reference/platform-constitution/` because Hugo resolves `.md` targets to page permalinks by name, wrong path notwithstanding. Verified against built HTML, not assumed |
| D2 | The gate that should catch D1 excludes the whole tree, on a false premise | `scripts/validate-links.sh:44` excludes `website/content/`, justified at lines 22–26 by "Hugo already gates that tree harder than this script could — `refLinksErrorLevel: ERROR`". That setting **is** present (`website/hugo.yaml:10`) but governs only `ref`/`relref` shortcodes; raw Markdown links bypass it. Verified: `hugo --source website --minify` exits 0 with all 8 dead links in place. The replacement rule must be the *escape* test, not "raw relative links are always wrong" — the latter would flag the 2 working links and the repository's own cross-ADR convention (`[ADR-0005](0005-….md)`, which resolves correctly) |
| D3 | `technology-stack.md` contradicts the live site | Its closing section calls `technology-choices` "the retired page"; that page is live in Concepts |
| D4 | ADR-0001/0002 carry invented provenance | Header says `Date: 2024-01-15`, `Deciders: Platform Team`. Both files were added 2026-01-06 in `6583c0ef`; the KCL conversion they describe landed 2024-09-29 (`convert compositions to use kcl function only`). Solo-maintained repository |
| D5 | The Decisions sidebar is a column of bare identifiers | Every record sets `linkTitle: ADR-000N`, so the navigation reads `ADR-0001 … ADR-0007` and conveys nothing about what each decides. Already unhelpful at seven; unusable at sixteen. Fixed by making `linkTitle` `NNNN · <short noun phrase>` on all sixteen |

## Decisions taken during design

| Question | Decision | Rationale |
|---|---|---|
| How wide is the ADR backfill? | Every choice with a namable rejected alternative — ADR-0008…0016 | The six already in prose, plus OpenTofu, Gateway API and Kyverno, which are recorded nowhere. Each has a real alternative that was considered and dropped, so each meets the new rule's own trigger; backfilling only the prose six would leave the rule failing on the repository that introduced it. Terramate and Karpenter are excluded on the same test — nothing credible competed |
| What replaces the version column? | `Component \| Role in the platform`, plus a per-section intro and a `**Decisions:**` line | Rejected: keeping a `Pinned in` column. It is wrong on a meaningful fraction of rows — `cilium_version` lives in `opentofu/config.tm.hcl` *and* is mirrored as a default in `opentofu/aws/eks/configure/variables.tf`; the VictoriaMetrics stack and VictoriaLogs each span two `HelmRelease` files; GHA runners span three. A multi-file list is the same rot problem in a different column |
| What survives of `technology-choices`? | Delete the page; move its four principles into `decisions/_index.md` as a preamble | After the backfill it is four principles plus a 13-row table near-duplicating the ADR index. The principles are the meta-decision framework and belong on the Decisions index |
| Which hero voice? | The README's own opening line, tightened | Same voice on GitHub and on the site, which matters because GitHub is where most readers arrive first |
| How far does the security work go? | Rewrite `SECURITY.md`; add a Supply chain section to `platform/security/policies.md` | Rejected: renaming `concepts/zero-trust` to "Security model". It churns a URL on a site launched the week before and dilutes a page with one sharp thesis |
| What triggers the new ADR rule? | A **rejected alternative** | Rejected: "any new technology or concept" (would have demanded ~45 records, most a paragraph long) and "any load-bearing component" (still produces records for uncontested picks). Tying the trigger to a named alternative is self-limiting — an ADR with no alternatives section is a changelog entry |

## Workstream 1 — ADR-0008…0016

Nine records under `website/content/docs/decisions/`, following `template.md`
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
| 0014 | OpenTofu | Terraform | The BUSL relicensing as the trigger, and the fork's provider ecosystem staying compatible. **The honest wrinkle**: `opentofu/aws/openbao/*` is configured with the `hashicorp/vault` provider — the platform left Terraform over the licence and still depends on a HashiCorp-licensed provider to configure the fork it left it for. Verify the provider's current licence before asserting it |
| 0015 | Gateway API | ingress-nginx | Role separation (`Gateway` owned by the platform, `HTTPRoute` by the application) and one CRD set serving both public and Tailscale-private ingress. Consequences: version lockstep with Cilium as the GatewayClass implementation — Cilium ≤1.19.4 crashes on Gateway API ≥v1.5.0 (cilium#45139) — and the CRDs must be installed before `cilium-operator` starts, because it probes for them exactly once and silently disables its controller for the process lifetime if any are missing |
| 0016 | Kyverno | OPA Gatekeeper, plain Pod Security Admission, native ValidatingAdmissionPolicy | Policies as YAML rather than Rego; mutation and generation alongside validation, which PSA cannot do. **Consequence that costs something**: `kyverno-policies` installs with `values: {}`, so the enforced policy set *and* its audit-versus-enforce action come from the chart's defaults rather than being chosen here — a deliberate deferral, not an oversight, and it should be recorded as one |

`decisions/_index.md` gains nine table rows and the four principles as a preamble.

ADR-0015 and ADR-0016 describe choices with no prose to migrate — `technology-choices.md` never
mentioned them. Their context has to be reconstructed from the manifests, so both carry a higher
fabrication risk than 0008–0014 and need their claims checked against source rather than written
from what is generally true of the tools.

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

**Supply chain** — a new section on `platform/security/policies.md`. This is the one security
domain the site currently frames only as CI plumbing. It must describe what the repository
actually runs, which is narrower than "supply chain security" usually implies:

- **Trivy** — `scan-type: fs` against the repository, `ignore-unfixed: true`,
  `severity: CRITICAL,HIGH`. **Not image scanning.** No container image is scanned anywhere in CI.
- **Checkov** — `soft_fail: true`. It uploads SARIF to GitHub Security and never fails the build.
  Advisory, not a gate, and the section must say so.
- **TruffleHog** in CI (`--only-verified`) and **`detect-secrets`** in pre-commit — two different
  tools at two different points, both currently collapsed into one line in `SECURITY.md`.
- **Polaris** on the rendered bundle, which *is* a gate.
- **Harbor** carries no Trivy configuration in `tooling/base/harbor/helmrelease-harbor.yaml`, so
  its scanner sits at chart defaults. Verify the chart default before claiming the registry scans
  anything.

Writing this section as though image scanning or Checkov gating exists would repeat exactly the
failure this workstream is fixing.

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
| Nine ADRs published and indexed | `decisions/_index.md` lists 0001–0016; each new file renders with Context / Options / Decision / Consequences |
| Every new ADR names a real cost | Each of 0008–0016 has at least one consequence that is a trade-off accepted, not a benefit gained |
| The backfill satisfies its own rule | No technology on the stack page has a namable rejected alternative and no ADR. Checked by reading, not by a script |
| No version numbers left on the stack page | `grep -E '\| [0-9]+\.[0-9]+' website/content/docs/reference/technology-stack.md` returns nothing |
| `technology-choices` fully removed | File deleted, card removed from `concepts/_index.md`, principles present in `decisions/_index.md`, no inbound link anywhere |
| Dead links fixed and the class gated | `./scripts/validate-links.sh` exits 0 and fails if a raw relative link is reintroduced under `website/content/` |
| Site builds | `hugo --minify` in `website/` exits 0 with no `REF_NOT_FOUND` warnings |
| Repo paths still resolve | `./scripts/verify-doc-paths.sh` exits 0 |
| The rule is enforceable, not decorative | Present in `CLAUDE.md`, `.claude/rules/superpowers.md`, and the constitution checklist, with identical wording |

## Out of scope

- Restructuring the site's navigation or section weights.
- Any change to `platform/`, `guides/`, or `get-started/` content beyond the two security edits.
- ADRs for picks where nothing credible competed — Terramate, Karpenter, cert-manager, External
  Secrets, ExternalDNS, CloudNativePG, Harbor, Headlamp. They fail the rule's own trigger: there is
  no rejected alternative to name. If one turns out to have had a real contender, it earns a record
  then.
- Renaming or moving `concepts/zero-trust.md`.

## Delivery

Three sequential PRs. Nine ADRs plus a page rewrite in one branch is more prose than a single
review can hold, and the ADRs are pure additions while everything else is edits and deletions —
different review modes, so they split cleanly.

| PR | Contents | Depends on |
|---|---|---|
| 1 — The records | ADR-0008…0016; nine rows added to `decisions/_index.md`; D5 (sidebar `linkTitle` on all sixteen) | — |
| 2 — Reference and the rule | Delete `technology-choices` and move its four principles into `decisions/_index.md`; rewrite `technology-stack`; the ADR rule in three places; D1, D2, D3 | PR 1 — the stack page's `**Decisions:**` lines cite the new ADRs |
| 3 — Front door and security | Homepage hero and grid; `how-this-is-built`; `SECURITY.md`; the supply-chain section; D4 | — |

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
