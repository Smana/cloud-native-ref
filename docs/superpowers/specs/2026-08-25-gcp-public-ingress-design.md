# GCP public ingress — design

**Workstream 12** of the [GCP support design](2026-08-18-gcp-support-design.md).
Settles the open question workstream 10 deliberately deferred.

**Status**: approved 2026-08-25, not yet implemented.

---

## What this builds

`gcp-0` can serve names under `cloud.ogenki.io` on the public internet, with a
publicly-trusted certificate, using **no static AWS credentials**.

Concretely: a public Gateway behind a GCP passthrough Network Load Balancer, a
`letsencrypt-prod` ClusterIssuer that solves DNS-01 against Route53 by federated
identity, and a second external-dns instance that writes the public records.

## The question this settles

Workstream 10 built private ingress and stopped at the boundary, recording why:

> DNS-01 has nothing to solve against on GCP. `opentofu/gcp/network/dns.tf`
> creates a **private** Cloud DNS zone, `cloud.ogenki.io` is a Route53 zone this
> repository does not manage, and Let's Encrypt must resolve the
> `_acme-challenge` TXT record **publicly**.

Three ways out were named and none chosen. This design picks the first, for a
reason that only became available on inspection: it is no longer the credential
liability the earlier note assumed.

## Decision: Route53 stays authoritative; GCP federates to it

**cert-manager v1.21.1 — the pinned version — supports
`spec.acme.solvers[].dns01.route53.auth.kubernetes`:**

> Kubernetes authenticates with Route53 using `AssumeRoleWithWebIdentity` by
> passing a bound ServiceAccount token.

So cert-manager on GKE assumes an AWS IAM role using a **projected ServiceAccount
token** as the web identity. There is no access key, no secret to place in GCP
Secret Manager, and nothing to rotate. It is the same identity-by-token model the
platform already uses on both clouds — EKS Pod Identity, GKE Workload Identity —
extended across the boundary.

That materially changes the trade-off the parent design recorded. Its objection
to this option was that it "reintroduces exactly the cross-cloud dependency
option A was rejected for". The dependency is real and remains, but it is a
*credential-less* dependency on a DNS zone, not a shared secret or a shared
control plane.

### Options considered

**A — Route53 authoritative, GCP federates (chosen).** One public zone, names
stay cloud-agnostic. Cost: an AWS IAM OIDC provider trusting the GKE issuer, and
GCP's public certificate issuance depends on Route53 being reachable.

**B — Delegate a subdomain to a public Cloud DNS zone.** No AWS dependency at
all, which is genuinely attractive. Rejected because the delegated name must be
cloud-labelled — `gcp.cloud.ogenki.io` — and
[ADR-0017](../../../website/content/docs/decisions/0017-multi-cloud-dns-naming.md)
rejects exactly that: *"A public endpoint has no such constraint, and encoding
the cloud into it converts a deployment detail into a permanent contract."*
Public names are cloud-agnostic **so a service can move between clouds**; a
per-cloud public zone forecloses that. It also needs a parent-zone change.

**C — Move `cloud.ogenki.io` wholesale to Cloud DNS.** Keeps names
cloud-agnostic and removes GCP's dependency — but inverts it, since `aws-0`
would then need federated access to Cloud DNS for its own certificates and
records. Symmetric problem, larger migration, and it moves a live public zone
that this repository does not even manage.

**Tailscale Funnel — considered and rejected on a hard constraint.** Both private
Gateways already carry `tailscale.com/funnel: "false"`, so it is one annotation
away, and it would need no load balancer, no DNS-01 and no public zone at all.
But Funnel serves a certificate for `<machine>.<tailnet>.ts.net` and **cannot
serve one for a custom domain**. A CNAME from `cloud.ogenki.io` to it fails TLS.
It is the right tool when the hostname does not matter; here it does.

## Decision: Cilium Gateway behind a passthrough Network LB

A `type=LoadBalancer` Service fronting the same `cilium` GatewayClass `aws-0`
already uses for its public Gateway. One Gateway implementation on the cluster.

**GKE's managed Gateway controller (`gke-l7-global-external-managed`) was
rejected** for the reason
[ADR-0005](../../../website/content/docs/decisions/0005-gke-standard-self-managed-cilium.md)
rejected Dataplane V2 for the private gateways: it is a second Gateway
implementation, with its own certificate story diverging from cert-manager and
its own `GatewayClass` semantics. The private gateways are Cilium; splitting the
public path onto Google's controller would mean maintaining two.

Unlike the private gateways — which use `loadBalancerClass: tailscale` and cost
no cloud load-balancer charges — this one **does** provision a GCP forwarding
rule and is billable. That is inherent to being publicly reachable.

## Architecture

```
Let's Encrypt ──DNS-01──> Route53 zone Z002027037R5RFCG05YY6 (cloud.ogenki.io)
                              ▲                    ▲
              AssumeRoleWithWebIdentity     AssumeRoleWithWebIdentity
              (bound KSA token, no keys)    (bound KSA token, no keys)
                              │                    │
                    cert-manager (gcp-0)   external-dns #2 (gcp-0, provider aws)
                              │                    │
                              ▼                    ▼
                    platform-public Gateway  ──  A record -> NLB IP
                    (GatewayClass cilium)
                              │
                    GCP passthrough Network LB (billable)
```

### 1. AWS-side IAM — `opentofu/shared/`

An OIDC identity provider for the GKE cluster's issuer
(`https://container.googleapis.com/v1/projects/<project>/locations/<location>/clusters/gcp-0`)
and one role, assumable only by named ServiceAccount subjects, scoped to:

- `route53:ChangeResourceRecordSets` on `Z002027037R5RFCG05YY6` only
- `route53:GetChange` (required by the ACME flow; not zone-scopable)
- `route53:ListHostedZonesByName` for external-dns's zone discovery

**It lives in `opentofu/shared/`, not `opentofu/aws/`.** It is an AWS resource
that exists solely to couple the two clouds, which is what `shared/` already
means here — `opentofu/shared/tailscale` holds the tailnet for the same reason.
Filing it under `aws/` would present a federation point as AWS's own concern and
hide it from anyone reading the GCP tree.

**No zone-management permission is granted.** The role can change records in one
zone; it cannot create, delete or reconfigure zones, consistent with the
constitution's "no deletion permissions for stateful services".

### 2. GCP-side identity — nothing

No `GCPWorkloadIdentity` claim, no Google service account, no secret. The
projected ServiceAccount token is the credential, and AWS validates it against
the OIDC provider. This is the one place in the platform where a workload
authenticates to the *other* cloud, and it does so with no material at rest.

### 3. Cluster manifests on `gcp-0`

| Manifest | Notes |
|---|---|
| `platform-public` Gateway | `gatewayClassName: cilium`, `type=LoadBalancer`. GCP-specific service annotations replace the AWS NLB ones; `allowedRoutes` starts empty of real namespaces. |
| `letsencrypt-prod` ClusterIssuer | route53 solver with `auth.kubernetes.serviceAccountRef`, `role`, `hostedZoneID`, `region` |
| Public wildcard `Certificate` | `*.${public_domain_name}`, issued by the above |
| external-dns #2 | `provider: aws`, `domainFilters: [${public_domain_name}]`, distinct `txtOwnerId` |

The AWS tree's `platform-public-gateway.yaml` is **not** reused by file: its
`service.beta.kubernetes.io/aws-load-balancer-*` annotations and its
`allowedRoutes` (runlore only) are AWS-specific. GCP gets its own, the same way
`security/gcp-0/` forked what it could not share.

### 4. A second external-dns, and why

external-dns takes **one `--provider` per instance**. `gcp-0`'s existing instance
is `provider: google`, filtered to the private zone; it cannot also write
Route53. Public records therefore need a second deployment.

The alternative — records created by hand or in OpenTofu — was rejected because a
capability where every public service needs a human DNS step is not the
capability. It is also how records drift and get orphaned.

**The two instances must not fight.** They are separated three ways: different
providers, non-overlapping `domainFilters` (private vs public zone), and
distinct `txtOwnerId`. The AWS cluster's external-dns also writes this zone, so
its owner ID must differ from GCP's too — `aws-0` and `gcp-0` already do, since
`txtOwnerId` is `${cluster_name}`.

## Success criteria

Falsifiable, verified against a live cluster, then torn down.

1. The AWS IAM role is assumable **only** by the intended subjects: a token from
   any other ServiceAccount is refused by STS.
2. cert-manager on `gcp-0` issues a certificate for `*.cloud.ogenki.io` — the
   `Certificate` reaches `Ready=True` and the chain terminates at a public root,
   not the platform's private one.
3. No AWS credential material exists on the cluster: no Secret, no mounted key,
   nothing in GCP Secret Manager for this path.
4. The public Gateway is `Programmed=True` with a public IP, and a GCP forwarding
   rule exists.
5. external-dns #2 creates the A record and its TXT registry in Route53, owned by
   `gcp-0`.
6. A probe route is reachable **from off the tailnet** over HTTPS with a
   publicly-trusted certificate — verified without `--cacert`, so the system
   trust store is doing the validating.
7. Deleting the probe prunes both records, and `aws-0`'s records in the same zone
   are untouched throughout.
8. Teardown leaves no forwarding rule, no public IP, and no records under
   `cloud.ogenki.io`.

## Risks and open questions

- **A public endpoint is a real attack surface**, unlike everything workstream 10
  built. `allowedRoutes` is the control: it ships with no application namespace
  listed, so adding a public service is a deliberate edit to the Gateway, not a
  side effect of deploying something. The AWS side sets the precedent — its
  public Gateway admits exactly one namespace and its one route matches a single
  path and method.
- **GCP's public certificates depend on Route53.** If the zone or the IAM role is
  unavailable, issuance and renewal fail on GCP. Certificates are 90 days and
  renew at ~60, so the failure window is wide — but it is a real cross-cloud
  dependency, and it is the price of option A.
- **This is the platform's first cross-cloud IAM trust.** An OIDC provider in AWS
  trusting a GKE issuer is a durable relationship: rebuilding `gcp-0` changes the
  cluster's issuer URL, which invalidates the provider. **Cluster rebuild will
  break this unless the provider is re-registered**, and this platform rebuilds
  routinely. The implementation must either derive the issuer from the cluster in
  OpenTofu, or fail loudly rather than mysteriously.
- **A billable load balancer appears in a project whose teardown was previously
  complete.** Criterion 8 exists because forwarding rules and reserved addresses
  are exactly what gets left behind.
- **Cross-cloud load balancing is NOT in scope**, and runlore is not the vehicle
  for it. It holds a knowledge base, an outcome ledger keyed by alert fingerprint
  and investigation coalescing state on a PVC; two instances diverge immediately,
  so a callback routed to the wrong cloud reaches an instance that has never
  heard of the investigation the button belongs to. It would demonstrate
  *failover* only once that state is shared. A stateless `App` claim is the
  honest vehicle for a weighted-record demonstration.

## References

- Parent: [GCP Support — Dual-Cloud Platform Design](2026-08-18-gcp-support-design.md)
- Sibling: [GCP private ingress](2026-08-25-gcp-private-ingress-design.md) and its
  [verification](2026-08-25-gcp-private-ingress-verification.md)
- [ADR-0005 · GKE Standard with self-managed Cilium](../../../website/content/docs/decisions/0005-gke-standard-self-managed-cilium.md)
- [ADR-0017 · Multi-cloud DNS naming](../../../website/content/docs/decisions/0017-multi-cloud-dns-naming.md)
- `infrastructure/base/gapi/platform-public-gateway.yaml` — the AWS shape this mirrors
