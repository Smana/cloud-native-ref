---
title: Fork and adapt
weight: 10
description: Every environment-specific value you must change, what you can remove, and the shape of the running cost.
lastVerified: 2026-08-20
---

This repository is a working platform for one AWS account, one domain and one
tailnet. Reusing it means replacing those, and the values are spread across
OpenTofu variables, Terramate globals, and a handful of manifests.

This page enumerates them so you do not have to find them by failing.

## What you must change

| Value | Currently | Where it lives | Affects |
|---|---|---|---|
| AWS region | `eu-west-3` | `opentofu/config.tm.hcl`, each stack's `variables.tfvars` | Everything |
| Cluster name | `mycluster-0` | `opentofu/config.tm.hcl` (`eks_cluster_name`), `opentofu/aws/eks/init/variables.tfvars` (`name`) | Cluster, IAM, and the `clusters/<name>/` directory Flux syncs |
| Private domain | `priv.cloud.ogenki.io` | `opentofu/aws/network/variables.tfvars` | Route 53 private zone, every internal hostname, the PKI |
| Public domain | `cloud.ogenki.io` | ExternalDNS and gateway manifests | Public certificates and DNS |
| Git repository URL | `github.com/Smana/cloud-native-ref` | `opentofu/config.tm.hcl` (`flux_sync_repository_url`) | What Flux reconciles — **change this first**, or your cluster syncs someone else's repo |
| Tailscale tailnet | `smainklh@gmail.com` | `opentofu/aws/network/variables.tfvars` | VPN, private gateways, ACL tags |
| Subnet router name | `ogenki` | `opentofu/aws/network/variables.tfvars` | Tailscale device naming |
| OpenBao URL | `bao.priv.cloud.ogenki.io` | `opentofu/config.tm.hcl` | PKI and secrets endpoints |
| Secrets Manager paths | `openbao/cloud-native-ref/…`, `certificates/priv.cloud.ogenki.io/…` | `opentofu/config.tm.hcl` | Where root token, recovery keys and CA material are stored |
| Identity provider | ZITADEL client ID and `auth.cloud.ogenki.io` | `opentofu/aws/eks/init/variables.tfvars` | Cluster OIDC authentication |
| Tags | `project`, `owner`, `GithubRepo`, `GithubOrg` | `opentofu/aws/network/variables.tfvars`, `opentofu/aws/eks/init/variables.tfvars` | Cost allocation |

Two more are not in Git at all and must exist before Stage 2 of the cluster
deploy:

- the **GitHub App secret** in AWS Secrets Manager (`github/flux-app` by
  default) — see
  [Prerequisites]({{< relref "/docs/get-started/prerequisites.md" >}})
- a `variables.tfvars` file in the `opentofu/aws/eks/configure` stack, which is
  not committed and which you must create — Stage 2 hard-errors without it
  rather than prompting

{{< callout type="warning" >}}
Search for the current domain across the repository before deploying. Several
manifests carry hostnames directly rather than through a variable, and a
missed one produces a certificate for a domain you do not own.
{{< /callout >}}

## What you can remove

None of these are required for a working platform:

| Component | Where | Note |
|---|---|---|
| Self-hosted LLM platform | `clusters/mycluster-0-llm-platform/`, `opentofu/aws/llm-platform/` | Already off by default behind two gates — leave it alone rather than deleting it |
| App Wizard | `apps/platform/app-wizard/` | Self-service UI; the `App` claim works without it |
| RunLore | `observability/base/runlore/` | SRE agent; needs its own credentials |
| Demo applications | `apps/demo/` | Reference claims |
| Self-hosted GitHub runners | `.github/workflows-disabled/`, `tooling/base/` | Disabled by default |
| Grafana OnCall | `observability/base/grafana-oncall/` | Built but wired into no Kustomization — it does not currently run |

## The minimum viable subset

To get a reconciling platform with private access and TLS, you need:

1. **Network** — VPC, subnets, Route 53 private zone, Tailscale subnet router
2. **OpenBao** — the PKI that issues every internal certificate
3. **EKS** — both stages: the cluster, then Cilium and Flux
4. **Security** — External Secrets and cert-manager
5. **Infrastructure** — Cilium Gateway API resources and ExternalDNS

Observability, the developer platform and applications are all additive from
there. Dropping Crossplane means dropping the `App` composition and writing
Deployments by hand, which removes most of the reason to use this repository.

## What it costs to run

No figures here — they would be wrong by the time you read them, and they
vary by region and usage. The drivers, roughly in order:

- **EKS control plane** — flat hourly charge per cluster
- **Compute** — the bootstrap node group plus whatever Karpenter provisions.
  The largest and most variable line; SPOT capacity is used where possible
- **NAT gateway** — hourly plus per-GB processing, and easy to underestimate
- **OpenBao instances** — small, always-on EC2
- **Load balancers** — one per gateway
- **S3, Route 53, Secrets Manager, KMS** — small but non-zero
- **GPU capacity** — only if you enable the LLM platform, and by far the
  largest cost if you do

Use the AWS pricing calculator for your region rather than trusting any
number written down in a repository.

## Where to start

Once the values above are yours, follow
[Get Started]({{< relref "/docs/get-started/_index.md" >}}) — it deploys the
three stages in order.
