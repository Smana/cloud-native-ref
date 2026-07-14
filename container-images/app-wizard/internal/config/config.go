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

	// GitHubClientID / GitHubClientSecret are the OAuth app credentials
	// (GITHUB_CLIENT_ID / GITHUB_CLIENT_SECRET).
	GitHubClientID     string
	GitHubClientSecret string
	// OAuthRedirectURL is the callback URL registered with the OAuth app
	// (OAUTH_REDIRECT_URL). Defaults to a localhost callback for dev.
	OAuthRedirectURL string

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
}

// Load resolves configuration from the environment, applying defaults.
func Load() (*Config, error) {
	cfg := &Config{
		ListenAddr:         env("LISTEN_ADDR", ":8080"),
		GitHubClientID:     os.Getenv("GITHUB_CLIENT_ID"),
		GitHubClientSecret: os.Getenv("GITHUB_CLIENT_SECRET"),
		OAuthRedirectURL:   env("OAUTH_REDIRECT_URL", "http://localhost:8080/api/auth/callback"),
		RepoOwner:          env("REPO_OWNER", "Smana"),
		RepoName:           env("REPO_NAME", "cloud-native-ref"),
		RepoBaseBranch:     env("REPO_BASE_BRANCH", "main"),
		XRDSource:          XRDSourceMode(strings.ToLower(env("XRD_SOURCE", string(SourceLocal)))),
		RepoRoot:           env("REPO_ROOT", defaultRepoRoot()),
		XRDPath:            env("XRD_PATH", "infrastructure/base/crossplane/configuration/app-definition.yaml"),
		UIHintsPath:        os.Getenv("UI_HINTS_PATH"),
		StacksPath:         env("STACKS_PATH", "apps/stacks.yaml"),
		CompositionPath:    env("COMPOSITION_PATH", "infrastructure/base/crossplane/configuration/app-composition.yaml"),
		FunctionsPath:      env("FUNCTIONS_PATH", "infrastructure/base/crossplane/configuration/functions.yaml"),
		EnvConfigPath:      env("ENVCONFIG_PATH", "infrastructure/base/crossplane/configuration/environmentconfig.yaml"),
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
