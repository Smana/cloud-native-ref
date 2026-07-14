// Zitadel OIDC authentication (AUTH_MODE=zitadel, CL-11). Zitadel is the login +
// authorization gate: an OIDC Authorization Code + PKCE flow establishes who the
// user is and whether they are allowed (via a role/group claim). GitHub OAuth is
// demoted to a *linked* `repo` token used only to open PRs — Zitadel cannot hand
// the wizard a GitHub token (retrieve-idp-intent returns profile info, not the
// IdP access token), so the two flows stay decoupled behind this seam.
//
// No token material (ID token, GitHub token, PKCE verifier, client secret) is
// ever logged.
package auth

import (
	"context"
	"log/slog"
	"net/http"

	"github.com/Smana/cloud-native-ref/container-images/app-wizard/internal/api"
	"github.com/Smana/cloud-native-ref/container-images/app-wizard/internal/gitprovider"
	"github.com/gorilla/sessions"
	"golang.org/x/oauth2"
	githuboauth "golang.org/x/oauth2/github"
)

// ZitadelRolesScope requests the Zitadel project-roles claim on the ID token so
// the wizard can enforce authorization server-side.
const ZitadelRolesScope = "urn:zitadel:iam:org:project:roles"

// Session keys used by the Zitadel flow. Distinct from the github-mode keys so
// the two modes never collide in a shared cookie.
const (
	zitLoginStateKey = "zit_login_state"
	zitPKCEKey       = "zit_pkce_verifier"
	zitSubKey        = "zit_sub"
	zitLoginNameKey  = "zit_login"
	zitNameKey       = "zit_name"
	zitAvatarKey     = "zit_avatar"
	zitRolesKey      = "zit_roles"
	ghLinkStateKey   = "gh_link_state"
)

// ZitadelClaims is the identity + authorization data extracted from a verified
// Zitadel ID token.
type ZitadelClaims struct {
	Subject       string
	Email         string
	PreferredName string // preferred_username
	Name          string
	AvatarURL     string
	Roles         []string
}

// IDTokenVerifier verifies a raw OIDC ID token (issuer + audience) and returns
// its claims. Implemented by the go-oidc-backed verifier in production and by a
// fake in tests — this is the seam that keeps the session/authz/link logic unit
// testable without a live issuer.
type IDTokenVerifier interface {
	Verify(ctx context.Context, rawIDToken string) (ZitadelClaims, error)
}

// Zitadel is the AUTH_MODE=zitadel authenticator. It owns two decoupled OAuth
// configs: oidcOAuth (Zitadel login) and ghOAuth (GitHub link → PR token).
type Zitadel struct {
	oidcOAuth    *oauth2.Config
	ghOAuth      *oauth2.Config
	verifier     IDTokenVerifier
	store        sessions.Store
	factory      ProviderFactory
	requiredRole string
	logger       *slog.Logger
}

// ZitadelConfig configures the Zitadel authenticator.
type ZitadelConfig struct {
	// AuthEndpoint / TokenEndpoint come from OIDC discovery (issuer/.well-known).
	AuthEndpoint  string
	TokenEndpoint string
	ClientID      string
	ClientSecret  string // may be empty for a public PKCE client
	RedirectURL   string
	// Verifier verifies ID tokens (issuer + this ClientID as audience).
	Verifier IDTokenVerifier
	// RequiredRole gates access; empty ⇒ any authenticated Zitadel user allowed.
	RequiredRole string

	// GitHub link flow (secondary): reuses the existing GitHub OAuth app.
	GitHubClientID     string
	GitHubClientSecret string
	GitHubRedirectURL  string

	SessionKey []byte
	Factory    ProviderFactory
	Logger     *slog.Logger
}

// NewZitadel builds the Zitadel authenticator.
func NewZitadel(cfg ZitadelConfig) *Zitadel {
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
	return &Zitadel{
		oidcOAuth: &oauth2.Config{
			ClientID:     cfg.ClientID,
			ClientSecret: cfg.ClientSecret,
			RedirectURL:  cfg.RedirectURL,
			Scopes:       []string{"openid", "profile", "email", ZitadelRolesScope},
			Endpoint:     oauth2.Endpoint{AuthURL: cfg.AuthEndpoint, TokenURL: cfg.TokenEndpoint},
		},
		ghOAuth: &oauth2.Config{
			ClientID:     cfg.GitHubClientID,
			ClientSecret: cfg.GitHubClientSecret,
			RedirectURL:  cfg.GitHubRedirectURL,
			Scopes:       []string{"repo"},
			Endpoint:     githuboauth.Endpoint,
		},
		verifier:     cfg.Verifier,
		store:        store,
		factory:      cfg.Factory,
		requiredRole: cfg.RequiredRole,
		logger:       logger,
	}
}

// Login redirects to Zitadel's /authorize with Auth Code + PKCE. The PKCE
// verifier and CSRF state are stored in the session.
func (z *Zitadel) Login(w http.ResponseWriter, r *http.Request) {
	state, err := randomState()
	if err != nil {
		z.writeError(w, http.StatusInternalServerError, "failed to init login")
		return
	}
	verifier := oauth2.GenerateVerifier()

	sess, _ := z.store.Get(r, sessionName)
	sess.Values[zitLoginStateKey] = state
	sess.Values[zitPKCEKey] = verifier
	sess.Options.MaxAge = stateCookieTTL
	if err := sess.Save(r, w); err != nil {
		z.writeError(w, http.StatusInternalServerError, "failed to save session")
		return
	}

	url := z.oidcOAuth.AuthCodeURL(state, oauth2.S256ChallengeOption(verifier))
	http.Redirect(w, r, url, http.StatusFound)
}

// Callback exchanges the code, verifies the ID token, enforces the required
// role, and stores the Zitadel identity in the session.
func (z *Zitadel) Callback(w http.ResponseWriter, r *http.Request) {
	sess, _ := z.store.Get(r, sessionName)
	wantState, _ := sess.Values[zitLoginStateKey].(string)
	gotState := r.URL.Query().Get("state")
	if wantState == "" || gotState != wantState {
		z.writeError(w, http.StatusBadRequest, "invalid OAuth state")
		return
	}
	verifier, _ := sess.Values[zitPKCEKey].(string)
	delete(sess.Values, zitLoginStateKey)
	delete(sess.Values, zitPKCEKey)

	code := r.URL.Query().Get("code")
	if code == "" {
		z.writeError(w, http.StatusBadRequest, "missing OAuth code")
		return
	}

	token, err := z.oidcOAuth.Exchange(r.Context(), code, oauth2.VerifierOption(verifier))
	if err != nil {
		z.logger.Warn("zitadel token exchange failed")
		z.writeError(w, http.StatusBadGateway, "OAuth exchange failed")
		return
	}
	rawID, ok := token.Extra("id_token").(string)
	if !ok || rawID == "" {
		z.logger.Warn("zitadel token response missing id_token")
		z.writeError(w, http.StatusBadGateway, "no id_token in token response")
		return
	}

	claims, err := z.verifier.Verify(r.Context(), rawID)
	if err != nil {
		z.logger.Warn("zitadel id_token verification failed")
		z.writeError(w, http.StatusUnauthorized, "invalid id_token")
		return
	}

	if !z.authorized(claims.Roles) {
		z.logger.Info("zitadel user not authorized", "sub", claims.Subject)
		z.writeError(w, http.StatusForbidden, "you are not authorized to use the app wizard")
		return
	}

	sess.Values[zitSubKey] = claims.Subject
	sess.Values[zitLoginNameKey] = loginFromClaims(claims)
	sess.Values[zitNameKey] = claims.Name
	sess.Values[zitAvatarKey] = claims.AvatarURL
	sess.Values[zitRolesKey] = claims.Roles
	sess.Options.MaxAge = 86400 * 7
	if err := sess.Save(r, w); err != nil {
		z.writeError(w, http.StatusInternalServerError, "failed to persist session")
		return
	}
	http.Redirect(w, r, "/", http.StatusFound)
}

// Me returns the Zitadel identity. 401 if unauthenticated; GitHubLinked reports
// whether a linked GitHub token is present.
func (z *Zitadel) Me(w http.ResponseWriter, r *http.Request) {
	sess, _ := z.store.Get(r, sessionName)
	sub, _ := sess.Values[zitSubKey].(string)
	if sub == "" {
		z.writeError(w, http.StatusUnauthorized, "not authenticated")
		return
	}
	// Re-check authorization on every /me: role claims may have been revoked.
	roles, _ := sess.Values[zitRolesKey].([]string)
	if !z.authorized(roles) {
		z.writeError(w, http.StatusForbidden, "you are not authorized to use the app wizard")
		return
	}
	login, _ := sess.Values[zitLoginNameKey].(string)
	name, _ := sess.Values[zitNameKey].(string)
	avatar, _ := sess.Values[zitAvatarKey].(string)
	_, linked := z.githubToken(r)
	writeJSON(w, http.StatusOK, api.User{Login: login, Name: name, AvatarURL: avatar, GitHubLinked: linked})
}

// Logout clears the session (both Zitadel identity and linked GitHub token).
func (z *Zitadel) Logout(w http.ResponseWriter, r *http.Request) {
	sess, _ := z.store.Get(r, sessionName)
	sess.Options.MaxAge = -1
	sess.Values = map[any]any{}
	_ = sess.Save(r, w)
	w.WriteHeader(http.StatusNoContent)
}

// LinkGitHub starts the secondary GitHub OAuth (`repo`) flow to obtain the PR
// token. Requires an authenticated Zitadel session.
func (z *Zitadel) LinkGitHub(w http.ResponseWriter, r *http.Request) {
	sess, _ := z.store.Get(r, sessionName)
	if sub, _ := sess.Values[zitSubKey].(string); sub == "" {
		z.writeError(w, http.StatusUnauthorized, "not authenticated")
		return
	}
	state, err := randomState()
	if err != nil {
		z.writeError(w, http.StatusInternalServerError, "failed to init github link")
		return
	}
	sess.Values[ghLinkStateKey] = state
	if err := sess.Save(r, w); err != nil {
		z.writeError(w, http.StatusInternalServerError, "failed to save session")
		return
	}
	http.Redirect(w, r, z.ghOAuth.AuthCodeURL(state), http.StatusFound)
}

// LinkGitHubCallback exchanges the GitHub code and stores the `repo` token in
// the SAME session, linked to the Zitadel identity.
func (z *Zitadel) LinkGitHubCallback(w http.ResponseWriter, r *http.Request) {
	sess, _ := z.store.Get(r, sessionName)
	if sub, _ := sess.Values[zitSubKey].(string); sub == "" {
		z.writeError(w, http.StatusUnauthorized, "not authenticated")
		return
	}
	wantState, _ := sess.Values[ghLinkStateKey].(string)
	gotState := r.URL.Query().Get("state")
	if wantState == "" || gotState != wantState {
		z.writeError(w, http.StatusBadRequest, "invalid OAuth state")
		return
	}
	delete(sess.Values, ghLinkStateKey)

	code := r.URL.Query().Get("code")
	if code == "" {
		z.writeError(w, http.StatusBadRequest, "missing OAuth code")
		return
	}
	token, err := z.ghOAuth.Exchange(r.Context(), code)
	if err != nil {
		z.logger.Warn("github link exchange failed")
		z.writeError(w, http.StatusBadGateway, "OAuth exchange failed")
		return
	}
	sess.Values[tokenKey] = token.AccessToken
	sess.Options.MaxAge = 86400 * 7
	if err := sess.Save(r, w); err != nil {
		z.writeError(w, http.StatusInternalServerError, "failed to persist session")
		return
	}
	http.Redirect(w, r, "/", http.StatusFound)
}

// ProviderForRequest builds a GitHub provider from the linked token. Returns
// ErrUnauthenticated when there is no Zitadel session, and ErrGitHubNotLinked
// when the user is authenticated but has not connected GitHub yet.
func (z *Zitadel) ProviderForRequest(r *http.Request) (gitprovider.Provider, error) {
	sess, err := z.store.Get(r, sessionName)
	if err != nil {
		return nil, ErrUnauthenticated
	}
	if sub, _ := sess.Values[zitSubKey].(string); sub == "" {
		return nil, ErrUnauthenticated
	}
	token, ok := sess.Values[tokenKey].(string)
	if !ok || token == "" {
		return nil, ErrGitHubNotLinked
	}
	return z.factory(r.Context(), token), nil
}

// githubToken reports whether the session carries a linked GitHub token.
func (z *Zitadel) githubToken(r *http.Request) (string, bool) {
	sess, err := z.store.Get(r, sessionName)
	if err != nil {
		return "", false
	}
	token, ok := sess.Values[tokenKey].(string)
	if !ok || token == "" {
		return "", false
	}
	return token, true
}

// authorized reports whether the roles satisfy the required-role gate. An empty
// requiredRole allows any authenticated user.
func (z *Zitadel) authorized(roles []string) bool {
	if z.requiredRole == "" {
		return true
	}
	for _, r := range roles {
		if r == z.requiredRole {
			return true
		}
	}
	return false
}

func (z *Zitadel) writeError(w http.ResponseWriter, status int, msg string) {
	writeJSON(w, status, api.ErrorResponse{Error: msg})
}

// loginFromClaims picks the best human-facing login: preferred_username, else
// email, else subject.
func loginFromClaims(c ZitadelClaims) string {
	if c.PreferredName != "" {
		return c.PreferredName
	}
	if c.Email != "" {
		return c.Email
	}
	return c.Subject
}

// Ensure both authenticators satisfy the shared interface.
var (
	_ Authenticator = (*Auth)(nil)
	_ Authenticator = (*Zitadel)(nil)
)
