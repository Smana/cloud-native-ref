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
| **Spot compute, 8 nodes** | **378** | **largest single item** — 24 vCPU: the static bootstrap pair alone is $180, the 6 Karpenter nodes $198 |
| NAT gateway | 76 | $35 gateway-hours + ~$41 data processing (measured) |
| EKS control plane | 73 | $0.10/hr, flat |
| EBS, 753 GiB gp3 | 70 | 33 volumes |
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

Compute is spot throughout — measured at $0.160 (`c7i-flex.2xlarge`) and
$0.0863 (`c7i-flex.xlarge`) for the static bootstrap pair, plus 3 × $0.0405
(`c7i-flex.large`), $0.0481 (`c8i-flex.large`), $0.0477 (`m8i.large`) and
$0.0544 (`r5ad.large`) per hour for the Karpenter fleet. The Karpenter line
moves between runs; the bootstrap pair never does — Karpenter cannot
consolidate a managed node group.

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

At list price AWS runs at about **2.2×** GCP — but most of that is not cloud
pricing. Re-price AWS at gcp-0's exact footprint (12 spot vCPUs, 283 GB of
disk, a trimmed secret/key inventory) and it lands near **$400/month**, about
**1.3×** GCP:

- **Most of the gap is deployment drift**, all fixable on our side: the
  oversized static bootstrap pair (~$120), a Karpenter fleet holding twice
  GCP's vCPUs (~$85), 2.8× the provisioned disk (~$44), and smaller inventory
  differences for the rest.
- **The remaining ~$80/month is genuinely AWS charging more**: three metered
  NLBs against forwarding rules under a flat minimum, NAT gateway-hours, the
  per-secret and per-key pricing model, and a ~10% spot premium at equal vCPUs.
  One line runs the other way — `pd-balanced` costs ~18% more per GiB than gp3.
- The control-plane fee is a wash at list price; both charge $0.10/hour.
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

**1. The static bootstrap node group — ~$180/month for two nodes.** A
`c7i-flex.2xlarge` + `c7i-flex.xlarge` pair that exists to host what must run
before Karpenter does, and that Karpenter therefore can never consolidate. It
is the single biggest lever on the bill: sizing the pair down is one variable
in `opentofu/aws/eks/init/main.tf` and worth on the order of $120/month.

**2. NAT data processing costs more than the NAT gateway** — $41/month against
$35/month of gateway-hours, from image pulls and telemetry egress. There are no
VPC endpoints configured; S3 and ECR endpoints would take most of it out.

**3. Provisioned EBS keeps growing** — 753 GiB across 33 volumes against
283 GB for the same charts on GCP. Worth one look at PVC sizes before calling
it necessary.

Together those are roughly **$200/month**, none of which requires changing what
the platform does.

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
