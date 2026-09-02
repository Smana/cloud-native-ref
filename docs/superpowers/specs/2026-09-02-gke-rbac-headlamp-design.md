# Per-user Kubernetes RBAC for Headlamp on GKE

**Issue:** #1952
**Date:** 2026-09-02
**Status:** design, awaiting review
**Supersedes:** [ADR-0026](../../../website/content/docs/decisions/0026-headlamp-auth-proxy-on-gke.md) (needs a new ADR-0032)

## Problem

`gcp-0` runs Headlamp with `unsafeUseServiceAccountToken: true`. Every user, whoever
they are, reaches the API server as the single `headlamp` ServiceAccount. Per-user
Kubernetes RBAC does not exist on that cluster, so the only authorisation control is
`allowed-group: admin` on oauth2-proxy — an all-or-nothing gate in front of a
shared, privileged identity.

`aws-0` has none of this problem. EKS is told to trust ZITADEL directly
(`identity_providers` in `opentofu/aws/eks/init/variables.tfvars`), so Headlamp
forwards the user's `id_token`, the API server validates it, and
`security/base/rbac/admin.yaml` binds `Group: admin` to `cluster-admin`.

ADR-0026 concluded that GKE could not be made to do the same, because GKE accepts no
custom OIDC issuer and Identity Service for GKE is deprecated (2026-07-01,
unsupported in 1.37+). It named Pinniped as the eventual upgrade path and deferred on
weight.

**That conclusion was wrong, and this design replaces it.**

## What changed

ADR-0026 dismissed Workforce Identity Federation in one sentence:

> Headlamp cannot forward a ZITADEL `id_token` into it. It solves human `kubectl`
> access, not this.

The first half is still true. The second half assumed Headlamp had to *be* the thing
performing the STS exchange. It does not: Headlamp's `-proxy-auth-token-header` flag
makes it forward a raw bearer token handed to it by an upstream proxy, so the
exchange can happen entirely outside Headlamp. That option was not considered.

## What was proven

Everything below was measured against the live `gcp-0` on 2026-09-02, then torn down.
Scripts were throwaway; the evidence is reproduced here because the design rests on
it.

| Claim | Result |
|---|---|
| GKE accepts a Google **id_token** | ✗ `HTTP 401` |
| GKE accepts a Google **access token** | ✓ `HTTP 200` |
| GKE accepts `userinfo.email`-scoped token | ✗ `HTTP 401` |
| GKE accepts `cloud-platform`-scoped token | ✓ `HTTP 200` |
| ZITADEL `id_token` → STS exchange | ✓ 1h token, **no GCP credentials needed** |
| Federated token → gcp-0 API server | ✓ `HTTP 200` |
| Identity GKE resolves | `principal://…/workforcePools/<pool>/subject/<zitadel-sub>` |
| ZITADEL `groups:['admin']` → K8s group | ✓ `principalSet://…/workforcePools/<pool>/group/admin` |
| **ClusterRoleBinding on that group authorises** | ✓ **46 pods listed** |
| RBAC still scopes (negative control) | ✓ `secrets` DENIED |
| GCP IAM roles required on the principal | **none** |
| Fleet registration required | **no** |
| Connect gateway required | **no** |
| In-cluster components required | **none** |
| Federated token's power in GCP | `403` on Resource Manager *and* Cloud Storage |

The last row matters as much as the rest. The STS token is requested with
`cloud-platform` **scope**, which looks alarming, but a workforce principal has no
default IAM permissions — scope is not authority. With zero role bindings the token
authenticates to the cluster and can do nothing whatsoever in Google Cloud. This is
strictly better than the alternative of authenticating Headlamp users as Google
Workspace humans, whose `cloud-platform` token carries everything that person can do.

> **A false trail, recorded so nobody repeats it.** An earlier pass concluded that
> GKE ignores Kubernetes RBAC for federated principals and that authorisation must
> live in Cloud IAM. That was an artefact of `kubectl` being pointed at `aws-0` while
> the token requests went to `gcp-0`: the bindings were created on the wrong cluster.
> Fleet registration and the Connect gateway were investigated as fixes for a problem
> that did not exist. **Check `kubectl config current-context` before trusting an
> RBAC result.**

## Architecture

```
browser
  │
  ▼
oauth2-proxy ──── OIDC authorization-code against ZITADEL
  │               emits X-Forwarded-Groups (existing)
  │               NEW: also forwards the raw ZITADEL id_token upstream
  ▼
token-exchange shim  (NEW, ~40 lines)
  │  POST https://sts.googleapis.com/v1/token
  │    subject_token = the ZITADEL id_token
  │    audience      = //iam.googleapis.com/…/workforcePools/<pool>/providers/zitadel
  │  ← short-lived Google federated access token (1h)
  │  sets X-Gke-Token: <federated token>
  ▼
Headlamp ──── -proxy-auth-token-header=X-Gke-Token
  │           forwards it as Authorization: Bearer to the API server
  ▼
GKE API server
  authenticates → principal://…/subject/<zitadel-sub>
  groups        → principalSet://…/group/admin
  authorises    → ClusterRoleBinding in Git
```

Nothing Google-hosted sits in the request path to the cluster. The only outbound call
is the shim's STS exchange, and it is unauthenticated — it presents the user's own
token and needs no service account.

## Components

### 1. Workforce identity pool — new OpenTofu stack

`opentofu/gcp/workforce-identity/`. A workforce pool is an **organisation**-level
resource, not a project or cluster one, so it does not belong in `gke/configure`. A
second GCP cluster would share this pool.

```hcl
resource "google_iam_workforce_pool" "zitadel" {
  workforce_pool_id = var.workforce_pool_id     # e.g. "ogenki-zitadel"
  parent            = "organizations/${var.org_id}"
  location          = "global"
  display_name      = "ogenki zitadel"          # NO parentheses -- INVALID_DISPLAY_NAME
}

resource "google_iam_workforce_pool_provider" "zitadel" {
  workforce_pool_id = google_iam_workforce_pool.zitadel.workforce_pool_id
  location          = "global"
  provider_id       = "zitadel"

  attribute_mapping = {
    "google.subject"      = "assertion.sub"
    "google.groups"       = "assertion.groups"
    "google.display_name" = "assertion.email"
  }

  oidc {
    issuer_uri = var.identity_provider_url      # https://auth.cloud.ogenki.io
    # The ZITADEL PROJECT id, not a per-cluster OIDC client id. ZITADEL puts the
    # project id in the aud of every token it issues for that project, and STS
    # accepts it (measured 2026-09-02). This is what lets the provider be created
    # before zitadel-oidc-clients.sh has created any app -- see open question 1.
    client_id  = var.zitadel_project_id
    web_sso_config {
      response_type             = "ID_TOKEN"
      assertion_claims_behavior = "ONLY_ID_TOKEN_CLAIMS"
    }
  }
}
```

Two things that cost time in the spike and are easy to hit again:

- `response_type = ID_TOKEN` pairs **only** with `ONLY_ID_TOKEN_CLAIMS`.
  `MERGE_USER_INFO_OVER_ID_TOKEN_CLAIMS` is for the `CODE` response type and fails
  with a bare `Invalid OIDC WebSsoConfig AssertionClaimsBehavior`.
- Display names reject parentheses (`INVALID_DISPLAY_NAME`).

**Required IAM:** `roles/iam.workforcePoolAdmin` on the organisation.
`roles/resourcemanager.organizationAdmin` does *not* include it.

**Deletion is a soft-delete with a 30-day purge**, and the name cannot be reused in
that window. Renaming the pool is therefore expensive and, as the next section shows,
also breaks every RBAC binding. Pick the name once.

### 2. RBAC — the pool name is load-bearing

The Kubernetes group name *contains the pool id*:

```
principalSet://iam.googleapis.com/locations/global/workforcePools/<POOL>/group/admin
```

Hard-coding that in a manifest couples `security/` to a Terraform resource name. Use
the repo's existing substitution idiom instead — `security/gcp-0/rbac/admin.yaml`:

```yaml
# GCP-0 CANNOT REUSE security/base/rbac/admin.yaml. On aws-0 the group is literally
# `admin`, because EKS trusts ZITADEL directly and passes the claim through. Here the
# API server sees a workforce principal, so the group carries the pool's full
# resource path. Same ZITADEL role, same cluster-admin, different spelling.
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: ogenki-admin
subjects:
  - kind: Group
    name: principalSet://iam.googleapis.com/locations/global/workforcePools/${workforce_pool_id}/group/admin
    apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: ClusterRole
  name: cluster-admin
  apiGroup: rbac.authorization.k8s.io
```

`${workforce_pool_id}` must be added to `flux_cluster_vars` in
`opentofu/gcp/gke/configure/kubernetes.tf`, otherwise
`scripts/flux-schema/check-substitution.py` fails the build — correctly, because Flux
would substitute an empty string and produce a binding for
`principalSet://…/workforcePools//group/admin`, which matches nobody and denies
silently.

The Kustomization applying `security/gcp-0/rbac` needs that ConfigMap in its
`substituteFrom`.

### 3. The token-exchange proxy

The one piece of custom code. A small Go service, one container, in the `tooling`
namespace.

**It is deliberately provider-neutral.** RFC 8693 token exchange is generic, and the
gap it fills is not ours alone: no standalone exchange proxy exists, and the same
shape solves AKS/Entra and any managed cluster whose cloud speaks the RFC. Nothing in
the binary names GCP, Kubernetes or Headlamp — the STS endpoint, audience, scope,
token types, request encoding and both header names are configuration. The intent is
to extract it to its own open-source repository **after** it is proven on a live
cluster; publishing an unverified auth-path component would be worse than not
publishing. Everything specific to this platform lives in the Deployment's
environment, not the image.

Two encodings are supported because providers disagree: RFC 8693 specifies
form-encoded snake_case, while some hosted services take JSON with camelCase keys.
The default is JSON, since that is the only encoding measured against a live STS
here — an auth component should not default to a path nobody has exercised.

Behaviour:

1. Read the ZITADEL `id_token` from the inbound `Authorization: Bearer` header
   (oauth2-proxy sets it — see §4).
2. Look it up in an in-memory cache keyed by a hash of the token.
3. On miss, `POST https://sts.googleapis.com/v1/token`:
   ```json
   {
     "grantType":         "urn:ietf:params:oauth:grant-type:token-exchange",
     "audience":          "//iam.googleapis.com/locations/global/workforcePools/<pool>/providers/zitadel",
     "scope":             "https://www.googleapis.com/auth/cloud-platform",
     "requestedTokenType":"urn:ietf:params:oauth:token-type:access_token",
     "subjectToken":      "<the ZITADEL id_token>",
     "subjectTokenType":  "urn:ietf:params:oauth:token-type:id_token"
   }
   ```
4. Cache the result until `min(sts_expiry, id_token_expiry)` minus a 5-minute safety
   margin. STS tokens last 3598s; without caching every page load costs a Google API
   round trip.
5. Set `X-Gke-Token: <access_token>`, strip the inbound `Authorization` header, and
   proxy to `http://headlamp.tooling.svc.cluster.local:80`.

**Failure handling is the part worth getting right.** If the exchange fails the shim
must return `502` with a body naming the STS error, and must **not** pass the request
through tokenless. Headlamp with no token falls back to its ServiceAccount, which is
exactly the shared-identity behaviour this design removes — a silent regression to
the status quo is the worst possible failure mode.

**Never log a token**, at any level. Log the `sub`, the cache decision, and STS
error codes.

Standard restricted-PSS context, requests and limits, liveness and readiness probes,
per the platform constitution.

### 4. oauth2-proxy — one flag, one upstream change

`tooling/gcp-0/headlamp/oauth2-proxy.yaml`:

```yaml
upstream: "http://headlamp-token-exchange.tooling.svc.cluster.local:8080"   # was headlamp
pass-authorization-header: "true"    # was "false" -- the shim needs the id_token
```

The current file explicitly sets `pass-authorization-header: "false"` with a comment
explaining that Headlamp must not receive a bearer token, because it authenticates as
its own ServiceAccount. **That reasoning is now obsolete and the comment must be
rewritten**, not merely flipped — leaving it would strand a justification that argues
against the code beside it.

`allowed-group: "admin"` stays. It is now defence in depth rather than the whole
authorisation model, and it usefully keeps non-admins from reaching the shim at all.

### 5. Headlamp

`tooling/gcp-0/headlamp/headlamp-proxy-auth.yaml`:

```yaml
unsafeUseServiceAccountToken: false        # the point of the whole change
extraArgs:
  - "-proxy-auth=true"
  - "-proxy-auth-group-header=X-Forwarded-Groups"
  - "-proxy-auth-token-header=X-Gke-Token"   # NEW
```

The long comment block explaining why OIDC is off needs replacing with why it is
still off *and no longer matters* — Headlamp never validates a token here; it
forwards one.

The `headlamp` ServiceAccount's existing ClusterRoleBinding should be **reduced to
the minimum Headlamp needs for its own operation**, since it is no longer the
identity user requests run as. Leaving a privileged SA in place would keep the
blast radius this design exists to remove.

### 6. CiliumNetworkPolicy

The shim is a new pod and needs a default-deny policy plus:

- egress to `kube-dns` **with `toPorts.rules.dns.matchPattern: "*"`** — without L7 DNS
  inspection the `toFQDNs` rule below has no IPs to match and every exchange fails
  while DNS appears to work;
- egress to `sts.googleapis.com` on TCP 443 via `toFQDNs`;
- ingress from the oauth2-proxy pod only;
- egress to the `headlamp` pod on 80.

`sts.googleapis.com` is a single hostname, so `toFQDNs` is appropriate here and the
subdomain-glob trap does not apply.

## Security analysis

| | Today | After |
|---|---|---|
| Identity reaching the API server | one shared SA, all users | the actual human |
| Authorisation | `allowed-group` on the proxy | Kubernetes RBAC, in Git |
| Audit trail | every action attributed to the SA | attributed to the ZITADEL subject |
| Credential held server-side | Headlamp's SA token | per-user 1h federated token |
| That credential's power in GCP | n/a | **none** — verified `403` |
| Blast radius of a Headlamp compromise | whatever the SA can do, forever | one user's RBAC, ≤1h |

The shim holds user tokens in memory for their lifetime. That is a real new asset and
the reason for the no-logging rule, the restricted security context, and the
ingress-from-oauth2-proxy-only policy.

## Testing

| Level | What |
|---|---|
| Unit (shim) | cache hit/miss, expiry margin, STS error → 502 (never pass-through), header stripped |
| Manifests | `./scripts/validate-manifests.sh` → `Invalid: 0, Skipped: 0` |
| Substitution | `check-substitution.py` passes with `workforce_pool_id` present |
| OpenTofu | `tofu validate`; `trivy config` clean |
| Live, positive | log in as a user with ZITADEL `admin`; `SelfSubjectReview` shows `principal://…`; a `cluster-admin` action succeeds |
| Live, negative | a user **without** `admin` is refused; a user with a non-admin role gets exactly that role's permissions and no more |
| Live, regression | `aws-0` Headlamp unchanged and still working |

The negative test is the one that proves the design rather than merely exercising it:
today *any* admitted user is `cluster-admin` in effect, so only a differentiated
result demonstrates per-user RBAC.

## Rollout

1. Terraform: create the pool + provider (needs `workforcePoolAdmin` on the org).
2. Add `workforce_pool_id` to `flux_cluster_vars`; apply `gke/configure`.
3. Deploy the shim with the RBAC binding, but leave Headlamp on
   `unsafeUseServiceAccountToken: true`. Nothing changes for users yet.
4. Flip Headlamp to `-proxy-auth-token-header` and
   `unsafeUseServiceAccountToken: false`.
5. Verify positive, negative, and regression tests.
6. Reduce the `headlamp` ServiceAccount's binding.

**Rollback** is step 4 in reverse — a one-line revert restoring
`unsafeUseServiceAccountToken: true`. Steps 1-3 are inert on their own, which is why
they come first.

## Open questions

1. ~~**Which ZITADEL audience does the provider pin?**~~ **RESOLVED 2026-09-02 by
   measurement.** The provider pins the ZITADEL **project id**
   (`388445486190712688`), not a per-cluster OIDC client id. ZITADEL puts the project
   id in the `aud` array of every token issued for that project, and STS accepts it:

   ```
   PROJECT-ID AUDIENCE ACCEPTED  (expires_in 3598)
   user  : principal://…/workforcePools/<pool>/subject/293297125834367432
   groups: ['principalSet://…/workforcePools/<pool>/group/admin', 'system:authenticated']
   ```

   So there is **no chicken-and-egg**: Terraform creates the provider from a value
   that exists before any cluster does, and `scripts/zitadel-oidc-clients.sh` needs no
   post-cluster step to update it. Adding a sixth OIDC client later changes nothing.

   The trade-off to be deliberate about: this audience covers *every* app in the
   `platform` project, so any token ZITADEL issues there can be exchanged. That is
   acceptable because exchange only yields an identity — authorisation is the
   ClusterRoleBinding, and a user without the `admin` role gets a token that
   authenticates and permits nothing.
2. **Shim language.** Go (matches the platform, single static binary, easy distroless
   image) versus Python (shorter). Recommend Go.
3. **Where the shim image is built and pinned.** Harbor, following an existing
   pattern in the repo.
4. Non-`admin` ZITADEL roles (`backend`, `frontend`, `data`) currently have no
   ClusterRole mapping on either cluster. Out of scope here, but this design makes
   them meaningful for the first time and they should get a follow-up.

## Alternatives rejected

- **Pinniped Concierge** (ADR-0026's choice) — a component in the API request path,
  and per Tremolo's comparison it has no story for non-OIDC-native apps like
  Headlamp, so it would *still* need an impersonating proxy beside it. Strictly more
  moving parts than this design.
- **oauth2-proxy + an impersonating proxy** (kube-oidc-proxy and its maintained forks:
  [TremoloSecurity](https://github.com/TremoloSecurity/kube-oidc-proxy),
  [banyansecurity](https://github.com/banyansecurity/kube-oidc-proxy),
  [sspreitzer](https://github.com/sspreitzer/helm-kube-oidc-proxy), or
  [OpenUnison](https://github.com/OpenUnison/openunison-k8s-login-oidc) which bundles
  one). This looked like the strongest contender — it keeps Kubernetes RBAC and needs
  no GCP org changes — but **it cannot work with in-cluster Headlamp at all.** An
  impersonating proxy must sit *behind* Headlamp, and Headlamp cannot be pointed at a
  different API endpoint in-cluster
  ([#1460](https://github.com/kubernetes-sigs/headlamp/issues/1460), open since
  October 2023), nor does its OIDC mode emit impersonation headers
  ([#4198](https://github.com/kubernetes-sigs/headlamp/issues/4198)). The design here
  works precisely because the exchange sits *in front*, where
  `-proxy-auth-token-header` already does what is needed.

  **Correcting an earlier claim in this document's history:** this option was first
  written up as putting "no component in the request path" versus a proxy that does.
  That was wrong. The exchange proxy sits between oauth2-proxy and Headlamp on every
  request. The honest distinction is *small code we own and test* versus *a larger
  third-party component whose upstream is archived* — and, decisively, that the
  latter does not function with in-cluster Headlamp.
- **Google Workspace identities + Google Groups for RBAC** — natively supported and
  needs no shim, but GKE demands a `cloud-platform`-scoped token, which for a real
  Workspace human is a full GCP credential (verified: `HTTP 200` against Resource
  Manager). It would also move group membership out of ZITADEL for one cloud only.
- **Do nothing** — leaves a shared privileged identity behind a single group gate,
  and leaves the two clouds structurally different.

## Constitution compliance

- [x] CiliumNetworkPolicy, default-deny, for the new pod
- [x] No hardcoded credentials — the shim needs no GCP credential at all
- [x] Restricted pod security context; requests + limits
- [x] RBAC least privilege; the `headlamp` SA is *reduced*, not widened
- [x] Health checks on the new workload
- [x] ADR-0032 required — Workforce Identity Federation chosen over named
      alternatives, and it supersedes ADR-0026
