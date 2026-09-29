---
title: GCP is the primary cloud; AWS keeps the essentials
linkTitle: 0052 · GCP primary
weight: 520
description: The agent factory and the platform run on one cluster, and running aws-0 beside gcp-0 doubles cost and operations for no user. GCP becomes primary with a ZITADEL directory that is fresh on every build; AWS keeps only Route53, the federation, the state bucket and the OpenBao lineage stacks.
lastVerified: 2026-09-29
---

**Status:** Proposed (2026-09-29): validated on `integration/agent-factory`, not merged to `main` (owner,
2026-09-29) · **Supersedes in part, once accepted:**
[ADR-0027]({{< relref "/docs/decisions/0027-primary-cloud-provider.md" >}})'s "relocation carries the
directory's data"

## Context

The agent factory and the platform run on one cluster. Running aws-0 and gcp-0 side by side doubles the cost
and the operations for no user. ADR-0027 made placement a single switch, `primary_cloud`.

## Decision

- **GCP is primary.** gcp-0 hosts ZITADEL and runs against GCP's own OpenBao lineage (`gcpckms`).
- **AWS keeps four things:** the Route53 zone, the AWS↔GCP federation (`opentofu/shared/aws-gcp-federation`),
  the S3 state bucket, and the OpenBao lineage stacks. No AWS cluster, no AWS OpenBao server.
- **The directory is fresh on every build.** Its masterkey, database-user and first-human passwords are
  generated in-cluster by ESO `Password` generators, and it is never restored. The deploy re-registers the
  Google IdP, the groups Action and every OIDC client. The owner logs in once and re-grants.
- **One key is not generated in-cluster: the CNPG superuser.** The SQLInstance composition reads
  `cnpg-xplane-zitadel-superuser` from Secret Manager, and CNPG needs it before the cluster exists. The
  deploy's seed step (`secret-store.sh seed`, gke/init stage 0) generates it when absent and never overwrites
  it. ZITADEL reads its database admin from the resulting `xplane-zitadel-cnpg-superuser` Secret, so the two
  cannot disagree.
- **The one owner-written exception:** the agents' GitHub App key, the factory App key and the Z.ai key go to
  `agents/` once per GCP lineage. The AWS raft snapshot cannot be restored across KMS seals.

## Stacks under `TM_CLOUD=gcp`

| Under `TM_CLOUD=gcp` | Stacks |
|---|---|
| Runs | `shared/tailscale`, `shared/aws-gcp-federation`, `gcp/network`, `gcp/openbao/{lineage,cluster,management}`, `gcp/workforce-identity`, `gcp/gke/{init,configure}` |
| Prints `[skip]` | `aws/{network,eks/init,eks/configure,openbao/cluster,openbao/management,llm-platform}` |
| Kept, untouched | `aws/openbao/lineage`, the Route53 zone, the S3 state bucket |

## Consequences

- An unset `TM_CLOUD` no longer means `aws`: `tm-provisioner.sh` fails every job with exit 3 while
  `primary_cloud` is not `aws`, so a bare deploy cannot apply the shared stacks and skip every GCP one.
- `TM_CLOUD=aws` builds a cluster with no identity provider until this is reverted. A revert means: flip
  `primary_cloud` back, swap the two `suspend`s, and re-register aws-0's clients.
- Every build loses ZITADEL users and IdP links. Grants are re-applied with
  `zitadel-oidc-clients.sh --grant-admin`. The chart's fresh admin PAT replaces the stored one on every build
  (GP-20).
- Until this is accepted and merged, `main` stays AWS-primary, and gcp-0 is deployed as primary only from
  `integration/agent-factory`.
- Each build uses one Let's Encrypt issuance for `auth.gcp.cloud.ogenki.io`; five a week is the ceiling.

## Alternatives rejected

- **Restore gcp-0's seed `zitadel-20260828`** (the 2026-09-11 test): a masterkey read from a store, and a
  directory that is weeks stale.
- **Relocate AWS's directory:** its data and snapshot are `awskms`-bound.
- **Keep AWS primary with gcp-0 consuming:** that needs aws-0 running, which is the cost this removes.
