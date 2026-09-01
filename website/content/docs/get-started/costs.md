---
title: What it costs
weight: 45
description: What the platform actually bills on each cloud, measured rather than estimated, and which lines are worth attacking.
lastVerified: 2026-09-01
---

Roughly **$690/month on AWS** and **$320/month on GCP** for the same platform at
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

## AWS — about $23/day

| Line | $/month | Notes |
|---|---:|---|
| **Spot compute, 10 nodes** | **369** | **largest single item** — 22 vCPU: a 2 × `m8i.large` static pair ($69) plus 8 Karpenter-provisioned nodes ($300), measured after right-sizing the static pair and letting Karpenter settle |
| NAT gateway | 76 | $35 gateway-hours + ~$41 data processing (measured) |
| EKS control plane | 73 | $0.10/hr, flat |
| EBS, ~900 GiB gp3 | 83 | 35 volumes |
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

Compute is spot throughout, and one measurement here is worth recording: the
static pair was originally xlarge/2xlarge (~$180/month on its own), and
right-sizing it to `m8i.large` did **not** shave that off the bill — Karpenter
grew by almost the same amount to absorb the displaced pods. The pair was
carrying real capacity, not idle headroom. The lesson generalizes: what this
platform pays for compute is set by what it *consumes*, and by node
granularity — every extra node carries its own copy of the DaemonSet overhead
(Cilium, CSI, exporters), which favors fewer, larger nodes over many small
ones.

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

At list price AWS runs at about **2.2×** GCP. Separating what the *clouds*
charge from what *this deployment* consumes:

- **Cloud pricing accounts for roughly 1.3× of it.** Priced at identical
  consumption (12 spot vCPUs, the same disk and inventory), AWS lands near
  **$410/month** against GCP's $317: a ~25% spot premium per vCPU, three
  metered NLBs against forwarding rules under a flat minimum, NAT
  gateway-hours, and the per-secret/per-key pricing model. One line runs the
  other way — `pd-balanced` costs ~18% more per GiB than gp3 — and the
  control-plane fee is a wash: both charge $0.10/hour.
- **The rest is consumption, on our side of the ledger, and it was measured
  rather than assumed**: the AWS deployment consumes ~22 spot vCPUs where GCP
  serves the platform on 12. Right-sizing the static pair did not close it —
  the capacity simply moved to Karpenter. The drivers are node granularity
  (ten 2-vCPU nodes pay ten copies of the per-node DaemonSet overhead; GCP
  packs onto three 4-vCPU machines), scheduling fragmentation on small nodes,
  3× the provisioned block storage, and a few AWS-only components (Karpenter
  itself, the demo applications).
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

**1. Node granularity.** The measured lesson above: the fleet runs ten mostly
2-vCPU nodes, each carrying its own copy of the DaemonSet overhead. Steering
Karpenter toward fewer, larger instances (NodePool requirements or
consolidation preferences) is now the biggest compute lever — plausibly on the
order of $100/month. (Right-sizing the static pair is already done; it moved
capacity to Karpenter rather than removing it, which is how we know the
remaining lever is granularity, not node-group sizing.)

**2. NAT data processing costs more than the NAT gateway** — $41/month against
$35/month of gateway-hours, from image pulls and telemetry egress. There are no
VPC endpoints configured; S3 and ECR endpoints would take most of it out.

**3. Provisioned EBS keeps growing** — ~900 GiB across 35 volumes against
283 GB for the same charts on GCP. Worth one look at PVC sizes before calling
it necessary.

Together those are plausibly **$150–200/month**, none of which requires
changing what the platform does.

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
