---
title: Cloud support
linkTitle: Cloud support
weight: 5
description: What runs on AWS, what runs on GCP, which managed service stands in for which, and the decisions that made the two lanes differ.
lastVerified: 2026-08-26
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
| Observability (VictoriaMetrics, Grafana) | ✅ | ❌ no gcp-0 overlay under `observability/` |
| Tooling (Harbor) | ✅ | ✅ Harbor on GCS with Workload Identity |
| Applications | ✅ | ❌ no `apps/gcp-0` outside the LLM platform |
| LLM platform | ⏸️ opt-in, suspended | ⏸️ opt-in, suspended — and [one gap remains](#known-gaps) |

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
| Runtime secret store | OpenBao | OpenBao | Same PKI model, one instance per cloud |
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
resources. The CloudNativePG operator itself is still deployed only on `aws-0`
(`infrastructure/aws-0/cloudnative-pg/`), so a claim on `gcp-0` needs that
overlay before it can reconcile.

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

Stated plainly rather than left for a reader to discover:

- **No observability on `gcp-0`.** `observability/` has a `base/` and an
  `aws-0/` overlay, and no gcp-0 one — so VictoriaMetrics, VictoriaLogs and
  Grafana do not run there. The base manifests are cloud-neutral; the overlay is
  simply not written yet.
- **Harbor on GCP is built but not deployed.** `tooling/gcp-0/harbor/` has the
  GCS driver and its `GCPWorkloadIdentity`, but `clusters/gcp-0/` has no
  `tooling.yaml` applying it.
- **No general applications on `gcp-0`** beyond the LLM platform's own claims.
- **The LLM platform's serving pods cannot read the weights bucket on GCP.** The
  Cloud Storage FUSE driver authenticates as the *mounting pod's* ServiceAccount,
  and the per-claim identity that would grant it is rendered by the
  `InferenceService` composition, which has no GCP branch yet. That composition
  lives in a separate repository, so it cannot be fixed from here. Details in
  `clusters/gcp-0-llm-platform/README.md`.

None of these are cloud-abstraction failures — every one is an overlay or a
composition that has not been written, on a platform whose shared layer already
reconciles identically on both clouds.

## Open question: one identity provider, or two?

ZITADEL is exposed at `auth.${public_domain_name}`, and that variable is
per-cluster — `cloud.ogenki.io` on `aws-0`, `gcp.cloud.ogenki.io` on `gcp-0`.
So the same manifest would render `auth.cloud.ogenki.io` on one cloud and
`auth.gcp.cloud.ogenki.io` on the other. **There is no DNS collision**, which is
the reassuring half of the answer.

The unresolved half is what that would mean. Two hostnames is two independent
ZITADEL instances: two user directories, two session stores, two sets of OIDC
clients, and no federation between them. For an identity provider that is
usually the wrong outcome, and it would be reached by default rather than by
decision.

Today the question is still open rather than urgent, because ZITADEL cannot run
on `gcp-0` at all — it declares a `SQLInstance`, and that claim has no GCP
implementation (see the table above). Three models are on the table:

1. **One instance on `aws-0`**, with `gcp-0` workloads authenticating across the
   cloud boundary. This mirrors the DNS decision — one authoritative service,
   reachable from the other cloud — and would be the platform's *second*
   deliberate cross-cloud dependency.
2. **Two independent instances**, which is what the current naming produces by
   default. Operationally simple, but the two clusters become separate identity
   islands.
3. **An external identity provider**, hosted by neither cloud.

No decision has been recorded yet. When one is, it belongs in an ADR alongside
[ADR-0019](../../decisions/0019-cross-cloud-dns-federation.md), for the same
reason that one exists: a dependency that crosses clouds should be argued for in
writing, not absorbed silently.

## Adding a third cloud

The mechanics of extending this — which values are cloud-neutral, which are
per-cluster, and what a new lane must supply — are in
[Guides → Add a cloud provider]({{< relref "/docs/guides/add-a-cloud-provider.md" >}}).
