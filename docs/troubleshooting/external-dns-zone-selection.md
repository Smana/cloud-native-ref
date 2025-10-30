# External-DNS Zone Selection Issue

## Problem Description

After cluster recreation, DNS records for `*.priv.cloud.ogenki.io` services (like `home.priv.cloud.ogenki.io`) were being created in the **public** hosted zone (`cloud.ogenki.io`) instead of the **private** hosted zone (`priv.cloud.ogenki.io`).

This caused two issues:
1. **Ownership conflicts**: Records created without proper ownership TXT records blocked future DNS management
2. **Wrong zone**: Private services exposed in public DNS (though not reachable due to Tailscale networking)

## Root Cause

The domain filters configuration allowed matching both zones:
```yaml
domainFilters: ["cloud.ogenki.io", "priv.cloud.ogenki.io"]
```

When external-dns encounters a hostname like `home.priv.cloud.ogenki.io`:
- It matches both `cloud.ogenki.io` (parent) and `priv.cloud.ogenki.io` (child) zones
- Without explicit zone preference, it could create records in the parent zone
- This behavior is inconsistent and can create orphaned records

## Solution

Add `aws.zoneMatchParent: false` to the external-dns HelmRelease configuration:

```yaml
# infrastructure/base/external-dns/helmrelease.yaml
spec:
  values:
    aws:
      region: ${region}
      zoneType: ""  # Manage both public and private zones
      batchChangeSize: 1000
      # Prefer more specific zones over parent zones
      # Prevents home.priv.cloud.ogenki.io from being created in cloud.ogenki.io (public)
      # when priv.cloud.ogenki.io (private) is more specific
      zoneMatchParent: false
```

## How It Works

The `zoneMatchParent: false` configuration forces external-dns to:
1. Always prefer the most specific zone match
2. For `home.priv.cloud.ogenki.io`, prefer `priv.cloud.ogenki.io` over `cloud.ogenki.io`
3. Never create records in parent zones when a more specific child zone exists

## Verification

After applying the fix, you can verify it's working:

1. **Check configuration is applied**:
```bash
kubectl logs -n kube-system deployment/external-dns --tail=100 | grep "AWSZoneMatchParent"
```

Expected output should show `AWSZoneMatchParent:false`

2. **Verify records are in the correct zone**:
```bash
# Get private zone ID
PRIVATE_ZONE_ID=$(aws route53 list-hosted-zones --query "HostedZones[?Name=='priv.cloud.ogenki.io.'].Id" --output text | cut -d'/' -f3)

# Check records are in private zone
aws route53 list-resource-record-sets --hosted-zone-id $PRIVATE_ZONE_ID \
  --query "ResourceRecordSets[?contains(Name, 'home.priv')]"

# Get public zone ID
PUBLIC_ZONE_ID=$(aws route53 list-hosted-zones --query "HostedZones[?Name=='cloud.ogenki.io.'].Id" --output text | cut -d'/' -f3)

# Verify NO records in public zone
aws route53 list-resource-record-sets --hosted-zone-id $PUBLIC_ZONE_ID \
  --query "ResourceRecordSets[?contains(Name, 'home.priv')]"
```

The second command should return an empty array `[]`.

3. **Test zone preference behavior**:

Delete any existing records from the public zone and wait for external-dns to sync (default interval: 1 minute). Records should ONLY be created in the private zone.

## Historical Context

This issue occurred repeatedly after cluster recreations because:
- Tailscale Gateway IPs change on recreation
- External-DNS creates new records for the new IPs
- Without `zoneMatchParent: false`, zone selection was non-deterministic
- Records ended up in the public zone without proper ownership

## Related Configuration

The complete external-dns configuration that prevents this issue:

```yaml
sources:
  - service
  - ingress
  - gateway-httproute

aws:
  region: ${region}
  zoneType: ""  # Manage both public and private zones
  batchChangeSize: 1000
  zoneMatchParent: false  # Critical fix

domainFilters: ["${domain_name}", "priv.${domain_name}"]
logFormat: json
logLevel: info
txtOwnerId: "${cluster_name}"

policy: sync  # Automatically cleanup stale DNS records

extraArgs:
  - --gateway-namespace=infrastructure
  - --gateway-label-filter=external-dns=enabled
  - --min-event-sync-interval=30s
```

## References

- External-DNS AWS Provider Documentation: https://github.com/kubernetes-sigs/external-dns/blob/master/docs/tutorials/aws.md
- Issue tracking: Recurring zone selection problem after cluster recreation
- Fix commit: `889ec3b` - "fix(external-dns): prevent DNS records in wrong zone with zoneMatchParent"
