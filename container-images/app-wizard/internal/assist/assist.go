// Package assist implements the two bounded, optional LLM assists of the App
// Wizard (SPEC-008 Phase 3, FR-011, CL-4):
//
//   - Prefill: map a plain-language app description to a partial Crossplane App
//     .spec, constrained by the XRD-derived JSON Schema.
//   - SuggestPolicies: map a plain-language dependency description to candidate
//     CiliumNetworkPolicy ingress/egress rules matching the composition's
//     networkPolicies schema, encoding the Cilium authoring traps from
//     .claude/rules/cilium-network-policies.md.
//
// The LLM is an input accelerator, never an authority: output is constrained by
// the XRD-derived schema, badged in the UI, never auto-submitted, and always
// re-validated by the existing validation gates. Structured output is obtained
// via a single schema-constrained tool forced with tool_choice — the schema is
// derived from the live pipeline so it can never drift from the XRD.
package assist

import (
	"context"
	"errors"
)

// ErrNotConfigured is returned by the Disabled implementation and by handlers
// when assists are requested but no LLM backend is configured.
var ErrNotConfigured = errors.New("LLM assists are not configured")

// Assist is the backend interface both the Anthropic and Disabled/Fake
// implementations satisfy. Handlers depend only on this interface.
type Assist interface {
	// Available reports whether the backend can serve assist requests.
	Available() bool
	// Prefill maps a plain-language description to a partial App .spec. appSchema
	// is the XRD-derived JSON Schema for the App spec (from the pipeline); it is
	// used verbatim as the tool input_schema so the model output can never drift
	// from the XRD.
	Prefill(ctx context.Context, description string, appSchema map[string]any) (map[string]any, error)
	// SuggestPolicies maps a plain-language dependency description to candidate
	// CiliumNetworkPolicy ingress/egress rules. cnpSchema is the networkPolicies
	// subschema (with "ingress" and "egress" array schemas) used to build the
	// tool input_schema.
	SuggestPolicies(ctx context.Context, description string, cnpSchema map[string]any) (ingress, egress []any, err error)
}

// Disabled is the no-op backend used when no LLM is configured. It reports
// unavailable and errors on every call so the form degrades gracefully.
type Disabled struct{}

// Available always returns false.
func (Disabled) Available() bool { return false }

// Prefill always returns ErrNotConfigured.
func (Disabled) Prefill(context.Context, string, map[string]any) (map[string]any, error) {
	return nil, ErrNotConfigured
}

// SuggestPolicies always returns ErrNotConfigured.
func (Disabled) SuggestPolicies(context.Context, string, map[string]any) ([]any, []any, error) {
	return nil, nil, ErrNotConfigured
}
