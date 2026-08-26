---
title: GCP
weight: 30
description: Deploy the platform on GKE — four prerequisites, three stages, two commands.
lastVerified: 2026-08-26
---

The GCP lane builds the same three-stage model as
[AWS]({{< relref "/docs/get-started/aws/_index.md" >}}) — network, then secrets
and PKI, then Kubernetes — on GKE Standard with self-managed Cilium.

{{< callout type="info" >}}
Every GCP stack is behind an opt-in gate. `terramate script run deploy` from
`opentofu/` **skips GCP entirely** unless `TM_GCP_ENABLED=true` is set, and exits
0 while doing so. Both clouds share one Terramate run order, and the gate is what
keeps an AWS deploy from building GCP as a side effect.
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
truncated state file, and painful to add afterwards.

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
That role and its OIDC provider live outside the GCP stack tree and are **not**
gated by `TM_GCP_ENABLED`, so apply them explicitly:

```bash
cd opentofu/shared/aws-gcp-federation
tofu init
tofu apply -var-file=variables.tfvars
```

This stack has no Terramate ordering edge to the GCP stacks on purpose — an AWS
stack must not depend on a GCP one, nor the reverse. So on a fresh deploy `gcp-0`
can come up before it is applied, and you may see `AccessDenied` in both
controllers for the first few minutes. That is not a stuck deploy: apply this
stack and give Flux a couple of reconcile intervals.

It is also left applied across teardowns (its `destroy` is guarded behind
`TM_FEDERATION_DESTROY=true`). An IAM role and an OIDC provider cost nothing
idle, and a rebuilt `gcp-0` then gets public ingress immediately.

Note that the OIDC provider trusts an issuer URL built from the project,
location and cluster name. **Renaming or moving `gcp-0` breaks this stack** —
re-apply it after any such change.

## Configure

Every stack already ships a `variables.tfvars` in Git with values that deploy.
You are editing a working configuration, not writing one:

1. `opentofu/gcp/config.tm.hcl` — project, region/zone, cluster name, chart
   versions, and the URL of *your* fork for Flux to sync.
2. Each stack's `variables.tfvars` under `opentofu/gcp/` — the committed values
   point at the reference project (`europe-west4-a`, `COS_CONTAINERD`,
   2 × `e2-standard-4` spot). Change the project ID and domains to yours.

## Deploy

{{% steps %}}

### Stages 1 and 2 — Network, then OpenBao

```bash
cd opentofu
TM_GCP_ENABLED=true terramate script run deploy
```

**One command covers both stages.** Terramate resolves the dependency graph:
`network` first, then `openbao/cluster`, then `openbao/management`.

Stage 1 creates the VPC with its node, pod, service and control-plane ranges, a
**private Cloud DNS zone**, and the Tailscale subnet router that gives you access
to everything built afterwards. Stage 2 brings up OpenBao on Compute Engine
behind an internal load balancer, auto-unsealed via the Cloud KMS key you created
above, then layers on the three-tier PKI and the cert-manager and snapshot
AppRoles.

### Stage 3 — Kubernetes (GKE)

```bash
cd opentofu/gcp/gke/init
TM_GCP_ENABLED=true terramate script run deploy
```

A separate command because this stack runs a two-stage bootstrap internally, for
the same provider-graph reason as EKS. Stage 1 creates the GKE cluster with a
private control plane and the static spot node pool; stage 2 installs Cilium —
which displaces GKE's CNI via `cni.exclusive` and replaces kube-proxy — then the
Flux Operator and a `FluxInstance` pointed at your fork.

To test a feature branch, add `TF_VAR_flux_git_ref`:

```bash
TM_GCP_ENABLED=true TF_VAR_flux_git_ref='refs/heads/my-branch' \
  terramate script run deploy
```

{{% /steps %}}

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
Kustomization reconciled. If gateways report `Waiting for controller`, see
[Troubleshooting]({{< relref "/docs/guides/troubleshooting.md" >}}) — cilium-operator
probes the Gateway API CRDs once at startup and disables its controller
permanently if any are missing.

## What Flux reconciles here

Less than on AWS, and knowingly so. `gcp-0` brings up namespaces, CRDs, Flux,
Crossplane with `provider-gcp`, the security layer (cert-manager, External
Secrets, Kyverno, Tailscale) and the infrastructure layer (Cilium policies,
Gateway API, both external-dns instances, ComputeClasses).

It does **not** yet run observability, tooling or general applications — those
overlays are not written. The full comparison, including what each gap needs, is
on [Cloud support]({{< relref "/docs/platform/foundations/cloud-support.md" >}}).

## Teardown

```bash
cd opentofu
TM_GCP_ENABLED=true TM_DESTROY_CONFIRMED=true terramate script run --reverse destroy
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
