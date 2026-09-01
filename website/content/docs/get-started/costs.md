---
title: What it costs
weight: 45
description: A rough monthly estimate of what the platform costs on each cloud, and how the two compare on equal terms.
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
| NAT gateway | 35+ | gateway-hours. Data processing is billed on top and can match it — an S3 gateway endpoint takes out most of that traffic |
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

Compute is spot throughout, and it is the line most worth understanding before
trying to shrink it. Spot pricing per vCPU is close to flat across instance
sizes, so **consolidating onto fewer, larger nodes saves per-node overhead —
one fewer copy of every DaemonSet, less scheduling fragmentation, fewer root
and data volumes — rather than capacity.** That is worth having (it also cuts
provisioned disk, since every node carries its own volumes), but it is a
second-order saving. What sets this line is what the workloads request.

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
- **The rest is consumption, not pricing**: this deployment consumes ~20 spot
  vCPUs on AWS where GCP serves the platform on 12, and provisions more block
  storage. Some of that is real (AWS additionally runs Karpenter and the demo
  applications), some is scheduling slack. Either way it is a property of how
  the platform is deployed, not of what the cloud charges — which is why the
  headline ratio and the like-for-like ratio differ so much.
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
- **Tear it down when you are done.** At ~$19/day, AWS costs more in two days
  than a month of the idle floor.

## Related

- [Teardown — AWS]({{< relref "/docs/get-started/aws/teardown.md" >}})
- [Teardown — GCP]({{< relref "/docs/get-started/gcp/teardown.md" >}})
- [Restore a database]({{< relref "/docs/guides/restore-a-database.md" >}}) — why
  the backup buckets are meant to keep costing money
