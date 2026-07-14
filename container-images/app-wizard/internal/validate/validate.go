package validate

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"strings"

	"github.com/Smana/cloud-native-ref/container-images/app-wizard/internal/api"
	"github.com/santhosh-tekuri/jsonschema/v6"
)

// SchemaProvider yields the JSON Schema and CEL rules for the App spec. The
// schema.Pipeline satisfies this.
type SchemaProvider interface {
	JSONSchema(ctx context.Context) (map[string]any, error)
	CELRules(ctx context.Context) ([]api.CELRule, error)
}

// Validator runs schema + CEL + secret gates against a candidate spec.
type Validator struct {
	provider SchemaProvider
}

// NewValidator builds a Validator over a schema provider.
func NewValidator(provider SchemaProvider) *Validator {
	return &Validator{provider: provider}
}

// Validate runs all gates and returns the aggregate result. It never errors on
// invalid input — invalidity is reported in the response.
func (v *Validator) Validate(ctx context.Context, spec map[string]any) (api.ValidateResponse, error) {
	resp := api.ValidateResponse{
		Valid:          true,
		SchemaErrors:   []api.FieldError{},
		CELViolations:  []api.CELRule{},
		SecretFindings: []api.SecretFinding{},
	}

	jsonSchema, err := v.provider.JSONSchema(ctx)
	if err != nil {
		return resp, fmt.Errorf("load schema: %w", err)
	}
	if errs := validateSchema(jsonSchema, spec); len(errs) > 0 {
		resp.SchemaErrors = errs
		resp.Valid = false
	}

	rules, err := v.provider.CELRules(ctx)
	if err != nil {
		return resp, fmt.Errorf("load CEL rules: %w", err)
	}
	evaluator, err := NewCELEvaluator(rules)
	if err != nil {
		return resp, fmt.Errorf("compile CEL: %w", err)
	}
	if viol := evaluator.Evaluate(spec); len(viol) > 0 {
		resp.CELViolations = viol
		resp.Valid = false
	}

	if findings := ScanSecrets(spec); len(findings) > 0 {
		resp.SecretFindings = findings // pragma: allowlist secret
		resp.Valid = false
	}

	return resp, nil
}

// validateSchema compiles the JSON Schema and validates spec against it,
// returning per-path field errors.
func validateSchema(jsonSchema map[string]any, spec map[string]any) []api.FieldError {
	compiler := jsonschema.NewCompiler()
	const url = "mem://app-spec-schema.json"
	if err := compiler.AddResource(url, jsonSchema); err != nil {
		return []api.FieldError{{Path: "spec", Message: "invalid schema: " + err.Error()}}
	}
	sch, err := compiler.Compile(url)
	if err != nil {
		return []api.FieldError{{Path: "spec", Message: "schema compile error: " + err.Error()}}
	}
	if err := sch.Validate(spec); err != nil {
		var ve *jsonschema.ValidationError
		if ok := asValidationError(err, &ve); ok {
			return flattenValidationError(ve)
		}
		return []api.FieldError{{Path: "spec", Message: err.Error()}}
	}
	return nil
}

func asValidationError(err error, target **jsonschema.ValidationError) bool {
	if ve, ok := err.(*jsonschema.ValidationError); ok {
		*target = ve
		return true
	}
	return false
}

// flattenValidationError turns the nested jsonschema error tree into flat
// leaf-level FieldErrors with JSON-pointer-ish paths.
func flattenValidationError(ve *jsonschema.ValidationError) []api.FieldError {
	var out []api.FieldError
	var walk func(e *jsonschema.ValidationError)
	walk = func(e *jsonschema.ValidationError) {
		if len(e.Causes) == 0 {
			out = append(out, api.FieldError{
				Path:    instancePath(e.InstanceLocation),
				Message: e.Error(),
			})
			return
		}
		for _, c := range e.Causes {
			walk(c)
		}
	}
	walk(ve)
	if len(out) == 0 {
		out = append(out, api.FieldError{Path: "spec", Message: ve.Error()})
	}
	return out
}

func instancePath(loc []string) string {
	if len(loc) == 0 {
		return "spec"
	}
	return "spec." + strings.Join(loc, ".")
}

// Handler serves POST /api/validate.
func (v *Validator) Handler() http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		var req api.ValidateRequest
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			writeJSONError(w, http.StatusBadRequest, "invalid request body: "+err.Error())
			return
		}
		if req.Spec == nil {
			req.Spec = map[string]any{}
		}
		resp, err := v.Validate(r.Context(), req.Spec)
		if err != nil {
			writeJSONError(w, http.StatusInternalServerError, err.Error())
			return
		}
		writeJSON(w, http.StatusOK, resp)
	}
}

func writeJSON(w http.ResponseWriter, status int, val any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(val)
}

func writeJSONError(w http.ResponseWriter, status int, msg string) {
	writeJSON(w, status, api.ErrorResponse{Error: msg})
}
