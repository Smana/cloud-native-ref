# Tailscale Gateway API - Verification Guide

This guide walks through verifying that the Tailscale Gateway API integration is working correctly.

## Prerequisites

Before starting verification:
- Flux has reconciled the changes
- You have `kubectl` access to the cluster
- You're connected to Tailscale network

## Component Status Checklist

### 1. CoreDNS Internal DNS Resolver ✅

**Expected State**: 2 replicas running, exposed via Tailscale LoadBalancer

```bash
# Check namespace exists
kubectl get namespace dns-system

# Check pods are running
kubectl get pods -n dns-system -l app=coredns-tailscale
```

**Expected Output:**
```
NAME                                READY   STATUS    RESTARTS   AGE
coredns-tailscale-xxxxxxxxxx-xxxxx  1/1     Running   0          5m
coredns-tailscale-xxxxxxxxxx-xxxxx  1/1     Running   0          5m
```

**Check Service and Tailscale Integration:**
```bash
# Check Service exists and has LoadBalancer type
kubectl get svc -n dns-system coredns-tailscale

# Expected: TYPE=LoadBalancer, EXTERNAL-IP should be a Tailscale IP (100.x.x.x)
```

**Expected Output:**
```
NAME                TYPE           CLUSTER-IP      EXTERNAL-IP    PORT(S)
coredns-tailscale   LoadBalancer   10.100.x.x      100.x.x.x      53:xxxxx/UDP,53:xxxxx/TCP,9153:xxxxx/TCP
```

**Get Tailscale Hostname:**
```bash
kubectl get svc -n dns-system coredns-tailscale \
  -o jsonpath='{.metadata.annotations.tailscale\.com/hostname}'

# Expected: dns-priv
```

**Get Tailscale IP (critical for split DNS configuration):**
```bash
kubectl get svc -n dns-system coredns-tailscale \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}'

# Expected: 100.x.x.x (note this IP for Tailscale split DNS config)
```

**Check CoreDNS Logs:**
```bash
kubectl logs -n dns-system deployment/coredns-tailscale --tail=20

# Expected: No errors, should see CoreDNS startup messages
# [INFO] plugin/reload: Running configuration SHA512 = ...
# [INFO] Reloading complete
```

**Test CoreDNS Resolution (from within cluster):**
```bash
# Create a test pod
kubectl run -it --rm debug --image=busybox --restart=Never -- sh

# Inside the pod:
nslookup kubernetes.default.svc.cluster.local <coredns-tailscale-cluster-ip>

# Exit the pod
exit
```

### 2. Cilium Gateway (Tailscale) ✅

**Expected State**: Gateway ready, listener programmed, LoadBalancer has Tailscale IP

```bash
# Check Gateway exists
kubectl get gateway -n infrastructure platform-tailscale
```

**Expected Output:**
```
NAME                  CLASS    ADDRESS       PROGRAMMED   AGE
platform-tailscale    cilium   100.y.y.y     True         5m
```

**Detailed Gateway Status:**
```bash
kubectl get gateway -n infrastructure platform-tailscale -o yaml
```

**Check for:**
1. `status.conditions`:
   ```yaml
   conditions:
   - type: Accepted
     status: "True"
   - type: Programmed
     status: "True"
   ```

2. `status.addresses`:
   ```yaml
   addresses:
   - type: IPAddress
     value: 100.y.y.y  # Tailscale IP
   ```

3. `status.listeners`:
   ```yaml
   listeners:
   - name: https
     attachedRoutes: 3  # Should match number of HTTPRoutes
     conditions:
     - type: Programmed
       status: "True"
     - type: Accepted
       status: "True"
   ```

**Check Underlying LoadBalancer Service:**
```bash
# Find the service created by Cilium Gateway
kubectl get svc -n infrastructure -l "gateway.networking.k8s.io/gateway-name=platform-tailscale"
```

**Expected Output:**
```
NAME                              TYPE           CLUSTER-IP      EXTERNAL-IP    PORT(S)
cilium-gateway-platform-tailscale LoadBalancer   10.100.x.x      100.y.y.y      443:xxxxx/TCP
```

**Verify loadBalancerClass Annotation:**
```bash
kubectl get svc -n infrastructure \
  -l "gateway.networking.k8s.io/gateway-name=platform-tailscale" \
  -o jsonpath='{.items[0].spec.loadBalancerClass}'

# Expected: tailscale
```

**Check Tailscale Annotations:**
```bash
kubectl get svc -n infrastructure \
  -l "gateway.networking.k8s.io/gateway-name=platform-tailscale" \
  -o jsonpath='{.items[0].metadata.annotations}'

# Should see:
# tailscale.com/hostname: gateway-priv
# tailscale.com/tags: tag:k8s
```

**Check Gateway Pods (Cilium Envoy):**
```bash
# Gateway creates Envoy pods
kubectl get pods -n infrastructure -l "gateway.networking.k8s.io/gateway-name=platform-tailscale"
```

**Expected Output:**
```
NAME                                        READY   STATUS    RESTARTS   AGE
cilium-gateway-platform-tailscale-xxxxxx    1/1     Running   0          5m
```

### 3. TLS Certificate ✅

**Expected State**: Certificate issued, secret exists, valid for 90 days

```bash
# Check Certificate resource
kubectl get certificate -n infrastructure private-gateway-certificate
```

**Expected Output:**
```
NAME                          READY   SECRET                 AGE
private-gateway-certificate   True    private-gateway-tls    5m
```

**Detailed Certificate Status:**
```bash
kubectl describe certificate -n infrastructure private-gateway-certificate
```

**Check for:**
- `Status: True`
- `Message: Certificate is up to date and has not expired`
- `Not Before: <timestamp>`
- `Not After: <timestamp>` (should be ~90 days from Not Before)

**Check Secret Exists:**
```bash
kubectl get secret -n infrastructure private-gateway-tls

# Should exist with type: kubernetes.io/tls
```

**Verify Certificate Content:**
```bash
kubectl get secret -n infrastructure private-gateway-tls \
  -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -text -noout

# Check:
# - Subject: CN=private-gateway.priv.cloud.ogenki.io
# - Issuer: Should reference OpenBao intermediate CA
# - Validity: Not After should be ~90 days
# - DNS names: harbor.priv.cloud.ogenki.io, headlamp.priv.cloud.ogenki.io, etc.
```

### 4. ExternalDNS (Internal) ✅

**Expected State**: Pod running, watching HTTPRoutes, creating DNS records

```bash
# Check ExternalDNS pod
kubectl get pods -n dns-system -l app.kubernetes.io/name=external-dns-internal
```

**Expected Output:**
```
NAME                                      READY   STATUS    RESTARTS   AGE
external-dns-internal-xxxxxxxxxx-xxxxx    1/1     Running   0          5m
```

**Check Logs:**
```bash
kubectl logs -n dns-system -l app.kubernetes.io/name=external-dns-internal --tail=50
```

**Expected Log Entries:**
```
time="..." level=info msg="Instantiating new Kubernetes client"
time="..." level=info msg="Using inCluster-config based on serviceaccount-token"
time="..." level=info msg="Created Kubernetes client"
time="..." level=info msg="Applying provider record filter for domains: [priv.cloud.ogenki.io]"
```

**Check for DNS record creation:**
```
time="..." level=info msg="Desired change: CREATE harbor.priv.cloud.ogenki.io A [Id: /zones/priv.cloud.ogenki.io/harbor.priv.cloud.ogenki.io/A]"
time="..." level=info msg="Desired change: CREATE headlamp.priv.cloud.ogenki.io A [Id: /zones/priv.cloud.ogenki.io/headlamp.priv.cloud.ogenki.io/A]"
```

**Verify DNS Records in CoreDNS:**
```bash
# Check zone file
kubectl exec -n dns-system deployment/coredns-tailscale -- cat /zones/priv.cloud.ogenki.io
```

**Expected Output:**
```
$ORIGIN priv.cloud.ogenki.io.
$TTL 300
@       IN      SOA     dns.priv.cloud.ogenki.io. admin.priv.cloud.ogenki.io. (...)

; Records created by ExternalDNS
harbor              300     IN      A       100.y.y.y
headlamp            300     IN      A       100.y.y.y
hubble-ui-mycluster-0 300   IN      A       100.y.y.y
```

### 5. HTTPRoutes ✅

**Expected State**: 3 HTTPRoutes (Harbor, Headlamp, Hubble UI), all accepted by Gateway

```bash
# List all HTTPRoutes
kubectl get httproute -A
```

**Expected Output:**
```
NAMESPACE       NAME        HOSTNAMES                                    AGE
tooling         harbor      ["harbor.priv.cloud.ogenki.io"]             5m
tooling         headlamp    ["headlamp.priv.cloud.ogenki.io"]           5m
kube-system     hubble-ui   ["hubble-ui-mycluster-0.priv.cloud.ogenki.io"] 5m
```

**Check Harbor HTTPRoute:**
```bash
kubectl get httproute -n tooling harbor -o yaml
```

**Verify Status:**
```yaml
status:
  parents:
  - conditions:
    - type: Accepted
      status: "True"
      reason: Accepted
    - type: ResolvedRefs
      status: "True"
      reason: ResolvedRefs
    controllerName: io.cilium/gateway-controller
    parentRef:
      group: gateway.networking.k8s.io
      kind: Gateway
      name: platform-tailscale
      namespace: infrastructure
```

**Check All HTTPRoutes Status:**
```bash
kubectl get httproute harbor -n tooling -o jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status}'
# Expected: True

kubectl get httproute headlamp -n tooling -o jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status}'
# Expected: True

kubectl get httproute hubble-ui -n kube-system -o jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status}'
# Expected: True
```

### 6. Backend Services ✅

**Expected State**: Services exist and have endpoints

```bash
# Check Harbor services
kubectl get svc -n tooling harbor-core harbor-portal

# Check Headlamp service
kubectl get svc -n tooling headlamp

# Check Hubble UI service
kubectl get svc -n kube-system hubble-ui
```

**Expected Output:**
```
NAME            TYPE        CLUSTER-IP       EXTERNAL-IP   PORT(S)
harbor-core     ClusterIP   10.100.x.x      <none>        80/TCP
harbor-portal   ClusterIP   10.100.x.x      <none>        80/TCP
headlamp        ClusterIP   10.100.x.x      <none>        80/TCP
hubble-ui       ClusterIP   10.100.x.x      <none>        80/TCP
```

**Check Service Endpoints:**
```bash
kubectl get endpoints -n tooling harbor-core
kubectl get endpoints -n tooling headlamp
kubectl get endpoints -n kube-system hubble-ui

# Each should have at least one IP:port in ENDPOINTS column
```

## End-to-End Testing

### Step 1: DNS Resolution Test

**From Tailscale-connected device:**

```bash
# Get CoreDNS Tailscale IP first
COREDNS_IP=$(kubectl get svc -n dns-system coredns-tailscale \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}')

echo "CoreDNS Tailscale IP: $COREDNS_IP"

# Test DNS resolution directly against CoreDNS
dig @$COREDNS_IP harbor.priv.cloud.ogenki.io +short
dig @$COREDNS_IP headlamp.priv.cloud.ogenki.io +short
dig @$COREDNS_IP hubble-ui-mycluster-0.priv.cloud.ogenki.io +short

# All should return the Gateway Tailscale IP (100.y.y.y)
```

**Expected Output:**
```
100.y.y.y
100.y.y.y
100.y.y.y
```

### Step 2: DNS Resolution via Split DNS

**After configuring Tailscale split DNS (see manual step below):**

```bash
# These queries should automatically use CoreDNS via Tailscale
dig harbor.priv.cloud.ogenki.io +short
nslookup headlamp.priv.cloud.ogenki.io

# Should return Gateway Tailscale IP
```

### Step 3: HTTPS Connectivity Test

```bash
# Test HTTPS connectivity (accept self-signed cert from OpenBao)
curl -k -I https://harbor.priv.cloud.ogenki.io
curl -k -I https://headlamp.priv.cloud.ogenki.io
curl -k -I https://hubble-ui-mycluster-0.priv.cloud.ogenki.io
```

**Expected Output:**
```
HTTP/2 200
server: envoy
...
```

### Step 4: Certificate Verification

```bash
# Check certificate issuer
echo | openssl s_client -connect harbor.priv.cloud.ogenki.io:443 -servername harbor.priv.cloud.ogenki.io 2>/dev/null | openssl x509 -noout -issuer -subject

# Expected:
# issuer=CN = priv.cloud.ogenki.io Intermediate CA (or similar from OpenBao)
# subject=CN = private-gateway.priv.cloud.ogenki.io
```

### Step 5: Browser Access Test

**Trust OpenBao CA Certificate (one-time setup):**

1. Download CA certificate:
   ```bash
   curl -k https://bao.priv.cloud.ogenki.io:8200/v1/pki/root/ca/pem -o openbao-ca.pem
   ```

2. Import into OS trust store:
   - **macOS**: `sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain openbao-ca.pem`
   - **Linux**: `sudo cp openbao-ca.pem /usr/local/share/ca-certificates/openbao-ca.crt && sudo update-ca-certificates`
   - **Windows**: Import via Certificate Manager (certmgr.msc)

3. Access services in browser:
   - https://harbor.priv.cloud.ogenki.io
   - https://headlamp.priv.cloud.ogenki.io
   - https://hubble-ui-mycluster-0.priv.cloud.ogenki.io

**Expected**: No certificate warnings, services load correctly.

## Manual Configuration Required

### Tailscale Split DNS Configuration

**Critical Step**: This MUST be done manually in Tailscale admin console.

1. Go to: https://login.tailscale.com/admin/dns
2. Click **Add nameserver** → **Custom...**
3. Configure:
   - **Nameserver**: `<CoreDNS-Tailscale-IP>` (from Step 1)
   - **Restrict to search domain**: ✅ Enable
   - **Search domain**: `priv.cloud.ogenki.io`
4. Click **Save**

**Verify Split DNS is Active:**
```bash
# From Tailscale device
tailscale status

# Check DNS configuration
scutil --dns | grep -A 5 "priv.cloud.ogenki.io"  # macOS
resolvectl status | grep -A 5 "priv.cloud.ogenki.io"  # Linux systemd-resolved
```

## Troubleshooting Commands

### Quick Status Check (All Components)

```bash
#!/bin/bash
echo "=== CoreDNS Status ==="
kubectl get pods -n dns-system -l app=coredns-tailscale
kubectl get svc -n dns-system coredns-tailscale

echo -e "\n=== Gateway Status ==="
kubectl get gateway -n infrastructure platform-tailscale

echo -e "\n=== Certificate Status ==="
kubectl get certificate -n infrastructure private-gateway-certificate

echo -e "\n=== HTTPRoutes Status ==="
kubectl get httproute -A

echo -e "\n=== ExternalDNS Status ==="
kubectl get pods -n dns-system -l app.kubernetes.io/name=external-dns-internal

echo -e "\n=== Tailscale IPs ==="
echo "CoreDNS IP:"
kubectl get svc -n dns-system coredns-tailscale -o jsonpath='{.status.loadBalancer.ingress[0].ip}'
echo -e "\nGateway IP:"
kubectl get gateway -n infrastructure platform-tailscale -o jsonpath='{.status.addresses[0].value}'
```

### View All Logs

```bash
# CoreDNS logs
kubectl logs -n dns-system deployment/coredns-tailscale -f

# ExternalDNS logs
kubectl logs -n dns-system -l app.kubernetes.io/name=external-dns-internal -f

# Gateway (Envoy) logs
kubectl logs -n infrastructure -l "gateway.networking.k8s.io/gateway-name=platform-tailscale" -f

# Tailscale operator logs
kubectl logs -n tailscale -l app=operator -f
```

### Common Issues

#### Issue: Gateway Has No IP

**Symptoms:**
```bash
kubectl get gateway platform-tailscale -n infrastructure
# ADDRESS column is empty or shows <pending>
```

**Diagnosis:**
```bash
# Check underlying service
kubectl get svc -n infrastructure -l "gateway.networking.k8s.io/gateway-name=platform-tailscale"

# Check loadBalancerClass
kubectl get svc -n infrastructure -l "gateway.networking.k8s.io/gateway-name=platform-tailscale" \
  -o jsonpath='{.items[0].spec.loadBalancerClass}'

# Expected: tailscale
# If empty or different: loadBalancerClass annotation not working
```

**Fix:**
Check `infrastructure/base/gapi/platform-tailscale-gateway.yaml`:
```yaml
spec:
  infrastructure:
    annotations:
      loadBalancerClass: tailscale  # Must be in annotations!
```

#### Issue: DNS Not Resolving

**Symptoms:**
```bash
dig harbor.priv.cloud.ogenki.io
# Returns NXDOMAIN or wrong IP
```

**Diagnosis:**
```bash
# Check ExternalDNS logs
kubectl logs -n dns-system -l app.kubernetes.io/name=external-dns-internal

# Check CoreDNS zone file
kubectl exec -n dns-system deployment/coredns-tailscale -- cat /zones/priv.cloud.ogenki.io

# Test direct query to CoreDNS
dig @<coredns-tailscale-ip> harbor.priv.cloud.ogenki.io
```

**Fix:**
- Verify HTTPRoutes are accepted
- Check ExternalDNS is watching `gateway-httproute` source
- Ensure split DNS is configured in Tailscale admin console

#### Issue: HTTPRoute Not Accepted

**Symptoms:**
```bash
kubectl get httproute harbor -n tooling
# Shows warnings or not accepted
```

**Diagnosis:**
```bash
kubectl describe httproute harbor -n tooling

# Check conditions:
# - Accepted: should be True
# - ResolvedRefs: should be True
```

**Common Causes:**
- Hostname doesn't match Gateway listener pattern (`*.priv.cloud.ogenki.io`)
- Namespace not allowed by Gateway's `allowedRoutes`
- Backend service doesn't exist

## Success Criteria

✅ **All components running:**
- CoreDNS: 2/2 pods, LoadBalancer with Tailscale IP
- Gateway: Programmed=True, Address=100.y.y.y
- ExternalDNS: 1/1 pod, no errors in logs
- HTTPRoutes: 3 routes, all Accepted=True
- Certificate: Ready=True

✅ **DNS resolution working:**
- `dig harbor.priv.cloud.ogenki.io` returns Gateway IP

✅ **HTTPS connectivity:**
- `curl -k https://harbor.priv.cloud.ogenki.io` returns HTTP 200

✅ **Services accessible:**
- Can access Harbor, Headlamp, Hubble UI in browser

If all criteria met: **🎉 Tailscale Gateway API integration is working!**
