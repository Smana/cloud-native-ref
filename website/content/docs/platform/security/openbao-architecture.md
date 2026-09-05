---
title: OpenBao Architecture
weight: 5
description: Why OpenBao survives a platform that is destroyed nightly — the lineage, rehydrate-at-boot, and cross-cloud fallback, in one page.
lastVerified: 2026-09-02
---

This platform is destroyed most nights to keep it affordable. OpenBao is the
store of record for secrets and the private PKI anyway — because what persists
between teardowns is not the instance.

## The idea in one line

**OpenBao's storage is derived state.** The node is disposable; the *lineage* is
not.

| Survives a teardown | Rebuilt on every deploy |
|---|---|
| The KMS **seal key** (multi-region) | The Raft store |
| **Five bootstrap secrets** per cloud | Every mount, policy, role and issuer |
| The **snapshot bucket**, and its cross-cloud mirror | The node itself |

## How a deploy puts it back

```mermaid
flowchart LR
  S[(Snapshot bucket)] -->|newest snapshot| R
  K[KMS seal key] -->|unseals| R
  R[rehydrate] --> N[Fresh node<br/>mounts, PKI, root token]
  N --> C[CronJob<br/>daily snapshot]
  C --> S
```

A fresh node is initialised with throwaway shares that are **never stored**, the
newest snapshot is restored into it, and the mounts, the PKI issuer and the root
token come back with it. There is no seeding step. If the bucket is empty — the
first deploy of a lineage — it is a plain init and the new keys are stored.

Before the cluster is destroyed, one last snapshot is taken, so nothing written
since the daily job is lost.

## Cross-cloud fallback

A snapshot can only be restored under **the seal that encrypted it**. So a GCP
standby unseals with the *AWS* KMS key, reached over OIDC federation — no AWS
credential is stored on the node.

{{< callout type="info" >}}
This is why the seal is part of the snapshot's **filename**. A node refuses to
restore an object its own seal cannot unwrap, and refuses *before* the
irreversible step rather than after it.
{{< /callout >}}

## Machine authentication

No generated credential exists to store or rotate. Workloads present a
**projected ServiceAccount token**, which OpenBao validates against their
cluster's own OIDC issuer — one JWT mount per cluster.

## Where the detail lives

{{< cards >}}
  {{< card link="/docs/platform/security/openbao/" title="OpenBao" icon="lock-closed" subtitle="The operational surface: namespaces, operator login, JWT roles, backup and restore." >}}
  {{< card link="/docs/platform/security/pki-and-secrets/" title="PKI & Secrets" icon="key" subtitle="The certificate chain, and how cert-manager and External Secrets consume it." >}}
  {{< card link="/docs/guides/openbao-cross-cloud-failover/" title="Failover runbook" icon="switch-horizontal" subtitle="What to run when the primary cloud is unavailable, and how to fail back." >}}
  {{< card link="/docs/decisions/0033-openbao-store-of-record-lineage/" title="ADR-0033" icon="document-text" subtitle="Why this design, the cost constraint behind it, and the alternatives rejected." >}}
{{< /cards >}}
