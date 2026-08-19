# GCP Support — Dual-Cloud Platform Design

**Date:** 2026-08-18
**Status:** design approved, plan pending
**Branch:** `feat/gcp-support-specs`
**ADRs:** [0005](../../decisions/0005-gke-standard-self-managed-cilium.md) (GKE flavour), [0006](../../decisions/0006-nap-computeclass-over-karpenter.md) (node autoscaling), [0007](../../decisions/0007-cloud-abstraction-boundaries.md) (abstraction rule), [0002 amended](../../decisions/0002-eks-pod-identity-over-irsa.md) (identity scope)

---

## Why this design exists

The platform runs only on AWS. Every claim that it is "cloud-native" rather than "AWS-native" is
currently untested, and the components that would break elsewhere are unknown rather than
documented.

The goal is GCP as a **second first-class cloud, maintained in parallel** — not a migration, not a
portability demo. That is the most demanding option available: every abstraction introduced needs
two genuinely working implementations, indefinitely.

Two unknowns are load-bearing and cannot be settled by reading documentation. Both are cheap to
falsify now and expensive to discover after a directory refactor and a compositions extraction have
been built on top of them:

1. **Does self-managed Cilium work on GKE?** Cilium removed its dedicated GKE installation guide
   after 1.9 (2021) and `cilium/gke` was archived in Feb 2020; Google does not support clusters
   whose CNI it does not manage. If Cilium's `cni.exclusive` fails to displace GKE's `netd` CNI
   configuration, ADR-0005 is wrong and the node-autoscaling, gateway and GPU work all need
   redesigning.
2. **Is WireGuard needed on GCP?** CLAUDE.md records `encryption.type: wireguard` as load-bearing,
   but it is a workaround for [cilium#43493](https://github.com/cilium/cilium/issues/43493) — the
   BPF ipcache `hastunnel` flag under **ENI mode with prefix delegation**. GCP uses
   `ipam.mode=kubernetes`, so that path should not be reached. Carrying WireGuard unnecessarily
   costs throughput and signals that the platform does not understand its own workaround.

## Verified during design (evidence, not assumption)

| Question | Finding | Source |
|---|---|---|
| Is there a current Cilium-on-GKE recipe? | Yes — the GKE Clustermesh Prep page carries a working recipe for the **exact pinned version** (1.20.0): `--enable-ip-alias`, explicit `--cluster-ipv4-cidr`/`--services-ipv4-cidr`, `--node-taints node.cilium.io/agent-not-ready=true:NoSchedule`, then `cilium install` | [docs.cilium.io](https://docs.cilium.io/en/latest/network/clustermesh/gke-clustermesh-prep/) |
| Must Dataplane V2 be disabled? | It is **opt-in** on Standard (default only on Autopilot), and there is no deprecation notice on the legacy datapath. So: do not enable it. It is **create-time only** — a mistake means cluster replacement | [GKE DPv2](https://docs.cloud.google.com/kubernetes-engine/docs/concepts/dataplane-v2), [gcloud ref](https://docs.cloud.google.com/sdk/gcloud/reference/container/clusters/create) |
| Is Karpenter viable on GCP? | No. `karpenter-provider-gcp` is community (CloudPilot AI), preview/alpha, explicitly not production-ready. Azure's equivalent reached GA; GCP's has not | [cloudpilot-ai/karpenter-provider-gcp](https://github.com/cloudpilot-ai/karpenter-provider-gcp) |
| Can GKE autoscaling satisfy Cilium's taint requirement? | Yes — `ComputeClass` exposes `nodePoolConfig.taints[]` **on auto-created pools**, plus `nodePoolConfig.imageType` to pin the node OS. This was the assumption most likely to break the whole approach | [ComputeClass CRD](https://docs.cloud.google.com/kubernetes-engine/docs/reference/crds/computeclass) |
| How does GCP workload identity compare to EPI? | Modern GCP binds IAM **directly to the KSA principal** — `principal://iam.googleapis.com/projects/<NUMBER>/locations/global/workloadIdentityPools/<ID>.svc.id.goog/subject/ns/<NS>/sa/<KSA>` — no Google service account, no `iam.gke.io/gcp-service-account` annotation. Structurally the *same* model as EKS Pod Identity, not IRSA | [GKE WIF](https://docs.cloud.google.com/kubernetes-engine/docs/how-to/workload-identity) |

## Framing decisions

Recorded as ADRs so they are not restated per-slice.

| Decision | Outcome |
|---|---|
| End state | Dual-cloud, both maintained |
| GKE flavour | **Standard + self-managed Cilium** (ADR-0005). Driven by Gateway API + Tailscale: both private gateways are `GatewayClass`es whose `parametersRef` points at a `CiliumGatewayClassConfig` setting `loadBalancerClass: tailscale`. Dataplane V2 has no such CRD and no `io.cilium/gateway-controller`, so it would mean rebuilding both gateways on a second Gateway implementation and losing the Envoy JSON access-log pipeline into VictoriaLogs |
| Node autoscaling | **GKE NAP via `ComputeClass`** (ADR-0006), not Karpenter |
| Abstraction rule | **Cloud-shaped platform APIs, neutral developer APIs** (ADR-0007). Platform-facing gets sibling per-cloud APIs; developer-facing gets a neutral surface with provider knobs quarantined in optional `aws {}` / `gcp {}` blocks |
| Workload identity | Sibling XRDs — `EPI` untouched, new `GCPWorkloadIdentity`. Avoids delete-and-create against live IAM roles, and `spec.policyDocument` (IAM JSON) has no honest neutral form |
| Object storage API | `spec.s3Bucket` → `spec.objectStore` with a per-cloud escape hatch. Developer-facing, so portability is worth the breaking change |
| Repo topology | Monorepo, cloud-partitioned, **plus** extraction of Crossplane XRDs/KCL modules to a dedicated OCI-released repo |
| Cost posture | Match the AWS intent, which is aggressive (see below) |

### Cost posture

The AWS side is more cost-optimised than it first appears, and GCP must match the *intent*, not just
work. `opentofu/eks/init/main.tf` runs even the **bootstrap** node group on `capacity_type = "SPOT"`
(min 2 / max 3) across 6 diversified instance types, pinned to one subnet with the comment *"Use a
single subnet for costs reasons"*. All three Karpenter pools are spot-first, `default` is
spot-**only**, and each carries a hard ceiling (`cpu 60/mem 192Gi`, `cpu 20/mem 64Gi`,
`nvidia.com/gpu: 4`).

Four mechanisms, and their GCP fate:

| AWS mechanism | GCP equivalent |
|---|---|
| Spot-first / spot-only capacity | `priorities[].spot` ✅ |
| Instance-size bounding (blast radius + cost) | `priorities[].machineFamily`/`machineType` ✅ |
| Hard **per-pool** resource ceiling | ⚠️ cluster-scoped `resourceLimits` only — three ceilings collapse into one, losing per-profile isolation |
| Consolidation (`WhenEmptyOrUnderutilized`) | ❌ **no equivalent** — document, do not emulate |

Two GCP-only levers with no AWS analogue, both **create-time** and awkward to retrofit:

- **Disable workload Cloud Logging/Monitoring.** VictoriaLogs and VictoriaMetrics already do this
  job; the GKE defaults bill for a duplicate pipeline nobody reads.
- **Private Google Access** on the node subnet, so Cloud NAT does not bill for Google API traffic.

One free win: private services use `loadBalancerClass: tailscale`, which creates a Tailscale device
rather than a GCP forwarding rule — no cloud load-balancer charges for the private gateways.

One AWS technique does **not** port: a GKE node pool takes a single machine type, so the 6-way
instance diversification that blunts spot interruption is unavailable. Spot risk concentrates on one
shape, which argues for keeping the static pool small and letting `ComputeClass` supply breadth.

---

## Scope split

Value-first: a **working GCP cluster** before enabling refactors. The directory refactor and
compositions extraction are deliberately not first — the first slice is purely additive (it moves no
existing AWS file), so those refactors are unblocked either way and are cheaper once the GCP shape is
known rather than predicted.

### In scope for the first plan

| # | Slice | Why first |
|---|---|---|
| 1 | GCP network — VPC, subnets + secondary ranges, Cloud DNS, Tailscale subnet router on GCE | Nothing is reachable without it; private control plane needs the tailnet |
| 2 | GKE Standard cluster + **static** tainted node pool + `--workload-pool` | Mirrors AWS: `eks/init` creates managed node groups before Karpenter arrives |
| 3 | Cilium (`ipam.mode=kubernetes`) + Flux bootstrap | Settles unknown #1 and #2 |
| 4 | Node autoscaling — three `ComputeClass` objects | Settles the taint-propagation risk; gates GPU/LLM work |
| 5 | `GCPWorkloadIdentity` XRD + Crossplane GCP provider plumbing | Gates every remaining workstream |

### Deferred (later plans)

> **Amendment (2026-08-19) — workstreams 6 and 7 are swapped.**
>
> This table originally had **7 depend on 6**: extract the compositions *after* the directory
> refactor. The Crossplane Configuration Extraction design reverses it, and that reversal stands.
> (That design lives on branch `feat/crossplane-configuration-extraction` as
> `docs/superpowers/specs/2026-08-18-crossplane-configuration-extraction-design.md` — not yet
> merged, so it is named rather than linked here.) Two reasons, both load-bearing:
>
> 1. The refactor's job is to partition the repo by cloud. Doing it first means partitioning ~40
>    files that are about to leave the repository entirely.
> 2. The extraction is what *forces* the AWS coupling to become explicit — it measured the seam and
>    found three of five APIs are mixed (`App`, `SQLInstance` cloud-neutral contracts with AWS
>    slices; `EPI` wholly AWS). That measurement is the input the refactor needs, so producing it
>    first makes the refactor cheaper and better-informed rather than the other way round.
>
> The repository is named **`crossplane-configuration`**, not `ogenki-compositions` as written
> below — see that design's *Naming* section for the namespace research behind the choice. It ships
> two packages, `-core` and `-aws`, with XRDs in `-core` and cloud-coupled Compositions in `-aws`.
>
> Workstream 15 (`per-cloud schema catalogs`) is also affected: once the XRDs leave, the catalog
> sources them from a release asset rather than a local glob. That seam exists in
> `gen-catalog.sh` today via `XRD_CRDS_FILE`, verified to produce byte-identical schemas.

| # | Workstream | Depends on |
|---|---|---|
| 6 | Directory refactor to cloud-partitioned layout | 3, **7** |
| 7 | Extract the Crossplane Configuration packages, OCI-released | 3 |
| 8 | `objectStore` API migration + `App`/`SQLInstance` branching | 5, 7 |
| 9 | Object-storage call sites: Harbor (GCS driver), `openbao-snapshot` (GCS + Cloud KMS), CNPG barman (GCS) | 5, 8 |
| 10 | DNS + PKI: `external-dns` google provider, cert-manager clouddns DNS-01 | 5 |
| 11 | OpenBao on GCP: MIG + internal LB + Cloud KMS auto-unseal | 1 |
| 12 | Gateway/LB: GCP public-LB annotations, drop `aws-load-balancer-controller` | 3 |
| 13 | Storage: `gp3` → `pd-balanced`/hyperdisk, EFS CSI → Filestore CSI | 3 |
| 14 | GPU + LLM platform: GPU `ComputeClass`, GCS Fuse weights, no `runtimeclass-nvidia` | 4, 9 |
| 15 | CI: `validate-manifests.sh` renders both clouds; Renovate; per-cloud schema catalogs | 6 |

### Already cloud-agnostic (verified — do not touch)

OpenBao itself (`openbao/management` uses only the `bao` provider), External Secrets, Envoy Gateway,
Envoy AI Gateway, VictoriaMetrics/Logs/Traces, Grafana Operator, KEDA, Zitadel, Harbor-the-app,
CloudNativePG-the-operator, Atlas Operator, Tailscale operator, Headlamp, Homepage, Dagger engine,
GHA runners, vLLM/`InferenceService`, and Cilium itself modulo the values divergence below.

---

## Architecture

### OpenTofu layout (additive — no existing file moves)

```
opentofu/gcp/
├── network/     VPC, node subnet, pod+service secondary ranges, Cloud DNS private zone,
│                Tailscale subnet router, Cloud NAT + Private Google Access
└── gke/
    ├── init/      GKE Standard (DPv2 not enabled), static tainted pool, --workload-pool,
    │              Crossplane WIF binding, Gateway API CRDs, helm_values/cilium.yaml
    └── configure/ Cilium then Flux Operator + Flux Instance

clusters/gcp-mycluster-0/   new sibling of clusters/mycluster-0/
```

Two-stage deploy mirrors EKS, for the same reason: the Helm provider needs a cluster endpoint at
plan time. `cd opentofu/gcp/gke/init && terramate script run deploy` runs both stages.

### Cilium values divergence

`cilium_version` stays a **shared** global in `opentofu/config.tm.hcl` so both clouds upgrade
together. The values **file is forked**, not templated: with two clouds and ~8 divergent keys,
duplicating ~130 lines is cheaper than a merge mechanism that hides what Cilium actually receives —
and "we don't understand what Cilium is doing on an unsupported path" is precisely the risk being
managed. Revisit at cloud three.

| Key | AWS | GCP |
|---|---|---|
| `ipam.mode` | `eni` | `kubernetes` (host-scope from `spec.podCIDR`; GKE alias IP ranges route natively) |
| `eni:` block, `cilium-cni-config.tf` | prefix-delegation ConfigMap | **deleted — no counterpart** |
| `routingMode` | `native` | `native` |
| `encryption.type` | `wireguard` (cilium#43493) | **expected unnecessary** — verify before removing the CLAUDE.md note |
| `kubeProxyReplacement`, `gatewayAPI`, `hubble` | — | port unchanged |

### Node autoscaling

Three `ComputeClass` objects replace six Karpenter manifests (`{default,io,gpu-l4}` ×
`NodePool`+`EC2NodeClass`). Each sets `nodePoolConfig.taints[]` carrying
`node.cilium.io/agent-not-ready=true:NoSchedule` and pins `imageType`. `priorities[]` is ordered
spot-first, with `default` spot-**only** to match AWS. A small static pool is retained because
`ComputeClass` cannot express `min > 0`.

`infrastructure/base/runtimeclass-nvidia/` is **not ported** — it is Bottlerocket-specific (that AMI
pre-configures an `nvidia` containerd handler and advertises `nvidia.com/gpu` natively). GKE installs
drivers via its own managed installer and advertises the resource with no `RuntimeClass`.

### GCPWorkloadIdentity

```yaml
apiVersion: cloud.ogenki.io/v1alpha1
kind: GCPWorkloadIdentity
metadata: { name: external-dns, namespace: infrastructure }
spec:
  serviceAccount: { name: external-dns, namespace: infrastructure }
  roles: [roles/dns.admin]              # predefined roles, named as GCP names them
  customRole:                            # optional — creates + binds a custom role
    permissions: [dns.resourceRecordSets.create]
```

Renders one **`ProjectIAMMember`** per role, member = the `principal://` KSA string, plus a
`ProjectIAMCustomRole` when `customRole.permissions` is set. No Google service account, no
annotation. `xplane-*` prefix owned by the composition.

**Two hard constraints, both silent-failure classes:**

- **Additive IAM only.** `ProjectIAMPolicy` and `ProjectIAMBinding` are *authoritative* — they
  overwrite the policy for the roles they manage. In a composition that renders once per workload,
  either would delete other workloads' and humans' bindings. `external-dns` and `cert-manager` both
  need Cloud DNS access, so this breaks immediately, and silently, until something unrelated loses
  permissions.
- **`PROJECT_NUMBER` and `PROJECT_ID` sit in different segments** of the principal string:
  `projects/` takes the **number**, `workloadIdentityPools/` takes the **ID**. Reversed, the API
  accepts the binding and it simply never matches — a permission error pointing nowhere. Must be
  asserted as an exact string in `main_test.k`.

**Chicken-and-egg:** Crossplane cannot create the binding that grants Crossplane access. The GKE
`init` stage must bootstrap Crossplane's own WIF binding in OpenTofu, exactly as the AWS side
bootstraps its Pod Identity. Slice 5 is blocked without it.

---

## Goal & success criteria

Falsifiable, verified against a live cluster.

**Slices 1–3 (cluster foundation)**

1. `cilium status --wait` all OK; `cilium`/`cilium-envoy` pods `Running`, 0 restarts, ≥2 nodes.
2. **Only Cilium's CNI config is active in `/etc/cni/net.d/`** — GKE's `netd` displaced. *If this
   fails, stop and revisit ADR-0005 before any further GCP work.*
3. With `encryption` unset, an `HTTPRoute` through a Cilium Gateway to a backend pod **on another
   node** returns 200 across 100 consecutive requests, 0 failures (the cilium#43493 check).
4. `flux get kustomizations -A` and `helmreleases -A` all `Ready=True`.
5. `kubectl get nodes` works against the **private** endpoint from a tailnet device, no public
   endpoint.
6. No GCP CIDR (node/pod/service/control-plane) overlaps any AWS range advertised into the tailnet —
   both clusters share one tailnet, so an overlap breaks subnet routing in a way that looks like a
   Cilium bug.
7. Second `terramate script run deploy` produces a 0-change plan.
8. `hubble observe --verdict DROPPED --last 50` returns results.
9. All static-pool nodes report `cloud.google.com/gke-spot=true`, in a single zone.
10. Workload Cloud Logging **and** Monitoring disabled; Private Google Access enabled on the node
    subnet.
11. A written monthly run-rate estimate exists (cluster fee, static pool, Cloud NAT, Cloud DNS,
    Tailscale instance) stating the zonal-vs-regional choice and its price delta.

**Slice 4 (autoscaling)**

12. A **freshly auto-created** node carries `node.cilium.io/agent-not-ready` at registration, and
    Cilium clears it. *This is the criterion the slice exists to test.*
13. Across 5 scale-up cycles, 0 pods record `FailedCreatePodSandBox` referencing a missing CNI.
14. `imageType` on every auto-created pool matches the pinned value; general-purpose nodes are
    spot with **zero** on-demand fallback.
15. A GPU pod with **no** `runtimeClassName` sees the device via `nvidia-smi`.
16. Cluster `resourceLimits` set; an oversized workload stays `Unschedulable` at the ceiling.
17. Empty auto-created pools are removed on scale-down.

**Slice 5 (identity)**

18. A pod calls its granted Google API with **no** key mounted and no `iam.gke.io` annotation.
19. `gcloud projects get-iam-policy` shows the member in exact `principal://.../ns/<NS>/sa/<KSA>`
    form.
20. `grep -rE 'ProjectIAMPolicy|ProjectIAMBinding'` finds no match in the composition; two claims
    coexist; a manually-created binding survives a full reconcile.
21. `external-dns` creates a Cloud DNS record and `cert-manager` completes a DNS-01 challenge using
    only the binding.
22. `git diff --stat` shows **zero** changes under `security/base/epis/` or to the `EPI`
    XRD/composition/module.

---

## Non-goals

- Migrating any AWS workload, or removing Karpenter from AWS.
- Generalising `EPI` into a neutral `WorkloadIdentity` XRD (ADR-0007).
- Any cloud-neutral façade over `NodePool`/`ComputeClass` — the two differ in *behaviour*, not
  syntax, and a shared surface would hide exactly the divergence that needs documenting.
- Replicating Karpenter consolidation. Documented as a gap; **not** emulated with a custom drain
  controller, which would put a bespoke component in the scheduling path to imitate a managed
  feature.
- Cross-project or cross-organisation identity federation.
- GCP Secret Manager for External Secrets — OpenBao-backed and already agnostic.
- Rescoping CLAUDE.md's WireGuard note *as a requirement*. It is a task gated on criterion 3; a
  documented invariant should not change on the strength of a docs read.

---

## Implementation outline (sketch — full plan from `superpowers:writing-plans`)

1. **Gate first.** Throwaway GKE Standard cluster: prove criteria 2 and 3 before writing any
   OpenTofu. If either fails, stop and reopen ADR-0005.
2. CIDR plan against the AWS ranges already in the tailnet; resolve region/zone, DNS zone naming and
   node image type.
3. `opentofu/gcp/network/`, then `gke/init/` (including the Crossplane WIF binding), then
   `gke/configure/`.
4. `clusters/gcp-mycluster-0/` minimum viable Flux tree — excluding `aws-load-balancer-controller`,
   `aws-efs-csi-driver`, Karpenter, `runtimeclass-nvidia`.
5. **Gate again.** One `ComputeClass` proving criterion 12 before writing the other two; fallback is
   static pools + cluster autoscaler (ADR-0006 option 3).
6. `GCPWorkloadIdentity` — confirm the API group from installed CRDs *first*, then XRD, KCL module
   (TDD, principal string asserted), then convert `external-dns` and `cert-manager` as proof.

---

## Risks & open questions

**Risks**

| Risk | Mitigation |
|---|---|
| `cni.exclusive` does not displace GKE's `netd` | Gate task on a throwaway cluster before any OpenTofu is written. Fallback: Dataplane V2, which costs a second Gateway implementation |
| DPv2 is create-time only | The gate cluster is disposable; the real cluster is created once the datapath choice is proven |
| Taint not propagated to auto-created nodes | Prove on one `ComputeClass` before writing three. Fallback: static pools + cluster autoscaler |
| Authoritative IAM kinds used by mistake | Forbidden in the design; enforced by a grep plus positive coexistence tests |
| Reversed `PROJECT_NUMBER`/`PROJECT_ID` | Exact-string assertion in `main_test.k` |
| Spot preemption concentrated on one machine type | Keep the static pool small; breadth from `ComputeClass`, not on-demand fallback |
| Crossplane informer stalls after CRD activation | Known trap — `kubectl auth can-i` first, then restart the controller |

**Open questions**

- GCP region and zone topology; zonal vs regional control plane (material cost difference).
- Private DNS zone naming — `priv.gcp.cloud.ogenki.io` sibling, or one zone shared across clouds?
- Node image type: `cos_containerd` (GKE default) or `ubuntu_containerd` (more familiar kernel for
  debugging an unsupported path)?
- GCP machine families for the `default`/`io` equivalents; retained static pool size; cluster
  `resourceLimits` values. Three of these need a measurement off the **AWS** cluster first — the
  always-on controller footprint and what the `io` pool actually serves. No GCP access required.
- **Exact namespaced API group for Crossplane GCP v2.** AWS uses `iam.aws.m.upbound.io/v1beta1`;
  GCP is *expected* to be `cloudplatform.gcp.m.upbound.io/v1beta1`, but `provider-gcp-cloudplatform`
  v2.6.0 reference pages still document the cluster-scoped `cloudplatform.gcp.upbound.io`. Must be
  confirmed against installed CRDs, never inferred.
- One Crossplane control plane per cluster, or one managing both clouds?
- Where do Flux's GitHub App credentials come from on GCP? They live in AWS Secrets Manager today;
  reading them from GCP would create a hard AWS dependency in the GCP bootstrap. Likely a GCP Secret
  Manager copy first, OpenBao once workstream 11 lands.
- Does the `ogenki-compositions` split absorb the App Wizard split already designed elsewhere?

**External prerequisite:** a GCP project with billing and APIs enabled, plus a Tailscale auth path
for a second cloud. Nothing past the gate task can be verified without it.

---

## Quality gates the PR must pass before merge

- `tofu validate` and `tofu fmt -check -recursive opentofu/gcp/`
- `trivy config --exit-code=1 --ignorefile=./.trivyignore.yaml .`
- `./scripts/validate-manifests.sh` → exit 0 with **`Invalid: 0, Skipped: 0`** (a skipped resource is
  an unvalidated one)
- `./scripts/validate-kcl-compositions.sh` → exit 0, and `kcl test` (needs `-Y settings-example.yaml`)
- `crossplane render` succeeds for the basic and complete `GCPWorkloadIdentity` examples
- `pre-commit run --all-files`
- Live-cluster evidence cited for every success criterion above, per
  [`.claude/rules/process.md`](../../../.claude/rules/process.md)
