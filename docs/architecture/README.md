# Architecture diagrams

Drawio (`.drawio`) files. Open with the [drawio desktop app](https://www.drawio.com/) or the
[VS Code "Draw.io Integration" extension](https://marketplace.visualstudio.com/items?itemName=hediet.vscode-drawio).

## Files

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
