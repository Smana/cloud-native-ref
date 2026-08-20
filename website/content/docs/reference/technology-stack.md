---
title: Technology Stack
weight: 20
description: What runs, which version, and where that version is pinned in this repository.
lastVerified: 2026-08-20
---

Every version below was re-read from the pin in this repository on 2026-08-20
— `mise.toml`, `opentofu/config.tm.hcl`, an OpenTofu variable default, or a
`HelmRelease`/`OCIRepository` — not copied from prose. Where a component has
no version pinned in this repo, that is stated instead of a guessed number.
For the *why* behind a choice, see [Decisions]({{< relref "/docs/decisions/_index.md" >}}).

## CLI tools (`mise.toml`)

| Tool | Version | Pinned in |
|------|---------|-----------|
| OpenTofu | 1.12.6 | `mise.toml` |
| Terramate | 0.17.2 | `mise.toml` |
| Flux CLI (+ schema plugin) | 2.9.4 | `mise.toml` |
| Helm | 4.2.4 | `mise.toml` |
| Kustomize | 5.8.1 | `mise.toml` |
| Trivy | 0.74.0 | `mise.toml` |
| Go | 1.27.0 | `mise.toml` |
| Node.js | 22.23.1 | `mise.toml` |
| golangci-lint | 2.12.2 | `mise.toml` |
| pre-commit | 4.6.2 | `mise.toml` |
| Hugo (extended) | 0.156.0 | `mise.toml` — required for this site; Hextra needs the extended build |

## EKS bootstrap (`opentofu/config.tm.hcl`, `opentofu/eks/init`)

| Component | Version | Pinned in |
|-----------|---------|-----------|
| Kubernetes (EKS control plane) | 1.36 | `opentofu/eks/init/variables.tf` — `kubernetes_version` default, not overridden in `variables.tfvars` |
| Cilium | 1.20.0 | `opentofu/config.tm.hcl` — `cilium_version` |
| Flux Operator | 0.55.0 | `opentofu/config.tm.hcl` — `flux_operator_version` |
| Flux Instance | 0.55.0 | `opentofu/config.tm.hcl` — `flux_instance_version` |
| Gateway API CRDs | v1.6.1 | `opentofu/eks/configure/variables.tf` — `gateway_api_version` default |

## Infrastructure

| Component | Version | Pinned in |
|-----------|---------|-----------|
| Crossplane (controller) | 2.3.4 | `infrastructure/base/crossplane/controller/helmrelease.yaml` |
| Crossplane Configuration package (compositions) | v0.1.0 | `infrastructure/base/crossplane/configuration/configuration-packages.yaml` — package built and released from [`Smana/crossplane-configuration`](https://github.com/Smana/crossplane-configuration) |
| Karpenter | 1.13.0 | `flux/sources/ocirepo-karpenter.yaml` |
| KEDA | 2.20.2 | `infrastructure/base/keda/helmrelease.yaml` |
| CloudNativePG (operator) | 0.29.0 | `infrastructure/base/cloudnative-pg/helmrelease.yaml` |
| Atlas Operator | 0.7.11 | `flux/sources/ocirepo-atlas-operator.yaml` — Atlas Operator v0.7.11 does not support `dir.remote` for Git repos; migrations use the GitOps/ConfigMap pattern instead |
| AWS Load Balancer Controller | 3.5.0 | `infrastructure/base/aws-load-balancer-controller/helmrelease.yaml` |
| AWS EFS CSI driver | 4.4.1 | `infrastructure/base/aws-efs-csi-driver/helmrelease.yaml` — chart 4.x ships driver v3.x, needed for S3 Files access points |
| External DNS | 1.21.1 | `infrastructure/base/external-dns/helmrelease.yaml` |
| Envoy Gateway *(LLM platform, opt-in)* | 1.9.0 | `flux/sources/ocirepo-envoy-gateway.yaml` |
| Envoy AI Gateway *(LLM platform, opt-in)* | 1.0.0 | `flux/sources/ocirepo-envoy-ai-gateway.yaml` |
| vLLM Semantic Router *(LLM platform, opt-in)* | 0.2.0 | `flux/sources/ocirepo-vllm-semantic-router.yaml` |

## Security

| Component | Version | Pinned in |
|-----------|---------|-----------|
| OpenBao | 2.6.2 | `opentofu/openbao/cluster/variables.tf` — `openbao_version` default, not overridden in `variables.tfvars` |
| cert-manager | v1.21.1 | `security/base/cert-manager/helmrelease.yaml` |
| External Secrets Operator | 2.9.0 | `security/base/external-secrets/helmrelease.yaml` |
| Kyverno | 3.8.2 | `security/base/kyverno/helmrelease-controller.yaml` |
| Tailscale Operator | 1.90.6 | `security/base/tailscale-operator/helmrelease.yaml` |
| ZITADEL | 10.0.4 | `security/base/zitadel/helmrelease.yaml` |

## Observability

| Component | Version | Pinned in |
|-----------|---------|-----------|
| VictoriaMetrics k8s stack | 0.91.0 | `observability/base/victoria-metrics-k8s-stack/helmrelease-vmcluster.yaml` (single-node variant pins the same 0.91.0) |
| VictoriaLogs (cluster mode) | 0.2.8 | `observability/base/victoria-logs/helmrelease-vlcluster.yaml` |
| VictoriaLogs (single mode) | 0.13.9 | `observability/base/victoria-logs/helmrelease-vlsingle.yaml` |
| VictoriaTraces | 0.1.11 | `observability/base/victoria-traces/helmrelease-vtsingle.yaml` |
| Grafana Operator | 5.24.0 | `observability/base/grafana-operator/helmrelease.yaml` |
| Grafana OnCall | 1.16.5 | `observability/base/grafana-oncall/helmrelease-oncall.yaml` |
| metrics-server | 3.14.0 | `observability/base/metrics-server/helmrelease.yaml` |

## Data and tooling

| Component | Version | Pinned in |
|-----------|---------|-----------|
| Harbor | 1.18.3 | `tooling/base/harbor/helmrelease-harbor.yaml` |
| Headlamp | 0.44.0 | `tooling/base/headlamp/helmrelease.yaml` |
| Homepage | 2.1.0 | `tooling/base/homepage/helmrelease.yaml` |
| Dagger engine | v0.21.8 | `tooling/base/dagger-engine/deployment.yaml` — image tag |
| GitHub Actions Runner Controller *(off by default)* | 0.14.2 | `tooling/base/gha-runners/controller-helmrelease.yaml` |
| GHA runner scale sets *(off by default)* | 0.9.3 | `tooling/base/gha-runners/default-scale-set-helmrelease.yaml`, `dagger-scale-set-helmrelease.yaml` |
| Valkey | not pinned in this repo | Provisioned per-tenant by the `KVStore` Crossplane composition in [`Smana/crossplane-configuration`](https://github.com/Smana/crossplane-configuration); the chart version tracks that repo's release, not a pin here |

## Managed AWS services

No version to pin — these are AWS APIs, not deployed software: Route 53 (DNS),
Elastic Load Balancing, IAM (via EKS Pod Identity), KMS, and S3.

## What this table intentionally omits

`docs/technology-choices.md` carried a flatter, badge-illustrated version of
this table with no version column at all — every entry there had drifted from
what actually deploys, which is the reason this page exists. This page also
drops a few rows that duplicated the [Repository Layout]({{< relref "/docs/reference/repository-layout.md" >}})
page's directory listing without adding version information.
