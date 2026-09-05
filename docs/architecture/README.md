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
| `openbao-lineage.drawio` | Two pages — what persists across a teardown versus what is rebuilt, then the cross-cloud fallback and the weekly restore drill. [Platform → Security → OpenBao](../../website/content/docs/platform/security/openbao.md) |
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

- **AWS** services use native drawio stencils (`mxgraph.aws4.resourceIcon`).
- **Cloud-native / application** components use their real brand logos, embedded as **PNG data-URIs**
  so the `.drawio` stays self-contained. Source them from the
  [CNCF Artwork](https://github.com/cncf/artwork) repo (`projects/<name>/icon/color/*.svg`) for CNCF
  projects, and each project's own brand otherwise.
- **Rasterize SVG → PNG before embedding** — headless drawio export does not render SVG `data:` URIs
  and shows a broken-image placeholder instead. `rsvg-convert -w 64 -h 64` works. Embed as
  `image=data:image/png,<base64>` — a **comma**, not `;base64,`, which terminates the drawio style
  value early and makes the icon silently disappear.
- Components with no clean logo source (Gateway API, ExternalDNS, ZITADEL, External Secrets) stay
  clean ogenki boxes — a consistent, intentional fallback, not a gap to paper over.
