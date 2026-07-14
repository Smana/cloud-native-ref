package auth

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/Smana/cloud-native-ref/container-images/app-wizard/internal/gitprovider"
)

func newTestAuth(dev gitprovider.Provider) *Auth {
	return New(Config{
		ClientID:    "gh-client",
		RedirectURL: "http://localhost:8080/api/auth/callback",
		SessionKey:  []byte("0123456789abcdef0123456789abcdef"), // pragma: allowlist secret
		Factory: func(ctx context.Context, token string) gitprovider.Provider {
			return &gitprovider.FakeProvider{User: gitprovider.User{Login: "gh-user"}}
		},
		DevProvider: dev,
	})
}

// seedAuthToken returns a request carrying a session with a github token, so
// github-mode ProviderForRequest can be exercised without the OAuth round-trip.
func seedAuthToken(t *testing.T, a *Auth, token string) *http.Request {
	t.Helper()
	req := httptest.NewRequest(http.MethodPost, "/api/pr", nil)
	sess, _ := a.store.Get(req, sessionName)
	sess.Values[tokenKey] = token
	rec := httptest.NewRecorder()
	if err := sess.Save(req, rec); err != nil {
		t.Fatalf("save session: %v", err)
	}
	out := httptest.NewRequest(http.MethodPost, "/api/pr", nil)
	for _, c := range rec.Result().Cookies() {
		out.AddCookie(c)
	}
	return out
}

// TestGitHubModeProviderForRequest confirms github mode is unchanged: a linked
// token yields a provider; no token yields ErrUnauthenticated (never the
// zitadel-only ErrGitHubNotLinked sentinel).
func TestGitHubModeProviderForRequest(t *testing.T) {
	a := newTestAuth(nil)

	// No session → ErrUnauthenticated.
	req := httptest.NewRequest(http.MethodPost, "/api/pr", nil)
	if _, err := a.ProviderForRequest(req); !errors.Is(err, ErrUnauthenticated) {
		t.Fatalf("no session: got %v, want ErrUnauthenticated", err)
	}

	// With token → provider, no error.
	req = seedAuthToken(t, a, "gh-token")
	p, err := a.ProviderForRequest(req)
	if err != nil || p == nil {
		t.Fatalf("with token: provider=%v err=%v", p, err)
	}
}

// TestDevModeBypass confirms AUTH_MODE=dev still returns the dev provider
// without a session (login bypass unchanged).
func TestDevModeBypass(t *testing.T) {
	dev := &gitprovider.FakeProvider{User: gitprovider.User{Login: "dev-user"}}
	a := newTestAuth(dev)

	req := httptest.NewRequest(http.MethodPost, "/api/pr", nil) // no session
	p, err := a.ProviderForRequest(req)
	if err != nil {
		t.Fatalf("dev bypass: unexpected error %v", err)
	}
	if p != dev {
		t.Fatalf("dev bypass: expected the dev provider")
	}
}
