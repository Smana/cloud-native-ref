---
title: GCP
weight: 30
description: Deploy the platform on GKE — four prerequisites, three stages, two commands.
lastVerified: 2026-08-30
---

The GCP lane builds the same three-stage model as
[AWS]({{< relref "/docs/get-started/aws/_index.md" >}}) — network, then secrets
and PKI, then Kubernetes — on GKE Standard with self-managed Cilium.

{{< callout type="info" >}}
**One knob picks the cloud: `TM_CLOUD`.** It defaults to `aws`, so
`terramate script run deploy` from `opentofu/` skips every GCP stack and exits 0
while doing so. Both clouds share one Terramate run order, and this is what keeps
an AWS deploy from building GCP as a side effect.

```bash
terramate script run deploy                    # aws alone (the default)
TM_CLOUD=gcp     terramate script run deploy   # gcp alone
TM_CLOUD=aws,gcp terramate script run deploy   # both
TM_CLOUD=all     terramate script run deploy   # every lane there is
```

It is a comma list, so a third cloud would need no new keyword. See
[Repository layout]({{< relref "/docs/reference/repository-layout.md" >}}) for
how a stack's lane is decided.
{{< /callout >}}

## Prerequisites

Read [Prerequisites]({{< relref "/docs/get-started/prerequisites.md" >}}) for the
tools (`mise install`) and GitHub App, then do the four below. The first three
are hand-created because each is chicken-and-egg or destructive to recreate; the
fourth is OpenTofu-managed but easy to skip and fails opaquely when you do.

Substitute your own project IDs, organisation and billing account throughout.

### 1 · State bucket, in its own project

Nothing can `plan` until this exists — a stack that created it would have
nowhere to record that it had. It lives in a project that holds nothing else, so
deleting the workload project cannot take the state describing it
([ADR-0018]({{< relref "/docs/decisions/0018-per-cloud-opentofu-state.md" >}})).

```bash
gcloud projects create ogenki-tfstate --organization=<org-id>
gcloud billing projects link ogenki-tfstate --billing-account=<account-id>
gcloud services enable storage.googleapis.com --project=ogenki-tfstate
gcloud storage buckets create gs://ogenki-cloud-native-ref-tfstate \
  --project=ogenki-tfstate --location=europe-west4 \
  --uniform-bucket-level-access --public-access-prevention
gcloud storage buckets update gs://ogenki-cloud-native-ref-tfstate --versioning
```

Turn versioning on **before** the first apply. It is the only recovery path for a
truncated state file, and painful to add afterwards. If you pick a different
bucket name, edit it in every GCP `backend` block **and** in the two
`terraform_remote_state` readers that hardcode it —
`opentofu/gcp/gke/init/data.tf` and `opentofu/gcp/gke/configure/data.tf`.

### 2 · Cloud KMS key ring for OpenBao auto-unseal

Read as a data source, never managed, because **GCP cannot delete a key ring or a
crypto key**. A `tofu destroy` of a managed one reports success while destroying
only key *versions*, and the next build then fails with `ALREADY_EXISTS`.

```bash
gcloud services enable cloudkms.googleapis.com --project=<your-project>
gcloud kms keyrings create openbao-dev --location=europe-west4 --project=<your-project>
gcloud kms keys create openbao-unseal --location=europe-west4 \
  --keyring=openbao-dev --purpose=encryption --project=<your-project>
```

This survives teardown by design and costs nothing idle — it is not a leak.

### 3 · Tailscale OAuth client

Separate from the AWS cluster's client, so compromising one cluster's operator
does not force rotating the other's. Create it in the Tailscale admin console
(Settings → OAuth clients) with scopes `devices:core` and `auth_keys` (write),
tagged `tag:k8s-operator`, then publish it:

```bash
printf '{"client_id":"%s","client_secret":"%s"}' "$CLIENT_ID" "$CLIENT_SECRET" \
  | gcloud secrets create tailscale-k8s-operator-oauth \
      --project=<your-project> --replication-policy=automatic --data-file=-
```

The JSON keys are consumed verbatim into the chart's `operator-oauth` Secret —
do not rename them. This is the one prerequisite that is a live credential rather
than an empty container: **revoke it** if you decommission the project.

### 4 · The AWS↔GCP federation stack

{{< callout type="warning" >}}
Skip this and the deploy still succeeds — then certificates never issue, and
nothing on GCP tells you why. `Certificate` objects sit `False` indefinitely
while cert-manager and external-dns fail against AWS with `AccessDenied` or
`InvalidIdentityToken`, naming neither the missing stack nor the role.
{{< /callout >}}

`gcp-0` reaches the public Route 53 zone by assuming an AWS IAM role with a
projected ServiceAccount token — no access key
([ADR-0019]({{< relref "/docs/decisions/0019-cross-cloud-dns-federation.md" >}})).
That role and its OIDC provider live outside the GCP stack tree, in
`opentofu/shared/`, so they belong to the `shared` lane and run under **every**
value of `TM_CLOUD` — which cuts both ways: a plain AWS deploy applies this stack
(only its `destroy` is guarded), and so does the GCP deploy below, so normally
you only need to verify it applied. Apply it standalone only if you are deploying
a single stack directly:

```bash
cd opentofu/shared/aws-gcp-federation
tofu init
tofu apply -var-file=variables.tfvars
```

This stack has no Terramate ordering edge to the GCP stacks on purpose — an AWS
stack must not depend on a GCP one, nor the reverse. So on a fresh deploy `gcp-0`
can come up before it is applied, and you may see `AccessDenied` in both
controllers for the first few minutes. That is not a stuck deploy: once this
stack is applied, give Flux a couple of reconcile intervals.

It is also left applied across teardowns (its `destroy` is guarded behind
`TM_FEDERATION_DESTROY=true`). An IAM role and an OIDC provider cost nothing
idle, and a rebuilt `gcp-0` then gets public ingress immediately.

Note that the OIDC provider trusts an issuer URL built from the project,
location and cluster name. **Renaming or moving `gcp-0` breaks this stack** —
re-apply it after any such change.

## Configure

Every stack already ships a `variables.tfvars` in Git with values that deploy.
You are editing a working configuration, not writing one:

1. The root `opentofu/config.tm.hcl` — the Helm chart versions used by the
   bootstrap (`cilium_version`, `flux_operator_version`,
   `flux_instance_version`), shared with the AWS lane.
   (There is no GCP-specific config file to edit; the cloud gate lives in
   `scripts/tm-provisioner.sh` and applies to both lanes.)
2. Each stack's `variables.tfvars` under `opentofu/gcp/` — the committed values
   point at the reference project (`europe-west4-a`, `COS_CONTAINERD`,
   2 × `e2-standard-4` spot). Project, region/zone and the private domain live
   in `opentofu/gcp/network/variables.tfvars`, the cluster name in
   `opentofu/gcp/gke/init/variables.tfvars`, and the URL of *your* fork
   (`flux_sync_url`) in `opentofu/gcp/gke/configure/variables.tfvars`. Change
   the project ID and domains to yours.
3. `opentofu/shared/tailscale/variables.tfvars` — `tailnet` and `admin_users`
   are the reference tailnet's identity, and this stack is the first thing the
   root deploy applies; point them at your own tailnet.

## Deploy

One command. Terramate owns the dependency graph — that is what it is for — and
runs every stack in order.

```bash
cd opentofu
TM_CLOUD=gcp terramate script run deploy
```

`TM_CLOUD=gcp` selects both directions at once — it turns the GCP stacks on
*and* the AWS ones off, so there is no second flag to remember. That leaves
exactly what a GCP deploy needs:

```
shared/tailscale            shared/aws-gcp-federation
gcp/network                 gcp/openbao/cluster        gcp/openbao/management
gcp/gke/init                gcp/gke/configure
```

The two `shared/` stacks are in the list on purpose: they are owned by neither
cloud, so they run whatever `TM_CLOUD` says.

Confirm the selection before applying anything — `terramate list --tags=gcp`
prints the five GCP stacks, and a dry `TM_CLOUD=gcp terramate script run init`
prints a `[skip]` line for each AWS stack it passes over.

What that runs, in order:

- **`shared/tailscale`** first, because `gcp/network` names it in `after`. It
  owns the tailnet ACL both clouds share.
- **`gcp/network`** — the VPC with its node, pod, service and control-plane
  ranges, a **private Cloud DNS zone**, and the Tailscale subnet router that
  gives you access to everything built afterwards.
- **`gcp/openbao/{cluster,management}`** — OpenBao on Compute Engine behind an
  internal load balancer, auto-unsealed via the Cloud KMS key from the
  prerequisites, then the three-tier PKI and the cert-manager and snapshot
  AppRoles.
- **`gcp/gke/init`**, whose own script drives the GKE bootstrap end to end:
  stage 1 creates the cluster with a private control plane and the static spot
  node pool; stage 2 installs Cilium — which displaces GKE's CNI via
  `cni.exclusive` and replaces kube-proxy — then the Flux Operator and a
  `FluxInstance` pointed at your fork; stage 3 seeds secrets and OIDC.
- **`shared/aws-gcp-federation`** has no ordering edge in either direction,
  by design, so Terramate is free to place it anywhere in the run. See
  prerequisite 4 above for why an early `AccessDenied` is expected rather than a
  stuck deploy.

{{< callout type="info" >}}
`gcp/gke/configure` is applied twice — once by `gke/init`'s stage 2, which shells
into it, and once as its own stack when Terramate reaches it. The second apply is
a no-op, so this is waste rather than breakage, but it is why the run reports one
more stack than you might expect.
{{< /callout >}}

`flux_git_ref` defaults to `refs/heads/main`. Only override it to test an
unmerged branch — and remember the branch is deleted when its PR merges, which
404s the cluster's Git source until you restore it:

```bash
TM_CLOUD=gcp TF_VAR_flux_git_ref='refs/heads/my-branch' \
  terramate script run deploy
```

## Single sign-on

The deploy leaves ZITADEL running with **nothing configured in it** — no identity
provider, no OIDC clients, no roles. Five ordered commands turn that into a
working Google login for Grafana, Harbor, the Flux UI and Headlamp:
[Set up single sign-on]({{< relref "/docs/get-started/sso.md" >}}).

Skipping this is not obvious from the cluster: every workload is healthy and
every service simply asks for a password nobody has.

## Verify

The control plane has a **private endpoint**, so the tailnet must be up first.

```bash
tailscale status                     # subnet router should be visible
gcloud container clusters get-credentials gcp-0 \
  --zone europe-west4-a --project <your-project>

kubectl get nodes
flux get all
```

A healthy result: nodes `Ready` with Cilium as the only CNI, and every
Kustomization reconciled. Reaching OpenBao and everything else private works
the same way as on AWS — see
[Access]({{< relref "/docs/get-started/access.md" >}}). If gateways report `Waiting for controller`, see
[Troubleshooting]({{< relref "/docs/guides/troubleshooting.md" >}}) — cilium-operator
probes the Gateway API CRDs once at startup and disables its controller
permanently if any are missing.

## What Flux reconciles here

Slightly less than on AWS. `gcp-0` brings up namespaces, CRDs, Flux,
Crossplane with `provider-gcp`, the security layer (cert-manager, External
Secrets, Kyverno, Tailscale), the infrastructure layer (Cilium policies,
Gateway API, both external-dns instances, ComputeClasses), the observability
stack, tooling (Harbor) and the applications.

What it does **not** run: `image-gallery` (not yet portable) and `flux-previews`
(excluded by design — previews belong to one cluster). The full comparison,
including what each gap needs, is on
[Cloud support]({{< relref "/docs/platform/foundations/cloud-support.md" >}}).

## Teardown

```bash
cd opentofu
TM_CLOUD=gcp TM_DESTROY_CONFIRMED=true terramate script run --reverse destroy
```

Then confirm against the provider rather than trusting the exit code — a
Terramate destroy can exit 0 while refusing to run:

```bash
gcloud container clusters list --project <your-project>
gcloud compute instances list --project <your-project>
gcloud compute forwarding-rules list --project <your-project>
gcloud compute disks list --project <your-project>
gcloud compute addresses list --project <your-project>
```

All five should be empty. The state bucket, the KMS key ring and the federation
stack survive on purpose — see above.
