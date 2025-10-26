# Tailscale Gateway API Integration

This document describes how to use Gateway API with Tailscale for custom domain access to private services using Route53 DNS.

## Architecture Overview

```
┌─────────────────────────────────────────────────────────┐
│                    Tailscale Network                     │
│  ┌────────────┐                                         │
│  │  User      │─────────┐                               │
│  │  Device    │         │                               │
│  └────────────┘         │                               │
│                         │                               │
│         *.priv.cloud.ogenki.io DNS queries             │
│                         ▼                               │
│              ┌────────────────────┐                     │
│              │  Route53 Private   │                     │
│              │  Hosted Zone       │                     │
│              │  (AWS VPC DNS)     │                     │
│              └──────────┬─────────┘                     │
└─────────────────────────┼──────────────────────────────┘
                          │ Points to
                          │ gateway-priv.tail-xxxxx.ts.net
                          ▼
┌─────────────────────────────────────────────────────────┐
│                    Kubernetes Cluster                    │
│                                                          │
│  ┌──────────────────────────────────────────────────┐   │
│  │  ExternalDNS                                     │   │
│  │  - Watches HTTPRoutes (gateway-httproute)        │   │
│  │  - Creates Route53 records (private zone)        │   │
│  │  - Points to Gateway Tailscale address           │   │
│  └──────────────────────────────────────────────────┘   │
│                                                          │
│  ┌─────────────────────────────────────────────────┐   │
│  │  Cilium Gateway (Tailscale)                     │   │
│  │  - gatewayClassName: cilium-tailscale           │   │
│  │  - loadBalancerClass: tailscale                 │   │
│  │  - Address: gateway-priv.tail-xxxxx.ts.net      │   │
│  │  - Listener: *.priv.cloud.ogenki.io:443        │   │
│  │  - TLS: cert-manager (OpenBao issuer)          │   │
│  └─────────────────┬───────────────────────────────┘   │
│                    │                                    │
│  ┌─────────────────┴───────────────────────────────┐   │
│  │           HTTPRoutes (per service)              │   │
│  │  - harbor.priv.cloud.ogenki.io                  │   │
│  │  - headlamp.priv.cloud.ogenki.io                │   │
│  │  - hubble-ui-mycluster-0.priv.cloud.ogenki.io   │   │
│  └─────────────────┬───────────────────────────────┘   │
│                    │                                    │
│  ┌─────────────────┴───────────────────────────────┐   │
│  │           Backend Services                       │   │
│  │  (Harbor, Headlamp, Hubble UI, etc.)            │   │
│  └──────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────┘
```

## Components

### 1. CiliumGatewayClassConfig

**Location**: `infrastructure/base/gapi/tailscale-gatewayclass-config.yaml`

Configures the Gateway Service to use Tailscale LoadBalancer instead of AWS NLB.

**Key Configuration:**
```yaml
apiVersion: cilium.io/v2alpha1
kind: CiliumGatewayClassConfig
metadata:
  name: tailscale-config
  namespace: infrastructure
spec:
  description: "Tailscale LoadBalancer configuration"
  service:
    type: LoadBalancer
    loadBalancerClass: tailscale  # Critical: use Tailscale operator
    externalTrafficPolicy: Cluster
```

**Important**: The `loadBalancerClass` must be under `spec.service`, not directly in `spec`.

### 2. GatewayClass

**Location**: `infrastructure/base/gapi/tailscale-gatewayclass.yaml`

Links the Cilium Gateway controller to the Tailscale configuration.

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: cilium-tailscale
spec:
  controllerName: io.cilium/gateway-controller
  parametersRef:
    group: cilium.io
    kind: CiliumGatewayClassConfig
    name: tailscale-config
    namespace: infrastructure
```

### 3. Platform Tailscale Gateway

**Location**: `infrastructure/base/gapi/platform-tailscale-gateway.yaml`

The main Gateway resource that gets exposed via Tailscale.

**Key Features:**
- Uses `cilium-tailscale` GatewayClass
- Labeled with `external-dns: enabled` for ExternalDNS discovery
- Tailscale hostname: `gateway-priv`
- TLS termination with OpenBao certificates

**Configuration:**
```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: platform-tailscale
  namespace: infrastructure
  labels:
    external-dns: enabled  # Required for ExternalDNS filtering
spec:
  gatewayClassName: cilium-tailscale
  infrastructure:
    annotations:
      tailscale.com/hostname: "gateway-priv"
      tailscale.com/tags: "tag:k8s"
      tailscale.com/funnel: "false"
  listeners:
    - name: https
      hostname: "*.priv.${domain_name}"
      port: 443
      protocol: HTTPS
      allowedRoutes:
        namespaces:
          from: Selector
          selector:
            matchExpressions:
              - key: kubernetes.io/metadata.name
                operator: In
                values:
                  - apps
                  - kube-system
                  - observability
                  - tooling
      tls:
        mode: Terminate
        certificateRefs:
          - name: private-gateway-tls  # Certificate from cert-manager/OpenBao
```

### 4. ExternalDNS Configuration

**Location**: `infrastructure/base/external-dns/helmrelease.yaml`

The existing ExternalDNS instance is configured to watch Gateway HTTPRoutes.

**Added Configuration:**
```yaml
values:
  # Watch sources
  sources:
    - service
    - ingress
    - gateway-httproute  # NEW: Watch HTTPRoutes

  # Extra arguments for Gateway filtering
  extraArgs:
    # Only watch HTTPRoutes from platform-tailscale Gateway
    - --gateway-namespace=infrastructure
    - --gateway-label-filter=external-dns=enabled
```

**How it works:**
1. ExternalDNS watches HTTPRoutes that reference Gateways with label `external-dns: enabled`
2. Extracts hostname from HTTPRoute spec (`harbor.priv.cloud.ogenki.io`)
3. Looks up Gateway's address (`gateway-priv.tail9c382.ts.net`)
4. Creates CNAME record in Route53 private zone pointing hostname → Gateway address

### 5. HTTPRoutes

**Locations**:
- `tooling/base/harbor/httproute.yaml`
- `tooling/base/headlamp/httproute.yaml`
- `infrastructure/base/cilium/hubble-ui-httproute.yaml`

Each service has an HTTPRoute that references the `platform-tailscale` Gateway.

**Example (Harbor):**
```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: harbor
  namespace: tooling
spec:
  parentRefs:
    - group: gateway.networking.k8s.io
      kind: Gateway
      name: platform-tailscale
      namespace: infrastructure
  hostnames:
    - "harbor.priv.${domain_name}"
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /v2/
      backendRefs:
        - name: harbor-core
          port: 80
    # Additional path-based routing...
```

## How It Works

### DNS Resolution Flow

1. **User queries** `harbor.priv.cloud.ogenki.io` from Tailscale device
2. **Route53 Private Zone** responds with CNAME: `gateway-priv.tail9c382.ts.net`
3. **Tailscale MagicDNS** resolves `gateway-priv.tail9c382.ts.net` to Tailscale IP (e.g., `100.103.159.24`)
4. **Direct connection** established via Tailscale mesh to Gateway
5. **Cilium Gateway** terminates TLS, matches HTTPRoute, forwards to backend service

### DNS Record Creation Flow

1. **HTTPRoute created** (e.g., Harbor) with hostname `harbor.priv.cloud.ogenki.io`
2. **HTTPRoute references** `platform-tailscale` Gateway
3. **ExternalDNS watches** HTTPRoute (filtered by Gateway label `external-dns: enabled`)
4. **ExternalDNS queries** Gateway status for address → `gateway-priv.tail9c382.ts.net`
5. **ExternalDNS creates** CNAME record in Route53:
   ```
   harbor.priv.cloud.ogenki.io → gateway-priv.tail9c382.ts.net
   ```

## Verification

### 1. Check Gateway Status

```bash
# Verify Gateway has Tailscale address
kubectl get gateway platform-tailscale -n infrastructure

# Expected output:
# NAME                 CLASS              ADDRESS                         PROGRAMMED   AGE
# platform-tailscale   cilium-tailscale   gateway-priv.tail9c382.ts.net   True         10m
```

### 2. Check HTTPRoute Attachment

```bash
# List HTTPRoutes attached to platform-tailscale Gateway
kubectl get httproute -A -o json | \
  jq -r '.items[] | select(.spec.parentRefs[]? | select(.name == "platform-tailscale")) | "\(.metadata.namespace)/\(.metadata.name): \(.spec.hostnames[])"'

# Expected output:
# kube-system/hubble-ui: hubble-ui-mycluster-0.priv.cloud.ogenki.io
# tooling/harbor: harbor.priv.cloud.ogenki.io
# tooling/headlamp: headlamp.priv.cloud.ogenki.io
```

### 3. Check DNS Records in Route53

```bash
# Get private zone ID
ZONE_ID=$(aws route53 list-hosted-zones --query 'HostedZones[?Name==`priv.cloud.ogenki.io.`].Id' --output text)

# List DNS records
aws route53 list-resource-record-sets --hosted-zone-id "$ZONE_ID" \
  --query 'ResourceRecordSets[?Type==`CNAME`]' \
  --output table

# Expected records:
# harbor.priv.cloud.ogenki.io → gateway-priv.tail9c382.ts.net
# headlamp.priv.cloud.ogenki.io → gateway-priv.tail9c382.ts.net
# hubble-ui-mycluster-0.priv.cloud.ogenki.io → gateway-priv.tail9c382.ts.net
```

### 4. Test DNS Resolution

```bash
# From a Tailscale-connected device
dig harbor.priv.cloud.ogenki.io

# Should resolve to gateway-priv.tail9c382.ts.net (CNAME)
# Then to Tailscale IP (A record via MagicDNS)
```

### 5. Test HTTPS Access

```bash
# From a Tailscale-connected device
curl -v https://harbor.priv.cloud.ogenki.io

# Should:
# 1. Resolve DNS via Route53 + MagicDNS
# 2. Connect to Gateway via Tailscale mesh
# 3. TLS handshake with OpenBao certificate
# 4. Route to Harbor backend
# 5. Return HTTP 200
```

## Troubleshooting

### Gateway Not Getting Tailscale IP

**Symptom**: Gateway shows AWS NLB address instead of Tailscale

**Check:**
```bash
kubectl get gateway platform-tailscale -n infrastructure -o jsonpath='{.status.addresses}'
```

**Solutions:**
1. Verify CiliumGatewayClassConfig has `service.loadBalancerClass: tailscale`
2. Check Gateway uses correct GatewayClass: `cilium-tailscale`
3. Verify Tailscale operator is running: `kubectl get pods -n tailscale`

### DNS Records Not Created

**Symptom**: No records in Route53 for HTTPRoute hostnames

**Check ExternalDNS logs:**
```bash
kubectl logs -n kube-system -l app.kubernetes.io/name=external-dns
```

**Common issues:**
1. **Gateway label missing**: Add `external-dns: enabled` label to Gateway
2. **Source not configured**: Verify `gateway-httproute` in sources list
3. **Filter not matching**: Check `--gateway-label-filter=external-dns=enabled` arg

### HTTPRoute Not Attached

**Symptom**: HTTPRoute shows `Accepted: False`

**Check HTTPRoute status:**
```bash
kubectl get httproute harbor -n tooling -o yaml
```

**Solutions:**
1. Verify namespace is allowed in Gateway's `allowedRoutes.namespaces`
2. Check hostname matches Gateway listener pattern (`*.priv.cloud.ogenki.io`)
3. Verify Gateway is in `Programmed: True` state

### TLS Certificate Issues

**Symptom**: Certificate errors when accessing services

**Check certificate:**
```bash
kubectl get certificate private-gateway-tls -n infrastructure
```

**Solutions:**
1. Verify cert-manager is running
2. Check OpenBao issuer configuration
3. Review cert-manager logs for errors

## Benefits vs Traditional Approaches

### Compared to Subnet Router

**Traditional Subnet Router approach:**
- ❌ Single point of failure (one Tailscale device)
- ❌ All traffic goes through one device
- ❌ Bandwidth limited per device
- ❌ No advanced routing (path-based, headers, weights)

**Gateway API approach:**
- ✅ Each Gateway is a separate Tailscale device
- ✅ Direct peer-to-peer connections
- ✅ Better failure isolation
- ✅ Advanced routing via Gateway API
- ✅ Gateway-level TLS management

### Compared to Individual Ingress Resources

**Traditional Ingress per service:**
- ❌ Each service = separate Tailscale device
- ❌ Expensive (cost per device)
- ❌ TLS certificates managed per Ingress

**Single Gateway approach:**
- ✅ One Tailscale device for all services
- ✅ Cost-effective
- ✅ Centralized TLS management
- ✅ Consistent routing pattern

## Cost Analysis

**Platform-Tailscale Gateway:**
- 1 Tailscale device (free tier or $6/month Personal)
- Unlimited services via HTTPRoutes
- No AWS NLB costs

**Platform-Private Gateway (AWS NLB):**
- ~$20-30/month for NLB
- Additional data transfer costs
- Required VPN or bastion for access

**Potential savings**: ~$20-30/month if platform-tailscale replaces platform-private

## Adding New Services

To expose a new service via Tailscale Gateway:

1. **Create HTTPRoute** in service namespace:
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
             port: 80
   ```

2. **Wait for DNS propagation** (30-60 seconds):
   ```bash
   # Watch ExternalDNS logs
   kubectl logs -n kube-system -l app.kubernetes.io/name=external-dns -f

   # Verify DNS record created
   aws route53 list-resource-record-sets --hosted-zone-id "$ZONE_ID" \
     --query 'ResourceRecordSets[?Name==`myapp.priv.cloud.ogenki.io.`]'
   ```

3. **Test access** from Tailscale device:
   ```bash
   curl -v https://myapp.priv.cloud.ogenki.io
   ```

## Future Enhancements

1. **Replace platform-private Gateway**: Migrate all private services to platform-tailscale to eliminate AWS NLB costs
2. **mTLS**: Add mutual TLS authentication for enhanced security
3. **Rate limiting**: Use Gateway API rate limit policies
4. **Traffic splitting**: A/B testing and canary deployments via HTTPRoute weights
5. **Header-based routing**: Route to different backends based on HTTP headers

## References

- [Tailscale Kubernetes Operator](https://tailscale.com/kb/1236/kubernetes-operator)
- [Gateway API with Tailscale](https://tailscale.com/kb/1620/kubernetes-operator-byod-gateway-api)
- [Cilium Gateway API](https://docs.cilium.io/en/stable/network/servicemesh/gateway-api/gateway-api/)
- [ExternalDNS Gateway API](https://kubernetes-sigs.github.io/external-dns/v0.14.0/tutorials/gateway-api/)
