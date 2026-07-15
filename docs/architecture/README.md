# Architecture diagrams

Drawio (`.drawio`) files. Open with the [drawio desktop app](https://www.drawio.com/) or the
[VS Code "Draw.io Integration" extension](https://marketplace.visualstudio.com/items?itemName=hediet.vscode-drawio).

## Files

- [`platform-overview.drawio`](platform-overview.drawio) — the whole platform on one page (AWS
  managed services → EKS tiers → applications & data). Embedded in the root [`README.md`](../../README.md).
  Uses official AWS icons (`mxgraph.aws4`) and CNCF/vendor logos embedded as PNG data-URIs
  (see "Logos" below). Regenerate the README preview after editing:

  ```bash
  drawio -x -f png -s 2 -b 10 -o docs/architecture/img/platform-overview.png docs/architecture/platform-overview.drawio
  ```

- [`llm-platform.drawio`](llm-platform.drawio) — self-hosted LLM platform on EKS. Three pages:
  1. **Request path** — client → Tailscale → AI Gateway → filter chain → vLLM.
  2. **One claim, rendered** — what a Crossplane `InferenceService` expands into, plus the weights flow.
  3. **Autoscaling & telemetry** — the three KEDA triggers, the two metric families, the dashboards.
- `img/llm-platform-{1,2,3}.png` — exported previews, embedded in [`docs/ai.md`](../ai.md). Regenerate
  after editing the source:

  ```bash
  for i in 1 2 3; do
    drawio -x -f png --width 1500 -b 10 --page-index $i \
      -o docs/architecture/img/llm-platform-$i.png docs/architecture/llm-platform.drawio
  done
  ```

  PNG rather than SVG on purpose: drawio's SVG export puts label text in `<foreignObject>`, which
  GitHub's sanitizer strips — the diagram would render without any text.

The narrative that goes with these diagrams — the request path, the fleet, autoscaling, observability,
security, and the known gaps — is in **[`docs/ai.md`](../ai.md)**. This file is an index, not a second
source of truth; keeping the prose in one place is what stops the two from drifting apart.

## Conventions

- One topic per file, kebab-case filename. Multi-page where a topic has distinct views.
- Style follows the **ogenki** drawio preset (`~/.drawio-skill/styles/ogenki.json`): indigo services,
  violet security, amber classification, emerald storage, red failure modes, slate dashed for external
  or opt-in-and-currently-off.
- Every box should be a real object in the cluster, named as it is named in the manifests. If a box is
  aspirational, mark it dashed and say so in its label — a diagram that shows a planned component as
  though it exists is worse than no diagram.
- Edge colors: slate = request flow, emerald = storage / weights, amber = scaling decisions, red =
  failure paths, dashed grey = optional or disabled.

## Logos

The ogenki preset supports icons/stencils on top of the clean-box style:

- **AWS** services use native draw.io stencils (`mxgraph.aws4.resourceIcon`).
- **Cloud-native / application** components use their real brand logos, embedded as **PNG
  data-URIs** so the `.drawio` stays self-contained (no remote refs to rot).
- Source the logos from the **[CNCF Artwork](https://github.com/cncf/artwork)** repo
  (`projects/<name>/icon/color/*.svg`) for CNCF projects, and each project's own brand for the
  rest. **Rasterize SVG → PNG before embedding** — headless draw.io export does not render SVG
  `data:` URIs (they show as a broken-image placeholder); `rsvg-convert -w 64 -h 64` works. Embed
  as `image=data:image/png,<base64>` (a comma, **not** `;base64,` — the semicolon terminates the
  draw.io style value early and the icon silently disappears).
- Components with no clean logo source (e.g. Gateway API, ExternalDNS, ZITADEL, External Secrets)
  stay clean ogenki boxes — a consistent, intentional fallback, not a gap to paper over.
