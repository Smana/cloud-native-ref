// Production OIDC verifier backed by github.com/coreos/go-oidc. Constructing it
// performs live OIDC discovery against the issuer (fetches JWKS), so it is kept
// out of zitadel.go — the pure session/authz/link logic there is unit-tested
// against a fake IDTokenVerifier instead.
package auth

import (
	"context"
	"fmt"

	"github.com/coreos/go-oidc/v3/oidc"
)

// NewOIDCVerifier discovers the issuer and returns an IDTokenVerifier that
// checks the issuer and clientID audience on every ID token. The returned
// AuthEndpoint / TokenEndpoint come from discovery and feed the oauth2.Config.
func NewOIDCVerifier(ctx context.Context, issuer, clientID string) (v IDTokenVerifier, authEndpoint, tokenEndpoint string, err error) {
	provider, err := oidc.NewProvider(ctx, issuer)
	if err != nil {
		return nil, "", "", fmt.Errorf("oidc discovery for %q: %w", issuer, err)
	}
	verifier := provider.Verifier(&oidc.Config{ClientID: clientID})
	return &oidcVerifier{verifier: verifier}, provider.Endpoint().AuthURL, provider.Endpoint().TokenURL, nil
}

type oidcVerifier struct {
	verifier *oidc.IDTokenVerifier
}

// oidcRawClaims is the JSON shape we pull off a verified ID token. Zitadel emits
// project roles under the urn:zitadel:iam:org:project:roles claim as a map of
// roleName → {orgID: orgDomain}; we take the role names.
type oidcRawClaims struct {
	Subject           string                            `json:"sub"`
	Email             string                            `json:"email"`
	PreferredUsername string                            `json:"preferred_username"`
	Name              string                            `json:"name"`
	Picture           string                            `json:"picture"`
	ZitadelRoles      map[string]map[string]interface{} `json:"urn:zitadel:iam:org:project:roles"`
	// Groups is a fallback for deployments that surface authorization as groups.
	Groups []string `json:"groups"`
}

func (o *oidcVerifier) Verify(ctx context.Context, rawIDToken string) (ZitadelClaims, error) {
	idToken, err := o.verifier.Verify(ctx, rawIDToken)
	if err != nil {
		return ZitadelClaims{}, err
	}
	var raw oidcRawClaims
	if err := idToken.Claims(&raw); err != nil {
		return ZitadelClaims{}, fmt.Errorf("parse id_token claims: %w", err)
	}
	roles := make([]string, 0, len(raw.ZitadelRoles)+len(raw.Groups))
	for role := range raw.ZitadelRoles {
		roles = append(roles, role)
	}
	roles = append(roles, raw.Groups...)
	return ZitadelClaims{
		Subject:       raw.Subject,
		Email:         raw.Email,
		PreferredName: raw.PreferredUsername,
		Name:          raw.Name,
		AvatarURL:     raw.Picture,
		Roles:         roles,
	}, nil
}
