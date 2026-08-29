---
title: Fork and adapt
weight: 10
description: Every environment-specific value you must change, what you can remove, and the shape of the running cost.
lastVerified: 2026-08-30
---

This repository is a working platform for one AWS account, one GCP project,
one domain and one tailnet. Reusing it means replacing those, and the values are spread across
OpenTofu variables, Terramate globals, and a handful of manifests.

This page enumerates them so you do not have to find them by failing.

## What you must change

| Value | Currently | Where it lives | Affects |
|---|---|---|---|
| AWS region | `eu-west-3` | `opentofu/config.tm.hcl`, each stack's `variables.tfvars` | Everything |
| Cluster name | `aws-0` | `opentofu/config.tm.hcl` (`eks_cluster_name`), `opentofu/aws/eks/init/variables.tfvars` (`name`) | Cluster, IAM, and the `clusters/<name>/` directory Flux syncs |
| Private domain | `priv.aws.ogenki.io` | `opentofu/aws/network/variables.tfvars` | Route 53 private zone, every internal hostname, the PKI |
| Public domain | `cloud.ogenki.io` | `opentofu/aws/eks/configure/variables.tfvars` (`public_domain_name`), propagated via the flux-system vars ConfigMap | Public certificates and DNS |
| Git repository URL | `github.com/Smana/cloud-native-ref` | `opentofu/config.tm.hcl` (`flux_sync_repository_url`) | What Flux reconciles — **change this first**, or your cluster syncs someone else's repo |
| Tailscale tailnet | `smainklh@gmail.com` | `opentofu/shared/tailscale/variables.tfvars` (owns the tailnet and its ACL), repeated in each cloud's network stack tfvars | VPN, private gateways, ACL tags |
| Subnet router name | `ogenki` | `opentofu/aws/network/variables.tfvars` | Tailscale device naming |
| OpenBao URL | `bao.priv.aws.ogenki.io` | `opentofu/config.tm.hcl` | PKI and secrets endpoints |
| Secrets Manager paths | `openbao/cloud-native-ref/…`, `certificates/priv.aws.ogenki.io/…` | `opentofu/config.tm.hcl` | Where root token, recovery keys and CA material are stored |
| Identity provider | ZITADEL client ID and `auth.cloud.ogenki.io` | `opentofu/aws/eks/init/variables.tfvars` | Cluster OIDC authentication |
| Tags | `project`, `owner`, `GithubRepo`, `GithubOrg` | `opentofu/aws/network/variables.tfvars`, `opentofu/aws/eks/init/variables.tfvars` | Cost allocation |

Running the GCP side (`gcp-0`) adds its own set, same shape:

| Value | Currently | Where it lives | Affects |
|---|---|---|---|
| GCP project | `ogenki-435905` | `opentofu/gcp/network/variables.tfvars`, `opentofu/gcp/gke/configure/variables.tfvars` | Everything on `gcp-0` |
| Region / zone | `europe-west4` / `europe-west4-a` | `opentofu/gcp/network/variables.tfvars` | Everything on `gcp-0` |
| Cluster name | `gcp-0` | `opentofu/gcp/gke/configure/variables.tfvars` (`cluster_name`) | Cluster and the `clusters/gcp-0/` directory Flux syncs |
| Domains | `priv.gcp.ogenki.io`, `gcp.cloud.ogenki.io` | `opentofu/gcp/network/variables.tfvars`, `opentofu/gcp/gke/configure/variables.tfvars` | Cloud DNS private zone, public certificates |
| Route 53 federation | `route53_public_zone_id`, `route53_role_arn` | `opentofu/gcp/gke/configure/variables.tfvars` — outputs of `opentofu/shared/aws-gcp-federation`, pinned literally | `gcp-0`'s public DNS and certificates (ADR-0019) |
| Flux Git credentials | `flux-github-app` | `opentofu/gcp/gke/configure/variables.tfvars` (`flux_github_app_secret_name`); the secret itself lives in GCP Secret Manager | What Flux on `gcp-0` reconciles |

One value is not in Git at all and must exist before Stage 2 of the cluster
deploy: the **GitHub App secret** in AWS Secrets Manager (`github/flux-app` by
default; `gcp-0` reads its own copy from GCP Secret Manager) — see
[Prerequisites]({{< relref "/docs/get-started/prerequisites.md" >}}). The
`variables.tfvars` files above are all committed — edit them rather than
creating them.

{{< callout type="warning" >}}
Search for the current domain across the repository before deploying. Several
manifests carry hostnames directly rather than through a variable, and a
missed one produces a certificate for a domain you do not own.
{{< /callout >}}

## What you can remove

None of these are required for a working platform:

| Component | Where | Note |
|---|---|---|
| Self-hosted LLM platform | `clusters/aws-0-llm-platform/`, `opentofu/aws/llm-platform/` | Already off by default behind two gates — leave it alone rather than deleting it |
| App Wizard | `apps/platform/app-wizard/` | Self-service UI; the `App` claim works without it |
| RunLore | `observability/base/runlore/` | SRE agent; needs its own credentials |
| Demo applications | `apps/demo/` | Reference claims |
| Self-hosted GitHub runners | `.github/workflows-disabled/`, `tooling/base/` | Disabled by default |

## The minimum viable subset

To get a reconciling platform with private access and TLS, you need:

1. **Network** — VPC, subnets, Route 53 private zone, Tailscale subnet router
2. **OpenBao** — the PKI that issues every internal certificate
3. **EKS** — both stages: the cluster, then Cilium and Flux
4. **Security** — External Secrets and cert-manager
5. **Infrastructure** — Cilium Gateway API resources and ExternalDNS

The GCP equivalent is the same shape: `opentofu/gcp/network`,
`opentofu/gcp/openbao`, `opentofu/gcp/gke` (both stages), then the
`security/gcp-0` and `infrastructure/gcp-0` overlays.

Observability, the developer platform and applications are all additive from
there. Dropping Crossplane means dropping the `App` composition and writing
Deployments by hand, which removes most of the reason to use this repository.

## What it costs to run

No figures here — they would be wrong by the time you read them, and they
vary by region and usage. The drivers, roughly in order:

- **EKS / GKE control plane** — flat hourly charge per cluster, one each if
  you run both clouds
- **Compute** — the bootstrap node group plus whatever Karpenter (AWS) or
  Node Auto-Provisioning (GCP) provisions. The largest and most variable
  line; SPOT capacity is used where possible
- **NAT gateway / Cloud NAT** — hourly plus per-GB processing, and easy to
  underestimate
- **OpenBao instances** — small, always-on VMs
- **Load balancers** — one per gateway
- **S3 / GCS, Route 53, Secrets Manager, KMS** — small but non-zero
- **GPU capacity** — only if you enable the LLM platform, and by far the
  largest cost if you do

Use the cloud pricing calculators for your region rather than trusting any
number written down in a repository.

## Where to start

Once the values above are yours, follow
[Get Started]({{< relref "/docs/get-started/_index.md" >}}) — it deploys the
three stages in order.
