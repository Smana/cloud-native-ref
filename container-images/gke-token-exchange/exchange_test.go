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

func TestExchangeDoesNotCacheUnparseableIDToken(t *testing.T) {
	hits := 0
	srv := fakeSTS(t, &hits, 200, `{"access_token":"ya29.fake","expires_in":3598}`)
	defer srv.Close()

	ex := NewExchanger("//aud", srv.Client())
	ex.stsURL = srv.URL

	opaque := "not.a.jwt"
	for i := 0; i < 2; i++ {
		if _, err := ex.Exchange(context.Background(), opaque); err != nil {
			t.Fatalf("call %d: %v", i, err)
		}
	}
	if hits != 2 {
		t.Fatalf("STS called %d times, want 2 (an unbounded entry must never be cached)", hits)
	}
}

func TestExchangeEvictsExpiredEntries(t *testing.T) {
	hits := 0
	srv := fakeSTS(t, &hits, 200, `{"access_token":"ya29.fake","expires_in":3598}`)
	defer srv.Close()

	ex := NewExchanger("//aud", srv.Client())
	ex.stsURL = srv.URL

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
