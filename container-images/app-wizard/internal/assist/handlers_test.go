package assist

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"reflect"
	"testing"

	"github.com/Smana/cloud-native-ref/container-images/app-wizard/internal/api"
)

// fakeSchema is a static schemaProvider for handler tests. It returns a minimal
// App schema whose networkPolicies subschema has ingress/egress array schemas.
type fakeSchema struct{}

func (fakeSchema) JSONSchema(context.Context) (map[string]any, error) {
	return map[string]any{
		"type": "object",
		"properties": map[string]any{
			"image": map[string]any{
				"type": "object",
				"properties": map[string]any{
					"repository": map[string]any{"type": "string"},
				},
			},
			"networkPolicies": map[string]any{
				"type": "object",
				"properties": map[string]any{
					"ingress": map[string]any{"type": "array", "items": map[string]any{"type": "object"}},
					"egress":  map[string]any{"type": "array", "items": map[string]any{"type": "object"}},
				},
			},
		},
	}, nil
}

// passValidator marks every spec valid (no trimming in prefill).
type passValidator struct{}

func (passValidator) Validate(context.Context, map[string]any) (api.ValidateResponse, error) {
	return api.ValidateResponse{Valid: true}, nil
}

func doJSON(t *testing.T, h http.HandlerFunc, method, path string, body any) *httptest.ResponseRecorder {
	t.Helper()
	var r io.Reader
	if body != nil {
		b, err := json.Marshal(body)
		if err != nil {
			t.Fatalf("marshal body: %v", err)
		}
		r = bytes.NewReader(b)
	}
	req := httptest.NewRequest(method, path, r)
	rec := httptest.NewRecorder()
	h(rec, req)
	return rec
}

func TestStatusAvailable(t *testing.T) {
	h := NewHandlers(&FakeAssist{AvailableVal: true}, fakeSchema{}, passValidator{}, nil)
	rec := doJSON(t, h.Status, http.MethodGet, "/api/assist/status", nil)
	if rec.Code != http.StatusOK {
		t.Fatalf("status code = %d, want 200", rec.Code)
	}
	var got api.AssistStatus
	if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if !got.Available {
		t.Fatalf("Available = false, want true")
	}
}

func TestStatusUnavailable(t *testing.T) {
	h := NewHandlers(Disabled{}, fakeSchema{}, passValidator{}, nil)
	rec := doJSON(t, h.Status, http.MethodGet, "/api/assist/status", nil)
	if rec.Code != http.StatusOK {
		t.Fatalf("status code = %d, want 200", rec.Code)
	}
	var got api.AssistStatus
	if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if got.Available {
		t.Fatalf("Available = true, want false")
	}
}

func TestPrefillReturnsSpecAndKeys(t *testing.T) {
	fake := &FakeAssist{
		AvailableVal: true,
		PrefillSpec: map[string]any{
			"image": map[string]any{"repository": "ghcr.io/acme/api"},
			"type":  "web",
		},
	}
	h := NewHandlers(fake, fakeSchema{}, passValidator{}, nil)
	rec := doJSON(t, h.Prefill, http.MethodPost, "/api/assist/prefill",
		api.AssistPrefillRequest{Description: "a web api"})
	if rec.Code != http.StatusOK {
		t.Fatalf("status code = %d, want 200 (body: %s)", rec.Code, rec.Body.String())
	}
	var got api.AssistPrefillResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if _, ok := got.Spec["image"]; !ok {
		t.Fatalf("Spec missing image: %v", got.Spec)
	}
	wantKeys := []string{"image", "type"} // sorted
	if !reflect.DeepEqual(got.Keys, wantKeys) {
		t.Fatalf("Keys = %v, want %v", got.Keys, wantKeys)
	}
	if fake.LastDescription != "a web api" {
		t.Fatalf("description not passed through: %q", fake.LastDescription)
	}
}

func TestPrefillDisabledReturns503(t *testing.T) {
	h := NewHandlers(Disabled{}, fakeSchema{}, passValidator{}, nil)
	rec := doJSON(t, h.Prefill, http.MethodPost, "/api/assist/prefill",
		api.AssistPrefillRequest{Description: "x"})
	if rec.Code != http.StatusServiceUnavailable {
		t.Fatalf("status code = %d, want 503", rec.Code)
	}
	var got api.ErrorResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if got.Error == "" {
		t.Fatalf("expected error message")
	}
}

func TestPrefillRuntimeErrorReturns502(t *testing.T) {
	fake := &FakeAssist{AvailableVal: true, PrefillErr: errors.New("boom")}
	h := NewHandlers(fake, fakeSchema{}, passValidator{}, nil)
	rec := doJSON(t, h.Prefill, http.MethodPost, "/api/assist/prefill",
		api.AssistPrefillRequest{Description: "x"})
	if rec.Code != http.StatusBadGateway {
		t.Fatalf("status code = %d, want 502 (body: %s)", rec.Code, rec.Body.String())
	}
}

func TestPoliciesReturnsRules(t *testing.T) {
	fake := &FakeAssist{
		AvailableVal: true,
		Ingress:      []any{map[string]any{"fromEntities": []any{"cluster"}}},
		Egress: []any{
			map[string]any{"toEntities": []any{"host"}},
		},
	}
	h := NewHandlers(fake, fakeSchema{}, passValidator{}, nil)
	rec := doJSON(t, h.Policies, http.MethodPost, "/api/assist/policies",
		api.AssistPoliciesRequest{Description: "talks to AWS S3"})
	if rec.Code != http.StatusOK {
		t.Fatalf("status code = %d, want 200 (body: %s)", rec.Code, rec.Body.String())
	}
	var got api.AssistPoliciesResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if len(got.Ingress) != 1 || len(got.Egress) != 1 {
		t.Fatalf("ingress/egress = %d/%d, want 1/1", len(got.Ingress), len(got.Egress))
	}
}

func TestPoliciesDisabledReturns503(t *testing.T) {
	h := NewHandlers(Disabled{}, fakeSchema{}, passValidator{}, nil)
	rec := doJSON(t, h.Policies, http.MethodPost, "/api/assist/policies",
		api.AssistPoliciesRequest{Description: "x"})
	if rec.Code != http.StatusServiceUnavailable {
		t.Fatalf("status code = %d, want 503", rec.Code)
	}
}
