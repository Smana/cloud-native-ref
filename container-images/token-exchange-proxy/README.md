# token-exchange-proxy

A tiny, provider-neutral [RFC 8693](https://datatracker.ietf.org/doc/html/rfc8693)
(OAuth 2.0 Token Exchange) reverse proxy, written in Go with no dependency
outside the standard library.

## Problem it solves

A managed API server (a cloud provider's control plane, a Kubernetes API
server fronted by an identity broker, any service that only trusts tokens
minted by its own token service) will not accept a bearer token from a
third-party IdP directly. Meanwhile your users authenticate against that
third-party IdP — an OIDC provider, an internal SSO, whatever already issues
your organisation's identities.

An application sitting between the two can usually forward the caller's
token as a header, but it cannot itself perform an RFC 8693 exchange: that
would mean embedding STS credentials and exchange logic in every app that
needs this, repeated per provider, with the failure mode of a bug there
being a request that reaches the upstream carrying no verified identity at
all — or worse, falling back to some ambient shared credential.

`token-exchange-proxy` sits in front of the upstream instead. It performs
the exchange once, centrally, using nothing but the caller's own subject
token — it holds no credentials of its own — then forwards the request with
the exchanged token in place of the original. Upstream apps stay unaware
that an exchange happens at all.

## The RFC 8693 flow

```
caller                    token-exchange-proxy                  upstream API
  │  request +                 │                                     │
  │  Authorization: Bearer <ID>│                                     │
  ├────────────────────────────►                                     │
  │                             │  POST TEP_STS_URL                  │
  │                             │  grant_type=token-exchange          │
  │                             │  subject_token=<ID>                 │
  │                             │──────────► token endpoint           │
  │                             │◄────────── access_token             │
  │                             │                                     │
  │                             │  same request, subject header       │
  │                             │  replaced by the exchanged token    │
  │                             ├────────────────────────────────────►│
  │                             │◄────────────────────────────────────┤
  │◄────────────────────────────                                     │
```

The proxy caches the exchanged token per subject token (keyed by its SHA-256
hash, never the raw value), bounded by whichever expires first: the token
endpoint's own `expires_in`, or the subject token's `exp` claim if it is a
JWT — minus a 5-minute safety margin. A subject token the proxy cannot parse
an expiry from is never cached at all, so it can never outlive the
credential that authorised it.

## Configuration

Everything is environment-driven; there is no config file and no
provider-specific code path.

| Variable | Meaning | Default | Required |
|---|---|---|---|
| `TEP_STS_URL` | The RFC 8693 token endpoint the proxy POSTs the exchange request to | — | **Yes** |
| `TEP_UPSTREAM_URL` | Base URL of the upstream API server requests are proxied to after a successful exchange | — | **Yes** |
| `TEP_AUDIENCE` | RFC 8693 `audience` parameter — identifies the intended relying party for the requested token | — | No |
| `TEP_RESOURCE` | RFC 8693 `resource` parameter — a URI identifying the target resource | — | No |
| `TEP_SCOPE` | RFC 8693 `scope` parameter — space-delimited scopes requested for the new token | — | No |
| `TEP_SUBJECT_TOKEN_TYPE` | RFC 8693 `subject_token_type` — the token type the caller presents | `urn:ietf:params:oauth:token-type:id_token` | No |
| `TEP_REQUESTED_TOKEN_TYPE` | RFC 8693 `requested_token_type` — the token type being requested | `urn:ietf:params:oauth:token-type:access_token` | No |
| `TEP_REQUEST_ENCODING` | How the exchange request body is serialised: `form` or `json` (see below) | `json` | No |
| `TEP_SUBJECT_HEADER` | Request header the proxy reads the caller's subject token from | `Authorization` | No |
| `TEP_SUBJECT_PREFIX` | Prefix stripped from `TEP_SUBJECT_HEADER` before the remainder is treated as the token; set empty for a header carrying a bare token | `Bearer ` | No |
| `TEP_INJECT_HEADER` | Request header the exchanged token is written into before proxying upstream | `Authorization` | No |
| `TEP_INJECT_PREFIX` | Prefix prepended to the exchanged token when writing `TEP_INJECT_HEADER` | `Bearer ` | No |
| `TEP_STRIP_SUBJECT` | Whether `TEP_SUBJECT_HEADER` is deleted before the upstream ever sees it (`true`/`false`) | `true` | No |
| `TEP_LISTEN_ADDR` | Address the HTTP server listens on | `:8080` | No |

`TEP_STS_URL` and `TEP_UPSTREAM_URL` have no default and must be set
explicitly; every other variable has a working default and the proxy starts
without it being set.

### Request encoding

[RFC 8693 §2.1](https://datatracker.ietf.org/doc/html/rfc8693#section-2.1)
specifies `application/x-www-form-urlencoded` with snake_case parameters
(`form`). In practice not every hosted Security Token Service accepts that:
some require a JSON body with camelCase keys instead (`json`). Neither is
universally supported, so it is configuration rather than a hardcoded
choice.

The default is `json` because that is the encoding this proxy has actually
been exercised against a live STS with. `form` is the RFC-specified
alternative — use it against a token endpoint that requires the RFC's own
encoding; nothing else about the proxy changes.

## Security properties

- **Never proxies without a token.** A failed exchange returns `502 Bad
  Gateway` and the upstream is never reached — see
  `TestHandlerNeverProxiesWithoutAToken`. The alternative (passing the
  request through anyway) would let an upstream silently fall back to
  whatever ambient credential it has, which is exactly the shared-identity
  problem this proxy exists to remove.
- **A missing or malformed subject token is rejected before any exchange is
  attempted**, with `401 Unauthorized`.
- **Client-nominated hop-by-hop headers are stripped on the way in**, before
  the exchanged token is injected. Without this, a client could name the
  injected credential header via `Connection: X-Access-Token` and have Go's
  `httputil.ReverseProxy` strip it back out on the way to the upstream —
  effectively client-controlled credential suppression.
- **The outbound `Host` header is pinned to the configured upstream**, never
  forwarded from the client. `httputil.NewSingleHostReverseProxy` rewrites
  the request URL but leaves `Host` alone by default; a security-facing
  proxy should not let a client choose the `Host` an upstream doing
  Host-based routing or auth sees.
- **Token material is never logged.** On an exchange failure the proxy logs
  and returns only the STS's `error` code, never `error_description` (which
  can echo token content) and never the subject or exchanged token itself.

## Worked example

A generic deployment sitting in front of an internal API, exchanging an
OIDC ID token for an opaque access token:

```bash
export TEP_STS_URL=https://idp.example.com/oauth2/token-exchange
export TEP_UPSTREAM_URL=http://internal-api.svc.cluster.local:8080
export TEP_AUDIENCE=//internal-api.example.com
export TEP_REQUEST_ENCODING=json   # or "form" for an RFC 8693-literal STS

docker run --rm -p 8080:8080 \
  -e TEP_STS_URL -e TEP_UPSTREAM_URL -e TEP_AUDIENCE -e TEP_REQUEST_ENCODING \
  ghcr.io/smana/token-exchange-proxy:v0.1.0
```

A caller then sends its OIDC ID token as it always would:

```bash
curl -H "Authorization: Bearer $ID_TOKEN" http://localhost:8080/api/v1/widgets
```

The proxy exchanges `$ID_TOKEN` for an access token at `TEP_STS_URL`, then
forwards the request to `TEP_UPSTREAM_URL` with that access token in place
of the original `Authorization` header. `internal-api` never sees the
caller's ID token, and never needs to know an exchange happened.

### Appendix: a named-provider example (documentation only)

The proxy has no code path specific to any provider — this is one concrete
set of values, not a dependency. Exchanging a GCP-issued OIDC identity for a
short-lived AWS STS credential via
[AWS IAM Roles Anywhere](https://docs.aws.amazon.com/rolesanywhere/latest/userguide/introduction.html)-style
federation looks the same, just with different endpoint and audience
values:

```bash
export TEP_STS_URL=https://sts.example-broker.com/v1/token-exchange
export TEP_UPSTREAM_URL=https://aws-facing-api.internal
export TEP_AUDIENCE=//iam.amazonaws.com/example-federation
export TEP_SUBJECT_TOKEN_TYPE=urn:ietf:params:oauth:token-type:id_token
export TEP_REQUESTED_TOKEN_TYPE=urn:ietf:params:oauth:token-type:access_token
```

## Building

```bash
./build.sh
```

Mirrors the rest of `container-images/`: `${CONTAINER_REGISTRY:-ghcr.io/smana}/token-exchange-proxy:v0.1.0`,
plus a `latest` tag. See `container-images/README.md` for the CI build and
publish pipeline.
