---
title: Policies
weight: 30
description: Kyverno admission policies, CiliumNetworkPolicy default-deny, RBAC, and the pod security context baseline enforced on every workload.
lastVerified: 2026-08-30
---

Where [OpenBao]({{< relref "/docs/platform/security/openbao.md" >}}) and
[PKI & Secrets]({{< relref "/docs/platform/security/pki-and-secrets.md" >}})
cover credentials and certificates, this page covers what's enforced once a
workload is actually running. The rules themselves are the [Platform
Constitution]({{< relref "/docs/reference/platform-constitution.md#3-security-defaults" >}}) —
this page is how the platform implements them.

## Admission: Kyverno

Two `HelmRelease`s in `security/base/kyverno/`: the `kyverno` controller
(chart 3.9.0) and `kyverno-policies` (chart 3.9.0) — the
upstream policy pack that implements the Kubernetes Pod Security Standards
as `ClusterPolicy` resources. `kyverno-policies` installs with `values: {}` —
no policy overrides at all — so the enforced set and its failure action (audit
vs. enforce) come from the chart's own defaults rather than being hand-picked
here. The controller release is not empty: it sets `fullnameOverride` and
`crds.install: false`, and nothing else.
`crds.install: false` on the controller — the CRDs are managed separately,
under `crds/base/`, alongside every other CRD this repository installs
ahead of the controllers that consume them.

## Network: CiliumNetworkPolicy default-deny

The constitution requires a `CiliumNetworkPolicy` on every pod-running
workload, default-deny with explicit allow. In Cilium, default-deny is
**per-direction** — a policy only puts an endpoint into default-deny for a
direction if it has a rules section for that direction, so an egress-only
policy silently leaves ingress wide open unless you ask for both explicitly:

```yaml
spec:
  enableDefaultDeny:
    ingress: true
    egress: true
```

The OpenBao snapshot CronJob's policy
(`security/base/openbao-snapshot/network-policy.yaml`) is a working example
of the traps that show up once you write these for real:

- **DNS egress** needs an explicit rule to `kube-dns` on port 53 before
  anything else can resolve — including the AWS SDK resolving STS and S3
  endpoints.
- **EKS Pod Identity's agent runs on the node's host network — as does
  GKE's metadata server at `169.254.169.254`.** Cilium classifies both
  destinations as the `host` entity, not a routable CIDR — a `toCIDR` rule
  for the link-local address silently fails. Use `toEntities: [host]` scoped
  to the port instead.
- **`toEntities: world` on 443 is a deliberate, bounded exception**, not a
  general escape hatch. It's acceptable here only because the workload is a
  one-shot CronJob with a TTL, S3's endpoint topology fans out past what a
  single-segment FQDN match can follow, restricted PSS is already enforced,
  and IAM is scoped. Every other port stays denied. A long-lived serving
  workload doesn't get this exception — it gets a tighter `toFQDNs` rule or
  two separate policies.

```yaml
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: openbao-snapshot
spec:
  endpointSelector:
    matchLabels:
      k8s:app.kubernetes.io/instance: openbao
  enableDefaultDeny:
    ingress: true
    egress: true
  egress:
    - toEndpoints:
        - matchLabels:
            k8s:io.kubernetes.pod.namespace: kube-system
            k8s:k8s-app: kube-dns
      toPorts:
        - ports: [{ port: "53", protocol: UDP }, { port: "53", protocol: TCP }]
    - toEntities: [host]
      toPorts:
        - ports: [{ port: "80", protocol: TCP }]   # EKS Pod Identity agent
    - toCIDR: ["${openbao_cidr}"]                  # VPC CIDR on AWS, node subnet on GCP
      toPorts:
        - ports: [{ port: "8200", protocol: TCP }]  # OpenBao, via the internal LB
    - toEntities: [world]
      toPorts:
        - ports: [{ port: "443", protocol: TCP }]   # S3 / STS — bounded, see above
```

## Pod security context

Every container the constitution governs carries the same
[baseline]({{< relref "/docs/reference/platform-constitution.md#33-security-context" >}}):
`runAsNonRoot: true`, `readOnlyRootFilesystem: true` where possible,
`allowPrivilegeEscalation: false`, capabilities dropped to `[ALL]`, and
`seccompProfile.type: RuntimeDefault` — mandatory under the `restricted` Pod
Security Standard, and the field most upstream charts leave commented out.
External Secrets' `HelmRelease` (`security/base/external-secrets/`) is a
concrete instance of a chart that segments this per component — the
controller, the webhook, and `certController` each need the restricted
fields restated individually, because a chart's per-component
`securityContext` **replaces** the top-level default rather than merging
with it:

```yaml
securityContext:
  capabilities:
    drop: [ALL]
  readOnlyRootFilesystem: true
  runAsNonRoot: true
  runAsUser: 1000
```

## Supply chain

What runs here is narrower than the phrase usually implies, so it is worth
being precise about which of these block a merge and which only report. A gate
that reports is still useful; a gate that reports while everyone believes it
blocks is worse than none.

| Tool | What it looks at | Blocks a merge? |
|---|---|---|
| `flux schema validate` | Every rendered manifest, with `skipMissingSchemas: false` in `.fluxschema.yml` — an unknown Kind **fails** the build rather than being skipped | **Yes** |
| Polaris | The *rendered* bundle rather than the source tree — the repository holds a handful of raw workloads, the render holds dozens | **Yes** |
| `detect-secrets` | Staged changes, pre-commit, before the push | **Yes**, locally |
| Trivy | Filesystem scan of the repository (`scan-type: fs`), `CRITICAL,HIGH`, `ignore-unfixed: true` | No — uploads SARIF to GitHub Security |
| Checkov | `terraform,secrets` frameworks, `soft_fail: true` | No — advisory |
| TruffleHog | The push range in CI, `--only-verified` | No — reports verified findings |

Two gaps are worth stating plainly rather than leaving a reader to infer them
from the table:

**No container image is scanned anywhere in CI.** Trivy is pointed at the
filesystem, not at images. Harbor is the registry, and it carries no explicit
Trivy configuration in
`tooling/base/harbor/helmrelease-harbor.yaml` — whatever the chart defaults to
is what runs, and nothing here asserts it.

**Checkov never blocks.** `soft_fail: true` means a finding lands in the
GitHub Security tab and the build stays green. It is a reporting tool in this
repository, not a gate, and reading the CI job list without reading its
arguments would give the opposite impression.

## RBAC

Cluster role bindings follow groups sourced from ZITADEL, not individual
users — `security/base/rbac/admin.yaml` binds the `admin` OIDC group to
`cluster-admin`, and that's the only binding in the platform wider than
namespace scope:

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: ogenki-admin
subjects:
  - kind: Group
    name: admin
    apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: ClusterRole
  name: cluster-admin
```

Every other service account is scoped to its own namespace — the
constitution's [RBAC rule]({{< relref "/docs/reference/platform-constitution.md#34-rbac" >}}):
least privilege, no `cluster-admin` for workloads.

## IAM

AWS access from a pod is [EKS Pod Identity, never
IRSA]({{< relref "/docs/decisions/0002-eks-pod-identity-over-irsa.md" >}})
— on `gcp-0`, GKE Workload Identity fills the same role —
and every policy is scoped to `xplane-*`-prefixed resources with no deletion
permission on stateful services (S3, IAM, Route53) — see the constitution's
[IAM Conventions]({{< relref "/docs/reference/platform-constitution.md#4-iam-conventions" >}}).
The OpenBao snapshot CronJob is the concrete case that makes the scoping
legible: its Pod Identity role can write to the snapshot S3 bucket, and
nothing else — not Secrets Manager, not any other bucket — which is what
keeps a compromised daily backup pod from also being a path to the recovery
keys that regenerate a root token.
