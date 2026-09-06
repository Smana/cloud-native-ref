---
description: Icon resolution for docs/architecture diagrams — the ogenki preset's icon step, which the skill itself does not enforce
globs:
  - "docs/architecture/**"
  - "website/static/images/diagrams/**"
---

# Diagram Rules — icons are a required step, not a flourish

Applies to every `.drawio` under `docs/architecture/`. The general drawio
workflow lives in the `drawio-skill` skill and the **ogenki** style preset
(`~/.drawio-skill/styles/ogenki.json`); this file is the delta the skill cannot
carry, and the reason it exists is specific:

**The preset's `icons` block is inert.** `styles/schema.json` declares
`additionalProperties: false` and does not list `icons`, and the skill's
*Applying a preset* procedure has steps for colour, shapes, edges, fonts and
extras — but none for icons. So the preset's careful icon guidance is prose in a
key no code path reads. Measured consequence: five of this repo's ten
single-page diagrams shipped with **zero** icons across 206 vertices, while the
seventeen logos that do exist sat trapped inside `platform-overview.drawio`,
unreachable from any other file.

The skill is a pinned vendored copy (`~/.claude/skills/drawio-skill/INSTALLED_FROM.md`
— *"Update: review a newer commit, then re-copy"*), so a fix inside it is erased
on the next update. This rule is where the step lives instead.

## The step

**Before writing any box, resolve an icon for it.** In this order — stop at the
first hit:

| # | Source | How | Cost |
|---|--------|-----|------|
| 1 | `docs/architecture/icons/` | `./scripts/diagram-icons.py style <name>` | none — 15 logos already rasterised |
| 2 | mxgraph stencil | `python3 ~/.claude/skills/drawio-skill/scripts/shapesearch.py "<terms>"`, then rasterise it into `icons/` ([recipe](../../docs/architecture/README.md#rasterising-an-mxgraph-stencil)) | one export |
| 3 | CNCF Artwork | **list** `projects/<slug>/icon/color/` and pick the SVG — filenames are not derivable from the slug | one fetch |
| 4 | Project brand | `python3 ~/.claude/skills/drawio-skill/scripts/aiicons.py "<brand>" --embed`, then rasterise | one fetch |
| 5 | — | a clean ogenki box, no icon | the honest fallback |

Reaching step 5 is fine. Skipping straight to it without trying 1–4 is the
failure this rule exists to stop.

`./scripts/diagram-icons.py audit` lists every box that names a product and
renders without one, grouped by which of the four sources would supply it. It is
**advisory and deliberately not a CI gate**: whether a box wants a logo is a
judgment call, and a gate that can go red on a judgment call gets switched off.

## Never on a grouping frame

An icon on a frame labels the grouping, not a thing — and it *looks* broken, because
`imageVerticalAlign=middle` centres the logo in the frame's full height, so it floats halfway down
the left edge over the border and the children. Three slipped through before this was checked.

`./scripts/diagram-icons.py audit` now reports these under **MISPLACED**. Its test is `container=1`,
plus an area threshold for the section-band shape — a wide, short, top-aligned cell whose contents
are siblings drawn inside it rather than child cells, which is why "is another cell's parent" is not
a sufficient test.

## Look at every icon before naming it

**Three of the first seventeen were wrong, and none was catchable by name.** A cell called
`karpenter-keda` held only the KEDA mark; one called `eks` held the plain Kubernetes wheel; and
`shapesearch`'s exact-name match for "Cloud Storage" is a generic server rack, while the real GCS
bucket is *unnamed* in the results.

Render a labelled contact sheet and read it:

```bash
for f in docs/architecture/icons/*.png; do n=$(basename "$f" .png); \
  magick "$f" -resize 110x110 -background white -flatten -gravity south \
    -splice 0x26 -pointsize 15 -annotate +0+4 "$n" "/tmp/l-$n.png"; done
magick montage /tmp/l-*.png -tile 5x -geometry +8+8 -background '#f1f5f9' /tmp/sheet.png
```

Two more traps the CNCF lane carries specifically:

- **Filenames are not slugs.** `external-secrets-operator` ships `eso-icon-color.svg`. List the
  directory (`api.github.com/repos/cncf/artwork/contents/projects/<slug>/icon/color`) rather than
  guessing a name.
- **Not everything is a CNCF project.** Valkey is Linux Foundation, Gateway API is a Kubernetes SIG
  rather than a project, and Alertmanager belongs to Prometheus. Probe before assuming a lane.
  (OpenTofu *is* in `cncf/artwork` despite being an LF project — so probe rather than reason.)

## An icon must not assert something false

Beyond the frame and both-clouds rules below, the sharper test is whether the logo claims something
untrue about *this* platform. **Alertmanager keeps no Prometheus mark**: the box sits in a diagram
whose subject is that observability runs on VictoriaMetrics, and a Prometheus flame there reads as
"Prometheus is deployed". The icon was fetched, judged, and the asset deleted rather than left to
rot in the library.

## Uniform columns are all or nothing

Iconing three of six stack boxes reads as noise, which is why `bootstrap-stages`' stack column was
left plain in two passes. Iconing **all six** — once you notice every one of them *is* an OpenTofu
stack — keeps the column uniform and makes it say something. Prefer that resolution over a
permanent skip when one logo covers the whole column.

## When an icon is wrong

Icon the box's **subject**, not something its body text mentions. A box titled
*Leaf certificates* whose second line says "signed by OpenTofu-managed PKI" gets
no OpenTofu logo — the box is about certificates. `audit` follows this rule by
reading only the first line; `audit --all` relaxes it and is noisier on purpose.

Two more cases that stay plain: a box representing a **concept** (`the CNI swap`,
`Always rendered — 7 objects`) and a **container/grouping** frame. Logos on those
label the wrong thing and make the diagram harder to read, not easier.

## Embedding — two traps, both silent

1. **PNG, never SVG.** Headless drawio export does not render SVG data URIs.
   The diagram looks right in the desktop app and exports with an empty box.
   Always `rsvg-convert -w 64 -h 64` first.
2. **Comma, never `;base64,`.** The style is
   `image=data:image/png,<base64>`. A semicolon terminates the mxCell style
   value, so `;base64,` silently truncates the style and drops the image *and*
   every property after it.

The ogenki convention is logo left, text right —
`imageAlign=left;imageVerticalAlign=middle;imageWidth=24;imageHeight=24;spacingLeft=42;align=left`.
`diagram-icons.py style` emits exactly this, so prefer it over hand-rolling.

## Adding to the library

A logo used by a second diagram belongs in `docs/architecture/icons/`, not
embedded twice. Rasterise to PNG, drop it in, add its entry to `manifest.json`.
Check `aliases` first — `victorialogs` and `victoriatraces` currently alias the
VictoriaMetrics mark because `platform-overview` used one logo for all three;
replacing them with the real upstream marks means adding two files and deleting
two alias entries.

## After any diagram change

```bash
./scripts/export-diagrams.sh      # regenerates every SVG the site embeds
./scripts/validate-links.sh       # relative links, after any file move
./scripts/validate-doc-claims.sh  # the pages that describe the diagram
```

`export-diagrams.sh` pins the drawio version, because a different build
perturbs the fallback `<text>` fills in ways that read as diff noise — see the
comment block at the top of the script. To re-export only what changed, copy its
`SVGOPTS` rather than inventing flags: `-x -f svg -b 10 --embed-svg-fonts false`,
and `--page-index` is **1-based**.
