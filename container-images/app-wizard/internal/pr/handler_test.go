package pr

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/Smana/cloud-native-ref/container-images/app-wizard/internal/auth"
	"github.com/Smana/cloud-native-ref/container-images/app-wizard/internal/gitprovider"
)

// TestHandler_GitHubNotLinked maps the zitadel-mode "no linked GitHub token"
// sentinel to 428 Precondition Required with the link hint (CL-11).
func TestHandler_GitHubNotLinked(t *testing.T) {
	s := validService()
	providerFor := func(r *http.Request) (gitprovider.Provider, error) {
		return nil, auth.ErrGitHubNotLinked
	}
	h := s.Handler(providerFor, nil)

	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPost, "/api/pr", strings.NewReader("{}"))
	h(rec, req)

	if rec.Code != http.StatusPreconditionRequired {
		t.Fatalf("got %d, want 428", rec.Code)
	}
	if loc := rec.Header().Get("Location"); loc != auth.GitHubLinkPath {
		t.Fatalf("Location = %q, want %q", loc, auth.GitHubLinkPath)
	}
	if !strings.Contains(rec.Body.String(), "Connect your GitHub account") {
		t.Fatalf("body missing link prompt: %s", rec.Body.String())
	}
}

// TestHandler_Unauthenticated keeps the plain 401 for a missing session.
func TestHandler_Unauthenticated(t *testing.T) {
	s := validService()
	providerFor := func(r *http.Request) (gitprovider.Provider, error) {
		return nil, auth.ErrUnauthenticated
	}
	h := s.Handler(providerFor, nil)

	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPost, "/api/pr", strings.NewReader("{}"))
	h(rec, req)

	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("got %d, want 401", rec.Code)
	}
}
