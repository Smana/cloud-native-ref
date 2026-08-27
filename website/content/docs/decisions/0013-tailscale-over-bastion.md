---
title: Use Tailscale for private access rather than a bastion
linkTitle: 0013 · Tailscale private access
weight: 130
description: Private cluster access runs over Tailscale with ACL tags as the authorization primitive, splitting general and admin gateways, instead of a bastion host or a managed VPN appliance.
lastVerified: 2026-08-21
---

**Status**: Accepted
**Date**: 2026-08-21
**Deciders**: Smana (Platform Owner)
**Related Design**: N/A — records a choice predating the design workflow

---

## Context

The EKS API endpoint is private, and so is every operational service this
platform runs: Harbor, Grafana, VictoriaMetrics, VictoriaLogs, Headlamp,
Homepage, Hubble UI, and OpenBao's own API and Raft peers. None of it has a
public IP. Something still has to let a human, or a CI runner, reach all of
that without exposing a listener to the internet.

The classic answer is a bastion host: one EC2 instance with a public IP,
inbound SSH restricted by security group, and a fleet of operator SSH keys
authorized on it. This platform takes a different path: every private
service is reached over a **Tailscale** tailnet, with two Gateway API
`Gateway`s and a subnet router as the only entry points, and access
controlled entirely by **Tailscale ACL tags** evaluated outside Kubernetes.

---

## Decision Drivers

- **No public attack surface.** Nothing private should have a listening
  public IP, ever — not even one gated by a security group and patch
  cadence.
- **Identity-based authorization, not network-based.** Access should be a
  function of *who* is connecting, not *where the packet came from*.
- **No long-lived credentials to rotate.** SSH key distribution and
  revocation across a fleet of operators is itself an ongoing cost.
- **Two audiences, two trust levels.** General platform services (Harbor,
  Grafana) and operational tooling (Hubble UI, `kube-system`) need
  different reachability — everyone on the tailnet for the former, only
  admins for the latter.
- **Fits the existing GitOps/Gateway API model.** The platform's only
  ingress mechanism is Gateway API; whatever provides private access
  should plug into a `GatewayClass`, not bolt on a separate proxy layer.

---

## Considered Options

### Option 1: Tailscale

A mesh VPN (WireGuard-based) with identity-backed ACLs. The Kubernetes
Tailscale Operator (`security/base/tailscale-operator/`) exposes two
Gateway API `Gateway`s as Tailscale devices; a separate subnet-router EC2
instance (`opentofu/aws/network/tailscale.tf`) advertises the VPC CIDR for
direct access to the EKS API and OpenBao.

**Pros**:
- Identity-based ACLs (`tailscale_acl` in `opentofu/aws/network/tailscale.tf`)
  replace network-perimeter trust: a device's tag, not its source IP,
  decides what it can reach.
- Tailscale SSH (`ssh { action = "check", src = ["autogroup:member"], dst =
  ["autogroup:self"] }`) gives the subnet router keyless, ephemeral,
  per-connection SSH — no static `authorized_keys` to maintain.
- Plugs directly into Gateway API via `CiliumGatewayClassConfig` and
  `loadBalancerClass: tailscale` — no separate ingress mechanism to run.
- The subnet router sits in a private subnet with no public IP; the only
  thing internet-reachable is Tailscale's own coordination service, which
  this platform does not operate.

**Cons**:
- A third-party control plane now sits on the path to a private cluster
  (see `### Negative`).
- Still one EC2 instance to size and patch (the subnet router) — this
  removes the *bastion*, not *all* infrastructure with a Tailscale
  connection.
- A new mechanism (ACL tags, `tagOwners`) for operators to learn, instead
  of the SSH/security-group model most platform teams already know.

### Option 2: Bastion host + SSH

One EC2 instance with a public (or NAT-forwarded) IP, security-group-gated
inbound SSH, and operator keys authorized on it as a jump box to the VPC.

**Pros**:
- No third-party control-plane dependency — reachability depends only on
  AWS and the instance itself.
- Familiar operational model; no new tool for operators to adopt.

**Cons**:
- A host with a public IP is a permanent target; patch cadence becomes a
  security-critical operational duty, not an optional one.
- SSH key distribution and revocation across every operator is a
  standing cost with no built-in expiry.
- Authorization is per-host (who can SSH to the bastion), not per-service
  — no equivalent to the general/admin Gateway split without building it.
- No native integration with Gateway API; reaching Kubernetes-native
  services (Grafana, Harbor) through a bastion means a second hop (SSH
  tunnel or `kubectl port-forward`), not a browser-navigable hostname.

### Option 3: AWS Client VPN

A managed VPN appliance (`aws_ec2_client_vpn_endpoint`) terminating in the
VPC, authenticated via certificates or SAML/IdP federation.

**Pros**:
- Fully AWS-managed — no third-party coordination server, no extra
  instance to patch.
- Certificate or IdP-based auth, no static SSH keys.

**Cons**:
- Priced per connection-hour and per associated subnet — an ongoing AWS
  bill scaling with usage, versus Tailscale's flat/free-tier model for a
  tailnet this size.
- Still network-perimeter trust once connected (a VPN client is "in the
  VPC"), not the per-device ACL-tag model this platform standardizes on
  for Kubernetes-native private services.
- No Gateway API integration — reaching private services still means a
  second mechanism on top of the VPN tunnel.

---

## Decision Outcome

**Chosen option**: "Option 1 — Tailscale"

**Rationale**: The platform's private-access requirement is not just "reach
the VPC" — it is "expose two classes of Kubernetes-native services with
different trust levels, plus the private EKS API endpoint, without a
publicly reachable listener on the private-access path." Tailscale is the
only option that satisfies all of that with one mechanism: ACL tags
authorize both the Gateway API split (general vs. admin) and the subnet
router, `tagOwners` puts tag assignment solely in the Kubernetes Tailscale
Operator's hands so no human or other automation can self-escalate, and
nothing in the path carries a public IP. A bastion solves reachability but
not the service-level trust split, and reintroduces the exact
public-listener and SSH-key-rotation costs this decision exists to avoid.
AWS Client VPN avoids the public listener but keeps network-perimeter trust
and buys none of the Gateway API integration.

---

## Consequences

### Positive

- ACL tags are the authorization primitive end to end: `tag:k8s` on the
  general `Gateway` (`platform-tailscale-general`) is reachable by every
  tailnet member; `tag:admin` on the admin `Gateway`
  (`platform-tailscale-admin`) is reachable only by `group:admin`. Both
  set `loadBalancerClass: tailscale` through the shared
  `CiliumGatewayClassConfig` (`infrastructure/base/gapi/`), and `tagOwners`
  restricts who can apply either tag to the Kubernetes Tailscale Operator
  alone (`opentofu/aws/network/tailscale.tf`).
- The two-gateway split makes admin-only services (Hubble UI, and anything
  else parented to `platform-tailscale-admin`) genuinely *unreachable* for
  a non-admin device — not merely unlisted or unlinked. A `tag:k8s`-only
  device gets no route to `platform-tailscale-admin` regardless of whether
  it knows the hostname.
- The EKS API endpoint is private with no other path in: Tailscale, via
  the subnet-router's VPC-CIDR advertisement, is how it is reached at all.
- No bastion host to patch: the subnet router carries no public IP and no
  inbound SSH listener open to arbitrary sources, and Tailscale SSH removes
  the need for any long-lived operator SSH key.

### Negative

- **A third-party dependency sits on the control path to a private
  cluster.** If Tailscale's coordination server is unavailable, devices
  already connected keep their existing peer-to-peer sessions, but *new*
  connections and re-authentications cannot be established — an outage
  there degrades this platform's only path to its private services.
- **No fallback if the Tailscale path to a service breaks.** Because
  Tailscale is the sole mechanism (no parallel bastion, no public
  allowlisted IP), a misconfigured ACL, a stalled subnet router, or a
  tailnet-side DNS problem leaves an operator with no alternate route in —
  the [Get Started → Access]({{< relref "/docs/get-started/access.md" >}})
  page documents only the working path, not a fallback one.
  - *Mitigation*: the subnet-router module runs `prometheus_enabled` node
    metrics and the platform's own alerting; a stuck router is expected to
    surface there before it's discovered by a locked-out operator.
- `TF_VAR_tailscale_api_key` is the one secret the bootstrap cannot source
  from AWS Secrets Manager — it has to exist before OpenTofu can create
  anything, including the Secrets Manager access path itself, so it is
  supplied by hand as an environment variable (see the repository
  [README](https://github.com/Smana/cloud-native-ref/blob/main/README.md)).
  Every other Tailscale credential — the Kubernetes Operator's OAuth
  client — is ESO-managed from OpenBao like any other secret
  (`security/base/tailscale-operator/oauth-client-externalsecret.yaml`);
  this one bootstrap key is the sole exception to that pattern.

### Neutral

- The subnet router is still a real EC2 instance with its own capacity
  planning — `opentofu/aws/network/tailscale.tf` pins `t3.micro` explicitly
  after an `t3a.micro` capacity failure in `eu-west-3`. Removing the
  bastion did not remove all patchable infrastructure from the access
  path, only the public-IP, SSH-key-fleet version of it.
- Two independent Tailscale-facing surfaces exist for two different jobs:
  the Kubernetes Tailscale Operator (Gateway API devices, OAuth-client
  authenticated) and the OpenTofu-provisioned subnet router (VPC-CIDR
  routing, API-key authenticated at creation). They are not redundant —
  each is the only path to what it serves.

---

## Implementation Notes

The Kubernetes-side Tailscale Operator (`security/base/tailscale-operator/`)
owns the two Gateway API `Gateway` devices and nothing else; it does not
advertise routes into the VPC. The OpenTofu-side subnet router
(`opentofu/aws/network/tailscale.tf`, module `Smana/tailscale-subnet-router/aws`)
owns VPC-CIDR advertisement and nothing else; it does not front any
Kubernetes `Service`. Reaching a Kubernetes-native private service always
goes through a `Gateway`/`HTTPRoute`; reaching the VPC directly (the EKS
API, OpenBao's Raft peers) always goes through the subnet router. The two
mechanisms are not interchangeable, and conflating them when adding a new
private service is the most common way to reach for the wrong one.

---

## References

- [Platform → Networking → Private access]({{< relref "/docs/platform/networking/private-access.md" >}}) — the ACL model, the Gateway wiring, and the subnet router in full
- [Get Started → Access]({{< relref "/docs/get-started/access.md" >}}) — the operator-facing walkthrough this ADR's Negative section references
- `opentofu/aws/network/tailscale.tf` — the `tailscale_acl` resource, `tagOwners`, and the subnet-router module block
- `security/base/tailscale-operator/` — the Kubernetes Tailscale Operator HelmRelease, `ProxyClass`es, and OAuth-client `ExternalSecret`
- `infrastructure/base/gapi/` — the two Tailscale `Gateway`s and the shared `CiliumGatewayClassConfig`
- [ADR-0015](0015-gateway-api-over-ingress-nginx.md) — the Gateway API routing mechanics behind the `CiliumGatewayClassConfig` and `loadBalancerClass: tailscale` wiring described here
- [Tailscale: Simplifying Cloud Access](https://blog.ogenki.io/post/tailscale/) — the platform author's long-form writeup of this same choice
- [Tailscale ACLs](https://tailscale.com/kb/1018/acls) — the tag/`tagOwners` model this ADR relies on
- [Tailscale architecture](https://tailscale.com/blog/how-tailscale-works) — the coordination-server dependency behind this ADR's first `### Negative` point
