---
title: Per-user RBAC on GKE
weight: 17
description: How a ZITADEL identity becomes a Kubernetes group on a cluster whose API server will not trust ZITADEL — the RFC 8693 exchange, the pieces that must agree, and the four failures only a live cluster exposed.
lastVerified: 2026-09-02
---

`aws-0` hands the user's ZITADEL token straight to the API server, because EKS can
be told to trust ZITADEL as an OIDC provider. **GKE cannot be told that**, and the
feature that used to allow it — Identity Service for GKE — is deprecated as of
2026-07-01 and unsupported in 1.37+.

The obvious conclusion is that per-user RBAC is impossible on GKE without putting
an impersonating proxy in front of the API server. That conclusion is wrong, and
this page is the mechanism that replaces it.

## The idea in one paragraph

GKE will not trust ZITADEL, but it *will* trust Google. **Workforce Identity
Federation** lets Google trust ZITADEL, and [RFC 8693 token
exchange](https://www.rfc-editor.org/info/rfc8693/) converts one into the other.
A small proxy performs that exchange between oauth2-proxy and Headlamp, so
Headlamp forwards a token GKE accepts. GKE resolves it to a real principal
carrying the user's ZITADEL role as a Kubernetes group, and an ordinary
`ClusterRoleBinding` authorises it.

Nothing Google-hosted sits in the path to the cluster, and no component in the
cluster holds a credential of its own.

## The chain

```
browser
  │
  ▼
oauth2-proxy ─── OIDC against ZITADEL
  │              forwards the user's id_token upstream
  ▼
token-exchange-proxy
  │  POST https://sts.googleapis.com/v1/token
  │    subject_token = the ZITADEL id_token
  │    audience      = //iam.googleapis.com/…/workforcePools/ogenki-zitadel/providers/zitadel
  │  ← short-lived Google federated token
  │  sets X-Gke-Token
  ▼
Headlamp ─── -proxy-auth-token-header=X-Gke-Token
  │           forwards it as Authorization: Bearer to the API server
  ▼
GKE API server
  authenticates → principal://…/workforcePools/ogenki-zitadel/subject/<zitadel sub>
  groups        → principalSet://…/workforcePools/ogenki-zitadel/group/admin
  authorises    → ClusterRoleBinding in security/gcp-0/rbac/
```

## Why the federated token is not the liability it looks like

The exchange requests `https://www.googleapis.com/auth/cloud-platform` scope,
which reads alarmingly. It is not, and the distinction matters:

> **Scope is not authority.** A workforce principal has no default IAM
> permissions. With no role bindings, the token authenticates to the cluster and
> can do *nothing* in Google Cloud.

Measured on a live cluster: the same token that lists 46 pods returns `403` from
both Cloud Resource Manager and Cloud Storage. That is strictly better than the
alternative of authenticating users as Google Workspace humans, whose
`cloud-platform` token carries everything that person can do.

## The pieces, and where each lives

| Piece | Where | What it must say |
|---|---|---|
| Workforce pool + ZITADEL provider | `opentofu/gcp/workforce-identity/` | `client_id` = the ZITADEL **project** id; `google.groups ← assertion.groups` |
| Pool id → cluster vars | `opentofu/gcp/gke/configure/` | published as `workforce_pool_id` |
| RBAC binding | `security/gcp-0/rbac/admin.yaml` | group `principalSet://…/workforcePools/${workforce_pool_id}/group/admin` |
| The proxy | `container-images/token-exchange-proxy/` | provider-neutral; all specifics are `TEP_*` env |
| Its Deployment | `tooling/gcp-0/headlamp/token-exchange.yaml` | the `TEP_*` values, and `runAsUser: 65532` |
| oauth2-proxy | `tooling/gcp-0/headlamp/oauth2-proxy.yaml` | upstream = the proxy; `pass-authorization-header: true`; the project-audience scope |
| Headlamp | `tooling/gcp-0/headlamp/headlamp-proxy-auth.yaml` | `-proxy-auth-token-header=X-Gke-Token`; `unsafeUseServiceAccountToken: false` |
| Network policy | `tooling/gcp-0/headlamp/network-policy.yaml` | Headlamp ingress from **the proxy**, not oauth2-proxy |

### The provider's audience is the ZITADEL project id

Deliberately, and for the same reason `aws-0` pins a project id: ZITADEL puts the
project id in the `aud` of every token issued for that project, so any client in
`platform` is accepted and adding a consumer needs no change here.

It also removes an ordering problem — the project id is known before any OIDC
client exists, so the pool can be created before `zitadel-oidc-clients.sh` has
ever run.

{{< callout type="warning" >}}
**The consumer must request that audience explicitly.** ZITADEL only puts the
project id in `aud` when the token was requested with
`urn:zitadel:iam:org:project:id:<project>:aud`. With plain `openid profile email`
the token carries `aud=[the client's own id]`, the exchange fails with a bare
`invalid_grant`, and oauth2-proxy, the proxy and Headlamp all report healthy. The
only symptom is `token exchange failed` in the browser.
{{< /callout >}}

### The pool id is load-bearing and effectively permanent

It appears verbatim inside every RBAC group string. Rename the pool and every
binding silently matches nobody — the manifests stay valid, nothing errors, and
the symptom is "everyone is suddenly unauthorised".

Worse, workforce pools **soft-delete with a 30-day purge**, so the same name
cannot be recreated until then; re-running `deploy` does not undo it. The
stack's `destroy` script says so loudly before it runs.

The value reaches manifests as `${workforce_pool_id}` from the cluster vars
ConfigMap, which is what makes `scripts/flux-schema/check-substitution.py` able to
catch an undefined variable — Flux would otherwise substitute an empty string and
produce `workforcePools//group/admin`.

## Diagnosing it

The proxy logs the subject token's `iss`, `aud` and `azp` whenever an exchange
fails. Those are configuration, not credentials, and they exist because an
authorization server refusing an exchange says only `invalid_grant` — which is
indistinguishable between a wrong audience, an untrusted issuer, an expired token
and a malformed one.

```console
$ kubectl logs -n tooling deploy/headlamp-token-exchange
token exchange failed: token exchange 400: invalid_grant \
  (subject iss=https://auth.cloud.ogenki.io azp=3884… aud=["3884…"])
```

Read the `aud` first. If it does not contain the ZITADEL project id, the consumer
is not requesting the project-audience scope.

To check what the API server makes of a token, ask it directly:

```console
$ curl -sk -H "Authorization: Bearer ${FEDERATED_TOKEN}" \
    -X POST https://${ENDPOINT}/apis/authentication.k8s.io/v1/selfsubjectreviews \
    -H 'Content-Type: application/json' \
    -d '{"apiVersion":"authentication.k8s.io/v1","kind":"SelfSubjectReview"}'
```

It returns the resolved `username` and `groups` — the fastest way to tell an
authentication problem from an authorisation one.

## Four failures that every gate passed over

Each of these survived `validate-manifests.sh` (`Invalid: 0, Skipped: 0`),
Polaris, `go vet`, the race detector and the unit suite. They are recorded
because the shape repeats, not because the specifics will.

**The pinned image tag was never published.** The image workflow derives a
version tag from `ARG <NAME>_VERSION` in the Dockerfile. Without one it publishes
only `latest` and `<branch>-<sha>`, so a Deployment pinning `:v0.1.0` can never
pull. This would have failed *after* merge exactly as before it.

**A distroless image needs a numeric UID.** The image declares `USER nonroot` by
name; under `runAsNonRoot` the kubelet cannot prove that is not root and refuses
with `CreateContainerConfigError` — after pulling successfully. The
securityContext is valid and restricted-compliant, so both schema validation and
Polaris approve it. Only a real kubelet objects.

**A network policy named the wrong caller.** Headlamp's ingress still permitted
oauth2-proxy, but after this change the *proxy* is what calls Headlamp. The
proxy's own egress rule permitted `headlamp:4466`, so the pair read as correct in
review — and because the drop is recorded against **Headlamp's** endpoint,
`hubble observe --pod tooling/headlamp-token-exchange` showed nothing at all, not
even a `DROPPED` verdict. The only trace anywhere was
`dial tcp <clusterIP>:80: i/o timeout`, which reads like a slow upstream.

**An explicitly empty config value silently defaulted.** `os.Getenv` cannot
distinguish "set to empty" from "absent", so `TEP_INJECT_PREFIX: ""` — meaning
"inject the raw token" — became `"Bearer "`. The API server received
`Authorization: Bearer Bearer <token>` and answered `401`, while the exchange
succeeded and every component logged success. Found only by comparing a working
request against a failing one header by header.

{{< callout type="warning" >}}
**A cloud secret store outlives the cluster.** `headlamp-oauth2-proxy` lives in
Secret Manager, so after a rebuild a browser cookie minted by the *previous*
cluster still decrypts — and oauth2-proxy validates the issuer at login, not per
request. The symptom is a tab replaying tokens from an identity provider that no
longer exists. A private window clears it; rotating the cookie secret clears it
for everyone.
{{< /callout >}}

## The proxy is deliberately not ours-only

`token-exchange-proxy` names no cloud, no orchestrator and no application. The
STS endpoint, audience, scope, token types, request encoding and both header
names are configuration; everything specific to this platform lives in the
Deployment's environment.

That is not gold-plating. No standalone RFC 8693 exchange proxy exists, and the
gap is not ours alone — Headlamp
[#5402](https://github.com/kubernetes-sigs/headlamp/issues/5402),
[#2643](https://github.com/kubernetes-sigs/headlamp/issues/2643),
[#1338](https://github.com/kubernetes-sigs/headlamp/issues/1338) and
[#2207](https://github.com/kubernetes-sigs/headlamp/issues/2207) all describe it.
The same shape solves AKS/Entra and any managed cluster whose cloud speaks the
RFC.

Two request encodings are supported because providers disagree: RFC 8693
specifies form-encoded snake_case, while some hosted services want JSON with
camelCase keys. The default is JSON — the only encoding exercised against a live
STS here, because an auth component should not default to a path nobody has run.

## Related

- [ADR-0032]({{< relref "/docs/decisions/0032-workforce-identity-federation-for-gke-rbac.md" >}}) — the decision, and the alternatives weighed
- [ADR-0026]({{< relref "/docs/decisions/0026-headlamp-auth-proxy-on-gke.md" >}}) — superseded; the shared-ServiceAccount design this replaced
- [Authentication]({{< relref "/docs/platform/security/authentication.md" >}}) — the whole identity chain, both clouds
