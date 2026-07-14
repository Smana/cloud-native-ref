package auth

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/Smana/cloud-native-ref/container-images/app-wizard/internal/api"
	"github.com/Smana/cloud-native-ref/container-images/app-wizard/internal/gitprovider"
)

// fakeVerifier is a stand-in for the go-oidc verifier so the session/authz/link
// logic is testable without a live issuer.
type fakeVerifier struct {
	claims ZitadelClaims
	err    error
}

func (f fakeVerifier) Verify(_ context.Context, _ string) (ZitadelClaims, error) {
	return f.claims, f.err
}

func newTestZitadel(requiredRole string) *Zitadel {
	return NewZitadel(ZitadelConfig{
		AuthEndpoint:  "https://id.example/authorize",
		TokenEndpoint: "https://id.example/token",
		ClientID:      "wizard",
		RedirectURL:   "http://localhost:8080/api/auth/callback",
		Verifier:      fakeVerifier{},
		RequiredRole:  requiredRole,
		SessionKey:    []byte("0123456789abcdef0123456789abcdef"), // pragma: allowlist secret
		Factory: func(ctx context.Context, token string) gitprovider.Provider {
			return &gitprovider.FakeProvider{User: gitprovider.User{Login: "gh-user"}}
		},
	})
}

// seedSession writes the given session values through the store and returns a
// request carrying the resulting cookie, so tests can exercise Me /
// ProviderForRequest with a realistic signed+encrypted session.
func seedSession(t *testing.T, z *Zitadel, values map[any]any) *http.Request {
	t.Helper()
	req := httptest.NewRequest(http.MethodGet, "/api/me", nil)
	sess, _ := z.store.Get(req, sessionName)
	for k, v := range values {
		sess.Values[k] = v
	}
	rec := httptest.NewRecorder()
	if err := sess.Save(req, rec); err != nil {
		t.Fatalf("save session: %v", err)
	}
	out := httptest.NewRequest(http.MethodGet, "/api/me", nil)
	for _, c := range rec.Result().Cookies() {
		out.AddCookie(c)
	}
	return out
}

func TestZitadelAuthorized(t *testing.T) {
	tests := []struct {
		name         string
		requiredRole string
		roles        []string
		want         bool
	}{
		{"no required role allows any", "", nil, true},
		{"no required role allows any (with roles)", "", []string{"other"}, true},
		{"required role present", "app-wizard:user", []string{"app-wizard:user"}, true},
		{"required role among many", "app-wizard:user", []string{"x", "app-wizard:user", "y"}, true},
		{"required role missing", "app-wizard:user", []string{"other"}, false},
		{"required role, empty roles", "app-wizard:user", nil, false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			z := newTestZitadel(tt.requiredRole)
			if got := z.authorized(tt.roles); got != tt.want {
				t.Fatalf("authorized(%v) with required %q = %v, want %v", tt.roles, tt.requiredRole, got, tt.want)
			}
		})
	}
}

func TestZitadelMe_RequiredRoleGate(t *testing.T) {
	// Authorized user: role present.
	z := newTestZitadel("app-wizard:user")
	req := seedSession(t, z, map[any]any{
		zitSubKey:       "sub-123",
		zitLoginNameKey: "alice",
		zitNameKey:      "Alice",
		zitRolesKey:     []string{"app-wizard:user"},
	})
	rec := httptest.NewRecorder()
	z.Me(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("authorized Me: got %d, want 200 (body %s)", rec.Code, rec.Body.String())
	}
	var u api.User
	if err := json.Unmarshal(rec.Body.Bytes(), &u); err != nil {
		t.Fatalf("decode user: %v", err)
	}
	if u.Login != "alice" || u.GitHubLinked {
		t.Fatalf("unexpected user: %+v (GitHubLinked should be false, no linked token)", u)
	}

	// Unauthorized user: role missing → 403.
	req = seedSession(t, z, map[any]any{
		zitSubKey:   "sub-456",
		zitRolesKey: []string{"someone-else"},
	})
	rec = httptest.NewRecorder()
	z.Me(rec, req)
	if rec.Code != http.StatusForbidden {
		t.Fatalf("unauthorized Me: got %d, want 403", rec.Code)
	}
}

func TestZitadelMe_Unauthenticated(t *testing.T) {
	z := newTestZitadel("")
	req := httptest.NewRequest(http.MethodGet, "/api/me", nil) // no cookie
	rec := httptest.NewRecorder()
	z.Me(rec, req)
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("no session Me: got %d, want 401", rec.Code)
	}
}

func TestZitadelMe_GitHubLinked(t *testing.T) {
	z := newTestZitadel("")
	req := seedSession(t, z, map[any]any{
		zitSubKey:       "sub-123",
		zitLoginNameKey: "alice",
		tokenKey:        "gh-token-xyz",
	})
	rec := httptest.NewRecorder()
	z.Me(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("Me: got %d, want 200", rec.Code)
	}
	var u api.User
	_ = json.Unmarshal(rec.Body.Bytes(), &u)
	if !u.GitHubLinked {
		t.Fatalf("GitHubLinked should be true when session carries a github token")
	}
}

func TestZitadelProviderForRequest_Sentinels(t *testing.T) {
	z := newTestZitadel("")

	// No session at all → ErrUnauthenticated.
	req := httptest.NewRequest(http.MethodPost, "/api/pr", nil)
	if _, err := z.ProviderForRequest(req); !errors.Is(err, ErrUnauthenticated) {
		t.Fatalf("no session: got %v, want ErrUnauthenticated", err)
	}

	// Authenticated Zitadel user, no linked GitHub token → ErrGitHubNotLinked.
	req = seedSession(t, z, map[any]any{zitSubKey: "sub-123"})
	req.Method = http.MethodPost
	if _, err := z.ProviderForRequest(req); !errors.Is(err, ErrGitHubNotLinked) {
		t.Fatalf("unlinked github: got %v, want ErrGitHubNotLinked", err)
	}

	// Authenticated + linked → provider returned, no error.
	req = seedSession(t, z, map[any]any{zitSubKey: "sub-123", tokenKey: "gh-token"})
	p, err := z.ProviderForRequest(req)
	if err != nil {
		t.Fatalf("linked: unexpected error %v", err)
	}
	if p == nil {
		t.Fatalf("linked: provider should be non-nil")
	}
}

func TestZitadelLinkGitHub_RequiresSession(t *testing.T) {
	z := newTestZitadel("")
	// Unauthenticated link attempt → 401.
	req := httptest.NewRequest(http.MethodGet, GitHubLinkPath, nil)
	rec := httptest.NewRecorder()
	z.LinkGitHub(rec, req)
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("unauthenticated link: got %d, want 401", rec.Code)
	}

	// Authenticated link attempt → 302 redirect to GitHub.
	req = seedSession(t, z, map[any]any{zitSubKey: "sub-123"})
	rec = httptest.NewRecorder()
	z.LinkGitHub(rec, req)
	if rec.Code != http.StatusFound {
		t.Fatalf("authenticated link: got %d, want 302", rec.Code)
	}
	if loc := rec.Header().Get("Location"); loc == "" {
		t.Fatalf("link should redirect to GitHub authorize URL")
	}
}
