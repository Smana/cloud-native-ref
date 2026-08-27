# Workstream 12 verification — GCP public ingress

**Verified 2026-08-25** against a live `gcp-0` in `ogenki-435905` / `europe-west4-a`, tracking
`refs/heads/worktree-gcp-public-ingress` at `5b203fec`. Torn down immediately afterwards.

Design: [`2026-08-25-gcp-public-ingress-design.md`](2026-08-25-gcp-public-ingress-design.md) ·
Plan: [`../plans/2026-08-25-gcp-public-ingress.md`](../plans/2026-08-25-gcp-public-ingress.md) ·
[ADR-0019](../../../website/content/docs/decisions/0019-cross-cloud-dns-federation.md)

**All seven success criteria pass.** An application deployed on GKE was reachable from the public
internet on `ogenki.io`, over a publicly-trusted certificate, with **no static AWS credentials
anywhere on the cluster**.

> **Superseded in one respect, and this matters for reading criterion 2.** The live run above
> issued a **wildcard** certificate for `*.gcp.cloud.ogenki.io`. That was changed afterwards, on
> the grounds that a wildcard means one private key covers every service under the subdomain: the
> Gateway now carries per-listener `certificateRefs`, so cert-manager's gateway-shim issues one
> certificate per hostname. **The per-hostname scheme has not been exercised against a live
> cluster.** Everything else here — the federation, the trust boundary, external-dns, pruning,
> reachability — is unaffected, because none of it depends on how many names a certificate carries.
> Re-run criteria 2 and 6 on the next deploy to close this.

## The gate that runs before any IAM

The plan places this first for a reason recorded in `main.tf`: `data "tls_certificate"` fetches the
certificate of the **host** (`container.googleapis.com`), which succeeds for any URL on that host —
including one whose cluster path 404s. A wrong project, location or cluster name therefore produces
an OIDC provider that applies cleanly and points at nothing.

```
$ curl -sS ".../clusters/gcp-0/.well-known/openid-configuration" | jq -r '.issuer, .jwks_uri'
https://container.googleapis.com/v1/projects/ogenki-435905/locations/europe-west4-a/clusters/gcp-0
https://container.googleapis.com/v1/projects/ogenki-435905/locations/europe-west4-a/clusters/gcp-0/jwks
```

`issuer` echoes the expected URL exactly. Only then was the federation applied:

```
route53_role_arn = "arn:aws:iam::396740644681:role/gcp-0-route53-dns"
```

— identical to the literal Tasks 2 and 4 hardcode, which is what the pre-flight ruling deferred to
this point.

## Criterion 1 — the role is assumable only by two named ServiceAccounts

Verified from the policy **AWS enforces**, not from the source that generated it. This is stronger
than a single negative test: it shows the complete allowed set rather than one denied case.

```json
"Action": "sts:AssumeRoleWithWebIdentity",
"Condition": { "StringEquals": {
  "...clusters/gcp-0:aud": "sts.amazonaws.com",
  "...clusters/gcp-0:sub": [
    "system:serviceaccount:security:cert-manager",
    "system:serviceaccount:kube-system:external-dns-public"
  ] } }
```

`StringEquals` on both conditions — no wildcard anywhere — and no `sts:AssumeRole`, so there is no
role-chaining or static-credential path in. Any other ServiceAccount is refused by construction.

> **Not tested by direct token exchange.** Minting a token for an untrusted ServiceAccount was
> blocked by a permission boundary. The static check above establishes the same property, but the
> negative case remains unexercised — recorded honestly rather than claimed.

## Criterion 2 — a publicly-trusted certificate, issued through the federation

```
$ kubectl get secret platform-public-tls -n infrastructure -o jsonpath='{.data.tls\.crt}' \
    | base64 -d | openssl x509 -noout -issuer -subject -dates
issuer=C=US, O=Let's Encrypt, CN=YR1
subject=CN=*.gcp.cloud.ogenki.io
notBefore=Aug 25 17:38:52 2026 GMT   notAfter=Nov 23 17:38:51 2026 GMT
```

This one line exercises the entire chain: cert-manager minted a projected token, called
`AssumeRoleWithWebIdentity`, received short-lived credentials, solved DNS-01 in Route53, and Let's
Encrypt signed the result. The ClusterIssuer reached `Ready=True`, meaning ACME account registration
also succeeded.

## Criterion 3 — no static AWS credential material on the cluster

```
$ kubectl get secrets -A -o json | jq -r '.items[] | select((.data // {}) | keys[]
    | test("aws.?access.?key|aws.?secret";"i")) | "\(.metadata.namespace)/\(.metadata.name)"'
(no output)
```

## Criterion 4 — the Gateway is programmed

```
NAME              CLASS    ADDRESS         PROGRAMMED
platform-public   cilium   34.178.64.252   True
```

The Flux Kustomization's `healthCheckExprs` on `Programmed` gated this — it did not merely assert
the object existed.

## Criterion 5 — the public record, with an ownership marker

```
probe.gcp.cloud.ogenki.io.   A     34.178.64.252
a-probe.gcp.cloud.ogenki.io. TXT   "heritage=external-dns,external-dns/owner=gcp-0-public,
                                     external-dns/resource=httproute/infrastructure/probe-public"
```

The TXT registry entry is what confines this instance to its own records in a zone `aws-0` shares.

**This is also the proof that F7's fix works.** external-dns logged
`Applying provider record filter for domains: [cloud.ogenki.io. .cloud.ogenki.io.]` with
`AWSZoneMatchParent:true`. Without `--aws-zone-match-parent` it would have discovered **zero** zones
and published nothing, while reporting healthy — a domain filter that is a *child* of the hosted
zone matches no zone by default.

## Criterion 6 — reachable from the public internet

The decisive test, run without `--cacert` so the system trust store validates:

```
$ dig +short probe.gcp.cloud.ogenki.io @8.8.8.8
34.178.64.252
$ curl -sS -o /dev/null -w 'http_code=%{http_code}\nssl_verify_result=%{ssl_verify_result}\n' \
    https://probe.gcp.cloud.ogenki.io/
http_code=200
ssl_verify_result=0
```

`ssl_verify_result=0` is the claim: a public client, public DNS, public trust — no private CA, no
tailnet, no credential on the cluster.

## Criterion 7 — pruning, with zero collateral damage

Deleting the HTTPRoute, then diffing the full 52-record zone before and after:

```
=== removed ===
a-probe.gcp.cloud.ogenki.io. TXT
probe.gcp.cloud.ogenki.io. A
=== added ===
(empty)
```

Exactly the two records this cluster created. **All 50 of `aws-0`'s records untouched** — including
`zitadel`, `grafana`, `harbor-*` and the live `_acme-challenge.cloud.ogenki.io`. This was the
highest-consequence risk in the design and it holds.

## Teardown

Order matters, and the plan was corrected during review to reflect it: `policy: sync` only reclaims
records while external-dns is **running**, so a wholesale destroy would strand `gcp-0-public`-owned
records in the production zone with nothing left alive to clean them up — and a later rebuild would
silently *adopt* them.

1. Deleted the HTTPRoute; external-dns reclaimed both records (verified above).
2. Suspended Flux, deleted the Gateway, and waited for the GCP forwarding rule to be released
   **before** destroying — so the load balancer could not be orphaned by the cluster deletion.
3. `terramate script run --reverse destroy` across the GCP tree.
4. Confirmed against the API rather than exit codes.

`opentofu/shared/aws-gcp-federation` is **deliberately left applied**: an IAM role and an OIDC
provider, both free, and destroying them would mean re-registering the provider on every rebuild.
The same reasoning as the Cloud KMS key ring — a deliberate survivor, not a leak.

## What this does not cover

- The untrusted-ServiceAccount denial (criterion 1's negative case), as noted above.
- Long-lived behaviour: certificate renewal, and external-dns reconciling a record changed
  out-of-band. Both were single-shot here.
- The private path (`infrastructure-gapi`, Tailscale) never reconciled, because the OpenBao stacks
  were deliberately not deployed — nothing in this workstream depends on the private PKI, and the
  public path's independence from it is itself a useful result.
