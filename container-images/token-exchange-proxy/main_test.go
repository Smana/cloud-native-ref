package main

import (
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
	"time"
)

// testExchanger returns an Exchanger, and the Config that built it, pointed
// at a fake token endpoint that always answers with status/body. The
// returned Config is what a real deployment would pass to both NewExchanger
// and newHandler -- the two share one Config.
func testExchanger(t *testing.T, status int, body string) (*Exchanger, Config) {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(status)
		fmt.Fprint(w, body)
	}))
	t.Cleanup(srv.Close)
	cfg := testConfig(srv.URL)
	return NewExchanger(cfg, srv.Client()), cfg
}

func TestHandlerSetsInjectHeaderAndStripsSubject(t *testing.T) {
	var gotInject, gotSubject string
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotInject = r.Header.Get("X-Access-Token")
		gotSubject = r.Header.Get("Authorization")
		w.WriteHeader(http.StatusOK)
	}))
	defer upstream.Close()
	u, _ := url.Parse(upstream.URL)

	ex, cfg := testExchanger(t, 200, `{"access_token":"opaque.access.token","expires_in":3598}`)
	h := newHandler(ex, cfg, u)

	req := httptest.NewRequest(http.MethodGet, "/api/v1/widgets", nil)
	req.Header.Set("Authorization", "Bearer "+idToken(time.Now().Add(time.Hour)))
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("status %d, want 200", rec.Code)
	}
	if gotInject != "opaque.access.token" {
		t.Fatalf("upstream saw %s=%q, want opaque.access.token", cfg.InjectHeader, gotInject)
	}
	if gotSubject != "" {
		t.Fatalf("subject header must be stripped, upstream saw %q", gotSubject)
	}
}

func TestHandlerRejectsMissingSubjectToken(t *testing.T) {
	u, _ := url.Parse("http://127.0.0.1:1")
	ex, cfg := testExchanger(t, 200, `{"access_token":"x","expires_in":10}`)
	h := newHandler(ex, cfg, u)

	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/", nil))

	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("status %d, want 401", rec.Code)
	}
}

// The most important test in this file. A failed exchange must NOT reach the
// upstream: a downstream consumer would fall back to its own ambient
// credentials and silently restore the shared-identity behaviour this proxy
// removes.
func TestHandlerNeverProxiesWithoutAToken(t *testing.T) {
	reached := false
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		reached = true
	}))
	defer upstream.Close()
	u, _ := url.Parse(upstream.URL)

	ex, cfg := testExchanger(t, 400, `{"error":"invalid_grant"}`)
	h := newHandler(ex, cfg, u)

	req := httptest.NewRequest(http.MethodGet, "/api/v1/widgets", nil)
	req.Header.Set("Authorization", "Bearer "+idToken(time.Now().Add(time.Hour)))
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)

	if rec.Code != http.StatusBadGateway {
		t.Fatalf("status %d, want 502", rec.Code)
	}
	if reached {
		t.Fatal("upstream was reached without a token -- silent credential fallback")
	}
}

func TestHealthzNeedsNoToken(t *testing.T) {
	u, _ := url.Parse("http://127.0.0.1:1")
	ex, cfg := testExchanger(t, 200, `{"access_token":"x","expires_in":10}`)
	h := newHandler(ex, cfg, u)

	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/healthz", nil))

	if rec.Code != http.StatusOK {
		t.Fatalf("status %d, want 200", rec.Code)
	}
}

// When SubjectHeader and InjectHeader are the same name -- the shipped
// default, both "Authorization" -- StripSubject must not wipe out the
// exchanged token that was just written under that name.
func TestHandlerInjectSurvivesStripWhenHeadersShareAName(t *testing.T) {
	var gotAuth string
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotAuth = r.Header.Get("Authorization")
		w.WriteHeader(http.StatusOK)
	}))
	defer upstream.Close()
	u, _ := url.Parse(upstream.URL)

	ex, cfg := testExchanger(t, 200, `{"access_token":"opaque.access.token","expires_in":3598}`)
	cfg.InjectHeader = cfg.SubjectHeader // both "Authorization"
	cfg.InjectPrefix = "Bearer "
	h := newHandler(ex, cfg, u)

	req := httptest.NewRequest(http.MethodGet, "/api/v1/widgets", nil)
	req.Header.Set("Authorization", "Bearer "+idToken(time.Now().Add(time.Hour)))
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("status %d, want 200", rec.Code)
	}
	if gotAuth != "Bearer opaque.access.token" {
		t.Fatalf("upstream Authorization = %q, want %q (strip must not clobber the inject)", gotAuth, "Bearer opaque.access.token")
	}
}

// A client that names the injected credential header as hop-by-hop, via
// Connection, must not be able to have httputil.ReverseProxy strip it back
// out on the way to the upstream.
func TestClientCannotStripInjectedHeaderViaConnection(t *testing.T) {
	var gotToken string
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotToken = r.Header.Get("X-Access-Token")
		w.WriteHeader(http.StatusOK)
	}))
	defer upstream.Close()
	u, _ := url.Parse(upstream.URL)

	ex, cfg := testExchanger(t, 200, `{"access_token":"real.exchanged.token","expires_in":3598}`)
	cfg.InjectHeader = "X-Access-Token"
	cfg.InjectPrefix = ""
	h := newHandler(ex, cfg, u)

	req := httptest.NewRequest(http.MethodGet, "/anything", nil)
	req.Header.Set("Authorization", "Bearer "+idToken(time.Now().Add(time.Hour)))
	// The attack: nominate the credential header as hop-by-hop.
	req.Header.Set("Connection", "X-Access-Token")
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)

	if gotToken != "real.exchanged.token" {
		t.Fatalf("upstream saw %q -- a client stripped the injected credential", gotToken)
	}
}

// NewSingleHostReverseProxy does not rewrite the Host header on its own; a
// security-facing proxy should pin it to the upstream rather than forward
// whatever Host the client sent.
func TestHostHeaderIsPinnedToUpstream(t *testing.T) {
	var gotHost string
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotHost = r.Host
		w.WriteHeader(http.StatusOK)
	}))
	defer upstream.Close()
	u, _ := url.Parse(upstream.URL)

	ex, cfg := testExchanger(t, 200, `{"access_token":"t","expires_in":3598}`)
	h := newHandler(ex, cfg, u)

	req := httptest.NewRequest(http.MethodGet, "/", nil)
	req.Header.Set("Authorization", "Bearer "+idToken(time.Now().Add(time.Hour)))
	req.Host = "attacker.example.invalid"
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)

	if gotHost == "attacker.example.invalid" {
		t.Fatalf("client Host reached upstream verbatim: %q", gotHost)
	}
}

func TestHandlerKeepsSubjectHeaderWhenStripSubjectFalse(t *testing.T) {
	var gotSubject string
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotSubject = r.Header.Get("Authorization")
		w.WriteHeader(http.StatusOK)
	}))
	defer upstream.Close()
	u, _ := url.Parse(upstream.URL)

	ex, cfg := testExchanger(t, 200, `{"access_token":"opaque.access.token","expires_in":3598}`)
	cfg.StripSubject = false
	h := newHandler(ex, cfg, u)

	subjectHeader := "Bearer " + idToken(time.Now().Add(time.Hour))
	req := httptest.NewRequest(http.MethodGet, "/api/v1/widgets", nil)
	req.Header.Set("Authorization", subjectHeader)
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("status %d, want 200", rec.Code)
	}
	if gotSubject != subjectHeader {
		t.Fatalf("subject header changed though StripSubject=false: got %q, want %q", gotSubject, subjectHeader)
	}
}

// subjectDiagnostics is what makes a bare `invalid_grant` diagnosable, so its
// output format is a contract with whoever is reading logs at 2am. It must
// render the claims plainly, and must never echo the token itself.
func TestSubjectDiagnosticsReportsClaimsNotToken(t *testing.T) {
	payload, _ := json.Marshal(map[string]any{
		"iss": "https://issuer.example",
		"azp": "client-123",
		"aud": []string{"aud-a", "aud-b"},
		"sub": "should-not-appear-verbatim-as-a-token",
	})
	tok := "aGRy." + base64.RawURLEncoding.EncodeToString(payload) + ".sig"

	got := subjectDiagnostics(tok)
	for _, want := range []string{"iss=https://issuer.example", "azp=client-123", "aud-a", "aud-b"} {
		if !strings.Contains(got, want) {
			t.Errorf("diagnostics %q should contain %q", got, want)
		}
	}
	if strings.Contains(got, tok) {
		t.Errorf("diagnostics must never contain the token itself: %q", got)
	}
}

func TestSubjectDiagnosticsHandlesNonJWT(t *testing.T) {
	for _, tok := range []string{"opaque-token", "a.b", "a.!!!not-base64!!!.c"} {
		got := subjectDiagnostics(tok)
		if got == "" {
			t.Errorf("expected a description for %q, got empty", tok)
		}
		if strings.Contains(got, "iss=") {
			t.Errorf("a malformed token must not report claims: %q", got)
		}
	}
}
