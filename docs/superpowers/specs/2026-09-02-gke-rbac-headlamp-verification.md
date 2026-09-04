# Per-user Kubernetes RBAC for Headlamp on GKE — verification

**Design:** [`2026-09-02-gke-rbac-headlamp-design.md`](2026-09-02-gke-rbac-headlamp-design.md)
**PR:** #1958 · **Issue:** #1952
**Verified:** 2026-09-02, on a live `gcp-0` rebuilt from the feature branch, before merge.

## Result

Every success criterion met. `gcp-0` now authorises Headlamp users individually,
by ZITADEL group, through Kubernetes RBAC.

| Criterion | Evidence |
|---|---|
| ZITADEL identity reaches the API server | `principal://…/workforcePools/ogenki-zitadel/subject/293297125834367432` |
| ZITADEL role becomes a Kubernetes group | `principalSet://…/ogenki-zitadel/group/admin` |
| RBAC authorises on that group | `A: HTTP 200, pods=46` |
| **RBAC is what decides** | flip binding to `group/backend` → `HTTP 403`; restore → `HTTP 200` |
| Federated token is inert in the cloud | `403` on Resource Manager and Storage |
| Full chain through the proxy | `namespaces 200 (5 items)`, `kube-system/secrets 200 (3 items)` |
| Browser, end to end | `smaine.kahlouch@ogenki.io … metrics.k8s.io/v1beta1/nodes 200 5273 bytes` |
| No ambient fallback | Headlamp SA reduced to `view`; `unsafeUseServiceAccountToken` absent from the rendered bundle |
| `aws-0` unaffected | untouched throughout; its `ogenki-admin` binding still names `Group: admin` |

### On the negative control

A second, non-`admin` user does not exist in this directory, so the literal
"user without the role is refused" test was impossible. It was replaced with a
stronger one: **hold the identity constant and change only the group the binding
names.** Same token, same principal, same cluster —

```
A  binding → group/admin      HTTP 200,  pods=46
B  binding → group/backend    HTTP 403,  DENIED
A  restored                   HTTP 200,  pods=46
```

That isolates group matching as the deciding variable, which a two-user test
would not have done as cleanly. It also rules out the failure mode that matters
most: that a 200 might come from an ambient credential rather than from the
user's own token.

## What live testing caught that no gate did

This is the substance of the exercise. Every item below passed
`validate-manifests.sh` (`Invalid: 0, Skipped: 0`), Polaris, `go vet`, the race
detector, and 20 unit tests while being broken.

| Defect | Why no gate saw it | Fix |
|---|---|---|
| Image tag was never published | The workflow derives a version tag from `ARG <NAME>_VERSION` in the Dockerfile; there was none, so only `latest`/`<branch>-<sha>` existed. The Deployment pinned `:v0.1.0`. Would have `ImagePullBackOff`ed **after merge too**. | `461c901b` |
| Distroless UID | The image declares `USER nonroot` by NAME; with `runAsNonRoot` the kubelet cannot prove it is non-root and refuses. The securityContext is valid and restricted-compliant, so schema and Polaris both approve. | `2016e134` |
| Headlamp ingress named the wrong caller | Policy still permitted `oauth2-proxy`, but after the cutover the shim is what calls Headlamp. The shim's own egress permitted `headlamp:4466`, so the pair read as correct; the drop was recorded against Headlamp's endpoint, so `hubble observe --pod tooling/headlamp-token-exchange` showed **nothing**. Only trace: `dial tcp …:80: i/o timeout`. | `ea14b0c5` |
| Empty config silently defaulted | `envOr` used `os.Getenv`, which cannot distinguish "set to empty" from "absent". `TEP_INJECT_PREFIX: ""` became `"Bearer "`, so the upstream received `Authorization: Bearer Bearer <token>` and the API server returned a bare 401. Exchange succeeded; every component logged success. | `346faac4` |

The `envOr` bug is the one worth remembering: four hypotheses were tested and
discarded before it, and it was found only by comparing a working request against
a failing one header by header.

**A diagnostic gap was also closed.** The proxy logged only the authorization
server's `invalid_grant`, which is indistinguishable between a wrong audience, an
untrusted issuer, an expired token and a malformed one. It now logs the subject
token's `iss`/`aud`/`azp` on failure — configuration, not credential — and that
line immediately disproved two wrong hypotheses of mine.

## Corrections to the design's own claims

- **"No component in the request path" was wrong.** The proxy sits between
  oauth2-proxy and Headlamp on every request. Retracted in the design's
  alternatives section; the honest distinction from an impersonating proxy is
  small code we own versus larger code we do not.
- **"The project id works as the provider audience" was over-generalised.** It was
  measured with a token minted *with* the ZITADEL project-audience scope, which
  proved the provider config but said nothing about what the real consumer sends.
  oauth2-proxy requested plain `openid profile email`, so its token carried
  `aud=[its own client id]`. The consumer must request
  `urn:zitadel:iam:org:project:id:<project>:aud` explicitly (`1c0597c2`).

## Operational notes

- **Cloud secret stores outlive clusters.** `headlamp-oauth2-proxy` survived the
  teardown, so a browser cookie minted by the *previous* `gcp-0` still decrypted
  after the rebuild and replayed a token from an identity provider that no longer
  exists. oauth2-proxy validates the issuer at login, not per request. Symptom: a
  polling tab producing `invalid_grant` every 10s from a dead issuer. A private
  window, or rotating the cookie secret, clears it.
- **The workforce pool id is embedded in every RBAC group string** and pools
  soft-delete with a 30-day purge. The destroy script now says so loudly.

## Not verified

- Behaviour with a genuinely non-`admin` ZITADEL user (none exists).
- The `form` request encoding — only `json` has been exercised against a live STS.
- Extraction of `token-exchange-proxy` to its own repository, which is the
  follow-up this verification unblocks.
