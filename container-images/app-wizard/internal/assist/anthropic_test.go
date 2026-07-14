package assist

import (
	"context"
	"encoding/json"
	"testing"

	"github.com/Smana/cloud-native-ref/container-images/app-wizard/internal/api"
	"github.com/anthropics/anthropic-sdk-go"
	"github.com/anthropics/anthropic-sdk-go/option"
)

// stubMessages is a fake messagesClient that records the params and returns a
// canned tool-use response, so the schema-constrained wiring can be tested
// without a real API key or network.
type stubMessages struct {
	lastParams anthropic.MessageNewParams
	toolName   string
	toolInput  any
}

func (s *stubMessages) New(_ context.Context, params anthropic.MessageNewParams, _ ...option.RequestOption) (*anthropic.Message, error) {
	s.lastParams = params
	raw, _ := json.Marshal(s.toolInput)
	// Build a ToolUseBlock via JSON round-trip (its fields are unexported/typed).
	blockJSON := map[string]any{
		"type":  "tool_use",
		"id":    "toolu_test",
		"name":  s.toolName,
		"input": json.RawMessage(raw),
	}
	bj, _ := json.Marshal(blockJSON)
	var block anthropic.ContentBlockUnion
	if err := json.Unmarshal(bj, &block); err != nil {
		return nil, err
	}
	return &anthropic.Message{
		Content:    []anthropic.ContentBlockUnion{block},
		StopReason: anthropic.StopReasonToolUse,
	}, nil
}

func newTestAssist(stub *stubMessages) *AnthropicAssist {
	return &AnthropicAssist{client: stub, model: anthropic.ModelClaudeOpus4_8, available: true}
}

func TestPrefillParsesToolInputAndForcesTool(t *testing.T) {
	stub := &stubMessages{
		toolName:  prefillToolName,
		toolInput: map[string]any{"image": map[string]any{"repository": "ghcr.io/acme/api"}},
	}
	a := newTestAssist(stub)
	appSchema := map[string]any{
		"type":       "object",
		"properties": map[string]any{"image": map[string]any{"type": "object"}},
		"required":   []any{"image"},
	}
	spec, err := a.Prefill(context.Background(), "a web api", appSchema)
	if err != nil {
		t.Fatalf("Prefill: %v", err)
	}
	if _, ok := spec["image"]; !ok {
		t.Fatalf("spec missing image: %v", spec)
	}
	// tool_choice must force the prefill tool.
	if tc := stub.lastParams.ToolChoice.OfTool; tc == nil || tc.Name != prefillToolName {
		t.Fatalf("tool_choice not forced to %q: %+v", prefillToolName, stub.lastParams.ToolChoice)
	}
	// input_schema must carry the XRD-derived schema verbatim (drift-free):
	// "required" is carried through ExtraFields.
	if len(stub.lastParams.Tools) != 1 {
		t.Fatalf("want 1 tool, got %d", len(stub.lastParams.Tools))
	}
	if _, ok := stub.lastParams.Tools[0].OfTool.InputSchema.ExtraFields["required"]; !ok {
		t.Fatalf("input_schema lost 'required' constraint: %+v", stub.lastParams.Tools[0].OfTool.InputSchema)
	}
}

func TestSuggestPoliciesParsesIngressEgress(t *testing.T) {
	stub := &stubMessages{
		toolName: policiesToolName,
		toolInput: map[string]any{
			"ingress": []any{map[string]any{"fromEntities": []any{"cluster"}}},
			"egress":  []any{map[string]any{"toEntities": []any{"host"}}},
		},
	}
	a := newTestAssist(stub)
	cnp := map[string]any{
		"type": "object",
		"properties": map[string]any{
			"ingress": map[string]any{"type": "array"},
			"egress":  map[string]any{"type": "array"},
		},
	}
	ingress, egress, err := a.SuggestPolicies(context.Background(), "calls AWS", cnp)
	if err != nil {
		t.Fatalf("SuggestPolicies: %v", err)
	}
	if len(ingress) != 1 || len(egress) != 1 {
		t.Fatalf("ingress/egress = %d/%d, want 1/1", len(ingress), len(egress))
	}
	// The tool input_schema must be the {ingress, egress} object, not the raw
	// networkPolicies schema.
	props, _ := stub.lastParams.Tools[0].OfTool.InputSchema.Properties.(map[string]any)
	if _, ok := props["ingress"]; !ok {
		t.Fatalf("policies tool schema missing ingress: %+v", props)
	}
	if _, ok := props["egress"]; !ok {
		t.Fatalf("policies tool schema missing egress: %+v", props)
	}
}

// trimValidator marks specs invalid and reports a schema error on a given path,
// to exercise dropInvalidTopLevelKeys.
type trimValidator struct{ badPath string }

func (v trimValidator) Validate(context.Context, map[string]any) (api.ValidateResponse, error) {
	return api.ValidateResponse{
		Valid:        false,
		SchemaErrors: []api.FieldError{{Path: v.badPath, Message: "nope"}},
	}, nil
}

func TestDropInvalidTopLevelKeys(t *testing.T) {
	h := &Handlers{validator: trimValidator{badPath: "spec.bogus.field"}}
	spec := map[string]any{
		"image": map[string]any{"repository": "x"},
		"bogus": map[string]any{"field": 1},
	}
	got := h.dropInvalidTopLevelKeys(context.Background(), spec)
	if _, ok := got["bogus"]; ok {
		t.Fatalf("bogus key should have been dropped: %v", got)
	}
	if _, ok := got["image"]; !ok {
		t.Fatalf("image key should have been kept: %v", got)
	}
}
