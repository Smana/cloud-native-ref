---
title: Commands
weight: 30
description: The commands used day to day, verified to exist against the scripts and Terramate workflows in this repository.
lastVerified: 2026-09-02
---

Every command below is either a Terramate script defined in a `workflows.tm.hcl`
file, a script in `scripts/`, or a standard `flux`/`kubectl`/`bao` invocation.

## Terramate / OpenTofu

```bash
terramate script run init            # Initialize all stacks
terramate script run preview         # Preview changes
terramate script run deploy          # Deploy platform
terramate script run drift detect    # Check drift

# Individual stack
cd opentofu/aws/<stack>   # network, eks/init, eks/configure, openbao/{lineage,cluster,management}, llm-platform
cd opentofu/gcp/<stack>   # network, gke/init, gke/configure, openbao/{lineage,cluster,management}
cd opentofu/shared/<stack>  # tailscale, aws-gcp-federation
tofu plan -var-file=variables.tfvars
tofu apply -var-file=variables.tfvars
```

**`TM_CLOUD` picks the cloud**, and defaults to `aws`. Both clouds share one
Terramate run order; this is what stops an AWS deploy building GCP as a side
effect, and a GCP deploy rebuilding `aws-0`:

```bash
terramate script run deploy                    # aws alone (the default)
TM_CLOUD=gcp     terramate script run deploy   # gcp alone; AWS stacks echo [skip]
TM_CLOUD=aws,gcp terramate script run deploy   # both
TM_CLOUD=all     terramate script run deploy   # every lane there is
```

A comma list, so a third cloud needs no new keyword. Stacks under
`opentofu/shared/` are owned by neither cloud and run under every value.

## Environment gates (`TM_*`)

Seven environment variables decide what a Terramate run is allowed to do. Six of
them protect something; **their polarity is not uniform**, so read the `=true`
column rather than guessing from the name. `TM_OPENBAO_SKIP_SNAPSHOT` is the odd
one out: it is the only gate where `true` *removes* a safety step rather than
authorising an action.

All six boolean gates compare against the exact string `true`. `TRUE`, `1` and
`yes` all read as unset — for the four destroy gates that means "stay skipped",
which is the safe direction; for the two `=true`-to-act gates it means "keep the
default behaviour".

| Variable | `=true` | unset (the default) | Gates |
|---|---|---|---|
| `TM_CLOUD` | *not a boolean* — a comma list of lanes, or `all` | `aws`: AWS stacks run, GCP stacks echo `[skip]` and exit 0, `opentofu/shared/**` runs under every value | Every `tofu` call, via `scripts/tm-provisioner.sh` behind `global.provisioner`; plus the non-tofu jobs that carry `--tm-run` or `${global.cloud_gate}` |
| `TM_LLM_PLATFORM_ENABLED` | the stack's `deploy`/`preview`/`drift detect`/`destroy` run | `[skip]`, exit 0 — the platform is never built by a bare `terramate script run deploy` | `opentofu/aws/llm-platform/workflows.tm.hcl` |
| `TM_DESTROY_CONFIRMED` | the y/n prompt is bypassed (this is the CI escape hatch) | prompts once on `/dev/tty`, cached 10 min so `--reverse destroy` asks once; **exits 1** when there is no tty | `scripts/terramate-destroy-confirm.sh`, called first by every stack's `destroy` |
| `TM_LINEAGE_DESTROY` | the four lineage-bearing stacks are destroyed | `[skip]`, exit 0 — a `--reverse destroy` sweep leaves the seal key, both snapshot buckets, the PKI mount and the JWT auth mounts standing | `destroy` in `opentofu/aws/openbao/{lineage,management}` and `opentofu/gcp/openbao/{lineage,management}` |
| `TM_OPENBAO_SKIP_SNAPSHOT` | **inverted** — the CA fetch and the pre-destroy raft snapshot are skipped, and everything written since the last scheduled snapshot is lost | the snapshot is taken, and a failure aborts the destroy rather than stranding a node's data | `destroy` in `opentofu/{aws,gcp}/openbao/cluster`, and the `pre-destroy-snapshot` subcommand of `scripts/openbao-config.sh` |
| `TM_TAILNET_DESTROY` | the tailnet-wide singletons are destroyed | `[skip]`, exit 0 — tearing down one cloud does not remove tailnet access for the other | `destroy` in `opentofu/shared/tailscale/workflows.tm.hcl` |
| `TM_FEDERATION_DESTROY` | the AWS↔GCP OIDC provider and role are destroyed | `[skip]`, exit 0 — `gcp-0`'s cert-manager and external-dns-public keep working | `destroy` in `opentofu/shared/aws-gcp-federation/workflows.tm.hcl` |

Two consequences worth stating outright:

- **A guarded destroy exits 0 when it skips.** That is deliberate — a
  `--reverse destroy` sweep must carry on to the next stack — so a teardown can
  report success having deliberately kept the expensive things. Verify against
  the provider afterwards (see the GKE teardown below) rather than trusting the
  exit code.
- **`TM_LINEAGE_DESTROY=true` is not sufficient on AWS.** Past the gate, the
  seal key carries `prevent_destroy` in `opentofu/aws/openbao/lineage/kms.tf`;
  removing that lifecycle block is a second, deliberate act. Destroying the
  lineage makes every snapshot — including the GCS mirror — permanently
  unreadable.

`TM_GCP_ENABLED` is **retired**. It was half of a two-knob scheme
(`TM_GCP_ENABLED=true` to turn GCP on, `--no-tags=aws` to turn AWS off) that
`TM_CLOUD` replaced; it is inert today and appears only in archived plans under
`docs/superpowers/plans/`.

## EKS deploy (two-stage bootstrap, three jobs)

Defined in `opentofu/aws/eks/init/workflows.tm.hcl`. Stage 1 creates the cluster
with the temporary VPC-CNI; Stage 2 (run from the same script) disables it,
installs Cilium, then Flux; a final `stage3-recycle-bootstrap-nodes` job
recycles the Stage 1 node-group nodes whose ENIs predate Cilium — a no-op once
they use prefix delegation.

`terramate script run deploy` from `opentofu/` already covers this stack, so
these are the targeted forms — useful for re-running one stage after a failure,
never required by the normal flow:

```bash
cd opentofu/aws/eks/init
terramate script run deploy                     # both stages
terramate script run deploy-stage1               # Stage 1 only

# Feature-branch testing — point Flux at a branch instead of main
TF_VAR_flux_git_ref='refs/heads/my-branch' terramate script run deploy
```

`EKS Full Destroy` runs the reverse order: `prepare-destroy` →
`stage2-destroy-addons` → `stage1-destroy-cluster`.

## GKE deploy (four-job bootstrap)

Defined in `opentofu/gcp/gke/init/workflows.tm.hcl`. Not the EKS two-stage
shape — GKE needs no CNI swap, since Cilium's `cni.exclusive` displaces GKE's
config directly — but it does need two bootstrap jobs EKS doesn't:

1. **`stage0-seed-secrets`** — seeds generated secrets *before* the cluster
   exists, so CNPG and Harbor never mint a password nobody holds.
2. **`stage1-cluster`** — the GKE cluster, static spot node pool and Workload
   Identity.
3. **`stage2-cilium-and-flux`** — Gateway API CRDs, then Cilium and Flux.
4. **`stage3-secrets-and-oidc`** — grants External Secrets its per-secret
   access, and registers OIDC clients if this cluster hosts the IdP.

```bash
cd opentofu/gcp/gke/init
TM_CLOUD=gcp terramate script run deploy          # all four jobs
TM_CLOUD=gcp terramate script run deploy-stage1   # stage1-cluster only

TM_CLOUD=gcp TF_VAR_flux_git_ref='refs/heads/my-branch' \
  terramate script run deploy
```

Teardown, then verify against the provider — a Terramate destroy can exit 0
while refusing to run:

```bash
cd opentofu
TM_CLOUD=gcp TM_DESTROY_CONFIRMED=true terramate script run --reverse destroy

gcloud container clusters list --project <project>
gcloud compute instances list --project <project>
gcloud compute forwarding-rules list --project <project>
gcloud compute disks list --project <project>
gcloud compute addresses list --project <project>
```

## Opt-in stacks

`opentofu/aws/llm-platform/` is tagged `opt-in` (see `opentofu/aws/llm-platform/workflows.tm.hcl`):
its `deploy`/`preview`/`drift detect`/`destroy` scripts no-op unless enabled.

```bash
# Default: skipped
terramate script run deploy

# Opt-in for one invocation, any depth
TM_LLM_PLATFORM_ENABLED=true terramate script run deploy

# Target only this stack
TM_LLM_PLATFORM_ENABLED=true terramate -C opentofu/aws/llm-platform script run deploy

# CI / audit path — filter by tag, no env var needed
terramate script run --no-tags=opt-in deploy
terramate script run --tags=opt-in    deploy
```

The Kubernetes side of the LLM platform has its own gate — see
[Repository Layout § Opt-in surfaces]({{< relref "/docs/reference/repository-layout.md" >}}).
`TM_LLM_PLATFORM_ENABLED` is one of seven `TM_*` gates; the rest, and their
polarities, are in [§ Environment gates](#environment-gates-tm_) above.

## Cluster access

Both API endpoints are private, so the Tailscale subnet router has to be up
first (`tailscale status`).

```bash
# aws-0
aws eks update-kubeconfig --region eu-west-3 --name aws-0

# gcp-0
gcloud container clusters get-credentials gcp-0 \
  --zone europe-west4-a --project <project>

flux get all
flux suspend kustomization --all
flux resume kustomization --all
```

## OpenBao

```bash
# aws-0
export VAULT_ADDR=https://bao.priv.aws.ogenki.io:8200
export VAULT_CACERT=opentofu/aws/openbao/management/.tls/ca.pem   # written by openbao-config.sh ca
bao status
bao login -method=userpass username=admin

# The admin password is generated by the management stack:
aws secretsmanager get-secret-value \
  --secret-id openbao/cloud-native-ref/users/admin \
  --query SecretString --output text | jq
```

```bash
# gcp-0 — no userpass here; authenticate with the root token itself
export VAULT_ADDR=https://bao.priv.gcp.ogenki.io:8200
export VAULT_CACERT=opentofu/gcp/openbao/management/.tls/ca.pem
bao status

gcloud secrets versions access latest \
  --secret openbao-priv-gcp-root-token --project <project> | jq -r .token
```

## Validation (run these before claiming anything is done)

```bash
tofu validate
trivy config --exit-code=1 --ignorefile=./.trivyignore.yaml .
./scripts/validate-manifests.sh   # renders the repo the way Flux does, then gates it
./scripts/validate-links.sh       # resolves every relative Markdown link
./scripts/validate-doc-claims.sh  # docs still agree with config (.doc-claims.yaml)
kubectl get nodes && kubectl get pods --all-namespaces
flux get all
```

See [CI Workflows]({{< relref "/docs/reference/ci-workflows.md" >}}) for what
each gate actually checks.

## Scripts (`scripts/`)

| Script | Purpose |
|--------|---------|
| `validate-manifests.sh` | Renders the repo (Kustomize + `helm template`) and gates it with `flux schema validate` + Polaris |
| `validate-links.sh` | Resolves every relative Markdown link in the repository |
| `validate-doc-claims.sh` | Checks the claims pinned in `.doc-claims.yaml` against the configuration they describe |
| `verify-doc-paths.sh` | Checks the documentation site's structural conventions |
| `openbao-config.sh` | OpenBao CA / config helper (`ca`, and other subcommands) |
| `openbao-snapshot.sh` | OpenBao Raft snapshot automation |
| `secret-store.sh` | Inspects and seeds the cloud secret store backing External Secrets (`check`, `seed`, `migrate-aws`) |
| `terramate-destroy-confirm.sh` | Single y/n prompt every stack's destroy script calls first, cached so `--reverse destroy` asks once |
| `eks-prepare-destroy.sh` | Pre-destroy EKS cleanup — suspends Flux, disables blocking webhooks, sweeps orphaned EBS volumes; the CSI volume reclaim itself moved to `k8s-reclaim-csi-volumes.sh` |
| `eks-recycle-bootstrap-nodes.sh` | Recycles Stage 1 node-group nodes so they pick up Cilium prefix delegation |
| `k8s-reclaim-csi-volumes.sh` | Reclaims CSI-provisioned volumes before a cluster destroy — cloud-neutral, called by both teardown paths |
| `destroy-stage2.sh` | Graceful-then-reconcile teardown of either cloud's `configure` stack, never gating the cluster delete |
| `gcp-purge-dns-records.sh` | Empties a Cloud DNS zone of external-dns leftovers so `tofu destroy` can delete it |
| `export-diagrams.sh` | Exports `.drawio` architecture diagrams to PNG |
| `cleanup-benchmark-images.sh` | Cleans up images left behind by the image-gallery/benchmark scripts |
| `image-gallery-benchmark.sh` | Benchmarks the image-gallery demo path |
| `test-flux-schema.sh` | Exercises the Flux schema-validation setup |
| `test-vector-vrl.sh` / `validate-vector-vrl.sh` / `vector-vrl-tests/` | Validate the Vector log-parsing configuration |
