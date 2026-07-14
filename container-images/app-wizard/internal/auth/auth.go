// Package auth implements GitHub OAuth for the wizard (FR-004, T104). The
// user's access token is stored only in a signed+encrypted secure cookie
// session and is never logged. PRs are opened with this per-user token.
package auth

import (
	"context"
	"encoding/json"
	"errors"
	"log/slog"
	"net/http"

	"github.com/Smana/cloud-native-ref/container-images/app-wizard/internal/api"
	"github.com/Smana/cloud-native-ref/container-images/app-wizard/internal/gitprovider"
	"github.com/gorilla/sessions"
	"golang.org/x/oauth2"
	githuboauth "golang.org/x/oauth2/github"
)

const (
	sessionName    = "app-wizard-session"
	tokenKey       = "gh_token"
	stateKey       = "oauth_state"
	stateCookieTTL = 600 // seconds
)

// ProviderFactory builds a gitprovider.Provider from a user token. Injected so
// tests and main can supply GitHub or a fake.
type ProviderFactory func(ctx context.Context, token string) gitprovider.Provider

// Auth holds OAuth configuration and the session store.
type Auth struct {
	oauthConfig *oauth2.Config
	store       sessions.Store
	factory     ProviderFactory
	logger      *slog.Logger
}

// Config configures the Auth handler.
type Config struct {
	ClientID     string
	ClientSecret string
	RedirectURL  string
	SessionKey   []byte
	Factory      ProviderFactory
	Logger       *slog.Logger
}

// New builds an Auth handler.
func New(cfg Config) *Auth {
	logger := cfg.Logger
	if logger == nil {
		logger = slog.Default()
	}
	store := sessions.NewCookieStore(cfg.SessionKey)
	store.Options = &sessions.Options{
		Path:     "/",
		HttpOnly: true,
		Secure:   true,
		SameSite: http.SameSiteLaxMode,
		MaxAge:   86400 * 7,
	}
	return &Auth{
		oauthConfig: &oauth2.Config{
			ClientID:     cfg.ClientID,
			ClientSecret: cfg.ClientSecret,
			RedirectURL:  cfg.RedirectURL,
			Scopes:       []string{"repo", "read:user"},
			Endpoint:     githuboauth.Endpoint,
		},
		store:   store,
		factory: cfg.Factory,
		logger:  logger,
	}
}

// Login redirects the user to GitHub's authorization page.
func (a *Auth) Login(w http.ResponseWriter, r *http.Request) {
	state, err := randomState()
	if err != nil {
		a.writeError(w, http.StatusInternalServerError, "failed to init login")
		return
	}
	sess, _ := a.store.Get(r, sessionName)
	sess.Values[stateKey] = state
	sess.Options.MaxAge = stateCookieTTL
	if err := sess.Save(r, w); err != nil {
		a.writeError(w, http.StatusInternalServerError, "failed to save session")
		return
	}
	http.Redirect(w, r, a.oauthConfig.AuthCodeURL(state), http.StatusFound)
}

// Callback exchanges the auth code for a token and stores it in the session.
func (a *Auth) Callback(w http.ResponseWriter, r *http.Request) {
	sess, _ := a.store.Get(r, sessionName)
	wantState, _ := sess.Values[stateKey].(string)
	gotState := r.URL.Query().Get("state")
	if wantState == "" || gotState != wantState {
		a.writeError(w, http.StatusBadRequest, "invalid OAuth state")
		return
	}
	delete(sess.Values, stateKey)

	code := r.URL.Query().Get("code")
	if code == "" {
		a.writeError(w, http.StatusBadRequest, "missing OAuth code")
		return
	}
	token, err := a.oauthConfig.Exchange(r.Context(), code)
	if err != nil {
		// Never log the code or any token material.
		a.logger.Warn("oauth exchange failed")
		a.writeError(w, http.StatusBadGateway, "OAuth exchange failed")
		return
	}

	sess.Values[tokenKey] = token.AccessToken
	sess.Options.MaxAge = 86400 * 7
	if err := sess.Save(r, w); err != nil {
		a.writeError(w, http.StatusInternalServerError, "failed to persist session")
		return
	}
	http.Redirect(w, r, "/", http.StatusFound)
}

// Me returns the authenticated user (401 if unauthenticated).
func (a *Auth) Me(w http.ResponseWriter, r *http.Request) {
	token, ok := a.Token(r)
	if !ok {
		a.writeError(w, http.StatusUnauthorized, "not authenticated")
		return
	}
	provider := a.factory(r.Context(), token)
	u, err := provider.CurrentUser(r.Context())
	if err != nil {
		a.writeError(w, http.StatusBadGateway, "failed to fetch user")
		return
	}
	writeJSON(w, http.StatusOK, api.User{Login: u.Login, AvatarURL: u.AvatarURL, Name: u.Name})
}

// Logout clears the session.
func (a *Auth) Logout(w http.ResponseWriter, r *http.Request) {
	sess, _ := a.store.Get(r, sessionName)
	sess.Options.MaxAge = -1
	sess.Values = map[any]any{}
	_ = sess.Save(r, w)
	w.WriteHeader(http.StatusNoContent)
}

// Token returns the session's GitHub token, if present.
func (a *Auth) Token(r *http.Request) (string, bool) {
	sess, err := a.store.Get(r, sessionName)
	if err != nil {
		return "", false
	}
	token, ok := sess.Values[tokenKey].(string)
	if !ok || token == "" {
		return "", false
	}
	return token, true
}

// ProviderForRequest builds a gitprovider for the request's authenticated user.
func (a *Auth) ProviderForRequest(r *http.Request) (gitprovider.Provider, error) {
	token, ok := a.Token(r)
	if !ok {
		return nil, ErrUnauthenticated
	}
	return a.factory(r.Context(), token), nil
}

// ErrUnauthenticated is returned when no user token is in the session.
var ErrUnauthenticated = errors.New("auth: not authenticated")

func (a *Auth) writeError(w http.ResponseWriter, status int, msg string) {
	writeJSON(w, status, api.ErrorResponse{Error: msg})
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}
