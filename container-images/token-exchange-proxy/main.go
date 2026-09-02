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
	"encoding/base64"
	"encoding/json"
	"fmt"
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
		// Sanitise first, before anything else reads or sets a header. A
		// client naming a header we depend on or are about to set --
		// Connection: X-Access-Token -- must not get a say in whether that
		// header survives the proxy hop.
		stripHopByHop(r.Header)

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
			// The subject token's own iss/aud/azp alongside the error. An
			// authorization server rejecting an exchange typically says only
			// `invalid_grant`, which is indistinguishable between a wrong
			// audience, an untrusted issuer, an expired token and a malformed
			// one -- while every component in the chain reports healthy. These
			// three claims separate those cases immediately, and none of them
			// is secret: they are configuration, not credential.
			log.Printf("token exchange failed: %v (subject %s)", err, subjectDiagnostics(subject))
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

		// NewSingleHostReverseProxy rewrites the outbound URL but leaves the
		// Host header as the client sent it. The dial target is pinned by
		// `upstream` regardless, so this is not SSRF, but an upstream that
		// does Host-based routing or auth should never see a client-chosen
		// value from a security-facing proxy.
		r.Host = upstream.Host
		proxy.ServeHTTP(w, r)
	})
	return mux
}

// stripHopByHop removes headers the CLIENT nominated as hop-by-hop, then the
// Connection header itself. RFC 7230 says a proxy must not forward these, and
// Go's ReverseProxy enforces that on the way out -- which means an
// unsanitised request lets a client name a header we are about to set
// (Connection: X-Access-Token) and have the freshly injected credential
// deleted for them. Sanitising on the way IN removes the client's control
// over that entirely.
func stripHopByHop(h http.Header) {
	for _, f := range h.Values("Connection") {
		for _, name := range strings.Split(f, ",") {
			if n := strings.TrimSpace(name); n != "" {
				h.Del(n)
			}
		}
	}
	h.Del("Connection")
}

// subjectDiagnostics renders the subject token's issuer, audience and authorised
// party for a log line. It NEVER returns token material: iss, aud and azp are
// configuration values, not credentials, and they are exactly what distinguishes
// an audience mismatch from an untrusted issuer when the authorization server
// will only say `invalid_grant`.
//
// The signature is not verified -- that is the authorization server's job, and
// this runs only where the server has already refused the token.
func subjectDiagnostics(tok string) string {
	parts := strings.Split(tok, ".")
	if len(parts) != 3 {
		return "not a JWT (opaque or malformed subject token)"
	}
	payload, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil {
		return "undecodable JWT payload"
	}
	var c struct {
		Iss string          `json:"iss"`
		Azp string          `json:"azp"`
		Aud json.RawMessage `json:"aud"`
	}
	if err := json.Unmarshal(payload, &c); err != nil {
		return "unparseable JWT claims"
	}
	return fmt.Sprintf("iss=%s azp=%s aud=%s", c.Iss, c.Azp, string(c.Aud))
}
