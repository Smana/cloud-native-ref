---
title: Cloud support
linkTitle: Cloud support
weight: 5
description: What runs on AWS, what runs on GCP, which managed service stands in for which, and the decisions that made the two lanes differ.
lastVerified: 2026-08-30
---

The platform runs on **two clouds**: `aws-0` on EKS and `gcp-0` on GKE Standard.
They are not one abstraction with two backends. They are two implementations of
the same three-stage model, sharing every Kubernetes-layer component and
diverging exactly where the clouds themselves diverge.

This page is the map of that divergence: what each cloud uses, where the two
deliberately meet, and what is still missing on GCP.

## Status at a glance

{{< callout type="info" >}}
Both lanes deploy from the same repository and the same Flux tree. Neither is a
fork, and neither is simulated — every row below was exercised on a live cluster
and torn down afterwards.
{{< /callout >}}

| Layer | `aws-0` | `gcp-0` |
|---|---|---|
| Network stack | ✅ `opentofu/aws/network` | ✅ `opentofu/gcp/network` |
| Secrets / PKI stack | ✅ `opentofu/aws/openbao/{cluster,management}` | ✅ `opentofu/gcp/openbao/{cluster,management}` |
| Kubernetes stack | ✅ `opentofu/aws/eks/{init,configure}` | ✅ `opentofu/gcp/gke/{init,configure}` |
| Namespaces · CRDs · Flux | ✅ | ✅ |
| Crossplane | ✅ `provider-aws` | ✅ `provider-gcp` |
| Security (cert-manager, ESO, Kyverno, Tailscale) | ✅ | ✅ |
| Infrastructure (Cilium, Gateway API, external-dns) | ✅ | ✅ |
| Observability (VictoriaMetrics, Grafana, RunLore) | ✅ | ✅ same stack |
| Tooling (Harbor) | ✅ | ✅ Harbor on GCS with Workload Identity |
| Applications | ✅ | ✅ podinfo · basic · App Wizard — minus `image-gallery` |
| LLM platform | ⏸️ opt-in, suspended | ⏸️ opt-in, suspended |
| Flux extras (alerts, dashboards) | ✅ | ✅ minus `flux-previews` |

One nuance in the Infrastructure row: Cilium itself is OpenTofu-owned on both
clouds (Stage 2 of the Kubernetes stack), not Flux-managed — and the Cilium
extras `aws-0` wires through Flux (`infrastructure/base/cilium`: Hubble UI
route, dashboards, scrape configs) have no `gcp-0` entry.

## Matching managed services

The Kubernetes layer is identical on both clouds — same Cilium, same Flux, same
OpenBao, same VictoriaMetrics, same Gateway API. Everything below is the layer
where a cloud's own service is unavoidable, and what stands in for what.

### Compute and networking

| Concern | AWS | GCP | Notes |
|---|---|---|---|
| Managed Kubernetes | EKS | GKE Standard | Standard, not Autopilot — Autopilot forbids the DaemonSet privileges Cilium needs ([ADR-0005](../../decisions/0005-gke-standard-self-managed-cilium.md)) |
| CNI | Cilium (replaces VPC-CNI) | Cilium (displaces GKE's) | Same chart, same version, both self-managed ([ADR-0009](../../decisions/0009-cilium-over-vpc-cni.md)) |
| Node autoscaling | Karpenter | Node Auto-Provisioning + ComputeClass | ([ADR-0006](../../decisions/0006-nap-computeclass-over-karpenter.md)) |
| Node OS | Bottlerocket | Container-Optimized OS (`cos_containerd`) | |
| Load balancer | ELB / NLB | Google Cloud Load Balancing | Both fronted by Gateway API, not consumed directly |
| Private access | Tailscale subnet router | Tailscale subnet router | One tailnet spans both clouds — `opentofu/shared/tailscale` |
| Encryption in transit | Cilium WireGuard | not required | The WireGuard workaround is an AWS prefix-delegation issue; GKE does not hit it |

### Storage

| Concern | AWS | GCP | Notes |
|---|---|---|---|
| Block storage class | `gp3` (EBS) | `standard-rwo` (pd-balanced) | Supplied to manifests as `${storage_class}` — no PVC hardcodes either |
| Object storage | S3 | Cloud Storage | |
| Model weights (LLM) | Amazon S3 Files | Cloud Storage FUSE CSI | ([ADR-0004](../../decisions/0004-amazon-s3-files-for-model-weights-storage.md), [ADR-0021](../../decisions/0021-gcs-fuse-for-model-weights-on-gcp.md)) |
| Registry storage | Harbor → S3 driver | Harbor → GCS driver | Harbor itself is self-hosted on both ([ADR-0020](../../decisions/0020-harbor-gcs-workload-identity.md)) |
| OpenTofu state | S3 bucket | GCS bucket, dedicated project | Deliberately *not* shared ([ADR-0018](../../decisions/0018-per-cloud-opentofu-state.md)) |

### Identity and secrets

| Concern | AWS | GCP | Notes |
|---|---|---|---|
| Workload identity | EKS Pod Identity | GKE Workload Identity Federation | Never IRSA, never a static key ([ADR-0002](../../decisions/0002-eks-pod-identity-over-irsa.md)) |
| Crossplane claim | `EPI` | `GCPWorkloadIdentity` | Cloud-shaped on purpose ([ADR-0007](../../decisions/0007-cloud-abstraction-boundaries.md)) |
| Bootstrap secret store | AWS Secrets Manager | Google Secret Manager | Read at apply time by the cluster stack |
| Runtime secret store (ESO) | AWS Secrets Manager | GCP Secret Manager | The one `ClusterSecretStore` every ExternalSecret reads ([ADR-0025]({{< relref "/docs/decisions/0025-cloud-managed-secret-stores.md" >}})) |
| Private PKI | OpenBao | OpenBao | Same PKI model, one instance per cloud |
| OpenBao auto-unseal | AWS KMS | Cloud KMS | |

### DNS and certificates

This is the one place the two clouds are deliberately *not* symmetric, and the
asymmetry is the point.

| Concern | AWS | GCP |
|---|---|---|
| Private zone | Route 53 private hosted zone — `priv.aws.ogenki.io` | **Cloud DNS** private zone — `priv.gcp.ogenki.io` |
| Public zone | Route 53 — `cloud.ogenki.io` | **Route 53**, via AWS IAM OIDC federation |
| external-dns (private) | `provider: aws` | `provider: google` |
| external-dns (public) | `provider: aws` | `provider: aws` — a second instance |
| Public certificate issuance | Let's Encrypt DNS-01 → Route 53 | Let's Encrypt DNS-01 → Route 53, federated |

**Private DNS is native on each cloud. Only the public zone is centralised** —
and only because `cloud.ogenki.io` is a Route 53 zone this repository does not
manage, while Let's Encrypt must resolve `_acme-challenge` publicly to issue a
certificate. Delegating a subdomain to Cloud DNS or moving the zone were both
considered and rejected; what made federation acceptable is that it needs **no
static AWS credential** on GCP — cert-manager and external-dns assume an AWS
role using a projected Kubernetes ServiceAccount token, the same
identity-by-token model both clouds already use internally. The full argument,
including what the dependency costs, is in
[ADR-0019](../../decisions/0019-cross-cloud-dns-federation.md).

### Data services

Neither cloud's managed database is used. PostgreSQL is CloudNativePG and
key/value is Valkey — both self-hosted, both driven by a Crossplane claim, and
both now work on either cloud:

| Claim | AWS | GCP |
|---|---|---|
| `SQLInstance` (PostgreSQL) | ✅ CloudNativePG, barman backups to S3 | ✅ CloudNativePG, barman backups to Cloud Storage |
| `KVStore` (Valkey) | ✅ | ✅ cloud-neutral Composition — no cloud resources, so it works unchanged |

`SQLInstance` was the last claim to reach GCP, and until
crossplane-configuration v0.4.0 its GCP Composition was a deliberate dead-end —
it failed evaluation rather than composing nothing, so a claim said why instead
of hanging `Ready=Unknown`. That was consistent with
[ADR-0007](../../decisions/0007-cloud-abstraction-boundaries.md): a claim that
cannot be honoured should say so at reconcile time.

It is a real implementation now. Both clouds render from the same KCL module,
differing in where barman writes (`gs://` with `googleCredentials.gkeEnvironment`
rather than `s3://` with `s3Credentials.inheritFromIAMRole`) and in the identity
that writes — one `GCPWorkloadIdentity`, bucket-scoped, in place of four AWS IAM
resources. The CloudNativePG operator runs on both clouds; `gcp-0` pulls the same
whole base directory `aws-0` does (`infrastructure/gcp-0/cloudnative-pg/`
references `../../base/cloudnative-pg` plus its own `gcs-bucket.yaml`) — including
the base's three Grafana dashboards, since both of their preconditions hold on
`gcp-0` too: `crds/base` installs the `GrafanaDashboard` CRD, and
`clusters/gcp-0/observability/observability-grafana-operator.yaml` runs the
operator that reconciles it.

## Decisions that shaped the split

Seven records carry the multicloud reasoning. Read in this order they explain
why the platform looks the way it does on a second cloud:

{{< cards >}}
  {{< card link="../../decisions/0007-cloud-abstraction-boundaries/" title="ADR-0007 · Cloud abstraction boundaries" subtitle="Where the platform refuses to pretend two clouds are one. An API that only looks neutral produces worse errors than one that is honestly cloud-shaped." >}}
  {{< card link="../../decisions/0005-gke-standard-self-managed-cilium/" title="ADR-0005 · GKE Standard, self-managed Cilium" subtitle="Autopilot cannot run the CNI this platform is built on, so Standard it is." >}}
  {{< card link="../../decisions/0006-nap-computeclass-over-karpenter/" title="ADR-0006 · ComputeClass over Karpenter" subtitle="Karpenter's GCP provider was not credible; NAP is the native equivalent." >}}
  {{< card link="../../decisions/0017-multi-cloud-dns-naming/" title="ADR-0017 · Multi-cloud DNS naming" subtitle="Public names carry no cloud label; private names are pinned per cloud." >}}
  {{< card link="../../decisions/0019-cross-cloud-dns-federation/" title="ADR-0019 · Cross-cloud DNS federation" subtitle="GKE reaches Route 53 with a projected token, not an access key." >}}
  {{< card link="../../decisions/0018-per-cloud-opentofu-state/" title="ADR-0018 · Per-cloud OpenTofu state" subtitle="Each cloud's state lives in its own cloud, so a teardown needs one set of credentials." >}}
  {{< card link="../../decisions/0020-harbor-gcs-workload-identity/" title="ADR-0020 · Harbor on GCS with Workload Identity" subtitle="A chart limitation forces static keys on AWS but not on GCP — the asymmetry is upstream's, not ours." >}}
{{< /cards >}}

## The shared layer

Two things belong to neither cloud and are provisioned once:

- **`opentofu/shared/tailscale`** — one tailnet, both clusters. Its state stays
  in S3 precisely because the tailnet is not a GCP resource or an AWS one.
- **`opentofu/shared/aws-gcp-federation`** — the AWS IAM OIDC provider that
  trusts the GKE issuer, which is what makes the DNS row above work.

## Known gaps

`gcp-0` now runs the same layers as `aws-0`. Four components are still
excluded, and the distinction that matters is **why** — three of them are not
gaps at all.

### Excluded by design, not missing

- **`flux-previews`** — PR preview environments. Running them on both clusters
  would double-provision every preview and both would write the same public DNS
  records. Previews belong to one cluster by nature. (It also hardcodes
  `cluster_name: aws-0` while living in the shared `flux/` tree, which is worth
  fixing regardless.)
- **`karpenter` / `karpenter-nodepools`** — GCP uses Node Auto-Provisioning with
  ComputeClasses instead ([ADR-0006](../../decisions/0006-nap-computeclass-over-karpenter.md)).
- **`eks-pod-identities`** — `GCPWorkloadIdentity` is the counterpart, a
  different Kind rather than a second Composition
  ([ADR-0002](../../decisions/0002-eks-pod-identity-over-irsa.md)).

### Genuinely not portable yet

- **`image-gallery`** — the only application excluded, and not for a manifest
  reason. It hardcodes `STORAGE_ENDPOINT=s3.eu-west-3.amazonaws.com` in its
  container environment and talks to it through an S3 SDK. Reaching Cloud
  Storage means either GCS's S3-compatible XML API with HMAC keys — static
  credentials this platform avoids wherever a workload identity will do — or a
  GCS-native client. Both are changes to the *application*.
- **Harbor's database has no backups on `gcp-0`.** The claim side is ready — the
  Composition renders barman's `ObjectStore` and a bucket-scoped identity as
  soon as `backup` is set. The cluster side is not: the barman plugin ships a
  `CiliumNetworkPolicy` whose egress is a `toFQDNs` allowlist of S3 endpoints,
  so deploying it would let the plugin start and then silently drop every
  connection to `storage.googleapis.com`.

### Needs a human, on both clouds

Two ExternalSecrets read from the cloud's managed secret store and nothing
seeds them — `./scripts/secret-store.sh check --cloud gcp` (or `aws`) lists
what is missing, and its `seed` command creates the generatable ones:

- Harbor's admin and Valkey passwords, at `harbor-admin-password`
- Flux's Slack token — the key named in `flux/notifications/externalsecret-flux-slack-app.yaml`

Until they exist, Harbor waits on its secret and Flux alerts are dropped.
Reconciliation itself is unaffected.

None of the above are cloud-abstraction failures. The shared layer reconciles
identically on both clouds; what is left is one application with a cloud baked
into its code, one policy to port, and secrets to seed.

## One identity provider, or two? — settled

ZITADEL is exposed at `auth.${public_domain_name}`, and that variable is
per-cluster — `cloud.ogenki.io` on `aws-0`, `gcp.cloud.ogenki.io` on `gcp-0` —
so there is no DNS collision either way.

[ADR-0022](../../decisions/0022-single-identity-provider-across-clouds.md) first
made ZITADEL a singleton on `aws-0`, reachable across the cloud boundary.
[ADR-0024](../../decisions/0024-identity-provider-per-cloud.md) superseded it:
the IdP is now a **per-cloud deployable component**, defaulting to AWS, so a
GCP-only platform can authenticate without an AWS cluster running. The accepted
cost is one user directory per cloud, with no federation between them. Only
public DNS stays AWS-owned ([ADR-0019](../../decisions/0019-cross-cloud-dns-federation.md)).

`gcp-0` does **not** take that opt-out: AWS is the primary cloud
([ADR-0027](../../decisions/0027-primary-cloud-provider.md)), so `aws-0` hosts
the one instance and `gcp-0` consumes it. The opt-out exists for a GCP-only
platform, where the singleton relocates rather than being duplicated — two
clouds each running a directory is ruled out, since a grant means nothing
without knowing which directory issued it.

Placement has two halves, and only one of them is typed:

| Gate | Where | Value today |
|---|---|---|
| 1 · which URL consumers read | `deploy_identity_provider`, **derived** from `primary_cloud` in `opentofu/config.tm.hcl` | `false` on `gcp-0` |
| 2 · whether an instance runs | `spec.suspend` in `clusters/gcp-0/security/zitadel.yaml` | `true` |

Gate 1 cannot disagree with the declaration, because it is the declaration.
Gate 2 is committed Flux state — Flux never reads Terramate globals — so it is
verified instead, by `./scripts/validate-idp-topology.sh` in CI. Changing which
cloud hosts is a [migration]({{< relref "/docs/guides/migrate-the-identity-provider.md" >}}),
not a toggle: the database seed, admin credential and OIDC clients travel with
it.

## Adding a third cloud

The mechanics of extending this — which values are cloud-neutral, which are
per-cluster, and what a new lane must supply — are in
[Guides → Add a cloud provider]({{< relref "/docs/guides/add-a-cloud-provider.md" >}}).
