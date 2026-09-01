---
title: What it costs
weight: 45
description: What the platform actually bills on each cloud, measured rather than estimated, and which lines are worth attacking.
lastVerified: 2026-09-01
---

Roughly **$575/month on AWS** and **$320/month on GCP** for the same platform at
list price, with the LLM components disabled on both.

The more useful number is smaller: **about $23/month keeps billing after every
cluster is destroyed** — and that part is by design. See
[the floor](#the-floor-you-pay-for-nothing).

{{< callout type="info" >}}
Measured on 2026-09-01, about one hour after bootstrapping both platforms from
scratch. AWS compute uses live spot prices per instance type, the rest published
`eu-west-3` rates — Cost Explorer actuals lag a same-day bootstrap. GCP comes
from the Cloud Billing Catalog API. These are rough estimates: node counts are
whatever the autoscalers held at snapshot time, and usage-based lines (NAT/LB
data processing, egress) are called out rather than measured.
{{< /callout >}}

## AWS — about $19/day

| Line | $/month | Notes |
|---|---:|---|
| **Spot compute, 6 nodes** | **331** | **largest single item** — 20 vCPU: a 2 × `m8i.large` static pair ($67) plus 4 Karpenter xlarge-class nodes ($264) |
| NAT gateway | 35+ | gateway-hours; data processing was ~$41/month before an S3 gateway endpoint was added — expect most of that gone, not yet re-measured |
| EKS control plane | 73 | $0.10/hr, flat |
| EBS, 443 GiB gp3 | 41 | 27 volumes |
| 3 × network load balancer | 49 | public gateway, ZITADEL, OpenBao internal |
| 2 × `t3.micro` on-demand | 17 | OpenBao, Tailscale subnet router |
| Secrets Manager | 16 | the ~40 secrets the platform actually reads |
| Public IPv4 | 4 | the NAT gateway's EIP |
| S3 | 3 | 8 buckets, ~112 GB (mostly LLM weights) |
| KMS | 3 | 3 keys: cluster encryption, OpenBao unseal, snapshot bucket |
| Route 53 | 1 | 2 hosted zones |

### No cloud-provider monitoring is on the bill

The platform
[runs its own observability and security stack in-cluster]({{< relref "/docs/platform/observability" >}})
— VictoriaMetrics, VictoriaLogs, Kyverno — so there is no CloudWatch, Cloud
Monitoring, GuardDuty or Security Command Center line above. EKS control-plane
logging is off for the same reason (`enabled_log_types = []` in
`opentofu/aws/eks/init/main.tf`): vended logs bill per byte, and the audit log
alone can rival the control plane itself. If you need it for an investigation,
enable it deliberately — `enabled_log_types = ["audit"]` — and expect the line
to appear.

Managed alternatives are a legitimate future direction — managed Prometheus,
provider log sinks, GuardDuty / Security Command Center would shift cost from
nodes and storage to per-signal service fees, and trade operating effort for
bill opacity. If the platform adopts any of them, that will be a recorded
decision with its price on this page, not a default left on.

Compute is spot throughout, and two experiments here are worth recording
because both under-delivered against the obvious theory:

1. **Right-sizing the static node group.** It ran xlarge/2xlarge (~$180/month
   on its own). Moving it to `m8i.large` did **not** shave that off the bill —
   Karpenter grew by almost as much to absorb the displaced pods. The pair was
   carrying real capacity, not idle headroom.
2. **Forcing fewer, larger nodes** (a 4-vCPU floor on the NodePool). Node count
   nearly halved, 10 → 6, but total consumption moved only 22 → 20 vCPU and the
   bill only $369 → $331. Per-vCPU spot pricing is near-flat between `large`
   and `xlarge`, so consolidating mostly removed **per-node overhead** (one
   fewer copy of every DaemonSet, less scheduling fragmentation) rather than
   capacity.

The generalizable lesson: on a spot fleet, **what you pay for compute is set by
what the workloads actually consume**. Node shape and count are worth tuning —
they were worth ~$38/month here, and they cut provisioned disk by half because
each node carries its own root and data volumes — but no instance-type choice
substitutes for right-sizing the workloads themselves.

## GCP — about $10/day

| Line | $/month | Notes |
|---|---:|---|
| **3 × `e2-standard-4` spot** | **161** | **largest single item** — spot catalog rates are revised by Google monthly, so this line moves |
| GKE control plane | 73 | $0.10/hr at list, same as EKS. The zonal free-tier credit ($74.40/month, one cluster per billing account) usually wipes this off the *invoice* — it is an account promotion, so it is not counted here |
| 283 GB persistent disk | 29 | 17 disks, `pd-balanced` + one `pd-standard` |
| 3 × forwarding rule | 20 | flat minimum up to 5 rules; plus data processing |
| `e2-micro` + `e2-small` | 20 | Tailscale router, OpenBao |
| Cloud NAT + IP | 9 | plus $0.045/GiB processing |
| Cloud DNS, GCS, Secret Manager, KMS | ~4 | 1 zone, ~17 GiB, 55 secret versions, 1 key |

## Why they differ

At list price AWS runs at about **1.8×** GCP. Separating what the *clouds*
charge from what *this deployment* consumes:

- **Cloud pricing accounts for roughly 1.3× of it.** Priced at identical
  consumption (12 spot vCPUs, the same disk and inventory), AWS lands near
  **$410/month** against GCP's $317: a ~25% spot premium per vCPU, three
  metered NLBs against forwarding rules under a flat minimum, NAT
  gateway-hours, and the per-secret/per-key pricing model. One line runs the
  other way — `pd-balanced` costs ~18% more per GiB than gp3 — and the
  control-plane fee is a wash: both charge $0.10/hour.
- **The rest is consumption, on our side of the ledger, and it was measured
  rather than assumed**: this deployment consumes ~20 spot vCPUs where GCP
  serves the platform on 12. Two tuning rounds narrowed it and neither closed
  it, which is the useful part — the capacity is real. What remains is genuine
  demand (AWS additionally runs Karpenter and the demo applications) plus
  scheduling slack that no instance-type choice removes.
- The comparison is structurally fair since ADR-0024: **both clouds run their
  own ZITADEL and their own OpenBao**, and only public DNS stays AWS-owned.

## The floor you pay for nothing

With every cluster destroyed, about **$23/month keeps billing** — the
platform's ~40 secrets, its 3 KMS keys, the DNS zones, and
[backup buckets that outlive their clusters on purpose]({{< relref "/docs/guides/restore-a-database.md" >}}).
That floor is a feature: **secrets, keys and backups survive teardown by
design.** The platform constitution withholds delete permissions for stateful
services, so `xplane-*` IAM, S3 and secrets are re-adopted by name on the next
deploy rather than recreated.

The flip side: nothing ever removes the ones that stop being used. Renamed or
removed components leave their secrets behind, and each rebuild can leave a key
behind, at $0.40/secret and $1/key per month. **Teardown is thorough about
compute and blind to everything that outlives a cluster** — the
[EBS]({{< relref "/docs/get-started/aws/teardown.md" >}}) and PD sweeps close
one leak of exactly this shape. If your account has lived through a few
rebuilds, audit the rest of it (keys in `PendingDeletion` cost nothing; enabled
ones bill):

```bash
aws secretsmanager list-secrets \
  --query 'SecretList[].[Name,LastAccessedDate]' --output table
aws kms list-keys --query 'Keys[].KeyId' --output text | xargs -n1 \
  aws kms describe-key --query 'KeyMetadata.[KeyState,Description]' --output text --key-id
```

## What is worth attacking

The infrastructure-shaped levers have now been pulled, and what they were
actually worth is recorded above: node shape and count (−$38/month), node
volume sizing (−$42/month), an S3 gateway endpoint for NAT data processing
(worth up to ~$41/month, not yet re-measured). What is left is not
configuration:

**1. Right-size the workloads.** ~20 vCPU is consumed for what GCP serves on
12, and two rounds of node tuning did not move that — so the remaining compute
cost is requests and replica counts, not instance types. Start with the
components that run more replicas here than they need to.

**2. Single-instance databases block node lifecycle.** A CNPG cluster with
`instances: 1` has a PodDisruptionBudget that can never permit a voluntary
eviction, so it pins its node against consolidation, drift and upgrades
indefinitely — the node has to be cordoned and the pod restarted by hand. This
is an availability and operations cost more than a billing one, and it is worth
knowing before you scale a database down to save a replica.

**3. Watch what accumulates.** Provisioned disk and node count creep back after
every rebuild; both are worth re-measuring rather than assumed stable.

## Keeping it cheap

The committed configuration is already the cheap one — spot instances
everywhere, a single-node OpenBao in `dev` mode, a zonal GKE cluster. The
expensive choices are the ones that look like defaults:

- **Spot with no on-demand fallback** on both clouds. Both reference clusters are
  throwaway; do not let a provider or module default quietly reintroduce
  on-demand capacity.
- **`mode = "dev"` for OpenBao** (`opentofu/aws/openbao/cluster/variables.tfvars`)
  is one `t3.micro`. `mode = "ha"` is five spot instances, and the configuration
  steps are identical either way.
- **Tear it down when you are done.** At ~$23/day, AWS costs more in three days
  than a month of the idle floor.

## Related

- [Teardown — AWS]({{< relref "/docs/get-started/aws/teardown.md" >}})
- [Teardown — GCP]({{< relref "/docs/get-started/gcp/teardown.md" >}})
- [Restore a database]({{< relref "/docs/guides/restore-a-database.md" >}}) — why
  the backup buckets are meant to keep costing money
