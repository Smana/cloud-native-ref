# Tailscale Gateway API Integration

This platform uses Gateway API with Tailscale to provide secure, custom domain access to private services (`*.priv.cloud.ogenki.io`) without exposing them to the internet.

## Architecture Overview

```mermaid
flowchart TB
    subgraph tailscale["🔒 Tailscale Network"]
        user["👤 User Device"]
    end

    subgraph aws["☁️ AWS"]
        route53["📝 Route53 Private Zone<br/>*.priv.cloud.ogenki.io"]
    end

    subgraph k8s["☸️ Kubernetes Cluster"]
        externaldns["🔄 ExternalDNS<br/>Watches HTTPRoutes<br/>Creates Route53 records"]

        subgraph gateway["🚪 Gateway"]
            cilium["Cilium Gateway<br/>class: cilium-tailscale<br/>addr: gateway-priv.tail9c382.ts.net<br/>TLS: OpenBao wildcard cert"]
        end

        subgraph routes["🔀 HTTPRoutes"]
            route1["harbor.priv.cloud.ogenki.io"]
            route2["headlamp.priv.cloud.ogenki.io"]
            route3["grafana.priv.cloud.ogenki.io"]
            route4["hubble-ui.priv.cloud.ogenki.io"]
        end

        subgraph services["🎯 Services"]
            svc1["Harbor"]
            svc2["Headlamp"]
            svc3["Grafana"]
            svc4["Hubble UI"]
        end
    end

    user -->|"1️⃣ DNS query:<br/>harbor.priv.cloud.ogenki.io"| route53
    route53 -->|"2️⃣ Returns:<br/>gateway-priv.tail9c382.ts.net"| user
    user -->|"3️⃣ Tailscale mesh<br/>HTTPS/443"| cilium

    externaldns -.->|"Watches"| routes
    externaldns -.->|"Creates A records"| route53

    cilium --> route1 & route2 & route3 & route4
    route1 --> svc1
    route2 --> svc2
    route3 --> svc3
    route4 --> svc4

    style tailscale fill:#e1f5fe
    style aws fill:#fff3e0
    style k8s fill:#f3e5f5
    style gateway fill:#e8f5e9
    style routes fill:#fff9c4
    style services fill:#fce4ec
```

**Flow**:
1. 👤 User queries `harbor.priv.cloud.ogenki.io` from Tailscale device
2. 📝 Route53 private zone returns CNAME: `gateway-priv.tail9c382.ts.net`
3. 🔒 Tailscale MagicDNS resolves to IP: `100.103.159.24`
4. 🚀 Direct encrypted connection via Tailscale mesh → Gateway → Service
5. 🔄 ExternalDNS automatically creates/updates DNS records for all HTTPRoutes

## How to Add a New Service

**For standard services**, create an HTTPRoute:

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: myapp
  namespace: apps
spec:
  parentRefs:
    - name: platform-tailscale
      namespace: infrastructure
  hostnames:
    - "myapp.priv.cloud.ogenki.io"
  rules:
    - backendRefs:
        - name: myapp-service
          port: 8080
```

**For Crossplane-managed apps**, set `route.enabled: true`:

```yaml
apiVersion: cloud.ogenki.io/v1alpha1
kind: App
metadata:
  name: xplane-myapp
  namespace: apps
spec:
  image:
    repository: ghcr.io/myorg/myapp
    tag: v1.0.0
  route:
    enabled: true
    hostname: "myapp"  # Creates myapp.priv.cloud.ogenki.io
```

**DNS is automatic**: ExternalDNS watches HTTPRoutes and creates Route53 records within 30-60 seconds.

**Test access**:
```bash
# From Tailscale-connected device
curl -v https://myapp.priv.cloud.ogenki.io
```

## Benefits

### Cost Savings
- **$0** - Tailscale free tier (up to 100 devices)
- **No AWS NLB** - Saves ~$20-30/month
- **Unlimited services** - One Tailscale device, infinite HTTPRoutes

### Security
- ✅ **Zero trust** - Only Tailscale-connected devices can access
- ✅ **Private PKI** - TLS certificates from OpenBao (internal CA)
- ✅ **No internet exposure** - Services never leave private network
- ✅ **Mesh networking** - Direct peer-to-peer connections

### Developer Experience
- ✅ **Custom domains** - `harbor.priv.cloud.ogenki.io` instead of `gateway-priv.tail9c382.ts.net`
- ✅ **Automatic DNS** - ExternalDNS creates records from HTTPRoutes
- ✅ **Standard Gateway API** - Kubernetes-native, portable
- ✅ **Advanced routing** - Path-based, header-based, weighted traffic

### Comparison to Individual Ingress

**Traditional approach** (Ingress per service):
- ❌ Each service = separate Tailscale device
- ❌ Expensive (Tailscale charges per device beyond free tier)
- ❌ TLS certificates managed per Ingress

**Gateway API approach** (shared Gateway):
- ✅ One Tailscale device for all services
- ✅ Cost-effective (free tier covers all services)
- ✅ Centralized TLS management
- ✅ Consistent routing pattern

## How It Works

### Platform Components

The platform provides these resources (already configured):

1. **CiliumGatewayClassConfig** (`infrastructure/base/gapi/tailscale-gatewayclass-config.yaml`)
   - Configures `loadBalancerClass: tailscale`

2. **GatewayClass** (`infrastructure/base/gapi/tailscale-gatewayclass.yaml`)
   - Links Cilium controller to Tailscale config

3. **Gateway** (`infrastructure/base/gapi/platform-tailscale-gateway.yaml`)
   - Listens on `*.priv.cloud.ogenki.io:443`
   - Exposed via Tailscale at `gateway-priv.tail-xxxxx.ts.net`
   - TLS termination with OpenBao certificates

4. **ExternalDNS** (`infrastructure/base/external-dns/helmrelease.yaml`)
   - Watches HTTPRoutes referencing `platform-tailscale`
   - Creates Route53 A records pointing to Tailscale IP

### What You Create

You only need to create HTTPRoutes for your services. ExternalDNS handles DNS automatically.

## Verification

### Check Gateway
```bash
kubectl get gateway platform-tailscale -n infrastructure
# Expected: ADDRESS = gateway-priv.tail9c382.ts.net, PROGRAMMED = True
```

### Check HTTPRoutes
```bash
kubectl get httproute -A -o json | \
  jq -r '.items[] | select(.spec.parentRefs[]? | select(.name == "platform-tailscale")) |
  "\(.metadata.namespace)/\(.metadata.name): \(.spec.hostnames[])"'
```

### Check DNS Records
```bash
ZONE_ID=$(aws route53 list-hosted-zones --query 'HostedZones[?Name==`priv.cloud.ogenki.io.`].Id' --output text)
aws route53 list-resource-record-sets --hosted-zone-id "$ZONE_ID" \
  --query 'ResourceRecordSets[?Type==`A` && contains(Name, `priv`)]' \
  --output table
```

## Troubleshooting

### Gateway Not Getting Tailscale IP

**Check**:
```bash
kubectl get gateway platform-tailscale -n infrastructure -o jsonpath='{.status.addresses}'
```

**Fix**:
- Verify Tailscale operator is running: `kubectl get pods -n tailscale`
- Check GatewayClass: `kubectl get gatewayclass cilium-tailscale -o yaml`

### DNS Records Not Created

**Check ExternalDNS logs**:
```bash
kubectl logs -n kube-system -l app.kubernetes.io/name=external-dns --tail=50
```

**Common issues**:
- Gateway missing `external-dns: enabled` label
- HTTPRoute namespace not allowed in Gateway's `allowedRoutes`

### HTTPRoute Not Attached

**Check status**:
```bash
kubectl get httproute <name> -n <namespace> -o yaml | grep -A 20 "status:"
```

**Fix**:
- Ensure hostname matches `*.priv.cloud.ogenki.io`
- Verify namespace is in Gateway's allowed list (apps, kube-system, observability, tooling)

### TLS Certificate Errors

**Check certificate**:
```bash
kubectl get certificate private-gateway-tls -n infrastructure
```

**Fix**:
- Verify cert-manager is running: `kubectl get pods -n cert-manager`
- Check OpenBao issuer: `kubectl get clusterissuer -o wide`

## References

- [Tailscale Kubernetes Operator](https://tailscale.com/kb/1236/kubernetes-operator)
- [Gateway API with Tailscale](https://tailscale.com/kb/1620/kubernetes-operator-byod-gateway-api)
- [Cilium Gateway API](https://docs.cilium.io/en/stable/network/servicemesh/gateway-api/gateway-api/)
- [ExternalDNS Gateway API](https://kubernetes-sigs.github.io/external-dns/v0.14.0/tutorials/gateway-api/)
