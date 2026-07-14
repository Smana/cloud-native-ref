// Package web embeds the built React SPA and serves it with SPA-fallback
// routing (unknown paths return index.html so client-side routing works).
package web

import (
	"embed"
	"io/fs"
	"net/http"
	"strings"
)

// Assets holds the built SPA. The Dockerfile builds ui/ into ui/dist and copies
// it here before `go build`. A committed placeholder keeps `go build` working
// during local backend development before the UI is built.
//
//go:embed all:dist
var Assets embed.FS

// SPAHandler serves static files from the given filesystem, falling back to
// index.html for any path that does not resolve to a file (client-side routes).
func SPAHandler(assets fs.FS) http.Handler {
	fileServer := http.FileServer(http.FS(assets))
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		p := strings.TrimPrefix(r.URL.Path, "/")
		if p == "" {
			p = "index.html"
		}
		if _, err := fs.Stat(assets, p); err != nil {
			// Not a real file → SPA route, serve index.html.
			r.URL.Path = "/"
		}
		fileServer.ServeHTTP(w, r)
	})
}
