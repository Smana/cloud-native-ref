# Per-user Kubernetes RBAC for Headlamp on GKE — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace Headlamp's shared ServiceAccount on `gcp-0` with per-user Kubernetes RBAC driven by ZITADEL group membership, matching the `aws-0` model.

**Architecture:** oauth2-proxy authenticates against ZITADEL and forwards the user's `id_token` to a new token-exchange shim. The shim swaps it at Google STS for a short-lived Workforce Identity Federation access token and sets `X-Gke-Token`. Headlamp forwards that to the GKE API server, which resolves a `principal://` user and `principalSet://…/group/<role>` groups. An ordinary ClusterRoleBinding authorises.

**Tech Stack:** Go 1.23 (shim), OpenTofu + Terramate (workforce pool), Flux/Kustomize (manifests), Helm (oauth2-proxy, Headlamp), Cilium (network policy).

**Spec:** [`docs/superpowers/specs/2026-09-02-gke-rbac-headlamp-design.md`](../specs/2026-09-02-gke-rbac-headlamp-design.md)

## Global Constraints

- The workforce pool id is embedded in **every** RBAC group string. It reaches manifests as `${workforce_pool_id}` via `flux_cluster_vars`; never hard-code it. Pools soft-delete with a **30-day** purge, so the name cannot be reused quickly — treat it as permanent.
- The WIF provider's `client_id` is the ZITADEL **project id** `388445486190712688`, not a per-app client id. Verified 2026-09-02; this is what removes the ordering dependency on `zitadel-oidc-clients.sh`.
- WIF provider `response_type = ID_TOKEN` pairs **only** with `assertion_claims_behavior = ONLY_ID_TOKEN_CLAIMS`. Display names reject parentheses (`INVALID_DISPLAY_NAME`).
- The shim must **never** proxy a request without a token. Headlamp would silently fall back to its ServiceAccount — a silent regression to the exact behaviour being removed. Fail with `502`.
- The shim must **never** log token material at any level. Log `sub`, cache decisions, STS error codes.
- Restricted PSS on every new pod: `runAsNonRoot`, `readOnlyRootFilesystem`, `allowPrivilegeEscalation: false`, `capabilities: {drop: [ALL]}`, `seccompProfile: {type: RuntimeDefault}`. Requests **and** limits mandatory.
- Every new pod gets a default-deny CiliumNetworkPolicy. Any `toFQDNs` rule requires the kube-dns egress rule to carry `toPorts.rules.dns.matchPattern: "*"`, or DNS resolves and TCP is silently dropped.
- `./scripts/validate-manifests.sh` must end `Invalid: 0, Skipped: 0`.
- Terraform: `roles/iam.workforcePoolAdmin` on org `519457084808` is required. `organizationAdmin` does not include it.
- **Before trusting any RBAC test result, run `kubectl config current-context`.** A wrong-cluster kubeconfig produced three wrong conclusions during the design spike.

---

## File Structure

| Path | Responsibility |
|---|---|
| `container-images/gke-token-exchange/main.go` | HTTP handler + reverse proxy wiring |
| `container-images/gke-token-exchange/exchange.go` | STS client + token cache |
| `container-images/gke-token-exchange/exchange_test.go` | unit tests for both |
| `container-images/gke-token-exchange/{Dockerfile,build.sh,README.md,.dockerignore,go.mod}` | image, matching `openbao-snapshot`'s pattern |
| `opentofu/gcp/workforce-identity/` | pool + ZITADEL OIDC provider (org-scoped stack) |
| `opentofu/gcp/gke/configure/kubernetes.tf` | publish `workforce_pool_id` into `flux_cluster_vars` |
| `tooling/gcp-0/headlamp/token-exchange.yaml` | shim Deployment + Service |
| `tooling/gcp-0/headlamp/network-policy.yaml` | extend with the shim's policy |
| `security/gcp-0/rbac/` | `principalSet://` ClusterRoleBinding |
| `tooling/gcp-0/headlamp/{oauth2-proxy,headlamp-proxy-auth}.yaml` | the cutover |
| `website/content/docs/decisions/0032-*.md` | ADR; supersedes 0026 |

---

## Task 1: Token-exchange shim — STS client and cache

**Files:**
- Create: `container-images/gke-token-exchange/go.mod`
- Create: `container-images/gke-token-exchange/exchange.go`
- Test: `container-images/gke-token-exchange/exchange_test.go`

**Interfaces:**
- Produces: `NewExchanger(audience string, c *http.Client) *Exchanger` and `(*Exchanger).Exchange(ctx context.Context, idToken string) (string, error)`. Task 2 consumes both. The unexported `now func() time.Time` field is settable from tests in the same package.

- [ ] **Step 1: Create the module**

```bash
mkdir -p container-images/gke-token-exchange
cd container-images/gke-token-exchange
cat > go.mod <<'EOF'
module github.com/Smana/cloud-native-ref/gke-token-exchange

go 1.23
EOF
```

- [ ] **Step 2: Write the failing tests**

`container-images/gke-token-exchange/exchange_test.go`:

```go
package main

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

// fakeSTS returns a handler that answers `calls` times with a token, counting hits.
func fakeSTS(t *testing.T, hits *int, status int, body string) *httptest.Server {
	t.Helper()
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		*hits++
		if r.Method != http.MethodPost {
			t.Errorf("expected POST, got %s", r.Method)
		}
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(status)
		fmt.Fprint(w, body)
	}))
}

// idToken builds an unsigned JWT with the given exp. Signature is never checked
// locally -- that is STS's job -- so a dummy signature is fine.
func idToken(exp time.Time) string {
	payload, _ := json.Marshal(map[string]int64{"exp": exp.Unix()})
	return "aGRy." + base64.RawURLEncoding.EncodeToString(payload) + ".sig"
}

func TestExchangeReturnsToken(t *testing.T) {
	hits := 0
	srv := fakeSTS(t, &hits, 200, `{"access_token":"ya29.fake","expires_in":3598}`)
	defer srv.Close()

	ex := NewExchanger("//aud", srv.Client())
	ex.stsURL = srv.URL

	got, err := ex.Exchange(context.Background(), idToken(time.Now().Add(time.Hour)))
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if got != "ya29.fake" {
		t.Fatalf("got %q, want ya29.fake", got)
	}
}

func TestExchangeCachesBySubjectToken(t *testing.T) {
	hits := 0
	srv := fakeSTS(t, &hits, 200, `{"access_token":"ya29.fake","expires_in":3598}`)
	defer srv.Close()

	ex := NewExchanger("//aud", srv.Client())
	ex.stsURL = srv.URL
	tok := idToken(time.Now().Add(time.Hour))

	for i := 0; i < 3; i++ {
		if _, err := ex.Exchange(context.Background(), tok); err != nil {
			t.Fatalf("call %d: %v", i, err)
		}
	}
	if hits != 1 {
		t.Fatalf("STS called %d times, want 1 (cache miss)", hits)
	}
}

func TestExchangeDoesNotCacheAcrossDifferentTokens(t *testing.T) {
	hits := 0
	srv := fakeSTS(t, &hits, 200, `{"access_token":"ya29.fake","expires_in":3598}`)
	defer srv.Close()

	ex := NewExchanger("//aud", srv.Client())
	ex.stsURL = srv.URL

	_, _ = ex.Exchange(context.Background(), idToken(time.Now().Add(time.Hour)))
	_, _ = ex.Exchange(context.Background(), idToken(time.Now().Add(2*time.Hour)))
	if hits != 2 {
		t.Fatalf("STS called %d times, want 2 (different subjects must not share a cache entry)", hits)
	}
}

func TestExchangeExpiryBoundedByIDToken(t *testing.T) {
	hits := 0
	// STS grants an hour, but the id_token dies in 6 minutes. With the 5-minute
	// safety margin the entry may live at most ~1 minute.
	srv := fakeSTS(t, &hits, 200, `{"access_token":"ya29.fake","expires_in":3598}`)
	defer srv.Close()

	ex := NewExchanger("//aud", srv.Client())
	ex.stsURL = srv.URL
	tok := idToken(time.Now().Add(6 * time.Minute))

	if _, err := ex.Exchange(context.Background(), tok); err != nil {
		t.Fatalf("first call: %v", err)
	}
	// Jump forward 2 minutes: past the bounded expiry, well inside the STS hour.
	ex.now = func() time.Time { return time.Now().Add(2 * time.Minute) }
	if _, err := ex.Exchange(context.Background(), tok); err != nil {
		t.Fatalf("second call: %v", err)
	}
	if hits != 2 {
		t.Fatalf("STS called %d times, want 2 (cache must expire with the id_token)", hits)
	}
}

func TestExchangeSTSErrorIsReported(t *testing.T) {
	hits := 0
	srv := fakeSTS(t, &hits, 400, `{"error":"invalid_grant","error_description":"bad audience"}`)
	defer srv.Close()

	ex := NewExchanger("//aud", srv.Client())
	ex.stsURL = srv.URL

	_, err := ex.Exchange(context.Background(), idToken(time.Now().Add(time.Hour)))
	if err == nil {
		t.Fatal("expected an error from a 400 response")
	}
	if !strings.Contains(err.Error(), "invalid_grant") {
		t.Fatalf("error should name the STS code, got %q", err)
	}
}

func TestExchangeErrorDoesNotLeakTokenMaterial(t *testing.T) {
	hits := 0
	srv := fakeSTS(t, &hits, 400, `{"error":"invalid_grant","error_description":"token eyJsecret was bad"}`)
	defer srv.Close()

	ex := NewExchanger("//aud", srv.Client())
	ex.stsURL = srv.URL

	_, err := ex.Exchange(context.Background(), idToken(time.Now().Add(time.Hour)))
	if err == nil {
		t.Fatal("expected an error")
	}
	if strings.Contains(err.Error(), "eyJsecret") {
		t.Fatalf("error must not echo the STS description, got %q", err)
	}
}
```

- [ ] **Step 3: Run the tests, confirm they fail to build**

```bash
cd container-images/gke-token-exchange && go test ./...
```
Expected: `undefined: NewExchanger`

- [ ] **Step 4: Implement**

`container-images/gke-token-exchange/exchange.go`:

```go
package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
	"sync"
	"time"
)

// Refresh before real expiry so an in-flight request never carries a token that
// expires mid-call against the API server.
const safetyMargin = 5 * time.Minute

type entry struct {
	token  string
	expiry time.Time
}

// Exchanger swaps a ZITADEL id_token for a Google Workforce Identity Federation
// access token. It holds NO Google credentials: the exchange is authenticated by
// the user's own token.
type Exchanger struct {
	audience string
	client   *http.Client
	stsURL   string
	now      func() time.Time

	mu    sync.Mutex
	cache map[string]entry
}

func NewExchanger(audience string, c *http.Client) *Exchanger {
	return &Exchanger{
		audience: audience,
		client:   c,
		stsURL:   "https://sts.googleapis.com/v1/token",
		now:      time.Now,
		cache:    map[string]entry{},
	}
}

func (x *Exchanger) Exchange(ctx context.Context, idToken string) (string, error) {
	key := cacheKey(idToken)

	x.mu.Lock()
	if ent, ok := x.cache[key]; ok && x.now().Before(ent.expiry) {
		x.mu.Unlock()
		return ent.token, nil
	}
	x.mu.Unlock()

	tok, ttl, err := x.callSTS(ctx, idToken)
	if err != nil {
		return "", err
	}

	expiry := x.now().Add(ttl)
	if idExp, ok := jwtExpiry(idToken); ok && idExp.Before(expiry) {
		expiry = idExp
	}
	expiry = expiry.Add(-safetyMargin)

	if expiry.After(x.now()) {
		x.mu.Lock()
		x.cache[key] = entry{token: tok, expiry: expiry}
		x.mu.Unlock()
	}
	return tok, nil
}

func (x *Exchanger) callSTS(ctx context.Context, idToken string) (string, time.Duration, error) {
	body, err := json.Marshal(map[string]string{
		"grantType":          "urn:ietf:params:oauth:grant-type:token-exchange",
		"audience":           x.audience,
		"scope":              "https://www.googleapis.com/auth/cloud-platform",
		"requestedTokenType": "urn:ietf:params:oauth:token-type:access_token",
		"subjectToken":       idToken,
		"subjectTokenType":   "urn:ietf:params:oauth:token-type:id_token",
	})
	if err != nil {
		return "", 0, err
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, x.stsURL, bytes.NewReader(body))
	if err != nil {
		return "", 0, err
	}
	req.Header.Set("Content-Type", "application/json")

	resp, err := x.client.Do(req)
	if err != nil {
		return "", 0, err
	}
	defer resp.Body.Close()

	raw, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if err != nil {
		return "", 0, err
	}

	if resp.StatusCode != http.StatusOK {
		// Report the STS error CODE only. error_description can echo token
		// material, and this string reaches logs.
		var serr struct {
			Error string `json:"error"`
		}
		_ = json.Unmarshal(raw, &serr)
		if serr.Error == "" {
			serr.Error = "unknown"
		}
		return "", 0, fmt.Errorf("sts %d: %s", resp.StatusCode, serr.Error)
	}

	var out struct {
		AccessToken string `json:"access_token"`
		ExpiresIn   int    `json:"expires_in"`
	}
	if err := json.Unmarshal(raw, &out); err != nil {
		return "", 0, fmt.Errorf("sts response unparseable: %w", err)
	}
	if out.AccessToken == "" {
		return "", 0, fmt.Errorf("sts returned no access_token")
	}
	return out.AccessToken, time.Duration(out.ExpiresIn) * time.Second, nil
}

func cacheKey(tok string) string {
	sum := sha256.Sum256([]byte(tok))
	return hex.EncodeToString(sum[:])
}

// jwtExpiry reads `exp` WITHOUT verifying the signature. Verification is STS's
// job; this only bounds how long the exchanged token may be cached.
func jwtExpiry(tok string) (time.Time, bool) {
	parts := strings.Split(tok, ".")
	if len(parts) != 3 {
		return time.Time{}, false
	}
	payload, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil {
		return time.Time{}, false
	}
	var c struct {
		Exp int64 `json:"exp"`
	}
	if err := json.Unmarshal(payload, &c); err != nil || c.Exp == 0 {
		return time.Time{}, false
	}
	return time.Unix(c.Exp, 0), true
}
```

- [ ] **Step 5: Run the tests, confirm they pass**

```bash
cd container-images/gke-token-exchange && go test ./... -v
```
Expected: all six `PASS`.

- [ ] **Step 6: Commit**

```bash
git add container-images/gke-token-exchange
git commit -m "feat(gke): STS token exchange with expiry-bounded cache"
```

---

## Task 2: Shim HTTP handler and reverse proxy

**Files:**
- Create: `container-images/gke-token-exchange/main.go`
- Test: `container-images/gke-token-exchange/main_test.go`

**Interfaces:**
- Consumes: `NewExchanger`, `(*Exchanger).Exchange` from Task 1.
- Produces: `newHandler(ex *Exchanger, upstream *url.URL, tokenHeader string) http.Handler`. Task 4's manifests set `STS_AUDIENCE`, `UPSTREAM_URL`, `TOKEN_HEADER`, `LISTEN_ADDR`.

- [ ] **Step 1: Write the failing tests**

`container-images/gke-token-exchange/main_test.go`:

```go
package main

import (
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"net/url"
	"testing"
	"time"
)

func testExchanger(t *testing.T, status int, body string) *Exchanger {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(status)
		fmt.Fprint(w, body)
	}))
	t.Cleanup(srv.Close)
	ex := NewExchanger("//aud", srv.Client())
	ex.stsURL = srv.URL
	return ex
}

func validIDToken() string {
	payload, _ := json.Marshal(map[string]int64{"exp": time.Now().Add(time.Hour).Unix()})
	return "aGRy." + base64.RawURLEncoding.EncodeToString(payload) + ".sig"
}

func TestHandlerSetsTokenHeaderAndStripsAuthorization(t *testing.T) {
	var gotToken, gotAuth string
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotToken = r.Header.Get("X-Gke-Token")
		gotAuth = r.Header.Get("Authorization")
		w.WriteHeader(http.StatusOK)
	}))
	defer upstream.Close()
	u, _ := url.Parse(upstream.URL)

	h := newHandler(testExchanger(t, 200, `{"access_token":"ya29.fake","expires_in":3598}`), u, "X-Gke-Token")

	req := httptest.NewRequest(http.MethodGet, "/api/v1/pods", nil)
	req.Header.Set("Authorization", "Bearer "+validIDToken())
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("status %d, want 200", rec.Code)
	}
	if gotToken != "ya29.fake" {
		t.Fatalf("upstream saw X-Gke-Token=%q, want ya29.fake", gotToken)
	}
	if gotAuth != "" {
		t.Fatalf("inbound Authorization must be stripped, upstream saw %q", gotAuth)
	}
}

func TestHandlerRejectsMissingBearer(t *testing.T) {
	u, _ := url.Parse("http://127.0.0.1:1")
	h := newHandler(testExchanger(t, 200, `{"access_token":"x","expires_in":10}`), u, "X-Gke-Token")

	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/", nil))

	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("status %d, want 401", rec.Code)
	}
}

// The most important test in this file. A failed exchange must NOT reach the
// upstream: Headlamp would fall back to its own ServiceAccount and silently
// restore the shared-identity behaviour this service removes.
func TestHandlerNeverProxiesWithoutAToken(t *testing.T) {
	reached := false
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		reached = true
	}))
	defer upstream.Close()
	u, _ := url.Parse(upstream.URL)

	h := newHandler(testExchanger(t, 400, `{"error":"invalid_grant"}`), u, "X-Gke-Token")

	req := httptest.NewRequest(http.MethodGet, "/api/v1/pods", nil)
	req.Header.Set("Authorization", "Bearer "+validIDToken())
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)

	if rec.Code != http.StatusBadGateway {
		t.Fatalf("status %d, want 502", rec.Code)
	}
	if reached {
		t.Fatal("upstream was reached without a token -- silent ServiceAccount fallback")
	}
}

func TestHealthzNeedsNoToken(t *testing.T) {
	u, _ := url.Parse("http://127.0.0.1:1")
	h := newHandler(testExchanger(t, 200, `{"access_token":"x","expires_in":10}`), u, "X-Gke-Token")

	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/healthz", nil))

	if rec.Code != http.StatusOK {
		t.Fatalf("status %d, want 200", rec.Code)
	}
}
```

- [ ] **Step 2: Run, confirm failure**

```bash
cd container-images/gke-token-exchange && go test ./...
```
Expected: `undefined: newHandler`

- [ ] **Step 3: Implement**

`container-images/gke-token-exchange/main.go`:

```go
// gke-token-exchange sits between oauth2-proxy and Headlamp on gcp-0.
//
// GKE trusts no custom OIDC issuer, so Headlamp cannot forward a ZITADEL
// id_token to the API server. It CAN forward a token an upstream proxy hands it
// (-proxy-auth-token-header). This service performs the Workforce Identity
// Federation STS exchange that turns the one into the other.
//
// It holds no Google credentials: the exchange is authenticated by the user's
// own id_token.
package main

import (
	"log"
	"net/http"
	"net/http/httputil"
	"net/url"
	"os"
	"strings"
	"time"
)

func main() {
	audience := mustEnv("STS_AUDIENCE")
	upstreamRaw := mustEnv("UPSTREAM_URL")
	tokenHeader := envOr("TOKEN_HEADER", "X-Gke-Token")
	addr := envOr("LISTEN_ADDR", ":8080")

	upstream, err := url.Parse(upstreamRaw)
	if err != nil {
		log.Fatalf("UPSTREAM_URL is not a URL: %v", err)
	}

	srv := &http.Server{
		Addr:              addr,
		Handler:           newHandler(NewExchanger(audience, http.DefaultClient), upstream, tokenHeader),
		ReadHeaderTimeout: 10 * time.Second,
	}
	log.Printf("listening on %s, upstream %s, audience %s", addr, upstream, audience)
	log.Fatal(srv.ListenAndServe())
}

func newHandler(ex *Exchanger, upstream *url.URL, tokenHeader string) http.Handler {
	proxy := httputil.NewSingleHostReverseProxy(upstream)

	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusOK)
	})
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		idToken := bearer(r.Header.Get("Authorization"))
		if idToken == "" {
			http.Error(w, "no bearer token from the authenticating proxy", http.StatusUnauthorized)
			return
		}

		tok, err := ex.Exchange(r.Context(), idToken)
		if err != nil {
			// Deliberately NOT a pass-through. Without a token Headlamp uses its
			// own ServiceAccount, which is the shared-identity behaviour this
			// service exists to remove -- a silent, invisible regression.
			log.Printf("token exchange failed: %v", err)
			http.Error(w, "token exchange failed", http.StatusBadGateway)
			return
		}

		r.Header.Del("Authorization")
		r.Header.Set(tokenHeader, tok)
		proxy.ServeHTTP(w, r)
	})
	return mux
}

func bearer(h string) string {
	const p = "Bearer "
	if len(h) > len(p) && strings.EqualFold(h[:len(p)], p) {
		return h[len(p):]
	}
	return ""
}

func mustEnv(k string) string {
	v := os.Getenv(k)
	if v == "" {
		log.Fatalf("%s is required", k)
	}
	return v
}

func envOr(k, d string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return d
}
```

- [ ] **Step 4: Run tests, confirm pass**

```bash
cd container-images/gke-token-exchange && go test ./... -v && go vet ./...
```
Expected: all ten tests `PASS`, `go vet` silent.

- [ ] **Step 5: Commit**

```bash
git add container-images/gke-token-exchange
git commit -m "feat(gke): token-exchange handler that never proxies untokenised"
```

---

## Task 3: Container image

**Files:**
- Create: `container-images/gke-token-exchange/Dockerfile`
- Create: `container-images/gke-token-exchange/.dockerignore`
- Create: `container-images/gke-token-exchange/build.sh`
- Create: `container-images/gke-token-exchange/README.md`

**Interfaces:**
- Consumes: the Go module from Tasks 1-2.
- Produces: an image named `gke-token-exchange`. `.github/workflows/build-container-images.yml` discovers `container-images/*/` automatically — no workflow edit needed.

- [ ] **Step 1: Read the existing pattern before writing**

```bash
cat container-images/openbao-snapshot/build.sh
cat container-images/openbao-snapshot/Dockerfile
```
Match its registry, tagging and argument conventions rather than inventing new ones.

- [ ] **Step 2: Write the Dockerfile**

```dockerfile
FROM golang:1.23-alpine AS build
WORKDIR /src
COPY go.mod ./
COPY *.go ./
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/gke-token-exchange .

# Distroless static: the only egress is HTTPS to sts.googleapis.com, so the CA
# bundle is required and nothing else is.
FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /out/gke-token-exchange /gke-token-exchange
USER nonroot:nonroot
EXPOSE 8080
ENTRYPOINT ["/gke-token-exchange"]
```

- [ ] **Step 3: Write `.dockerignore`**

```
README.md
*_test.go
```

- [ ] **Step 4: Write `build.sh` mirroring `openbao-snapshot/build.sh`, and `README.md` covering purpose, env vars (`STS_AUDIENCE`, `UPSTREAM_URL`, `TOKEN_HEADER`, `LISTEN_ADDR`), and the never-proxy-untokenised rule**

- [ ] **Step 5: Build locally and smoke-test the failure path**

```bash
cd container-images/gke-token-exchange
docker build -t gke-token-exchange:dev .
docker run --rm -e STS_AUDIENCE=//x -e UPSTREAM_URL=http://127.0.0.1:1 -p 8080:8080 -d --name tx gke-token-exchange:dev
sleep 2
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:8080/healthz    # expect 200
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:8080/api/v1/pods # expect 401
docker rm -f tx
```

- [ ] **Step 6: Commit**

```bash
git add container-images/gke-token-exchange
git commit -m "build(gke): container image for the token-exchange shim"
```

---

## Task 4: Workforce identity OpenTofu stack

**Files:**
- Create: `opentofu/gcp/workforce-identity/{main.tf,variables.tf,outputs.tf,variables.tfvars,terramate.tm.hcl}`

**Interfaces:**
- Produces: output `workforce_pool_id` (string). Task 5 consumes it.

- [ ] **Step 1: Copy the stack scaffolding conventions from a sibling**

```bash
cat opentofu/gcp/network/terramate.tm.hcl
cat opentofu/gcp/network/variables.tf | head -30
```
Match backend, provider pinning and `terramate.tm.hcl` shape exactly. This stack must run **before** `gcp/gke/configure`.

- [ ] **Step 2: Write `main.tf`**

```hcl
# The workforce pool is an ORGANISATION-level resource, which is why this is its
# own stack rather than part of gke/configure: a second GCP cluster shares it.
resource "google_iam_workforce_pool" "zitadel" {
  workforce_pool_id = var.workforce_pool_id
  parent            = "organizations/${var.org_id}"
  location          = "global"
  display_name      = "ogenki zitadel"  # NO parentheses -- INVALID_DISPLAY_NAME
  description       = "Federates ZITADEL identities for Kubernetes RBAC on GKE"
}

resource "google_iam_workforce_pool_provider" "zitadel" {
  workforce_pool_id = google_iam_workforce_pool.zitadel.workforce_pool_id
  location          = "global"
  provider_id       = "zitadel"
  display_name      = "zitadel oidc"

  # google.groups is what makes RBAC group bindings work: ZITADEL's `groups`
  # claim (produced by scripts/zitadel-actions/groups-from-roles.js) arrives at
  # the API server as principalSet://.../group/<role>.
  attribute_mapping = {
    "google.subject"      = "assertion.sub"
    "google.groups"       = "assertion.groups"
    "google.display_name" = "assertion.email"
  }

  oidc {
    issuer_uri = var.identity_provider_url

    # The ZITADEL PROJECT id, not a per-cluster OIDC client id. ZITADEL includes
    # the project id in the aud of every token issued for that project, and STS
    # accepts it (measured 2026-09-02). This is what lets this stack run before
    # scripts/zitadel-oidc-clients.sh has created any app.
    client_id = var.zitadel_project_id

    web_sso_config {
      # ID_TOKEN pairs ONLY with ONLY_ID_TOKEN_CLAIMS. The other combination
      # fails as "Invalid OIDC WebSsoConfig AssertionClaimsBehavior".
      response_type             = "ID_TOKEN"
      assertion_claims_behavior = "ONLY_ID_TOKEN_CLAIMS"
    }
  }
}
```

- [ ] **Step 3: Write `variables.tf` and `outputs.tf`**

```hcl
variable "org_id" {
  description = "GCP organisation that owns the workforce pool"
  type        = string
}

variable "workforce_pool_id" {
  description = "Pool id. Embedded in every RBAC group string, and soft-deleted for 30 days -- treat as permanent."
  type        = string
}

variable "identity_provider_url" {
  description = "ZITADEL issuer URL"
  type        = string
}

variable "zitadel_project_id" {
  description = "ZITADEL project id, used as the provider audience"
  type        = string
}
```

```hcl
output "workforce_pool_id" {
  description = "Consumed by gke/configure to publish into flux_cluster_vars"
  value       = google_iam_workforce_pool.zitadel.workforce_pool_id
}
```

- [ ] **Step 4: Write `variables.tfvars`**

```hcl
org_id                = "519457084808"
workforce_pool_id     = "ogenki-zitadel"
identity_provider_url = "https://auth.cloud.ogenki.io"
zitadel_project_id    = "388445486190712688"
```

- [ ] **Step 5: Validate**

```bash
cd opentofu/gcp/workforce-identity && tofu init -backend=false && tofu validate
cd - && trivy config --exit-code=1 --ignorefile=./.trivyignore.yaml opentofu/gcp/workforce-identity
```
Expected: `Success! The configuration is valid.` and trivy exit 0.

- [ ] **Step 6: Commit**

```bash
git add opentofu/gcp/workforce-identity
git commit -m "feat(gcp): workforce identity pool federating ZITADEL"
```

---

## Task 5: Publish the pool id into cluster vars

**Files:**
- Modify: `opentofu/gcp/gke/configure/kubernetes.tf`
- Modify: `opentofu/gcp/gke/configure/variables.tf`
- Modify: `opentofu/gcp/gke/configure/variables.tfvars`

**Interfaces:**
- Consumes: `workforce_pool_id` from Task 4.
- Produces: key `workforce_pool_id` in the `gke-gcp-0-vars` ConfigMap. Task 7's manifests substitute it.

- [ ] **Step 1: Add the variable**

In `variables.tf`:
```hcl
variable "workforce_pool_id" {
  description = "Workforce pool federating ZITADEL. Substituted into the gcp-0 RBAC bindings; an empty value silently produces a binding matching nobody."
  type        = string
}
```
In `variables.tfvars`: `workforce_pool_id = "ogenki-zitadel"`

- [ ] **Step 2: Add it to the ConfigMap** in `kubernetes.tf`, inside the `data` block of `flux_cluster_vars`:

```hcl
      workforce_pool_id = var.workforce_pool_id
```

- [ ] **Step 3: Validate**

```bash
cd opentofu/gcp/gke/configure && tofu init -backend=false && tofu validate
```
Expected: `Success! The configuration is valid.`

- [ ] **Step 4: Commit**

```bash
git add opentofu/gcp/gke/configure
git commit -m "feat(gcp): publish workforce_pool_id to gcp-0 cluster vars"
```

---

## Task 6: Shim manifests and network policy

**Files:**
- Create: `tooling/gcp-0/headlamp/token-exchange.yaml`
- Modify: `tooling/gcp-0/headlamp/network-policy.yaml`
- Modify: `tooling/gcp-0/headlamp/kustomization.yaml`

**Interfaces:**
- Consumes: the image from Task 3, `${workforce_pool_id}` from Task 5.
- Produces: Service `headlamp-token-exchange.tooling.svc.cluster.local:8080`. Task 8 points oauth2-proxy at it.

- [ ] **Step 1: Read the existing network policy** so the new rules match its structure

```bash
cat tooling/gcp-0/headlamp/network-policy.yaml
```

- [ ] **Step 2: Write `token-exchange.yaml`** — Deployment + Service. Set `STS_AUDIENCE` to `//iam.googleapis.com/locations/global/workforcePools/${workforce_pool_id}/providers/zitadel` and `UPSTREAM_URL` to `http://headlamp.tooling.svc.cluster.local:80`. Include the full restricted security context from Global Constraints, requests **and** limits, and `/healthz` liveness + readiness probes.

- [ ] **Step 3: Extend the network policy** with a default-deny rule for the shim allowing exactly: ingress from the oauth2-proxy pod on 8080; egress to `headlamp` on 80; egress to kube-dns **with `toPorts.rules.dns.matchPattern: "*"`**; egress to `sts.googleapis.com` on TCP 443 via `toFQDNs`.

Without the DNS L7 rule, Cilium proxies the query but never sees the response IPs, so the `toFQDNs` allowlist has nothing to match: DNS keeps working and every STS call is silently dropped.

- [ ] **Step 4: Add both files to `kustomization.yaml`**

- [ ] **Step 5: Validate**

```bash
./scripts/validate-manifests.sh
```
Expected: exit 0, report shows `Invalid: 0, Skipped: 0`.

- [ ] **Step 6: Commit**

```bash
git add tooling/gcp-0/headlamp
git commit -m "feat(gcp-0): deploy the token-exchange shim with a default-deny policy"
```

---

## Task 7: RBAC binding

**Files:**
- Create: `security/gcp-0/rbac/admin.yaml`
- Create: `security/gcp-0/rbac/kustomization.yaml`
- Modify: `clusters/gcp-0/security/` — the Kustomization that applies it

**Interfaces:**
- Consumes: `${workforce_pool_id}` from Task 5.

- [ ] **Step 1: Write `security/gcp-0/rbac/admin.yaml`**

```yaml
# GCP-0 CANNOT REUSE security/base/rbac/admin.yaml. On aws-0 the group is
# literally `admin`: EKS trusts ZITADEL directly, so the claim passes through
# unchanged. Here the API server sees a Workforce Identity Federation principal,
# so the group carries the pool's full resource path. Same ZITADEL role, same
# cluster-admin, different spelling.
#
# ${workforce_pool_id} comes from the gke-gcp-0-vars ConfigMap. If it were
# undefined Flux would substitute an EMPTY STRING, producing a binding for
# .../workforcePools//group/admin -- schema-valid, matching nobody, denying
# silently. scripts/flux-schema/check-substitution.py is what makes that
# impossible.
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

- [ ] **Step 2: Write `kustomization.yaml`** listing `admin.yaml`.

- [ ] **Step 3: Wire it into the cluster.** Add the path to the Flux Kustomization that applies `security/gcp-0`, ensuring its `postBuild.substituteFrom` includes the `gke-gcp-0-vars` ConfigMap.

- [ ] **Step 4: Validate substitution and manifests**

```bash
python3 scripts/flux-schema/check-substitution.py
./scripts/validate-manifests.sh
```
Expected: substitution check passes with `workforce_pool_id` resolved; `Invalid: 0, Skipped: 0`.

- [ ] **Step 5: Commit**

```bash
git add security/gcp-0/rbac clusters/gcp-0
git commit -m "feat(gcp-0): bind the ZITADEL admin group to cluster-admin"
```

---

## Task 8: The cutover

**Files:**
- Modify: `tooling/gcp-0/headlamp/oauth2-proxy.yaml`
- Modify: `tooling/gcp-0/headlamp/headlamp-proxy-auth.yaml`

This is the only task that changes user-visible behaviour. Tasks 4-7 are inert on their own.

- [ ] **Step 1: Point oauth2-proxy at the shim and forward the id_token**

```yaml
      upstream: "http://headlamp-token-exchange.tooling.svc.cluster.local:8080"
      pass-authorization-header: "true"
```

**Rewrite, do not merely flip, the comment above `pass-authorization-header`.** It currently reads "No Authorization header upstream. Headlamp must NOT receive a bearer token here: it authenticates to the API server with its own ServiceAccount". That justification is now obsolete; leaving it would strand an argument against the code beside it. Replace with: the shim needs the raw id_token as its STS subject token, and it strips the header before reaching Headlamp.

Keep `allowed-group: "admin"`. It is now defence in depth rather than the whole authorisation model, and it keeps non-admins from reaching the shim at all.

- [ ] **Step 2: Switch Headlamp to per-user tokens**

```yaml
      unsafeUseServiceAccountToken: false
      extraArgs:
        - "-proxy-auth=true"
        - "-proxy-auth-group-header=X-Forwarded-Groups"
        - "-proxy-auth-token-header=X-Gke-Token"
```

Replace the long OIDC-is-off comment: OIDC stays off, but it no longer costs anything, because Headlamp never validates a token here — it forwards one the shim minted.

- [ ] **Step 3: Validate**

```bash
./scripts/validate-manifests.sh
```
Expected: `Invalid: 0, Skipped: 0`.

- [ ] **Step 4: Confirm the rendered flags rather than trusting the values**

```bash
grep -A5 'proxy-auth-token-header' .bundle/chart-tooling-gcp-0-tooling-headlamp.yaml
grep -E 'upstream|pass-authorization-header' .bundle/chart-tooling-gcp-0-tooling-headlamp-oauth2-proxy.yaml
```
Expected: both flags present in the rendered output. `config.extraArgs` at the wrong nesting level renders nothing, silently — this is why the check is on the bundle, not the values.

- [ ] **Step 5: Commit**

```bash
git add tooling/gcp-0/headlamp
git commit -m "feat(gcp-0): Headlamp forwards per-user federated tokens"
```

---

## Task 9: Reduce the Headlamp ServiceAccount

**Files:**
- Modify: whichever manifest binds the `headlamp` ServiceAccount (find it first)

- [ ] **Step 1: Find the current binding**

```bash
grep -rn "headlamp" --include='*.yaml' security/ tooling/ | grep -iE 'clusterrolebinding|serviceaccount'
kubectl --context gke_ogenki-435905_europe-west4-a_gcp-0 get clusterrolebinding -o wide | grep -i headlamp
```

- [ ] **Step 2: Reduce it** to only what Headlamp needs for its own operation. User requests no longer run as this identity, so a privileged binding here would preserve the blast radius this whole change removes.

- [ ] **Step 3: Validate and commit**

```bash
./scripts/validate-manifests.sh
git add -A && git commit -m "fix(gcp-0): drop the headlamp SA's user-facing privileges"
```

---

## Task 10: ADR-0032 and documentation

**Files:**
- Create: `website/content/docs/decisions/0032-workforce-identity-federation-for-gke-rbac.md`
- Modify: `website/content/docs/decisions/0026-headlamp-auth-proxy-on-gke.md` (mark superseded)
- Modify: `.doc-claims.yaml`

- [ ] **Step 1: Read the ADR template and a recent ADR**

```bash
cat website/content/docs/decisions/template.md
cat website/content/docs/decisions/0031-per-cluster-observability-panes.md
```

- [ ] **Step 2: Write ADR-0032.** Decision: Workforce Identity Federation over Pinniped, kube-oidc-proxy, and Google Workspace + Google Groups. Include the measured evidence table from the design, and state explicitly that ADR-0026's dismissal rested on assuming Headlamp had to perform the STS exchange itself.

- [ ] **Step 3: Mark ADR-0026 superseded by 0032**, with one sentence on what changed.

- [ ] **Step 4: Add a doc claim** pinning `workforce_pool_id` so the docs cannot drift from the Terraform value.

- [ ] **Step 5: Validate**

```bash
./scripts/validate-links.sh
./scripts/validate-doc-claims.sh
```
Expected: both exit 0.

- [ ] **Step 6: Commit**

```bash
git add website/content/docs/decisions .doc-claims.yaml
git commit -m "docs(adr): ADR-0032 workforce identity federation, supersedes 0026"
```

---

## Task 11: Live verification

Runs after deployment. **This is the task that proves the feature**; everything before it only proves the code renders.

- [ ] **Step 1: Deploy**

```bash
cd opentofu/gcp/workforce-identity && TM_CLOUD=gcp terramate script run deploy
cd ../gke/configure && TM_CLOUD=gcp TF_VAR_flux_git_ref=refs/heads/<branch> terramate script run deploy
flux --context gke_ogenki-435905_europe-west4-a_gcp-0 reconcile kustomization security --with-source
```

- [ ] **Step 2: Confirm the context before any RBAC claim**

```bash
kubectl config current-context   # MUST be gke_ogenki-435905_europe-west4-a_gcp-0
```

A wrong context produced three false conclusions during the design spike. Do not skip this.

- [ ] **Step 3: Positive test.** Log in to `https://headlamp.priv.gcp.ogenki.io/` as a user holding the ZITADEL `admin` role. Expected: the UI loads and lists pods.

- [ ] **Step 4: Confirm the identity is per-user, not the ServiceAccount**

```bash
kubectl --context gke_ogenki-435905_europe-west4-a_gcp-0 \
  logs -n tooling deploy/headlamp-token-exchange | tail -20
```
Expected: exchanges logged per subject, no token material.

- [ ] **Step 5: Negative test — the one that actually proves per-user RBAC.** Remove the `admin` role from a test ZITADEL user, grant `backend` instead, log in. Expected: oauth2-proxy refuses at `allowed-group`, or (if the gate is widened for the test) the user authenticates and is denied by RBAC. Today *every* admitted user is effectively `cluster-admin`, so only a differentiated result demonstrates the change.

- [ ] **Step 6: Regression test — aws-0 untouched**

```bash
kubectl --context aws-0 get clusterrolebinding ogenki-admin -o yaml | head -20
```
Expected: unchanged, `Group: admin`. Confirm aws-0's Headlamp still logs in.

- [ ] **Step 7: Write the verification doc**

```bash
/verify-spec docs/superpowers/specs/2026-09-02-gke-rbac-headlamp-design.md
```

---

## Self-review

**Spec coverage:** pool + provider → Task 4; pool id into cluster vars → Task 5; RBAC binding → Task 7; shim → Tasks 1-3, 6; oauth2-proxy + Headlamp changes → Task 8; CiliumNetworkPolicy → Task 6; SA reduction → Task 9; ADR + supersede → Task 10; the design's whole Testing section → Task 11. Open questions 2 and 3 (shim language, image location) are resolved in-plan as Go and `container-images/`. Open question 4 (non-admin roles) is explicitly out of scope in the design and has no task, correctly.

**Placeholder scan:** no TBD/TODO. Tasks 6, 9 and 10 direct the implementer to read an existing file before writing rather than reproducing its full content — that is deliberate, since those files' current contents are the pattern to match and would go stale if copied here.

**Type consistency:** `NewExchanger`/`Exchange`/`newHandler` signatures match across Tasks 1-2 and their tests. `stsURL` and `now` are unexported fields set by same-package tests; both exist in the Task 1 struct. `workforce_pool_id` is spelled identically in Tasks 4, 5 and 7 and in the ConfigMap key. `X-Gke-Token` is consistent across the shim default, Task 6's env, and Task 8's Headlamp flag.
