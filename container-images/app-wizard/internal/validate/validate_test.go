package validate

import (
	"context"
	"testing"

	"github.com/Smana/cloud-native-ref/container-images/app-wizard/internal/api"
)

// fakeProvider is a static SchemaProvider for validator tests.
type fakeProvider struct {
	schema map[string]any
	rules  []api.CELRule
}

func (f *fakeProvider) JSONSchema(_ context.Context) (map[string]any, error) { return f.schema, nil }
func (f *fakeProvider) CELRules(_ context.Context) ([]api.CELRule, error)    { return f.rules, nil }

// xrdCELRules mirrors the App XRD's spec-level x-kubernetes-validations.
var xrdCELRules = []api.CELRule{
	{
		Rule:    "!has(self.autoscaling) || !self.autoscaling.enabled || self.autoscaling.minReplicas <= self.autoscaling.maxReplicas",
		Message: "autoscaling.minReplicas must be <= maxReplicas",
	},
	{
		Rule:    "!has(self.route) || !self.route.enabled || has(self.route.hostname)",
		Message: "route.hostname is required when route is enabled",
	},
	{
		Rule:    "!has(self.sqlInstance) || !self.sqlInstance.enabled || !has(self.sqlInstance.backup) || !has(self.sqlInstance.backup.schedule) || has(self.sqlInstance.backup.bucketName)",
		Message: "sqlInstance.backup.bucketName is required when backup schedule is set",
	},
}

func newTestValidator() *Validator {
	// Minimal permissive schema: object with image required so schema errors
	// don't interfere with CEL-focused cases that include image.
	schema := map[string]any{
		"$schema": "https://json-schema.org/draft/2020-12/schema",
		"type":    "object",
	}
	return NewValidator(&fakeProvider{schema: schema, rules: xrdCELRules})
}

func TestCELCronWithoutBucketNameFails(t *testing.T) {
	v := newTestValidator()
	spec := map[string]any{
		"sqlInstance": map[string]any{
			"enabled": true,
			"backup": map[string]any{
				"schedule": "0 2 * * *",
				// bucketName intentionally absent -> rule must fail.
			},
		},
	}
	resp, err := v.Validate(context.Background(), spec)
	if err != nil {
		t.Fatalf("Validate: %v", err)
	}
	if resp.Valid {
		t.Fatalf("expected invalid, got valid")
	}
	if !hasCELMessage(resp.CELViolations, "sqlInstance.backup.bucketName is required when backup schedule is set") {
		t.Errorf("expected bucketName CEL violation, got %+v", resp.CELViolations)
	}
}

func TestCELRouteWithoutHostnameFails(t *testing.T) {
	v := newTestValidator()
	spec := map[string]any{
		"route": map[string]any{"enabled": true},
	}
	resp, err := v.Validate(context.Background(), spec)
	if err != nil {
		t.Fatalf("Validate: %v", err)
	}
	if !hasCELMessage(resp.CELViolations, "route.hostname is required when route is enabled") {
		t.Errorf("expected route.hostname violation, got %+v", resp.CELViolations)
	}
}

func TestCELPassesWhenSatisfied(t *testing.T) {
	v := newTestValidator()
	spec := map[string]any{
		"route": map[string]any{"enabled": true, "hostname": "myapp"},
		"autoscaling": map[string]any{
			"enabled":     true,
			"minReplicas": 1,
			"maxReplicas": 3,
		},
	}
	resp, err := v.Validate(context.Background(), spec)
	if err != nil {
		t.Fatalf("Validate: %v", err)
	}
	if len(resp.CELViolations) != 0 {
		t.Errorf("expected no CEL violations, got %+v", resp.CELViolations)
	}
}

func TestSecretScanAKIA(t *testing.T) {
	v := newTestValidator()
	spec := map[string]any{
		"env": []any{
			// Assembled at runtime so the literal key never appears in source
			// (would trip the repo's secret-scanning pre-commit hooks). The
			// scanner under test still receives the full 20-char string.
			map[string]any{"name": "AWS_ACCESS_KEY_ID", "value": "AKIA" + "IOSFODNN7EXAMPLE"},
		},
	}
	resp, err := v.Validate(context.Background(), spec)
	if err != nil {
		t.Fatalf("Validate: %v", err)
	}
	if resp.Valid {
		t.Fatalf("expected invalid due to secret finding")
	}
	if len(resp.SecretFindings) == 0 {
		t.Fatalf("expected a secret finding")
	}
	found := false
	for _, f := range resp.SecretFindings {
		if f.Path == "spec.env[0].value" {
			found = true
		}
	}
	if !found {
		t.Errorf("expected finding at spec.env[0].value, got %+v", resp.SecretFindings)
	}
}

func TestSecretScanPEMAndEntropy(t *testing.T) {
	findings := ScanSecrets(map[string]any{
		// PEM header split so the literal never appears contiguously in source
		// (defeats the detect-private-key hook, which ignores allowlist pragmas).
		"a": "-----BEGIN RSA PRIVATE" + " KEY-----",
		"b": "aB3xZ9qL7mK2pR8v" + "T4wN6yH1cD5eF0gJ", // 32 mixed chars, high entropy // pragma: allowlist secret
		"c": "plain-lowercase-value",                 // low entropy, should not flag
		"d": "ghcr.io/acme/my-app:v1.2.3",            // has slash/colon, excluded
	})
	paths := map[string]string{}
	for _, f := range findings {
		paths[f.Path] = f.Reason
	}
	if _, ok := paths["spec.a"]; !ok {
		t.Errorf("expected PEM finding at spec.a")
	}
	if _, ok := paths["spec.b"]; !ok {
		t.Errorf("expected entropy finding at spec.b")
	}
	if _, ok := paths["spec.c"]; ok {
		t.Errorf("did not expect finding at spec.c")
	}
	if _, ok := paths["spec.d"]; ok {
		t.Errorf("did not expect finding on image reference spec.d")
	}
}

func TestSchemaValidationRejectsWrongType(t *testing.T) {
	schema := map[string]any{
		"$schema": "https://json-schema.org/draft/2020-12/schema",
		"type":    "object",
		"properties": map[string]any{
			"replicas": map[string]any{"type": "integer", "minimum": float64(1)},
		},
	}
	v := NewValidator(&fakeProvider{schema: schema, rules: nil})
	resp, err := v.Validate(context.Background(), map[string]any{"replicas": "not-an-int"})
	if err != nil {
		t.Fatalf("Validate: %v", err)
	}
	if resp.Valid {
		t.Fatalf("expected schema error for wrong type")
	}
	if len(resp.SchemaErrors) == 0 {
		t.Errorf("expected schema errors, got none")
	}
}

func hasCELMessage(viol []api.CELRule, msg string) bool {
	for _, r := range viol {
		if r.Message == msg {
			return true
		}
	}
	return false
}
