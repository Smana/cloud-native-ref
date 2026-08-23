# Documentation Site — Hugo + Hextra at cnref.ogenki.io

**Date:** 2026-08-20
**Status:** design approved, plan pending
**Branch:** `feat/docs-hugo`
**Related:** [ADR-0007 Cloud abstraction boundaries](../../../website/content/docs/decisions/0007-cloud-abstraction-boundaries.md), [GCP Support design](2026-08-18-gcp-support-design.md), [Platform Constitution](../../platform-constitution.md)

---

## Why this design exists

The repository's documentation is 16 top-level Markdown files (~7,500 lines) plus a 335-line
`README.md` that doubles as landing page, quickstart, concept primer, and link index. There is no
search, no navigation, no ordering, and no way to tell a current page from a stale one. Two of the
longest files have not been touched since November 2025.

That shape actively works against every purpose the repository has:

| Purpose | How the current docs fail it |
|---|---|
| **Demo material** — showing the platform in talks and walkthroughs | Nothing is presentable on a screen; a reader is dropped into a 700-line file with no visual anchor |
| **Teaching concepts and architecture** | Concepts are scattered across README sections and buried mid-file in operational docs |
| **Showing what each tool buys you** | The per-tool rationale exists but is unfindable; no `Why X?` is more than one hop from a config dump |
| **Bootstrapping a production-ready platform fast** | The quickstart is a README section competing for attention with a tech-stack table and an acknowledgements list |
| **Being reusable by other people** | There is no "fork and adapt" path at all — a reader must reverse-engineer which values are environment-specific |

A second, sharper problem is arriving: **GCP support** ([design](2026-08-18-gcp-support-design.md)).
Fifteen workstreams will add a second cloud. Without an information architecture that already knows
where cloud-specific content goes, that content will land wherever each PR finds room, and the docs
will need a reorganisation under time pressure rather than before the work starts.

## Goals

1. A published documentation site at **`cnref.ogenki.io`** with working full-text search.
2. A landing page a first-time visitor can read in under a minute and come away knowing what the
   project is and where to start.
3. An information architecture organised by domain and by reader intent, that has a place for a
   second cloud provider **before** GCP content exists.
4. Every migrated page verified against the repository as it actually is today. No page ships
   carrying content that cannot be checked.
5. Diagrams where prose fails — one per platform domain.
6. A written guide for someone who wants to use this repository for their own platform.

## Non-goals

- Versioned documentation. `main` is the only version that matters for a living reference platform.
- Internationalisation. The blog is bilingual; these docs are English-only.
- Per-PR preview deployments.
- Blog-style posts or a news section — [blog.ogenki.io](https://blog.ogenki.io) already exists.
- A CI check that diagram exports match their `.drawio` sources.
- Moving per-stack `README.md` files out of the code tree.

---

## Decisions

| # | Decision | Rationale |
|---|---|---|
| D1 | Content **moves** into `website/content/`; Hugo is the single canonical rendering | Frees the prose from dual-audience constraints — shortcodes, callouts, tabs, page weights and `relref` link-checking all become available. `docs/` retains only agent- and contributor-facing artifacts. |
| D2 | Theme: **Hextra** | Zero-config FlexSearch, hero/feature-grid primitives for the landing page, native `tabs` for the coming per-cloud split, mermaid support, and **no npm** — a Node toolchain in a repository whose pitch is reproducible infrastructure is a poor advertisement. Docsy's main differentiator (docs versioning) is a non-goal here. |
| D3 | IA: **audience lanes** — Get Started / Platform / Concepts / Guides / Reference / Decisions | Maps one-to-one onto the five purposes above. A domain-only tree leaves the "guide for others" and demo material homeless; strict Diátaxis scatters each component across four quadrants, and readers of an infrastructure reference navigate by component. |
| D4 | Palette: brand navy `#004675` as accent, drawio `ogenki` preset as the semantic layer | `#004675` is the actual ogenki logo colour (dominant non-white pixel of `ogenki-blue-logo-only.png`). Reusing the drawio preset for callouts, badges and diagram legends makes site chrome and diagrams read as one system. |
| D5 | Multi-cloud: the IA splits **where ADR-0007 says the platform splits** | Infrastructure bootstrap branches per provider; everything from the CNI upward stays one narrative, because ADR-0007 already establishes those APIs as cloud-neutral. The docs inherit a boundary the platform has already reasoned about instead of inventing a second one. |
| D6 | Hosting: **GitHub Pages** at `cnref.ogenki.io`, build workflow + PR check | Matches the runlore setup. A root domain avoids `baseURL` subpath discipline. The PR check exists because this repository gates everything else in CI. |
| D7 | Process artifacts: **publish the method, not the artifacts** | The 51-file `docs/specs/` archive and 14 `docs/superpowers/` files stay on GitHub — publishing them would let stale archived specs dominate FlexSearch over ~45 curated pages. The *method* becomes a Concepts page, which is genuinely differentiating. |
| D8 | Cleanup: **verify-on-migrate** | No page moves without its file paths, commands, component lists and versions being checked against the current tree. Publishing known-wrong content at a URL that will be cited in talks is worse than publishing nothing. |
| D9 | Diagrams: **six new**, one per platform domain, plus the existing four pages | A domain section that opens with a wall of text loses the reader at exactly the moment they are deciding whether to continue. |

---

## Site foundation

### Layout and toolchain

```
website/
  hugo.yaml                    Hextra via Hugo Modules; refLinksErrorLevel: ERROR
  go.mod / go.sum              github.com/imfing/hextra, version-pinned
  assets/
    css/custom.css             ogenki palette overrides (~20 lines, no theme fork)
    diagrams/                  SVG exports consumed by content pages
  layouts/partials/custom/     head-end / footer hooks only
  content/                     see Information architecture
  static/
    CNAME                      cnref.ogenki.io
    favicon.*, images/         logo, og-card
```

Hugo Extended is pinned in the **root `mise.toml`** next to the existing tools. CI already uses
`jdx/mise-action@v4`, so local and CI resolve the same binary with no extra wiring. Hextra is
pinned in `website/go.mod`. Renovate's `config:recommended` already enables both the `gomod` and
`mise` managers, so no Renovate configuration change is needed.

`refLinksErrorLevel: ERROR` makes any unresolved `relref`/`ref` a build failure rather than a
silent 404 — this is the site's internal-link gate.

### Colour scheme

Hextra exposes its accent as three CSS custom properties, so this is an override, not a fork.

| Token | Light | Dark |
|---|---|---|
| `--primary-hue` / `--primary-saturation` / `--primary-lightness` | `204` / `100%` / `23%` — `#004675` | `204` / `62%` / `58%` — `#4FA8DA` |
| Body text | `#1E293B` | `#E2E8F0` |
| Surface | `#FFFFFF` | `#0F172A` |

Semantic colours, identical in both modes and identical to the `ogenki` drawio preset
(`~/.drawio-skill/styles/ogenki.json`):

| Role | Colour | Used for |
|---|---|---|
| service | `#6366F1` indigo | component callouts, diagram service boxes |
| security | `#7C3AED` violet | security notes, PKI/secrets diagram elements |
| storage / success | `#059669` emerald | success callouts, storage paths |
| scaling / warning | `#F59E0B` amber | warning callouts, autoscaling edges |
| failure | `#DC2626` red | danger callouts, failure paths |
| external / optional | `#94A3B8` slate | external systems, opt-in-and-currently-off |

Dark mode is the theme's `system` default with a visible toggle.

### Landing page

`content/_index.md`, `layout: hextra-home`:

1. **Hero** — one-sentence claim, plus two buttons: *Deploy in 30 minutes* and *GitHub*.
2. **The `platform-overview` diagram, inline.** For this project the architecture *is* the pitch;
   it belongs above the fold, not three clicks in.
3. **"What this repo is for" — 4 cards** mapping to the stated purposes: bootstrap a platform ·
   learn the concepts · evaluate the tools · demo it.
4. **"Browse the docs" — 6 cards**, one per top-nav lane.
5. **Stack strip** — the technology set, and "runs on: AWS today, GCP designed".

### Search

FlexSearch, `index: content`, `tokenize: forward`. Builds into the bundle; no external service, no
API key, works offline. This is the single strongest argument for Hextra over Docsy in this
repository.

---

## Information architecture

Top navigation: **Get Started · Platform · Concepts · Guides · Reference · Decisions**, plus GitHub
and Search.

```
website/content/
  _index.md                              landing page
  docs/
    get-started/
      _index.md                          what you get, choose your cloud, time & cost
      prerequisites.md
      aws/
        _index.md                        deploy: network -> openbao -> eks init -> eks configure
        access.md                        Tailscale, kubeconfig, bao login, platform dashboard
        teardown.md
      gcp/
        _index.md                        planned; links the GCP design + ADR-0005/0006/0007
      first-app.md                       deploy your first App claim

    platform/
      foundations/
        _index.md                        the three-stage model, why OpenTofu, why Terramate
        aws.md                           stacks, two-stage EKS bootstrap, OpenBao cluster
        gcp.md                           planned
      gitops/
        _index.md                        Flux model + dependency hierarchy
        repository-structure.md
        validation.md                    the SPEC-007 render-and-gate pipeline
      networking/
        _index.md                        request path overview
        cilium.md                        eBPF datapath, prefix delegation, WireGuard, policies
        gateway-api.md                   gateways, HTTPRoutes, TLS, ExternalDNS
        private-access.md                Tailscale, the two gateways, ACL tags
      security/
        _index.md                        the zero-trust model end to end
        openbao.md                       cluster, management stack, namespaces, operations
        pki-and-secrets.md               root -> intermediate -> leaf, cert-manager, ESO
        policies.md                      Kyverno, CiliumNetworkPolicy, pod security standards
      developer-platform/
        _index.md                        Crossplane, the abstraction, progressive complexity
        app.md                           the App composition end to end
        data-services.md                 SQLInstance, KVStore, S3 buckets
        app-wizard.md                    the self-service UI
      observability/
        _index.md                        the stack and why VictoriaMetrics
        metrics.md
        logs.md
        dashboards-and-alerts.md
        postgresql.md                    CloudNativePG monitoring
      ai-platform/
        _index.md                        self-hosted LLM platform (opt-in)
        coding-clients.md
        roadmap.md                       remaining upgrade paths

    concepts/
      _index.md
      architecture.md
      progressive-complexity.md
      gitops-model.md
      zero-trust.md
      technology-choices.md
      how-this-is-built.md               NEW — the design method and the gates

    guides/
      _index.md
      fork-and-adapt.md                  NEW — use this repo for your own platform
      add-an-application.md
      add-a-cloud-provider.md            NEW — what a new provider must implement
      troubleshooting.md

    reference/
      _index.md
      repository-layout.md
      technology-stack.md
      commands.md
      ci-workflows.md
      platform-constitution.md
      glossary.md                        NEW

    decisions/
      _index.md
      0001-use-kcl-for-crossplane-compositions.md
      ... 0007-cloud-abstraction-boundaries.md
      template.md
```

### How the multi-cloud boundary is expressed

ADR-0007 establishes: **platform-facing APIs are cloud-shaped; developer-facing APIs are
cloud-neutral.** The IA mirrors it exactly.

| Layer | Docs treatment | Why |
|---|---|---|
| Infrastructure bootstrap — VPC, cluster, IAM/identity, secrets store | Per-provider pages: `get-started/<cloud>/`, `platform/foundations/<cloud>.md` | Genuinely different stacks, different identity models, different commands. Forcing this into tabs makes the longest and most important page the least readable. |
| CNI upward — GitOps, networking, developer platform, observability | Single narrative; `{{< tabs items="AWS,GCP" >}}` only where a specific command or manifest differs | ADR-0007 already declares these neutral. Duplicating them produces two copies that drift. |

Cloud number three adds two directories and some tab entries. It does not need a reorganisation.

---

## Content migration map

Every row is **verify-on-migrate**: before a page lands in `website/content/`, each referenced file
path must still exist, each command must match `workflows.tm.hcl` / `scripts/`, each component list
must match what Flux actually deploys, and each version must match `mise.toml`, `config.tm.hcl` or
the relevant HelmRelease. Anything that cannot be verified is cut or explicitly marked a known gap.

| Source | Lines | Destination | Action |
|---|---|---|---|
| `README.md` (Quickstart, Prerequisites, Platform Dashboard) | — | `get-started/**` | split; verify every command |
| `docs/opentofu.md` | 739 | `get-started/prerequisites.md`, `platform/foundations/{_index,aws}.md` | split by *why* vs *AWS specifics*; last touched 2026-03, re-verify |
| `docs/gitops.md` | 767 | `platform/gitops/{_index,repository-structure}.md` | split; verify the dependency hierarchy against `clusters/mycluster-0/` |
| `docs/ci-workflows.md` | 259 | `platform/gitops/validation.md`, `reference/ci-workflows.md` | split: the validation pipeline is platform content, the workflow inventory is reference |
| `docs/ingress.md` | 723 | `platform/networking/{_index,gateway-api}.md` | **merge** with the file below, de-duplicate |
| `docs/tailscale-gateway-api.md` | 291 | `platform/networking/private-access.md` | **merge**; last touched 2025-12, heavy overlap with `ingress.md` |
| *(new)* | — | `platform/networking/cilium.md` | written from `opentofu/aws/eks/configure/`, `helm_values/cilium.yaml` and CLAUDE.md's prefix-delegation / WireGuard notes |
| `opentofu/aws/openbao/cluster/docs/getting_started.md` | 144 | `platform/security/openbao.md` | **promote** — currently four directories deep |
| `opentofu/aws/openbao/cluster/docs/pki_requirements.md` | 162 | `platform/security/pki-and-secrets.md` | promote |
| `opentofu/aws/openbao/management/docs/cert-manager.md` | 218 | `platform/security/pki-and-secrets.md` | promote, merge |
| `opentofu/aws/openbao/management/docs/approle.md` | 48 | `platform/security/openbao.md` | promote, merge |
| `opentofu/aws/openbao/management/docs/backup_restore.md` | 131 | `platform/security/openbao.md` | promote, merge |
| `docs/crossplane.md` | 670 | `platform/developer-platform/_index.md` | trim the composition-authoring content — it belongs in `Smana/crossplane-configuration` |
| `docs/apps-user-guide.md` | 1046 | `platform/developer-platform/{app,data-services}.md`, `get-started/first-app.md`, `guides/add-an-application.md` | the largest split; 12 numbered sections redistributed |
| `docs/app-wizard.md` | 238 | `platform/developer-platform/app-wizard.md` | move |
| `docs/assets/app-wizard/` | 1 file | `website/assets/screenshots/app-wizard/` | move; the README records what each of the 5 still-uncaptured screenshots should show |
| `docs/observability.md` | 878 | `platform/observability/{_index,metrics,logs,dashboards-and-alerts}.md` | **stale since 2025-11** — hardest verification in the migration |
| `docs/postgresql-monitoring-architecture.md` | 451 | `platform/observability/postgresql.md` | stale since 2025-11; verify against the CNPG manifests and the SPEC-010 Barman work |
| `docs/ai.md` | 385 | `platform/ai-platform/_index.md` | move |
| `docs/coding-clients.md` | 212 | `platform/ai-platform/coding-clients.md` | move |
| `docs/llm-platform-future-paths.md` | 194 | `platform/ai-platform/roadmap.md` | **drop shipped paths** — path 4 (InferencePool + EPP) shipped as SPEC-004/SPEC-011 |
| `docs/technology-choices.md` | 221 | `concepts/technology-choices.md` + `reference/technology-stack.md` | split: philosophy and rationale vs the version table |
| `docs/platform-constitution.md` | 243 | `reference/platform-constitution.md` | move; `.claude/rules/platform-constitution.md` re-pointed |
| `docs/decisions/**` | 9 files | `decisions/**` | move; 12 inbound links rewired |
| `README.md` (Core Concepts, Architecture) | — | `concepts/**` | split |
| `CLAUDE.md` (Common Commands, Troubleshooting) | — | `reference/commands.md`, `guides/troubleshooting.md` | CLAUDE.md keeps its copy — it is the agent contract, not site content |

### New pages with no source

| Page | Content |
|---|---|
| `concepts/how-this-is-built.md` | The design method: brainstorm → design → plan → subagent execution → verification. Why a platform constitution exists, which gates enforce it, how AI-assisted development is actually used here. Links to real examples in `docs/superpowers/` on GitHub. |
| `guides/fork-and-adapt.md` | The missing guide. Which values are environment-specific (domain, region, cluster name, GitHub App, Tailscale tailnet, AWS account), what to strip out, what the minimum viable subset is, what it costs to run. |
| `guides/add-a-cloud-provider.md` | ADR-0007's rule made operational: what a new provider must implement, which abstractions must gain a sibling, which must not. |
| `platform/networking/cilium.md` | The eBPF datapath story, currently only in CLAUDE.md and inline comments. |
| `reference/glossary.md` | Claim, composition, XR, XRD, EPI, stack, reconciliation, drift, tenant, prefix delegation. |
| `get-started/gcp/_index.md` | Stub — states GCP is designed but not implemented, links the design and ADRs 0005/0006/0007. |

### Deletions

| File | Reason |
|---|---|
| `docs/plans/crossplane-validation-improvements.md` | Superseded by SPEC-007 (`flux schema validate` + Polaris) |
| `docs/crossplane-kcl-authoring.md` | Authoring guide for KCL that no longer lives here; content belongs in `Smana/crossplane-configuration`. Replaced by a pointer inside `platform/developer-platform/_index.md` |
| `docs/technology-choices.md` | Split into two destinations |
| `docs/tailscale-gateway-api.md` | Merged into `platform/networking/` |
| all other `docs/*.md` | Moved (see map) |

After migration `docs/` contains exactly `architecture/`, `specs/`, `superpowers/`.

The root `README.md` shrinks to roughly 120 lines: what this is, the architecture diagram, a
six-command quickstart, repository structure, and a prominent link to `cnref.ogenki.io`. GitHub
remains many readers' first impression, so it stays substantial — it just stops being a second
documentation site.

---

## Diagrams

`.drawio` sources stay in `docs/architecture/` per the established convention, kebab-case, using
the **ogenki** preset. Exports are written to `website/assets/diagrams/`.

| # | File | Shows | Used by |
|---|---|---|---|
| 1 | `bootstrap-stages.drawio` | network → OpenBao → EKS init → EKS configure, and what each stage creates | `get-started/`, `platform/foundations/` |
| 2 | `flux-dependency-tree.drawio` | namespaces → CRDs → Crossplane → EPIs → security → infrastructure → observability → apps | `platform/gitops/` |
| 3 | `request-path.drawio` | internet / Tailscale → gateway → HTTPRoute → app, with ExternalDNS and cert-manager alongside | `platform/networking/` |
| 4 | `secrets-and-pki.drawio` | root → intermediate → leaf; ESO pulling from AWS Secrets Manager and OpenBao into Kubernetes Secrets | `platform/security/` |
| 5 | `app-claim-expansion.drawio` | one `App` claim → Deployment, Service, HTTPRoute, HPA, PDB, CiliumNetworkPolicy, SQLInstance, EPI, Bucket | `platform/developer-platform/`, landing page |
| 6 | `observability-flow.drawio` | scrape → vmagent → VictoriaMetrics; Vector → VictoriaLogs; Grafana; alerts → OnCall/Slack | `platform/observability/` |
| — | `platform-overview.drawio` | existing | landing page, `concepts/architecture.md` |
| — | `llm-platform.drawio` (3 pages) | existing | `platform/ai-platform/` |

**Export format: SVG.** The PNG-only constraint recorded in `docs/architecture/README.md` exists
because GitHub's sanitizer strips `<foreignObject>` text from drawio SVG. That constraint does not
apply to a Hugo site, and SVG stays crisp at any zoom and works with Hextra's `imageZoom`. PNG is
retained only for `platform-overview`, which is also embedded in the GitHub README.

**Size budget: 500 KB per asset.** `platform-overview.png` is already 949 KB against pre-commit's
1000 KB `check-added-large-files` ceiling. SVG carrying the same base64-embedded logos lands around
150–250 KB.

`scripts/export-diagrams.sh` wraps the per-file drawio CLI invocations so regenerating all nine is
one command. Export drift is **not** CI-gated — headless drawio needs Electron plus xvfb, which is
disproportionate. Regeneration stays a documented step in `docs/architecture/README.md`.

---

## CI and tooling wiring

### New workflows

```yaml
# .github/workflows/docs.yml
on:
  push:
    branches: [main]
    paths: ['website/**', 'docs/architecture/**', '.github/workflows/docs.yml']
# mise install -> hugo --minify --gc -> actions/upload-pages-artifact -> actions/deploy-pages

# .github/workflows/docs-check.yml
on:
  pull_request:
    paths: ['website/**', 'docs/architecture/**', '.github/workflows/docs-check.yml']
# mise install -> hugo --minify
# refLinksErrorLevel: ERROR makes a dead relref a build failure
```

### Edits to existing tooling

| File | Change | Why |
|---|---|---|
| `mise.toml` | add `hugo` (extended), pinned | one toolchain for local and CI; Renovate tracks it |
| `scripts/validate-links.sh` | exclude `website/content/**` | Hugo's `refLinksErrorLevel: ERROR` is authoritative inside the site; the script stays authoritative for the rest of the repo. Two gates, no overlap, no double-reporting. |
| `.linkcheck-allow` | drop the five `docs/app-wizard.md` screenshot entries | they move with the page; the allowlist should end empty |
| `.github/workflows/ci.yaml` | unchanged | the `links` job keeps running `validate-links.sh` over the non-site tree |
| `.github/renovate.json` | unchanged | `config:recommended` already enables the `gomod` and `mise` managers |
| `.pre-commit-config.yaml` | unchanged | `markdownlint` is already commented out, so Hugo shortcodes cannot trip it |

### Path rewiring inventory

| Consumer | References | Action |
|---|---|---|
| `README.md` | 14 links into `docs/*.md` | rewritten to `https://cnref.ogenki.io/docs/...` or removed with the shrink |
| `CLAUDE.md` | `docs/platform-constitution.md`, `docs/tailscale-gateway-api.md`, `docs/specs/` | re-pointed |
| `.claude/rules/platform-constitution.md` | `docs/platform-constitution.md` ×2 | re-pointed to `website/content/docs/reference/` |
| `.claude/rules/superpowers.md`, `.claude/rules/crossplane-validation.md`, `.claude/rules/process.md` | constitution and ADR paths | re-pointed |
| `.claude/skills/spec-research/SKILL.md` | `docs/platform-constitution.md` | re-pointed |
| `docs/specs/**` (8 files), `docs/superpowers/**` (3 files) | `docs/decisions/000*` | rewritten to the new location, **not** allowlisted |

`./scripts/validate-links.sh` exiting 0 with an empty allowlist is the gate on this table.

---

## Migration sequence

One branch, one pull request, ordered commits so each is independently reviewable.

| # | Commit | Contents |
|---|---|---|
| 1 | scaffold | `website/` skeleton, `hugo.yaml`, `go.mod`, `custom.css`, `CNAME`, both workflows, `mise.toml` pin. Site builds and deploys, empty. |
| 2 | shell | landing page, navigation, the six section `_index.md` files, footer, favicons, OG card |
| 3–8 | content, one lane per commit | get-started → platform → concepts → guides → reference → decisions, each verify-on-migrate |
| 9 | diagrams | six new `.drawio`, exports, `scripts/export-diagrams.sh`, embedded in their pages |
| 10 | rewiring | README shrink, CLAUDE.md and `.claude/**` path updates, `docs/` deletions, `validate-links.sh` scoping, `.linkcheck-allow` emptied |
| 11 | diagram index | `docs/architecture/README.md` refreshed for the new set and the SVG convention |

The `platform` lane in step 3–8 is the largest and is subdivided per domain directory.

---

## Risks

| Risk | Mitigation |
|---|---|
| `observability.md` (878 lines, stale 9 months) is largely wrong and verification balloons | Verify section by section against the deployed manifests; cut what cannot be verified rather than carry it. If a section needs a rewrite beyond migration scope, publish the verified remainder and record the gap explicitly on the page. |
| The `docs/decisions/` move breaks links inside the read-only spec archive | 12 inbound references, enumerated above. Rewritten, not allowlisted. `validate-links.sh` is the gate. |
| Splitting `apps-user-guide.md` (1046 lines) across four destinations loses content | Section-by-section checklist against the original's 12 numbered sections before the source file is deleted. |
| DNS is outside this repository | `cnref.ogenki.io CNAME smana.github.io` is a manual prerequisite. This repository manages only the private zone `priv.cloud.ogenki.io` (`opentofu/aws/network/route53.tf`). The site builds and deploys to `smana.github.io/cloud-native-ref` until the record exists. |
| SVG exports with embedded base64 logos exceed the 1000 KB pre-commit ceiling | 500 KB budget per asset, checked at export time. |
| Site and repository drift after launch | `refLinksErrorLevel: ERROR` catches internal rot; `validate-links.sh` catches the rest; verify-on-migrate establishes the norm that a page states what it was checked against. |

---

## Prerequisites

1. DNS: `cnref.ogenki.io CNAME smana.github.io` in the public `ogenki.io` zone (manual, outside this repository).
2. GitHub Pages enabled for the repository with source set to GitHub Actions.

---

## Success criteria

| Criterion | Evidence |
|---|---|
| Site builds clean | `hugo --minify` in `website/` → exit 0, zero `REF_NOT_FOUND` |
| No link rot anywhere in the repository | `./scripts/validate-links.sh` → exit 0, `.linkcheck-allow` empty |
| Migration complete | `docs/` contains exactly `architecture/`, `specs/`, `superpowers/` |
| Search works | "wireguard", "prefix delegation", "AppRole", "progressive complexity" each return the correct page as the first hit |
| Landing page does its job | a first-time reader can state what the repository is for and reach the deploy path in one click |
| Accessibility and performance | Lighthouse ≥ 95 accessibility, ≥ 90 performance on the landing page |
| Diagrams present | six new diagrams rendered on their domain pages; every **new** export under 500 KB (the retained `platform-overview.png` stays at its current 949 KB) |
| Multi-cloud ready | `get-started/gcp/` and `platform/foundations/gcp.md` exist as stubs; no cloud-neutral page contains AWS-only content |
| Published | `https://cnref.ogenki.io` serves the site over HTTPS |
