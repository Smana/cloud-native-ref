---
title: Networking
weight: 25
description: Cilium as the eBPF data plane, Gateway API as the routing model on top of it, and Tailscale for every private service.
lastVerified: 2026-08-20
---

Three layers, bottom to top: [Cilium]({{< relref "/docs/platform/networking/cilium.md" >}})
is the eBPF data plane — CNI, kube-proxy replacement, and the Gateway API L7
proxy in one component, with IPAM and encryption settings that aren't
optional tuning. [Gateway API]({{< relref "/docs/platform/networking/gateway-api.md" >}})
is the routing model everything runs on top of — `GatewayClass`, `Gateway`,
`HTTPRoute` — including TLS termination and DNS record creation.
[Private Access]({{< relref "/docs/platform/networking/private-access.md" >}})
is how that model gets used for services that should never be reachable from
the public internet: two Gateways, split by Tailscale ACL tag.

![Three ways into the cluster, all terminating on the same Cilium-managed Envoy: internet traffic through an AWS NLB into the platform-public Gateway, and two Tailscale paths whose ACL tags decide which of platform-tailscale-general and platform-tailscale-admin a device may reach; each Gateway matches an HTTPRoute onto a backing Service, while cert-manager supplies the certificates and ExternalDNS writes the Route53 records](/images/diagrams/request-path.svg)

{{< cards >}}
  {{< card link="/docs/platform/networking/cilium/" title="Cilium" icon="cube" subtitle="The CNI and kube-proxy replacement: prefix delegation, the load-bearing WireGuard workaround, and the Gateway API CRD startup trap." >}}
  {{< card link="/docs/platform/networking/gateway-api/" title="Gateway API" icon="switch-horizontal" subtitle="GatewayClass, Gateway, and HTTPRoute; the platform's three Gateways; TLS attachment and ExternalDNS." >}}
  {{< card link="/docs/platform/networking/private-access/" title="Private Access" icon="lock-closed" subtitle="The two Tailscale-backed Gateways, the ACL model that separates them, and how to add a new private service." >}}
{{< /cards >}}
