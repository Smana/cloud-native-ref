# OpenTofu / Terramate

15 stacks today. `cd opentofu && terramate list` is the source of truth, not this list:

```
aws/{network,eks/init,eks/configure,openbao/cluster,openbao/lineage,openbao/management,llm-platform}
gcp/{network,gke/init,gke/configure,openbao/cluster,openbao/lineage,openbao/management}
shared/{tailscale,aws-gcp-federation}
```

```bash
terramate script run init | preview | deploy       # all stacks
terramate script run drift detect
cd opentofu/<stack> && tofu plan -var-file=variables.tfvars   # one stack, directly
```

Validate with `tofu validate` and
`trivy config --exit-code=1 --ignorefile=./.trivyignore.yaml .`

## Choosing the cloud — `TM_CLOUD`

One variable, a comma list, defaulting to `aws`. A third cloud needs no new keyword.

```bash
terramate script run deploy                    # aws alone (the default)
TM_CLOUD=gcp     terramate script run deploy   # gcp alone; AWS stacks echo [skip]
TM_CLOUD=aws,gcp terramate script run deploy
TM_CLOUD=all     terramate script run deploy
```

A stack's lane is its directory. `opentofu/shared/**` is owned by neither cloud and always runs.
Enforced in `scripts/provision/tm-provisioner.sh`, which `global.provisioner` points at, so it wraps every
`tofu` call in the shared scripts *and* every per-stack override at once. Jobs that run something
other than tofu carry `${global.cloud_gate}` or `--tm-run`; the destructive ones must, since
`eks-prepare-destroy.sh` deletes every PVC.

**Why not tags.** A tag filter has no committed default — `--no-tags` has to be typed, so a fresh
clone or CI would get all 15 stacks, and `drift reconcile` runs `tofu apply -auto-approve`. Tags
remain right for *listing* (`terramate list --tags=gcp`), never for gating.

## The other six `TM_*` gates

`TM_CLOUD` is one of **seven** environment variables that decide what a run may do. The others are
`TM_LLM_PLATFORM_ENABLED`, `TM_DESTROY_CONFIRMED`, `TM_LINEAGE_DESTROY`,
`TM_OPENBAO_SKIP_SNAPSHOT`, `TM_TAILNET_DESTROY` and `TM_FEDERATION_DESTROY`.

The authoritative table — polarity, default-when-unset, and what each gates — is
[§ Environment gates in the Commands reference](../website/content/docs/reference/commands.md).
It is deliberately not restated here: two copies of a safety table is how one of them goes stale,
and an operator who cannot find `TM_LINEAGE_DESTROY` cannot destroy that stack at all.

**The polarity is not uniform.** Five of the six authorise an action when set to `true`;
`TM_OPENBAO_SKIP_SNAPSHOT` *removes* the pre-destroy snapshot when `true`. A new gate follows the
majority shape — `=true` authorises — and goes into that table in the same commit.

## Opt-in stacks

Stacks tagged `opt-in` (currently `llm-platform`) no-op unless an env var enables them. Their
scripts are overridden in their own `workflows.tm.hcl`.

```bash
TM_LLM_PLATFORM_ENABLED=true terramate script run deploy
terramate script run --no-tags=opt-in deploy   # CI / audit path
```

Trade-off: opt-in scripts use a single bash heredoc and lose Terramate Cloud sync metadata
(`sync_deployment` / `sync_preview`). Acceptable for branch-local stacks. The Kubernetes half of
the same gate is in `clusters/AGENTS.md` — **both** must be released for an end-to-end deploy.

## EKS two-stage bootstrap

Helm needs the cluster endpoint at plan time, so the cluster must exist before Cilium and Flux can
be installed.

| Stage | Directory | Does |
|---|---|---|
| 1 | `aws/eks/init` | EKS cluster, managed node groups, bootstrap addons (vpc-cni, kube-proxy, coredns, ebs-csi), Gateway API CRDs, IAM, `flux-system` namespace |
| 2 | `aws/eks/configure` | Disables VPC CNI, installs Cilium (replacing CNI + kube-proxy), installs Flux Operator + Instance |

`cd opentofu && terramate script run deploy` covers both. `cd opentofu/aws/eks/init && terramate
script run deploy` re-runs just this stack — for a failed run, not the normal flow.

**Cilium prefix delegation is enabled, and WireGuard is load-bearing.** Pods get IPs from the
secondary CIDR (100.64.0.0/16) via the custom CNI ConfigMap in
`aws/eks/configure/cilium-cni-config.tf`. Cilium bug #43493 (still open) breaks the Gateway API L7
proxy on cross-node traffic in this mode — the BPF ipcache sets `hastunnel` incorrectly for remote
pods under native routing. **`encryption.type: wireguard` is the workaround**: node-to-node tunnels
bypass the faulty routing logic. Do not disable it, and do not swap it for ztunnel transparent
encryption, while #43493 is open.

`cniVersion` in `cilium-cni-config.tf` must track the CNI standard version Cilium defaults to (1.20
moved it 0.3.1 → 1.0.0). Because we set `cni.configMap` the chart default never applies — **bump it
manually on every Cilium minor upgrade.**

**Pod subnets (100.64.x.x) must NOT carry the `kubernetes.io/role/cni` tag.** VPC-CNI uses that tag
to discover subnets during Stage 1, which leaves orphan ENIs when Cilium takes over in Stage 2. Use
only `cilium.io/pod-subnet=true`.

**Gateway API version pins move in pairs**: `gateway_api_version` in `config.tm.hcl`'s `globals`
(one value for both clouds, passed by `-var` like `cilium_version`) and the `ref.tag` in
`flux/sources/gitrepo-gateway-api.yaml`. `./scripts/ci/validate-doc-claims.sh` fails when they
disagree.

## Two traps that cost a day each

**A stack that gains a provider breaks `--reverse destroy` invisibly**, because lock files are
gitignored and the destroy path never ran `init`.

**Deploys apply the shared checkout's disk, not `main`.** `git pull` first, then verify the result
against the cloud rather than against the log — `terramate destroy` can exit 0 having destroyed
nothing.
