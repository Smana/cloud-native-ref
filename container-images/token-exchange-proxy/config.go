package main

import (
	"fmt"
	"os"
	"strings"
)

// Encoding selects how the exchange request is serialised. Providers disagree:
// RFC 8693 specifies application/x-www-form-urlencoded with snake_case
// parameters, while some hosted Security Token Services accept (or require) a
// JSON body with camelCase keys. Neither is universally accepted, so it is
// configuration rather than a default baked into the code.
type Encoding string

const (
	EncodingForm Encoding = "form"
	EncodingJSON Encoding = "json"
)

// Config describes ONE token exchange plus how the token enters and leaves the
// proxy. Nothing here is provider-specific; a deployment supplies the values.
type Config struct {
	// The RFC 8693 token endpoint.
	STSURL string

	// RFC 8693 request parameters.
	Audience           string
	Resource           string
	Scope              string
	SubjectTokenType   string
	RequestedTokenType string

	RequestEncoding Encoding

	// Where the subject token arrives. SubjectPrefix is stripped before use;
	// set it empty for a header carrying a bare token.
	SubjectHeader string
	SubjectPrefix string

	// Where the exchanged token is written before proxying upstream.
	InjectHeader string
	InjectPrefix string

	// Remove the subject header before forwarding, so the upstream never sees
	// the original credential.
	StripSubject bool

	UpstreamURL string
	ListenAddr  string
}

// Defaults follow RFC 8693 where the RFC is unambiguous. RequestEncoding
// defaults to JSON because that is the encoding this proxy has been verified
// against a live STS with; `form` is the RFC-specified alternative for
// providers that require it. An auth component should not default to a path
// nobody has exercised.
func LoadConfig() (Config, error) {
	c := Config{
		STSURL:             os.Getenv("TEP_STS_URL"),
		Audience:           os.Getenv("TEP_AUDIENCE"),
		Resource:           os.Getenv("TEP_RESOURCE"),
		Scope:              os.Getenv("TEP_SCOPE"),
		SubjectTokenType:   envOr("TEP_SUBJECT_TOKEN_TYPE", "urn:ietf:params:oauth:token-type:id_token"),
		RequestedTokenType: envOr("TEP_REQUESTED_TOKEN_TYPE", "urn:ietf:params:oauth:token-type:access_token"),
		RequestEncoding:    Encoding(envOr("TEP_REQUEST_ENCODING", string(EncodingJSON))),
		SubjectHeader:      envOr("TEP_SUBJECT_HEADER", "Authorization"),
		SubjectPrefix:      envOr("TEP_SUBJECT_PREFIX", "Bearer "),
		InjectHeader:       envOr("TEP_INJECT_HEADER", "Authorization"),
		InjectPrefix:       envOr("TEP_INJECT_PREFIX", "Bearer "),
		StripSubject:       envOr("TEP_STRIP_SUBJECT", "true") == "true",
		UpstreamURL:        os.Getenv("TEP_UPSTREAM_URL"),
		ListenAddr:         envOr("TEP_LISTEN_ADDR", ":8080"),
	}
	return c, c.Validate()
}

func (c Config) Validate() error {
	var missing []string
	if c.STSURL == "" {
		missing = append(missing, "TEP_STS_URL")
	}
	if c.UpstreamURL == "" {
		missing = append(missing, "TEP_UPSTREAM_URL")
	}
	if c.SubjectHeader == "" {
		missing = append(missing, "TEP_SUBJECT_HEADER")
	}
	if c.InjectHeader == "" {
		missing = append(missing, "TEP_INJECT_HEADER")
	}
	if len(missing) > 0 {
		return fmt.Errorf("missing required configuration: %s", strings.Join(missing, ", "))
	}
	switch c.RequestEncoding {
	case EncodingForm, EncodingJSON:
	default:
		return fmt.Errorf("TEP_REQUEST_ENCODING must be %q or %q, got %q",
			EncodingForm, EncodingJSON, c.RequestEncoding)
	}
	return nil
}

func envOr(k, d string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return d
}
