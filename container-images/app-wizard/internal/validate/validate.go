package validate

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"strings"
	"sync"

	"github.com/Smana/cloud-native-ref/container-images/app-wizard/internal/api"
	"github.com/Smana/cloud-native-ref/container-images/app-wizard/internal/httputil"
	"github.com/santhosh-tekuri/jsonschema/v6"
)

// SchemaProvider yields the JSON Schema and CEL rules for the App spec, plus a
// cheap version key used to memoize the compiled artifacts. The schema.Pipeline
// satisfies this.
type SchemaProvider interface {
	JSONSchema(ctx context.Context) (map[string]any, error)
	CELRules(ctx context.Context) ([]api.CELRule, error)
	SchemaVersion(ctx context.Context) (string, error)
}

// Validator runs schema + CEL + secret gates against a candidate spec.
//
// The compiled JSON Schema and CEL evaluator are memoized (keyed by the
// provider's SchemaVersion) so repeated Validate calls — fired per keystroke
// from the form — reuse them instead of recompiling every time. Compiled
// *jsonschema.Schema and cel-go programs are safe for concurrent reuse.
type Validator struct {
	provider SchemaProvider

	mu           sync.Mutex
	cachedSHA    string
	cachedSchema *jsonschema.Schema
	cachedCEL    *CELEvaluator
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

	sch, evaluator, err := v.compiled(ctx)
	if err != nil {
		return resp, err
	}

	if errs := validateSchema(sch, spec); len(errs) > 0 {
		resp.SchemaErrors = errs
		resp.Valid = false
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

// compiled returns the compiled JSON Schema and CEL evaluator for the current
// schema version, recompiling (and caching) only when the version changed.
func (v *Validator) compiled(ctx context.Context) (*jsonschema.Schema, *CELEvaluator, error) {
	sha, err := v.provider.SchemaVersion(ctx)
	if err != nil {
		return nil, nil, fmt.Errorf("load schema version: %w", err)
	}

	v.mu.Lock()
	defer v.mu.Unlock()
	if sha != "" && sha == v.cachedSHA && v.cachedSchema != nil && v.cachedCEL != nil {
		return v.cachedSchema, v.cachedCEL, nil
	}

	jsonSchema, err := v.provider.JSONSchema(ctx)
	if err != nil {
		return nil, nil, fmt.Errorf("load schema: %w", err)
	}
	sch, err := compileSchema(jsonSchema)
	if err != nil {
		return nil, nil, err
	}

	rules, err := v.provider.CELRules(ctx)
	if err != nil {
		return nil, nil, fmt.Errorf("load CEL rules: %w", err)
	}
	evaluator, err := NewCELEvaluator(rules)
	if err != nil {
		return nil, nil, fmt.Errorf("compile CEL: %w", err)
	}

	v.cachedSHA = sha
	v.cachedSchema = sch
	v.cachedCEL = evaluator
	return sch, evaluator, nil
}

// compileSchema compiles the JSON Schema document into a reusable validator.
func compileSchema(jsonSchema map[string]any) (*jsonschema.Schema, error) {
	compiler := jsonschema.NewCompiler()
	const url = "mem://app-spec-schema.json"
	if err := compiler.AddResource(url, jsonSchema); err != nil {
		return nil, fmt.Errorf("invalid schema: %w", err)
	}
	sch, err := compiler.Compile(url)
	if err != nil {
		return nil, fmt.Errorf("schema compile error: %w", err)
	}
	return sch, nil
}

// validateSchema validates spec against the compiled schema, returning per-path
// field errors.
func validateSchema(sch *jsonschema.Schema, spec map[string]any) []api.FieldError {
	if err := sch.Validate(spec); err != nil {
		var ve *jsonschema.ValidationError
		if errors.As(err, &ve) {
			return flattenValidationError(ve)
		}
		return []api.FieldError{{Path: "spec", Message: err.Error()}}
	}
	return nil
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
			httputil.WriteError(w, http.StatusBadRequest, "invalid request body: "+err.Error())
			return
		}
		if req.Spec == nil {
			req.Spec = map[string]any{}
		}
		resp, err := v.Validate(r.Context(), req.Spec)
		if err != nil {
			httputil.WriteError(w, http.StatusInternalServerError, err.Error())
			return
		}
		httputil.WriteJSON(w, http.StatusOK, resp)
	}
}
