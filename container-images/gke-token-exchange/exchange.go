package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
	"sync"
	"time"
)

// Refresh before real expiry so an in-flight request never carries a token that
// expires mid-call against the API server.
const safetyMargin = 5 * time.Minute

type entry struct {
	token  string
	expiry time.Time
}

// Exchanger swaps a ZITADEL id_token for a Google Workforce Identity Federation
// access token. It holds NO Google credentials: the exchange is authenticated by
// the user's own token.
type Exchanger struct {
	audience string
	client   *http.Client
	stsURL   string
	now      func() time.Time

	mu    sync.Mutex
	cache map[string]entry
}

func NewExchanger(audience string, c *http.Client) *Exchanger {
	return &Exchanger{
		audience: audience,
		client:   c,
		stsURL:   "https://sts.googleapis.com/v1/token",
		now:      time.Now,
		cache:    map[string]entry{},
	}
}

func (x *Exchanger) Exchange(ctx context.Context, idToken string) (string, error) {
	key := cacheKey(idToken)

	x.mu.Lock()
	if ent, ok := x.cache[key]; ok && x.now().Before(ent.expiry) {
		x.mu.Unlock()
		return ent.token, nil
	}
	x.mu.Unlock()

	tok, ttl, err := x.callSTS(ctx, idToken)
	if err != nil {
		return "", err
	}

	expiry := x.now().Add(ttl)
	if idExp, ok := jwtExpiry(idToken); ok && idExp.Before(expiry) {
		expiry = idExp
	}
	expiry = expiry.Add(-safetyMargin)

	if expiry.After(x.now()) {
		x.mu.Lock()
		x.cache[key] = entry{token: tok, expiry: expiry}
		x.mu.Unlock()
	}
	return tok, nil
}

func (x *Exchanger) callSTS(ctx context.Context, idToken string) (string, time.Duration, error) {
	body, err := json.Marshal(map[string]string{
		"grantType":          "urn:ietf:params:oauth:grant-type:token-exchange",
		"audience":           x.audience,
		"scope":              "https://www.googleapis.com/auth/cloud-platform",
		"requestedTokenType": "urn:ietf:params:oauth:token-type:access_token",
		"subjectToken":       idToken,
		"subjectTokenType":   "urn:ietf:params:oauth:token-type:id_token",
	})
	if err != nil {
		return "", 0, err
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, x.stsURL, bytes.NewReader(body))
	if err != nil {
		return "", 0, err
	}
	req.Header.Set("Content-Type", "application/json")

	resp, err := x.client.Do(req)
	if err != nil {
		return "", 0, err
	}
	defer resp.Body.Close()

	raw, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if err != nil {
		return "", 0, err
	}

	if resp.StatusCode != http.StatusOK {
		// Report the STS error CODE only. error_description can echo token
		// material, and this string reaches logs.
		var serr struct {
			Error string `json:"error"`
		}
		_ = json.Unmarshal(raw, &serr)
		if serr.Error == "" {
			serr.Error = "unknown"
		}
		return "", 0, fmt.Errorf("sts %d: %s", resp.StatusCode, serr.Error)
	}

	var out struct {
		AccessToken string `json:"access_token"`
		ExpiresIn   int    `json:"expires_in"`
	}
	if err := json.Unmarshal(raw, &out); err != nil {
		return "", 0, fmt.Errorf("sts response unparseable: %w", err)
	}
	if out.AccessToken == "" {
		return "", 0, fmt.Errorf("sts returned no access_token")
	}
	return out.AccessToken, time.Duration(out.ExpiresIn) * time.Second, nil
}

func cacheKey(tok string) string {
	sum := sha256.Sum256([]byte(tok))
	return hex.EncodeToString(sum[:])
}

// jwtExpiry reads `exp` WITHOUT verifying the signature. Verification is STS's
// job; this only bounds how long the exchanged token may be cached.
func jwtExpiry(tok string) (time.Time, bool) {
	parts := strings.Split(tok, ".")
	if len(parts) != 3 {
		return time.Time{}, false
	}
	payload, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil {
		return time.Time{}, false
	}
	var c struct {
		Exp int64 `json:"exp"`
	}
	if err := json.Unmarshal(payload, &c); err != nil || c.Exp == 0 {
		return time.Time{}, false
	}
	return time.Unix(c.Exp, 0), true
}
