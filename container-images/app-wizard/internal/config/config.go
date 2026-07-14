// Package config loads the app-wizard runtime configuration from the
// environment. All values have local-dev-friendly defaults so `go run` works
// without any setup; secrets (OAuth client secret, session key) come from the
// environment only and are never logged.
package config

import (
	"crypto/rand"
	"encoding/hex"
	"os"
	"path/filepath"
	"strings"
)

// XRDSourceMode selects where the schema pipeline reads repo files from.
type XRDSourceMode string

const (
	// SourceLocal reads files from RepoRoot on disk (dev/test).
	SourceLocal XRDSourceMode = "local"
	// SourceGitHub reads files from the GitHub repo via the API (prod).
	SourceGitHub XRDSourceMode = "github"
)

// Config is the fully-resolved runtime configuration.
type Config struct {
	// ListenAddr is the HTTP bind address (LISTEN_ADDR, default ":8080").
	ListenAddr string

	// AuthMode selects the authentication backend (AUTH_MODE):
	//   "github" (default) — real GitHub OAuth; login == PR token, opened as the user.
	//   "dev"              — LOCAL TESTING ONLY. Bypasses login (fake user) and
	//                        writes generated files to RepoRoot instead of opening
	//                        a real PR. Must never be set in a deployed environment.
	//   "zitadel"          — Zitadel OIDC is the login + authorization gate (CL-11);
	//                        GitHub OAuth is demoted to a linked `repo` token used
	//                        only to open PRs (Zitadel cannot supply a GitHub token).
	AuthMode string

	// GitHubClientID / GitHubClientSecret are the OAuth app credentials
	// (GITHUB_CLIENT_ID / GITHUB_CLIENT_SECRET). In zitadel mode these back the
	// secondary "Connect GitHub" link flow that yields the PR token.
	GitHubClientID     string
	GitHubClientSecret string
	// OAuthRedirectURL is the callback URL registered with the OAuth app
	// (OAUTH_REDIRECT_URL). Defaults to a localhost callback for dev. In zitadel
	// mode this is the GitHub-link callback (/api/auth/github/callback); if it
	// still points at the primary callback path it is rewritten automatically.
	OAuthRedirectURL string

	// --- Zitadel OIDC (AUTH_MODE=zitadel, CL-11). ---
	//
	// ZitadelIssuer is the OIDC issuer URL used for discovery + ID-token
	// verification (ZITADEL_ISSUER, e.g. https://id.priv.cloud.ogenki.io).
	ZitadelIssuer string
	// ZitadelClientID / ZitadelClientSecret are the Zitadel application
	// credentials (ZITADEL_CLIENT_ID / ZITADEL_CLIENT_SECRET). The secret may be
	// empty for a public PKCE client. Never logged.
	ZitadelClientID     string
	ZitadelClientSecret string
	// ZitadelRedirectURL is the Zitadel callback URL registered with the
	// application (ZITADEL_REDIRECT_URL, default localhost /api/auth/callback).
	ZitadelRedirectURL string
	// ZitadelRequiredRole, when set, gates access: only users whose Zitadel
	// role/group claim contains it may use the wizard (e.g. "app-wizard:user").
	// Empty ⇒ any authenticated Zitadel user is allowed (ZITADEL_REQUIRED_ROLE).
	ZitadelRequiredRole string

	// RepoOwner / RepoName identify the GitOps repository PRs are opened
	// against (REPO_OWNER / REPO_NAME).
	RepoOwner string
	RepoName  string
	// RepoBaseBranch is the PR base branch (REPO_BASE_BRANCH, default "main").
	RepoBaseBranch string

	// XRDSource selects the schema source backend (XRD_SOURCE, local|github).
	XRDSource XRDSourceMode
	// RepoRoot is the on-disk repository root used by the local source and by
	// the crossplane renderer to locate composition files (REPO_ROOT).
	RepoRoot string

	// SessionKey is the secret used to authenticate/encrypt the session cookie
	// (SESSION_KEY). A random ephemeral key is generated when unset — fine for
	// dev, but sessions do not survive a restart.
	SessionKey []byte

	// XRDPath is the repo-relative path to the App XRD (XRD_PATH).
	XRDPath string
	// UIHintsPath is the on-disk path to ui-hints.yaml (UI_HINTS_PATH).
	UIHintsPath string
	// StacksPath is the repo-relative path to apps/stacks.yaml (STACKS_PATH).
	StacksPath string
	// CompositionPath / FunctionsPath / EnvConfigPath are repo-relative paths
	// used by the crossplane renderer.
	CompositionPath string
	FunctionsPath   string
	EnvConfigPath   string
	// FunctionsDevTargets maps a Crossplane Function name to a running gRPC
	// endpoint (host:port), parsed from FUNCTIONS_DEV_TARGETS
	// ("function-kcl=localhost:9443,function-auto-ready=localhost:9444,…").
	// When set, the renderer overlays the "Development" runtime onto the repo's
	// functions.yaml so `crossplane render` connects to those endpoints (the
	// in-pod function sidecars) instead of pulling+running images via Docker.
	FunctionsDevTargets map[string]string

	// --- LLM assists (Phase 3, FR-011). All optional. ---
	//
	// LLMAPIKey is the Anthropic API key (LLM_API_KEY). Never logged. When set,
	// LLM assists are available.
	LLMAPIKey string
	// LLMBaseURL overrides the Anthropic API base URL (LLM_BASE_URL). Optional;
	// lets the wizard target the platform AI Gateway. When empty the SDK default
	// (api.anthropic.com) is used. A non-empty base URL also marks assists as
	// available (supports a keyless gateway).
	LLMBaseURL string
	// LLMModel is the model id used for assists (LLM_MODEL, default
	// "claude-opus-4-8").
	LLMModel string
}

// AssistsAvailable reports whether LLM assists are configured: either an API
// key or a base URL (keyless gateway) is set.
func (c *Config) AssistsAvailable() bool {
	return c.LLMAPIKey != "" || c.LLMBaseURL != ""
}

// Load resolves configuration from the environment, applying defaults.
func Load() (*Config, error) {
	cfg := &Config{
		ListenAddr:          env("LISTEN_ADDR", ":8080"),
		AuthMode:            strings.ToLower(env("AUTH_MODE", "github")),
		GitHubClientID:      os.Getenv("GITHUB_CLIENT_ID"),
		GitHubClientSecret:  os.Getenv("GITHUB_CLIENT_SECRET"),
		OAuthRedirectURL:    env("OAUTH_REDIRECT_URL", "http://localhost:8080/api/auth/callback"),
		ZitadelIssuer:       os.Getenv("ZITADEL_ISSUER"),
		ZitadelClientID:     os.Getenv("ZITADEL_CLIENT_ID"),
		ZitadelClientSecret: os.Getenv("ZITADEL_CLIENT_SECRET"),
		ZitadelRedirectURL:  env("ZITADEL_REDIRECT_URL", "http://localhost:8080/api/auth/callback"),
		ZitadelRequiredRole: os.Getenv("ZITADEL_REQUIRED_ROLE"),
		RepoOwner:           env("REPO_OWNER", "Smana"),
		RepoName:            env("REPO_NAME", "cloud-native-ref"),
		RepoBaseBranch:      env("REPO_BASE_BRANCH", "main"),
		XRDSource:           XRDSourceMode(strings.ToLower(env("XRD_SOURCE", string(SourceLocal)))),
		RepoRoot:            env("REPO_ROOT", defaultRepoRoot()),
		XRDPath:             env("XRD_PATH", "infrastructure/base/crossplane/configuration/app-definition.yaml"),
		UIHintsPath:         os.Getenv("UI_HINTS_PATH"),
		StacksPath:          env("STACKS_PATH", "apps/stacks.yaml"),
		CompositionPath:     env("COMPOSITION_PATH", "infrastructure/base/crossplane/configuration/app-composition.yaml"),
		FunctionsPath:       env("FUNCTIONS_PATH", "infrastructure/base/crossplane/configuration/functions.yaml"),
		EnvConfigPath:       env("ENVCONFIG_PATH", "infrastructure/base/crossplane/configuration/environmentconfig.yaml"),
		LLMAPIKey:           os.Getenv("LLM_API_KEY"),
		LLMBaseURL:          os.Getenv("LLM_BASE_URL"),
		LLMModel:            env("LLM_MODEL", "claude-opus-4-8"),
		FunctionsDevTargets: parseKVList(os.Getenv("FUNCTIONS_DEV_TARGETS")),
	}

	if cfg.XRDSource != SourceLocal && cfg.XRDSource != SourceGitHub {
		cfg.XRDSource = SourceLocal
	}

	if cfg.UIHintsPath == "" {
		cfg.UIHintsPath = filepath.Join(defaultSelfDir(), "ui-hints.yaml")
	}

	if key := os.Getenv("SESSION_KEY"); key != "" {
		cfg.SessionKey = []byte(key)
	} else {
		b := make([]byte, 32)
		if _, err := rand.Read(b); err != nil {
			return nil, err
		}
		cfg.SessionKey = []byte(hex.EncodeToString(b))
	}

	return cfg, nil
}

func env(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

// parseKVList parses "k=v,k=v" into a map. Empty/malformed entries are skipped.
// Returns nil for empty input so callers can test presence with len()>0.
func parseKVList(s string) map[string]string {
	s = strings.TrimSpace(s)
	if s == "" {
		return nil
	}
	out := map[string]string{}
	for _, pair := range strings.Split(s, ",") {
		k, v, ok := strings.Cut(strings.TrimSpace(pair), "=")
		k, v = strings.TrimSpace(k), strings.TrimSpace(v)
		if ok && k != "" && v != "" {
			out[k] = v
		}
	}
	if len(out) == 0 {
		return nil
	}
	return out
}

// defaultRepoRoot best-efforts the repo root for local dev: the current
// working directory. Overridable via REPO_ROOT.
func defaultRepoRoot() string {
	wd, err := os.Getwd()
	if err != nil {
		return "."
	}
	return wd
}

// defaultSelfDir returns the working directory; ui-hints.yaml lives beside the
// binary/source in container-images/app-wizard.
func defaultSelfDir() string {
	wd, err := os.Getwd()
	if err != nil {
		return "."
	}
	return wd
}
