---
title: Per-user RBAC
weight: 17
description: One ZITADEL identity, one set of roles, and a ClusterRoleBinding on either cloud — plus the exchange GKE needs because its API server will not trust ZITADEL.
lastVerified: 2026-09-11
aliases:
  - /docs/platform/security/gke-per-user-rbac/
---

A person logs in once, against ZITADEL, and gets the same access on either
cluster. **The model is identical on both clouds; only the plumbing between the
token and the API server differs** — and on GKE that plumbing is most of this
page, because GKE's API server will not trust ZITADEL directly.

## The shared model

Three steps, the same on `aws-0` and `gcp-0`:

1. **ZITADEL project roles are the source of truth.** `platform`, `backend`,
   `frontend`, `data` — granted to a person, not to a cluster.
2. **A `groups` claim carries them.** ZITADEL has no native groups, so the
   `groupsFromRoles` Action flattens its nested role object into the flat array
   every consumer expects.
3. **An ordinary `ClusterRoleBinding` authorises the group.** No cluster holds a
   credential; nothing is per-cluster except the binding itself.

## Who gets what

The teams and their permissions are not decided on this page. They are
defined once, in
[`security/base/access-matrix/matrix.yaml`](https://github.com/Smana/cloud-native-ref/blob/main/security/base/access-matrix/matrix.yaml),
and `scripts/render_access_matrix.py` renders that single source into every
RBAC manifest that enforces it — `security/base/rbac/teams.yaml` on `aws-0`,
`security/gcp-0/rbac/teams.yaml` on `gcp-0`, and `flux/operator/rbac.yaml` for
the Flux UI. CI runs the renderer with `--check` and fails if a rendered file
was hand-edited instead of the matrix. The table below states what the matrix
currently says — it is not a second copy to keep in sync by hand:

| Team | Google group | Kubernetes | OpenBao mount access | Grafana | Flux UI |
|---|---|---|---|---|---|
| `platform` | `platform@ogenki.io` | **`cluster-admin`** | all | Admin | cluster-admin |
| `backend` | `backend@ogenki.io` | view | own | Editor | edit |
| `data` | `data-eng@ogenki.io` | view | own | Editor | edit |
| `frontend` | `frontend@ogenki.io` | none | none | Editor | none |

`platform` is the one team the matrix requires — the reconciler's
never-leave-it-empty guard keys off that name — and its `mountAccess: all` is
what used to be the hand-written `openbao-admin` OpenBao identity group.
**Only `platform`, `backend` and `data` get a Kubernetes `ClusterRoleBinding`
today** — `frontend`'s `kubernetes: none` means the renderer skips it
entirely; `frontend` gets Grafana access and nothing else.

### Keeping ZITADEL grants in sync

`scripts/access-matrix-sync.sh` reconciles ZITADEL project-role grants from
each team's Google Workspace group membership, so that adding or removing
someone in Workspace becomes the only action needed. **It is built and
fixture-tested, but it is not deployed** — it waits on Google Workspace
prerequisites that do not exist yet (a service account, domain-wide
delegation for `admin.directory.group.readonly`, and the team groups
themselves). Until it runs, role grants are still made by hand, as today.

Once it does run, two behaviours are deliberate rather than bugs:

- **A team's Google group must list its people directly.** A nested group, a
  customer/domain entry, or a member with an unexpected status makes that
  team unreadable: the reconciler changes nothing for it, and the run exits
  non-zero until the group is fixed. It cannot see inside a nested group, and
  treating its people as absent would revoke them.
- **A run exits non-zero when it had to drop a change** — a ZITADEL user
  holding more than one grant on the project, or an email matching two
  ZITADEL users — after applying everything else it could. A member who has
  never logged in is normal and does not fail the run.

## Where the two clouds differ

Exactly one thing: **what the API server is willing to believe.**

| | `aws-0` | `gcp-0` |
|---|---|---|
| Trusts ZITADEL directly? | **Yes** — EKS takes a custom OIDC issuer | **No.** GKE accepts none, and Identity Service for GKE is deprecated as of 2026-07-01, unsupported in 1.37+ |
| What reaches the API server | the user's ZITADEL `id_token`, unchanged | a Google federated token, obtained by exchanging that `id_token` |
| The group the binding names | `platform` | `principalSet://iam.googleapis.com/locations/global/workforcePools/<pool>/group/platform` |
| Extra moving parts | none | a Workforce Identity pool, and a proxy performing the exchange |

That last row of the group name is the practical consequence, and the reason
`gcp-0` cannot reuse the base binding: same ZITADEL role, same `cluster-admin`,
different spelling.

{{< callout type="warning" >}}
`${workforce_pool_id}` in the GCP binding comes from the cluster vars ConfigMap.
Were it undefined, Flux would substitute an **empty string** and produce a
binding for `.../workforcePools//group/platform` — schema-valid, matching
nobody, denying silently. `scripts/flux-schema/check-substitution.py` exists to make that
impossible.
{{< /callout >}}

## How GKE gets there

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

![A browser reaches oauth2-proxy, which authenticates the human against ZITADEL and forwards the resulting id_token to the token-exchange proxy; that proxy sends the id_token to Google STS as an RFC 8693 subject token and receives a one-hour federated token in return, which it injects as X-Gke-Token; Headlamp forwards that header verbatim to the GKE API server as an Authorization bearer, and the API server resolves it to a principal identifier and a principalSet group derived from the user's ZITADEL role, which an ordinary ClusterRoleBinding authorises exactly as on aws-0. A proxy is needed at all because GKE accepts no custom OIDC issuer and Headlamp cannot perform the exchange itself, though it can forward a token a proxy hands it. The exchange requests cloud-platform scope, but a workforce principal has no default IAM permissions, so the same token that lists pods in the cluster is refused with 403 by Cloud Resource Manager and Cloud Storage](/images/diagrams/gke-token-exchange.svg)

In text, in the order a request travels it:

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
  groups        → principalSet://…/workforcePools/ogenki-zitadel/group/platform
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
| RBAC binding | `security/gcp-0/rbac/teams.yaml` | group `principalSet://…/workforcePools/${workforce_pool_id}/group/platform` |
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
produce `workforcePools//group/platform`.

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
