# Validators — what each one catches, and what none of them can

Layout: [`README.md`](README.md). CI calls the entry point below as `task ci:validate`.

`./scripts/ci/validate-manifests.sh` is the single entry point CI runs and the one to cite as evidence. It
renders the repo the way Flux does — every Kustomize overlay with `postBuild` vars substituted,
plus every HelmRelease rendered through `helm template` with its own values and `postRenderers` —
then applies five gates to the result. Run `scripts/ci/ai-overlay.sh` (`task ai:overlay`) first:
the AI paths are gitignored, and only the pinned `ai-native-ref` artifact puts them in the tree.
The AI invariants (`assert-ai-gateway.py`, `assert-agent-gateway.py`) run in that repository.

| Gate | Tool | Catches |
|---|---|---|
| 1 | `flux schema validate` | structure + CEL, against the repo's own XRDs, the Flux catalog and the CNCF ecosystem catalog |
| 2 | `polaris audit` | workload best practices — privilege escalation, capabilities, image tags |
| 3 | `flux-schema/assert-cloud-shape.py` | gcp-0's agent and AI-gateway overlays carry no AWS-shaped value (an `amazonaws.com` or EKS host, a `certificates/` CA key, `platform-llm-api-keys`), their run-token issuer and JWKS are GKE's, and no gcp-0 umbrella child substitutes `gke-gcp-0-vars` into a path CI renders with AWS values. Positively: `ai-gateway-api-keys` is generated (`Password` generators, `CreatedOnce`, no store), `openbao-ca` reads `openbao-priv-gcp-ca-chain`, envoy-gateway renders the rate-limit `KVStore` while `llm-gateway` is deployed, no chart-rendered CNP reaches the metadata server via `toEntities: host`, and no pod off the host network in a gcp-0 or base render (only `-aws-0-` renders are skipped) tolerates Cilium's startup taint (`agentNotReadyTaintKey`) or every taint (F2). Each check fails, not passes, when its subject disappears: an expected overlay, a run-token issuer, an umbrella directory. Exists because the render fixtures were AWS-shaped for both clusters, so a GCP-only break rendered clean (GP-14) |
| 4 | `flux-schema/assert-zitadel-floor.py` | every rendered `ghcr.io/zitadel/zitadel` container runs a release ≥ v4.17.3 and no pre-release (the v4.18 pre-releases predate the fix): older ones let a user add an unverified IdP link and forge the GitHub identity room access reads (ADR-0056). Reads the rendered image, so it covers the `image.tag` override and the chart's appVersion alike; an unparseable tag, or no ZITADEL container at all, fails |
| 5 | `validate-alertmanager-templates.sh` | the Slack notification actually renders |

Two properties are load-bearing:

- **`skipMissingSchemas: false`** (`.fluxschema.yml`) — an unknown Kind **fails the build**. It is
  not skipped. The previous kubeconform setup ran with `-ignore-missing-schemas`, so every
  `cloud.ogenki.io` claim went unvalidated for the life of the repo.
- **Polaris audits rendered charts, not raw files.** The repo has 1 raw Deployment; the rendered
  bundle has 160 controllers. Pointing a best-practices gate at the source tree checks almost
  nothing.

`.schemas/` and `.bundle/` are generated on every run and gitignored — a committed catalog drifts
from the XRDs it derives from. **Concurrent runs in one checkout race on `.bundle/`** and produce
spurious `Invalid` results; a resource count that moves between runs is the tell.

Requires `flux` ≥ 2.9 with the schema plugin: `mise install && flux plugin install schema`.

## The checks that run separately, and why

**`flux-schema/check-substitution.py`** reads the Flux Kustomizations under `clusters/` directly
and fails on a `${var}` the cluster's ConfigMap does not define. Flux substitutes an empty string
there — schema-valid and silently wrong — so the bundle looks perfect either way. Details in
`clusters/AGENTS.md`.

Its two tests are `tests/flux-schema/test-check-substitution.py` and
`tests/flux-schema/test-render-bundle.py`. The second pins `render-bundle.py`'s `spec.valuesFrom`
resolution: six HelmReleases get most of their values that way, and a regression there does not
break the build — it quietly shrinks what the build checks.

Both run inside `task ci:test`, alongside the other suites, because they test the scripts that do
the rendering. They are deliberately not folded into `validate-manifests.sh`, whose contract is
manifest validation. Run them directly: `python3 scripts/ci/tests/flux-schema/<file>`.

**`flux-schema/check-ai-boundary.py`** **reads source `*.yaml` under `clusters/`, `infrastructure/`,
`security/`, `observability/`, `tooling/`, `apps/`, `flux/`, `namespaces/` and `crds/`, not the
rendered bundle**, and fails on a reference across the host/AI boundary that the host contract does
not list (ADR-0057; design §1 and §2): kustomize file references, Flux `spec.path`, `dependsOn`,
`sourceRef` and `substituteFrom`, HelmRelease `valuesFrom` (H8's ConfigMap must carry `optional:
true`), and `${var}` in AI files. Its data, `flux-schema/ai-boundary.yaml`, is the move list S2
hands to `git filter-repo`: a path added there is a path that moves, and a change there is a
host-contract change. A move-list entry matching no file fails too. It runs in step 1 of
`validate-manifests.sh`; its suite, `tests/flux-schema/test-check-ai-boundary.py`, plants a crossing
each way in a copy of the tree.
Blind spots: a reference in a script, a doc, a CiliumNetworkPolicy selector, Helm values text,
`.policy.yml`, `.github/`, `website/` or `container-images/` goes unseen. So does a host Flux
Kustomization whose path has no `kustomization.yaml` and therefore applies every YAML under it
(today `flux-sources` → `flux/sources/`, known, design §1); a new case is not flagged.

**`validate-vmrules.sh`** parses alerting expressions, which nothing else ever did. It reads
committed VMRules rather than the bundle, because the bundle also holds VMRules shipped by upstream
charts that we neither author nor can fix, and which are entitled to MetricsQL that promtool
rejects. **A gate that can go red on something the repo cannot fix gets switched off.** See
`observability/AGENTS.md`.

**`validate-alertmanager-templates.sh`** pulls the rendered Alertmanager config and template
ConfigMap out of `.bundle/` — **every copy, not the first found**, since the chart renders once per
cluster. It checks each config with `amtool check-config`, renders every templated string in the
Slack receiver against five fixture payloads with `amtool template render` and golden-compares, and
asserts every `VMAlert` carries an **absolute** `external.url`.

That last assertion is not theoretical. vmalert shipped with `external.url: "http://"`, so every
`generatorURL` was `http:/explore?…` with no host, and Slack silently drops an attachment action
whose URL is invalid — the Query button never rendered on any alert on either cluster. It sat in
the bundle the whole time and no gate could fail on it: `flux schema validate` sees a valid string
and Polaris never reads `extraArgs`.

Both URL args are now set **explicitly** in `vm-common-helm-values-configmap.yaml`, so the Query
button lands in **vmui** with the alert's expression pre-filled rather than in Grafana Explore —
the Dashboard button is already the Grafana link, and two of those on one message is one too many.
The chart only fills these when absent, so an explicit value wins.

> **Escaping trap.** The chart pipes the whole vmalert spec through Helm's `tpl`
> (`_helpers.tpl:291`), so `{{.Expr|queryEscape}}` must be written `{{ "{{" }}…{{ "}}" }}` — or
> Helm evaluates it, finds no `queryEscape` function, and the render dies with a bare "invalid YAML".

It validates **structure, not semantics**. A typo'd `equal` label (`clustre`) is a syntactically
valid label name and passes; so does a shadowing route or an over-broad inhibit rule. Changing
wording means `--update-golden`, then reading the diff — it *is* the Slack message.

**`test-ci-notify-main-broken.sh`** is the only thing that exercises the `notify-main-broken` job
while the repository is healthy. That job runs `if: failure() && github.event_name == 'push'`, so
its first run that matters is also its first run ever — and it shipped broken: no checkout step, so
every `gh` call died with `fatal: not a git repository` and a red `main` went unreported.

The suite takes the step's **`env:` from the workflow**, not from itself, and that is the whole
design. Two earlier versions exported `GH_REPO` themselves and asserted only the branch logic
(open an issue vs comment on the open one) — both passed against a workflow that supplied no
`GH_REPO` at all, which is the same "tested the logic, not the invocation context" gap as the
defect they were meant to catch. **Deleting the `GH_REPO` line from `ci.yaml` must fail this
suite**; if a change stops that being true, it has regressed to testing nothing. It runs under
`task ci:test`, and says SKIP (exit 77) without pyyaml.

## The rest

| Script | Checks |
|---|---|
| `validate-links.sh` | every relative Markdown link resolves. Run after **any** file move |
| `verify-doc-paths.sh` | every **backticked** repository path in `website/content/` still exists. Runs in the website workflow, not in `validate-manifests.sh`, and catches what `validate-links.sh` cannot: a path in prose, or one linked by absolute GitHub URL. No allowlist by design — fix the path or drop the reference |
| `validate-doc-claims.sh` | docs still agree with config, per `.doc-claims.yaml` |
| `validate-idp-topology.sh` | exactly one cloud hosts ZITADEL (ADR-0027) |
| `provision/openbao-oidc-check.sh` | OpenBao's `auth/oidc` config agrees with the secret store and that ZITADEL still knows the client (#2045); the `stage5-verify-openbao-oidc` deploy job halts on exit 1, and treats exit 2 ("cannot tell") as a halt too. The management stack's `drift detect` runs it as well, since its plan ignores the rotated fields: exit 1 there is reported as drift and the walk continues (#2084) |
| `ci/tests/test-terramate-script-refs.sh` | every script path on an **executed** `.tf`/`.tm.hcl`/`.tfvars` line is resolved or fails loudly — the apply- and destroy-time calls no CI job runs. Comments are skipped; `echo` hints are not |
| `docs/diagram-icons.py audit` | boxes naming a product that render without an icon. Advisory, never a CI gate |
| `docs/export-diagrams.sh` | regenerates every SVG the site embeds. Pins the drawio version on purpose |
| `ops/aws/eks-prepare-destroy.sh` | **deletes every PVC.** Must carry a cloud gate |
| `provision/tm-provisioner.sh` | the `TM_CLOUD` lane enforcement every stack routes through |

**`validate-idp-topology.sh` only checks the repo.** It cannot see whether the committed
`zitadel_project_id` is the live directory's: a restored directory keeps the seed's id, an empty
bootstrap gets a new one, which the sync publishes through Secret Manager `zitadel-project-id`.

**EKS teardown leaks CSI EBS volumes.** Sweep `status=available` volumes after a rebuild; the
proper fix belongs in `eks-prepare-destroy.sh`.
