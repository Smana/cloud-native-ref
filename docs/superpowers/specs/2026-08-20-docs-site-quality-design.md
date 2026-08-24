# Documentation Site — Quality Pass

**Date:** 2026-08-20
**Status:** design approved
**Branch:** `feat/docs-site-quality`
**Related:** [Documentation Site design](2026-08-20-docs-hugo-site-design.md), [plan](../plans/2026-08-20-docs-hugo-site.md)

---

## Why this design exists

The site shipped in #1794/#1798/#1799 meets every success criterion its own design set:
`hugo --minify --gc` is clean, `validate-links.sh` and `verify-doc-paths.sh` both exit 0, and
the content is genuinely verified — the version table matches every pin re-read from
`mise.toml`, `opentofu/config.tm.hcl` and the HelmReleases, and the observability page names
the one component (`grafana-oncall`) that is built but wired to nothing.

What it does not yet do is *read* well in four specific places, plus three defects that only
appear in the production build.

| Problem | Evidence |
|---|---|
| Flux is under-described | `platform/gitops/_index.md` has a five-bullet "Why Flux" and then 60 lines of prose walking `dependsOn` edges. No page on the site describes the Flux **resource model** — `FluxInstance`, `GitRepository`, `ArtifactGenerator`, `Kustomization`, `HelmRelease` — or how to observe a reconciliation. |
| The directory tree is not visible | It exists once, in `reference/repository-layout.md`, three lanes away from GitOps. Seven of its thirteen entries are `filetree/folder` with `state="closed"`, so they render as bare one-word rows with their descriptions hidden behind a click; the other six use `filetree/file`, so directories render with **file** icons. |
| CI is thinly documented | `reference/ci-workflows.md` has three inbound links and no diagram, and never mentions that `ci.yaml`'s `pre-commit` job runs through `dagger/dagger-for-github` → `Smana/daggerverse/pre-commit-tf` — it claims the check is reproduced locally by `pre-commit run --all-files`. |
| The technology stack is visually flat | Seven consecutive tables, no logos, and a `Pinned in` column that repeats `mise.toml` eleven times in the CLI section alone. |
| Footer misattributes the site | Hextra's `i18n/en.yaml` sets `copyright: "© 2026 Hextra Project."` and the site never overrides it. Every page carries it. |
| Open Graph tags are broken **in production only** | Hextra's `_partials/opengraph.html` emits `og:description` and `og:type` as multi-line HTML attributes. The dev server renders them correctly; `hugo --minify` — what `docs.yml` ships — collapses them to whitespace, and the minifier then drops the attribute. There is no `og:image` at all. Every link shared to Slack, LinkedIn or X renders a bare card. |
| A README states something untrue | `website/assets/screenshots/app-wizard/README.md` says its five PNGs "are referenced by `app-wizard.md`". The page contains zero image references and the PNGs do not exist. |
| The AI platform is one page doing a domain's work | `platform/ai-platform/_index.md` is 230 lines with **two** code blocks, both `bash` gate commands. The `InferenceService` claim the domain is built on is never shown; `apps/base/ai/llm/qwen-coder-fim.yaml` carries thirty lines of rationale that reach no reader. There is no "why self-host" — the one question every other domain page answers — and no worked request. Developer Platform has five pages for a simpler API. |
| The SRE agent is undocumented | RunLore appears in ten places — a component-table row, a dashboard row, two alert rows, a PromQL example, an `HTTPRoute` footnote — and has no page. Nothing on the site says what it is, what it does with an alert, or that it is read-only. It is among the most distinctive things running on this cluster. |

The site's stated purpose is demo material. A broken social card and an invisible directory
tree both fail that purpose at exactly the moment someone else encounters the project.

## Goals

1. Flux described as a system — its resources, its intervals, and how to watch it work.
2. The repository tree visible without a click, on the page where it is relevant.
3. CI documented per job, including what actually blocks a merge, with a diagram.
4. The technology stack rendered with logos, from data rather than hand-written tables.
5. The production build's Open Graph tags, footer attribution and reading polish fixed.
6. The AI platform split into a lane, with the `InferenceService` claim finally shown.
7. The SRE agent given a page of its own.

## Non-goals

- Restructuring the information architecture. The six lanes stay as they are.
- Re-verifying content that `verify-doc-paths.sh` and the 2026-08-20 migration already checked.
- Capturing the five missing App Wizard screenshots (needs a running wizard). The README is
  corrected to say they are pending; the capture is left as recorded work.
- Forking the Hextra theme. Every change is an override or an addition.

---

## Decisions

| # | Decision | Rationale |
|---|---|---|
| D1 | Hand-written content that appears twice becomes **data plus one renderer** | The tech table is maintained by hand in seven sections and the tree exists once and is invisible. Both need to appear in two places. A `data/` file with a shortcode is the only shape that gives two renderings without two copies to drift. |
| D2 | The tree is a **project shortcode**, not Hextra's `filetree` | `filetree/folder` accepts only a `name`, so descriptions have to be smuggled into the folder label, and its `state` attribute hides content by default. A project shortcode reading `data/repo-tree.yaml` renders correct icons, always-visible descriptions, and an owning-Kustomization column the theme has no concept of. |
| D3 | Logos are **bundled official SVGs**, not an icon font or a CDN | Crisp at any size, no external request from a page that must work offline, and no dependency on a third party's uptime for the project's own branding. Monochrome sets (Simple Icons) have no entry for Cilium, Crossplane, OpenBao, VictoriaMetrics, Karpenter or Terramate — precisely this platform's distinctive half. |
| D4 | A component with no usable mark gets a **typographic tile**, not a gap | A logo strip with holes reads as broken. A tile in the ogenki palette reads as intentional. |
| D5 | `opengraph.html` is **overridden in the project**, not worked around | The bug is whitespace inside an HTML attribute. Only the template can fix it; `params.images` alone would add `og:image` and leave `og:description` empty. |
| D6 | The GitOps prose is **cut**, not appended to | The page is already 110 lines and the new material is three sections. The `dependsOn` walk duplicates the diagram beside it and the table below it; it collapses into them. |
| D7 | CI keeps its **existing split** | The parent design deliberately put the validation pipeline in Platform and the workflow inventory in Reference. That split is right; the gap was depth and discoverability, not location. |
| D8 | The AI platform becomes a **four-page lane**, mirroring Developer Platform | The IA already establishes that a domain gets an index plus a page per major surface. AI Platform is the only domain that violates it, and it is the domain with the most novel material. Splitting it is applying the existing rule, not inventing one. |
| D9 | The `InferenceService` page shows a **real claim with its comments intact** | `qwen-coder-fim.yaml` explains why the base variant beats the Instruct fine-tune for FIM, why `maxNumSeqs: 64`, and why the NodePool uses `consolidationPolicy: WhenEmpty` to stop Karpenter consolidating an always-warm pod. Stripping that commentary to a bare YAML block would discard the most instructive content in the repository. |
| D10 | The SRE agent gets a page under **Observability**, not Tooling or AI Platform | It is deployed by the `observability` Kustomization, alerts on itself through the same `VMRule` mechanism, and exists to consume Alertmanager output. Its dependencies and its purpose are both observability; being LLM-backed is an implementation detail, not a lane. |

---

## Data model

### `website/data/stack.yaml`

```yaml
groups:
  - id: cli
    title: CLI tools
    pin_note: "`mise.toml`"        # hoisted out of the per-row column when every row shares it
    items:
      - name: OpenTofu
        version: "1.12.6"
        logo: opentofu             # -> static/images/logos/opentofu.svg
        url: https://opentofu.org
      - name: Terramate
        version: "0.17.2"
        logo: terramate
        url: https://terramate.io
  - id: infrastructure
    title: Infrastructure
    items:
      - name: Cilium
        version: "1.20.0"
        logo: cilium
        pin: "`opentofu/config.tm.hcl` — `cilium_version`"
        url: https://cilium.io
        note: ""                   # optional, rendered under the row
```

Rules the shortcodes enforce:

- `pin_note` on a group hoists a shared pin out of the per-row column — this is what removes
  the eleven repeated `mise.toml` cells.
- `logo` omitted, or the file missing, renders the typographic tile (D4). It is never an error,
  because a missing logo must not fail a build that is otherwise correct.
- `version` may be the literal string `not pinned in this repo`, preserving the existing page's
  refusal to guess a number.

The strip on the landing page renders a curated subset — a `strip: true` flag per item — because
forty-five marks is a wall, not a strip.

### `website/data/repo-tree.yaml`

```yaml
entries:
  - path: opentofu/
    kind: dir
    desc: VPC, EKS, OpenBao — everything that must exist before a Kubernetes API does
    owner: "OpenTofu / Terramate"
    children:
      - path: network/
        kind: dir
        desc: VPC, subnets, Route53, Tailscale VPN
  - path: infrastructure/
    kind: dir
    desc: Cilium, Crossplane, Karpenter, Gateway API, CSI drivers
    owner: "`infrastructure` Kustomization"
```

`owner` is the column the current tree cannot express and the GitOps page most needs: which
Flux `Kustomization` reconciles this directory, or `OpenTofu / Terramate` for the pre-Kubernetes
half. The shortcode takes a `depth` parameter so the GitOps page can render the top level only
while the Reference page renders the full tree.

---

## Page changes

### `platform/gitops/_index.md`

```
What GitOps means here            keep, tighten
The Flux resource model           NEW
The repository, as Flux sees it   NEW — {{< repo-tree depth="1" >}}
The dependency hierarchy          diagram + fork table; the prose walk is cut
Observing and operating           NEW
Validation before any of this     keep
```

**The Flux resource model** is a table, one row per CRD actually in use, each row naming the
real file in this repository so the reader can go look at it:

| Resource | What it does here | Where |
|---|---|---|
| `FluxInstance` | Flux Operator manages Flux's own lifecycle | `opentofu/aws/eks/init/helm_values/flux-instance.yaml` |
| `GitRepository` | one source, `flux-system`, GitHub App auth | created by Stage 2 |
| `ArtifactGenerator` → `ExternalArtifact` | re-slices that one artifact per domain | `flux/artifact-generators/monorepo-split.yaml` |
| `Kustomization` | applies one domain, with `dependsOn`, `prune`, health checks | `clusters/mycluster-0/*.yaml` |
| `HelmRelease` + `HelmRepository`/`OCIRepository` | every upstream chart | `flux/sources/` |
| `Alert` / `Provider` | reconciliation failures to Slack | `flux/notifications/` |
| `ResourceSet` | preview environments | `flux/previews/` |

plus prose on intervals, `prune`, `wait`, health checks and drift correction — the properties
that make the difference between "Flux applied it" and "Flux keeps it true".

**Observing and operating** is the command surface: `flux get all`, `flux tree kustomization`,
`flux events`, suspend/resume, forced reconcile, where the Flux Grafana dashboards live, and a
pointer to the `gitops-cluster-debug` skill.

### `reference/repository-layout.md`

The `filetree` block is replaced by `{{< repo-tree >}}`. The surrounding prose — base/overlay,
two deployment models, opt-in surfaces — is unchanged apart from one stale phrase: `docs/` is
described as "the pre-site documentation source", which it no longer is.

### `reference/ci-workflows.md`

Rewritten around one table — **trigger · what it runs · does it block the merge** — with:

- the Dagger module the `pre-commit` job actually uses, and the honest statement of what
  `pre-commit run --all-files` does and does not reproduce;
- which checks branch protection requires versus which are informational (`render-diff` posts a
  comment and never gates);
- the new `ci-pipeline` diagram.

### `reference/technology-stack.md`

Prose and the verified-pins preamble stay verbatim; the seven hand-written tables become seven
`{{< stack-table group="…" >}}` calls.

### `content/_index.md`

Gains the stack strip below the feature grids. The inline-styled `<h2>`s become real classes.

### `platform/ai-platform/`

```
_index.md               what it is · why self-host · the two gates · child
                        Kustomizations · security posture · known gaps   (<130 lines)
inference-service.md    NEW — a complete real claim, what it renders, the field reference,
                        and the model fleet table moved down from the index
gateway-and-routing.md  NEW — request path, API-key auth, the EnvoyPatchPolicy ordering,
                        `model: MoM` semantic routing, and a worked curl
autoscaling-and-gpu.md  NEW — the three KEDA triggers, the scale-from-zero deadlock
                        `min=1` avoids, the gpu-l4 NodePool, S3 Files weights
coding-clients.md       unchanged
roadmap.md              unchanged
```

Every section moved out of the index is deleted from it, not duplicated. The three existing
`llm-platform-*.svg` diagrams move to the sub-pages they illustrate.

### `platform/observability/sre-agent.md`

New. What RunLore is, what happens to an alert end to end, the knowledge-base repository and
recall, how it is deployed (`HelmRelease` from a `flux/sources/` `GitRepository`, HA
`StatefulSet` with leader election), its secrets, its own dashboard and twelve alerts, and its
gaps. Two facts are load-bearing because both have caused incidents: the image tag and the
`GitRepository` ref must move together, and the source lives under `flux/sources/` because a
source under an app-owned directory inherits the `apps` shard label and becomes invisible to
the default controller.

---

## Diagram

`docs/architecture/ci-pipeline.drawio`, ogenki preset, exported to
`website/static/images/diagrams/ci-pipeline.svg` and added to `scripts/export-diagrams.sh` and
`docs/architecture/README.md`.

Shows: a pull request fanning into `ci.yaml`'s six jobs plus the two path-filtered docs
workflows; which of them are required checks; the merge; and Flux picking up `main` — closing
the loop that CI never applies anything itself.

---

## Frontend

| Change | File |
|---|---|
| Footer attribution | `website/i18n/en.yaml` — overrides the theme's `copyright` string |
| Footer link row | `website/layouts/_partials/custom/footer.html` — extends the existing verification stamp |
| Open Graph fix | `website/layouts/_partials/opengraph.html` — project override, whitespace-tight |
| Social card | `website/static/images/og-card.png`, 1200×630, wired via `params.images` in `hugo.yaml` |
| Section headings, stack strip and table, repo tree, diagram figure, card hover, `scroll-margin-top` | `website/assets/css/custom.css` |

The OG card is authored as a standalone HTML file and screenshotted at exactly 1200×630 rather
than hand-drawn, so it can be regenerated from source when the title or palette changes.

Every colour added to `custom.css` is checked for 4.5:1 against both themes' page grounds,
matching the discipline the file already documents at length.

---

## Risks

| Risk | Mitigation |
|---|---|
| Logo licensing — some marks carry trademark restrictions | `static/images/logos/LICENSES.md` records source URL and terms per file. Nominative use to identify the software a platform runs is the standard case these guidelines permit; anything whose terms do not permit it gets the typographic tile instead. |
| A logo is dark-on-transparent and vanishes on the dark theme | Per-file dark variant, swapped by CSS the way the navbar mark already is. Checked visually in both themes, not assumed. |
| Overriding `opengraph.html` means diffing it on the next Hextra bump | Same contract as the existing `render-image.html` override, which already carries that instruction in its header comment. The new file gets the same note. |
| The GitOps prose cut loses a fact that only existed there | The cut sections are compared line by line against the diagram and the fork table before deletion; anything present in neither is kept. |
| `data/stack.yaml` drifts from the pins the way the prose table would have | It does not remove the need to re-verify, but it moves 45 versions into one file where a single `grep` compares them against the repo. Recorded as a follow-up, not solved here. |

---

## Success criteria

| Criterion | Evidence |
|---|---|
| Site builds clean | `hugo --minify --gc` → exit 0, zero `REF_NOT_FOUND` |
| No link rot | `./scripts/validate-links.sh` → exit 0, allowlist empty |
| No stale paths in prose | `./scripts/verify-doc-paths.sh` → exit 0 |
| Open Graph fixed **after minification** | `grep` over `public/` shows non-empty `og:description`, `og:type` and `og:image` on the landing page and on a doc page |
| Footer attributes the site correctly | no occurrence of "Hextra Project" in `public/` |
| Tree visible without interaction | rendered HTML contains every entry's description; no `data-state="closed"` in the tree markup |
| Flux described | `platform/gitops/_index.md` names `FluxInstance`, `ArtifactGenerator`, `HelmRelease`, `ResourceSet` and the observation commands, each against a real path that `verify-doc-paths.sh` accepts |
| CI described | every job in `.github/workflows/ci.yaml` appears in the page's table; Dagger named |
| Logos render | every `stack.yaml` item resolves to a logo or a tile; no broken image in either theme |
| AI platform split loses nothing | every backticked token in the pre-split `_index.md` still appears somewhere in the four resulting pages, or its removal is justified |
| The `InferenceService` claim is shown | `platform/ai-platform/inference-service.md` contains a complete claim and a field reference covering `model`, `gpu`, `scaling` and `gateway` |
| The SRE agent is described | `platform/observability/sre-agent.md` exists, is linked from the observability index, and states the read-only boundary and the two incident-causing facts |
| Accessibility and performance | Lighthouse ≥ 95 accessibility, ≥ 90 performance on the landing page |
| Both themes | screenshots of landing, GitOps and Technology Stack in light and dark |
