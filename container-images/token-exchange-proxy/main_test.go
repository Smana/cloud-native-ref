package main

import (
	"fmt"
	"net/http"
	"net/http/httptest"
	"net/url"
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
