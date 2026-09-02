package main

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
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

// testConfig returns a Config pointed at the given token endpoint, with the
// remaining fields set to values exercised by the tests below.
func testConfig(stsURL string) Config {
	return Config{
		STSURL:             stsURL,
		Audience:           "//example-audience",
		SubjectTokenType:   "urn:ietf:params:oauth:token-type:id_token",
		RequestedTokenType: "urn:ietf:params:oauth:token-type:access_token",
		RequestEncoding:    EncodingJSON,
		SubjectHeader:      "Authorization",
		SubjectPrefix:      "Bearer ",
		InjectHeader:       "X-Access-Token",
		StripSubject:       true,
		UpstreamURL:        "http://upstream.invalid",
		ListenAddr:         ":8080",
	}
}

// idToken builds an unsigned JWT with the given exp. Signature is never checked
// locally -- that is the token endpoint's job -- so a dummy signature is fine.
func idToken(exp time.Time) string {
	payload, _ := json.Marshal(map[string]int64{"exp": exp.Unix()})
	return "aGRy." + base64.RawURLEncoding.EncodeToString(payload) + ".sig"
}

func TestExchangeReturnsToken(t *testing.T) {
	hits := 0
	srv := fakeSTS(t, &hits, 200, `{"access_token":"opaque.access.token","expires_in":3598}`)
	defer srv.Close()

	ex := NewExchanger(testConfig(srv.URL), srv.Client())

	got, err := ex.Exchange(context.Background(), idToken(time.Now().Add(time.Hour)))
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if got != "opaque.access.token" {
		t.Fatalf("got %q, want opaque.access.token", got)
	}
}

func TestExchangeCachesBySubjectToken(t *testing.T) {
	hits := 0
	srv := fakeSTS(t, &hits, 200, `{"access_token":"opaque.access.token","expires_in":3598}`)
	defer srv.Close()

	ex := NewExchanger(testConfig(srv.URL), srv.Client())
	tok := idToken(time.Now().Add(time.Hour))

	for i := 0; i < 3; i++ {
		if _, err := ex.Exchange(context.Background(), tok); err != nil {
			t.Fatalf("call %d: %v", i, err)
		}
	}
	if hits != 1 {
		t.Fatalf("token endpoint called %d times, want 1 (cache miss)", hits)
	}
}

func TestExchangeDoesNotCacheAcrossDifferentTokens(t *testing.T) {
	hits := 0
	srv := fakeSTS(t, &hits, 200, `{"access_token":"opaque.access.token","expires_in":3598}`)
	defer srv.Close()

	ex := NewExchanger(testConfig(srv.URL), srv.Client())

	_, _ = ex.Exchange(context.Background(), idToken(time.Now().Add(time.Hour)))
	_, _ = ex.Exchange(context.Background(), idToken(time.Now().Add(2*time.Hour)))
	if hits != 2 {
		t.Fatalf("token endpoint called %d times, want 2 (different subjects must not share a cache entry)", hits)
	}
}

func TestExchangeExpiryBoundedBySubjectToken(t *testing.T) {
	hits := 0
	// The token endpoint grants an hour, but the subject token dies in 6
	// minutes. With the 5-minute safety margin the entry may live at most ~1
	// minute.
	srv := fakeSTS(t, &hits, 200, `{"access_token":"opaque.access.token","expires_in":3598}`)
	defer srv.Close()

	ex := NewExchanger(testConfig(srv.URL), srv.Client())
	tok := idToken(time.Now().Add(6 * time.Minute))

	if _, err := ex.Exchange(context.Background(), tok); err != nil {
		t.Fatalf("first call: %v", err)
	}
	// Jump forward 2 minutes: past the bounded expiry, well inside the token
	// endpoint's hour.
	ex.now = func() time.Time { return time.Now().Add(2 * time.Minute) }
	if _, err := ex.Exchange(context.Background(), tok); err != nil {
		t.Fatalf("second call: %v", err)
	}
	if hits != 2 {
		t.Fatalf("token endpoint called %d times, want 2 (cache must expire with the subject token)", hits)
	}
}

func TestExchangeErrorIsReported(t *testing.T) {
	hits := 0
	srv := fakeSTS(t, &hits, 400, `{"error":"invalid_grant","error_description":"bad audience"}`)
	defer srv.Close()

	ex := NewExchanger(testConfig(srv.URL), srv.Client())

	_, err := ex.Exchange(context.Background(), idToken(time.Now().Add(time.Hour)))
	if err == nil {
		t.Fatal("expected an error from a 400 response")
	}
	if !strings.Contains(err.Error(), "invalid_grant") {
		t.Fatalf("error should name the exchange code, got %q", err)
	}
}

func TestExchangeErrorDoesNotLeakTokenMaterial(t *testing.T) {
	hits := 0
	srv := fakeSTS(t, &hits, 400, `{"error":"invalid_grant","error_description":"token eyJsecret was bad"}`)
	defer srv.Close()

	ex := NewExchanger(testConfig(srv.URL), srv.Client())

	_, err := ex.Exchange(context.Background(), idToken(time.Now().Add(time.Hour)))
	if err == nil {
		t.Fatal("expected an error")
	}
	if strings.Contains(err.Error(), "eyJsecret") {
		t.Fatalf("error must not echo the exchange description, got %q", err)
	}
}

func TestExchangeDoesNotCacheUnparseableSubjectToken(t *testing.T) {
	hits := 0
	srv := fakeSTS(t, &hits, 200, `{"access_token":"opaque.access.token","expires_in":3598}`)
	defer srv.Close()

	ex := NewExchanger(testConfig(srv.URL), srv.Client())

	opaque := "not.a.jwt"
	for i := 0; i < 2; i++ {
		if _, err := ex.Exchange(context.Background(), opaque); err != nil {
			t.Fatalf("call %d: %v", i, err)
		}
	}
	if hits != 2 {
		t.Fatalf("token endpoint called %d times, want 2 (an unbounded entry must never be cached)", hits)
	}
}

func TestExchangeEvictsExpiredEntries(t *testing.T) {
	hits := 0
	srv := fakeSTS(t, &hits, 200, `{"access_token":"opaque.access.token","expires_in":3598}`)
	defer srv.Close()

	ex := NewExchanger(testConfig(srv.URL), srv.Client())

	if _, err := ex.Exchange(context.Background(), idToken(time.Now().Add(6*time.Minute))); err != nil {
		t.Fatal(err)
	}
	if len(ex.cache) != 1 {
		t.Fatalf("cache has %d entries, want 1", len(ex.cache))
	}

	// Past the first entry's expiry. Writing a different token must sweep the dead
	// entry rather than accumulate it.
	ex.now = func() time.Time { return time.Now().Add(10 * time.Minute) }
	if _, err := ex.Exchange(context.Background(), idToken(time.Now().Add(2*time.Hour))); err != nil {
		t.Fatal(err)
	}
	if len(ex.cache) != 1 {
		t.Fatalf("cache has %d entries after the eviction sweep, want 1", len(ex.cache))
	}
}

func TestFormEncodingUsesRFCParameterNames(t *testing.T) {
	var gotContentType, gotBody string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotContentType = r.Header.Get("Content-Type")
		b, _ := io.ReadAll(r.Body)
		gotBody = string(b)
		fmt.Fprint(w, `{"access_token":"tok","expires_in":3598}`)
	}))
	defer srv.Close()

	cfg := testConfig(srv.URL)
	cfg.RequestEncoding = EncodingForm
	ex := NewExchanger(cfg, srv.Client())

	if _, err := ex.Exchange(context.Background(), idToken(time.Now().Add(time.Hour))); err != nil {
		t.Fatal(err)
	}
	if gotContentType != "application/x-www-form-urlencoded" {
		t.Errorf("Content-Type = %q, want form encoding", gotContentType)
	}
	for _, want := range []string{"grant_type=", "subject_token=", "subject_token_type="} {
		if !strings.Contains(gotBody, want) {
			t.Errorf("form body should contain %q, got %q", want, gotBody)
		}
	}
}
