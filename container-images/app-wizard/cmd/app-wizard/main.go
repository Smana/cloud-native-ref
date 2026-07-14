// Command app-wizard serves the App Wizard SPA and its JSON API (SPEC-008
// Phase 1). It wires the schema pipeline, validation gates, secret scanning,
// GitHub OAuth, gitprovider, render preview, and the PR flow, then serves the
// embedded SPA for all non-/api paths.
package main

import (
	"context"
	"fmt"
	"io/fs"
	"log/slog"
	"net/http"
	"os"

	"github.com/Smana/cloud-native-ref/container-images/app-wizard/internal/auth"
	"github.com/Smana/cloud-native-ref/container-images/app-wizard/internal/config"
	"github.com/Smana/cloud-native-ref/container-images/app-wizard/internal/gitprovider"
	"github.com/Smana/cloud-native-ref/container-images/app-wizard/internal/pr"
	"github.com/Smana/cloud-native-ref/container-images/app-wizard/internal/render"
	"github.com/Smana/cloud-native-ref/container-images/app-wizard/internal/schema"
	"github.com/Smana/cloud-native-ref/container-images/app-wizard/internal/validate"
	"github.com/Smana/cloud-native-ref/container-images/app-wizard/internal/web"
)

func main() {
	// Subcommands. `generate` is the offline dry-run of the PR flow (produces
	// the claim + kustomization files locally, no GitHub/cluster). Bare invocation
	// runs the HTTP server.
	if len(os.Args) > 1 && os.Args[1] == "generate" {
		if err := runGenerate(os.Args[2:]); err != nil {
			fmt.Fprintln(os.Stderr, "error:", err)
			os.Exit(1)
		}
		return
	}

	logger := slog.New(slog.NewJSONHandler(os.Stdout, nil))
	slog.SetDefault(logger)

	cfg, err := config.Load()
	if err != nil {
		logger.Error("failed to load config", "err", err)
		os.Exit(1)
	}

	ctx := context.Background()

	// Schema source: local disk (dev/test) or GitHub (prod). The GitHub source
	// reads the XRD/stacks as the process's default identity via an anonymous
	// provider is not possible, so in github mode we read from the repo on disk
	// if present, else fall back to local. For simplicity v1 uses LocalSource
	// against REPO_ROOT; GitHub source is available for callers that inject a
	// provider (see internal/schema.NewGitHubSource).
	src := schema.SchemaSource(schema.NewLocalSource(cfg.RepoRoot))
	if cfg.XRDSource == config.SourceGitHub && cfg.GitHubClientID != "" {
		// Server-side reads require a token; when unavailable we keep LocalSource.
		logger.Info("XRD_SOURCE=github requested; using LocalSource for server-side reads (per-user tokens are request-scoped)")
	}

	pipeline := schema.NewPipeline(src, cfg.XRDPath, cfg.StacksPath, cfg.UIHintsPath)

	// Warm the cache / fail fast on a broken XRD.
	if _, err := pipeline.Build(ctx); err != nil {
		logger.Error("failed to build schema payload", "err", err)
		os.Exit(1)
	}

	validator := validate.NewValidator(pipeline)
	renderer := render.NewCrossplaneRenderer(cfg.RepoRoot, cfg.CompositionPath, cfg.FunctionsPath, cfg.EnvConfigPath)
	prService := pr.NewService(validator, renderer, pipeline, cfg.RepoBaseBranch)

	// Provider factory: build a GitHub gitprovider from a user token.
	factory := func(ctx context.Context, token string) gitprovider.Provider {
		return gitprovider.NewGitHub(ctx, token, cfg.RepoOwner, cfg.RepoName)
	}
	authCfg := auth.Config{
		ClientID:     cfg.GitHubClientID,
		ClientSecret: cfg.GitHubClientSecret,
		RedirectURL:  cfg.OAuthRedirectURL,
		SessionKey:   cfg.SessionKey,
		Factory:      factory,
		Logger:       logger,
	}
	if cfg.AuthMode == "dev" {
		logger.Warn("AUTH_MODE=dev — login bypassed, PRs written to the working tree; DO NOT use in a deployed environment")
		authCfg.DevProvider = gitprovider.NewLocalDryRun(cfg.RepoRoot)
	}
	authHandler := auth.New(authCfg)

	mux := http.NewServeMux()

	// Health endpoints (used by the App composition probes).
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("ok"))
	})
	mux.HandleFunc("GET /readyz", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("ok"))
	})

	// Schema / validation / render.
	mux.Handle("GET /api/schema", pipeline.Handler())
	mux.Handle("POST /api/validate", validator.Handler())
	mux.Handle("POST /api/render-preview", render.Handler(renderer, pipeline))

	// Auth.
	mux.HandleFunc("GET /api/auth/login", authHandler.Login)
	mux.HandleFunc("GET /api/auth/callback", authHandler.Callback)
	mux.HandleFunc("GET /api/me", authHandler.Me)
	mux.HandleFunc("POST /api/auth/logout", authHandler.Logout)

	// PR flow (authenticated).
	mux.Handle("POST /api/pr", prService.Handler(authHandler.ProviderForRequest, logger))

	// Serve the embedded SPA for everything else, with SPA fallback to index.html.
	spa, err := fs.Sub(web.Assets, "dist")
	if err != nil {
		logger.Error("failed to mount embedded UI", "err", err)
		os.Exit(1)
	}
	mux.Handle("/", web.SPAHandler(spa))

	logger.Info("app-wizard listening", "addr", cfg.ListenAddr, "repoRoot", cfg.RepoRoot, "xrdSource", cfg.XRDSource)
	srv := &http.Server{Addr: cfg.ListenAddr, Handler: mux}
	if err := srv.ListenAndServe(); err != nil {
		logger.Error("server exited", "err", err)
		os.Exit(1)
	}
}
