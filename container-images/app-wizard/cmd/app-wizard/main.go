// Command app-wizard serves the App Wizard SPA and its JSON API.
//
// This is the Phase 1 scaffold (SPEC-008). The backend implementation
// (schema pipeline, validation, gitprovider, PR flow, OAuth) fills the
// internal/* packages and replaces the stub handlers registered here.
package main

import (
	"encoding/json"
	"io/fs"
	"log/slog"
	"net/http"
	"os"

	"github.com/Smana/cloud-native-ref/container-images/app-wizard/internal/api"
	"github.com/Smana/cloud-native-ref/container-images/app-wizard/internal/web"
)

func main() {
	logger := slog.New(slog.NewJSONHandler(os.Stdout, nil))

	addr := os.Getenv("LISTEN_ADDR")
	if addr == "" {
		addr = ":8080"
	}

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

	// Stub /api/schema so the SPA has a live target before the schema pipeline
	// lands. Replaced by internal/schema in the backend implementation task.
	mux.HandleFunc("GET /api/schema", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, http.StatusOK, api.SchemaPayload{
			JSONSchema:    map[string]any{"type": "object", "properties": map[string]any{}},
			CELRules:      []api.CELRule{},
			Hints:         api.UIHints{Fields: map[string]api.FieldHint{}, Groups: []api.GroupHint{}},
			Stacks:        []api.Stack{},
			SchemaVersion: "scaffold",
		})
	})

	// Serve the embedded SPA for everything else, with SPA fallback to index.html.
	spa, err := fs.Sub(web.Assets, "dist")
	if err != nil {
		logger.Error("failed to mount embedded UI", "err", err)
		os.Exit(1)
	}
	mux.Handle("/", web.SPAHandler(spa))

	logger.Info("app-wizard listening", "addr", addr)
	srv := &http.Server{Addr: addr, Handler: mux}
	if err := srv.ListenAndServe(); err != nil {
		logger.Error("server exited", "err", err)
		os.Exit(1)
	}
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}
