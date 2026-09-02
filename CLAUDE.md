# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Overview

This is a comprehensive cloud-native platform reference repository implementing GitOps practices with Kubernetes. The repository demonstrates production-ready configurations for building, managing, and maintaining a secure, scalable cloud-native platform using AWS EKS and GCP GKE.

## Infrastructure Architecture

The platform is deployed in three sequential stages:

1. **Network Layer** (`opentofu/aws/network/`): VPC, subnets, Route53, and Tailscale VPN
2. **Security Layer** (`opentofu/aws/openbao/`): OpenBao cluster for secrets management and PKI
3. **Kubernetes Layer** (`opentofu/aws/eks/init/` + `opentofu/aws/eks/configure/`): EKS cluster with Flux, Cilium, and Karpenter

### Key Components

- **OpenTofu**: Infrastructure as Code (Terraform alternative)
- **Terramate**: OpenTofu orchestration and stack management
- **Flux**: GitOps continuous delivery
- **Crossplane**: Infrastructure composition from Kubernetes
- **OpenBao**: Secrets management and private PKI
- **Cilium**: Advanced networking and security with eBPF
- **Gateway API**: Modern ingress and traffic routing
- **VictoriaMetrics**: High-performance observability stack

### EKS Bootstrap Architecture

Two-stage OpenTofu deployment: Stage 1 creates the EKS cluster with temporary CNI, Stage 2 replaces it with Cilium and installs Flux.

**Why two stages?** Helm provider needs cluster endpoint at plan time, so Stage 2 runs after the cluster exists.

**Deploy**: `cd opentofu && terramate script run deploy` — one command builds the
whole platform, EKS included. `cd opentofu/aws/eks/init && terramate script run deploy`
re-runs just this stack, e.g. after a failure.

**Key Files:**
- `opentofu/config.tm.hcl` - Cilium/Flux versions
- `opentofu/aws/eks/init/main.tf` - EKS module with bootstrap addons
- `opentofu/aws/eks/configure/main.tf` - Cilium and Flux helm_releases
- `opentofu/aws/eks/init/helm_values/cilium.yaml` - Cilium Helm values

**Cilium Prefix Delegation (ENABLED — WireGuard is load-bearing):**
Pods get IPs from the secondary CIDR (100.64.0.0/16) via prefix delegation, configured by the custom CNI ConfigMap in `opentofu/aws/eks/configure/cilium-cni-config.tf`. Cilium bug #43493 (still open) breaks the Gateway API L7 proxy on cross-node traffic in this mode: the BPF ipcache sets `hastunnel` incorrectly for remote pods under native routing. **The workaround is `encryption.type: wireguard`** — node-to-node tunnels bypass the faulty routing logic. Do not disable WireGuard, and do not swap it for ztunnel transparent encryption, while #43493 is open.

`cniVersion` in `cilium-cni-config.tf` must track the CNI standard version Cilium defaults to (1.20 moved it 0.3.1 → 1.0.0). Because we set `cni.configMap`, the chart default never applies — bump it manually on every Cilium minor upgrade.

**Pod Subnet Tagging (IMPORTANT):**
The pod subnets (100.64.x.x) must NOT have the `kubernetes.io/role/cni` tag. VPC-CNI uses this tag to discover subnets during Stage 1 bootstrap, which creates orphan ENIs when Cilium takes over in Stage 2. Only use `cilium.io/pod-subnet=true` for these subnets.

**IAM:** EBS CSI and Crossplane use EKS Pod Identity (`xplane-*` resource scope for Crossplane).

### Self-Hosted LLM Platform (opt-in)

Two independent gates govern the self-hosted LLM platform; both must be released for an end-to-end deploy:

| Layer | Gate | Default | Enable |
|---|---|---|---|
| AWS (S3 Files filesystem + IAM) | `opentofu/aws/llm-platform/` Terramate stack tagged `opt-in`, `$TM_LLM_PLATFORM_ENABLED` env-var guard in `workflows.tm.hcl` | skipped | `TM_LLM_PLATFORM_ENABLED=true terramate -C opentofu/aws/llm-platform script run deploy` |
| Kubernetes (vLLM router, NVIDIA plugin, GPU NodePool, LLM apps, LLM EPI) | `clusters/aws-0/llm-platform.yaml` umbrella Flux Kustomization with `spec.suspend: true` | skipped | `flux resume kustomization llm-platform -n flux-system` |

The umbrella Kustomization aggregates 8 children under `clusters/aws-0-llm-platform/` (kept a sibling of `clusters/aws-0/` to keep `flux-system`'s recursive sync from auto-applying the children and bypassing the umbrella suspend). See `clusters/aws-0-llm-platform/README.md` for child manifests + teardown procedure. The default `terramate script run deploy` from `opentofu/` and the default Flux reconciliation both leave the cluster LLM-free.

#### On `gcp-0` — one gate, six children, and **do not resume it yet**

`gcp-0` has the same platform with three differences, and one warning that matters more than the
differences:

- **One gate, not two.** There is no `opentofu/gcp/llm-platform/` stack: the weights bucket is a
  Crossplane claim, not a Terraform-managed filesystem. The only gate is
  `clusters/gcp-0/llm-platform.yaml` (`spec.suspend: true`).
- **Six children, not eight.** No `gpu-nodepools` — `infrastructure/gcp-0/computeclass/gpu-l4.yaml`
  already provisions g2 + L4 on spot. No `runtimeclass-nvidia` — that exists on AWS only because
  Bottlerocket's NVIDIA AMI crashloops the upstream device plugin; GKE manages GPU drivers itself.
- **Weights come from a GCS bucket over the Cloud Storage FUSE CSI driver**, not an S3 Files POSIX
  mount — see [ADR-0021](website/content/docs/decisions/0021-gcs-fuse-for-model-weights-on-gcp.md)
  for why, including what it gives up.

> **Both known blockers are closed; the umbrella stays suspended on cost, not breakage.**
> Serving pods need a per-claim read-only identity because the FUSE mount authenticates as the
> mounting pod's own ServiceAccount. That identity **is** rendered by the `InferenceService`
> composition as of `crossplane-configuration` v0.4.6 — the version already pinned here — which
> emits a per-claim ServiceAccount, a Deployment running as it, and a `GCPWorkloadIdentity` granting
> `roles/storage.objectViewer` scoped to the weights bucket. No pin bump needed. (The second gap,
> KEDA on `gcp-0`, is also closed — `infrastructure/gcp-0` pulls the shared `base/keda`.)
> **But none of it has run on a live GKE cluster**: that is a static read of the pinned package's
> golden fixture, not a cluster result. Treat the first resume as a validation run — what to watch,
> in failure order, is in `clusters/gcp-0-llm-platform/README.md`.

**Autoscaling design** (composition v0.5.0+, [SPEC-001](docs/specs/done/2026-Q2/0001-llm-platform-prometheus-autoscaling/spec.md)): every model defaults `min=1` with a KEDA `ScaledObject` driven by leading vLLM saturation metrics — `running/max-num-seqs` ratio + `kv_cache_usage_perc`. The legacy KEDA HTTP add-on (proxy in the data path, lagging request-count trigger) is no longer used; AI Gateway routes directly to each vLLM Service.

**Experimental TUI client:** OpenCode (used occasionally; Claude Code stays primary). Setup design lives in the standalone [`Smana/opencode-config`](https://github.com/Smana/opencode-config) repo at `docs/2026-05-05-opencode-migration-design.md`.

## Common Commands

### Terramate / OpenTofu

```bash
terramate script run init       # Initialize all stacks
terramate script run preview    # Preview changes
terramate script run deploy     # Deploy platform
terramate script run drift detect  # Check drift

# The deploy above already includes EKS. To re-run just that stack:
cd opentofu/aws/eks/init && terramate script run deploy

# Feature branch testing
TF_VAR_flux_git_ref='refs/heads/my-branch' terramate script run deploy

# Individual stack
cd opentofu/<stack> && tofu plan -var-file=variables.tfvars
```

### EKS Cluster

```bash
aws eks update-kubeconfig --region eu-west-3 --name aws-0
flux get all
flux suspend kustomization --all
flux resume kustomization --all
```

### OpenBao

```bash
export VAULT_ADDR=https://bao.priv.aws.ogenki.io:8200
export VAULT_CACERT=opentofu/aws/openbao/management/.tls/ca.pem   # written by `openbao-config.sh ca`; prefer this over VAULT_SKIP_VERIFY
bao status

# Operator login is userpass in the root namespace, managed by
# opentofu/aws/openbao/management (auth.tf). It carries both the admin and
# pki-admin policies.
bao login -method=userpass username=admin

# The password is generated by the management stack and published here:
aws secretsmanager get-secret-value \
  --secret-id openbao/cloud-native-ref/users/admin \
  --query SecretString --output text | jq
```

> The backend and the user used to be created by hand. Both are now in OpenTofu.

**Namespace layout**: shared platform services — the PKI (`pki_private_issuer`), the
per-cluster JWT auth mounts, operator logins — live in the **root** namespace. Namespaces are
reserved for tenants; `app` is the only one, holding a `secret/` kv-v2 mount reachable
via its own AppRole. Cluster-wide endpoints such as `sys/storage/raft/*` are callable
*only* from root, which is why anything operational belongs there.
OpenBao's storage is rebuilt from its newest snapshot on every deploy (the *lineage*, ADR-0032): the lineage and management stacks are never destroyed by the default `destroy` (`TM_LINEAGE_DESTROY=true` overrides), machine auth is the JWT method on `jwt/<cluster>`, and consumers reach it at `openbao.security.svc.cluster.local:8200`. See
`opentofu/aws/openbao/management/namespaces.tf`.

## Development Workflow

### Prerequisites

- [mise](https://mise.jdx.dev/) - Polyglot tool version manager (manages OpenTofu, Terramate, Trivy, pre-commit)
- AWS CLI configured with appropriate permissions
- Helm CLI (v3.12+), kubectl, bao CLI, jq
- Tailscale account and API key
- **GCP only:** three hand-created prerequisites — state bucket, Cloud KMS key ring, Tailscale OAuth client. See [`docs/gcp-bootstrap.md`](docs/gcp-bootstrap.md).

**Tool versions managed via `mise.toml`**. Run `mise install` to install all required tools.

### Configuration Files

- `mise.toml`: Tool versions
- `opentofu/config.tm.hcl`: Global Terramate config (Cilium/Flux versions)
- `opentofu/workflows.tm.hcl`: Terramate scripts and workflows
- `opentofu/aws/eks/init/workflows.tm.hcl`: EKS two-stage deployment scripts

### GitOps with Flux

Flux manages all Kubernetes resources through a dependency hierarchy, broadly:

1. **Namespaces** -> **CRDs** -> **Crossplane** -> **EKS Pod Identities**
2. **Security** (External Secrets, Cert-Manager, Kyverno)
3. **Infrastructure** (Cilium, DNS, Load Balancers)
4. **Observability** (VictoriaMetrics, Grafana)
5. **Applications** (Harbor, Headlamp, etc.)

> **Simplified model — do not copy a `dependsOn` from it.** The real graph is
> wider than this chain: Crossplane is three sequential Kustomizations, Karpenter
> sits outside them, `infrastructure` depends on `karpenter` + `eks-pod-identities`
> rather than on `security`, and several `flux/*` Kustomizations run in parallel.
> Read `clusters/aws-0/` — or the derived graph at
> [Platform → GitOps](https://cnref.ogenki.io/docs/platform/gitops/) — before
> wiring a new component.

### Crossplane Resources

- **XRDs and Compositions live in [`Smana/crossplane-configuration`](https://github.com/Smana/crossplane-configuration)**, not here. This repo installs them as a Crossplane Configuration package — see `infrastructure/base/crossplane/configuration-aws/configuration-packages.yaml` for the pinned version. Edit the KCL, run the validators and cut a release **in that repo**; then bump the pin here.
- **App Composition**: Platform abstraction supporting progressive complexity (image-only to production-ready with managed PostgreSQL, Redis/Valkey, S3, autoscaling, HA, zero-trust networking)
- **EPI (EKS Pod Identity)**: IAM roles for service accounts in `security/base/epis/`
- **Resource naming**: All Crossplane-managed resources prefixed with `xplane-`
- **Still owned here**: `functions.yaml` (version-pinned rather than resolved by the packages' `dependsOn`), `environmentconfig.yaml`, and the provider config.

> The claim-side rules that still apply in this repo are in `.claude/rules/crossplane-validation.md`.

## Development Workflow (Superpowers)

Non-trivial changes go through the [Superpowers](https://github.com/obra/superpowers) plugin,
declared in `.claude/settings.json`. Its skills auto-trigger — there are no repo-specific slash
commands to remember for the core flow.

```
superpowers:brainstorming        -> docs/superpowers/specs/YYYY-MM-DD-<topic>-design.md
  superpowers:writing-plans      -> docs/superpowers/plans/YYYY-MM-DD-<topic>-plan.md
    superpowers:subagent-driven-development (or executing-plans)
      /verify-spec               -> docs/superpowers/specs/YYYY-MM-DD-<topic>-verification.md
        /commit -> /create-pr
```

> **Always work in a git worktree.** Use the `EnterWorktree` tool at the start of any task that
> changes files — worktrees land in the gitignored `.claude/worktrees/` and branch from
> `origin/main`, so concurrent sessions never share a working directory or inherit each other's
> `HEAD`. Details in [`.claude/rules/superpowers.md`](.claude/rules/superpowers.md).

**Key documents**:
- [Platform Constitution](docs/platform-constitution.md) — non-negotiable principles (auto-loaded via `.claude/rules/platform-constitution.md`)
- [Architecture Decision Records](website/content/docs/decisions/) — cross-cutting technology choices
- [Repo deltas](.claude/rules/superpowers.md) — artifact locations and the gate that applies at each phase
- [Spec archive](docs/specs/) — output of the in-house SDD workflow retired on 2026-08-18, read-only

### When a Design Is Required

| Change Type | Examples |
|-------------|----------|
| New Crossplane Composition | New KCL module, new XRD |
| Major Infrastructure | New OpenTofu stack, VPC changes, EKS upgrades |
| Security Changes | Network policies, RBAC, PKI, secrets |
| Platform Capabilities | Multi-component features, observability |
| New Technology | Any component or pattern chosen over a named alternative — needs an [ADR](website/content/docs/decisions/) before merge |

**A technology choice with a rejected alternative requires an ADR before merge.**
If you can name what it was chosen over, write the record. If nothing credible
competed, it is an installation and not a decision — say so in the pull request
rather than leaving it unsaid. Version bumps, chart-value changes and single-file
fixes never need one.

### When to Skip

Version bumps, documentation-only, single-file bug fixes, minor config changes, HelmRelease value tweaks.

### Repo-Specific Companions

Two skills cover ground the plugin does not. Both are optional.

| Skill | Description |
|-------|-------------|
| `/verify-spec <design-doc>` | Post-merge: verify a design's success criteria against the live cluster via the Flux and VictoriaMetrics/VictoriaLogs MCPs, write `<topic>-verification.md` |
| `/spec-research <slug> "<q>"` | Forked Explore subagent: Context7 + repo scan -> writes `<date>-<slug>-research.md` without burning main context |

## Security Considerations

### OpenBao PKI Structure

- **Offline** root CA -> intermediate CA -> leaf certificates. The root signed each
  cloud's intermediate offline, once; only the intermediate's cert+key bundle is
  imported into the `pki` mount, and that intermediate **is** the issuer. OpenBao
  never holds the root key — the `root-ca` Secrets Manager entry that used to
  carry it is deleted. One root for both clouds, so a tailnet client trusts one
  anchor. See `opentofu/aws/openbao/management/pki.tf`.
- cert-manager authenticates with a **projected ServiceAccount token** against the
  per-cluster JWT mount (`jwt/<cluster>`, role `cert-manager`) — not an AppRole,
  and no long-lived credential anywhere. It needs the `create` grant on
  `serviceaccounts/token` for itself to mint that token:
  `security/base/cert-manager-token-creator/rbac.yaml`.
- Automatic certificate rotation

### IAM and Permissions

- Least privilege principle enforced
- EKS Pod Identity for service account authentication
- Crossplane controllers limited to `xplane-*` prefixed resources
- No deletion permissions for stateful services (S3, IAM, Route53)

### Network Security

- Private EKS API endpoint
- Tailscale VPN for secure access to private resources
- Cilium Network Policies for pod-to-pod communication
- Gateway API for ingress with TLS termination

### Tailscale Gateway API Integration

Private services exposed via Tailscale using Gateway API with custom domains (`*.priv.aws.ogenki.io`). Two separate Gateways enforce ACL-based access control:

- **General Gateway** (`tag:k8s`): All Tailscale members. Services: Harbor, Headlamp, Homepage, Grafana, VictoriaMetrics.
- **Admin Gateway** (`tag:admin`): `group:admin` only. Services: Hubble UI. (VictoriaLogs is on the *general* gateway — both its HTTPRoutes name `platform-tailscale-general`. Grafana OnCall was removed on 2026-08-29 — see ADR-0029; RunLore + Slack carry the incident flow.)

Both use `loadBalancerClass: tailscale` via CiliumGatewayClassConfig. ExternalDNS watches HTTPRoutes to create Route53 records. See [Platform → Networking → Private access](https://cnref.ogenki.io/docs/platform/networking/private-access/) for setup details.

## Key File Locations

### Infrastructure
- OpenTofu stacks: `opentofu/{network,eks/init,eks/configure,openbao}`
- Kubernetes manifests: `{infrastructure,security,observability,tooling}/base/`
- Cluster-specific overrides: `{infrastructure,security,observability,tooling}/aws-0/`

### GitOps
- Flux configuration: `flux/`
- Custom Resource Definitions: `crds/base/`
- Cluster bootstrap: `clusters/aws-0/`

### Scripts
- EKS cleanup: `scripts/eks-prepare-destroy.sh`
- OpenBao config: `scripts/openbao-config.sh`
- KCL/composition validation: `task check` in [`Smana/crossplane-configuration`](https://github.com/Smana/crossplane-configuration) (moved with the compositions)

## Troubleshooting

Use the FluxCD agent-skills plugin for Flux troubleshooting (`/gitops-cluster-debug`, `/gitops-knowledge`, `/gitops-repo-audit`). Use `.claude/config` for Crossplane troubleshooting and platform-specific guidelines.

### Common Issues
- **EKS Access**: Ensure proper IAM permissions and kubeconfig
- **Flux Sync**: Verify GitHub App credentials in AWS Secrets Manager
- **Certificates**: Check OpenBao CA chain and cert-manager logs
- **Network**: Confirm Tailscale subnet router connectivity
- **Resource Conflicts**: Review Crossplane composition functions and resource references
- **Gateways stuck `Waiting for controller`**: cilium-operator probes for the Gateway API CRDs
  **once, at startup**, and permanently disables its Gateway API controller if any are missing —
  no crash, no alert. Symptoms cascade: `GatewayClass ACCEPTED=Unknown`, Gateways unprogrammed,
  HTTPRoutes with no `status.parents`, and every `App` claim that owns a route stuck
  `READY=False`. Confirm with
  `kubectl logs -n kube-system -l io.cilium/app=operator | grep "Required GatewayAPI resources"`,
  then `kubectl rollout restart -n kube-system deployment/cilium-operator`. Both clouds install
  these CRDs from `opentofu/shared/modules/gateway-api-crds`, which applies the whole
  experimental-channel bundle keyed by `for_each` — so a CRD Cilium wants can no longer be missing
  from an enumeration. If a *newer Gateway API release* is the fix, bump the two pins together:
  `gateway_api_version` in `opentofu/config.tm.hcl`'s `globals` (one value, both clouds — it is
  passed by `-var` like `cilium_version`) and the `ref.tag` in
  `flux/sources/gitrepo-gateway-api.yaml`. `./scripts/validate-doc-claims.sh` fails when they
  disagree (claim `gateway-api-version`). Flux applies the full CRD directory too, but only
  *after* Cilium is already running.

> **VictoriaLogs and Grafana rules** are in `.claude/rules/observability.md` (loaded automatically when editing observability files).

> **Verification and debugging discipline** (evidence-before-completion gate, 4-phase root-cause method) is in `.claude/rules/process.md` (loaded automatically when editing spec/infra/security/observability/tooling/opentofu/clusters/flux files).

## Validation Commands

```bash
tofu validate
trivy config --exit-code=1 --ignorefile=./.trivyignore.yaml .
./scripts/validate-manifests.sh   # renders the repo, then gates it (see below)
./scripts/validate-links.sh       # resolves every relative Markdown link
./scripts/validate-doc-claims.sh  # docs still agree with config (.doc-claims.yaml)
kubectl get nodes && kubectl get pods --all-namespaces
flux get all
```

### Manifest validation (SPEC-007)

`./scripts/validate-manifests.sh` is the single entry point CI runs, and the one to cite as
evidence. It renders the repo the way Flux does — every Kustomize overlay (with `postBuild`
vars substituted) plus every HelmRelease rendered through `helm template` with its own values
and `postRenderers` — then applies two gates to the result:

| Gate | Tool | Catches |
|------|------|---------|
| 1 | `flux schema validate` | structure + CEL, against the repo's own XRDs, the Flux catalog, and the CNCF ecosystem catalog |
| 2 | `polaris audit` | workload best practices (privilege escalation, capabilities, image tags) |

**A third check runs separately, and catches what neither gate can:**
`scripts/flux-schema/check-substitution.py` reads the Flux Kustomizations under `clusters/` directly
and fails when one **applies a `${var}` its own cluster's ConfigMap does not define**. Flux
substitutes an **empty string** for an undefined variable — schema-valid, and silently wrong — so the
bundle looks perfect either way. It reads each cluster's real keys from the `flux_cluster_vars`
resource in `opentofu/*/configure/kubernetes.tf`.

It also fails when a Kustomization applies variables with no `postBuild` wired at all, where Flux
would apply the literal `${var}`. Covered by `scripts/flux-schema/test-check-substitution.py` — the
only test any script in `scripts/flux-schema/` has.

**A fourth check parses the alerting expressions, which nothing else ever did:**
`scripts/validate-vmrules.sh` extracts each repo-authored `VMRule`'s `.spec` — already the shape of
a Prometheus rules file — and runs `promtool check rules` over it. To `flux schema validate`, an
`expr` is just a string in the right place; polaris never looks at rules at all. So an unbalanced
paren, an unknown function or a malformed label matcher validated clean until now, and the cost
landed at runtime: vmalert logs a parse error, the group never evaluates, and **the alert silently
never fires**.

It reads **committed VMRules, not the bundle** — the bundle also holds VMRules shipped by upstream
Helm charts, which we neither author nor can fix, and which are entitled to use MetricsQL that
promtool rejects. A gate that can go red on something the repo cannot fix gets switched off. (All 22
VMRule documents in the rendered bundle pass promtool as of 2026-09-02, so this is about the first
chart bump that would not, not about present breakage.) The gap that leaves: rules written inline in
a HelmRelease `values:` block are repo-authored and are *not* seen — there are none today.

**It skips what it cannot check, and says so on every run.** A rule group's `type` field selects the
query language (`prometheus` — the default — plus `graphite` and `vlogs`), so the skip predicate is
read from the data rather than hardcoded to a filename: a group is checked when `type` is unset,
empty, or `prometheus`. Today that skips exactly one group, `loggen` in
`observability/base/loggen/demo-vmrule.yaml`, whose `type: vlogs` expressions are LogsQL against
VictoriaLogs — and which **must not be made to pass**. Every skipped group is named with its reason
in both a green and a red run, and the summary counts skipped groups separately, for the same reason
`Skipped: 0` is part of the claim below.

> **PromQL ⊂ MetricsQL, so this gate can in principle reject a valid expression.** Nothing in the
> repo relies on MetricsQL-only syntax today — verified by construction, since every checked
> expression passes a PromQL parser. When someone does hit it, the fix is *not* to delete the gate:
> rewrite in PromQL, or isolate the rule in its own group with a `type` the script skips so the hole
> is visible. The script's header spells this out at the point of failure.

> A `substituteFrom` entry may name a **Secret** as well as a ConfigMap. **None does today** — the
> last was `cert-manager-openbao-approle` supplying `${cert_manager_approle_id}`, removed when
> cert-manager moved to a projected ServiceAccount token. A Secret's keys are created in-cluster at
> runtime, so they cannot be checked here — those variables are **reported as a note** rather than
> failed, and rather than silently skipped.

Two properties are load-bearing:

- **`skipMissingSchemas: false`** (`.fluxschema.yml`) — an unknown Kind *fails the build*. It
  does not get skipped. The previous kubeconform setup ran with `-ignore-missing-schemas`, so
  every `cloud.ogenki.io` claim went unvalidated for the life of the repo.
- **Polaris audits rendered charts, not raw files.** The repo has 1 raw Deployment; the
  rendered bundle has 156 controllers (109 Deployment, 25 Job, 10 StatefulSet, 8 DaemonSet,
  4 CronJob). Pointing a best-practices gate at the source tree checks almost nothing.

The schema catalog (`.schemas/`) and the bundle (`.bundle/`) are generated on every run and are
gitignored — a committed catalog drifts from the XRDs it is derived from.

Requires `flux` ≥ 2.9 with the schema plugin: `mise install && flux plugin install schema`.
`promtool` comes from the `promtool = "3.14.0"` pin in `mise.toml` (mise resolves it to the
prometheus release archive, which is what promtool ships inside), so `mise install` covers it too.

- always check the network policies when there are timeouts
