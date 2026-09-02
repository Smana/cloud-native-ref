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
	"net/url"
	"strings"
	"sync"
	"time"
)

// Refresh before real expiry so an in-flight request never carries a token that
// expires mid-call against the upstream API.
const safetyMargin = 5 * time.Minute

type entry struct {
	token  string
	expiry time.Time
}

// Exchanger swaps a subject token for an RFC 8693 access token via the
// configured token endpoint. It holds no credentials of its own: each
// exchange is authenticated by the caller's own subject token.
type Exchanger struct {
	cfg    Config
	client *http.Client
	now    func() time.Time

	mu    sync.Mutex
	cache map[string]entry
}

func NewExchanger(cfg Config, c *http.Client) *Exchanger {
	return &Exchanger{cfg: cfg, client: c, now: time.Now, cache: map[string]entry{}}
}

func (x *Exchanger) Exchange(ctx context.Context, subjectToken string) (string, error) {
	key := cacheKey(subjectToken)

	x.mu.Lock()
	if ent, ok := x.cache[key]; ok && x.now().Before(ent.expiry) {
		x.mu.Unlock()
		return ent.token, nil
	}
	x.mu.Unlock()

	// Concurrent requests for the same COLD token each call the token endpoint.
	// Deliberate: singleflight lives in golang.org/x/sync and this module is
	// stdlib-only by constraint, hand-rolled in-flight dedup adds real
	// concurrency risk to a security-path component, and the cost is bounded --
	// one burst per token per cache period per caller, far inside a token
	// endpoint's quota for a handful of operators.

	tok, ttl, err := x.callSTS(ctx, subjectToken)
	if err != nil {
		return "", err
	}

	expiry := x.now().Add(ttl)
	subExp, ok := jwtExpiry(subjectToken)
	if !ok {
		// Cannot bound this entry by the subject token's own lifetime, so do not
		// cache it at all. Caching on the exchanged token's TTL alone would let
		// it outlive the subject token that authorised it -- the single property
		// this cache exists to preserve.
		return tok, nil
	}
	if subExp.Before(expiry) {
		expiry = subExp
	}
	expiry = expiry.Add(-safetyMargin)

	if expiry.After(x.now()) {
		x.mu.Lock()
		x.evictExpiredLocked()
		x.cache[key] = entry{token: tok, expiry: expiry}
		x.mu.Unlock()
	}
	return tok, nil
}

func (x *Exchanger) callSTS(ctx context.Context, subjectToken string) (string, time.Duration, error) {
	req, err := x.buildRequest(ctx, subjectToken)
	if err != nil {
		return "", 0, err
	}

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
		// Report the error CODE only. error_description can echo token material
		// and this string reaches logs.
		var serr struct {
			Error string `json:"error"`
		}
		_ = json.Unmarshal(raw, &serr)
		if serr.Error == "" {
			serr.Error = "unknown"
		}
		return "", 0, fmt.Errorf("token exchange %d: %s", resp.StatusCode, serr.Error)
	}

	// RFC 8693 section 2.2.1: the response is JSON for both request encodings.
	var out struct {
		AccessToken string `json:"access_token"`
		ExpiresIn   int    `json:"expires_in"`
	}
	if err := json.Unmarshal(raw, &out); err != nil {
		return "", 0, fmt.Errorf("token exchange response unparseable: %w", err)
	}
	if out.AccessToken == "" {
		return "", 0, fmt.Errorf("token exchange returned no access_token")
	}
	return out.AccessToken, time.Duration(out.ExpiresIn) * time.Second, nil
}

const grantTypeTokenExchange = "urn:ietf:params:oauth:grant-type:token-exchange"

func (x *Exchanger) buildRequest(ctx context.Context, subjectToken string) (*http.Request, error) {
	if x.cfg.RequestEncoding == EncodingForm {
		// RFC 8693 section 2.1: form-encoded, snake_case.
		v := url.Values{}
		v.Set("grant_type", grantTypeTokenExchange)
		v.Set("subject_token", subjectToken)
		v.Set("subject_token_type", x.cfg.SubjectTokenType)
		v.Set("requested_token_type", x.cfg.RequestedTokenType)
		setIfNotEmpty(v, "audience", x.cfg.Audience)
		setIfNotEmpty(v, "resource", x.cfg.Resource)
		setIfNotEmpty(v, "scope", x.cfg.Scope)

		req, err := http.NewRequestWithContext(ctx, http.MethodPost, x.cfg.STSURL,
			strings.NewReader(v.Encode()))
		if err != nil {
			return nil, err
		}
		req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
		return req, nil
	}

	// JSON body with camelCase keys, as some hosted STS implementations expect.
	body := map[string]string{
		"grantType":          grantTypeTokenExchange,
		"subjectToken":       subjectToken,
		"subjectTokenType":   x.cfg.SubjectTokenType,
		"requestedTokenType": x.cfg.RequestedTokenType,
	}
	putIfNotEmpty(body, "audience", x.cfg.Audience)
	putIfNotEmpty(body, "resource", x.cfg.Resource)
	putIfNotEmpty(body, "scope", x.cfg.Scope)

	enc, err := json.Marshal(body)
	if err != nil {
		return nil, err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, x.cfg.STSURL, bytes.NewReader(enc))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/json")
	return req, nil
}

func setIfNotEmpty(v url.Values, k, val string) {
	if val != "" {
		v.Set(k, val)
	}
}

func putIfNotEmpty(m map[string]string, k, val string) {
	if val != "" {
		m[k] = val
	}
}

// evictExpiredLocked drops entries whose expiry has passed. Caller must hold x.mu.
//
// It runs under the same lock that gates cache HITS, so a sweep briefly stalls
// unrelated lookups too. That is fine while the number of LIVE entries stays
// small: map iteration is tens of nanoseconds per entry, so a thousand entries
// costs well under a millisecond. Note the key is the token, not the user, so
// entries accumulate with token ROTATION as well as with headcount. If live
// entries ever reach the tens of thousands, move the sweep off the request path
// (a ticker) or switch to sync.RWMutex so hits proceed during one.
// Called on WRITE, which happens once per token rather than once per request, so
// the O(n) sweep is cheap and keeps the map bounded by the number of LIVE tokens
// instead of every token ever seen.
func (x *Exchanger) evictExpiredLocked() {
	now := x.now()
	for k, ent := range x.cache {
		if !now.Before(ent.expiry) {
			delete(x.cache, k)
		}
	}
}

func cacheKey(tok string) string {
	sum := sha256.Sum256([]byte(tok))
	return hex.EncodeToString(sum[:])
}

// decodeJWTPayload returns a JWT's claims segment WITHOUT verifying the
// signature. Verification belongs to the authorization server; this exists only
// so the proxy can read two things it needs locally -- how long a result may be
// cached, and what to say when an exchange is refused.
//
// Shared rather than duplicated: both callers previously carried the same
// split/base64/unmarshal boilerplate and had already drifted in how they
// reported a malformed token.
func decodeJWTPayload(tok string) (map[string]json.RawMessage, error) {
	parts := strings.Split(tok, ".")
	if len(parts) != 3 {
		return nil, fmt.Errorf("not a JWT")
	}
	payload, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil {
		return nil, fmt.Errorf("undecodable payload")
	}
	var claims map[string]json.RawMessage
	if err := json.Unmarshal(payload, &claims); err != nil {
		return nil, fmt.Errorf("unparseable claims")
	}
	return claims, nil
}

// jwtExpiry reads `exp`. Used only to bound how long an exchanged token may be
// cached, never to decide whether the subject token is acceptable.
func jwtExpiry(tok string) (time.Time, bool) {
	claims, err := decodeJWTPayload(tok)
	if err != nil {
		return time.Time{}, false
	}
	raw, ok := claims["exp"]
	if !ok {
		return time.Time{}, false
	}
	var exp int64
	if err := json.Unmarshal(raw, &exp); err != nil || exp == 0 {
		return time.Time{}, false
	}
	return time.Unix(exp, 0), true
}
