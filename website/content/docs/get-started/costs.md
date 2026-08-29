---
title: What it costs
weight: 45
description: What the platform actually bills on each cloud, measured rather than estimated, and which lines are worth attacking.
lastVerified: 2026-08-29
---

Roughly **$730/month on AWS** and **$220/month on GCP** for the same platform,
with the LLM components disabled on both.

The more useful number is smaller: **$66/month bills on AWS even when every
cluster is destroyed**, and almost none of it is the platform.

{{< callout type="info" >}}
Measured on 2026-08-29 against both reference clusters, LLM platform suspended.
The AWS figures come from Cost Explorer actuals plus live spot prices. The GCP
figures are **rate-card estimates** — the billing API is reachable but exposes no
spend without a BigQuery export — so treat them as ±20%.
{{< /callout >}}

## AWS — about $24/day

| Line | $/month | Notes |
|---|---:|---|
| **CloudWatch vended logs** | **144** | **largest single item** — EKS control-plane logging |
| Spot compute, 6 nodes | 250 | measured spot rates, `eu-west-3` |
| NAT gateway | 76 | $35 gateway-hours + $41 data processing |
| EKS control plane | 73 | $0.10/hr, flat |
| EBS, 563 GiB gp3 | 54 | 27 volumes |
| 3 × network load balancer | 49 | public gateway, ZITADEL, OpenBao internal |
| KMS | 29 | 39 keys |
| Secrets Manager | 26 | 81 secrets |
| 2 × `t3.micro` on-demand | 17 | OpenBao, Tailscale subnet router |
| Kinesis | 11 | orphaned stream |
| S3 | 10 | 7 buckets |
| Route 53 | 1 | 2 hosted zones |

Compute is spot throughout — the six nodes measured at $0.0688 (`t3a.xlarge`),
$0.0747 (`c5.xlarge`), $0.0428 (`c6i.large`), $0.0401 (`m5.large`) and $0.0471
(`m8i.large`) per hour. Node count varies with what Karpenter has provisioned, so
this line moves the most between runs.

## GCP — about $7/day

| Line | $/month | Notes |
|---|---:|---|
| **3 × `e2-standard-4` spot** | **88** | **largest single item** |
| 3 × forwarding rule | 54 | 2 external, 1 internal |
| Cloud NAT | 32 | plus data processing |
| 273 GB `pd-balanced` | 27 | 16 disks |
| `e2-micro` + `e2-small` | 18 | Tailscale router, OpenBao |
| GKE control plane | 0 | zonal — assumed covered by the free zonal-cluster tier; **+$73 if not** |
| Cloud DNS, GCS, Secret Manager | ~3 | 1 zone, 4 buckets, 28 secrets |

GCP runs at roughly **a third of AWS** for the same workload. Very little of that
gap is compute. It is CloudWatch, NAT data processing, and the accumulated cruft
below.

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

The pattern is worth naming: **teardown is thorough about compute and blind to
everything that outlives a cluster.** The
[EBS]({{< relref "/docs/get-started/aws/teardown.md" >}}) and PD sweeps close one
leak of exactly this shape; secrets, KMS keys and cross-region leftovers are the
same shape, unswept.

## What is worth attacking

**1. EKS control-plane logging — $144/month, 20% of the AWS bill.** Every cent of
it is `EUW3-VendedLog-Bytes`, dominated by the audit log, and nothing in this
repository reads any of it. `opentofu/aws/eks/init/main.tf` turns on **all five**
types:

```hcl
enabled_log_types = [
  "api", "audit", "authenticator", "controllerManager", "scheduler"
]
```

The module's own default is the first three; `controllerManager` and `scheduler`
were added on top. Dropping to the types you actually consult — or to `[]` on a
throwaway cluster — is the single biggest saving available, and changes nothing
about how the platform runs.

**2. The idle floor — $66/month.** Sweep the orphaned secrets and KMS keys, and
delete the stray stream:

```bash
aws --region eu-west-1 kinesis delete-stream \
  --stream-name xplane-vector-stream --enforce-consumer-deletion
```

**3. NAT data processing costs more than the NAT gateway** — $41/month against
$35/month of gateway-hours, from image pulls and telemetry egress. There are no
VPC endpoints configured; S3 and ECR endpoints would take most of it out.

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
- **Tear it down when you are done.** At ~$24/day, AWS costs more in three days
  than a month of the idle floor.

## Related

- [Teardown — AWS]({{< relref "/docs/get-started/aws/teardown.md" >}})
- [Teardown — GCP]({{< relref "/docs/get-started/gcp/teardown.md" >}})
- [Restore a database]({{< relref "/docs/guides/restore-a-database.md" >}}) — why
  the backup buckets are meant to keep costing money
