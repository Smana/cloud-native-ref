---
title: What it costs
weight: 45
description: What the platform actually bills on each cloud, measured rather than estimated, and which lines are worth attacking.
lastVerified: 2026-09-01
---

Roughly **$700/month on AWS** and **$320/month on GCP** for the same platform at
list price, with the LLM components disabled on both.

The more useful number is smaller: **about $80/month bills on AWS even when
every cluster is destroyed**, and almost none of it is the platform.

{{< callout type="info" >}}
Measured on 2026-09-01, about one hour after bootstrapping both platforms from
scratch. AWS compute uses live spot prices per instance type, the rest published
`eu-west-3` rates — Cost Explorer actuals lag a same-day bootstrap. GCP comes
from the Cloud Billing Catalog API. These are rough estimates: node counts are
whatever the autoscalers held at snapshot time, and usage-based lines (NAT/LB
data processing, egress) are called out rather than measured.
{{< /callout >}}

## AWS — about $25/day

| Line | $/month | Notes |
|---|---:|---|
| **Spot compute, 8 nodes** | **378** | **largest single item** — 24 vCPU: the static bootstrap pair alone is $180, the 6 Karpenter nodes $198 |
| NAT gateway | 76 | $35 gateway-hours + ~$41 data processing (August actuals) |
| EKS control plane | 73 | $0.10/hr, flat |
| EBS, 753 GiB gp3 | 70 | 33 volumes |
| 3 × network load balancer | 49 | public gateway, ZITADEL, OpenBao internal |
| Secrets Manager | 34 | 84 secrets |
| KMS | 31 | 31 customer-managed keys |
| 2 × `t3.micro` on-demand | 17 | OpenBao, Tailscale subnet router |
| Kinesis | 11 | orphaned stream — still, see below |
| Public IPv4 | 4 | the NAT gateway's EIP |
| S3 | 3 | 8 buckets, ~112 GB (mostly LLM weights) |
| Route 53 | 1 | 2 hosted zones |

### CloudWatch is absent on purpose

EKS control-plane logging used to be the **largest line on the whole bill** —
**$144/month**, 20% of AWS, almost entirely `EUW3-VendedLog-Bytes` dominated by
the audit log. All five log types were on.

Nothing in this repository reads any of it. Observability is
VictoriaMetrics/VictoriaLogs, and the platform
[uses no cloud-provider monitoring on either cloud]({{< relref "/docs/platform/observability" >}}).
So it was $144/month of logs nobody could look at without first going to find
them in a console. `enabled_log_types` is now empty in
`opentofu/aws/eks/init/main.tf`.

Turn types back on deliberately if you need them. `audit` is the one worth having
during a security investigation, and it is also the expensive one — the module's
own default is `["audit", "api", "authenticator"]`.

Compute is spot throughout — measured at $0.160 (`c7i-flex.2xlarge`) and
$0.0863 (`c7i-flex.xlarge`) for the static bootstrap pair, plus 3 × $0.0405
(`c7i-flex.large`), $0.0481 (`c8i-flex.large`), $0.0477 (`m8i.large`) and
$0.0544 (`r5ad.large`) per hour for the Karpenter fleet. The Karpenter line
moves between runs; the bootstrap pair never does — Karpenter cannot
consolidate a managed node group.

## GCP — about $10/day

| Line | $/month | Notes |
|---|---:|---|
| **3 × `e2-standard-4` spot** | **161** | **largest single item** — the catalog spot rate for E2 nearly doubled since August's estimate |
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

- **Two-thirds of the gap is deployment drift**, all fixable on our side: the
  oversized static bootstrap pair (~$120), a Karpenter fleet holding twice
  GCP's vCPUs (~$85), 2.8× the provisioned disk (~$44), and secrets, keys and
  one Kinesis stream accumulated across rebuilds (~$60).
- **The remaining ~$80/month is genuinely AWS charging more**: three metered
  NLBs against forwarding rules under a flat minimum, NAT gateway-hours, the
  per-secret and per-key pricing model, and a ~10% spot premium at equal vCPUs.
  One line runs the other way — `pd-balanced` costs ~18% more per GiB than gp3.
- The control-plane fee is a wash at list price; both charge $0.10/hour.
- The comparison is structurally fair since ADR-0024: **both clouds run their
  own ZITADEL and their own OpenBao**, and only public DNS stays AWS-owned.

Until 2026-08-29 the single biggest contributor was CloudWatch at $144/month.
Removing it closed a fifth of the gap on its own.

## The floor you pay for nothing

On 2026-08-28 — a full day with no cluster on either cloud — AWS still billed
**$2.19**:

| Service | $/day | Why |
|---|---:|---|
| Secrets Manager | 0.87 | **81 secrets**; the platform provisions about 10 |
| KMS | 0.81 | **39 keys** |
| Kinesis | 0.36 | `xplane-vector-stream` in `eu-west-1` |
| S3 | 0.15 | backup buckets, which *should* outlive clusters |
| Route 53 | 0.001 | 2 zones |

Only the S3 line is deliberate — [backup buckets outlive their clusters on
purpose]({{< relref "/docs/guides/restore-a-database.md" >}}). The rest is
residue from rebuilds:

- **Secrets and KMS keys survive teardown by design.** The platform constitution
  withholds delete permissions for stateful services, so `xplane-*` IAM, S3 and
  secrets are re-adopted by name on the next deploy rather than recreated. That
  is correct, and it means nothing ever removes the ones that stop being used.
- **`xplane-vector-stream` sits in `eu-west-1`**, a region this platform does not
  deploy to at all — left from an old Vector experiment.

By 2026-09-01 the same lines had grown, not shrunk: **84 secrets, 31
customer-managed keys, and the stream still ACTIVE** — about $80/month. GCP's
equivalent floor is **under $4/month** (secret versions, backup buckets, one
DNS zone, one key version).

The pattern is worth naming: **teardown is thorough about compute and blind to
everything that outlives a cluster.** The
[EBS]({{< relref "/docs/get-started/aws/teardown.md" >}}) and PD sweeps close one
leak of exactly this shape; secrets, KMS keys and cross-region leftovers are the
same shape, unswept.

## What is worth attacking

**1. EKS control-plane logging — $144/month. Done.** It was the largest single
line and 20% of the AWS bill, every cent `EUW3-VendedLog-Bytes` dominated by the
audit log, and nothing in this repository read any of it. All five types were
enabled; the module's own default is three.

`opentofu/aws/eks/init/main.tf` now sets `enabled_log_types = []`, which changes
nothing about how the platform runs — the platform uses
[no cloud-provider monitoring on either cloud]({{< relref "/docs/platform/observability/_index.md" >}}).
Verified live on the 2026-09-01 rebuild: the log group exists with 0 stored
bytes.

Audit logs are the one signal the in-cluster stack cannot reconstruct, since the
API server writes them before anything in the cluster can observe them. If you
need them for an investigation, turn them on deliberately —
`enabled_log_types = ["audit"]` — and expect the bill to come back.

**2. The static bootstrap node group — ~$180/month for two nodes.** A
`c7i-flex.2xlarge` + `c7i-flex.xlarge` pair that exists to host what must run
before Karpenter does, and that Karpenter therefore can never consolidate. It
is the single biggest lever left on the bill: sizing the pair down is one
variable in `opentofu/aws/eks/init/main.tf` and worth on the order of
$120/month.

**3. The idle floor — now $80/month, still unswept.** Two audits later the
orphaned secrets and KMS keys have grown (84 and 31), and the stray stream is
still ACTIVE. Delete it:

```bash
aws --region eu-west-1 kinesis delete-stream \
  --stream-name xplane-vector-stream --enforce-consumer-deletion
```

**4. NAT data processing costs more than the NAT gateway** — $41/month against
$35/month of gateway-hours, from image pulls and telemetry egress. There are no
VPC endpoints configured; S3 and ECR endpoints would take most of it out.

**5. Provisioned EBS keeps growing** — 753 GiB across 33 volumes against
283 GB for the same charts on GCP. Worth one look at PVC sizes before calling
it necessary.

Together those are roughly **$300/month**, none of which requires changing what
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
- **Tear it down when you are done.** At ~$24/day, AWS costs more in three days
  than a month of the idle floor.

## Related

- [Teardown — AWS]({{< relref "/docs/get-started/aws/teardown.md" >}})
- [Teardown — GCP]({{< relref "/docs/get-started/gcp/teardown.md" >}})
- [Restore a database]({{< relref "/docs/guides/restore-a-database.md" >}}) — why
  the backup buckets are meant to keep costing money
