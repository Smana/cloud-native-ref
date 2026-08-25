# GCP private ingress and external-dns — design

**Workstream 10** of the [GCP support design](2026-08-18-gcp-support-design.md).
Sibling of workstream 11 ([private PKI](2026-08-24-gcp-openbao-design.md)), merged as #1830.

**Status**: approved 2026-08-25, not yet implemented.

**Prerequisite — SATISFIED.** The cluster rename (`mycluster-0` → `aws-0`,
`gcp-mycluster-0` → `gcp-0`) landed in #1832 before this was implemented, deliberately: this
design puts `${cluster_name}` inside Tailscale device names, so building it first would have
renamed those devices twice, each time costing a private-ingress interruption and stale
tailnet devices to clear. Every path and device name below uses the new names.

---

## What this builds

Private ingress for `gcp-0`: two Tailscale-backed Gateways serving
`*.priv.gcp.ogenki.io`, TLS from the OpenBao PKI that workstream 11 built, and DNS records
maintained automatically in the private Cloud DNS zone.

After this, a service on the GCP cluster is reachable from a tailnet device by name, over
HTTPS, with a certificate that chains to the offline root — the same experience AWS has
today, through the same manifests.

## What this deliberately does NOT build

**Public certificates, and public ingress generally.** The parent design's workstream 10 also
listed "cert-manager clouddns DNS-01 (public certs)", and its own open question already
observed that DNS-01 *has nothing to solve against on GCP*: `opentofu/gcp/network/dns.tf`
creates a private zone only, `cloud.ogenki.io` is a Route53 zone this repository does not
manage, and Let's Encrypt must resolve `_acme-challenge` publicly.

That question stays open, and it is not blocking, because **GCP has no public endpoint to put
a certificate on.** There is no public Gateway, no internet-facing load balancer, and
workstream 12 owns that. Designing public certificate issuance before anything needs one
would settle a registrar-level decision on speculation.

The three options the parent design named remain on the table unchanged: solve DNS-01 against
Route53 from GCP; delegate a public subdomain to a new public Cloud DNS zone; or serve no
public certificates from GCP at all. **Whoever picks up workstream 12 must resolve it then.**

## Starting position — what already exists

This workstream is much smaller than the parent design's table suggests, because the tailnet
and DNS foundation landed with earlier slices. Verified 2026-08-25:

| Already in place | Where |
|---|---|
| Tailnet ACLs, `tagOwners` for `tag:k8s` / `tag:admin` / `tag:k8s-operator`, autoApprovers | `opentofu/shared/tailscale/main.tf` |
| `priv.gcp.ogenki.io` in `search_domains`; GCP's four CIDRs in `advertised_routes` | `opentofu/shared/tailscale/variables.tfvars` |
| GCP subnet router, split-DNS inbound policy, tailnet key | `opentofu/gcp/network/tailscale.tf` |
| Private Cloud DNS zone `priv.gcp.ogenki.io` | `opentofu/gcp/network/dns.tf` |
| `xplane_dns_editor` custom role, allowlisted in `crossplane_grantable_roles` | `opentofu/gcp/gke/init/iam.tf` |
| `openbao` ClusterIssuer, verified issuing | workstream 11 |
| `clustersecretstore` → GCP Secret Manager via Workload Identity | workstream 11 |

The tailnet singletons matter most. They were extracted into `opentofu/shared/tailscale`
precisely so that neither cloud authorises the other's devices, and the extraction comment
records the failure mode it avoids: *"a second `tailscale_acl` in the GCP stack would have
made each apply silently overwrite the other's, last apply winning, with no error."*
**Consequently this workstream changes no ACL and no `tagOwners` entry** — `tag:k8s` and
`tag:admin` are already owned by `tag:k8s-operator` tailnet-wide, so a GCP operator can tag
its Gateways with no AWS-side change.

## Architecture

Three components, all cluster-side. The only infrastructure change is one manually created
secret.

```
tailnet (shared)
  └── tag:k8s / tag:admin ──── owned by tag:k8s-operator, tailnet-wide

gcp-0
  ├── tailscale-operator ───── services loadBalancerClass: tailscale
  │     └── operator-oauth ─── ExternalSecret ← GCP Secret Manager
  ├── Gateway API layer
  │     ├── GatewayClass cilium-tailscale + CiliumGatewayClassConfig
  │     ├── Gateway platform-tailscale-general  (tag:k8s)
  │     ├── Gateway platform-tailscale-admin    (tag:admin)
  │     └── Certificate *.priv.gcp.ogenki.io ← ClusterIssuer openbao (WS11)
  └── external-dns ─────────── provider google, private zone only
        └── GCPWorkloadIdentity ← xplane_dns_editor
```

### 1. tailscale-operator — `security/gcp-0/tailscale-operator/`

Reuses `security/base/tailscale-operator/helmrelease.yaml`, `proxyclass-general.yaml` and
`proxyclass-admin.yaml` **by file reference**, not by directory. The base directory also
carries `oauth-client-externalsecret.yaml`, whose `key: tailscale/k8s-operator/oauth-client`
is an AWS Secrets Manager path; pulling the directory would bring a store reference that
cannot resolve on GCP. This is the same by-file pattern workstream 11 established for the
shared HelmReleases, and it works because Flux builds kustomizations with
`LoadRestrictionsNone` — as does `scripts/flux-schema/render-bundle.py`, deliberately, so CI
renders what Flux renders.

GCP supplies its own `ExternalSecret` reading a new GCP Secret Manager entry
`tailscale-k8s-operator-oauth-gcp`, with `target.name: operator-oauth` — the name the chart
requires, unchanged.

**No `ProxyGroup`.** AWS runs `ts-proxies`, two egress replicas. Nothing on the GCP cluster
egresses through the tailnet today, so this is YAGNI until something does.

### 2. Gateway API layer — consumed by file from `infrastructure/base/gapi/`

Six of the seven manifests are cloud-neutral and are referenced as-is:

| File | Why it needs no change |
|---|---|
| `tailscale-gatewayclass.yaml` | Cilium is the GatewayClass implementation on both clouds — ADR-0005 chose Standard GKE + self-managed Cilium exactly so `CiliumGatewayClassConfig` exists |
| `tailscale-gatewayclass-config.yaml` | `loadBalancerClass: tailscale`; no cloud load balancer is involved, so no cloud-specific annotations |
| `platform-tailscale-general-gateway.yaml` | Listener hostname is `*.${private_domain_name}` |
| `platform-tailscale-admin-gateway.yaml` | Same |
| `platform-private-gateway-certificate.yaml` | `issuerRef: openbao` — precisely what WS11 built and verified |
| `allow-gateway-l7-proxy.yaml` | `CiliumClusterwideNetworkPolicy` for the Envoy `reserved:ingress` identity |

**Excluded**: `platform-public-gateway.yaml` — `service.beta.kubernetes.io/aws-load-balancer-*`
annotations and `cert-manager.io/cluster-issuer: letsencrypt-prod`. It is the public path this
design does not build.

Using `loadBalancerClass: tailscale` rather than a GCP forwarding rule means **the private
gateways incur no cloud load-balancer charges**, which the parent design already noted.

#### Gateway hostname rename — the one change that touches AWS

Both Gateways currently hardcode `tailscale.com/hostname: gateway-general-priv` and
`gateway-admin-priv`. Two clusters cannot claim the same hostname; Tailscale would silently
suffix the second one, making the resulting MagicDNS name unpredictable.

**Decision: parameterise as `gateway-{general,admin}-priv-${cluster_name}` on both clouds**,
giving `gateway-general-priv-aws-0` on AWS and `gateway-general-priv-gcp-0` on GCP.
`cluster_name` already exists in both clusters' vars ConfigMaps, so no new variable is
introduced.

**This assumes the cluster rename has already landed** — see *Prerequisite* below. Applied
against today's names it would produce `gateway-general-priv-mycluster-0`, which would then
need renaming a second time.

Two alternatives were rejected. A GCP-only fork of the five manifests would leave AWS
untouched but duplicate near-identical files that drift. A new suffix variable, empty on AWS,
would avoid the rename but make one cloud the unlabelled default — the exact asymmetry
[ADR-0017](../../../website/content/docs/decisions/0017-multi-cloud-dns-naming.md) rejected
for DNS names, and for the same reason.

**The cost is real and must be planned for, not discovered.** Changing the annotation makes
the operator register a *new* Tailscale device with a *new* Tailscale IP. The old device does
not disappear. So on the AWS cluster:

1. The Gateway's Service gets a new Tailscale IP.
2. external-dns rewrites the `*.priv.aws.ogenki.io` records to it — after its sync interval,
   not instantly.
3. Every private AWS service is briefly unreachable in between.
4. The two superseded devices (`gateway-general-priv`, `gateway-admin-priv`) linger in the
   tailnet and must be deleted by hand.

This is a deliberate, user-approved trade for symmetric naming. It should be applied to AWS in
a window where a short private-ingress interruption is acceptable, and the stale devices
removed in the same session.

### 3. external-dns — `infrastructure/gcp-0/external-dns/`

Patches `infrastructure/base/external-dns/helmrelease.yaml`:

| Value | AWS | GCP |
|---|---|---|
| `provider` | `aws` | `google` |
| `domainFilters` | `[cloud.ogenki.io, priv.aws.ogenki.io]` | `[${private_domain_name}]` — one zone; GCP has no public zone |
| `extraArgs` | `--aws-zone-type` etc. | `--google-project=${project_id}`, `--google-zone-visibility=private` |
| `global.imageRegistry` | `public.ecr.aws` | dropped — an AWS registry is an odd dependency for GCP image pulls |
| `txtOwnerId` | `${cluster_name}` | `${cluster_name}` — already distinct, so the two clusters' TXT registries cannot collide |
| `sources` | service, ingress, gateway-httproute | unchanged |

`policy: sync` and the `--gateway-label-filter=external-dns=enabled` /
`--gateway-namespace=infrastructure` arguments carry over unchanged.

#### Identity — the composition's first consumer

A `GCPWorkloadIdentity` claim in `kube-system` (where external-dns runs) for ServiceAccount
`external-dns`, granting `projects/ogenki-435905/roles/xplane_dns_editor`.

This is the opposite call from workstream 11, and deliberately so. There, External Secrets
needed exactly two named secrets, and the composition's project-scoped `ProjectIAMMember`
would have granted read of *every* secret in the project including the intermediate CA's
private key — so it was bound per secret and the composition was left without a consumer, with
a comment predicting external-dns would be the first genuine one.

external-dns's access **is** project-shaped. It must discover which zone owns a name, which
requires `dns.managedZones.list` across the project — a per-zone
`google_dns_managed_zone_iam_member` cannot express that. `xplane_dns_editor` already excludes
zone creation and deletion, so the widest thing it grants is record edits in zones that
already exist. That is the shape of the workload.

## Flux ordering

```
namespaces → crds → security (controllers)
                      ├── security-openbao      (ClusterIssuer openbao)
                      └── security-tailscale    (operator)
                            └── infrastructure-gapi   (GatewayClass, Gateways, Certificate)
infrastructure (existing) ── external-dns added here
```

Two edges are load-bearing and get `dependsOn` plus health checks, not a retry timer:

- **`infrastructure-gapi` after `security-openbao`.** The wildcard Certificate cannot be
  issued before the `openbao` ClusterIssuer exists.
- **`infrastructure-gapi` after `security-tailscale`.** Without the operator, both Gateways'
  Services sit `Pending` forever with no error that names the cause.

Workstream 11 already paid for learning this: External Secrets' own admission webhook had no
endpoints when its ExternalSecrets were applied in the same Kustomization as its chart, and
the resulting exponential backoff left both secrets unsynced *while Flux reported Ready*. The
fix there was a `dependsOn` edge gated on HelmRelease health checks. The same discipline
applies here.

external-dns joins the existing `infrastructure` Kustomization rather than getting its own —
it degrades gracefully when there is nothing to watch, so it needs no ordering edge.

## Success criteria

Falsifiable, verified against a live cluster, then torn down.

1. `kubectl get gateway -n infrastructure` → both `PROGRAMMED=True`, each with a
   `100.x.y.z` Tailscale address.
2. `tailscale status` from a laptop lists `gateway-general-priv-gcp-0` and
   `gateway-admin-priv-gcp-0`.
3. `kubectl get certificate -n infrastructure private-gateway-certificate` → `READY=True`,
   and `openssl x509 -issuer` on the secret shows `CN=Ogenki GCP Intermediate CA`.
4. A test `HTTPRoute` on the general Gateway resolves and serves over HTTPS from a tailnet
   device, with the certificate validating against the offline root's chain.
5. `gcloud dns record-sets list --zone=priv-gcp-ogenki-io` shows that record plus its
   external-dns TXT registry entry carrying `txtOwnerId=gcp-0`.
6. Deleting the `HTTPRoute` removes both records within one sync interval (`policy: sync`
   actually pruning, not just creating).
7. A device **not** in `group:admin` can reach the general Gateway's hostname and **cannot**
   reach the admin Gateway's — the two-gateway ACL split enforced by Tailscale, not by
   Kubernetes.
8. Teardown leaves no Tailscale device, no Cloud DNS record under the zone, and no billable
   GCP resource.

## Risks and open questions

- **The AWS Gateway rename causes a brief private-ingress outage** and leaves two stale
  Tailscale devices. Described above; it is a planned cost, not a surprise, but it means this
  change must not be applied to AWS unattended.
- **Manual bootstrap steps are accumulating.** GCP now needs, by hand: the Cloud KMS key ring
  (WS11), the OpenTofu state bucket and its project (ADR-0018), and now a Tailscale OAuth
  client in GCP Secret Manager. Three undocumented steps is how a repository stops being
  reproducible. **This design requires them to be collected into one documented bootstrap
  procedure**, not left as three comments in three files.
- **A separate GCP OAuth client** was chosen over copying AWS's so that compromising one
  cluster's operator does not force rotating the other's. It is one more credential to create
  and one more to remember to revoke on teardown.
- **external-dns's project-wide DNS role is wider than the one zone it uses.** Accepted because
  zone discovery genuinely needs `managedZones.list`, but if GCP ever hosts a zone external-dns
  must not touch, `domainFilters` is a *client-side* filter and not a security boundary — the
  IAM role would need revisiting then.
- **Public certificates remain unresolved**, by design. Workstream 12 must settle it.
- **Cilium's Gateway API on GKE is verified only for basic L7.** The parent design's CHECK 2
  passed 100/100 requests through a Cilium Gateway on a throwaway GKE cluster without
  WireGuard, but that predates this Gateway configuration and the Tailscale
  `loadBalancerClass` path. Criterion 4 is what actually establishes it.

## References

- Parent design: [GCP Support — Dual-Cloud Platform Design](2026-08-18-gcp-support-design.md)
- Sibling: [GCP OpenBao — private PKI](2026-08-24-gcp-openbao-design.md), merged #1830
- [ADR-0005 · Cilium on GKE Standard](../../../website/content/docs/decisions/0005-gke-standard-self-managed-cilium.md)
- [ADR-0017 · Multi-cloud DNS naming](../../../website/content/docs/decisions/0017-multi-cloud-dns-naming.md)
- ADR-0018 · Per-cloud OpenTofu state — `website/content/docs/decisions/0018-per-cloud-opentofu-state.md`, landing with PR #1831; left unlinked here because it is not on this branch yet
- `website/content/docs/platform/networking/private-access.md` — the AWS-side operator's guide this mirrors
