# Diagrams

## Mermaid is the default

Use **mermaid** for any new diagram in documentation — READMEs, ADRs, the docs site, PR bodies. It
renders on GitHub and in the site without a build step, it diffs as text so a review can read the
change, and every agent can author it.

Reach for `.drawio` only when:

- the user explicitly asks for drawio, **or**
- you are editing a diagram that already exists in this directory.

The rest of this file covers that second case. It exists because the `drawio-skill` preset's
`icons` block is **inert**: `styles/schema.json` declares `additionalProperties: false` and does
not list `icons`, so the preset's icon guidance sits in a key no code path reads. The measured
consequence was five of ten single-page diagrams shipping with zero icons across 206 vertices,
while seventeen logos sat trapped inside `platform-overview.drawio`.

## Resolve an icon before writing the box

Stop at the first hit:

| # | Source | How |
|---|---|---|
| 1 | `icons/` | `./scripts/diagram-icons.py style <name>` — 15 logos already rasterised |
| 2 | mxgraph stencil | `shapesearch.py "<terms>"`, then rasterise into `icons/` |
| 3 | CNCF Artwork | **list** `projects/<slug>/icon/color/` and pick the SVG — filenames are not derivable |
| 4 | Project brand | `aiicons.py "<brand>" --embed`, then rasterise |
| 5 | — | a clean ogenki box, no icon |

Reaching step 5 is fine. Skipping to it without trying 1–4 is the failure this rule exists to stop.
`./scripts/diagram-icons.py audit` lists boxes that name a product and render without one,
grouped by which source would supply it. **Advisory, deliberately not a CI gate** — whether a box
wants a logo is a judgment call, and a gate that can go red on a judgment call gets switched off.

## Look at every icon before naming it

Three of the first seventeen were wrong and none was catchable by name: `karpenter-keda` held only
the KEDA mark, `eks` held the plain Kubernetes wheel, and `shapesearch`'s exact-name match for
"Cloud Storage" is a generic server rack while the real GCS bucket is *unnamed* in the results.

**Check at 24px, not on a contact sheet.** At 110px everything looks fine. Gateway API's logo is
genuine and measurably distinct — the Kubernetes wheel with routing arrows, 12.7% of pixels — but
at render size the arrows vanish and it *is* the Kubernetes wheel. It was fetched, compared at
render size, and dropped.

```bash
magick icons/<a>.png -resize 24x24 -background white -flatten -resize 400% /tmp/a.png
magick icons/<b>.png -resize 24x24 -background white -flatten -resize 400% /tmp/b.png
magick montage /tmp/a.png /tmp/b.png -tile 2x -geometry +8+8 /tmp/cmp.png
```

**`aiicons.py` returns the wrong product outside its scope, confidently.** It is an AI/LLM-brand
tool (lobe-icons): asked for `vector` it returns **vectorizerai**, asked for `gateway api` it
returns **cometapi**. Neither is an error — both are plausible hits for a different product.

**`none` is a real answer.** Vector, Valkey, Karpenter and Alertmanager have no mark at any source
probed. The catalog records them as `none` so the next pass does not repeat the search.

Two traps in the CNCF lane: **filenames are not slugs** (`external-secrets-operator` ships
`eso-icon-color.svg`), and **not everything is a CNCF project** — Valkey is Linux Foundation,
Gateway API is a Kubernetes SIG, Alertmanager belongs to Prometheus, and OpenTofu *is* in
`cncf/artwork` despite being LF. Probe rather than reason.

## When an icon is wrong

**An icon must not assert something false.** Alertmanager keeps no Prometheus mark: the box sits in
a diagram whose subject is that observability runs on VictoriaMetrics, and a Prometheus flame there
reads as "Prometheus is deployed". The asset was deleted rather than left to rot in the library.

**Never on a grouping frame.** An icon on a frame labels the grouping, not a thing — and it *looks*
broken, because `imageVerticalAlign=middle` centres it in the frame's full height so it floats
halfway down the left edge over the border and the children. `audit` reports these under
**MISPLACED**, testing `container=1` plus an area threshold for the section-band shape.

Icon the box's **subject**, not something its body text mentions. A box titled *Leaf certificates*
whose second line says "signed by OpenTofu-managed PKI" gets no OpenTofu logo. `audit` follows this
by reading only the first line; `audit --all` relaxes it and is noisier on purpose. Boxes
representing a **concept** (`the CNI swap`) and grouping frames stay plain.

**Uniform columns are all or nothing.** Iconing three of six stack boxes reads as noise. Iconing
all six — once you notice every one of them *is* an OpenTofu stack — keeps the column uniform and
makes it say something.

## Embedding — two silent traps

1. **PNG, never SVG.** Headless drawio export does not render SVG data URIs. It looks right in the
   desktop app and exports an empty box. Always `rsvg-convert -w 64 -h 64` first.
2. **Comma, never `;base64,`.** The style is `image=data:image/png,<base64>`. A semicolon
   terminates the mxCell style value, silently dropping the image *and* every property after it.

The ogenki convention is logo left, text right. `diagram-icons.py style` emits exactly this, so
prefer it over hand-rolling:
`imageAlign=left;imageVerticalAlign=middle;imageWidth=24;imageHeight=24;spacingLeft=42;align=left`

A logo used by a second diagram belongs in `icons/`, not embedded twice. Check `aliases` first —
`victorialogs` and `victoriatraces` currently alias the VictoriaMetrics mark.

## After any diagram change

```bash
./scripts/export-diagrams.sh      # regenerates every SVG the site embeds
./scripts/validate-links.sh       # after any file move
./scripts/validate-doc-claims.sh  # the pages that describe the diagram
```

`export-diagrams.sh` pins the drawio version, because a different build perturbs the fallback
`<text>` fills in ways that read as diff noise. To re-export only what changed, copy its `SVGOPTS`
rather than inventing flags — and note `--page-index` is **1-based**.
