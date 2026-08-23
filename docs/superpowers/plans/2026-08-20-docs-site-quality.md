# Documentation Site Quality Pass — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Describe Flux properly with the directory tree visible, document CI per job with a diagram, render the technology stack from data with logos, and fix the production-only defects in the site's footer and Open Graph tags.

**Architecture:** Content that appears in two places becomes a `website/data/*.yaml` file with one project shortcode rendering it, so there is no second copy to drift. Everything else is a Hugo template override or an addition — the Hextra theme is never forked.

**Tech Stack:** Hugo 0.156.0 extended, Hextra v0.12.3 (Hugo Module), Go templates, drawio CLI, chrome-devtools MCP for the OG card render and Lighthouse.

**Design:** [`docs/superpowers/specs/2026-08-20-docs-site-quality-design.md`](../specs/2026-08-20-docs-site-quality-design.md)

## Global Constraints

- **Never fork the theme.** Every template change is a file under `website/layouts/` that shadows a Hextra path, and carries a header comment naming the theme file and version it was copied from — matching the convention in `website/layouts/_markup/render-image.html`.
- **`hugo --minify --gc` must exit 0 with zero `REF_NOT_FOUND`.** `refLinksErrorLevel: ERROR` is the site's internal link gate.
- **`./scripts/validate-links.sh` must exit 0 with `.linkcheck-allow` empty.** Never add an allowlist entry.
- **`./scripts/verify-doc-paths.sh` must exit 0.** It walks `git ls-files`, so `git add` before running it or a new page is not checked at all.
- **Every backticked repository path written into a page must exist.** That is what the script above enforces.
- **Every colour added to `website/assets/css/custom.css` holds 4.5:1** against both themes' page grounds (`#FFFFFF` light, `#0F172A` dark), and the file records the measured ratio in a comment — matching the existing entries.
- **Diagram SVG exports stay under 500 KB.** Budget from the parent design.
- **Verification before completion**: no task is marked done without its verification command run fresh in the same response, with output cited.

---

## File Structure

| File | Responsibility | Task |
|---|---|---|
| `website/i18n/en.yaml` | Override the theme's `copyright` string | 1 |
| `website/layouts/_partials/opengraph.html` | Whitespace-tight OG tags that survive `--minify` | 1 |
| `website/static/images/og-card.png` | 1200×630 social card | 1 |
| `scripts/build-og-card.html` | Source the card is rendered from | 1 |
| `website/data/repo-tree.yaml` | The directory tree, once | 2 |
| `website/layouts/_shortcodes/repo-tree.html` | Renders the tree at a given depth | 2 |
| `website/content/docs/reference/repository-layout.md` | Consumes the tree shortcode | 2 |
| `website/content/docs/platform/gitops/_index.md` | Flux resource model, tree, observation | 3 |
| `docs/architecture/ci-pipeline.drawio` | CI pipeline diagram source | 4 |
| `website/static/images/diagrams/ci-pipeline.svg` | Its export | 4 |
| `website/content/docs/reference/ci-workflows.md` | Per-job CI reference | 4 |
| `website/data/stack.yaml` | Every component, version, pin, logo | 5 |
| `website/static/images/logos/*.svg` | Bundled official marks | 5 |
| `website/static/images/logos/LICENSES.md` | Source and terms per mark | 5 |
| `website/layouts/_shortcodes/stack-table.html` | One group as a table with logos | 5 |
| `website/layouts/_shortcodes/stack-strip.html` | The landing-page logo strip | 6 |
| `website/content/_index.md` | Strip + real heading classes | 6 |
| `website/assets/css/custom.css` | All new styling, appended | 2,5,6,7 |
| `website/layouts/_partials/custom/footer.html` | Footer link row | 7 |

---

## Task 1: Fix the production-only defects

The footer misattributes the site and the Open Graph tags are destroyed by `--minify`. Both are invisible in `hugo server` and visible to everyone who sees a shared link.

**Files:**
- Create: `website/i18n/en.yaml`
- Create: `website/layouts/_partials/opengraph.html`
- Create: `scripts/build-og-card.html`
- Create: `website/static/images/og-card.png`
- Modify: `website/hugo.yaml` (add `params.images`)

**Interfaces:**
- Consumes: nothing.
- Produces: `params.images` in `hugo.yaml`, read by the overridden `opengraph.html`.

- [ ] **Step 1: Prove the bug in the minified build**

```bash
cd website && hugo --minify --gc >/dev/null && \
  grep -oE '<meta property="og:(description|type|image)"[^>]*>' public/index.html
```

Expected: `og:description` and `og:type` present with whitespace-only `content`, and **no** `og:image` line at all. This is the failing state.

- [ ] **Step 2: Override the copyright string**

`website/i18n/en.yaml`:

```yaml
# Hextra reads the footer copyright from i18n, not from hugo.yaml params, so
# this file is the only place it can be overridden without forking the theme.
# Upstream default: "© 2026 Hextra Project." (hextra@v0.12.3 i18n/en.yaml:28).
copyright: "© 2026 Smaine Kahlouch · Apache-2.0 · built with Hugo and Hextra"
```

- [ ] **Step 3: Override the Open Graph partial**

`website/layouts/_partials/opengraph.html` — copy of `hextra@v0.12.3/layouts/_partials/opengraph.html` with every attribute value emitted on one line:

```go-html-template
{{- /*
  Project override of Hextra's opengraph partial (hextra@v0.12.3).

  Why it is worth overriding a theme file for this. The theme emits og:description
  and og:type as MULTI-LINE HTML attributes. `hugo server` renders them correctly,
  so the bug is invisible in development — but `hugo --minify`, which is what
  .github/workflows/docs.yml ships, collapses the value to whitespace and then
  drops the attribute entirely. Every link shared to Slack or LinkedIn rendered a
  bare card.

  The fix is whitespace control, not logic: each value is computed into a variable
  first and emitted inline. Behaviour is otherwise identical to upstream.

  When bumping Hextra, diff its opengraph.html against this file.
*/ -}}

{{- $description := "" -}}
{{- with .Description -}}
  {{- $description = . -}}
{{- else -}}
  {{- if .IsPage -}}
    {{- $description = .Summary -}}
  {{- else -}}
    {{- $description = site.Params.description -}}
  {{- end -}}
{{- end -}}
{{- $ogType := cond .IsPage "article" "website" -}}

<meta property="og:title" content="{{ .Title }}">
<meta property="og:description" content="{{ $description | plainify | chomp }}">
<meta property="og:type" content="{{ $ogType }}">
<meta property="og:url" content="{{ .Permalink }}">
{{- with .Params.images -}}
  {{- range first 6 . -}}
    <meta property="og:image" content="{{ . | absURL }}">
  {{- end -}}
{{- else -}}
  {{- with site.Params.images -}}
    <meta property="og:image" content="{{ index . 0 | absURL }}">
  {{- end -}}
{{- end -}}
{{- with site.Params.title -}}
  <meta property="og:site_name" content="{{ . }}">
{{- end -}}
{{- if .IsPage -}}
  {{- $iso8601 := "2006-01-02T15:04:05-07:00" -}}
  <meta property="article:section" content="{{ .Section }}">
  {{- with .Lastmod -}}
    <meta property="article:modified_time" content="{{ .Format $iso8601 }}">
  {{- end -}}
{{- end -}}
```

- [ ] **Step 4: Write the OG card source**

`scripts/build-og-card.html` — a standalone 1200×630 page using the site's own tokens, so it can be re-rendered when the palette or title changes. Include the ogenki mark, the site title, the one-line claim, and the component names as a strip. Document the render command in a comment at the top of the file:

```
<!-- Render:  see scripts/build-og-card.html header — screenshot at exactly 1200x630
     into website/static/images/og-card.png -->
```

- [ ] **Step 5: Render the card**

Open `scripts/build-og-card.html` in the browser at a 1200×630 viewport and screenshot it to `website/static/images/og-card.png`. Verify:

```bash
file website/static/images/og-card.png
```

Expected: `PNG image data, 1200 x 630`.

- [ ] **Step 6: Wire the card into the site**

In `website/hugo.yaml`, under `params:`, add:

```yaml
  # Social card. Consumed by layouts/_partials/opengraph.html; absolute-ised
  # against baseURL, so it must stay a site-root path.
  images:
    - /images/og-card.png
```

- [ ] **Step 7: Verify the fix in the minified build**

```bash
cd website && hugo --minify --gc && \
  grep -oE '<meta property="og:(description|type|image)"[^>]*>' public/index.html && \
  grep -oE '<meta property="og:(description|type)"[^>]*>' public/docs/platform/gitops/index.html && \
  ! grep -rq "Hextra Project" public/ && echo "OK: no Hextra attribution left"
```

Expected: three non-empty `og:` tags on the landing page, two non-empty on the doc page, and `OK: no Hextra attribution left`.

- [ ] **Step 8: Commit**

```bash
git add website/i18n website/layouts/_partials/opengraph.html website/hugo.yaml \
        website/static/images/og-card.png scripts/build-og-card.html
git commit -m "fix(site): repair Open Graph tags under --minify and correct footer attribution"
```

---

## Task 2: The repository tree, as data

The tree exists once, three lanes from where it is needed, with seven of thirteen entries collapsed and six rendered with file icons for directories.

**Files:**
- Create: `website/data/repo-tree.yaml`
- Create: `website/layouts/_shortcodes/repo-tree.html`
- Modify: `website/content/docs/reference/repository-layout.md`
- Modify: `website/assets/css/custom.css` (append)

**Interfaces:**
- Consumes: nothing.
- Produces: `{{< repo-tree >}}` and `{{< repo-tree depth="1" >}}`. Entry fields: `path` (string, trailing `/` for directories), `kind` (`dir` or `file`), `desc` (string), `owner` (string, optional, Markdown-rendered), `children` (list, optional).

- [ ] **Step 1: Write the data file**

`website/data/repo-tree.yaml`. Every `path` must exist in the repository — `verify-doc-paths.sh` does not read data files, so this is checked by hand in Step 5. Top level, in the order a reader meets them:

```yaml
# The repository tree, rendered by layouts/_shortcodes/repo-tree.html on both
# Platform -> GitOps (depth 1) and Reference -> Repository Layout (full).
#
# `owner` names what reconciles the directory: a Flux Kustomization from
# clusters/mycluster-0/, or "OpenTofu / Terramate" for the pre-Kubernetes half.
entries:
  - path: opentofu/
    kind: dir
    desc: Everything that must exist before a Kubernetes API does
    owner: OpenTofu / Terramate
    children:
      - path: network/
        kind: dir
        desc: VPC, subnets, Route53, Tailscale VPN
      - path: openbao/
        kind: dir
        desc: OpenBao cluster and its management stack — secrets and private PKI
      - path: eks/init/
        kind: dir
        desc: "Stage 1 — EKS cluster, node groups, bootstrap addons"
      - path: eks/configure/
        kind: dir
        desc: "Stage 2 — Cilium replaces the CNI, Flux is installed"
      - path: llm-platform/
        kind: dir
        desc: "opt-in — S3 Files and IAM for the self-hosted LLM platform"
```

Continue with `flux/`, `clusters/`, `namespaces/`, `crds/`, `infrastructure/`, `security/`, `observability/`, `tooling/`, `apps/`, `container-images/`, `scripts/`, `docs/`, `website/` — each with `owner` set to the Kustomization that reconciles it (`namespaces`, `crds`, `infrastructure`, `security`, `observability`, `tooling`, `apps`, `flux-*`), or `—` where nothing does (`container-images/`, `scripts/`, `docs/`, `website/`).

- [ ] **Step 2: Write the shortcode**

`website/layouts/_shortcodes/repo-tree.html`:

```go-html-template
{{- /*
  Renders site.Data.repoTree as a always-visible annotated tree.

  Not Hextra's filetree shortcode: filetree/folder takes only a `name`, so a
  description has to be smuggled into the folder label, and its `state`
  attribute hides children behind a click. On a page whose whole job is
  "here is the repository", collapsed-by-default is the wrong default.

  @param depth  1 renders top-level entries only; omitted renders children too.
*/ -}}
{{- $depth := int (.Get "depth" | default 99) -}}
<div class="cnref-tree">
  {{- range site.Data.repoTree.entries -}}
    <div class="cnref-tree-row">
      <span class="cnref-tree-icon" aria-hidden="true">{{ if eq .kind "dir" }}▸{{ else }}·{{ end }}</span>
      <code class="cnref-tree-path">{{ .path }}</code>
      <span class="cnref-tree-desc">{{ .desc }}</span>
      {{- with .owner }}<span class="cnref-tree-owner">{{ . | markdownify }}</span>{{ end -}}
    </div>
    {{- if and (ge $depth 2) .children -}}
      {{- range .children -}}
        <div class="cnref-tree-row cnref-tree-child">
          <span class="cnref-tree-icon" aria-hidden="true">{{ if eq .kind "dir" }}▸{{ else }}·{{ end }}</span>
          <code class="cnref-tree-path">{{ .path }}</code>
          <span class="cnref-tree-desc">{{ .desc }}</span>
        </div>
      {{- end -}}
    {{- end -}}
  {{- end -}}
</div>
```

- [ ] **Step 3: Style it**

Append to `website/assets/css/custom.css`. A three-column grid on wide screens that stacks below `48rem`; `.cnref-tree-owner` uses the existing `--cnref-stamp` token, which already holds 6.9:1 on both themes so no new contrast measurement is needed. The whole block scrolls inside `overflow-x: auto` so a long path never scrolls the page body.

- [ ] **Step 4: Replace the broken filetree**

In `website/content/docs/reference/repository-layout.md`, replace the entire `{{< filetree/container >}}` … `{{< /filetree/container >}}` block with `{{< repo-tree >}}`, and fix the one stale phrase: `docs/` is no longer "the pre-site documentation source" — it holds the architecture diagram sources, the read-only spec archive, the superpowers artifacts, and the platform constitution.

- [ ] **Step 5: Verify every path in the data file exists**

```bash
python3 -c "
import yaml,os,sys
d=yaml.safe_load(open('website/data/repo-tree.yaml'))
bad=[]
def walk(es,pre=''):
    for e in es:
        p=pre+e['path']
        if not os.path.exists(p): bad.append(p)
        walk(e.get('children',[]), p if e['path'].endswith('/') else pre)
walk(d['entries'])
print('MISSING:',bad) if bad else print('OK: every path exists')
sys.exit(1 if bad else 0)"
```

Expected: `OK: every path exists`.

- [ ] **Step 6: Verify the tree renders with nothing hidden**

```bash
cd website && hugo --minify --gc && \
  grep -c "cnref-tree-row" public/docs/reference/repository-layout/index.html && \
  ! grep -q 'data-state="closed"' public/docs/reference/repository-layout/index.html && \
  echo "OK: nothing collapsed"
```

Expected: a row count matching the data file, then `OK: nothing collapsed`.

- [ ] **Step 7: Commit**

```bash
git add website/data/repo-tree.yaml website/layouts/_shortcodes/repo-tree.html \
        website/content/docs/reference/repository-layout.md website/assets/css/custom.css
git commit -m "feat(site): render the repository tree from data, always expanded"
```

---

## Task 3: Describe Flux

**Files:**
- Modify: `website/content/docs/platform/gitops/_index.md`

**Interfaces:**
- Consumes: `{{< repo-tree depth="1" >}}` from Task 2.
- Produces: nothing later tasks depend on.

- [ ] **Step 1: Collect the facts before writing a word**

Every claim on this page must come from the tree, not from memory:

```bash
ls flux/*/ && \
cat opentofu/aws/eks/init/helm_values/flux-instance.yaml && \
grep -rn "interval:" clusters/mycluster-0/*.yaml | head -20 && \
grep -rln "kind: ResourceSet\|kind: Alert\|kind: Provider" flux/
```

Record the real interval values, the `FluxInstance` version and sync settings, and which `flux/` subdirectories hold which kinds.

- [ ] **Step 2: Add "The Flux resource model"**

Insert after "Why Flux". A table with one row per CRD in use — `FluxInstance`, `GitRepository`, `ArtifactGenerator`/`ExternalArtifact`, `Kustomization`, `HelmRelease` with `HelmRepository`/`OCIRepository`, `Alert`/`Provider`, `ResourceSet` — each naming what it does *in this repository* and the real file, using the values collected in Step 1. Follow with prose on the four `Kustomization` properties that separate "applied once" from "kept true": `interval`, `prune`, `wait` with `healthChecks`, and drift correction.

- [ ] **Step 3: Add "The repository, as Flux sees it"**

A short paragraph plus `{{< repo-tree depth="1" >}}`, with a sentence pointing at [Repository Layout] for the full tree and at [Repository Structure] for the `ArtifactGenerator` mechanism.

- [ ] **Step 4: Cut the dependency-hierarchy prose**

The section currently walks the graph in ~60 lines of prose that duplicates both the diagram above it and the table below it. Compare it line by line against those two; keep only facts present in neither — the `karpenter`/`crds` shortcut, the `flux-artifact-generators` bootstrap ordering, and the `llm-platform` exclusion. Target: under 25 lines.

- [ ] **Step 5: Add "Observing and operating"**

The command surface, each command verified to exist in `CLAUDE.md` or the Flux CLI pinned in `mise.toml` (2.9.4): `flux get all`, `flux tree kustomization <name>`, `flux events`, `flux suspend`/`resume`, `flux reconcile kustomization <name> --with-source`. Name where the Flux Grafana dashboards come from (`flux/observability/`) and point at the `gitops-cluster-debug` skill for the Flux → Kubernetes → Crossplane chain.

- [ ] **Step 6: Verify**

```bash
git add website/content/docs/platform/gitops/_index.md && \
  ./scripts/verify-doc-paths.sh && \
  cd website && hugo --minify --gc && cd .. && \
  ./scripts/validate-links.sh
```

Expected: three clean exits — every path named exists, the build resolves every `relref`, and no link rot.

- [ ] **Step 7: Commit**

```bash
git commit -m "docs(site): describe the Flux resource model and put the tree on the GitOps page"
```

---

## Task 4: Document CI

**Files:**
- Create: `docs/architecture/ci-pipeline.drawio`
- Create: `website/static/images/diagrams/ci-pipeline.svg`
- Modify: `scripts/export-diagrams.sh`
- Modify: `docs/architecture/README.md`
- Modify: `website/content/docs/reference/ci-workflows.md`
- Modify: `website/content/docs/platform/gitops/validation.md`

**Interfaces:**
- Consumes: nothing.
- Produces: `/images/diagrams/ci-pipeline.svg`, embedded by two pages.

- [ ] **Step 1: Re-read every workflow before describing it**

```bash
for f in .github/workflows/*; do echo "=== $f ==="; cat "$f"; done | head -300
gh api repos/Smana/cloud-native-ref/branches/main/protection \
  --jq '.required_status_checks.contexts' 2>/dev/null || echo "(protection not readable; state it as unverified)"
```

Record: each job's `name`, its trigger and path filter, whether it can fail the build, and which contexts branch protection actually requires. If the protection API is not readable, the page says so rather than guessing.

- [ ] **Step 2: Author the diagram**

`docs/architecture/ci-pipeline.drawio`, ogenki preset, matching the visual language of the existing seven. Shows the pull request fanning into `ci.yaml`'s six jobs plus the two path-filtered docs workflows; marks which are required checks and which are informational; then merge → `main` → Flux reconciles — closing the loop that CI itself never applies anything.

- [ ] **Step 3: Export and register it**

Add the file to `scripts/export-diagrams.sh` alongside the existing entries, run it, and confirm the budget:

```bash
./scripts/export-diagrams.sh && ls -l website/static/images/diagrams/ci-pipeline.svg
```

Expected: the file exists and is under 500 KB.

- [ ] **Step 4: Add it to the diagram index**

One row in `docs/architecture/README.md`'s table, matching the existing format: file, what it shows, and the page that consumes it.

- [ ] **Step 5: Rewrite the CI reference page**

`website/content/docs/reference/ci-workflows.md`, built around one table — **job · trigger · what it runs · blocks the merge?** — and correcting the page's one false statement: the `pre-commit` job runs through `dagger/dagger-for-github@v8.4.1` calling `github.com/Smana/daggerverse/pre-commit-tf`, so `pre-commit run --all-files` reproduces the *hooks* but not the job. Embed the diagram below the intro. Keep the existing pre-commit-hooks table and self-hosted-runners section.

- [ ] **Step 6: Embed the diagram on the validation page too**

`website/content/docs/platform/gitops/validation.md` gets the same image with an alt text describing where `kubernetes-validation` sits among the other jobs.

- [ ] **Step 7: Verify every job is documented**

```bash
comm -13 \
  <(grep -oE '^\s{2}[a-z0-9-]+:$' .github/workflows/ci.yaml | tr -d ' :' | sort) \
  <(grep -oE '\b(pre-commit|security-scan|kubernetes-validation|render-diff|shellcheck|links)\b' \
      website/content/docs/reference/ci-workflows.md | sort -u)
```

Expected: empty output in the first direction — run it both ways and confirm every job name in `ci.yaml` appears on the page.

- [ ] **Step 8: Commit**

```bash
git add docs/architecture/ci-pipeline.drawio docs/architecture/README.md \
        scripts/export-diagrams.sh website/static/images/diagrams/ci-pipeline.svg \
        website/content/docs/reference/ci-workflows.md \
        website/content/docs/platform/gitops/validation.md
git commit -m "docs(site): document CI per job and add the pipeline diagram"
```

---

## Task 5: The technology stack, with logos

**Files:**
- Create: `website/data/stack.yaml`
- Create: `website/static/images/logos/*.svg`
- Create: `website/static/images/logos/LICENSES.md`
- Create: `website/layouts/_shortcodes/stack-table.html`
- Modify: `website/content/docs/reference/technology-stack.md`
- Modify: `website/assets/css/custom.css` (append)

**Interfaces:**
- Consumes: nothing.
- Produces: `{{< stack-table group="<id>" >}}`. Item fields: `name`, `version`, `logo` (basename under `static/images/logos/`, optional), `logo_dark` (optional), `pin` (Markdown, optional), `url`, `note` (optional), `strip` (bool, consumed by Task 6). Group fields: `id`, `title`, `pin_note` (optional, hoists a shared pin out of the per-row column).

- [ ] **Step 1: Build the data file from the existing verified page**

`website/content/docs/reference/technology-stack.md` already carries 45 rows re-read from their pins on 2026-08-20. Transcribe them into `website/data/stack.yaml` **without re-deriving the versions** — the transcription is mechanical, and Step 6 proves it lossless. Group ids: `cli`, `bootstrap`, `infrastructure`, `security`, `observability`, `tooling`. Set `pin_note: "`mise.toml`"` on the `cli` group and drop the eleven repeated per-row pins.

- [ ] **Step 2: Source the logos**

For each item, fetch the official SVG mark into `website/static/images/logos/<logo>.svg`. Preference order: the project's own brand/press page, then the CNCF `cncf/artwork` repository for CNCF projects. For each file record source URL and licence/trademark terms in `website/static/images/logos/LICENSES.md`. Where the mark is dark-on-transparent, fetch the light variant as `<logo>-dark.svg`. Where no usable mark exists or the terms do not permit nominative use, leave `logo` unset — the shortcode renders a typographic tile.

```bash
ls website/static/images/logos/*.svg | wc -l && \
  du -ch website/static/images/logos/ | tail -1
```

Expected: the count matches the `logo:` keys in `stack.yaml`, and the directory total stays well under the 1000 KB pre-commit per-file ceiling.

- [ ] **Step 3: Write the shortcode**

`website/layouts/_shortcodes/stack-table.html`. Renders one group: a logo cell (`<img>` with the dark variant swapped by CSS the way the navbar mark already is, or a `.cnref-tile` span carrying the first letter when `logo` is unset), the name linked to `url`, the version, and the pin — with the pin column omitted entirely when the group has a `pin_note`. Every `<img>` carries `alt=""` and `aria-hidden="true"`, because the component name sits beside it as text and a duplicated label is noise to a screen reader.

- [ ] **Step 4: Style it**

Append to `custom.css`: logo sized at `1.25rem` square with `object-fit: contain`; `.cnref-tile` as a rounded square using `--ogenki-service` at the text size with white text — measure and record its contrast; table wrapped in `overflow-x: auto`.

- [ ] **Step 5: Convert the page**

Replace each of the seven hand-written tables in `website/content/docs/reference/technology-stack.md` with `{{< stack-table group="…" >}}`. The preamble, the per-section prose, the "Managed AWS services" section and "What this table intentionally omits" stay verbatim — they are prose, not data.

- [ ] **Step 6: Prove the conversion lost nothing**

```bash
cd website && hugo --minify --gc && cd .. && \
python3 -c "
import re,subprocess,yaml
html=open('website/public/docs/reference/technology-stack/index.html').read()
data=yaml.safe_load(open('website/data/stack.yaml'))
missing=[i['name'] for g in data['groups'] for i in g['items'] if i['name'] not in html]
vmiss=[i['name'] for g in data['groups'] for i in g['items'] if str(i['version']) not in html]
print('names missing:',missing); print('versions missing:',vmiss)"
```

Expected: both lists empty. Then diff the rendered page against `git show HEAD:website/content/docs/reference/technology-stack.md` by eye to confirm no row was dropped.

- [ ] **Step 7: Verify the versions still match the repository**

Re-read a sample of pins against the tree, the same way the page's preamble claims they were:

```bash
grep -E "cilium_version|flux_operator_version" opentofu/config.tm.hcl && \
grep -hA1 "chart:" infrastructure/base/crossplane/controller/helmrelease.yaml | grep version && \
grep -E '^(opentofu|helm|flux2|kustomize|trivy) *=' mise.toml
```

Expected: every value matches its `stack.yaml` entry. Any mismatch is a real drift to fix in the data file, not a transcription error to ignore.

- [ ] **Step 8: Commit**

```bash
git add website/data/stack.yaml website/static/images/logos \
        website/layouts/_shortcodes/stack-table.html \
        website/content/docs/reference/technology-stack.md website/assets/css/custom.css
git commit -m "feat(site): render the technology stack from data with project logos"
```

---

## Task 6: The landing page

**Files:**
- Create: `website/layouts/_shortcodes/stack-strip.html`
- Modify: `website/content/_index.md`
- Modify: `website/data/stack.yaml` (set `strip: true` on the curated subset)
- Modify: `website/assets/css/custom.css` (append)

**Interfaces:**
- Consumes: `website/data/stack.yaml` and the logo files from Task 5.
- Produces: `{{< stack-strip >}}`.

- [ ] **Step 1: Curate the strip**

Set `strip: true` on 12–16 items in `stack.yaml` — the components that define what this platform *is*, not everything it contains. Forty-five marks is a wall, not a strip.

- [ ] **Step 2: Write the shortcode**

`website/layouts/_shortcodes/stack-strip.html`: a wrapped flex row of logo + name pairs for every item where `strip` is true, each linking to its `url`, the whole strip preceded by an eyebrow label and followed by a link to the Technology Stack page.

- [ ] **Step 3: Replace the inline-styled headings**

`website/content/_index.md` currently carries `<h2 style="margin-top:3.5rem">` and a `<p>` with six inline declarations. Replace with `.cnref-section-title` and `.cnref-eyebrow` classes defined in `custom.css`, and give the two section headings real typographic weight — they currently read as labels rather than section headers.

- [ ] **Step 4: Add the strip**

Insert `{{< stack-strip >}}` after the "Browse the docs" grid and before the AWS/GCP closing line.

- [ ] **Step 5: Verify in both themes**

```bash
cd website && hugo --minify --gc && grep -c "cnref-strip-item" public/index.html
```

Expected: the count equals the number of `strip: true` items. Then screenshot the landing page in light and dark and confirm every mark is legible on both grounds — a dark-on-transparent logo with no `logo_dark` variant is the failure to look for.

- [ ] **Step 6: Commit**

```bash
git add website/layouts/_shortcodes/stack-strip.html website/content/_index.md \
        website/data/stack.yaml website/assets/css/custom.css
git commit -m "feat(site): add the technology strip and real heading hierarchy to the landing page"
```

---

## Task 7: Reading polish and the honest README

**Files:**
- Modify: `website/assets/css/custom.css` (append)
- Modify: `website/layouts/_partials/custom/footer.html`
- Modify: `website/assets/screenshots/app-wizard/README.md`
- Modify: `website/content/docs/platform/developer-platform/app-wizard.md`

**Interfaces:**
- Consumes: `--cnref-stamp` and `--ogenki-external` from `custom.css`.
- Produces: nothing.

- [ ] **Step 1: Fix the anchor-link landing position**

Hextra's navbar is `position: sticky`, so an in-page anchor lands the heading underneath it. Append to `custom.css` a `scroll-margin-top` on `h2, h3, h4` equal to the navbar height plus a line.

- [ ] **Step 2: Give diagrams a zoom affordance**

The diagram card is already `data-zoomable`, but nothing tells the reader. Add a hover cursor and a small persistent hint on the card, styled with `--cnref-stamp` so no new contrast measurement is needed.

- [ ] **Step 3: Add feature-card hover states**

The landing page's twelve cards have no hover feedback beyond the theme default. Add a subtle lift and an accent border using the existing `--primary-*` variables — no new colour tokens.

- [ ] **Step 4: Extend the footer**

`website/layouts/_partials/custom/footer.html` currently renders only the verification stamp. Add a link row above it — the six doc lanes, GitHub, `blog.ogenki.io`, and the licence. Keep the existing `$page := .context` unwrapping and its comment; the partial is called with a wrapper dict, not the page.

- [ ] **Step 5: Make the App Wizard README true**

It claims its five PNGs "are referenced by `app-wizard.md`". The page has no image references and the files do not exist. Reword the README to say the captures are pending, and add one sentence to the page recording that the screenshots are not yet captured — the same "state the gap explicitly" rule the observability page already follows.

- [ ] **Step 6: Full verification**

```bash
cd website && hugo --minify --gc && cd .. && \
  ./scripts/validate-links.sh && \
  git add -A && ./scripts/verify-doc-paths.sh && \
  ! grep -rq "Hextra Project" website/public/ && echo "OK: attribution" && \
  grep -oE '<meta property="og:(description|type|image)"[^>]*>' website/public/index.html
```

Expected: build exit 0, links exit 0, doc paths exit 0, `OK: attribution`, and three non-empty `og:` tags.

- [ ] **Step 7: Lighthouse and screenshots**

Run a Lighthouse audit on the landing page against a local `hugo server`. Expected: accessibility ≥ 95, performance ≥ 90 — the criterion the parent design set. Capture landing, GitOps and Technology Stack in both themes.

- [ ] **Step 8: Commit**

```bash
git add website/assets/css/custom.css website/layouts/_partials/custom/footer.html \
        website/assets/screenshots/app-wizard/README.md \
        website/content/docs/platform/developer-platform/app-wizard.md
git commit -m "feat(site): reading polish, footer links, and an honest screenshots README"
```

---

## Task 8: Split the AI Platform lane

`platform/ai-platform/_index.md` is 230 lines carrying an entire domain, with two code blocks on it — both `bash` gate commands. The `InferenceService` claim the whole domain is built on is never shown, there is no "why self-host", and no worked request. Every other Platform domain has four or five pages; this one has three and the index does all the work.

**Files:**
- Modify: `website/content/docs/platform/ai-platform/_index.md`
- Create: `website/content/docs/platform/ai-platform/inference-service.md`
- Create: `website/content/docs/platform/ai-platform/gateway-and-routing.md`
- Create: `website/content/docs/platform/ai-platform/autoscaling-and-gpu.md`

**Interfaces:**
- Consumes: nothing.
- Produces: three new pages that `_index.md`'s card grid links to. Page weights: `inference-service` 20, `gateway-and-routing` 30, `autoscaling-and-gpu` 40, `coding-clients` 50, `roadmap` 60.

- [ ] **Step 1: Re-read the claims before writing the reference**

The four claims are the source of truth, and they are the richest commentary in the repository:

```bash
cat apps/base/ai/llm/qwen-coder.yaml apps/base/ai/llm/qwen-coder-fim.yaml \
    apps/base/ai/llm/qwen3-8b.yaml apps/base/ai/llm/llamaguard3-1b.yaml
grep -n "InferenceService" infrastructure/base/crossplane/configuration/configuration-packages.yaml
```

Record every `spec.*` field that appears across the four, and the pinned Configuration package version — the field reference documents the XRD at that pin, not a general vLLM API.

- [ ] **Step 2: Create `inference-service.md`**

Mirrors the shape of `developer-platform/app.md` plus `app-field-reference.md`, in one page because the API is smaller:

- a **complete, real claim** — `qwen-coder-fim.yaml`, the most instructive of the four, with its own rationale comments preserved rather than stripped: why the base variant and not Instruct, why `contextWindow: 8192`, why `maxNumSeqs: 64`, and the Karpenter `consolidationPolicy: WhenEmpty` defence for an always-warm pod;
- **what one claim renders** — reuse the existing `llm-platform-2.svg` diagram, which already shows exactly this;
- a **field reference table** — `model.*` (`repository`, `revision`, `quantization`, `contextWindow`, `maxNumSeqs`, `preload.enabled`), `gpu.*`, `scaling.*`, `gateway.*` — each with type, default, and whether it is required, read from the claims and the pinned XRD;
- the **model fleet table**, moved here from the index — it is claim-level detail, not domain-level narrative.

- [ ] **Step 3: Create `gateway-and-routing.md`**

Moves the index's "Request path" and "Semantic routing — `model: MoM`" sections, plus `llm-platform-1.svg`, and adds what the index lacks: a **worked request** showing the `curl` against `/v1/chat/completions` with `model: MoM` and the same call naming a model explicitly, with the latency difference the index already quantifies (250–300 ms of classification skipped). Keep the `EnvoyPatchPolicy` ordering explanation verbatim — an `EnvoyExtensionPolicy` can only append filters, and that is the reason a raw xDS JSONPatch is used.

- [ ] **Step 4: Create `autoscaling-and-gpu.md`**

Moves the index's "Autoscaling", "GPU foundation and storage" sections and `llm-platform-3.svg`, and adds the piece that is currently only in `CLAUDE.md`: the **KEDA scale-from-zero deadlock** that `min=1` exists to avoid, and why the legacy KEDA HTTP add-on was dropped. Keep the unverified-InferencePool-trigger callout exactly as written — it is a correct, load-bearing warning.

- [ ] **Step 5: Rewrite `_index.md` as the domain narrative**

New order, motivation first and gates last:

```
What this is                     one paragraph + the at-a-glance table
Why self-host                    NEW — the question every other domain page answers
                                 and this one does not: what running your own
                                 fleet buys over a hosted API here, and what it costs
                                 (4 GPUs at min=1 is a hard floor, not a soft one)
Turning it on                    the two gates, moved below the narrative
The 8 child Kustomizations       keep
Security posture                 keep
Known gaps                       keep
{{< cards >}}                    five cards, one per sub-page
```

Target: under 130 lines. Every section moved out is deleted from the index, not duplicated.

- [ ] **Step 6: Verify nothing was lost in the split**

```bash
git add website/content/docs/platform/ai-platform/ && \
python3 -c "
import subprocess
old=subprocess.run(['git','show','HEAD:website/content/docs/platform/ai-platform/_index.md'],
                   capture_output=True,text=True).stdout
new=''.join(open(f).read() for f in [
  'website/content/docs/platform/ai-platform/_index.md',
  'website/content/docs/platform/ai-platform/inference-service.md',
  'website/content/docs/platform/ai-platform/gateway-and-routing.md',
  'website/content/docs/platform/ai-platform/autoscaling-and-gpu.md'])
import re
# every backticked token in the old page must survive somewhere in the new set
old_toks={t for t in re.findall(r'\`([^\`\n]+)\`',old) if len(t)>3}
missing=sorted(t for t in old_toks if t not in new)
print('DROPPED:',missing) if missing else print('OK: nothing dropped')"
```

Expected: `OK: nothing dropped`. Anything listed is either a deliberate cut — justify it — or an accident.

- [ ] **Step 7: Verify**

```bash
./scripts/verify-doc-paths.sh && cd website && hugo --minify --gc && cd .. && ./scripts/validate-links.sh
```

Expected: three clean exits.

- [ ] **Step 8: Commit**

```bash
git add website/content/docs/platform/ai-platform/
git commit -m "docs(site): split the AI platform lane and document the InferenceService claim"
```

---

## Task 9: Document the SRE agent

RunLore appears in ten places on the site — a table row, a dashboard row, two alert rows, a PromQL example, an `HTTPRoute` footnote — and has no page. The site never says what it is, what it does with an alert, or how it is wired.

**Files:**
- Create: `website/content/docs/platform/observability/sre-agent.md`
- Modify: `website/content/docs/platform/observability/_index.md` (card grid + component table link)
- Modify: `website/content/docs/platform/observability/dashboards-and-alerts.md` (point its RunLore rows at the new page)

**Interfaces:**
- Consumes: nothing.
- Produces: `sre-agent.md` at weight 50, linked from the observability index card grid.

- [ ] **Step 1: Re-read the deployment before describing it**

```bash
cat observability/base/runlore/helmrelease.yaml
cat observability/base/runlore/ciliumnetworkpolicy-ingress.yaml \
    observability/base/runlore/httproute.yaml
ls observability/base/runlore/externalsecret-*.yaml
cat flux/sources/gitrepo-runlore.yaml
grep -rn "runlore" observability/base/victoria-metrics-k8s-stack/vmrules/runlore.yaml | head -20
```

Record: the pinned Git ref and image tag (they must match — the HelmRelease comment records a live incident where they did not), `workloadKind: StatefulSet` with `replicaCount: 2`, which secrets come from AWS Secrets Manager, what the `HTTPRoute` exposes, and the alert names.

- [ ] **Step 2: Write the page**

Sections, each grounded in Step 1's output:

- **What it is** — an SRE agent that receives Alertmanager webhooks and investigates them with an LLM against read-only cluster access, rather than paging a human first. This is the framing the site is missing entirely.
- **What happens to an alert** — Alertmanager fires → webhook → investigation → findings posted to Slack `#alerts`. Name the read-only boundary explicitly: it investigates, it does not remediate.
- **The knowledge base** — the separate [`Smana/runlore-kb`](https://github.com/Smana/runlore-kb) repository, git-synced into the pod, and recall: past investigations inform new ones.
- **How it is deployed** — `HelmRelease` from a `GitRepository` in `flux/sources/` (not under `observability/`, because of the [controller sharding]({{< relref "/docs/platform/gitops/repository-structure.md" >}}) trap this repository already documents — a source under an app-owned directory inherits `sharding.fluxcd.io/key=apps` and the default shard cannot see it). HA as a `StatefulSet` with per-replica RWO volumes and leader election.
- **Secrets** — credentials, Slack token and webhook secret all via External Secrets from AWS Secrets Manager.
- **Its own observability** — the dashboard and the 12 `VMRule` alerts covering the agent itself, linking to [Dashboards & Alerts]({{< relref "/docs/platform/observability/dashboards-and-alerts.md" >}}).
- **Known gaps** — state that it tracks an unreleased branch rather than a tagged release, if Step 1 confirms that is still true.

{{< callout >}} Two facts from Step 1 must appear, because both are non-obvious and both caused real incidents: the image tag and the `GitRepository` ref have to move together, and the source lives under `flux/sources/` for sharding reasons. {{< /callout >}}

- [ ] **Step 3: Link it**

Add a card to `observability/_index.md`'s `{{< cards >}}` grid, and repoint the `runlore` row in its component table from `dashboards-and-alerts.md` to the new page.

- [ ] **Step 4: Verify**

```bash
git add website/content/docs/platform/observability/ && \
  ./scripts/verify-doc-paths.sh && \
  cd website && hugo --minify --gc && cd .. && ./scripts/validate-links.sh
```

Expected: three clean exits.

- [ ] **Step 5: Commit**

```bash
git add website/content/docs/platform/observability/
git commit -m "docs(site): document the RunLore SRE agent"
```

---

## Self-review

**Spec coverage.** Every design section maps to a task: Flux + tree → 2, 3. CI → 4. Stack + logos → 5. Landing strip → 6. Footer, OG, polish, README → 1, 7. D1 (data + one renderer) → 2, 5. D2 (project shortcode over `filetree`) → 2. D3/D4 (bundled SVGs, typographic tile) → 5. D5 (`opengraph.html` override) → 1. D6 (cut, not append) → 3 Step 4. D7 (keep the CI split) → 4. Tasks 8 and 9 were added after the design was approved, on the same "a domain the site under-describes" grounds as the Flux workstream; the design document is amended alongside them.

**Placeholders.** None: every step names exact paths and either shows the code or states the verification command and its expected output. The three steps that write prose rather than code (3.2, 3.5, 4.5) each begin by re-reading the source of truth, and name exactly which facts must come from it.

**Type consistency.** `repo-tree.yaml` fields (`path`, `kind`, `desc`, `owner`, `children`) are used identically in Task 2's data file and shortcode. `stack.yaml` fields (`name`, `version`, `logo`, `logo_dark`, `pin`, `url`, `note`, `strip`; group `id`, `title`, `pin_note`) are declared in Task 5's interface block and consumed unchanged by Task 6. Hugo lower-cases the data filename, so `website/data/repo-tree.yaml` is reached as `site.Data.repoTree` — used consistently in the shortcode.
