---
title: Security
weight: 30
description: OpenBao's PKI and secrets engine, how External Secrets and cert-manager consume it, and the admission and network policies enforced on top.
lastVerified: 2026-08-27
---

Three layers, each consuming the one before it: [OpenBao]({{< relref "/docs/platform/security/openbao.md" >}})
is the cluster's secrets and PKI backend; [PKI & Secrets]({{< relref "/docs/platform/security/pki-and-secrets.md" >}})
covers how cert-manager and External Secrets Operator pull certificates and
credentials out of it into the cluster; [Policies]({{< relref "/docs/platform/security/policies.md" >}})
covers what's enforced once a workload is running — Kyverno admission,
CiliumNetworkPolicy default-deny, and pod security context.

The repository's
[security policy](https://github.com/Smana/cloud-native-ref/blob/main/SECURITY.md)
covers reporting, the enforced posture in summary, and the limitations this
platform accepts as a reference implementation — including the ones it would be
more comfortable not to mention.

These pages describe how the platform *implements* security. The rules
themselves — required security-context fields, RBAC conventions, IAM
scoping — are the [Platform Constitution]({{< relref "/docs/reference/platform-constitution.md" >}});
this section links to it rather than restating it.

![Two secret paths sharing one private CA: a root CA signs an intermediate inside OpenBao, which becomes the pki_private_issuer mount that signs every leaf certificate cert-manager requests through the openbao ClusterIssuer; alongside it, External Secrets Operator authenticates to the cloud's managed secret store (AWS Secrets Manager / GCP Secret Manager) through a ClusterSecretStore and materialises every other credential as a Kubernetes Secret](/images/diagrams/secrets-and-pki.svg)

{{< cards >}}
  {{< card link="/docs/platform/security/openbao/" title="OpenBao" icon="lock-closed" subtitle="Namespace layout, the lineage, operator login, JWT machine auth, backup and restore, and the 2.6.x parallelism constraint." >}}
  {{< card link="/docs/platform/security/pki-and-secrets/" title="PKI & Secrets" icon="key" subtitle="The three-tier PKI chain, how cert-manager issues from it, and how External Secrets syncs credentials from AWS." >}}
  {{< card link="/docs/platform/security/policies/" title="Policies" icon="shield-check" subtitle="Kyverno admission policies, CiliumNetworkPolicy default-deny, and the pod security context baseline." >}}
{{< /cards >}}
