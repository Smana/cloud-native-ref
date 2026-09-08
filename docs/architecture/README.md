# Architecture diagrams

Drawio (`.drawio`) sources. Open with the [drawio desktop app](https://www.drawio.com/) or the
[VS Code "Draw.io Integration" extension](https://marketplace.visualstudio.com/items?itemName=hediet.vscode-drawio).

**One command regenerates every export:**

```bash
./scripts/export-diagrams.sh
```

It writes SVG to `website/static/images/diagrams/`, writes the one PNG GitHub still needs, and
fails if any export exceeds the 500 KB budget. Run it after editing any source — the exports are
committed, so a source change without a re-run ships a stale picture.

## Sources

| Source | Where it is published |
|--------|-----------------------|
| `platform-overview.drawio` | The whole platform on one page. Site landing page, [Concepts → Architecture](../../website/content/docs/concepts/architecture.md), and the root [`README.md`](../../README.md) |
| `bootstrap-stages.drawio` | The five OpenTofu stacks in Terramate's order, and the two-stage CNI swap. [Platform → Foundations](../../website/content/docs/platform/foundations/_index.md) |
| `flux-dependency-tree.drawio` | Every Flux Kustomization and its `dependsOn` edges. [Platform → GitOps](../../website/content/docs/platform/gitops/_index.md) |
| `ci-pipeline.drawio` | What gates a merge, and the three consumers of `main` afterwards. [Reference → CI Workflows](../../website/content/docs/reference/ci-workflows.md), [Platform → GitOps → Validation](../../website/content/docs/platform/gitops/validation.md) |
| `request-path.drawio` | Three front doors onto one Envoy fleet. [Platform → Networking](../../website/content/docs/platform/networking/_index.md) |
| `secrets-and-pki.drawio` | The private CA chain and the two secret paths. [Platform → Security](../../website/content/docs/platform/security/_index.md) |
| `authentication-chain.drawio` | ZITADEL brokering one Google Workspace directory into every client's token, and where EKS and GKE diverge at the Kubernetes API. [Platform → Security → Authentication](../../website/content/docs/platform/security/authentication.md) |
| `app-claim-expansion.drawio` | One `App` claim becoming a whole application. [Platform → Developer Platform](../../website/content/docs/platform/developer-platform/_index.md) |
| `observability-flow.drawio` | Metrics, logs, traces and the alerting path. [Platform → Observability](../../website/content/docs/platform/observability/_index.md) |
| `openbao-architecture.drawio` | The whole OpenBao design on one page — both clouds, the seal key, snapshots and their mirror, the PKI, and where the bootstrap secrets live. Deliberately sparse; the detail lives in prose. [Platform → Security → OpenBao Architecture](../../website/content/docs/platform/security/openbao-architecture.md) |
| `openbao-lineage.drawio` | Two pages, embedded on two different pages. Page 1, what persists across a teardown versus what is rebuilt: [Platform → Security → OpenBao](../../website/content/docs/platform/security/openbao.md). Page 2, the cross-cloud fallback and the weekly restore drill: [Guides → OpenBao cross-cloud failover](../../website/content/docs/guides/openbao-cross-cloud-failover.md) |
| `llm-platform.drawio` | Three pages — request path, one claim rendered, autoscaling and telemetry. [Platform → AI Platform](../../website/content/docs/platform/ai-platform/_index.md) |

## SVG for the site, PNG only where GitHub needs it

The site gets SVG: it scales, it stays sharp when the reader clicks to zoom, and it is a fraction
of the size of an equivalent PNG.

The old PNG-only rule was never about quality — it was a GitHub constraint. drawio puts every
label inside a `<foreignObject>`, and GitHub's Markdown sanitizer strips those, so a drawio SVG
embedded in a `README.md` renders as a diagram with no text at all. That applies to files GitHub
renders, and only to those: `platform-overview` is embedded in the root README, so it is the one
source exported to PNG as well.

Two export flags carry more weight than they look:

- `--embed-svg-fonts false` — drawio embeds the full font as base64 by default. `platform-overview`
  exports at 1.29 MB with fonts and 152 KB without, and every logo in it together is only 64 KB.
  Nothing is lost: the ogenki preset sets a web-safe Helvetica stack that every browser resolves
  locally.
- `--page-index` is **1-based** in this CLI despite reading like an index. Looping `0 1 2` silently
  exports page 1 twice and drops page 3.

## Conventions

- One topic per file, kebab-case filename. Multi-page where a topic has genuinely distinct views.
- Style follows the **ogenki** drawio preset (`~/.drawio-skill/styles/ogenki.json`): indigo services,
  violet security, emerald storage, amber scaling, red failure modes, slate dashed for external or
  not-in-the-steady-state.
- Every box should be a real object — a resource, a module, a controller — **named as it is named in
  the manifests**. If a box is aspirational, or built but not deployed, mark it dashed and say so in
  its label. A diagram that shows a planned component as though it exists is worse than no diagram.
- Edge colours: slate = request flow, emerald = storage, amber = scaling decisions, red = removal or
  failure, dashed grey = optional or disabled.
- Each diagram carries its own legend. The semantic colours are shared verbatim with the site's
  `custom.css`, so a diagram and the prose beside it read as one system.

## Logos

Seventeen logos were rasterised for `platform-overview.drawio` and, for the life of the repo, were
reachable from no other file — which is most of why five of the ten single-page diagrams shipped
with no icons at all. They now live in [`icons/`](icons/) as real PNGs with a
[`manifest.json`](icons/manifest.json), so a diagram references one asset instead of re-fetching and
re-rasterising its own.

**Resolve an icon before writing a box.** Stop at the first hit:

| # | Source | How |
|---|--------|-----|
| 1 | `icons/` | `./scripts/diagram-icons.py style <name>` — paste-ready, ogenki palette applied |
| 2 | mxgraph stencil | `shapesearch.py "<terms>"` to find it, then **rasterise it into `icons/`** — see below |
| 3 | [CNCF Artwork](https://github.com/cncf/artwork) | **list** `projects/<slug>/icon/color/` and pick the SVG — `external-secrets-operator` ships `eso-icon-color.svg`, so filenames are not slugs |
| 4 | Project brand | `aiicons.py "<brand>" --embed` |
| 5 | none | a clean ogenki box — the honest fallback, only after 1–4 miss |

`./scripts/diagram-icons.py audit` lists every box that names a product and renders without one,
grouped by which source would supply it. It is advisory, not a CI gate: whether a box wants a logo
is a judgment call, and a gate that can go red on a judgment call gets switched off.

**Two traps, both silent:**

- **Rasterize SVG → PNG before embedding.** Headless drawio export does not render SVG `data:`
  URIs — the diagram looks right in the desktop app and exports with an empty box.
  `rsvg-convert -w 64 -h 64` works.
- **`image=data:image/png,<base64>` — a comma, not `;base64,`.** The semicolon terminates the
  drawio style value, dropping the image *and* every property after it.

**Icon the box's subject, never a product its body text mentions in passing** — a box titled *Leaf
certificates* gets no OpenTofu logo because its second line says "OpenTofu-managed". Concept boxes
(*the CNI swap*) and container frames stay plain: a logo there labels the wrong thing.

Some boxes are **deliberately** plain, and re-adding an icon to one is a regression:

| Box | Why it stays plain |
|---|---|
| `bootstrap-stages` stack column | the subject is the OpenTofu stack path, and iconing part of a uniform column reads as noise |
| `bootstrap-stages` `s4` `s5` `i0` | each names both clouds — one cloud's logo asserts something false |
| `ci-pipeline` `j1`–`j6` | a uniform column of CI jobs |
| container frames | `dp`, `pipe`, `fluxfam`, `ns` — a logo labels the grouping, not a thing |
| `llm-platform` `vm` | `shape=cylinder3`; `shape=label` would destroy the datastore shape |
| `openbao-lineage` `c4` `p1` `p3` | an annotation sentence, the KMS key, and an IAM role |

### Rasterising an mxgraph stencil

A stencil cannot be layered onto an ogenki box: `shape=` **replaces** the box shape, so the
alternative would be a floating icon cell per box, carrying absolute coordinates that do not follow
the box when it moves. Rasterise it into the library instead, where it behaves like every other
logo. The eight cloud icons here were made this way.

```bash
# AWS — mxgraph.aws4.resourceIcon, drawn by drawio, so it exports through drawio
cat > /tmp/i.drawio <<'EOF'
<mxfile><diagram name="i" id="i"><mxGraphModel><root>
<mxCell id="0"/><mxCell id="1" parent="0"/>
<mxCell id="s" value="" style="sketch=0;html=1;aspect=fixed;shape=mxgraph.aws4.resourceIcon;resIcon=mxgraph.aws4.s3;fillColor=#7AA116;strokeColor=#ffffff;" vertex="1" parent="1">
<mxGeometry x="0" y="0" width="128" height="128" as="geometry"/></mxCell>
</root></mxGraphModel></diagram></mxfile>
EOF
drawio -x -f png -t -b 0 --width 64 -o docs/architecture/icons/s3.png /tmp/i.drawio

# Google — the gcp2 shapes already carry an SVG data URI; decode and convert
#   shapesearch.py "gcp cloud storage bucket"  ->  take the image=data:image/svg+xml,<b64>
#   base64 -d, then: rsvg-convert -w 64 -h 64 -o docs/architecture/icons/gcs.png in.svg
```

**Check a new icon at 24px, not on the contact sheet.** The sheet renders at 110px, where
everything looks fine. Gateway API's logo is genuine and measurably distinct — the Kubernetes wheel
with routing arrows, 12.7% of pixels — but at the size these render, the arrows vanish and it *is*
the Kubernetes wheel, already used here for other things. Fetched, compared at render size, dropped.

**`aiicons.py` confidently returns the wrong product outside its scope.** It covers AI/LLM brands.
Asked for `vector` it returns *vectorizerai*; for `gateway api`, *cometapi*. Use `simple-icons` or
the project's own repo for anything else — and verify by eye regardless.

**`none` is a real answer.** Vector, Valkey, Karpenter and Alertmanager have no mark at any source
probed. The catalog records them as `none` so nobody repeats the search.

**Not everything is a CNCF project.** Valkey is Linux Foundation, Gateway API is a Kubernetes SIG
rather than a project, and Alertmanager belongs to Prometheus — none has an artwork entry. OpenTofu
*is* there despite being an LF project. Probe, don't reason.

**An icon must not assert something false.** Alertmanager keeps no Prometheus mark: this platform's
observability runs on VictoriaMetrics, and a Prometheus flame in that diagram reads as "Prometheus is
deployed". The icon was fetched, judged, and deleted rather than left to rot in the library.

**Look at what comes out.** The exact-name match for "Cloud Storage" is a generic server rack from
the clip-art library, not the GCS bucket; the right one is unnamed in the results. Rendering the
candidates side by side is the only way to tell.

Adding one: rasterise to PNG, drop it in `icons/`, add its `manifest.json` entry — and **look at
the image before you name it**. Two of the seventeen were mislabelled by the extraction, which
inherited `platform-overview`'s cell names rather than checking: `karpenter-keda` was only the KEDA
mark (there is no Karpenter logo here), and `eks` was the plain Kubernetes wheel. Both are now named
for what they are, and EKS falls back to its `mxgraph.aws4` stencil.

Check `aliases` too — `victorialogs` and `victoriatraces` alias the VictoriaMetrics mark today,
because `platform-overview` used one logo for all three and the extracted files were byte-identical.
Replacing them with the real upstream marks means two files added and two alias entries deleted.

The authoring procedure agents follow is [`.claude/rules/diagrams.md`](../../.claude/rules/diagrams.md),
which exists because the drawio skill's own preset-application steps cover colour, shape, edges and
fonts but have no icon step at all.
