// token-exchange-proxy sits between an authenticating reverse proxy and an
// upstream API server. It performs an RFC 8693 token exchange, swapping the
// subject token the reverse proxy attaches for a token the upstream server
// accepts, then forwards the request.
//
// It holds no credentials of its own: each exchange is authenticated by the
// caller's own subject token. Configuration is entirely environment-driven --
// see config.go -- so this file carries no coupling to any particular
// identity provider or upstream application.
package main

import (
	"log"
	"net/http"
	"net/http/httputil"
	"net/url"
	"strings"
	"time"
)

func main() {
	cfg, err := LoadConfig()
	if err != nil {
		log.Fatalf("configuration error: %v", err)
	}

	upstream, err := url.Parse(cfg.UpstreamURL)
	if err != nil {
		log.Fatalf("TEP_UPSTREAM_URL is not a URL: %v", err)
	}

	srv := &http.Server{
		Addr:              cfg.ListenAddr,
		Handler:           newHandler(NewExchanger(cfg, http.DefaultClient), cfg, upstream),
		ReadHeaderTimeout: 10 * time.Second,
	}
	log.Printf("listening on %s, upstream %s", cfg.ListenAddr, upstream)
	log.Fatal(srv.ListenAndServe())
}

// newHandler wires the exchange into an HTTP handler. Every field that
// governs its behaviour comes from cfg: which header carries the subject
// token, which prefix to strip from it, which header to inject the exchanged
// token into, and whether the original subject header survives the proxy
// hop.
func newHandler(ex *Exchanger, cfg Config, upstream *url.URL) http.Handler {
	proxy := httputil.NewSingleHostReverseProxy(upstream)

	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusOK)
	})
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		raw := r.Header.Get(cfg.SubjectHeader)
		if !strings.HasPrefix(raw, cfg.SubjectPrefix) {
			http.Error(w, "missing or malformed subject token", http.StatusUnauthorized)
			return
		}
		subject := raw[len(cfg.SubjectPrefix):]
		if subject == "" {
			http.Error(w, "missing or malformed subject token", http.StatusUnauthorized)
			return
		}

		tok, err := ex.Exchange(r.Context(), subject)
		if err != nil {
			// Deliberately NOT a pass-through. Without a token the upstream
			// would be reached carrying whatever ambient credentials it falls
			// back to -- the shared-identity behaviour this proxy exists to
			// remove -- as a silent, invisible regression.
			log.Printf("token exchange failed: %v", err)
			http.Error(w, "token exchange failed", http.StatusBadGateway)
			return
		}

		// Delete before inject: when SubjectHeader and InjectHeader are the
		// same name (the common case -- both default to Authorization), the
		// inject below must be the last write, or it would clobber the
		// exchanged token it just set.
		if cfg.StripSubject {
			r.Header.Del(cfg.SubjectHeader)
		}
		r.Header.Set(cfg.InjectHeader, cfg.InjectPrefix+tok)
		proxy.ServeHTTP(w, r)
	})
	return mux
}
