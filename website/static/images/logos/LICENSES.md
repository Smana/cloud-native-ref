# Project logos — sources and terms

Every file in this directory is a third-party trademark, used here to identify
the software this platform runs. That is **nominative use**: naming a product to
refer to that product, which every source below permits. None of these marks
implies endorsement of this repository by its project, and none of them is
modified beyond the two mechanical changes noted at the end.

Consumed by `website/layouts/_shortcodes/stack-table.html` and
`stack-strip.html`, keyed by the `logo:` field in `website/data/stack.yaml`.
A component with no entry here renders a typographic tile instead — a missing
logo is a supported state, never a build failure.

## CNCF Artwork

Fetched from [`cncf/artwork`](https://github.com/cncf/artwork), whose
[trademark guidelines](https://www.linuxfoundation.org/legal/trademark-usage)
permit unmodified use to refer to the project. Path pattern:
`projects/<project>/icon/color/<project>-icon-color.svg`.

`cert-manager` · `cilium` · `cloudnativepg` · `crossplane` · `envoy` ·
`external-secrets` (published as `eso-icon-color.svg` under
`external-secrets-operator`) · `flux` · `harbor` · `headlamp` · `helm` ·
`helm-dark` (`icon/white`) · `keda` · `kubernetes` · `kyverno` · `opentofu`

## Project repositories

| File | Source | Terms |
|---|---|---|
| `dagger.svg` | `dagger/dagger` — `docs/static/img/favicon.svg` | Apache-2.0 project; brand assets for nominative use |
| `go.svg` | `golang/website` — `_content/images/go-logo-blue.svg` | [Go brand guidelines](https://go.dev/brand) — unmodified use permitted |
| `grafana.svg` | `grafana/grafana` — `public/img/grafana_icon.svg` | [Grafana Labs trademark policy](https://grafana.com/legal/trademark-policy/) |
| `hugo.svg` | `gohugoio/hugoDocs` — `static/images/hugo-logo-wide.svg` | Apache-2.0 project |
| `karpenter.svg` | `aws/karpenter-provider-aws` — `website/static/favicon.svg` | Apache-2.0 project |
| `openbao.svg` / `openbao-dark.svg` | `openbao/openbao` — `website/public/img/logo-black.svg` and `logo-white.svg` | Linux Foundation project |
| `tailscale.svg` | `tailscale/tailscale` — `client/web/src/assets/icons/tailscale-icon.svg` | [Tailscale brand](https://tailscale.com/press) — nominative use |
| `trivy.svg` / `trivy-dark.svg` | `aquasecurity/trivy` — `docs/imgs/logo-horizontal.svg` and `logo-white.svg` | Apache-2.0 project |
| `zitadel.svg` | `zitadel/zitadel` — `console/src/assets/images/zitadel-logo-solo-light.svg` | Apache-2.0 project |

## Simple Icons

[simple-icons](https://github.com/simple-icons/simple-icons) is **CC0-1.0**;
the underlying marks remain their owners' trademarks, used nominatively.

`github-actions` (`githubactions`) · `nodejs` (`nodedotjs`) ·
`victoriametrics` · `vllm`

## Modifications

Two mechanical changes, no redrawing:

1. **Simple Icons files are given a `fill`.** They ship as single-path glyphs
   with no fill, which renders black — invisible on the dark theme. Each is
   stamped with its brand hex on the `<svg>` root: VictoriaMetrics `#621773`,
   Node.js `#5FA04E`, GitHub Actions `#2088FF`, vLLM `#30A2FF`.
2. **A trailing newline** is added, because pre-commit's `end-of-file-fixer`
   requires one.

## Deliberately absent

These render as typographic tiles rather than borrowing another project's mark:

- **Terramate** — simple-icons has no entry, and Terraform's mark is *not* a
  substitute. This repository uses OpenTofu specifically; showing HashiCorp's
  logo next to Terramate would misstate both.
- **Kustomize, Gateway API, ExternalDNS, metrics-server** — all Kubernetes SIG
  projects with no distinct mark. Reusing the Kubernetes wheel for four
  different rows produces four identical icons carrying no information.
- **AWS** — service marks (Route 53, ELB, IAM, KMS, S3) have the most
  restrictive usage terms of anything here, and the row is a list of managed
  APIs rather than of installed software.
- **Valkey, Atlas, golangci-lint, pre-commit, Homepage** — no SVG located at a
  canonical source.

## Refreshing

There is no automation. A mark changes rarely, and a rebrand that silently
replaced a logo would be worse than a stale one. Re-fetch by hand from the
source above, re-check both themes, and update this file.
