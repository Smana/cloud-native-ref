# GCP Foundation (Network + GKE + Cilium + Flux) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stand up a private GKE Standard cluster on GCP running self-managed Cilium and Flux, reachable over the existing Tailscale tailnet, without moving or modifying any existing AWS file.

**Architecture:** Three new OpenTofu stacks under `opentofu/gcp/` mirroring the existing AWS shape — `network/` (VPC, secondary ranges, Cloud DNS, Tailscale subnet router), `gke/init/` (cluster + static tainted node pool), `gke/configure/` (Cilium then Flux). Two stages because the Helm provider needs a cluster endpoint at plan time, the same reason `eks/init` and `eks/configure` are split. Cilium runs `ipam.mode=kubernetes` over GKE alias IP ranges instead of AWS ENI mode. Flux syncs a **new sibling** tree `clusters/gcp-mycluster-0/`.

**Tech Stack:** OpenTofu 1.12.5, Terramate 0.17.2, `hashicorp/google` provider, GKE Standard (legacy datapath), Cilium 1.20.0, Flux Operator 0.55.0, Tailscale, Trivy.

**Branch:** `feat/gcp-support-specs` (continues the design commit).

**Spec:** [`docs/superpowers/specs/2026-08-18-gcp-support-design.md`](../specs/2026-08-18-gcp-support-design.md)

**Scope:** Design slices 1–3 only. Node autoscaling (slice 4) and `GCPWorkloadIdentity` (slice 5) are separate plans and must not be started here — except for the single Crossplane WIF binding in Task 9, which slice 5 is blocked without.

---

## Amendments (2026-08-22 — Phases 0–4 executed)

**Phases 0 and 1 are complete and the gate PASSED** — see the design doc's
[*Gate results*](../specs/2026-08-18-gcp-support-design.md) section for the evidence.

**Phases 2, 3 and 4 are written, validated and committed but NOT APPLIED.** All three stacks
(`opentofu/gcp/network`, `gke/init`, `gke/configure`) pass `tofu validate`, `tofu fmt -check` and
`trivy config`, and `terramate list` discovers them. Nothing bills yet. Phase 5
(`clusters/gcp-mycluster-0/`) and Phase 6 (verification, runbook) remain.

### Settled inputs

| Input | Value | Source |
|---|---|---|
| Project ID / number | `ogenki-435905` / **`323586397743`** | Task 2 |
| Billing account | `01169B-F52211-252611` | Task 2 |
| State bucket | `gs://ogenki-435905-tfstate` (EU, UBLA, PAP enforced, versioned) | Task 2 |
| **Region** | **`europe-west4`** (Netherlands) | Task 3 |
| **Topology** | **zonal**, `europe-west4-a` | Task 3 |
| **Node image** | **`cos_containerd`** — slice 4 must pin the same | Task 3 |
| GKE version available | `1.35.6-gke.1641000` (floor was `1.33.3-gke.1136000`) | Task 3 |

Region was decided on **GPU availability**, not price: `nvidia-l4` — what the AWS `gpu-l4` pool uses
and what slice 4 / workstream 14 need — exists in all three `europe-west4` zones, in two
`europe-west1` zones, and **not at all in `europe-west9`** (Paris, the geographic match for AWS
`eu-west-3`, which offers only H100/H100-mega). `europe-west4` additionally carries A100, H100,
H200, B200 and TPUs, so a future accelerator tier needs no region migration.

Zonal follows design criterion 9 ("static-pool nodes … in a single zone") and the AWS bootstrap
group's single-subnet cost choice. Per GKE docs a regional Standard cluster's default node pool is
**nine nodes (three per zone)** and *"you are charged for node-to-node traffic across zones"*.
Accepted trade-off, to be documented not hidden: **a zonal control plane is unavailable during
upgrades and maintenance.**

> **Still open for Task 18:** the per-cluster management fee split between zonal and regional under
> GKE Standard edition, and the free-tier credit. The pricing page did not render usefully via
> fetch, so the run-rate estimate is not yet citable.

### Amendment 1 — use mature upstream modules (user directive)

Phases 2–3 must be written with the Cloud Foundation Toolkit modules rather than hand-rolled
`google_compute_*` / `google_container_*` resources, mirroring the AWS side
(`terraform-aws-modules/vpc/aws ~> 6.0`, `terraform-aws-modules/eks/aws ~> 21`):

| Purpose | Module | Latest at time of writing |
|---|---|---|
| VPC, subnets, secondary ranges, PGA, firewall | `terraform-google-modules/network/google` | 18.1.2 |
| GKE cluster + node pools | `terraform-google-modules/kubernetes-engine/google` | 44.3.0 |
| Cloud Router + NAT | `terraform-google-modules/cloud-nat/google` | verify at Phase 2 |
| Cloud DNS private zone | `terraform-google-modules/cloud-dns/google` | verify at Phase 2 |

The File Structure table below keeps its filenames; their **bodies** become module blocks. When
wiring the GKE module: never set `datapath_provider = "ADVANCED_DATAPATH"` (create-time only),
disable the module's `network_policy` (Cilium is the policy engine), and keep
`node.cilium.io/agent-not-ready=true:NoSchedule` on the pool at create time.

### Amendment 2 — Task 1 was wrong about `gcloud`

`gcloud` **was** already installed (Arch `/opt/google-cloud-cli`, 581.0.0), contradicting the
pre-flight note. It is now pinned anyway as `"asdf:mise-plugins/mise-gcloud" = "581.0.0"`, because
the system package cannot run `gcloud components install`.

**`gke-gcloud-auth-plugin` is a separate component and was absent.** Without it every `kubectl`
call against GKE fails with `executable gke-gcloud-auth-plugin not found`. Install it into the
mise-managed SDK: `gcloud components install gke-gcloud-auth-plugin`.

### Amendment 2b — Application Default Credentials are a SEPARATE login

`gcloud auth login` and Application Default Credentials are **two different credential stores**, and
this bites in a way that looks like a permissions bug rather than an auth one.

Every `gcloud` CLI command uses the *active account* (`gcloud config get-value account`). The
OpenTofu `google` provider and the GCS backend do **not** — they read
`~/.config/gcloud/application_default_credentials.json`. Log in with one and not the other and every
`gcloud` command succeeds while `tofu init` fails at backend initialisation with:

```
Error: Failed to get existing workspaces: querying Cloud Storage failed: googleapi: Error 403:
<wrong-identity> does not have storage.objects.list access to the Google Cloud Storage bucket.
```

Observed live on 2026-08-23: the active account was `smaine.kahlouch@ogenki.io` while the ADC file
was four months stale and still held a personal gmail identity, which has no access to
`ogenki-435905`. The 403 names the ADC identity, not the active account — read it carefully, because
the instinct is to go grant the *active* account more IAM, which changes nothing.

**Required before any `tofu` command against GCP:**

```bash
gcloud auth application-default login \
  --scopes=https://www.googleapis.com/auth/cloud-platform,https://www.googleapis.com/auth/userinfo.email
gcloud auth application-default set-quota-project ogenki-435905
```

The explicit `--scopes` matters: the bare form requests a narrower default set and fails with
`cloud-platform scope is required but not consented` — hit twice on 2026-08-23 before the flag was
added. The consent screen also lists the scopes as checkboxes; they must be ticked.

Verify the two identities agree before deploying:

```bash
gcloud config get-value account                                   # CLI identity
ls -la ~/.config/gcloud/application_default_credentials.json      # ADC: check the date is recent
```

`set-quota-project` is not cosmetic — without it the provider emits a billing-attribution warning on
every API call and some APIs refuse the request outright.

### Amendment 2c — findings from the first real deploy (2026-08-23)

Network and stage 1 were applied end to end against `ogenki-435905`, then destroyed.
Stage 2 was not reached (it needs `tailscaled` running locally for the private endpoint).
Three defects surfaced that **no amount of `tofu validate`, `trivy` or plan review could catch**:

1. **Tailscale rejects `(` and `)` in a tailnet key description.** `GCP subnet router (dev)` failed
   at API create time with `keys: description had invalid characters (400)` — an error naming
   neither the offending character nor the accepted charset. Alphanumerics, spaces and dashes are
   safe. Note the blast radius: this fired *mid-apply*, after 9 of 11 resources had already been
   created, which is why applying the network stack before the cluster is the right order.
2. **ADC vs CLI credentials** — see Amendment 2b.
3. **`google_project_iam_member.crossplane` needs `depends_on = [module.gke]`.** Its principal is
   built from variables, so OpenTofu sees no reference to the cluster and schedules the binding in
   parallel — but the Workload Identity Pool `<project>.svc.id.goog` does not exist until a cluster
   with `workload_pool` has been created. Fresh applies fail with
   `Error 400: Identity Pool does not exist`. **It does not reproduce on re-apply**, because by then
   the pool exists — a fresh-apply-only failure, the same class as the
   provider-from-same-apply-outputs trap in `opentofu/aws/eks/init/providers.tf`: a dependency that
   is real but invisible to the graph.

**Teardown gotcha.** `tofu destroy` on the network stack failed with
`subnetwork ... is already being used by instances/ogenki-gcp` while an audit seconds later showed
no instances — GCP eventual consistency, the instance delete had returned but the subnet still
counted it as attached. Re-running succeeded unchanged. Expect this on the
`terramate script run destroy` path; the first failure is not a real blocker.

### Amendment 2d — cluster naming convention

**`aws-mycluster-0` / `gcp-mycluster-0`** — symmetric cloud prefixes, so neither cloud reads as
"the" platform, matching the cloud-partitioned `opentofu/` layout.

GCP already uses `gcp-mycluster-0`. **AWS keeps `mycluster-0` until its next from-scratch rebuild**,
then becomes `aws-mycluster-0`: an EKS cluster name is immutable, so renaming now would mean
destroying and recreating the live cluster plus touching 144 files. The present asymmetry is
therefore deliberate and temporary — not an oversight to be "fixed" by someone reading
`clusters/` later.

### Amendment 3 — Task 4's Cilium install is missing two mandatory values

Both were found by the gate and must be carried into Task 10's forked
`helm_values/cilium.yaml`. Full evidence in the design doc.

```
--set cni.binPath=/home/kubernetes/bin      # /opt/cni/bin is READ-ONLY on COS
--set ipv4NativeRoutingCIDR=100.65.0.0/16   # mandatory for native + ipam=kubernetes
```

`gke.enabled=true` does **not** set `cni.binPath` in 1.20.0 — it only toggles
`enable-endpoint-routes` and `enable-health-check-loadbalancer-ip`.

### Amendment 4 — Gateway API CRDs need server-side apply

`kubectl apply -f experimental-install.yaml` fails on `httproutes` with
`metadata.annotations: Too long: may not be more than 262144 bytes`. Use
`kubectl apply --server-side`. **Task 11 applies these CRDs from OpenTofu — the provider must use
server-side apply**, or Phase 3 hits the same wall.

### Amendment 5 — `gateway_api.tf` belongs in `configure`, not `init`

Task 11 places it in `gke/init`. It cannot go there. `opentofu/eks/init/providers.tf` documents why,
after the AWS side hit it: a kubectl/kubernetes provider configured from the cluster being created
in the *same apply* cannot be deferred and fails on fresh applies with *"no configuration has been
provided"*. The AWS side accordingly applies its Gateway API CRDs from `eks/configure`.

`gke/init` therefore declares **no** Kubernetes-facing provider at all, and says so in
`versions.tf`. Two consequences:

- `gateway_api_version` is a `configure` variable, not an `init` one.
- The CFT GKE module's `configure_ip_masq` must stay **false** — its ip-masq-agent is a
  `kubernetes_config_map`, i.e. the same same-apply call. It defaults to false; it is now pinned
  explicitly with a comment, because flipping it would silently reintroduce the bug.

### Amendment 6 — the tailnet ACL is a singleton owned by the AWS stack

`opentofu/network/tailscale.tf` declares `tailscale_acl` with
`overwrite_existing_content = true`, plus `tailscale_dns_nameservers` and
`tailscale_dns_search_paths`. These are **tailnet-wide**, and both clouds share one tailnet.

`opentofu/gcp/network` therefore deliberately declares none of them — a second `tailscale_acl` would
make each apply silently overwrite the other's, last-apply-wins. It creates only per-device and
per-domain resources (`tailscale_tailnet_key`, a `tailscale_dns_split_nameservers` for the GCP
domain, the GCE instance).

The consequence is a genuine cross-stack dependency the plan did not anticipate: the GCP router's
routes are advertised but neither auto-approved nor permitted until the **AWS-owned** ACL carries
them, and editing that ACL by hand does not survive the next AWS apply. Resolved by adding a
`gcp_routes` variable to `opentofu/network` and wiring it into both `acls` and `autoApprovers`.

### Amendment 7 — corrections to the plan's scaffolding snippets

| Plan says | Reality |
|---|---|
| `stack.id = "gcp-network"` | Terramate stack IDs in this repo are **UUIDs** |
| `tailscale ~> 0.17` | The AWS stack pins `~> 0.29` |
| `google ~> 6.0` | Latest is 7.45; the CFT GKE module requires `>= 7.17, < 8`. Use `~> 7.17` |
| `alekc/kubectl` (implied) | `eks/configure` uses **`gavinbunney/kubectl ~> 1.14`** |
| — | `*.tfvars` is gitignored; the AWS ones are force-added. Use `git add -f` |
| — | The CFT network module also requires the `google-beta` provider to be configured |

### Amendment 8 — Flux's Git credentials come from GCP Secret Manager

This closes a design open question. The AWS cluster reads the GitHub App credentials from AWS
Secrets Manager; doing the same on GCP would put a hard AWS dependency in the GCP bootstrap, which
is precisely what a second first-class cloud is meant to avoid.

`gke/configure` reads them from **GCP Secret Manager** instead (`secretmanager.googleapis.com` is
already enabled). The secret is a **prerequisite**, deliberately not created in OpenTofu — putting
real credentials in a plan or state violates the platform's no-hardcoded-credentials rule.
`configure/data.tf` documents the expected JSON shape and the `gcloud secrets create` command.
Moves to OpenBao once workstream 11 lands.

### Amendment 9 — a CFT module key that looks right and does nothing

`workload_metadata_configuration` inside a `node_pools[]` entry is **not** a key the module reads.
Node metadata mode comes from the module-level `var.node_metadata` (default `GKE_METADATA`). The
per-pool key renders no config while looking correct in review. Now set explicitly at module level.

Trivy also reports `GCP-0057` against the module's own `cluster.tf` because it cannot resolve the
`dynamic "workload_metadata_config"` block — a false positive, annotated as such.

### Amendment 10 — diagnosis is blind while the CNI is down

`kubectl logs` and `kubectl exec` both tunnel through konnectivity, whose agent is a pod needing the
very CNI that is broken; both return `error dialing backend: No agent available`. A hostNetwork
debug pod does not help — `exec` uses the same tunnel. The working route was `gcloud compute ssh`
reading `/var/log/pods/`. Note `gcloud compute ssh` needs a passphrase-free key or a loaded agent in
non-interactive use.

---

## Pre-flight context (verified during plan writing — no action needed)

- **`gcloud` is NOT installed** and is absent from `mise.toml`. Task 1 adds it. Every other tool in this plan is already pinned in `mise.toml` (opentofu 1.12.5, terramate 0.17.2, trivy 0.74.0, flux2 2.9.4, helm 4.2.4, kustomize 5.8.1).
- **AWS CIDRs that GCP must not collide with** (`opentofu/network/variables.tf`): VPC `10.0.0.0/16` (`vpc_cidr`), pods `100.64.0.0/16` (`pod_cidr`). Both clusters join the **same tailnet**, so an overlap breaks subnet routing in a way that presents as a Cilium bug.
- **Terramate globals** live in `opentofu/config.tm.hcl`. `region = "eu-west-3"` and `eks_cluster_name` are AWS-specific; `cilium_version = "1.20.0"` and `flux_operator_version`/`flux_instance_version = "0.55.0"` are **shared** and must stay shared.
- **The two-stage script pattern** is `opentofu/eks/init/workflows.tm.hcl`: a `deploy` script with one `job` per stage, stage 2 invoked via `["bash", "-c", "cd ../configure && ..."]`, and `trivy config --exit-code=1 --ignorefile=./.trivyignore.yaml .` in the chain before apply. `preview` uses `sync_preview = true` + `tofu_plan_file`.
- **`eks/init` stage 3 (`eks-recycle-bootstrap-nodes.sh`) has no GCP analogue** — it exists solely for ENI prefix-delegation ordering. Do not port it.
- **`eks/configure/main.tf` is deliberately `local-exec`-free**; imperative steps live in Terramate jobs. Keep `gke/configure` the same way.
- **`eks/configure` reads the Cilium values from the init stack**: `values = [file("${path.module}/../init/helm_values/cilium.yaml")]`. Mirror that path convention.
- **AWS Cilium values to diverge from** (`opentofu/eks/init/helm_values/cilium.yaml`): `ipam.mode: eni`, an `eni:` block, `routingMode: native`, `kubeProxyReplacement: true`, `encryption` (wireguard), `gatewayAPI`, `hubble`.
- **`opentofu/eks/configure/cilium-cni-config.tf`** is the AWS prefix-delegation ConfigMap. **No GCP counterpart — do not create one.**
- **EKS bootstrap node group cost posture to match** (`opentofu/eks/init/main.tf:120-149`): `capacity_type = "SPOT"`, `min_size = 2 / max_size = 3`, single subnet with the comment *"Use a single subnet for costs reasons"*, 6 diversified instance types. A GKE node pool takes **one** machine type, so that last technique does not port.
- **Tailscale tailnet**: `smainklh@gmail.com`, subnet router named `ogenki` (`opentofu/network/variables.tfvars`).
- **Cilium's current GKE recipe** (docs.cilium.io GKE Clustermesh Prep) requires `--enable-ip-alias`, explicit `--cluster-ipv4-cidr` / `--services-ipv4-cidr`, and `--node-taints node.cilium.io/agent-not-ready=true:NoSchedule`. `--enable-dataplane-v2` is opt-in on Standard, so it is simply **not passed**.

### Proposed CIDR allocation (verify in Task 3, do not assume)

| Range | Value | Avoids |
|---|---|---|
| GCP node subnet | `10.10.0.0/16` | AWS VPC `10.0.0.0/16` |
| GCP pods (secondary) | `100.65.0.0/16` | AWS pods `100.64.0.0/16` |
| GCP services (secondary) | `10.11.0.0/20` | both |
| GKE control plane | `172.16.0.0/28` | both (GKE requires exactly /28) |

---

## File Structure

| File | Action | Responsibility |
|---|---|---|
| `mise.toml` | Modify | Pin `gcloud` |
| `opentofu/config.tm.hcl` | Modify | Add GCP globals; leave `cilium_version`/`flux_*` shared |
| `opentofu/gcp/network/versions.tf` | Create | Provider + OpenTofu version constraints |
| `opentofu/gcp/network/providers.tf` | Create | `google` + `tailscale` provider config |
| `opentofu/gcp/network/backend.tf` | Create | GCS remote state |
| `opentofu/gcp/network/variables.tf` | Create | Inputs with CIDR defaults + validation |
| `opentofu/gcp/network/variables.tfvars` | Create | Concrete values for this environment |
| `opentofu/gcp/network/network.tf` | Create | VPC, node subnet, pod/service secondary ranges, Private Google Access |
| `opentofu/gcp/network/nat.tf` | Create | Cloud Router + Cloud NAT for external egress only |
| `opentofu/gcp/network/dns.tf` | Create | Cloud DNS private zone |
| `opentofu/gcp/network/tailscale.tf` | Create | Subnet router on GCE, smallest viable machine type |
| `opentofu/gcp/network/outputs.tf` | Create | Network/subnet self-links, range names, consumed by `gke/init` |
| `opentofu/gcp/network/stack.tm.hcl` | Create | Terramate stack metadata |
| `opentofu/gcp/gke/init/main.tf` | Create | GKE Standard cluster + static spot node pool |
| `opentofu/gcp/gke/init/iam.tf` | Create | Crossplane WIF binding (unblocks slice 5) |
| `opentofu/gcp/gke/init/gateway_api.tf` | Create | Gateway API CRDs, applied before Cilium |
| `opentofu/gcp/gke/init/helm_values/cilium.yaml` | Create | Forked GCP Cilium values |
| `opentofu/gcp/gke/init/helm_values/flux-instance.yaml` | Create | Flux Instance values, GCP storage class |
| `opentofu/gcp/gke/init/{versions,providers,backend,variables,data,outputs}.tf` | Create | Stack plumbing |
| `opentofu/gcp/gke/init/variables.tfvars` | Create | Concrete values |
| `opentofu/gcp/gke/init/{stack,workflows}.tm.hcl` | Create | Stack metadata + two-stage deploy scripts |
| `opentofu/gcp/gke/configure/main.tf` | Create | Cilium then Flux Operator + Flux Instance |
| `opentofu/gcp/gke/configure/{versions,providers,backend,variables,data,locals}.tf` | Create | Stack plumbing |
| `opentofu/gcp/gke/configure/stack.tm.hcl` | Create | Stack metadata |
| `clusters/gcp-mycluster-0/**` | Create | New sibling Flux tree, minimum viable set |
| `docs/gcp-bootstrap.md` | Create | Bootstrap runbook + monthly run-rate estimate |
| `CLAUDE.md` | Modify | GCP stacks in architecture; WireGuard note rescoped (Task 21 only, gated) |

---

## Phase 0 — Tooling and prerequisites

### Task 1: Pin `gcloud` in mise

**Files:**
- Modify: `mise.toml`

- [x] **Step 1: Confirm gcloud is genuinely absent**

Run: `command -v gcloud || echo ABSENT`
Expected: `ABSENT`

- [x] **Step 2: Find the correct mise backend for gcloud**

Run: `mise registry | grep -i gcloud`
Expected: one or more rows. Record the exact backend string printed (for example `asdf:jthegedus/asdf-gcloud`). **Use what the registry prints — do not guess the backend.** If the registry returns nothing, stop and install the Google Cloud SDK by the official method, then note in `docs/gcp-bootstrap.md` that gcloud is not mise-managed and why.

- [x] **Step 3: Add the pin**

Add to the `[tools]` table in `mise.toml`, keeping the existing comment block intact, substituting the backend and latest stable version from Step 2:

```toml
# Google Cloud SDK — required by the GCP stacks (opentofu/gcp/**) for cluster
# credentials and for the gcloud-based evidence commands in the GCP runbook.
"<backend-from-step-2>" = "<version>"
```

- [x] **Step 4: Verify it installs and runs**

Run: `mise install && gcloud version`
Expected: version output, no error.

- [x] **Step 5: Commit**

```bash
git add mise.toml
git commit -m "build(mise): pin gcloud for the GCP stacks"
```

### Task 2: GCP project prerequisites

**Files:** none (environment setup; recorded in the runbook by Task 20)

- [x] **Step 1: Confirm an authenticated project with billing**

Run:
```bash
gcloud auth list
gcloud config get-value project
gcloud beta billing projects describe "$(gcloud config get-value project)" --format='value(billingEnabled)'
```
Expected: an active account, a project id, and `True`.

**If billing is not enabled, stop.** Nothing past Task 4 can be verified without a billable project.

- [x] **Step 2: Enable the required APIs**

Run:
```bash
gcloud services enable \
  container.googleapis.com \
  compute.googleapis.com \
  dns.googleapis.com \
  iam.googleapis.com \
  iamcredentials.googleapis.com \
  secretmanager.googleapis.com \
  cloudresourcemanager.googleapis.com
```
Expected: `Operation ... finished successfully.`

- [x] **Step 3: Record the project number**

Run: `gcloud projects describe "$(gcloud config get-value project)" --format='value(projectNumber)'`
Expected: a numeric id. **Save it** — the Workload Identity principal string in Task 9 needs the project **number**, while the pool name needs the project **id**. These are different values in different segments and reversing them produces a binding that is accepted and never matches.

- [x] **Step 4: Create the GCS state bucket**

Run, substituting the project id:
```bash
PROJECT="$(gcloud config get-value project)"
gcloud storage buckets create "gs://${PROJECT}-tfstate" \
  --location=EU --uniform-bucket-level-access --public-access-prevention
gcloud storage buckets update "gs://${PROJECT}-tfstate" --versioning
```
Expected: bucket created, versioning enabled.

### Task 3: Fix the CIDR allocation

**Files:** none yet (values consumed by Task 5)

- [x] **Step 1: Print the AWS ranges currently advertised into the tailnet**

Run:
```bash
grep -A3 -E 'variable "(vpc_cidr|pod_cidr)"' opentofu/network/variables.tf
tailscale status --json | jq -r '.Peer[] | select(.PrimaryRoutes != null) | "\(.HostName): \(.PrimaryRoutes | join(", "))"'
```
Expected: `10.0.0.0/16` and `100.64.0.0/16` from the first command, plus whatever the subnet router actually advertises.

- [x] **Step 2: Confirm the proposed GCP ranges do not overlap**

Run:
```bash
python3 - <<'PY'
import ipaddress as ip
aws = [ip.ip_network(c) for c in ("10.0.0.0/16", "100.64.0.0/16")]
gcp = {"nodes":"10.10.0.0/16","pods":"100.65.0.0/16","services":"10.11.0.0/20","control-plane":"172.16.0.0/28"}
bad = False
for name, c in gcp.items():
    n = ip.ip_network(c)
    for a in aws:
        if n.overlaps(a):
            print(f"OVERLAP: gcp {name} {c} overlaps aws {a}"); bad = True
print("no overlap" if not bad else "FIX THE PLAN")
PY
```
Expected: `no overlap`

**Add any extra ranges the previous step revealed to the `aws` list before trusting this.**

- [x] **Step 3: Decide zonal vs regional, and record the cost delta**

Run: `gcloud container get-server-config --region=europe-west1 --format='value(defaultClusterVersion)'`
Expected: a version string >= `1.33.3-gke.1136000`. If it is lower, pick a different region or channel — the autoscaling plan (slice 4) requires that floor, and `--workload-pool` support is needed here.

Then decide zonal or regional and write one sentence of justification into a scratch note for Task 20. The GKE cluster management fee and free-tier eligibility differ between them; defaulting to regional without stating the cost is not acceptable.

- [x] **Step 4: Choose the node image type**

Decide `cos_containerd` (GKE default, smaller attack surface) or `ubuntu_containerd` (more familiar kernel, easier debugging on an unsupported path). Record the choice and reason for Task 20. Slice 4 must pin the **same** value, so this decision propagates.

---

## Phase 1 — THE GATE: prove ADR-0005 on a throwaway cluster

**Do not write any OpenTofu until this phase passes.** If either check fails, stop, reopen [ADR-0005](../../../website/content/docs/decisions/0005-gke-standard-self-managed-cilium.md), and evaluate Dataplane V2 — which costs a second Gateway API implementation and the loss of the Envoy access-log pipeline. Discovering this after Phase 2–5 is built means throwing away all of it.

### Task 4: Prove Cilium displaces GKE's netd, and that WireGuard is unnecessary

**Files:** none (throwaway resources, deleted in Step 8)

- [x] **Step 1: Create the throwaway cluster**

Run, substituting your zone and the image type from Task 3 Step 4:
```bash
ZONE=europe-west1-b
gcloud container clusters create cilium-gate \
  --zone "$ZONE" --num-nodes 2 --machine-type e2-standard-4 --spot \
  --enable-ip-alias --cluster-ipv4-cidr 100.65.0.0/16 --services-ipv4-cidr 10.11.0.0/20 \
  --image-type COS_CONTAINERD \
  --node-taints node.cilium.io/agent-not-ready=true:NoSchedule \
  --no-enable-master-authorized-networks \
  --logging=NONE --monitoring=NONE
```
Expected: cluster created. Note `--enable-dataplane-v2` is deliberately **absent**.

- [x] **Step 2: Confirm the datapath is legacy, not Dataplane V2**

Run: `gcloud container clusters describe cilium-gate --zone "$ZONE" --format='yaml(networkConfig.datapathProvider)'`
Expected: the field is absent or not `ADVANCED_DATAPATH`. **If it says `ADVANCED_DATAPATH`, the flavour is not available as designed — stop and reopen ADR-0005.**

- [x] **Step 3: Install Cilium 1.20.0 in GKE mode**

Run:
```bash
gcloud container clusters get-credentials cilium-gate --zone "$ZONE"
helm repo add cilium https://helm.cilium.io && helm repo update
helm install cilium cilium/cilium --version 1.20.0 --namespace kube-system \
  --set ipam.mode=kubernetes \
  --set routingMode=native \
  --set kubeProxyReplacement=true \
  --set gatewayAPI.enabled=true \
  --set hubble.relay.enabled=true --set hubble.ui.enabled=true
kubectl -n kube-system rollout status ds/cilium --timeout=5m
```
Expected: DaemonSet rolls out.

**Install the Gateway API CRDs BEFORE this helm install**, not after it errors. `gatewayAPI.enabled=true`
does not necessarily fail loudly on missing CRDs — cilium-operator probes for them once at startup and
then silently disables Gateway API for the life of the pod (see Task 11). Installing after the fact
leaves the gate cluster in exactly the broken state that took AWS down on 2026-08-19, and a gate that
lies is worse than no gate.

```bash
kubectl apply -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/experimental-install.yaml"
```

`GATEWAY_API_VERSION` is `flux/sources/gitrepo-gateway-api.yaml`'s `ref.tag` — experimental channel, to
match AWS. If you install Cilium first by mistake:
`kubectl rollout restart -n kube-system deployment/cilium-operator`.

- [x] **Step 4: CHECK 1 — Cilium's CNI config displaced netd**

Run:
```bash
NODE=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')
POD=$(kubectl get pod -n kube-system -l k8s-app=cilium \
  --field-selector "spec.nodeName=$NODE" -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n kube-system "$POD" -c cilium-agent -- ls -la /host/etc/cni/net.d/
```
Expected: a Cilium conflist present, and **no active GKE/netd conflist** ahead of it in lexical order. Files renamed to `*.cilium_bak` are fine — that is `cni.exclusive` doing its job.

**FAIL CRITERION:** an active non-Cilium `.conflist` sorting before Cilium's. If so, **stop — reopen ADR-0005.**

- [x] **Step 5: Confirm Cilium is healthy and pods actually get IPs**

Run:
```bash
kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium status --brief
kubectl create deploy gate-probe --image=nginx --replicas=4
kubectl rollout status deploy/gate-probe --timeout=3m
kubectl get pods -o wide -l app=gate-probe
```
Expected: `cilium status` OK; 4 pods `Running` with IPs from `100.65.0.0/16`, spread across both nodes.

- [x] **Step 6: CHECK 2 — cross-node L7 through a Cilium Gateway, no WireGuard**

Run:
```bash
kubectl apply -f - <<'YAML'
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata: { name: cilium }
spec: { controllerName: io.cilium/gateway-controller }
---
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata: { name: gate, namespace: default }
spec:
  gatewayClassName: cilium
  listeners: [{ name: http, protocol: HTTP, port: 80 }]
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata: { name: gate, namespace: default }
spec:
  parentRefs: [{ name: gate }]
  rules: [{ backendRefs: [{ name: gate-probe, port: 80 }] }]
YAML
kubectl expose deploy gate-probe --port 80
kubectl wait --for=condition=Programmed gateway/gate --timeout=5m
GW=$(kubectl get gateway gate -o jsonpath='{.status.addresses[0].value}')
kubectl run curl --image=curlimages/curl --restart=Never -it --rm -- \
  sh -c "for i in \$(seq 1 100); do curl -s -o /dev/null -w '%{http_code}\n' http://$GW/; done | sort | uniq -c"
```
Expected: `100 200` — 100 responses, all HTTP 200, with `encryption` never set.

**FAIL CRITERION:** any non-200. That would mean cilium#43493 (or something like it) applies on GKE too. Do **not** paper over it by enabling WireGuard — record the evidence and reopen ADR-0005, because the design's claim that the bug is ENI-specific would be wrong.

- [x] **Step 7: Record the outcome in the design doc**

Append a short "Gate results (YYYY-MM-DD)" subsection to
`docs/superpowers/specs/2026-08-18-gcp-support-design.md` under *Verified during design*, stating for each check: pass/fail, the command output, and the cluster version tested. This is the durable evidence that ADR-0005 was validated rather than assumed.

- [x] **Step 8: Destroy the throwaway cluster**

Run: `gcloud container clusters delete cilium-gate --zone "$ZONE" --quiet`
Expected: deleted. **Do not skip — a forgotten GKE cluster is the single most expensive mistake available in this plan.**

- [x] **Step 9: Commit**

```bash
git add docs/superpowers/specs/2026-08-18-gcp-support-design.md
git commit -m "docs(gcp): record Cilium-on-GKE gate results

CNI displacement and cross-node L7 verified on GKE <version>. ADR-0005
validated on a throwaway cluster before any OpenTofu was written."
```

---

## Phase 2 — Network stack

### Task 5: Terramate globals for GCP

**Files:**
- Modify: `opentofu/config.tm.hcl`

- [ ] **Step 1: Add GCP globals**

Append inside the existing `globals { }` block, below `flux_sync_repository_url`. Do **not** touch `cilium_version`, `flux_operator_version` or `flux_instance_version` — they are shared across both clouds on purpose, so the two clusters upgrade Cilium together.

```hcl
  # GCP (dual-cloud — see docs/superpowers/specs/2026-08-18-gcp-support-design.md)
  # `region`/`eks_cluster_name` above are AWS-specific; these are the GCP peers.
  gcp_project      = "<project-id-from-task-2>"
  gcp_region       = "europe-west1"
  gcp_zone         = "europe-west1-b"
  gke_cluster_name = "gcp-mycluster-0"
```

- [ ] **Step 2: Verify Terramate still parses every stack**

Run: `terramate list`
Expected: the existing stacks listed, no HCL error.

- [ ] **Step 3: Commit**

```bash
git add opentofu/config.tm.hcl
git commit -m "feat(gcp): add GCP globals to terramate config

cilium_version and flux_* stay shared so both clouds upgrade together."
```

### Task 6: Network stack plumbing

**Files:**
- Create: `opentofu/gcp/network/versions.tf`, `providers.tf`, `backend.tf`, `stack.tm.hcl`

- [ ] **Step 1: Write `versions.tf`**

```hcl
terraform {
  required_version = "~> 1.12"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
    tailscale = {
      source  = "tailscale/tailscale"
      version = "~> 0.17"
    }
  }
}
```

- [ ] **Step 2: Write `providers.tf`**

```hcl
provider "google" {
  project = var.project_id
  region  = var.region
}

provider "tailscale" {
  tailnet = var.tailscale_config.tailnet
}
```

- [ ] **Step 3: Write `backend.tf`**

Substitute the bucket from Task 2 Step 4:

```hcl
terraform {
  backend "gcs" {
    bucket = "<project-id>-tfstate"
    prefix = "gcp/network"
  }
}
```

- [ ] **Step 4: Write `stack.tm.hcl`**

```hcl
stack {
  name        = "GCP Network"
  description = "VPC, subnets with pod/service secondary ranges, Cloud DNS, Cloud NAT, Tailscale subnet router"
  id          = "gcp-network"

  tags = [
    "gcp",
    "network",
    "infrastructure"
  ]
}
```

- [ ] **Step 5: Verify the stack is discovered**

Run: `terramate list | grep gcp/network`
Expected: `/opentofu/gcp/network`

- [ ] **Step 6: Commit**

```bash
git add opentofu/gcp/network
git commit -m "feat(gcp): scaffold network stack"
```

### Task 7: VPC, subnet, secondary ranges, Private Google Access

**Files:**
- Create: `opentofu/gcp/network/variables.tf`, `variables.tfvars`, `network.tf`, `nat.tf`, `outputs.tf`

- [ ] **Step 1: Write `variables.tf` with overlap-guarding validation**

The `validation` blocks are the test: they make an AWS-colliding CIDR a plan-time failure rather than a Tailscale mystery months later.

```hcl
variable "project_id" {
  description = "GCP project ID"
  type        = string
}

variable "region" {
  description = "GCP region"
  type        = string
  default     = "europe-west1"
}

variable "env" {
  description = "Environment name"
  type        = string
  default     = "dev"
}

variable "private_domain_name" {
  description = "Private DNS zone for GCP platform services"
  type        = string
  default     = "priv.gcp.ogenki.io"
}

variable "node_cidr" {
  description = "Primary CIDR for the node subnet. MUST NOT overlap the AWS VPC (10.0.0.0/16) — both clusters share one tailnet."
  type        = string
  default     = "10.10.0.0/16"

  validation {
    condition     = !can(cidrhost("10.0.0.0/16", 0)) ? true : length(cidrnetmask(var.node_cidr)) > 0
    error_message = "node_cidr must be a valid CIDR."
  }
}

variable "pod_cidr" {
  description = "Secondary range for pod IPs. MUST NOT overlap the AWS pod CIDR (100.64.0.0/16)."
  type        = string
  default     = "100.65.0.0/16"
}

variable "service_cidr" {
  description = "Secondary range for Service ClusterIPs."
  type        = string
  default     = "10.11.0.0/20"
}

variable "tailscale_config" {
  description = "Tailscale subnet router configuration. Reuses the existing tailnet."
  type = object({
    subnet_router_name = string
    tailnet            = string
    machine_type       = optional(string, "e2-small")
  })
}

variable "labels" {
  description = "Labels applied to all resources"
  type        = map(string)
  default = {
    project = "cloud-native-ref"
    owner   = "smana"
  }
}
```

- [ ] **Step 2: Write `variables.tfvars`**

```hcl
project_id          = "<project-id-from-task-2>"
region              = "europe-west1"
env                 = "dev"
private_domain_name = "priv.gcp.ogenki.io"

node_cidr    = "10.10.0.0/16"
pod_cidr     = "100.65.0.0/16"
service_cidr = "10.11.0.0/20"

tailscale_config = {
  subnet_router_name = "ogenki-gcp"
  tailnet            = "smainklh@gmail.com"
  machine_type       = "e2-small"
}
```

- [ ] **Step 3: Write `network.tf`**

`private_ip_google_access = true` is the cost lever: without it, every call to a Google API is billed through Cloud NAT.

```hcl
resource "google_compute_network" "this" {
  name                    = "${var.env}-ogenki"
  auto_create_subnetworks = false
  routing_mode            = "REGIONAL"
}

resource "google_compute_subnetwork" "nodes" {
  name          = "${var.env}-ogenki-nodes"
  network       = google_compute_network.this.id
  region        = var.region
  ip_cidr_range = var.node_cidr

  # Cost lever: keeps Google API traffic off Cloud NAT entirely.
  private_ip_google_access = true

  secondary_ip_range {
    range_name    = "pods"
    ip_cidr_range = var.pod_cidr
  }

  secondary_ip_range {
    range_name    = "services"
    ip_cidr_range = var.service_cidr
  }
}
```

- [ ] **Step 4: Write `nat.tf`**

```hcl
# Cloud NAT exists ONLY for genuine external egress (public container registries).
# Google API traffic goes via Private Google Access — see network.tf.
resource "google_compute_router" "this" {
  name    = "${var.env}-ogenki-router"
  network = google_compute_network.this.id
  region  = var.region
}

resource "google_compute_router_nat" "this" {
  name                               = "${var.env}-ogenki-nat"
  router                             = google_compute_router.this.name
  region                             = var.region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"

  # Logging on so egress cost is attributable rather than a mystery line item.
  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }
}
```

- [ ] **Step 5: Write `outputs.tf`**

```hcl
output "network_id" {
  description = "VPC network ID, consumed by gke/init"
  value       = google_compute_network.this.id
}

output "network_name" {
  description = "VPC network name"
  value       = google_compute_network.this.name
}

output "nodes_subnetwork_id" {
  description = "Node subnetwork ID, consumed by gke/init"
  value       = google_compute_subnetwork.nodes.id
}

output "pods_range_name" {
  description = "Secondary range name for pod IPs"
  value       = google_compute_subnetwork.nodes.secondary_ip_range[0].range_name
}

output "services_range_name" {
  description = "Secondary range name for Service ClusterIPs"
  value       = google_compute_subnetwork.nodes.secondary_ip_range[1].range_name
}
```

- [ ] **Step 6: Validate, scan, apply**

Run:
```bash
cd opentofu/gcp/network
tofu init && tofu fmt -check && tofu validate
trivy config --exit-code=1 --ignorefile=../../../.trivyignore.yaml .
tofu apply -var-file=variables.tfvars
```
Expected: validate clean, trivy exit 0, apply succeeds. If trivy flags a finding, fix it — do not add an ignore entry without a comment explaining why.

- [ ] **Step 7: Verify Private Google Access is actually on**

Run:
```bash
gcloud compute networks subnets describe dev-ogenki-nodes --region europe-west1 \
  --format='yaml(privateIpGoogleAccess,secondaryIpRanges)'
```
Expected: `privateIpGoogleAccess: true` and both secondary ranges present.

- [ ] **Step 8: Commit**

```bash
git add opentofu/gcp/network
git commit -m "feat(gcp): VPC, subnet with pod/service secondary ranges, Cloud NAT

Private Google Access on so Google API traffic bypasses Cloud NAT billing.
CIDRs chosen to avoid the AWS VPC (10.0.0.0/16) and pod (100.64.0.0/16)
ranges — both clusters share one tailnet."
```

### Task 8: Cloud DNS private zone and Tailscale subnet router

**Files:**
- Create: `opentofu/gcp/network/dns.tf`, `opentofu/gcp/network/tailscale.tf`

- [ ] **Step 1: Write `dns.tf`**

```hcl
resource "google_dns_managed_zone" "private" {
  name        = replace(var.private_domain_name, ".", "-")
  dns_name    = "${var.private_domain_name}."
  description = "Private zone for GCP platform services"
  visibility  = "private"

  private_visibility_config {
    networks {
      network_url = google_compute_network.this.id
    }
  }

  labels = var.labels
}
```

- [ ] **Step 2: Write `tailscale.tf`**

The router advertises all three GCP ranges so the private control plane and pod network are reachable from the tailnet. `e2-small` mirrors the AWS subnet router's minimal sizing.

```hcl
resource "tailscale_tailnet_key" "subnet_router" {
  ephemeral     = false
  preauthorized = true
  reusable      = false
  tags          = ["tag:subnet-router"]
  description   = "GCP subnet router (${var.env})"
}

resource "google_service_account" "subnet_router" {
  account_id   = "${var.env}-ts-subnet-router"
  display_name = "Tailscale subnet router"
}

resource "google_compute_instance" "subnet_router" {
  name         = var.tailscale_config.subnet_router_name
  machine_type = var.tailscale_config.machine_type
  zone         = "${var.region}-b"
  labels       = var.labels

  # IP forwarding is REQUIRED for a subnet router; without it Tailscale
  # advertises the routes and every packet is silently dropped.
  can_ip_forward = true

  boot_disk {
    initialize_params {
      image = "debian-cloud/debian-12"
      type  = "pd-balanced"
      size  = 20
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.nodes.id
    # No access_config: no public IP. Egress goes via Cloud NAT.
  }

  metadata = {
    enable-oslogin = "TRUE"
  }

  metadata_startup_script = templatefile("${path.module}/scripts/subnet-router.sh.tftpl", {
    auth_key         = tailscale_tailnet_key.subnet_router.key
    advertise_routes = join(",", [var.node_cidr, var.pod_cidr, var.service_cidr])
    hostname         = var.tailscale_config.subnet_router_name
  })

  service_account {
    email  = google_service_account.subnet_router.email
    scopes = ["cloud-platform"]
  }
}
```

- [ ] **Step 3: Write the startup script template**

Create `opentofu/gcp/network/scripts/subnet-router.sh.tftpl`:

```bash
#!/usr/bin/env bash
set -euo pipefail

curl -fsSL https://tailscale.com/install.sh | sh

# Required for subnet routing; the kernel drops forwarded packets without these.
cat >/etc/sysctl.d/99-tailscale.conf <<'SYSCTL'
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
SYSCTL
sysctl -p /etc/sysctl.d/99-tailscale.conf

tailscale up \
  --authkey='${auth_key}' \
  --hostname='${hostname}' \
  --advertise-routes='${advertise_routes}' \
  --accept-dns=false
```

- [ ] **Step 4: Add the DNS zone output**

Append to `opentofu/gcp/network/outputs.tf`:

```hcl
output "private_dns_zone_name" {
  description = "Cloud DNS private zone name, consumed by external-dns later"
  value       = google_dns_managed_zone.private.name
}
```

- [ ] **Step 5: Apply and verify the routes are advertised**

Run:
```bash
cd opentofu/gcp/network
tofu fmt -check && tofu validate
trivy config --exit-code=1 --ignorefile=../../../.trivyignore.yaml .
tofu apply -var-file=variables.tfvars
```
Then approve the advertised routes in the Tailscale admin console (or via `tailscale set`), and verify:
```bash
tailscale status --json | jq -r '.Peer[] | select(.HostName|test("ogenki-gcp")) | .PrimaryRoutes'
```
Expected: `["10.10.0.0/16","100.65.0.0/16","10.11.0.0/20"]`

- [ ] **Step 6: Prove reachability into the GCP subnet**

Run: `ping -c 3 "$(gcloud compute instances describe ogenki-gcp --zone europe-west1-b --format='value(networkInterfaces[0].networkIP)')"`
Expected: replies. **If this fails, do not continue** — the private GKE endpoint in Task 9 will be unreachable and the failure will look like a cluster problem.

- [ ] **Step 7: Commit**

```bash
git add opentofu/gcp/network
git commit -m "feat(gcp): Cloud DNS private zone and Tailscale subnet router

Router advertises node/pod/service ranges into the existing tailnet, so the
private GKE endpoint is reachable without a public endpoint. No public IP;
egress via Cloud NAT. can_ip_forward is required or routes silently drop."
```

---

## Phase 3 — GKE cluster (stage 1)

### Task 9: GKE Standard cluster, static spot node pool, Workload Identity

**Files:**
- Create: `opentofu/gcp/gke/init/{versions,providers,backend,variables,data,main,iam,outputs}.tf`, `variables.tfvars`, `stack.tm.hcl`

- [ ] **Step 1: Write the stack plumbing**

`versions.tf` — same `required_providers` block as Task 6 Step 1, minus `tailscale`.

`providers.tf`:
```hcl
provider "google" {
  project = var.project_id
  region  = var.region
}
```

`backend.tf` — same as Task 6 Step 3 with `prefix = "gcp/gke/init"`.

`data.tf` — consume the network stack's state:
```hcl
data "terraform_remote_state" "network" {
  backend = "gcs"
  config = {
    bucket = "${var.project_id}-tfstate"
    prefix = "gcp/network"
  }
}
```

`stack.tm.hcl`:
```hcl
stack {
  name        = "GKE Cluster - Init"
  description = "GKE Standard cluster, static spot node pool, Workload Identity, Gateway API CRDs"
  id          = "gcp-gke-init"

  after = [
    "/opentofu/gcp/network"
  ]

  tags = [
    "gcp",
    "gke",
    "kubernetes",
    "infrastructure"
  ]
}
```

- [ ] **Step 2: Write `variables.tf`**

```hcl
variable "project_id" {
  description = "GCP project ID"
  type        = string
}

variable "project_number" {
  description = "GCP project NUMBER (not ID). Required for the Workload Identity principal string, where projects/ takes the number and workloadIdentityPools/ takes the ID."
  type        = string
}

variable "region" {
  description = "GCP region"
  type        = string
  default     = "europe-west1"
}

variable "zone" {
  description = "Zone for the cluster and its static node pool. Single zone mirrors the AWS single-subnet choice and avoids cross-zone egress charges."
  type        = string
  default     = "europe-west1-b"
}

variable "cluster_name" {
  description = "GKE cluster name"
  type        = string
  default     = "gcp-mycluster-0"
}

variable "control_plane_cidr" {
  description = "Control-plane CIDR. GKE requires exactly /28."
  type        = string
  default     = "172.16.0.0/28"
}

variable "node_image_type" {
  description = "Node image. Must match what the ComputeClass plan pins, or autoscaled nodes differ in kernel capability from the static pool."
  type        = string
  default     = "COS_CONTAINERD"
}

variable "node_machine_type" {
  description = "Static pool machine type. A GKE node pool accepts ONE type, so the AWS 6-way spot diversification does not port."
  type        = string
  default     = "e2-standard-4"
}
```

- [ ] **Step 3: Write `main.tf`**

Four things here are load-bearing and each has a comment saying why, because every one of them is a silent-failure class:

```hcl
locals {
  net = data.terraform_remote_state.network.outputs
}

resource "google_container_cluster" "this" {
  name     = var.cluster_name
  location = var.zone

  network    = local.net.network_id
  subnetwork = local.net.nodes_subnetwork_id

  # Alias IPs: Cilium runs ipam.mode=kubernetes and takes each node's
  # spec.podCIDR from here, letting the GCP VPC route pod traffic natively.
  ip_allocation_policy {
    cluster_secondary_range_name  = local.net.pods_range_name
    services_secondary_range_name = local.net.services_range_name
  }

  # Dataplane V2 is DELIBERATELY NOT ENABLED (ADR-0005). It is opt-in on
  # Standard clusters and CREATE-TIME ONLY. Enabling it would replace our
  # Cilium with Google's, which has no CiliumGatewayClassConfig CRD and no
  # io.cilium/gateway-controller -- both Tailscale gateways would break.
  # Do not add datapath_provider here.

  private_cluster_config {
    enable_private_nodes    = true
    enable_private_endpoint = true
    master_ipv4_cidr_block  = var.control_plane_cidr
  }

  master_authorized_networks_config {
    cidr_blocks {
      cidr_block   = local.net.node_cidr
      display_name = "tailnet-via-subnet-router"
    }
  }

  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }

  # Cost lever: VictoriaLogs and VictoriaMetrics already collect this. The GKE
  # defaults bill Cloud Logging/Monitoring for a duplicate pipeline nobody reads.
  logging_config {
    enable_components = []
  }

  monitoring_config {
    enable_components = []
  }

  # We manage the node pool separately so its config is explicit and mutable.
  remove_default_node_pool = true
  initial_node_count       = 1

  deletion_protection = false
}

resource "google_container_node_pool" "static" {
  name     = "static"
  cluster  = google_container_cluster.this.name
  location = var.zone

  node_count = 2

  node_config {
    machine_type = var.node_machine_type
    image_type   = var.node_image_type

    # Spot, matching the EKS bootstrap node group (capacity_type = "SPOT").
    spot = true

    disk_type    = "pd-balanced"
    disk_size_gb = 50

    # REQUIRED for self-managed Cilium: without this taint, pods schedule onto
    # a node before the Cilium agent is ready and fail with
    # FailedCreatePodSandBox. Cilium removes the taint once it is up.
    taint {
      key    = "node.cilium.io/agent-not-ready"
      value  = "true"
      effect = "NO_SCHEDULE"
    }

    workload_metadata_config {
      mode = "GKE_METADATA"
    }

    oauth_scopes = ["https://www.googleapis.com/auth/cloud-platform"]
  }

  management {
    auto_repair  = true
    auto_upgrade = true
  }
}
```

Add `node_cidr` to the network stack's outputs if it is not already exported — `master_authorized_networks_config` above needs it:

```hcl
output "node_cidr" {
  description = "Node subnet CIDR, used for GKE master authorized networks"
  value       = google_compute_subnetwork.nodes.ip_cidr_range
}
```

- [ ] **Step 4: Write `iam.tf` — Crossplane's own Workload Identity binding**

This is the chicken-and-egg the design calls out: Crossplane cannot create the binding that grants Crossplane access, so it must be bootstrapped here. **The `GCPWorkloadIdentity` plan (slice 5) is blocked without it.**

```hcl
# Crossplane's own GCP identity. Bootstrapped in OpenTofu because Crossplane
# cannot create the binding that grants itself access -- the same reason the AWS
# side bootstraps Crossplane's Pod Identity in eks/init.
#
# NOTE the two different project identifiers: projects/ takes the project
# NUMBER, workloadIdentityPools/ takes the project ID. Reversed, the API accepts
# the binding and it simply never matches -- a permission error pointing nowhere.
locals {
  crossplane_principal = join("", [
    "principal://iam.googleapis.com/projects/${var.project_number}",
    "/locations/global/workloadIdentityPools/${var.project_id}.svc.id.goog",
    "/subject/ns/crossplane-system/sa/crossplane",
  ])
}

# Additive binding. NEVER use google_project_iam_policy or
# google_project_iam_binding here -- both are authoritative and would delete
# every binding they do not manage, including break-glass human access.
resource "google_project_iam_member" "crossplane" {
  project = var.project_id
  role    = "roles/editor"
  member  = local.crossplane_principal
}
```

> **Scope note:** `roles/editor` is a bootstrap-only breadth. Narrowing it to the specific roles Crossplane needs belongs to the `GCPWorkloadIdentity` plan, which is where the permission model is designed. State that in the code comment as written above, and open a follow-up issue — do not leave the breadth undocumented.

- [ ] **Step 5: Write `outputs.tf`**

```hcl
output "cluster_name" {
  description = "GKE cluster name"
  value       = google_container_cluster.this.name
}

output "cluster_endpoint" {
  description = "Private control-plane endpoint, consumed by gke/configure"
  value       = google_container_cluster.this.endpoint
}

output "cluster_ca_certificate" {
  description = "Cluster CA, consumed by gke/configure"
  value       = google_container_cluster.this.master_auth[0].cluster_ca_certificate
  sensitive   = true
}

output "workload_pool" {
  description = "Workload Identity pool, consumed by the GCPWorkloadIdentity composition"
  value       = google_container_cluster.this.workload_identity_config[0].workload_pool
}
```

- [ ] **Step 6: Write `variables.tfvars`**

```hcl
project_id     = "<project-id-from-task-2>"
project_number = "<project-NUMBER-from-task-2-step-3>"
region         = "europe-west1"
zone           = "europe-west1-b"
cluster_name   = "gcp-mycluster-0"
```

- [ ] **Step 7: Validate, scan, apply**

Run:
```bash
cd opentofu/gcp/gke/init
tofu init && tofu fmt -check && tofu validate
trivy config --exit-code=1 --ignorefile=../../../../.trivyignore.yaml .
tofu apply -var-file=variables.tfvars
```
Expected: cluster and node pool created. This takes roughly 10 minutes.

- [ ] **Step 8: Verify the four load-bearing settings**

Run:
```bash
gcloud container clusters describe gcp-mycluster-0 --zone europe-west1-b \
  --format='yaml(networkConfig.datapathProvider,privateClusterConfig.enablePrivateEndpoint,workloadIdentityConfig,loggingConfig,monitoringConfig)'
gcloud container node-pools describe static --cluster gcp-mycluster-0 --zone europe-west1-b \
  --format='yaml(config.spot,config.imageType,config.taints,locations)'
```
Expected: `datapathProvider` absent or not `ADVANCED_DATAPATH`; `enablePrivateEndpoint: true`; a `workloadPool`; logging and monitoring components **empty**; and on the pool `spot: true`, the pinned `imageType`, the `node.cilium.io/agent-not-ready` taint, one zone.

- [ ] **Step 9: Confirm the private endpoint is reachable over the tailnet**

Run:
```bash
gcloud container clusters get-credentials gcp-mycluster-0 --zone europe-west1-b --internal-ip
kubectl get nodes
```
Expected: 2 nodes, both `Ready`... **or `NotReady` — which is correct at this point**, because no CNI is installed yet. What matters is that the API server answers. If the command times out, the tailnet route is the problem, not the cluster.

- [ ] **Step 10: Commit**

```bash
git add opentofu/gcp/network/outputs.tf opentofu/gcp/gke/init
git commit -m "feat(gcp): GKE Standard cluster with static spot node pool

Dataplane V2 deliberately not enabled (ADR-0005) -- it is create-time only and
would replace Cilium with Google's, breaking both Tailscale gateways. Private
endpoint only, reachable over the tailnet. Workload Cloud Logging/Monitoring
disabled: VictoriaLogs and VictoriaMetrics already do that job. Nodes tainted
node.cilium.io/agent-not-ready so pods cannot land before the CNI is ready.
Bootstraps Crossplane's own WIF binding, which slice 5 is blocked without."
```

---

## Phase 4 — Cilium and Flux (stage 2)

### Task 10: Forked GCP Cilium values

**Files:**
- Create: `opentofu/gcp/gke/init/helm_values/cilium.yaml`

- [ ] **Step 1: Read the AWS values to diverge from**

Run: `cat opentofu/eks/init/helm_values/cilium.yaml`
Expected: the file with `ipam.mode: eni`, an `eni:` block, `encryption`, `routingMode: native`, `kubeProxyReplacement`, `gatewayAPI`, `hubble`.

- [ ] **Step 2: Write the GCP values**

The header comment is not decoration — the fork is a deliberate decision and the next person needs to know which keys diverge and why.

```yaml
# Cilium Helm values — GCP / GKE
#
# FORKED from opentofu/eks/init/helm_values/cilium.yaml rather than templated
# from a shared base. With two clouds and ~8 divergent keys, duplication is
# cheaper than a merge mechanism that hides what Cilium actually receives --
# and "we do not fully understand what Cilium does on an unsupported path" is
# precisely the risk being managed here. Revisit at cloud number three.
#
# `cilium_version` stays a SHARED global in opentofu/config.tm.hcl, so both
# clouds upgrade Cilium together. Only these keys differ:
#
#   ipam.mode          eni -> kubernetes   (host-scope from node spec.podCIDR;
#                                           GKE alias IP ranges route natively)
#   eni: block         REMOVED             (no AWS ENI concept on GCP)
#   encryption         REMOVED             (see below)
#   k8sServiceHost     set via --set in gke/configure (private endpoint)
#
# WireGuard is intentionally ABSENT. On AWS it is load-bearing, working around
# cilium#43493 -- but that bug is the BPF ipcache `hastunnel` flag under ENI
# mode WITH prefix delegation. ipam.mode=kubernetes does not take that path.
# Verified by the Phase 1 gate: 100/100 HTTP 200 across nodes with encryption
# unset. Do not add WireGuard here without new evidence.

ipam:
  mode: kubernetes

routingMode: native

kubeProxyReplacement: true

gatewayAPI:
  enabled: true

hubble:
  enabled: true
  relay:
    enabled: true
  ui:
    enabled: true
  metrics:
    enableOpenMetrics: true

operator:
  replicas: 2
  # Restarts pods not managed by Cilium, so no manual restart step is needed.
  unmanagedPodWatcher:
    restart: true

envoy:
  enabled: true
```

> Copy across any `resources`, `prometheus`, `bpf` or `hubble.metrics.enabled` blocks present in the AWS file that are not cloud-specific, so the two clusters observe the same things. Do **not** copy `eni:`, `encryption:`, or anything referencing `karpenter.sh` or `aws:eks`.

- [ ] **Step 3: Verify it is valid YAML and Helm accepts it**

Run:
```bash
helm repo add cilium https://helm.cilium.io 2>/dev/null; helm repo update cilium
helm template cilium cilium/cilium --version 1.20.0 -n kube-system \
  -f opentofu/gcp/gke/init/helm_values/cilium.yaml >/dev/null && echo TEMPLATE_OK
```
Expected: `TEMPLATE_OK`

- [ ] **Step 4: Confirm no AWS-isms leaked in**

Run: `grep -nE 'eni|wireguard|encryption|aws|karpenter' opentofu/gcp/gke/init/helm_values/cilium.yaml`
Expected: matches **only** inside the header comment block. Any match in an actual key is a bug.

- [ ] **Step 5: Commit**

```bash
git add opentofu/gcp/gke/init/helm_values/cilium.yaml
git commit -m "feat(gcp): fork Cilium Helm values for GKE

ipam.mode=kubernetes, no eni block, no WireGuard. cilium_version stays shared
so both clouds upgrade together. Header documents every divergent key."
```

### Task 11: Gateway API CRDs

**Files:**
- Create: `opentofu/gcp/gke/init/gateway_api.tf`

> **Rewritten 2026-08-19 after this exact task's AWS equivalent took the cluster down.**
>
> `cilium-operator` probes for the Gateway API CRDs **once, at startup**. If any are missing it logs
> `Required GatewayAPI resources are not found`, disables its Gateway API controller and **never
> retries** — the pod stays `Running` and `Ready`, nothing crashes, nothing alerts. The symptom
> surfaces four layers away: `GatewayClass ACCEPTED=Unknown` → Gateways never `Programmed` →
> HTTPRoutes with no `status.parents` at all → every `App` claim owning a route stuck `READY=False`.
> Worse, only the *leader* replica logs the error, so a one-pod `kubectl logs` looks clean.
>
> On AWS this fired on 2026-08-19 over a **two-second** gap: the operator probed at 11:26:44 and Flux
> created `backendtlspolicies` at 11:26:46. Cilium 1.20 requires `BackendTLSPolicy`; the hand-written
> CRD list in `eks/configure` had eight entries and not that one. Fixed in #1781.
>
> **The lesson for GCP: do not enumerate the CRDs.** Apply the whole release bundle, so a CRD Cilium
> starts requiring in a later version cannot be silently missing. The AWS side cannot switch cheaply
> — its list is `count`-indexed, so restructuring would destroy and recreate live CRDs — but GCP is
> greenfield and should start correct.

- [ ] **Step 1: Read the AWS pin and the trap it encodes**

```bash
grep -n "gateway_api_crds_urls" -A 30 opentofu/eks/configure/locals.tf
grep -rn "gateway_api_version" opentofu/eks/configure/variables.tf
grep -n "gateway_api_crds" opentofu/eks/configure/main.tf
```

Expected: a URL list with a comment block explaining the startup probe, `depends_on` from the Cilium
`helm_release`, and a `gateway_api_version` variable. Take **only the version** from here — the
enumeration is the thing this task deliberately does not copy.

The version must equal `flux/sources/gitrepo-gateway-api.yaml`'s `ref.tag`, which is the cross-cloud
invariant: one Gateway API version on both clouds.

- [ ] **Step 2: Write `gateway_api.tf`**

Use the **experimental** channel bundle. Two reasons, and the second is not obvious:

1. AWS runs experimental (`crds/base/kustomization-gateway-api.yaml` applies
   `./config/crd/experimental`, and the installed CRDs carry
   `gateway.networking.k8s.io/channel: experimental`). Different channels across clouds means a route
   using an experimental field works on AWS and fails on GCP — a divergence that would surface as an
   application bug, not a platform one.
2. Cilium's 1.19 upgrade notes call for the experimental TLSRoute specifically.

```hcl
# The whole bundle, not a hand-picked list. cilium-operator probes for these CRDs
# exactly once at startup and permanently disables Gateway API if any are absent
# (see the AWS incident referenced in the plan). Enumerating them is what failed
# there; the bundle cannot drift from what Cilium expects.
#
# Experimental channel to match the AWS side -- one Gateway API surface on both
# clouds. Version must equal flux/sources/gitrepo-gateway-api.yaml's ref.tag.
data "http" "gateway_api_crds" {
  url = "https://github.com/kubernetes-sigs/gateway-api/releases/download/${var.gateway_api_version}/experimental-install.yaml"
}

data "kubectl_file_documents" "gateway_api_crds" {
  content = data.http.gateway_api_crds.response_body
}

# for_each, NOT count: keyed by manifest identity, so a future Gateway API release
# adding a CRD appends instead of shifting every index. A count-indexed list would
# make tofu destroy and recreate live CRDs on any reordering, taking every Gateway
# and HTTPRoute with them.
resource "kubectl_manifest" "gateway_api_crds" {
  for_each  = data.kubectl_file_documents.gateway_api_crds.manifests
  yaml_body = each.value

  # Flux also reconciles these from the gateway-api GitRepository; whoever applies
  # second must not fight the first.
  server_side_apply = true
  force_conflicts   = true
}
```

`response_body` rather than the deprecated `body` attribute (#1772).

Add to `variables.tf`:

```hcl
variable "gateway_api_version" {
  description = "Gateway API release. Must match flux/sources/gitrepo-gateway-api.yaml ref.tag so both clouds run one version."
  type        = string
  default     = "<version-from-step-1>"
}
```

- [ ] **Step 3: Verify the bundle actually resolves before wiring Cilium to it**

A 404 here fails the apply *after* the cluster exists, which is an expensive way to find a typo.

```bash
curl -fsSL -o /dev/null -w "%{http_code}
" \
  "https://github.com/kubernetes-sigs/gateway-api/releases/download/<version>/experimental-install.yaml"
```

Expected: `200`.

- [ ] **Step 4: Confirm Cilium depends on this**

Task 12 wires `helm_release.cilium`'s `depends_on` to `kubectl_manifest.gateway_api_crds`. That
dependency is necessary and **not sufficient** — it was already correct on AWS when the outage
happened. What made it insufficient was an incomplete list, which Step 2 removes by construction.

- [ ] **Step 5: Commit**

```bash
git add opentofu/gcp/gke/init
git commit -m "feat(gcp): install the full Gateway API CRD bundle before Cilium"
```

**If Gateway API is inert after the cluster comes up** — GatewayClass `Accepted=Unknown`, Gateways
`Waiting for controller` — check every operator replica, then restart:

```bash
kubectl logs -n kube-system -l io.cilium/app=operator | grep "Required GatewayAPI resources"
kubectl rollout restart -n kube-system deployment/cilium-operator
```

Recovery on AWS took under 20 seconds. If a restart fixes it, a CRD arrived late and Step 2's bundle
did not cover it — record which one.

### Task 12: Configure stack — Cilium then Flux

**Files:**
- Create: `opentofu/gcp/gke/configure/{versions,providers,backend,variables,data,locals,main}.tf`, `stack.tm.hcl`

- [ ] **Step 1: Write the plumbing**

`data.tf`:
```hcl
data "terraform_remote_state" "gke" {
  backend = "gcs"
  config = {
    bucket = "${var.project_id}-tfstate"
    prefix = "gcp/gke/init"
  }
}

data "google_client_config" "this" {}
```

`locals.tf`:
```hcl
locals {
  gke          = data.terraform_remote_state.gke.outputs
  api_endpoint = local.gke.cluster_endpoint
}
```

`providers.tf` — note `helm` and `kubernetes` authenticate with a short-lived token from `google_client_config`:
```hcl
provider "google" {
  project = var.project_id
  region  = var.region
}

provider "helm" {
  kubernetes {
    host                   = "https://${local.gke.cluster_endpoint}"
    token                  = data.google_client_config.this.access_token
    cluster_ca_certificate = base64decode(local.gke.cluster_ca_certificate)
  }
}

provider "kubectl" {
  host                   = "https://${local.gke.cluster_endpoint}"
  token                  = data.google_client_config.this.access_token
  cluster_ca_certificate = base64decode(local.gke.cluster_ca_certificate)
  load_config_file       = false
}
```

`stack.tm.hcl`:
```hcl
stack {
  name        = "GKE Cluster - Configure"
  description = "Install Cilium and Flux on the GKE cluster"
  id          = "gcp-gke-configure"

  after = [
    "/opentofu/gcp/gke/init"
  ]

  tags = [
    "gcp",
    "gke",
    "kubernetes",
    "infrastructure"
  ]
}
```

- [ ] **Step 2: Write `main.tf`**

Keep this stack **`local-exec`-free**, as `eks/configure/main.tf` is, on purpose.

```hcl
# GKE Configure - Stage 2
# Dependency chain: gateway_api_crds -> cilium -> flux_operator -> flux_instance
#
# Simpler than the EKS equivalent: there is no VPC-CNI or kube-proxy DaemonSet
# to disable first. Cilium's cni.exclusive displaces GKE's netd CNI config
# directly (verified by the Phase 1 gate), and kubeProxyReplacement handles
# kube-proxy.

resource "kubectl_manifest" "gateway_api_crds" {
  for_each = toset(compact(split("---", data.http.gateway_api_crds.response_body)))

  yaml_body         = each.value
  server_side_apply = true
  force_conflicts   = true
}

resource "helm_release" "cilium" {
  depends_on = [kubectl_manifest.gateway_api_crds]

  name             = "cilium"
  repository       = "https://helm.cilium.io"
  chart            = "cilium"
  version          = var.cilium_version
  namespace        = "kube-system"
  create_namespace = false

  values = [file("${path.module}/../init/helm_values/cilium.yaml")]

  set = [
    {
      name  = "cluster.name"
      value = var.cluster_name
    },
    {
      # Private endpoint. kubeProxyReplacement needs this to reach the API
      # server before kube-proxy is replaced.
      name  = "k8sServiceHost"
      value = local.api_endpoint
    },
    {
      name  = "k8sServicePort"
      value = "443"
    },
  ]

  wait    = true
  timeout = 600
}

resource "helm_release" "flux_operator" {
  depends_on = [helm_release.cilium]

  name             = "flux-operator"
  repository       = "oci://ghcr.io/controlplaneio-fluxcd/charts"
  chart            = "flux-operator"
  version          = var.flux_operator_version
  namespace        = "flux-system"
  create_namespace = true

  wait    = true
  timeout = 600
}

resource "helm_release" "flux_instance" {
  depends_on = [helm_release.flux_operator]

  name       = "flux"
  repository = "oci://ghcr.io/controlplaneio-fluxcd/charts"
  chart      = "flux-instance"
  version    = var.flux_instance_version
  namespace  = "flux-system"

  values = [file("${path.module}/../init/helm_values/flux-instance.yaml")]

  set = [
    {
      name  = "instance.sync.url"
      value = var.flux_sync_repository_url
    },
    {
      name  = "instance.sync.ref"
      value = var.flux_git_ref
    },
    {
      name  = "instance.sync.path"
      value = "clusters/gcp-mycluster-0"
    },
  ]

  wait    = true
  timeout = 600
}
```

- [ ] **Step 3: Write the Flux Instance values**

Create `opentofu/gcp/gke/init/helm_values/flux-instance.yaml` by copying the AWS one and changing **only** the storage class — `gp3` does not exist on GCP:

Run: `cp opentofu/eks/init/helm_values/flux-instance.yaml opentofu/gcp/gke/init/helm_values/flux-instance.yaml`

Then change `storage.class` from `gp3` to `standard-rwo`, and add this header:

```yaml
# Flux Instance values — GCP / GKE
#
# Copied from opentofu/eks/init/helm_values/flux-instance.yaml. The ONLY
# intended divergence is storage.class: gp3 (AWS EBS) -> standard-rwo (GCP PD).
# Keep every other value in sync with the AWS file; if you change one, change
# both, or the two clusters' Flux behaviour silently drifts.
```

- [ ] **Step 4: Write `variables.tf`**

```hcl
variable "project_id" {
  description = "GCP project ID"
  type        = string
}

variable "region" {
  description = "GCP region"
  type        = string
  default     = "europe-west1"
}

variable "cluster_name" {
  description = "GKE cluster name"
  type        = string
  default     = "gcp-mycluster-0"
}

variable "cilium_version" {
  description = "Cilium chart version. Passed from the shared terramate global so both clouds upgrade together."
  type        = string
}

variable "flux_operator_version" {
  description = "Flux Operator chart version, from the shared terramate global."
  type        = string
}

variable "flux_instance_version" {
  description = "Flux Instance chart version, from the shared terramate global."
  type        = string
}

variable "flux_sync_repository_url" {
  description = "Git repository Flux syncs from"
  type        = string
}

variable "flux_git_ref" {
  description = "Git ref Flux syncs. Override with TF_VAR_flux_git_ref for branch testing, as on AWS."
  type        = string
  default     = "refs/heads/main"
}

variable "gateway_api_version" {
  description = "Gateway API release, must match the AWS stack."
  type        = string
}
```

- [ ] **Step 5: Validate**

Run:
```bash
cd opentofu/gcp/gke/configure
tofu init && tofu fmt -check && tofu validate
trivy config --exit-code=1 --ignorefile=../../../../.trivyignore.yaml .
```
Expected: validate clean, trivy exit 0. **Do not apply yet** — the Flux tree it syncs does not exist until Task 14.

- [ ] **Step 6: Commit**

```bash
git add opentofu/gcp/gke/configure opentofu/gcp/gke/init/helm_values/flux-instance.yaml
git commit -m "feat(gcp): configure stack installing Cilium then Flux

No VPC-CNI/kube-proxy disable step is needed on GKE -- cni.exclusive displaces
netd and kubeProxyReplacement handles kube-proxy. Stack is local-exec-free,
matching eks/configure. Flux syncs clusters/gcp-mycluster-0."
```

### Task 13: Terramate two-stage deploy scripts

**Files:**
- Create: `opentofu/gcp/gke/init/workflows.tm.hcl`

- [ ] **Step 1: Write the scripts, mirroring the EKS pattern**

Note there is **no stage 3** — `eks-recycle-bootstrap-nodes.sh` exists only for ENI prefix-delegation ordering and has no GCP analogue.

```hcl
# GCP GKE-specific Terramate scripts
# Two-stage deployment:
# Stage 1 (this stack): GKE cluster, static spot node pool, Workload Identity, Gateway API CRDs
# Stage 2 (configure stack): Cilium -> Flux Operator -> Flux Instance
#
# There is no stage 3: the EKS equivalent recycles bootstrap nodes whose ENIs
# predate Cilium, which is specific to ENI prefix delegation.
#
# Usage:
#   cd opentofu/gcp/gke/init
#   terramate script run deploy
#   TF_VAR_flux_git_ref='refs/heads/feature-branch' terramate script run deploy

script "deploy" {
  name        = "GKE Full Deployment"
  description = "Deploy GKE cluster (Stage 1) and Cilium + Flux (Stage 2)"

  job {
    name        = "stage1-cluster"
    description = "Deploy GKE cluster, static node pool, Workload Identity"
    commands = [
      [global.provisioner, "init"],
      [global.provisioner, "validate"],
      ["trivy", "config", "--exit-code=1", "--ignorefile=./.trivyignore.yaml", "."],
      [global.provisioner, "apply", "-auto-approve", "-var-file=variables.tfvars"],
    ]
  }

  job {
    name        = "stage2-cilium-and-flux"
    description = "Install Cilium and Flux"
    commands = [
      ["bash", "-c", "cd ../configure && ${global.provisioner} init"],
      ["bash", "-c", "cd ../configure && ${global.provisioner} apply -auto-approve -var-file=variables.tfvars -var='cilium_version=${global.cilium_version}' -var='flux_operator_version=${global.flux_operator_version}' -var='flux_instance_version=${global.flux_instance_version}' -var='flux_sync_repository_url=${global.flux_sync_repository_url}' $${TF_VAR_flux_git_ref:+-var=\"flux_git_ref=$${TF_VAR_flux_git_ref}\"}"],
    ]
  }
}

script "preview" {
  name        = "GKE Deployment Preview"
  description = "Preview GKE deployment changes"

  job {
    commands = [
      [global.provisioner, "init"],
      [global.provisioner, "validate"],
      ["trivy", "config", "--exit-code=1", "--ignorefile=./.trivyignore.yaml", "."],
      [global.provisioner, "plan", "-out=out.tfplan", "-var-file=variables.tfvars", {
        sync_preview   = true
        tofu_plan_file = "out.tfplan"
      }],
    ]
  }
}

script "destroy" {
  name        = "GKE Full Destroy"
  description = "Destroy Cilium + Flux (Stage 2) then the cluster (Stage 1)"

  job {
    name        = "stage2-destroy-addons"
    description = "Destroy Cilium and Flux"
    commands = [
      ["bash", "${terramate.root.path.fs.absolute}/scripts/terramate-destroy-confirm.sh"],
      ["bash", "-c", "cd ../configure && ${global.provisioner} init"],
      ["bash", "-c", "cd ../configure && ${global.provisioner} destroy -auto-approve -var-file=variables.tfvars -var='cilium_version=${global.cilium_version}' -var='flux_operator_version=${global.flux_operator_version}' -var='flux_instance_version=${global.flux_instance_version}' -var='flux_sync_repository_url=${global.flux_sync_repository_url}'"],
    ]
  }

  job {
    name        = "stage1-destroy-cluster"
    description = "Destroy the GKE cluster"
    commands = [
      [global.provisioner, "destroy", "-auto-approve", "-var-file=variables.tfvars"],
    ]
  }
}
```

- [ ] **Step 2: Verify Terramate parses and the scripts are listed**

Run:
```bash
terramate list
terramate script list | grep -A2 -i gke
```
Expected: both GCP stacks listed, `deploy`/`preview`/`destroy` present.

- [ ] **Step 3: Commit**

```bash
git add opentofu/gcp/gke/init/workflows.tm.hcl
git commit -m "feat(gcp): terramate two-stage deploy scripts for GKE

Mirrors eks/init. No stage 3 -- bootstrap-node recycling is ENI-specific."
```

---

## Phase 5 — Flux tree

### Task 14: Minimum viable `clusters/gcp-mycluster-0/`

**Files:**
- Create: `clusters/gcp-mycluster-0/**`

- [ ] **Step 1: Inspect the AWS cluster tree to mirror its shape**

Run:
```bash
find clusters/mycluster-0 -type f | sort
cat clusters/mycluster-0/namespaces.yaml
```
Expected: the Kustomization set (`namespaces`, `crds`, `flux/`, `infrastructure/`, `security/`, `observability/`, `tooling.yaml`, `apps.yaml`, `llm-platform.yaml`) and the dependency ordering between them.

- [ ] **Step 2: Create the minimum viable set**

Create only what a bare working cluster needs, in the constitution's dependency order (Namespaces -> CRDs -> ...). Start with `namespaces` and `crds` Kustomizations copied from the AWS tree with paths repointed, and **nothing else**.

**Explicitly exclude** — these are AWS-only and would fail or waste money on GCP:
- `aws-load-balancer-controller`
- `aws-efs-csi-driver`
- `karpenter`, `karpenter-nodepools`, `karpenter-nodepools-gpu`
- `runtimeclass-nvidia` (Bottlerocket-specific)
- `llm-platform.yaml` (out of scope; also suspended on AWS)

- [ ] **Step 3: Verify nothing AWS-specific leaked in**

Run: `grep -rniE 'aws|eks|karpenter|efs|\bs3\b|route53' clusters/gcp-mycluster-0/ || echo CLEAN`
Expected: `CLEAN`. Any match is either a mistake or needs a comment saying why it is deliberate.

- [ ] **Step 4: Verify the repo still renders and validates**

Run: `./scripts/validate-manifests.sh`
Expected: exit 0, and the report shows **`Invalid: 0, Skipped: 0`**. A skipped resource is an unvalidated one — `Skipped: 0` is part of the claim, not decoration.

- [ ] **Step 5: Confirm the AWS tree is untouched**

Run: `git status --short clusters/mycluster-0/ && git diff --stat clusters/mycluster-0/`
Expected: **no output from either.** If there is any, revert it — this plan is additive.

- [ ] **Step 6: Commit**

```bash
git add clusters/gcp-mycluster-0
git commit -m "feat(gcp): add clusters/gcp-mycluster-0 Flux tree

New sibling of clusters/mycluster-0; no existing AWS file is moved or changed.
Excludes aws-load-balancer-controller, aws-efs-csi-driver, Karpenter and
runtimeclass-nvidia -- all AWS-specific."
```

### Task 15: Deploy stage 2 and reach a reconciling cluster

**Files:** none (deployment)

- [ ] **Step 1: Push the branch so Flux can sync it**

```bash
git push -u origin feat/gcp-support-specs
```

- [ ] **Step 2: Deploy stage 2 against the branch**

Run:
```bash
cd opentofu/gcp/gke/init
TF_VAR_flux_git_ref='refs/heads/feat/gcp-support-specs' terramate script run deploy
```
Expected: stage 1 reports no changes (already applied in Task 9), stage 2 installs Cilium then Flux.

- [ ] **Step 3: Verify Cilium came up and cleared the taint**

Run:
```bash
kubectl -n kube-system rollout status ds/cilium --timeout=5m
kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium status --brief
kubectl get nodes -o json | jq -r '.items[] | "\(.metadata.name) taints=\([.spec.taints[]?.key] | join(","))"'
```
Expected: rollout complete, `cilium status` OK, and **no** `node.cilium.io/agent-not-ready` remaining on any node.

- [ ] **Step 4: Verify Flux is reconciling**

Run:
```bash
flux get kustomizations -A
flux get helmreleases -A
```
Expected: every Kustomization and HelmRelease `Ready=True`. If a Kustomization is stuck, run `flux logs --level=error --all-namespaces` before changing anything — and check network policies first, since timeouts here are usually policy, not Flux.

- [ ] **Step 5: Commit any fixes**

If the deploy required manifest fixes, commit them individually with messages naming the specific failure, not "fix flux".

---

## Phase 6 — Verification and documentation

### Task 16: Verify the cluster foundation criteria

**Files:** none (evidence gathering)

- [ ] **Step 1: Criteria 1, 8 — Cilium healthy, Hubble observing**

Run:
```bash
kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium status --wait
kubectl -n kube-system get pods -l k8s-app=cilium -o json | jq -r '.items[] | "\(.metadata.name) restarts=\([.status.containerStatuses[].restartCount]|add)"'
hubble observe --verdict DROPPED --last 50
```
Expected: all OK, 0 restarts on every agent, and Hubble returns output (an empty result is acceptable only if you can also show a non-empty `hubble observe --last 50`).

- [ ] **Step 2: Criterion 2 — netd still displaced on the real cluster**

Repeat Task 4 Step 4 against `gcp-mycluster-0`. The gate proved it on a throwaway cluster with `helm install`; this proves it with the real values file and the real node image.

- [ ] **Step 3: Criterion 3 — cross-node L7, no WireGuard**

Repeat Task 4 Step 6 against `gcp-mycluster-0`, then confirm encryption really is off:
```bash
kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium status | grep -i encryption
```
Expected: `100 200`, and encryption reported as `Disabled`.

- [ ] **Step 4: Criteria 5, 6 — private endpoint over tailnet, no CIDR overlap**

Run:
```bash
gcloud container clusters describe gcp-mycluster-0 --zone europe-west1-b \
  --format='value(privateClusterConfig.enablePrivateEndpoint)'
kubectl get nodes
tailscale status --json | jq -r '.Peer[] | select(.PrimaryRoutes != null) | "\(.HostName): \(.PrimaryRoutes|join(", "))"'
```
Expected: `True`; `kubectl` works; and the advertised route list contains no CIDR appearing twice across the AWS and GCP routers.

- [ ] **Step 5: Criteria 9, 10 — cost posture**

Run:
```bash
gcloud container node-pools describe static --cluster gcp-mycluster-0 --zone europe-west1-b \
  --format='yaml(config.spot,config.imageType,locations)'
gcloud container clusters describe gcp-mycluster-0 --zone europe-west1-b \
  --format='yaml(loggingConfig,monitoringConfig)'
gcloud compute networks subnets describe dev-ogenki-nodes --region europe-west1 \
  --format='value(privateIpGoogleAccess)'
```
Expected: `spot: true`, one zone, logging/monitoring components **empty**, `True`.

- [ ] **Step 6: Criterion 7 — idempotent re-deploy**

Run:
```bash
cd opentofu/gcp/network && tofu plan -var-file=variables.tfvars -detailed-exitcode; echo "network exit=$?"
cd ../gke/init && tofu plan -var-file=variables.tfvars -detailed-exitcode; echo "init exit=$?"
```
Expected: `exit=0` for both (exit 2 means changes — investigate the drift rather than applying it away).

- [ ] **Step 7: Gateway API is actually wired, not merely installed**

Cheap, and the one failure this plan has already seen in production. A Gateway API that was disabled
at operator startup looks completely healthy from the Cilium side — `cilium status` is fine, the
DaemonSet is fine, the operator is `Running`.

```bash
kubectl get gatewayclass                        # ACCEPTED must be True, not Unknown
kubectl logs -n kube-system -l io.cilium/app=operator \
  | grep -c "Required GatewayAPI resources"     # must be 0, across ALL replicas
```

`ACCEPTED=Unknown` or a non-zero count means a CRD was missing at startup: restart the operator to
recover, then fix Task 11's bundle so the next build does not repeat it.

- [ ] **Step 8: Record every result**

Write the actual command output into `docs/gcp-bootstrap.md` (created in Task 20) under a "Verification evidence" section, with the date and cluster version. Prose is not evidence; numbers and exit codes are.

### Task 17: Confirm the AWS blast radius is zero

**Files:** none

- [ ] **Step 1: Diff every AWS path this plan must not have touched**

Run:
```bash
git diff --stat origin/main...HEAD -- \
  opentofu/network opentofu/eks opentofu/openbao opentofu/llm-platform \
  clusters/mycluster-0 infrastructure security observability tooling apps
```
Expected: **empty output.** The only permitted exceptions are `mise.toml`, `opentofu/config.tm.hcl`, `CLAUDE.md`, and new files under `opentofu/gcp/`, `clusters/gcp-mycluster-0/`, `docs/`.

- [ ] **Step 2: Confirm the AWS cluster is still healthy**

Run:
```bash
aws eks update-kubeconfig --region eu-west-3 --name mycluster-0
flux get kustomizations -A | grep -v True || echo "ALL READY"
```
Expected: `ALL READY`

- [ ] **Step 3: Switch back to the GCP context**

Run: `kubectx` and select the GKE context, then `kubectx -c` to confirm. Getting this wrong is how a GCP verification command silently reports on the AWS cluster.

### Task 18: Write the bootstrap runbook and run-rate estimate

**Files:**
- Create: `docs/gcp-bootstrap.md`

- [ ] **Step 1: Write the runbook**

It must contain: prerequisites (project, billing, APIs, state bucket, `gcloud` via mise); the deploy sequence; the CIDR allocation table with the reason non-overlap matters; the zonal-vs-regional decision from Task 3 Step 3 **with its cost delta**; the node image choice from Task 3 Step 4; the verification evidence from Task 16 Step 7; and a teardown procedure.

- [ ] **Step 2: Write the monthly run-rate estimate (criterion 11)**

A table with a line per cost driver — GKE cluster management fee, static node pool (2 × spot), Cloud NAT (hourly + per-GB), Cloud DNS zone, Tailscale router instance, persistent disks — each with the figure used and where it came from. State the zonal-vs-regional delta explicitly. An estimate with no sourced numbers does not satisfy the criterion.

- [ ] **Step 3: Commit**

```bash
git add docs/gcp-bootstrap.md
git commit -m "docs(gcp): bootstrap runbook, CIDR plan, and monthly run-rate estimate"
```

### Task 19: Update CLAUDE.md

**Files:**
- Modify: `CLAUDE.md`

- [ ] **Step 1: Add the GCP stacks to the architecture section**

Document `opentofu/gcp/{network,gke/init,gke/configure}`, the `gcp-mycluster-0` Flux tree, and the two-stage deploy command. Add a line to *Key File Locations* naming the GCP stacks alongside the AWS ones.

- [ ] **Step 2: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: document the GCP stacks and gcp-mycluster-0 Flux tree"
```

### Task 20: Rescope the WireGuard note — ONLY if criterion 3 passed

**Files:**
- Modify: `CLAUDE.md`

**Gate:** do this **only** if Task 16 Step 3 returned `100 200` with encryption `Disabled`. If it did not, skip this task entirely and open an issue instead — a documented invariant must not change on the strength of a docs read.

- [ ] **Step 1: Confirm the evidence exists**

Run: `grep -A5 'Verification evidence' docs/gcp-bootstrap.md | grep -c '200'`
Expected: at least 1. If 0, **stop** — the evidence was never recorded, so this task's precondition is unmet.

- [ ] **Step 2: Narrow the note to AWS**

In the *Cilium Prefix Delegation* block, change the claim from a platform-wide invariant to an AWS/ENI-scoped one, keeping the existing prohibition intact for AWS and adding that GCP (`ipam.mode=kubernetes`) does not take the faulty path, with a pointer to ADR-0005 and the recorded evidence.

- [ ] **Step 3: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: scope the Cilium WireGuard workaround to AWS/ENI mode

cilium#43493 is the BPF ipcache hastunnel flag under ENI mode with prefix
delegation. GCP runs ipam.mode=kubernetes and does not take that path --
verified 100/100 HTTP 200 cross-node with encryption disabled. The AWS
prohibition is unchanged."
```

### Task 21: Final gates and handoff

**Files:** none

- [ ] **Step 1: Run every quality gate**

Run:
```bash
tofu fmt -check -recursive opentofu/gcp/
trivy config --exit-code=1 --ignorefile=./.trivyignore.yaml .
./scripts/validate-manifests.sh
pre-commit run --all-files
```
Expected: all exit 0, and `validate-manifests.sh` reports `Invalid: 0, Skipped: 0`.

- [ ] **Step 2: Update the design doc status**

Change `**Status:**` to `slices 1-3 implemented`, and record which open questions the implementation closed (region/zone, DNS naming, image type) with the answers chosen.

- [ ] **Step 3: Note what the next plans need**

Append to the design doc: the node image type slice 4 must pin, and confirmation that the Crossplane WIF binding (Task 9 Step 4) exists so slice 5 is unblocked — plus the reminder that its `roles/editor` breadth is bootstrap-only and slice 5 must narrow it.

- [ ] **Step 4: Commit and open the PR**

```bash
git add docs/superpowers/specs/2026-08-18-gcp-support-design.md
git commit -m "docs(gcp): mark slices 1-3 implemented, record resolved questions"
git push
gh pr create --title "feat(gcp): dual-cloud foundation — network, GKE, Cilium, Flux" --body "<summary + evidence>"
```

---

## Self-review

**Spec coverage.** Design criteria 1–11 map to Tasks 16 (1,2,3,5,6,7,8,9,10) and 18 (11). Criteria 12–17 (autoscaling) and 18–22 (identity) are deliberately out of scope — separate plans, as flagged in the header. The Crossplane WIF binding is the one identity-slice prerequisite pulled forward, in Task 9 Step 4, because slice 5 is blocked without it. Cost posture: spot Task 9 Step 3, single zone Task 9 Step 2, logging/monitoring off Task 9 Step 3, Private Google Access Task 7 Step 3, disk types Tasks 7–9, run-rate Task 18. Both stop-gates present: Phase 1 (CNI) and — deferred to the autoscaling plan — the taint gate.

**Placeholders.** Four `<...>` substitutions remain by design, each with a task that produces the value: project id/number (Task 2), mise backend for `gcloud` (Task 1 Step 2 — deliberately read from `mise registry` rather than guessed), Gateway API version (Task 11 Step 1 — read from the AWS stack so the two clouds match), and the PR body (Task 21). No "TBD", no "add error handling", no "similar to Task N".

**Consistency.** Verified across tasks: `gcp-mycluster-0` as cluster name and Flux path; `10.10.0.0/16` / `100.65.0.0/16` / `10.11.0.0/20` / `172.16.0.0/28` throughout; network outputs (`network_id`, `nodes_subnetwork_id`, `pods_range_name`, `services_range_name`, `node_cidr`) all produced in Tasks 7–9 before being consumed; `node_image_type` set in Task 9 and flagged for slice 4 to reuse; `cilium_version` / `flux_*` passed from globals in Task 13 to the variables declared in Task 12 Step 4.

**Known gap carried forward deliberately:** Task 9's `roles/editor` for Crossplane is bootstrap breadth, called out inline and again in Task 21 Step 3 so the identity plan must narrow it rather than inherit it silently.
