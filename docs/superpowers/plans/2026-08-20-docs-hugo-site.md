# Documentation Site (Hugo + Hextra) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Publish the repository's documentation as a searchable Hugo + Hextra site at `cnref.ogenki.io`, reorganised into audience lanes, with every migrated page verified against the repository as it is today.

**Architecture:** A Hugo site lives in `website/`, consuming Hextra as a Hugo Module (no npm). Content moves out of `docs/` into `website/content/docs/` under six top-level lanes whose cloud boundary mirrors ADR-0007. Two GitHub Actions workflows build the site — one gating pull requests, one deploying to GitHub Pages. Diagram sources stay in `docs/architecture/`; SVG exports are written into `website/assets/diagrams/`.

**Tech Stack:** Hugo Extended 0.156.0 (pinned in `mise.toml`), Hextra v0.12.3 (pinned in `website/go.mod`), Go 1.27.0 (already pinned; required by Hugo Modules), FlexSearch (bundled with Hextra), draw.io desktop CLI for diagram export.

**Design:** [2026-08-20-docs-hugo-site-design.md](../specs/2026-08-20-docs-hugo-site-design.md)

---

## Global Constraints

Every task's requirements implicitly include this section.

### Versions and pinning

- Hugo: `hugo-extended = "0.156.0"` in the **root** `mise.toml`. **Not** `hugo` — mise's `hugo` entry resolves to the non-extended build (verified: `hugo v0.156.0-9d914726…` with no `+extended` suffix), while `hugo-extended` resolves to `…+extended`. Hextra declares `module.hugoVersion.min = '0.146.0'`.
- Hextra: `github.com/imfing/hextra v0.12.3` in `website/go.mod`.
- Go: already `go = "1.27.0"` in `mise.toml`. Hugo Modules require it; do not remove.
- GitHub Actions already used in this repo — reuse these majors: `actions/checkout@v7`, `actions/cache@v6`, `jdx/mise-action@v4`. New for Pages: `actions/configure-pages@v6`, `actions/upload-pages-artifact@v5`, `actions/deploy-pages@v5`.

### Front-matter contract

Every content page under `website/content/docs/` uses exactly this front matter:

```yaml
---
title: Gateway API
linkTitle: Gateway API      # omit when identical to title
weight: 20
description: How HTTP traffic reaches applications, and how TLS is terminated.
lastVerified: 2026-08-20
---
```

- `weight` in steps of 10 (10, 20, 30…) so a page can be inserted later without renumbering.
- `description` is one sentence, no trailing period omission — it feeds FlexSearch and the OG card.
- `lastVerified` is the date the page's contents were checked against the repository. It is rendered in the page footer by the partial built in Task 2. **A page without `lastVerified` is not migrated, it is merely moved.**

### Internal links

Use `relref` for every internal link: `[Gateway API]({{< relref "/docs/platform/networking/gateway-api.md" >}})`. `refLinksErrorLevel: ERROR` turns an unresolved ref into a build failure. Never use a bare relative `.md` path inside `website/content/`.

**Forward references break the build.** A `relref` to a page a later task creates fails
`hugo --minify` immediately — this is the gate working, not a bug. Two remedies, in order of
preference:

1. Follow the recommended task order in *Notes for the executor*, which is sequenced so that link
   targets exist before the pages that link them.
2. If you genuinely need a link to a page outside your task's scope, create that page as a
   two-line stub in the same commit (front matter plus one sentence), and let the task that owns
   it replace the stub. Never delete the link to make the build pass.

### Verify-on-migrate

No page lands in `website/content/` until all four hold. This is the plan's central quality bar.

1. Every repository path the page names still exists.
2. Every command the page shows matches `opentofu/workflows.tm.hcl`, `opentofu/*/workflows.tm.hcl`, `scripts/`, or `CLAUDE.md`.
3. Every component list matches what Flux actually deploys (`clusters/mycluster-0/`, `*/base/`).
4. Every version matches `mise.toml`, `opentofu/config.tm.hcl`, or the relevant HelmRelease.

Content that cannot be verified is **cut**, or kept inside a `{{< callout type="warning" >}}` that says explicitly what is unverified. It is never carried over silently.

`scripts/verify-doc-paths.sh` (built in Task 3) mechanises point 1.

### Per-task verification commands

Every content task ends with this sequence, all three exiting 0:

```bash
cd website && hugo --minify --gc && cd ..
./scripts/verify-doc-paths.sh
./scripts/validate-links.sh
```

### The blog is a separate property

[blog.ogenki.io](https://blog.ogenki.io) is the personal blog and stays that way. This site is
documentation: **no blog layout, no posts section, no news, no dated entries.** Hextra ships a blog
layout — do not enable it.

The blog's per-topic deep-dives are still the best long-form explanation of several components, so
each is linked from the domain page it deepens, under a `## Further reading` heading at the end of
the page. Never as a nav entry, never as a feed.

| Blog post | Linked from |
|---|---|
| [Crossplane: Compositions and Functions](https://blog.ogenki.io/post/crossplane_composition_functions/) | `platform/developer-platform/_index.md` |
| [TLS with Gateway API and Private PKI](https://blog.ogenki.io/post/pki-gapi/) | `platform/networking/gateway-api.md` and `platform/security/pki-and-secrets.md` |
| [Tailscale: Simplifying Cloud Access](https://blog.ogenki.io/post/tailscale/) | `platform/networking/private-access.md` |
| [VictoriaMetrics and Grafana Operators](https://blog.ogenki.io/post/series/observability/metrics) | `platform/observability/metrics.md` |
| [Effective Alerting with VictoriaMetrics](https://blog.ogenki.io/post/series/observability/alerts/) | `platform/observability/dashboards-and-alerts.md` |
| [Agentic Coding: concepts and hands-on Platform Engineering use cases](https://blog.ogenki.io/post/series/agentic_ai/ai-coding-agent/) | `concepts/how-this-is-built.md` |
| [Dagger: The Missing Piece of Developer Experience](https://blog.ogenki.io/post/dagger-intro/) | `reference/ci-workflows.md` |

### Commit convention

Conventional commits, `docs(site):` scope for site work, `docs(<lane>):` for content lanes. **Never co-author.** No "Generated with Claude Code" line.

---

## File Structure

| Path | Responsibility |
|---|---|
| `website/hugo.yaml` | Site config: module import, menus, params, search, markup. Single source of site-wide behaviour. |
| `website/go.mod` / `go.sum` | Hextra version pin. Renovate-tracked via the `gomod` manager. |
| `website/assets/css/custom.css` | Palette overrides only. Shadows Hextra's empty `assets/css/custom.css` hook. No layout CSS. |
| `website/assets/diagrams/` | SVG diagram exports consumed by content pages. Generated, committed. |
| `website/layouts/_partials/custom/footer.html` | Renders the `lastVerified` line. Hextra 0.12.3 uses the Hugo 0.146+ `_partials` layout structure. |
| `website/content/_index.md` | Landing page (`layout: hextra-home`). |
| `website/content/docs/<lane>/_index.md` | Lane index: what the lane covers and where to go next. One per lane. |
| `website/static/` | `CNAME`, favicons, logo, OG card. Copied verbatim, no processing. |
| `scripts/verify-doc-paths.sh` | Asserts every repository path named in a Markdown file exists. |
| `scripts/export-diagrams.sh` | Regenerates all diagram exports from `docs/architecture/*.drawio`. |
| `.github/workflows/docs-check.yml` | PR gate: build must succeed, paths must resolve. |
| `.github/workflows/docs.yml` | main → GitHub Pages deploy. |

---

## Task 1: Scaffold the Hugo site

**Files:**
- Create: `website/hugo.yaml`, `website/go.mod`, `website/.gitignore`
- Create: `website/content/_index.md` (placeholder, replaced in Task 4)
- Modify: `mise.toml`
- Modify: `.gitignore`

**Interfaces:**
- Produces: a `website/` directory where `hugo --minify --gc` exits 0. Every later task depends on this.
- Produces: `hugo` on `PATH` via mise for local and CI use.

- [ ] **Step 1: Pin Hugo Extended in the root mise.toml**

Add to the `[tools]` block in `mise.toml`, after `helm`:

```toml
# Documentation site (website/). "hugo-extended" is deliberate: mise's plain
# `hugo` entry resolves to the non-extended build, and Hextra targets extended.
hugo-extended = "0.156.0"
```

- [ ] **Step 2: Install it and confirm it is the extended build**

Run: `mise install && mise exec -- hugo version`
Expected: output contains both `v0.156.0` and `+extended`. If `+extended` is absent, the wrong tool name was used — fix Step 1 before continuing.

- [ ] **Step 3: Create the Hugo module**

```bash
mkdir -p website/content
cd website
mise exec -- hugo mod init github.com/Smana/cloud-native-ref/website
mise exec -- hugo mod get github.com/imfing/hextra@v0.12.3
cd ..
```

Expected: `website/go.mod` exists and contains `github.com/imfing/hextra v0.12.3`.

- [ ] **Step 4: Write `website/hugo.yaml`**

```yaml
baseURL: https://cnref.ogenki.io/
title: Cloud Native Reference
languageCode: en-us
enableRobotsTXT: true
enableGitInfo: true

# Drift guard: any unresolved internal ref (relref/ref) fails the build rather
# than shipping a silent 404. This is the site's internal-link gate; the
# repository-wide gate stays scripts/validate-links.sh.
refLinksErrorLevel: ERROR

module:
  hugoVersion:
    min: "0.146.0"
  imports:
    - path: github.com/imfing/hextra

markup:
  goldmark:
    renderer:
      unsafe: true
  highlight:
    noClasses: false

menu:
  main:
    - name: Get Started
      pageRef: /docs/get-started
      weight: 1
    - name: Platform
      pageRef: /docs/platform
      weight: 2
    - name: Concepts
      pageRef: /docs/concepts
      weight: 3
    - name: Guides
      pageRef: /docs/guides
      weight: 4
    - name: Reference
      pageRef: /docs/reference
      weight: 5
    - name: Decisions
      pageRef: /docs/decisions
      weight: 6
    - name: GitHub
      weight: 7
      url: "https://github.com/Smana/cloud-native-ref"
      params:
        icon: github
    - name: Search
      weight: 8
      params:
        type: search

params:
  description: "An opinionated, production-ready Kubernetes platform reference: GitOps with Flux, infrastructure from Kubernetes with Crossplane, zero-trust networking with Cilium, and a private PKI with OpenBao — on AWS EKS today, designed for a second cloud."
  navbar:
    displayTitle: true
    displayLogo: false
  search:
    enable: true
    type: flexsearch
    flexsearch:
      index: content
      tokenize: forward
  editURL:
    enable: true
    base: "https://github.com/Smana/cloud-native-ref/edit/main/website/content"
  footer:
    enable: true
    displayCopyright: true
    displayPoweredBy: false
  imageZoom:
    enable: true
  theme:
    default: system
    displayToggle: true
```

- [ ] **Step 5: Write a placeholder landing page**

`website/content/_index.md`:

```markdown
---
title: Cloud Native Reference
layout: hextra-home
---

Placeholder. Replaced in Task 4.
```

- [ ] **Step 6: Ignore Hugo build artifacts**

`website/.gitignore`:

```gitignore
/public/
/resources/
/.hugo_build.lock
```

- [ ] **Step 7: Build and verify**

Run: `cd website && mise exec -- hugo --minify --gc`
Expected: exit 0, output reports `Pages` ≥ 1 and no `ERROR` lines.

- [ ] **Step 8: Commit**

```bash
git add mise.toml website/
git commit -m "docs(site): scaffold the Hugo site with the Hextra theme

Hugo Extended 0.156.0 pinned in mise.toml — mise's plain `hugo` entry is the
non-extended build. Hextra v0.12.3 consumed as a Hugo Module, so there is no
npm toolchain. refLinksErrorLevel: ERROR makes a dead internal ref a build
failure rather than a silent 404."
```

---

## Task 2: Apply the ogenki palette and static assets

**Files:**
- Create: `website/assets/css/custom.css`
- Create: `website/layouts/_partials/custom/footer.html`
- Create: `website/static/CNAME`
- Create: `website/static/images/logo.png`, `website/static/favicon.ico`, `website/static/favicon-32x32.png`, `website/static/favicon-16x16.png`, `website/static/apple-touch-icon.png`

**Interfaces:**
- Consumes: the site from Task 1.
- Produces: the `lastVerified` footer rendering, which every content task's front matter feeds.

- [ ] **Step 1: Write the palette override**

Hextra derives its full colour scale from three variables. Its defaults are `:root { --primary-hue: 212deg; --primary-saturation: 100%; --primary-lightness: 50% }` and `.dark { --primary-hue: 204deg; … }`, and it uses `--color-primary-600` for links and active navigation (14 usages, against 7 for `primary-500`).

`--color-primary-600` is derived as `lightness / 50 × 45`, i.e. `0.9 × lightness`. The brand navy `#004675` is `hsl(204, 100%, 23%)`, so the lightness that lands `primary-600` on the brand colour is `23 / 0.9 = 25.6%`, rounded to **26%**. Setting lightness to 23% directly would put `primary-600` at 20.7% — links indistinguishable from body text.

`website/assets/css/custom.css` (shadows Hextra's empty `assets/css/custom.css` hook):

```css
/* ogenki palette.
 *
 * Hextra generates its whole primary scale from these three variables and uses
 * --color-primary-600 for links and active nav. That shade is 0.9 x lightness,
 * so lightness is set to 26% -> primary-600 = hsl(204 100% 23.4%) = #004777,
 * the ogenki brand navy. Setting 23% here instead would render links at 20.7%
 * lightness: near-black, and visually identical to body text.
 *
 * The `deg` unit is required — the theme's own values carry it.
 */
:root {
  --primary-hue: 204deg;
  --primary-saturation: 100%;
  --primary-lightness: 26%;
}

.dark {
  --primary-hue: 204deg;
  --primary-saturation: 62%;
  --primary-lightness: 65%; /* -> primary-600 = #4FA6D9 */
}

/* Semantic colours, shared verbatim with the `ogenki` drawio preset
 * (~/.drawio-skill/styles/ogenki.json) so that callouts, badges and diagram
 * legends read as one system. Identical in both themes on purpose: a diagram
 * cannot change colour with the page, so neither should the legend beside it.
 */
:root,
.dark {
  --ogenki-service: #6366f1;  /* indigo  */
  --ogenki-security: #7c3aed; /* violet  */
  --ogenki-storage: #059669;  /* emerald */
  --ogenki-scaling: #f59e0b;  /* amber   */
  --ogenki-failure: #dc2626;  /* red     */
  --ogenki-external: #94a3b8; /* slate   */
}

/* The verification stamp rendered by layouts/_partials/custom/footer.html */
.cnref-verified {
  margin-top: 3rem;
  padding-top: 1rem;
  border-top: 1px solid var(--ogenki-external);
  font-size: 0.8125rem;
  color: var(--ogenki-external);
}
```

- [ ] **Step 2: Write the `lastVerified` footer partial**

The design's stated norm is that a page says what it was checked against. `website/layouts/_partials/custom/footer.html`:

```go-html-template
{{- with .Params.lastVerified }}
  <p class="cnref-verified">
    Verified against the repository on
    <time datetime="{{ . }}">{{ time.Format "2 January 2006" . }}</time>.
    {{- with $.GitInfo }}
      Last edited in
      <a href="https://github.com/Smana/cloud-native-ref/commit/{{ .Hash }}">{{ .AbbreviatedHash }}</a>.
    {{- end }}
  </p>
{{- end }}
```

- [ ] **Step 3: Add the CNAME**

`website/static/CNAME` — exactly one line, no trailing content:

```
cnref.ogenki.io
```

- [ ] **Step 4: Add favicons and the logo**

Source the ogenki mark from the blog repository and generate the icon set:

```bash
cp ~/Sources/smana.github.io/static/logos/ogenki-blue-logo-only.png website/static/images/logo.png
cd website/static
magick images/logo.png -resize 32x32 favicon-32x32.png
magick images/logo.png -resize 16x16 favicon-16x16.png
magick images/logo.png -resize 180x180 apple-touch-icon.png
magick images/logo.png -define icon:auto-resize=64,48,32,16 favicon.ico
cd ../..
```

Expected: five files created, each under 100 KB.

- [ ] **Step 5: Build and verify the palette applied**

```bash
cd website && mise exec -- hugo --minify --gc && cd ..
grep -c "primary-lightness: 26%" website/public/css/*.css
```

Expected: build exits 0; the grep returns at least 1.

- [ ] **Step 6: Commit**

```bash
git add website/assets website/layouts website/static
git commit -m "docs(site): apply the ogenki palette and static assets

Accent derived rather than copied: Hextra builds its scale from
--primary-lightness and uses primary-600 for links, which is 0.9x lightness.
Lightness 26% lands primary-600 on the brand navy #004675; setting 23%
directly would render links near-black.

The lastVerified footer partial renders the date each page was checked
against the repository, so a stale page says so on its face."
```

---

## Task 3: Build the CI gates

**Files:**
- Create: `.github/workflows/docs-check.yml`
- Create: `.github/workflows/docs.yml`
- Create: `scripts/verify-doc-paths.sh`

**Interfaces:**
- Produces: `./scripts/verify-doc-paths.sh` — exit 0 when every repository path named in `website/content/**/*.md` exists; exit 1 with a list otherwise. Every content task runs it.

- [ ] **Step 1: Write the path verifier**

`scripts/verify-doc-paths.sh`:

```bash
#!/usr/bin/env bash
#
# verify-doc-paths.sh — assert that every repository path named in the docs site
# still exists.
#
# scripts/validate-links.sh resolves Markdown *links*. It cannot see the far more
# common failure in this repository's prose: a backticked path in running text
# ("configured in `opentofu/eks/configure/locals.tf`") that silently stops being
# true after a refactor. This closes that gap, and is what makes the design's
# "verify-on-migrate" rule mechanical rather than a promise.
#
# Only strings that look like repository paths are checked: they contain a `/`
# and start with a known top-level directory. Everything else in backticks —
# commands, field names, prose — is ignored.
#
# NOTE: this walks `git ls-files`, so it only sees TRACKED files. Run it after
# `git add`, or a brand-new page passes without ever being checked.
#
# Usage:
#   ./scripts/verify-doc-paths.sh          # fail on the first missing path
#   ./scripts/verify-doc-paths.sh --list   # print every missing path, exit 0

set -euo pipefail
cd "$(dirname "$0")/.."

MODE="${1:-check}"

mapfile -t MISSING < <(python3 - <<'PY'
import os, re, subprocess

TOP = ('apps/', 'clusters/', 'container-images/', 'crds/', 'docs/', 'flux/',
       'infrastructure/', 'namespaces/', 'observability/', 'opentofu/',
       'scripts/', 'security/', 'tooling/', 'website/', '.github/', '.claude/')

files = subprocess.run(['git', 'ls-files', 'website/content/*.md'],
                       capture_output=True, text=True).stdout.split()
# Backticked spans only. Prose mentions without backticks are not claims about
# the tree; treating them as such produces noise nobody acts on.
span = re.compile(r'`([^`\n]+)`')

for f in files:
    with open(f, encoding='utf-8') as fh:
        for n, line in enumerate(fh, 1):
            for raw in span.findall(line):
                # Strip a trailing line-range suffix such as ":123-145".
                p = re.sub(r':\d+(-\d+)?$', '', raw.strip())
                if not p.startswith(TOP):
                    continue
                # A glob or a placeholder is not a claim about a concrete file.
                if any(c in p for c in '*?<>${}'):
                    continue
                if not os.path.exists(p):
                    print(f'{f}:{n}\t{p}')
PY
)

if [ "$MODE" = "--list" ]; then
    printf '%s\n' "${MISSING[@]}"
    exit 0
fi

if [ ${#MISSING[@]} -gt 0 ] && [ -n "${MISSING[0]}" ]; then
    echo "==> Documentation names paths that do not exist:"
    printf '    %s\n' "${MISSING[@]}"
    echo
    echo "Fix the path, or drop the reference. Do not add an allowlist."
    exit 1
fi

echo "==> Every repository path named in the docs site exists."
```

- [ ] **Step 2: Make it executable and run it**

```bash
chmod +x scripts/verify-doc-paths.sh
./scripts/verify-doc-paths.sh
```

Expected: `==> Every repository path named in the docs site exists.` (trivially true — no content yet).

- [ ] **Step 3: Write the pull-request gate**

`.github/workflows/docs-check.yml`:

```yaml
name: Docs site

on:
  pull_request:
    branches: ["main"]
    paths:
      - "website/**"
      - "docs/architecture/**"
      - "scripts/verify-doc-paths.sh"
      - ".github/workflows/docs-check.yml"

permissions:
  contents: read

jobs:
  build:
    name: Build the documentation site 📚
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7
        with:
          fetch-depth: 0 # enableGitInfo needs history

      - name: Install tools
        uses: jdx/mise-action@v4

      - name: Cache Hugo modules
        uses: actions/cache@v6
        with:
          path: ~/.cache/hugo_cache
          key: hugo-mod-${{ hashFiles('website/go.sum') }}
          restore-keys: hugo-mod-

      # refLinksErrorLevel: ERROR turns an unresolved relref into a non-zero
      # exit, so this step is the internal-link gate as well as the build gate.
      - name: Build
        working-directory: website
        run: hugo --minify --gc

      - name: Verify every referenced repository path exists
        run: ./scripts/verify-doc-paths.sh
```

- [ ] **Step 4: Write the deploy workflow**

`.github/workflows/docs.yml`:

```yaml
name: Deploy docs site

on:
  push:
    branches: ["main"]
    paths:
      - "website/**"
      - "docs/architecture/**"
      - ".github/workflows/docs.yml"
  workflow_dispatch:

permissions:
  contents: read
  pages: write
  id-token: write

# Never cancel an in-flight deploy: a half-published site is worse than a
# slightly stale one.
concurrency:
  group: pages
  cancel-in-progress: false

jobs:
  deploy:
    name: Build and deploy to GitHub Pages 🚀
    runs-on: ubuntu-latest
    environment:
      name: github-pages
      url: ${{ steps.deployment.outputs.page_url }}
    steps:
      - uses: actions/checkout@v7
        with:
          fetch-depth: 0

      - name: Install tools
        uses: jdx/mise-action@v4

      - name: Cache Hugo modules
        uses: actions/cache@v6
        with:
          path: ~/.cache/hugo_cache
          key: hugo-mod-${{ hashFiles('website/go.sum') }}
          restore-keys: hugo-mod-

      - name: Configure Pages
        uses: actions/configure-pages@v6

      - name: Build
        working-directory: website
        run: hugo --minify --gc

      - name: Upload artifact
        uses: actions/upload-pages-artifact@v5
        with:
          path: website/public

      - name: Deploy
        id: deployment
        uses: actions/deploy-pages@v5
```

- [ ] **Step 5: Validate both workflows parse**

```bash
mise exec -- yq '.jobs | keys' .github/workflows/docs-check.yml
mise exec -- yq '.jobs | keys' .github/workflows/docs.yml
```

Expected: `- build` and `- deploy` respectively.

- [ ] **Step 6: Commit**

```bash
git add .github/workflows/docs-check.yml .github/workflows/docs.yml scripts/verify-doc-paths.sh
git commit -m "docs(site): add the build gate, the Pages deploy and the path verifier

verify-doc-paths.sh closes the gap validate-links.sh cannot reach: a backticked
path in running prose is a claim about the tree, and nothing checked those. It
is what makes verify-on-migrate mechanical instead of a promise."
```

---

## Task 4: Build the landing page and the lane shells

**Files:**
- Modify: `website/content/_index.md`
- Create: `website/content/docs/_index.md`
- Create: `website/content/docs/{get-started,platform,concepts,guides,reference,decisions}/_index.md`

**Interfaces:**
- Consumes: the palette and footer partial from Task 2.
- Produces: the six lane index pages that every content task fills. Their `weight` values fix sidebar order: get-started 10, platform 20, concepts 30, guides 40, reference 50, decisions 60.

- [ ] **Step 1: Write the landing page**

`website/content/_index.md`. The `platform-overview` image reference resolves once Task 16 writes the export; until then the build succeeds and the image 404s in the browser — acceptable, and Task 16 closes it.

```markdown
---
title: Cloud Native Reference
layout: hextra-home
description: "An opinionated, production-ready Kubernetes platform reference. GitOps with Flux, infrastructure from Kubernetes with Crossplane, zero-trust networking with Cilium, a private PKI with OpenBao — on AWS EKS today, designed for a second cloud."
---

{{< hextra/hero-badge >}}
  Open source · Apache-2.0 · runs on your own AWS account
{{< /hextra/hero-badge >}}

{{< hextra/hero-headline >}}
  A production-ready platform you can actually deploy
{{< /hextra/hero-headline >}}

{{< hextra/hero-subtitle >}}
  Not a slide deck and not a toy cluster. Every component here runs, is
  reconciled by Flux, and is gated in CI — a private PKI, zero-trust networking,
  a developer-facing abstraction over managed infrastructure, and a full
  observability stack. Deploy it into your own account in about thirty minutes,
  or read how each piece was chosen.
{{< /hextra/hero-subtitle >}}

{{< hextra/hero-button text="Deploy in 30 minutes" link="docs/get-started/" >}}
{{< hextra/hero-button text="View on GitHub" link="https://github.com/Smana/cloud-native-ref" style="background:transparent;border:1px solid rgba(148,163,184,0.45);color:inherit" >}}

<p style="margin-top:3rem;margin-bottom:0.5rem;font-size:0.8125rem;text-transform:uppercase;letter-spacing:0.08em;color:var(--ogenki-external)">The whole platform, on one page</p>

![Platform architecture: AWS managed services, the EKS cluster in four tiers, and the applications and data stores on top](images/diagrams/platform-overview.svg)

<h2 style="margin-top:3.5rem">What this repository is for</h2>

{{< hextra/feature-grid cols="2" >}}
  {{< hextra/feature-card link="docs/get-started/" icon="rocket-launch" title="Bootstrap a platform"
    subtitle="Three sequential stages — network, secrets, Kubernetes — driven by OpenTofu and Terramate. One command per stage, and the cluster comes up with Cilium, Flux and Karpenter already running." >}}
  {{< hextra/feature-card link="docs/concepts/" icon="academic-cap" title="Learn the concepts"
    subtitle="GitOps as a dependency hierarchy rather than a slogan. Progressive complexity in a platform API. Zero trust that is enforced by policy, not asserted in a README." >}}
  {{< hextra/feature-card link="docs/platform/" icon="cube-transparent" title="Evaluate the tools"
    subtitle="Cilium, Flux, Crossplane, OpenBao, VictoriaMetrics, Gateway API, Karpenter, KEDA — each with what it actually buys you here, and what it cost to adopt." >}}
  {{< hextra/feature-card link="docs/guides/fork-and-adapt/" icon="template" title="Make it yours"
    subtitle="Which values are environment-specific, what to strip out, what the minimum viable subset is, and roughly what it costs to run." >}}
{{< /hextra/feature-grid >}}

<h2 style="margin-top:3.5rem">Browse the docs</h2>

{{< hextra/feature-grid cols="3" >}}
  {{< hextra/feature-card link="docs/get-started/" icon="play" title="Get Started" subtitle="Prerequisites, the deploy path, first application, teardown." >}}
  {{< hextra/feature-card link="docs/platform/" icon="server" title="Platform" subtitle="Every domain: foundations, GitOps, networking, security, developer platform, observability, AI." >}}
  {{< hextra/feature-card link="docs/concepts/" icon="light-bulb" title="Concepts" subtitle="The ideas the platform demonstrates, and how it is built." >}}
  {{< hextra/feature-card link="docs/guides/" icon="map" title="Guides" subtitle="Fork and adapt, add an application, add a cloud provider, troubleshoot." >}}
  {{< hextra/feature-card link="docs/reference/" icon="book-open" title="Reference" subtitle="Repository layout, technology stack, commands, CI, the platform constitution." >}}
  {{< hextra/feature-card link="docs/decisions/" icon="scale" title="Decisions" subtitle="Architecture decision records — what was chosen, and what it was chosen over." >}}
{{< /hextra/feature-grid >}}

<p style="margin-top:3.5rem;font-size:0.9375rem;color:var(--ogenki-external)">
Runs on <strong>AWS EKS</strong> today. A second cloud is designed but not yet
implemented — see <a href="docs/decisions/0007-cloud-abstraction-boundaries/">ADR-0007</a>
for where the platform draws its cloud boundary.
</p>
```

- [ ] **Step 2: Write the docs root index**

`website/content/docs/_index.md`:

```markdown
---
title: Documentation
weight: 1
description: Everything about building, running and reusing this platform.
lastVerified: 2026-08-20
---

This platform runs on AWS EKS and is reconciled entirely by Flux. Where you go
next depends on what you want from it.

- **[Get Started]({{< relref "/docs/get-started/_index.md" >}})** — deploy it into
  your own account. Prerequisites, three stages, first application, teardown.
- **[Platform]({{< relref "/docs/platform/_index.md" >}})** — one section per
  domain: what runs, why it was chosen, and how it is wired.
- **[Concepts]({{< relref "/docs/concepts/_index.md" >}})** — the ideas being
  demonstrated, rather than the configuration that demonstrates them.
- **[Guides]({{< relref "/docs/guides/_index.md" >}})** — task-oriented: reuse
  this repository, add an application, add a cloud provider, debug a failure.
- **[Reference]({{< relref "/docs/reference/_index.md" >}})** — repository layout,
  technology stack, commands, CI, the platform constitution.
- **[Decisions]({{< relref "/docs/decisions/_index.md" >}})** — the architecture
  decision records, including what each choice was made *over*.
```

- [ ] **Step 3: Write the six lane index pages**

Each gets `title`, `weight`, `description`, `lastVerified`, and one paragraph naming what the lane covers. Weights: `get-started` 10, `platform` 20, `concepts` 30, `guides` 40, `reference` 50, `decisions` 60. Child page lists are added by the task that fills each lane.

Example — `website/content/docs/get-started/_index.md`:

```markdown
---
title: Get Started
weight: 10
description: Deploy the platform into your own cloud account in about thirty minutes.
lastVerified: 2026-08-20
---

The platform deploys in three sequential stages: the network, then the secrets
and PKI layer, then Kubernetes. Each is a separate OpenTofu stack orchestrated
by Terramate, and each must complete before the next begins.

Pick your cloud to begin. AWS is implemented and maintained; GCP is designed but
not yet built.
```

- [ ] **Step 4: Build and verify navigation**

```bash
cd website && mise exec -- hugo --minify --gc && cd ..
ls website/public/docs/
```

Expected: build exits 0; the listing shows all six lane directories plus `index.html`.

- [ ] **Step 5: Inspect the landing page locally**

Run: `cd website && mise exec -- hugo server -D`
Open `http://localhost:1313`. Confirm: hero renders, both button rows render, the six lane cards link correctly, the theme toggle switches light/dark, and links are visibly blue in both modes (this is the check on Task 2's derived lightness).

- [ ] **Step 6: Commit**

```bash
git add website/content
git commit -m "docs(site): add the landing page and the six lane indexes

Landing page leads with the architecture diagram and four cards mapping to what
the repository is actually for — deploy it, learn from it, evaluate the tools,
reuse it. Lane weights step by ten so pages can be inserted without renumbering."
```

---

## Task 5: Migrate the Get Started lane

**Files:**
- Create: `website/content/docs/get-started/prerequisites.md`
- Create: `website/content/docs/get-started/aws/_index.md`, `access.md`, `teardown.md`
- Create: `website/content/docs/get-started/gcp/_index.md`
- Create: `website/content/docs/get-started/first-app.md`
- Read: `README.md`, `docs/opentofu.md`, `opentofu/workflows.tm.hcl`, `opentofu/eks/init/workflows.tm.hcl`, `scripts/eks-prepare-destroy.sh`, `mise.toml`, `docs/apps-user-guide.md`

**Interfaces:**
- Consumes: the lane index from Task 4.
- Produces: `/docs/get-started/` targets that the landing page's "Deploy in 30 minutes" button and Task 17's shrunk README both link to.

- [ ] **Step 1: Map source sections to destination pages**

| Destination | Source | Cut |
|---|---|---|
| `prerequisites.md` | `docs/opentofu.md` §Prerequisites, `README.md` §Prerequisites | the hand-written install commands — replace with `mise install`, which is what the repository actually uses |
| `aws/_index.md` | `README.md` §Quickstart Deployment Steps, `docs/opentofu.md` §Repository Structure | the tech-stack table (belongs in reference), the acknowledgements |
| `aws/access.md` | `README.md` §Network access, §OpenBao, §Kubernetes, §Platform Dashboard | nothing |
| `aws/teardown.md` | `scripts/eks-prepare-destroy.sh` header, `opentofu/workflows.tm.hcl` destroy script | nothing |
| `first-app.md` | `docs/apps-user-guide.md` §2 Quick start | sections 3–12 (they belong to Task 9) |

- [ ] **Step 2: Verify every version claim before writing**

```bash
grep -E '^(go|opentofu|flux2|helm|kustomize|trivy|hugo-extended|"ubi:terramate)' mise.toml
grep -E 'cilium_version|flux_version|gateway_api_version' opentofu/config.tm.hcl
```

Record the values. `prerequisites.md` must state these exact versions, or state `mise install` and name no versions at all. It must not state versions from `docs/opentofu.md`, which was last edited 2026-03-06.

- [ ] **Step 3: Verify every command before writing**

```bash
grep -n 'name *=' opentofu/workflows.tm.hcl opentofu/eks/init/workflows.tm.hcl
```

Every command shown on `aws/_index.md` and `aws/teardown.md` must appear in that output. A command that does not is cut.

- [ ] **Step 4: Write the pages**

Each with the standard front matter and `lastVerified: 2026-08-20`. Weights: `prerequisites` 10, `aws` 20, `gcp` 30, `first-app` 40; within `aws/`: `_index` 10, `access` 20, `teardown` 30.

`aws/_index.md` presents the three stages as a `{{< steps >}}` block, one heading per stage, each with its `terramate script run` command and what the stage creates.

`gcp/_index.md` is a stub and says so plainly:

```markdown
---
title: GCP
weight: 30
description: Designed, not yet implemented.
lastVerified: 2026-08-20
---

{{< callout type="warning" >}}
GCP is **not implemented**. This page exists so the documentation has a place
for it, and so nothing above it silently assumes AWS.
{{< /callout >}}

The design is complete and three decision records frame it:

- [ADR-0005]({{< relref "/docs/decisions/0005-gke-standard-self-managed-cilium.md" >}}) — GKE Standard with self-managed Cilium
- [ADR-0006]({{< relref "/docs/decisions/0006-nap-computeclass-over-karpenter.md" >}}) — node autoscaling via ComputeClass rather than Karpenter
- [ADR-0007]({{< relref "/docs/decisions/0007-cloud-abstraction-boundaries.md" >}}) — where the platform draws its cloud boundary

The full design lives in the repository at `docs/superpowers/specs/2026-08-18-gcp-support-design.md`.
```

- [ ] **Step 5: Add the child list to the lane index**

Append to `website/content/docs/get-started/_index.md` a `{{< cards >}}` block linking the four children.

- [ ] **Step 6: Verify**

```bash
cd website && mise exec -- hugo --minify --gc && cd ..
./scripts/verify-doc-paths.sh
./scripts/validate-links.sh
```

Expected: all three exit 0.

- [ ] **Step 7: Commit**

```bash
git add website/content/docs/get-started
git commit -m "docs(get-started): migrate the deploy path from README and opentofu.md

Every command checked against workflows.tm.hcl and every version against
mise.toml and config.tm.hcl before the page was written — docs/opentofu.md was
last edited in March and its pinned versions had drifted.

GCP ships as an honest stub rather than being omitted, so no page above it
silently assumes AWS."
```

---

## Task 6: Migrate Foundations and GitOps

**Files:**
- Create: `website/content/docs/platform/foundations/{_index,aws,gcp}.md`
- Create: `website/content/docs/platform/gitops/{_index,repository-structure,validation}.md`
- Read: `docs/opentofu.md`, `docs/gitops.md`, `docs/ci-workflows.md`, `clusters/mycluster-0/`, `scripts/validate-manifests.sh`, `.fluxschema.yml`

**Interfaces:**
- Produces: `/docs/platform/foundations/` and `/docs/platform/gitops/`, referenced by Get Started and by Task 15's guides.

- [ ] **Step 1: Split `docs/opentofu.md` (739 lines)**

| Destination | Sections |
|---|---|
| `foundations/_index.md` | Overview, Why OpenTofu, Why Terramate, the three-stage model. Cloud-neutral — no AWS resource names. |
| `foundations/aws.md` | Repository Structure, the stacks, the two-stage EKS bootstrap, the OpenBao cluster stack. |
| `foundations/gcp.md` | Stub, same shape as `get-started/gcp/_index.md`. |

The Prerequisites section is **not** duplicated here — it lives in `get-started/prerequisites.md`. Link to it.

- [ ] **Step 2: Split `docs/gitops.md` (767 lines)**

| Destination | Sections |
|---|---|
| `gitops/_index.md` | What is GitOps, Why Flux, the dependency hierarchy |
| `gitops/repository-structure.md` | Directory Structure, plus the repository-structure section of `README.md` |

- [ ] **Step 3: Verify the dependency hierarchy against the cluster manifests**

```bash
ls clusters/mycluster-0/
grep -l "dependsOn" clusters/mycluster-0/*.yaml | while read -r f; do
  echo "== $f"; mise exec -- yq '.spec.dependsOn[].name' "$f" 2>/dev/null
done
```

The hierarchy drawn on `gitops/_index.md` must match this output exactly. `docs/gitops.md` was last edited 2026-07-15 and predates at least the `llm-platform` umbrella Kustomization — check whether it appears.

- [ ] **Step 4: Write `gitops/validation.md` from `docs/ci-workflows.md` §"How manifest validation works"**

Must state, because these are the two load-bearing properties of the SPEC-007 setup:

- `skipMissingSchemas: false` in `.fluxschema.yml` — an unknown Kind **fails the build**, it is not skipped.
- Polaris audits the *rendered* bundle, not the source tree: 2 raw Deployments in the repository versus 70 controllers after rendering.

Verify both:

```bash
grep -n "skipMissingSchemas" .fluxschema.yml
grep -c "kind: Deployment" $(git ls-files '*/base/**/*.yaml' | head -200) 2>/dev/null | awk -F: '{s+=$2} END {print s}'
```

- [ ] **Step 5: Add child lists to both lane indexes and to `platform/_index.md`**

- [ ] **Step 6: Verify**

```bash
cd website && mise exec -- hugo --minify --gc && cd ..
./scripts/verify-doc-paths.sh
./scripts/validate-links.sh
```

- [ ] **Step 7: Commit**

```bash
git add website/content/docs/platform
git commit -m "docs(platform): migrate foundations and GitOps

opentofu.md split along the cloud boundary ADR-0007 sets: the three-stage model
and the tooling rationale are cloud-neutral, the stacks and the two-stage EKS
bootstrap are not. gitops.md's dependency hierarchy re-derived from
clusters/mycluster-0/ rather than trusted."
```

---

## Task 7: Migrate Networking — merging two overlapping documents

**Files:**
- Create: `website/content/docs/platform/networking/{_index,cilium,gateway-api,private-access}.md`
- Read: `docs/ingress.md` (723), `docs/tailscale-gateway-api.md` (291), `infrastructure/base/gapi/`, `opentofu/eks/configure/`, `opentofu/eks/init/helm_values/cilium.yaml`, `CLAUDE.md`

**Interfaces:**
- Produces: `/docs/platform/networking/`, linked from security (TLS termination) and developer-platform (App ingress).

- [ ] **Step 1: Build the overlap inventory before writing anything**

```bash
grep -n '^#\{2,3\} ' docs/ingress.md > /tmp/ingress-headings.txt
grep -n '^#\{2,3\} ' docs/tailscale-gateway-api.md > /tmp/tailscale-headings.txt
diff -y --suppress-common-lines /tmp/ingress-headings.txt /tmp/tailscale-headings.txt || true
```

Both files describe the two Tailscale gateways and the ACL tags. Decide once, per topic, which destination owns it. Nothing may appear on two pages.

| Topic | Owner |
|---|---|
| Gateway API model, GatewayClass, listeners, HTTPRoute | `gateway-api.md` |
| TLS termination, cert-manager wiring | `gateway-api.md`, linking to `security/pki-and-secrets.md` |
| The two Tailscale gateways, `tag:k8s` vs `tag:admin`, ACLs | `private-access.md` |
| ExternalDNS and Route53 record creation | `gateway-api.md` |
| Adding a new private service | `private-access.md` |
| eBPF datapath, kube-proxy replacement, prefix delegation, WireGuard | `cilium.md` |

- [ ] **Step 2: Verify the gateway inventory against the manifests**

```bash
ls infrastructure/base/gapi/
mise exec -- yq '.metadata.name, .spec.gatewayClassName' infrastructure/base/gapi/*gateway*.yaml
```

The gateway names and classes on `private-access.md` must match this output. `docs/tailscale-gateway-api.md` was last edited 2025-12-24.

- [ ] **Step 3: Write `cilium.md` — new content, no single source**

Sources: `opentofu/eks/configure/cilium-cni-config.tf`, `opentofu/eks/init/helm_values/cilium.yaml`, and the Cilium section of `CLAUDE.md`. Must cover, because each is a live trap:

- Cilium replaces both the CNI and kube-proxy; VPC-CNI is disabled in stage 2.
- Prefix delegation is enabled, and pods draw from the secondary CIDR `100.64.0.0/16`.
- `encryption.type: wireguard` is **load-bearing**, not an optimisation: it works around [cilium#43493](https://github.com/cilium/cilium/issues/43493), which breaks the Gateway API L7 proxy on cross-node traffic under native routing with prefix delegation. State plainly that it must not be disabled while the issue is open.
- `cniVersion` in `cilium-cni-config.tf` must be bumped by hand on every Cilium minor upgrade, because setting `cni.configMap` means the chart default never applies.
- Pod subnets must **not** carry the `kubernetes.io/role/cni` tag.

Verify each claim:

```bash
grep -n "cniVersion\|encryption\|prefix" opentofu/eks/configure/cilium-cni-config.tf opentofu/eks/init/helm_values/cilium.yaml
grep -rn "cilium.io/pod-subnet\|role/cni" opentofu/network/
```

- [ ] **Step 4: Confirm the merge lost nothing**

```bash
grep -c '^#\{2,3\} ' docs/ingress.md docs/tailscale-gateway-api.md
grep -c '^#\{2,3\} ' website/content/docs/platform/networking/*.md
```

Walk the source heading list and tick each one off as migrated or deliberately cut. Record deliberate cuts in the commit message.

- [ ] **Step 5: Verify**

```bash
cd website && mise exec -- hugo --minify --gc && cd ..
./scripts/verify-doc-paths.sh
./scripts/validate-links.sh
```

- [ ] **Step 6: Commit**

```bash
git add website/content/docs/platform/networking
git commit -m "docs(platform): merge ingress and tailscale docs into networking

ingress.md and tailscale-gateway-api.md both described the two gateways and the
ACL tags, and had drifted apart. Each topic now has exactly one owner.

Adds cilium.md, which had no source document: the WireGuard workaround for
cilium#43493, the manual cniVersion bump, and the pod-subnet tagging trap were
recorded only in CLAUDE.md and inline comments."
```

---

## Task 8: Migrate Security — promoting the OpenBao documentation

**Files:**
- Create: `website/content/docs/platform/security/{_index,openbao,pki-and-secrets,policies}.md`
- Read: `opentofu/openbao/cluster/docs/{getting_started,pki_requirements}.md`, `opentofu/openbao/management/docs/{cert-manager,approle,backup_restore}.md`, `opentofu/openbao/management/namespaces.tf`, `security/base/`, `CLAUDE.md`

**Interfaces:**
- Produces: `/docs/platform/security/`, linked from networking (TLS) and get-started (`bao login`).

- [ ] **Step 1: Inventory what is being promoted**

```bash
wc -l opentofu/openbao/*/docs/*.md
```

Expected: five files, 703 lines total. All five are promoted; none stays behind. The directories are deleted in Task 17, so nothing may be left unmigrated.

- [ ] **Step 2: Assign sources to destinations**

| Destination | Sources |
|---|---|
| `openbao.md` | `cluster/docs/getting_started.md`, `management/docs/approle.md`, `management/docs/backup_restore.md` |
| `pki-and-secrets.md` | `cluster/docs/pki_requirements.md`, `management/docs/cert-manager.md`, plus External Secrets from `security/base/` |
| `policies.md` | New: Kyverno, CiliumNetworkPolicy defaults, pod security standards, from `security/base/` and the platform constitution |

- [ ] **Step 3: Verify the namespace layout claim**

```bash
grep -n "namespace\|path" opentofu/openbao/management/namespaces.tf | head -30
```

`openbao.md` must state the layout accurately: shared platform services — the PKI (`pki_private_issuer`), the snapshot AppRole, operator logins — live in the **root** namespace; namespaces are reserved for tenants, and `app` is the only one, holding a `secret/` kv-v2 mount reached through its own AppRole. Cluster-wide endpoints such as `sys/storage/raft/*` are callable only from root.

- [ ] **Step 4: Verify the operator login procedure**

```bash
grep -rn "userpass\|admin" opentofu/openbao/management/auth.tf
```

The documented `bao login -method=userpass username=admin` and the Secrets Manager path `openbao/cloud-native-ref/users/admin` must match. Include `VAULT_CACERT` pointing at `opentofu/openbao/management/.tls/ca.pem` and **not** `VAULT_SKIP_VERIFY` — a security reference that documents skipping verification undercuts itself.

- [ ] **Step 5: Record the version constraint**

`openbao.md` must carry a `{{< callout type="warning" >}}` stating that the entire OpenBao 2.6 line is blocked in Renovate: 2.6.0 deadlocks in `namespace_store` and 2.6.2 in `auth.go` (upstream issue #3411, still open), and that a hanging `bao status` on 127.0.0.1 indicates a core deadlock, not a VPN problem. Verify:

```bash
grep -n "2\.6\|openbao" .github/renovate.json
grep -rn "openbao_version" opentofu/openbao/cluster/variables.tf
```

- [ ] **Step 6: Verify**

```bash
cd website && mise exec -- hugo --minify --gc && cd ..
./scripts/verify-doc-paths.sh
./scripts/validate-links.sh
```

- [ ] **Step 7: Commit**

```bash
git add website/content/docs/platform/security
git commit -m "docs(platform): promote the OpenBao documentation into the site

703 lines of real security documentation sat four directories deep under
opentofu/openbao/*/docs/ and were reachable only by someone already reading
that Terraform. It is the platform's strongest security story and it was the
least findable thing in the repository.

Records the 2.6 pin and its symptom: a hanging bao status on 127.0.0.1 is a
core deadlock, not the VPN."
```

---

## Task 9: Migrate the Developer Platform — splitting the 1,046-line guide

**Files:**
- Create: `website/content/docs/platform/developer-platform/{_index,app,data-services,app-wizard}.md`
- Create: `website/assets/screenshots/app-wizard/README.md`
- Read: `docs/crossplane.md` (670), `docs/apps-user-guide.md` (1046), `docs/app-wizard.md` (238), `docs/assets/app-wizard/README.md`, `infrastructure/base/crossplane/configuration/configuration-packages.yaml`

**Interfaces:**
- Produces: `/docs/platform/developer-platform/`, linked from the landing page, get-started `first-app.md`, and Task 15's `add-an-application.md`.

- [ ] **Step 1: Build the section checklist**

`docs/apps-user-guide.md` has twelve numbered sections. Write them out and assign each a destination before editing anything — this checklist is what proves nothing was dropped.

| § | Title | Destination |
|---|---|---|
| 1 | What is an App | `_index.md` |
| 2 | Quick start: deploy a web app | already migrated in Task 5 → `get-started/first-app.md`; link, do not duplicate |
| 3 | Background workers | `app.md` |
| 4 | Scheduled jobs (cron) | `app.md` |
| 5 | Configuration and secrets | `app.md` |
| 6 | Sidecars and init containers | `app.md` |
| 7 | Persistent storage | `app.md` |
| 8 | Health probes | `app.md` |
| 9 | Databases, cache, and object storage | `data-services.md` |
| 10 | Exposing your app and network security | `app.md`, linking to `networking/gateway-api.md` |
| 11 | Autoscaling and availability | `app.md` |
| 12 | Observability | `app.md`, linking to `platform/observability/` |

- [ ] **Step 2: State the compositions boundary prominently**

`_index.md` must open by making clear that **XRDs and Compositions are not in this repository**. They live in [`Smana/crossplane-configuration`](https://github.com/Smana/crossplane-configuration) and ship as a Crossplane Configuration package; this repository pins a version. Verify the pin:

```bash
mise exec -- yq '.spec.package' infrastructure/base/crossplane/configuration/configuration-packages.yaml
```

Quote the pinned version on the page. Also state what this repository still owns: `functions.yaml`, `environmentconfig.yaml`, and the provider config.

- [ ] **Step 3: Trim `docs/crossplane.md` of authoring content**

Its §"Composition Functions with KCL" and §"Validation Requirements" describe authoring KCL, which now happens in the other repository. Replace with a short pointer paragraph. This is the content that made `docs/crossplane-kcl-authoring.md` redundant; that file is deleted in Task 17.

- [ ] **Step 4: Move the screenshot placeholders**

```bash
git mv docs/assets/app-wizard/README.md website/assets/screenshots/app-wizard/README.md
```

The five screenshots are still uncaptured. `app-wizard.md` must reference them through the README rather than linking five broken image paths — that is what the five `.linkcheck-allow` entries were papering over, and Task 17 empties that file.

- [ ] **Step 5: Verify the App Wizard version coupling**

```bash
grep -rn "tag\|version" apps/platform/app-wizard/app.yaml | head
```

`app-wizard.md` must state that the wizard clones the same tag as the pinned Configuration package, and that the two are bumped together.

- [ ] **Step 6: Verify**

```bash
cd website && mise exec -- hugo --minify --gc && cd ..
./scripts/verify-doc-paths.sh
./scripts/validate-links.sh
```

Then walk the twelve-row table from Step 1 and confirm every section has landed.

- [ ] **Step 7: Commit**

```bash
git add website/content/docs/platform/developer-platform website/assets/screenshots
git rm -r --cached docs/assets/app-wizard 2>/dev/null || true
git commit -m "docs(platform): split the apps user guide across the developer platform

1,046 lines in one file meant the App composition's twelve capability areas were
undiscoverable. Split by audience question, with the quick start living in Get
Started rather than being repeated.

States the compositions boundary up front: XRDs and Compositions ship from
Smana/crossplane-configuration and are pinned here, which is the single most
common source of confusion about this repository."
```

---

## Task 10: Migrate Observability — the hardest verification

**Files:**
- Create: `website/content/docs/platform/observability/{_index,metrics,logs,dashboards-and-alerts,postgresql}.md`
- Read: `docs/observability.md` (878, stale since 2025-11-02), `docs/postgresql-monitoring-architecture.md` (451, stale since 2025-11-14), `observability/base/`, `observability/mycluster-0/`, `.claude/rules/observability.md`

**Interfaces:**
- Produces: `/docs/platform/observability/`, linked from developer-platform §12 and Task 15's troubleshooting guide.

- [ ] **Step 1: Establish what is actually deployed, before reading the stale documents**

```bash
ls observability/base/
mise exec -- yq '.metadata.name' observability/base/*/helmrelease*.yaml 2>/dev/null | sort -u
grep -rn "chart:" observability/base/ | grep -o 'name: .*' | sort -u
```

Write this inventory down first. It is the ground truth. `docs/observability.md` is nine months old and predates at least the SPEC-006 GenAI observability work and the SPEC-010 CNPG Barman plugin migration.

- [ ] **Step 2: Diff the stale document against the inventory**

Walk `docs/observability.md`'s component list against Step 1's output. Produce three lists: **still true**, **changed**, **gone**. Only the first migrates unedited; the second is rewritten from the manifests; the third is cut.

- [ ] **Step 3: Split into four pages plus PostgreSQL**

| Destination | Sources |
|---|---|
| `_index.md` | Overview, Why VictoriaMetrics |
| `metrics.md` | Metrics Stack, VMServiceScrape/ServiceMonitor usage, example queries |
| `logs.md` | Logs Stack, plus the LogsQL rules from `.claude/rules/observability.md` |
| `dashboards-and-alerts.md` | Grafana, dashboard conventions, alerting |
| `postgresql.md` | `docs/postgresql-monitoring-architecture.md`, re-verified |

- [ ] **Step 4: Carry the LogsQL syntax rules onto `logs.md`**

They are correct, non-obvious, and currently only in `.claude/rules/observability.md` where no human reads them:

- Kubernetes labels use **dot** notation (`kubernetes.container_name`), not underscores.
- After `unpack_json`, fields are prefixed `log.` — `log.level`, `log.trace_id`.
- Grafana dashboard JSON must use `$${var}` (double dollar) to survive Flux `postBuild` substitution.

- [ ] **Step 5: Re-verify the PostgreSQL monitoring page against SPEC-010**

```bash
grep -rn "barman\|plugin" infrastructure/base/ observability/base/ 2>/dev/null | grep -i cnpg | head
ls docs/specs/done/2026-Q3/010-cnpg-barman-cloud-plugin/
```

`docs/postgresql-monitoring-architecture.md` predates the Barman plugin migration. Any backup-related content it carries is suspect and must be checked or cut.

- [ ] **Step 6: Mark what could not be verified**

Anything that survives Step 2 as "cannot tell" goes inside:

```markdown
{{< callout type="warning" >}}
Not verified against the running cluster at the time of writing. Treat as
indicative; check `observability/base/` for what is actually deployed.
{{< /callout >}}
```

Being explicit about an unverified section is acceptable. Carrying it silently is not.

- [ ] **Step 7: Verify**

```bash
cd website && mise exec -- hugo --minify --gc && cd ..
./scripts/verify-doc-paths.sh
./scripts/validate-links.sh
```

- [ ] **Step 8: Commit**

```bash
git add website/content/docs/platform/observability
git commit -m "docs(platform): rebuild the observability docs from the manifests

observability.md had not been touched since November 2025 and its component
list no longer matched observability/base/. Rewritten against what Flux
actually deploys rather than migrated as-is; sections that could not be
verified are marked as such on the page instead of shipping silently.

Brings the LogsQL syntax rules out of .claude/rules/ and onto the page: dot
notation for Kubernetes labels, the log. prefix after unpack_json, and the
double-dollar escape for Grafana variables under Flux postBuild."
```

---

## Task 11: Migrate the AI Platform

**Files:**
- Create: `website/content/docs/platform/ai-platform/{_index,coding-clients,roadmap}.md`
- Read: `docs/ai.md` (385), `docs/coding-clients.md` (212), `docs/llm-platform-future-paths.md` (194), `clusters/mycluster-0/llm-platform.yaml`, `clusters/mycluster-0-llm-platform/README.md`, `docs/specs/done/2026-Q3/`

**Interfaces:**
- Produces: `/docs/platform/ai-platform/`.

- [ ] **Step 1: State both opt-in gates on `_index.md`**

Two independent gates must both be released for an end-to-end deploy. Verify both:

```bash
mise exec -- yq '.spec.suspend' clusters/mycluster-0/llm-platform.yaml
grep -n "TM_LLM_PLATFORM_ENABLED" opentofu/llm-platform/workflows.tm.hcl
```

Expected: `true`, and the env-var guard present. The page states that the default `terramate script run deploy` and the default Flux reconciliation both leave the cluster LLM-free.

- [ ] **Step 2: Drop the shipped paths from the roadmap**

`docs/llm-platform-future-paths.md` lists seven upgrade paths. At least two have shipped:

```bash
ls docs/specs/done/2026-Q3/ | grep -i "inferencepool\|saturation"
```

Path 4 (re-introduce InferencePool + EPP) shipped as SPEC-004 and SPEC-011. Check each of the seven against `docs/specs/done/` and carry forward only those still open. A roadmap listing delivered work as future work is worse than no roadmap.

- [ ] **Step 3: Verify the autoscaling description**

The design is KEDA `ScaledObject`s on leading vLLM saturation signals — the `running/max-num-seqs` ratio and `kv_cache_usage_perc` — with `min=1` by default. The legacy KEDA HTTP add-on is **not** used; the AI Gateway routes directly to each vLLM Service. Verify against the pinned composition version and SPEC-001.

- [ ] **Step 4: Verify**

```bash
cd website && mise exec -- hugo --minify --gc && cd ..
./scripts/verify-doc-paths.sh
./scripts/validate-links.sh
```

- [ ] **Step 5: Commit**

```bash
git add website/content/docs/platform/ai-platform
git commit -m "docs(platform): migrate the self-hosted LLM platform docs

Roadmap trimmed to what is still open — path 4 shipped as SPEC-004/SPEC-011 and
was still listed as future work. Both opt-in gates are stated up front so no
reader assumes the default deploy brings up GPUs."
```

---

## Task 12: Write the Concepts lane

**Files:**
- Create: `website/content/docs/concepts/{architecture,progressive-complexity,gitops-model,zero-trust,technology-choices,how-this-is-built}.md`
- Read: `README.md` §Core Concepts, `docs/gitops.md` §§1–2, `docs/technology-choices.md`, `docs/platform-constitution.md`, `.claude/rules/superpowers.md`, `docs/superpowers/`

**Interfaces:**
- Produces: `/docs/concepts/`, linked from the landing page's second card.

- [ ] **Step 1: Write `architecture.md`**

From `README.md` §Architecture Overview. Embeds `platform-overview.svg` (written in Task 16) and narrates the three bands: AWS managed services, the EKS cluster in four tiers, applications and data.

- [ ] **Step 2: Write `progressive-complexity.md`**

From `README.md` §Progressive Complexity. The `App` composition's ladder: an image-only claim through to a production application with managed PostgreSQL, Redis/Valkey, S3, autoscaling, HA and zero-trust networking. Show the shortest possible claim and the fullest one, and name what each rung adds.

- [ ] **Step 3: Write `gitops-model.md` and `zero-trust.md`**

`gitops-model.md` from `docs/gitops.md` §§What is GitOps / Why Flux — the *idea*, with the operational hierarchy staying in `platform/gitops/`.

`zero-trust.md` from `README.md` §Security by Design: private EKS endpoint, Tailscale, default-deny CiliumNetworkPolicy, Gateway API TLS termination, EKS Pod Identity, no deletion permissions for stateful services.

- [ ] **Step 4: Write `technology-choices.md`**

From `docs/technology-choices.md` §§Philosophy, Key Technology Decisions, Alternative Considerations. The stack **table** does not come here — it goes to `reference/technology-stack.md` in Task 14. Cross-link each decision to its ADR where one exists.

- [ ] **Step 5: Write `how-this-is-built.md` — new content**

The differentiating page. Covers:

- The design method: brainstorm → design → plan → subagent-driven execution → verification, with artifacts committed on the feature branch under `docs/superpowers/`.
- Why a [platform constitution]({{< relref "/docs/reference/platform-constitution.md" >}}) exists and what it makes non-negotiable.
- The gates: `./scripts/validate-manifests.sh` (schema + CEL via `flux schema validate`, then Polaris on the *rendered* bundle), `./scripts/validate-links.sh`, `./scripts/verify-doc-paths.sh`, `trivy config`, pre-commit.
- The evidence rule: no "done" claim without a fresh command run and its output cited.
- Honest scope: what AI-assisted development is used for here and what it is not.

Link to real examples in `docs/superpowers/specs/` on GitHub rather than reproducing them.

- [ ] **Step 6: Verify**

```bash
cd website && mise exec -- hugo --minify --gc && cd ..
./scripts/verify-doc-paths.sh
./scripts/validate-links.sh
```

- [ ] **Step 7: Commit**

```bash
git add website/content/docs/concepts
git commit -m "docs(concepts): write the concepts lane

Separates the ideas from the configuration that implements them — the README's
core-concepts material had no home once the README shrank.

Adds how-this-is-built, which had no source: the design method, the constitution
and the CI gates that enforce it. Few reference repositories show their
engineering process, and here it is a large part of what the repository is."
```

---

## Task 13: Write the Guides lane

**Files:**
- Create: `website/content/docs/guides/{fork-and-adapt,add-an-application,add-a-cloud-provider,troubleshooting}.md`
- Read: `opentofu/config.tm.hcl`, `opentofu/*/variables.tfvars`, `CLAUDE.md` §Troubleshooting, `.claude/rules/`, `docs/decisions/0007-cloud-abstraction-boundaries.md`, `docs/superpowers/specs/2026-08-18-gcp-support-design.md`

**Interfaces:**
- Produces: `/docs/guides/fork-and-adapt/`, which the landing page's fourth card links to directly.

- [ ] **Step 1: Enumerate every environment-specific value**

```bash
cat opentofu/config.tm.hcl
grep -rn "domain\|region\|cluster_name\|account" opentofu/*/variables.tfvars
grep -rn "ogenki.io" --include="*.yaml" --include="*.tf" --include="*.hcl" . | grep -v website/ | awk -F: '{print $1}' | sort -u | head -40
```

Every hit is something a forker must change. `fork-and-adapt.md` is only useful if this list is complete.

- [ ] **Step 2: Write `fork-and-adapt.md`**

Sections, in this order:

1. **What you must change** — a table: value, where it lives, what it affects. Domain, AWS region, cluster name, AWS account, GitHub App credentials, Tailscale tailnet and ACL tags, Route53 zones.
2. **What you can remove** — the LLM platform (already opt-in), the App Wizard, RunLore, the demo applications, self-hosted runners.
3. **The minimum viable subset** — the smallest set that still produces a working GitOps platform.
4. **What it costs** — the shape of the bill: EKS control plane, node groups plus Karpenter capacity, NAT, the OpenBao instances, S3 and Route53. State that figures are indicative and vary by region and usage rather than inventing precise numbers.
5. **What to do first** — the deploy path, linking to Get Started.

- [ ] **Step 3: Write `add-a-cloud-provider.md`**

ADR-0007's rule made operational. State the rule verbatim: **platform-facing APIs stay cloud-shaped, developer-facing APIs stay cloud-neutral.** Then: what a new provider must implement (network stack, cluster stack, identity binding, secrets store), which abstractions gain a sibling XRD rather than a new field, and which must not change at all (`App`, `SQLInstance` claims). Use the GCP work as the worked example.

- [ ] **Step 4: Write `troubleshooting.md`**

From `CLAUDE.md` §Common Issues and the `.claude/rules/` files. Must include the traps that are non-obvious and have each cost real time:

- **Gateways stuck "Waiting for controller"** — cilium-operator probes for the Gateway API CRDs **once, at startup**, and permanently disables its Gateway API controller if any are missing. No crash, no alert. Confirm with `kubectl logs -n kube-system -l io.cilium/app=operator | grep "Required GatewayAPI resources"`, recover with `kubectl rollout restart -n kube-system deployment/cilium-operator`, and fix durably by adding the CRD to `gateway_api_crds_urls` in `opentofu/eks/configure/locals.tf`.
- **DNS L7 inspection is mandatory for `toFQDNs`** — the kube-dns egress rule must carry `toPorts.rules.dns.matchPattern: "*"`, or Cilium never sees the resolved IPs and every follow-up TCP connection is silently dropped while DNS keeps working.
- **`matchPattern: "*"` does not span dots** — `*.huggingface.co` does not match `cas-bridge.xet.huggingface.co`.
- **`toEntities: world` excludes link-local, and `toCIDR` does not match host-network endpoints** — the EKS Pod Identity Agent at `169.254.170.23:80` needs `toEntities: ["host"]`.
- **Flux source sharding** — this repository shards Flux controllers; a `GitRepository` or `HelmRepository` placed under an application directory inherits `sharding.fluxcd.io/key=apps`, and the default-shard HelmChart then cannot find it. Sources live under `flux-sources`.
- Always check network policies first when something times out.

- [ ] **Step 5: Write `add-an-application.md`**

The task-oriented path: choose the App Wizard or hand-written YAML, what the claim needs, how to verify it reconciled. Links into `platform/developer-platform/` rather than repeating it.

- [ ] **Step 6: Verify**

```bash
cd website && mise exec -- hugo --minify --gc && cd ..
./scripts/verify-doc-paths.sh
./scripts/validate-links.sh
```

- [ ] **Step 7: Commit**

```bash
git add website/content/docs/guides
git commit -m "docs(guides): write the guides lane

fork-and-adapt is the guide the repository never had: which values are
environment-specific, what can be removed, the minimum viable subset, and the
shape of the bill. Without it a reader has to reverse-engineer every hardcoded
domain and account.

troubleshooting brings the expensive traps out of .claude/rules and into the
open — the cilium-operator startup CRD probe, the toFQDNs DNS-inspection
requirement, and Flux source sharding."
```

---

## Task 14: Write the Reference lane

**Files:**
- Create: `website/content/docs/reference/{repository-layout,technology-stack,commands,ci-workflows,glossary,further-reading}.md`
- Move: `docs/platform-constitution.md` → `website/content/docs/reference/platform-constitution.md`
- Read: `README.md` §Repository Structure, `docs/technology-choices.md` §Technology Stack, `CLAUDE.md`, `docs/ci-workflows.md`, `mise.toml`

**Interfaces:**
- Produces: `/docs/reference/platform-constitution/`, which `.claude/rules/platform-constitution.md` is re-pointed at in Task 17.

- [ ] **Step 1: Move the constitution with git history preserved**

```bash
git mv docs/platform-constitution.md website/content/docs/reference/platform-constitution.md
```

Then add the front matter at the top of the file (`title: Platform Constitution`, `weight: 50`, a description, `lastVerified: 2026-08-20`). Do not otherwise edit the body — it is a governance document and the agent rules load it.

- [ ] **Step 2: Write `technology-stack.md`**

The table from `docs/technology-choices.md` §Technology Stack, with every version re-verified:

```bash
grep -E '^[a-z"]' mise.toml
grep -E 'version' opentofu/config.tm.hcl
grep -rhn "version:" --include="helmrelease*.yaml" infrastructure/base observability/base security/base | sort -u | head -40
```

A version table that is wrong is worse than absent. If a version cannot be resolved from the repository, name the source of truth rather than a number.

- [ ] **Step 3: Write `commands.md`**

From `CLAUDE.md` §Common Commands and §Validation Commands. Every command verified to exist:

```bash
grep -n 'name *=' opentofu/workflows.tm.hcl opentofu/eks/init/workflows.tm.hcl opentofu/llm-platform/workflows.tm.hcl
ls scripts/
```

- [ ] **Step 4: Write `repository-layout.md` and `ci-workflows.md`**

`repository-layout.md` from `README.md` §Repository Structure, using the `{{< filetree/container >}}` shortcode. Verify against `ls`.

`ci-workflows.md` from `docs/ci-workflows.md`, minus the manifest-validation deep dive that went to `platform/gitops/validation.md` in Task 6. Verify the job list:

```bash
grep -n "^  [a-z-]*:$" .github/workflows/ci.yaml
ls .github/workflows/
```

Note that the new `docs-check` and `docs` workflows exist and what they gate.

- [ ] **Step 5: Write `glossary.md`**

Definitions, each one or two sentences: claim, composition, XR, XRD, EPI, stack, reconciliation, drift, tenant, prefix delegation, GitOps, managed resource, Configuration package, shard.

- [ ] **Step 6: Write `further-reading.md`**

The destination for the README's §Learning Resources, which Task 17 removes. Two sections:

- **Deep dives on this platform** — the seven blog.ogenki.io posts from the table in Global
  Constraints, each with one line on what it covers. This page collects them; the domain pages
  link them individually. It is a reading list on a reference page, **not** a blog index — no
  dates, no ordering by recency, no feed.
- **Upstream documentation** — Crossplane, Flux, Gateway API, Cilium, VictoriaMetrics.

Verify every URL resolves:

```bash
grep -o 'https://[^)]*' website/content/docs/reference/further-reading.md | while read -r u; do
  printf '%-70s %s\n' "$u" "$(curl -so /dev/null -w '%{http_code}' "$u")"
done
```

Expected: every line reports `200`.

- [ ] **Step 7: Verify**

```bash
cd website && mise exec -- hugo --minify --gc && cd ..
./scripts/verify-doc-paths.sh
./scripts/validate-links.sh
```

- [ ] **Step 8: Commit**

```bash
git add website/content/docs/reference docs/platform-constitution.md
git commit -m "docs(reference): write the reference lane and move the constitution

Constitution moved with git mv so its history survives; .claude/rules is
re-pointed in the cleanup commit. Every version in the stack table re-derived
from mise.toml, config.tm.hcl and the HelmReleases rather than copied from
technology-choices.md, which had drifted."
```

---

## Task 15: Migrate the Decisions lane and rewire its inbound links

**Files:**
- Move: `docs/decisions/*.md` → `website/content/docs/decisions/`
- Create: `website/content/docs/decisions/_index.md`
- Modify: 12 files that link to `docs/decisions/000*`

**Interfaces:**
- Produces: `/docs/decisions/000N-*/` URLs, referenced from concepts, guides, get-started and the landing page.

- [ ] **Step 1: Enumerate the inbound links before moving anything**

```bash
git grep -n "decisions/000" -- '*.md' > /tmp/adr-inbound.txt
wc -l /tmp/adr-inbound.txt
```

Expected: 12 files. This list is the checklist for Step 4.

- [ ] **Step 2: Move the files**

```bash
mkdir -p website/content/docs/decisions
git mv docs/decisions/0001-use-kcl-for-crossplane-compositions.md website/content/docs/decisions/
git mv docs/decisions/0002-eks-pod-identity-over-irsa.md website/content/docs/decisions/
git mv docs/decisions/0003-vllm-production-stack-over-kserve.md website/content/docs/decisions/
git mv docs/decisions/0004-amazon-s3-files-for-model-weights-storage.md website/content/docs/decisions/
git mv docs/decisions/0005-gke-standard-self-managed-cilium.md website/content/docs/decisions/
git mv docs/decisions/0006-nap-computeclass-over-karpenter.md website/content/docs/decisions/
git mv docs/decisions/0007-cloud-abstraction-boundaries.md website/content/docs/decisions/
git mv docs/decisions/template.md website/content/docs/decisions/
git mv docs/decisions/README.md website/content/docs/decisions/_index.md
```

- [ ] **Step 3: Add front matter to each ADR**

`title` is the ADR's H1 without the `ADR-000N: ` prefix; `linkTitle` is `ADR-000N`; `weight` is the ADR number × 10; `description` is the decision in one sentence; `lastVerified: 2026-08-20`. `_index.md` gets `title: Decisions`, `weight: 60`, and a table of all seven with their status.

- [ ] **Step 4: Rewire every inbound link**

Work through `/tmp/adr-inbound.txt`. Two cases:

- Links **from inside** `website/content/` → rewrite as `relref`.
- Links **from outside** (`docs/specs/**`, `docs/superpowers/**`, `.claude/rules/**`, `CLAUDE.md`) → rewrite as the new relative path, e.g. from `docs/superpowers/specs/X.md` the target becomes `../../../website/content/docs/decisions/0007-cloud-abstraction-boundaries.md`.

Do **not** add allowlist entries. `./scripts/validate-links.sh` is the gate.

- [ ] **Step 5: Verify**

```bash
cd website && mise exec -- hugo --minify --gc && cd ..
./scripts/verify-doc-paths.sh
./scripts/validate-links.sh
git grep -c "docs/decisions/000" -- '*.md' || echo "no stale ADR paths remain"
```

Expected: all exit 0, and the final grep finds nothing.

- [ ] **Step 6: Commit**

```bash
git add -A website/content/docs/decisions docs CLAUDE.md .claude
git commit -m "docs(decisions): move the ADRs into the site and rewire inbound links

git mv preserves history. All 12 inbound references rewritten rather than
allowlisted — eight of them live in the read-only spec archive, where a path
grep cannot see relative-link rot, which is exactly the failure validate-links
exists to catch."
```

---

## Task 16: Produce the diagrams

**Files:**
- Create: `docs/architecture/{bootstrap-stages,flux-dependency-tree,request-path,secrets-and-pki,app-claim-expansion,observability-flow}.drawio`
- Create: `scripts/export-diagrams.sh`
- Create: `website/assets/diagrams/*.svg`, `website/static/images/diagrams/platform-overview.svg`
- Modify: `docs/architecture/README.md`

**Interfaces:**
- Consumes: the content pages from Tasks 5–14, which reference these image paths.
- Produces: the SVG assets the landing page and each platform section embed.

- [ ] **Step 1: Write the export script**

`scripts/export-diagrams.sh`:

```bash
#!/usr/bin/env bash
#
# export-diagrams.sh — regenerate every diagram export from its .drawio source.
#
# Sources live in docs/architecture/ (one topic per file, kebab-case, ogenki
# preset). Exports are written where each consumer needs them:
#   - website/assets/diagrams/     for docs pages
#   - website/static/images/diagrams/  for the landing page (no asset pipeline)
#   - docs/architecture/img/       PNG, only where GitHub also renders it
#
# SVG is the site format. The PNG-only rule recorded in docs/architecture/README.md
# exists because GitHub's sanitizer strips <foreignObject> text from drawio SVG,
# which does not apply to a Hugo site.
#
# Requires the draw.io desktop app on PATH.

set -euo pipefail
cd "$(dirname "$0")/.."

command -v drawio >/dev/null || { echo "drawio not on PATH — install the desktop app"; exit 1; }

SRC="docs/architecture"
ASSETS="website/assets/diagrams"
STATIC="website/static/images/diagrams"
mkdir -p "$ASSETS" "$STATIC"

SINGLE_PAGE=(
  bootstrap-stages
  flux-dependency-tree
  request-path
  secrets-and-pki
  app-claim-expansion
  observability-flow
)

for name in "${SINGLE_PAGE[@]}"; do
    echo "==> $name.svg"
    drawio -x -f svg -b 10 -o "$ASSETS/$name.svg" "$SRC/$name.drawio"
done

# platform-overview is embedded in both the site and the GitHub README, so it
# needs both formats and lands in static/ for the home layout.
echo "==> platform-overview (svg + png)"
drawio -x -f svg -b 10 -o "$STATIC/platform-overview.svg" "$SRC/platform-overview.drawio"
drawio -x -f png -s 2 -b 10 -o "$SRC/img/platform-overview.png" "$SRC/platform-overview.drawio"

for i in 0 1 2; do
    echo "==> llm-platform page $i"
    drawio -x -f svg -b 10 --page-index "$i" \
        -o "$ASSETS/llm-platform-$((i + 1)).svg" "$SRC/llm-platform.drawio"
done

echo
echo "==> Size check (budget: 500 KB per new export)"
find "$ASSETS" "$STATIC" -name '*.svg' -size +500k -printf '    OVER BUDGET: %p (%s bytes)\n' | tee /tmp/oversize
[ ! -s /tmp/oversize ] || { echo "Reduce embedded raster logos or their resolution."; exit 1; }
echo "    all exports within budget"
```

- [ ] **Step 2: Make it executable and confirm it runs against the existing sources**

```bash
chmod +x scripts/export-diagrams.sh
./scripts/export-diagrams.sh
```

Expected: `platform-overview` and the three `llm-platform` pages export; the six new ones fail because their sources do not exist yet. Comment out the `SINGLE_PAGE` loop for this run, or create empty sources first.

- [ ] **Step 3: Author the six diagrams**

All six use the **ogenki** preset (`~/.drawio-skill/styles/ogenki.json`) via the drawio skill. Conventions, restated from `docs/architecture/README.md` because they are load-bearing:

- Indigo = service, violet = security, emerald = storage, amber = scaling, red = failure, slate dashed = external or opt-in-and-currently-off.
- Every box is a real object in the cluster, **named as it is named in the manifests**. An aspirational box is dashed and says so in its label.
- Edge colours: slate = request flow, emerald = storage/weights, amber = scaling decisions, red = failure paths, dashed grey = optional or disabled.
- AWS services use `mxgraph.aws4.resourceIcon`; cloud-native components use brand logos embedded as PNG data-URIs. **Rasterize SVG → PNG before embedding** (`rsvg-convert -w 64 -h 64`) — headless export does not render SVG data URIs. Embed as `image=data:image/png,<base64>` with a **comma**, not `;base64,`, which terminates the style value and silently drops the icon.

| Diagram | Content | Verify against |
|---|---|---|
| `bootstrap-stages` | network → OpenBao → EKS init → EKS configure, with what each stage creates and the two-stage CNI swap | `opentofu/*/workflows.tm.hcl`, `opentofu/eks/*/main.tf` |
| `flux-dependency-tree` | namespaces → CRDs → Crossplane → EPIs → security → infrastructure → observability → apps, with the suspended `llm-platform` umbrella dashed | `clusters/mycluster-0/*.yaml` `dependsOn` |
| `request-path` | internet and Tailscale → the two gateways → HTTPRoute → application, with ExternalDNS and cert-manager alongside | `infrastructure/base/gapi/` |
| `secrets-and-pki` | root CA → intermediate → leaf; ESO pulling from AWS Secrets Manager and OpenBao into Kubernetes Secrets | `opentofu/openbao/`, `security/base/` |
| `app-claim-expansion` | one `App` claim → Deployment, Service, HTTPRoute, HPA, PDB, CiliumNetworkPolicy, SQLInstance, EPI, Bucket | the App composition's rendered output |
| `observability-flow` | scrape → vmagent → VictoriaMetrics; Vector → VictoriaLogs; Grafana; alerts → OnCall/Slack | `observability/base/` |

- [ ] **Step 4: Export and check sizes**

```bash
./scripts/export-diagrams.sh
ls -lh website/assets/diagrams/ website/static/images/diagrams/
```

Expected: every new SVG under 500 KB; the script exits 0.

- [ ] **Step 5: Embed each diagram in its page**

Each `platform/<domain>/_index.md` opens with its diagram, immediately after the front matter and the first paragraph. Every image needs alt text that describes the mechanism, not the picture — `![Bootstrap stages]` is useless; describe what flows where.

- [ ] **Step 6: Update the architecture index**

Rewrite `docs/architecture/README.md`: nine sources, the SVG-for-the-site convention and why the old PNG-only rule applied only to GitHub, and `./scripts/export-diagrams.sh` as the single regeneration command replacing the hand-written per-file invocations.

- [ ] **Step 7: Verify**

```bash
cd website && mise exec -- hugo --minify --gc && cd ..
./scripts/verify-doc-paths.sh
./scripts/validate-links.sh
./scripts/export-diagrams.sh
```

Then run `hugo server` and confirm each diagram renders and zooms in both light and dark themes.

- [ ] **Step 8: Commit**

```bash
git add docs/architecture website/assets/diagrams website/static/images/diagrams scripts/export-diagrams.sh website/content
git commit -m "docs(architecture): add six domain diagrams and one export command

Every platform section now opens with a diagram, so the shape of a subsystem is
visible before any prose is read. app-claim-expansion is the one that shows what
this repository is actually for: a single claim becoming nine objects.

SVG for the site — the PNG-only rule was a GitHub sanitizer constraint that does
not apply to Hugo. export-diagrams.sh replaces the hand-copied per-file drawio
invocations and enforces the 500 KB budget."
```

---

## Task 17: Rewire the repository and delete the old documentation

**Files:**
- Modify: `README.md`, `CLAUDE.md`, `.claude/rules/{platform-constitution,superpowers,crossplane-validation,process,observability}.md`, `.claude/skills/spec-research/SKILL.md`
- Modify: `scripts/validate-links.sh`, `.linkcheck-allow`
- Delete: `docs/*.md`, `docs/plans/`, `docs/assets/`, `opentofu/openbao/*/docs/`

**Interfaces:**
- Consumes: every content page from Tasks 5–15. Nothing may be deleted before its content has landed.

- [ ] **Step 1: Prove every source has a destination before deleting anything**

```bash
for f in docs/*.md; do
  base=$(basename "$f" .md)
  hits=$(grep -rl "$base" website/content/ 2>/dev/null | wc -l)
  printf '%-45s %s\n' "$f" "$hits site references"
done
```

Any source with zero references is either unmigrated or a deliberate deletion. Resolve each one explicitly — do not delete on the assumption it was handled.

- [ ] **Step 2: Delete the migrated and superseded sources**

```bash
git rm docs/ai.md docs/app-wizard.md docs/apps-user-guide.md docs/ci-workflows.md \
       docs/coding-clients.md docs/crossplane.md docs/gitops.md docs/ingress.md \
       docs/llm-platform-future-paths.md docs/observability.md docs/opentofu.md \
       docs/postgresql-monitoring-architecture.md docs/tailscale-gateway-api.md \
       docs/technology-choices.md
git rm docs/crossplane-kcl-authoring.md            # content belongs in Smana/crossplane-configuration
git rm docs/plans/crossplane-validation-improvements.md  # superseded by SPEC-007
git rm -r opentofu/openbao/cluster/docs opentofu/openbao/management/docs
```

- [ ] **Step 3: Confirm what remains**

```bash
ls docs/
```

Expected exactly: `architecture`, `specs`, `superpowers`. Anything else is unfinished migration.

- [ ] **Step 4: Scope the link checker**

In `scripts/validate-links.sh`, change the file list so the site tree is excluded, and record why:

```python
files = subprocess.run(['git', 'ls-files', '*.md'],
                       capture_output=True, text=True).stdout.split()
# website/content is Hugo's tree: internal links are `relref` shortcodes, which
# this regex cannot resolve, and Hugo's own refLinksErrorLevel: ERROR already
# fails the build on a dead ref. Two gates, each authoritative for one tree.
files = [f for f in files if not f.startswith('website/content/')]
```

Update the script's header comment to name the split.

- [ ] **Step 5: Empty the allowlist**

```bash
cat > .linkcheck-allow <<'EOF'
# Known-broken relative Markdown links, accepted for now.
# Format: <file><TAB><target>.  Delete entries as they are fixed; never add one
# to route around a break your own change introduced.
#
# Currently empty. The App Wizard screenshot placeholders that used to live here
# moved to website/assets/screenshots/app-wizard/ with the page.
EOF
```

- [ ] **Step 6: Shrink the README**

Target roughly 120 lines. Keep: title and one-paragraph pitch, the architecture PNG, a six-command quickstart, the repository structure, licence and acknowledgements. Replace the entire §Documentation section with:

```markdown
## Documentation

Full documentation — deploy guides, platform internals, concepts, and the
architecture decision records — is published at **[cnref.ogenki.io](https://cnref.ogenki.io)**.

- [Get Started](https://cnref.ogenki.io/docs/get-started/) — deploy the platform in about 30 minutes
- [Platform](https://cnref.ogenki.io/docs/platform/) — every domain, what runs and why
- [Fork and adapt](https://cnref.ogenki.io/docs/guides/fork-and-adapt/) — use this repository for your own platform
- [Decisions](https://cnref.ogenki.io/docs/decisions/) — what was chosen, and what over
```

Remove: §Core Concepts (→ `concepts/`), §Real Production Patterns (→ `platform/`), §Technology Stack
(→ `reference/technology-stack.md`), §Learning Resources (→ `reference/further-reading.md`, with each
post also linked from the domain page it deepens), and the long §Optional LLM Platform block
(→ `platform/ai-platform/`). Keep the LLM platform to two sentences plus a link.

Do **not** drop the blog links on the floor: they are the best long-form explanation of several
components. Confirm the destination exists before removing them:

```bash
grep -c "blog.ogenki.io" website/content/docs/reference/further-reading.md
```

Expected: at least 7.

- [ ] **Step 7: Re-point the agent-facing files**

```bash
git grep -n "docs/platform-constitution.md\|docs/tailscale-gateway-api.md\|docs/opentofu.md\|docs/crossplane.md\|docs/observability.md\|docs/ci-workflows.md\|docs/apps-user-guide.md\|docs/gitops.md\|docs/ingress.md\|docs/ai.md" -- CLAUDE.md '.claude/**'
```

Rewrite each hit. `docs/platform-constitution.md` becomes `website/content/docs/reference/platform-constitution.md`. Paths that moved into the site and have no agent-facing role become the published URL instead.

- [ ] **Step 8: Verify the whole repository**

```bash
./scripts/validate-links.sh
./scripts/verify-doc-paths.sh
cd website && mise exec -- hugo --minify --gc && cd ..
mise exec -- pre-commit run --all-files
```

Expected: all exit 0. `validate-links.sh` must report `0 allowlisted`.

- [ ] **Step 9: Commit**

```bash
git add -A
git commit -m "docs: retire docs/ into the site and rewire every consumer

docs/ now holds only architecture/, specs/ and superpowers/ — the artifacts that
are agent- and contributor-facing. Everything reader-facing is published.

validate-links.sh no longer walks website/content: internal links there are
relref shortcodes it cannot resolve, and Hugo's refLinksErrorLevel already fails
the build on a dead ref. Each gate is now authoritative for exactly one tree, and
the allowlist is empty for the first time."
```

---

## Task 18: Final verification and launch

**Files:**
- Modify: any page failing a check below.

**Interfaces:**
- Consumes: everything.

- [ ] **Step 1: Full gate run**

```bash
cd website && mise exec -- hugo --minify --gc && cd ..
./scripts/verify-doc-paths.sh
./scripts/validate-links.sh
./scripts/validate-manifests.sh
mise exec -- pre-commit run --all-files
```

Expected: every command exits 0. `validate-manifests.sh` must report `Invalid: 0, Skipped: 0` — this migration touched no manifests, so a regression here means something unintended was changed.

- [ ] **Step 2: Confirm no page shipped unverified**

```bash
missing=$(grep -rL "lastVerified" website/content/docs --include="*.md")
[ -z "$missing" ] && echo "every page carries lastVerified" || { echo "$missing"; exit 1; }
```

- [ ] **Step 3: Test search**

```bash
cd website && mise exec -- hugo server
```

Search each term and confirm the expected first hit:

| Query | Expected first hit |
|---|---|
| `wireguard` | `platform/networking/cilium` |
| `prefix delegation` | `platform/networking/cilium` |
| `AppRole` | `platform/security/openbao` |
| `progressive complexity` | `concepts/progressive-complexity` |
| `fork` | `guides/fork-and-adapt` |
| `EKS Pod Identity` | `decisions/0002-eks-pod-identity-over-irsa` |

- [ ] **Step 4: Check both themes and mobile**

With the server running: toggle light and dark on the landing page and on one page from each lane. Confirm links are clearly distinguishable from body text in both — this is the check on Task 2's derived lightness values. Then narrow the window to 375 px and confirm the sidebar collapses, no horizontal scroll appears, and diagrams scale down.

- [ ] **Step 5: Lighthouse**

Run Lighthouse against `http://localhost:1313`.
Expected: accessibility ≥ 95, performance ≥ 90. The most likely accessibility failure is missing or unhelpful image alt text — fix on the page, not by lowering the bar.

- [ ] **Step 6: Confirm the multi-cloud stubs hold the line**

```bash
grep -rln "aws\|AWS\|EKS" website/content/docs/platform/gitops website/content/docs/platform/observability website/content/docs/concepts
```

Each hit must be a deliberate reference to the current implementation, not an assumption baked into a page that ADR-0007 says should be cloud-neutral. Fix any that are not.

- [ ] **Step 7: Open the pull request**

```bash
git push -u origin feat/docs-hugo
gh pr create --title "docs: publish the documentation as a Hugo site at cnref.ogenki.io" --body "$(cat <<'BODY'
Publishes the repository's documentation as a searchable Hugo + Hextra site,
reorganised into audience lanes, with every page verified against the repository
rather than moved as-is.

Design: `docs/superpowers/specs/2026-08-20-docs-hugo-site-design.md`
Plan: `docs/superpowers/plans/2026-08-20-docs-hugo-site.md`

## What changed

- `website/` — Hugo site, Hextra as a Hugo Module, no npm toolchain
- `docs/` retires to `architecture/`, `specs/`, `superpowers/`; everything
  reader-facing is published
- 703 lines of OpenBao documentation promoted out of `opentofu/openbao/*/docs/`
- `ingress.md` and `tailscale-gateway-api.md` merged; each topic has one owner
- Six new diagrams, one per platform domain
- `observability.md` rebuilt from the manifests — it had drifted since November
- New: fork-and-adapt, add-a-cloud-provider, how-this-is-built, cilium, glossary
- The IA already has a place for GCP, per ADR-0007

## Verification

| Gate | Result |
|---|---|
| `hugo --minify --gc` | exit 0, no unresolved refs |
| `./scripts/verify-doc-paths.sh` | exit 0 |
| `./scripts/validate-links.sh` | exit 0, allowlist empty |
| `./scripts/validate-manifests.sh` | Invalid: 0, Skipped: 0 |
| Lighthouse | accessibility / performance recorded in the thread |

## Before merge

- [ ] DNS: `cnref.ogenki.io CNAME smana.github.io` in the public `ogenki.io` zone
- [ ] Repository Settings → Pages → Source = GitHub Actions
BODY
)"
```

- [ ] **Step 8: After merge, confirm the deploy**

```bash
gh run list --workflow=docs.yml --limit 1
curl -sI https://cnref.ogenki.io | head -1
```

Expected: the workflow concluded `success`, and the curl returns `HTTP/2 200`. Until the DNS record exists, check the `page_url` output of the deploy job instead.

---

## Notes for the executor

**Task order is load-bearing, because `refLinksErrorLevel: ERROR` turns a link to a not-yet-written
page into a build failure.** Content tasks are *not* freely reorderable.

Hard dependencies:

| Task | Must run after | Why |
|---|---|---|
| 2, 3, 4 | 1 | nothing builds without the site |
| every content task | 4 | the lane indexes must exist |
| 5 (get-started) | **15** (decisions) | the GCP stub links ADR-0005/0006/0007 |
| 7 (networking) | **8** (security) *or* stub `pki-and-secrets.md` first | `gateway-api.md` links TLS termination |
| 9 (developer-platform) | 5, 7, **10** | links `first-app`, `gateway-api`, and `platform/observability` |
| 12 (concepts) | **14** (reference), **15** (decisions) | links the constitution and every ADR |
| 13 (guides) | 5, 9, 10 | links get-started, the App docs and observability |
| 16 (diagrams) | 6–11 | diagrams are verified against those pages' content |
| 17 (cleanup) | **all content tasks** | it deletes the sources |
| 18 | 17 | it is the final gate |

**Recommended order:** 1 → 2 → 3 → 4 → **15** → **14** → 5 → 6 → 8 → 7 → 10 → 9 → 11 → 12 → 13 → 16 → 17 → 18.

Decisions and Reference move first because almost everything links into them and both are cheap —
15 is a `git mv` plus front matter, 14 is largely re-derivation from files that already exist.
Security precedes networking, and observability precedes the developer platform, for the same
reason: the link target should exist before the link.

Genuinely parallelisable, once 15 and 14 are done: **6, 8, 10, 11** have no cross-links between
them.

**The one rule that carries the whole plan:** a page is not migrated until it has been checked against the repository, and it says so via `lastVerified`. A `git mv` with front matter added is not a migration — it is a move that has laundered stale content into a public URL.
