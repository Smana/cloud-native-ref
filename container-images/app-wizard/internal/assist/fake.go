package assist

import "context"

// FakeAssist is a canned Assist for handler tests. It records the last call and
// returns configured values (or errors), without any network or API key.
type FakeAssist struct {
	AvailableVal bool

	PrefillSpec map[string]any
	PrefillErr  error

	Ingress     []any
	Egress      []any
	PoliciesErr error

	// LastDescription captures the description passed to the most recent call.
	LastDescription string
}

// Available returns the configured availability.
func (f *FakeAssist) Available() bool { return f.AvailableVal }

// Prefill returns the canned spec (or error).
func (f *FakeAssist) Prefill(_ context.Context, description string, _ map[string]any) (map[string]any, error) {
	f.LastDescription = description
	if f.PrefillErr != nil {
		return nil, f.PrefillErr
	}
	return f.PrefillSpec, nil
}

// SuggestPolicies returns the canned rules (or error).
func (f *FakeAssist) SuggestPolicies(_ context.Context, description string, _ map[string]any) ([]any, []any, error) {
	f.LastDescription = description
	if f.PoliciesErr != nil {
		return nil, nil, f.PoliciesErr
	}
	return f.Ingress, f.Egress, nil
}
