# Gemini on Vertex AI from aws-0: keyless, through Workload Identity Federation

**Date:** 2026-11-26 · **Status:** design and offline build; no live proof (aws-0 is torn down) ·
**Decision:** ADR-0063 (`website/content/docs/decisions/0063-aws-to-gcp-workload-identity-federation.md`) ·
**Builds on:** ai-native-ref's Gemini design (`docs/superpowers/specs/2026-11-25-gemini-provider-design.md`,
G1 to G3), this repository's `xplane_vertex_predict` role (#2925)

## Goal

Maku's `vertex` gateway preset works on gcp-0 because the proxy has a Google identity there: GKE
Workload Identity, read from the metadata server. aws-0 has no metadata server for Google. The
goal is the **same preset** on aws-0, with **no Google key anywhere**: not in OpenBao, not in a
Secret, not in a pod.

## Decision in one picture

```mermaid
sequenceDiagram
    autonumber
    participant AGW as agentgateway (proxy)
    participant SHIM as aws-creds sidecar
    participant EPI as EKS Pod Identity agent<br/>169.254.170.23
    participant GSTS as sts.googleapis.com
    participant AWS as sts.eu-west-3.amazonaws.com
    participant VTX as aiplatform.eu.rep.googleapis.com
    AGW->>SHIM: GET /latest/meta-data/iam/security-credentials/ (127.0.0.1)
    SHIM->>EPI: GET /v1/credentials + pod token
    EPI-->>SHIM: role xplane-model-gateway-iam-role, 6 h session
    SHIM-->>AGW: AccessKeyId, SecretAccessKey, Token (in memory)
    AGW->>AGW: sign GetCallerIdentity (SigV4), never sent to AWS by the pod
    AGW->>GSTS: token exchange: audience = pool provider, subject = signed request
    GSTS->>AWS: replays GetCallerIdentity
    AWS-->>GSTS: arn:aws:sts::<acct>:assumed-role/xplane-model-gateway-iam-role/<session>
    GSTS-->>AGW: federated access token (1 h), if the pool's condition admits the ARN
    AGW->>VTX: generateContent, Bearer token; IAM checks xplane_vertex_predict on the principalSet
```

| Piece | Where | What |
|---|---|---|
| AWS role | ai-native-ref, `EPI xplane-model-gateway` (aws-0 overlay) | `xplane-model-gateway-iam-role`, assumable by `pods.eks.amazonaws.com`, associated to `agent-gateway/model-gateway`. Its policy denies every action: it exists to be an identity, not to do anything in AWS. `GetCallerIdentity` needs no permission and cannot be denied |
| Pool and provider | here, `opentofu/shared/aws-gcp-federation/vertex.tf` | Pool `aws-workloads`, provider `aws-account` of type `aws` for this account. `attribute_condition`: the assumed-role ARN starts with `arn:aws:sts::<acct>:assumed-role/xplane-model-gateway-iam-role/` |
| Grant | same file | `xplane_vertex_predict_v3` (`aiplatform.endpoints.predict` only) to `principalSet://…/attribute.aws_role/arn:aws:sts::<acct>:assumed-role/xplane-model-gateway-iam-role`. Direct resource access: no service account, no impersonation |
| Credential config | ai-native-ref, ConfigMap in `agent-gateway` | An ADC `external_account` JSON: `audience` (from `${gcp_vertex_wif_audience}`), `subject_token_type: urn:ietf:params:aws:token-type:aws4_request`, `credential_source.url` pointing at the sidecar. Not a secret: it names a provider, it proves nothing |
| Wiring on the proxy | Maku chart knob, set by ai-native-ref | `GOOGLE_APPLICATION_CREDENTIALS` to the mounted file, `AWS_REGION`, the sidecar |
| Cluster vars | here, `opentofu/aws/eks/configure` | `gcp_project_id`, `gcp_vertex_wif_audience` in `eks-aws-0-vars` (contract version 10, H3) |

## The blocker, and why a sidecar

The owner's approved shape was "GCP trusts aws-0's gateway IAM role". It holds, with one fact
the approval did not have.

agentgateway v1.6.0 fetches the token for `policies.auth.gcp: {type: AccessToken}` with no
explicit credential through `google-cloud-auth` 1.16.0's ADC builder
(`crates/agentgateway/src/http/auth/gcp.rs`, `credentials::Builder::default()`). That builder
reads `GOOGLE_APPLICATION_CREDENTIALS` and supports `external_account` with an AWS
`credential_source` (`src/credentials/external_account_sources/aws_sourced.rs`). **But that AWS
source gets AWS credentials from exactly two places:** the static `AWS_ACCESS_KEY_ID` /
`AWS_SECRET_ACCESS_KEY` environment variables, or an IMDS-shaped HTTP endpoint
(`url` → role name, `url/<role>` → `{AccessKeyId, SecretAccessKey, Token}`). It has no EKS Pod
Identity (container credentials: `AWS_CONTAINER_CREDENTIALS_FULL_URI` plus an `Authorization`
token file) and no web identity. Pointed at the node's real IMDS, it would get the **node's**
role, shared by every pod on the node, which is the opposite of a workload identity.

What makes the fix small: the source does not restrict the host of `url`, sends no IMDSv2 token
when `imdsv2_session_token_url` is unset, and reads the region from `AWS_REGION` before any URL.
So a sidecar on `127.0.0.1` that answers the two IMDS paths from the Pod Identity agent is
enough. It is about forty lines of Python's standard library, delivered as a ConfigMap and run
in a pinned distroless image; it holds the session credentials in memory for the length of one
request and writes nothing.

## Alternatives

| Option | Verdict |
|---|---|
| **A. AWS provider on the gateway's role, IMDS-shaped sidecar** | **Chosen.** Trust is a role ARN, stable across every aws-0 rebuild; the EPI is recreated by Flux on each rebuild with the same name. One small sidecar |
| B. OIDC provider on the EKS issuer, projected token, `file` credential source | No sidecar at all, and `google-cloud-auth` supports it. Rejected: the issuer ID is random per EKS cluster, so every rebuild needs the pool provider re-applied with the new URL, and nothing fails until the first Gemini call answers 403. The shared stack applies before the cluster exists in an AWS deploy, so it cannot read the issuer itself |
| C. Node IMDS | The node role, shared by every pod on the node. Rejected |
| D. A Google service-account key in OpenBao | The thing the owner ruled out |
| E. Fix it upstream (`google-cloud-auth` container credentials, or agentgateway using its own `aws-config` chain as a programmatic AWS supplier) | The right long-term fix, and the sidecar comes out when it lands. Not on our clock |

## Network

The proxy pod's egress, in addition to what the chart already renders for every provider:

| To | Port | Why | Rule |
|---|---|---|---|
| `sts.googleapis.com` | 443 | The token exchange | Chart, `gcpCredentials.source: external` (FQDN) |
| `aiplatform.eu.rep.googleapis.com` | 443 | Vertex, `region: eu` | Chart, as on gcp-0 |
| Pod Identity agent `169.254.170.23` | 80 | The sidecar's credentials | ai-native-ref overlay CNP, `toEntities: [host]` (security/AGENTS.md rule 3) |
| `sts.<region>.amazonaws.com` | none | Google's STS calls it, the pod never does | none |
| `iamcredentials.googleapis.com` | none | No impersonation | none |
| `169.254.169.254` (metadata) | none | The chart drops its metadata rule with `source: external`, so the proxy cannot reach the EC2 metadata service either | none |

## Threats, and why it stays keyless

| Threat | Answer |
|---|---|
| A key leaks | There is none. The config file is public information; the AWS session lives in memory, six hours at most; the Google token one hour |
| Another AWS principal in the account calls Vertex | The pool refuses any ARN but the gateway role's, before IAM sees it; the grant also names that role. Both must be relaxed to widen it |
| Another pod assumes the gateway role | Only a Pod Identity association for `agent-gateway/model-gateway` can, and associations are made by Crossplane from the `EPI` claim. Anyone who can create pods with that ServiceAccount in `agent-gateway` already holds the gateway |
| An `EPI` of the same name elsewhere | IAM role names are account-wide, so a second claim named `xplane-model-gateway` would collide with this role. Claims in other namespaces must not reuse the name; the host's EPI composition does not prevent it today (open question 2) |
| A replayed signed request | The signature binds `x-goog-cloud-target-resource` to this pool provider and expires in 15 minutes; it is only ever sent to Google's STS over TLS |
| The sidecar | Listens on loopback only, serves two read paths, no write, no shell in the image; restricted security context, requests and limits, both probes |
| What the role can do in GCP | `aiplatform.endpoints.predict` in one project: it spends money, reads and changes nothing. Budgets B1, B2 and B6 bound the spend |

## Host contract (version 10)

- **H3** adds `gcp_project_id` and `gcp_vertex_wif_audience` to `eks-aws-0-vars`.
- **H5 Workload identity**: GCP trusts `xplane-model-gateway-iam-role`, the role of
  `EPI xplane-model-gateway`, with the same prediction-only role. A claim with another name is
  not trusted; renaming the claim is a host change.

## What changes in ai-native-ref (aws-0 overlay)

`infrastructure/aws-0/agent-gateway/model-gateway/` gains the `EPI`, the two ConfigMaps
(credential config, sidecar script), the same `vertex` provider patch gcp-0 has plus the
`gcpCredentials` and sidecar values, and an overlay CNP rule for the Pod Identity agent. The run
controller's public aliases gain `gemini-standard` and `gemini-light` as on gcp-0. The child
`model-gateway` gains `dependsOn: eks-pod-identities` for the `EPI` CRD.

## Open questions

1. **Vertex AI and federated principals.** Direct resource access is documented for Vertex AI
   prediction, and gcp-0's Workload Identity principal is the same kind. If the live call answers
   403 `PERMISSION_DENIED` naming the federated principal rather than the permission, the
   fallback is a service account the principalSet impersonates
   (`service_account_impersonation_url`, egress to `iamcredentials.googleapis.com`).
2. **EPI name collision.** Recommend a host-side guard (an admission rule or a composition
   check) that refuses an `EPI` named `xplane-model-gateway` outside `agent-gateway`.
3. **Upstream.** Recommend an issue on `googleapis/google-cloud-rust` for container credentials
   in the AWS source; the sidecar goes away with it.
