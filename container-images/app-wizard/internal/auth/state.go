package auth

import (
	"crypto/rand"
	"encoding/base64"
)

// randomState generates a URL-safe random OAuth state token.
func randomState() (string, error) {
	b := make([]byte, 24)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return base64.RawURLEncoding.EncodeToString(b), nil
}
