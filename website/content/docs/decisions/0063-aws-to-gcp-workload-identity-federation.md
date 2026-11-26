---
title: aws-0 reaches Vertex AI through Workload Identity Federation on an AWS role
linkTitle: 0063 · AWS-to-GCP workload identity federation
weight: 630
description: The model gateway on aws-0 calls Gemini on Vertex AI as its EKS Pod Identity role, trusted by a GCP Workload Identity Federation pool of type AWS, with a loopback sidecar handing Pod Identity credentials to Google's client library. No Google key exists anywhere.
lastVerified: 2026-11-26
---

**Status**: Proposed
**Date**: 2026-11-26
**Deciders**: Platform Team
**Related Design**: `docs/superpowers/specs/2026-11-26-aws-vertex-federation-design.md` (design
docs are not published to this site, so this is a repo path rather than a link)

---

## Context

[ADR-0019]({{< relref "/docs/decisions/0019-cross-cloud-dns-federation.md" >}}) made AWS trust
tokens from GKE. This is the other direction: ai-native-ref's model gateway on aws-0 needs to
call Gemini on Vertex AI, and on gcp-0 it does so with GKE Workload Identity, which aws-0 does
not have. The proxy is agentgateway, whose Google client library (`google-cloud-auth`) accepts an
`external_account` credential with an AWS source, but reads AWS credentials only from static
environment variables or an IMDS-shaped endpoint, never from EKS Pod Identity.

## Decision Drivers

- **No Google key**, in OpenBao, a Secret or a pod.
- **Survives an aws-0 rebuild with no step**: aws-0 is torn down and rebuilt often.
- **The same Maku `vertex` preset** on both clusters.

## Considered Options

| Option | Rebuild | Moving parts | Verdict |
|---|---|---|---|
| WIF provider of type AWS on the gateway's Pod Identity role, loopback IMDS-shaped sidecar | Role ARN is stable | One sidecar | **Chosen** |
| WIF OIDC provider on the EKS issuer, projected token | Issuer ID changes per cluster: re-apply after every rebuild, silent 403 until then | None | Rejected |
| Node IMDS credentials | Stable | None | Rejected: the node's role, shared by every pod |
| Google service-account key | Stable | A secret to rotate | Rejected: the requirement |

## Decision

GCP pool `aws-workloads` trusts this AWS account, and its provider's condition admits only the
assumed-role ARN of `xplane-model-gateway-iam-role` (the role ai-native-ref's
`EPI xplane-model-gateway` creates). That principalSet holds `xplane_vertex_predict_v3`, prediction
only, by direct resource access. The proxy reads an `external_account` config from a ConfigMap,
and a sidecar on `127.0.0.1` serves it the Pod Identity session in IMDS's shape.

## Consequences

- **Positive**: keyless; rebuild-proof; GCP-side resources live in
  `opentofu/shared/aws-gcp-federation` beside the other cross-cloud trusts, and an AWS-only
  deploy still needs no Google account (`vertex_federation_enabled` off).
- **Negative**: a sidecar we own until `google-cloud-auth` reads container credentials. The
  trust is by role **name**, so the `EPI` claim's name is part of the host contract.

## Related

- `opentofu/shared/aws-gcp-federation/vertex.tf`
- [ADR-0019]({{< relref "/docs/decisions/0019-cross-cloud-dns-federation.md" >}}), the GCP-to-AWS direction
