package assist

import (
	"context"
	"encoding/json"
	"errors"
	"log/slog"
	"net/http"
	"sort"

	"github.com/Smana/cloud-native-ref/container-images/app-wizard/internal/api"
	"github.com/Smana/cloud-native-ref/container-images/app-wizard/internal/httputil"
)

// schemaProvider yields the App JSON Schema and the networkPolicies subschema.
// The schema.Pipeline satisfies JSONSchema; the subschema is derived from it.
type schemaProvider interface {
	JSONSchema(ctx context.Context) (map[string]any, error)
}

// specValidator re-validates the model's prefill output through the existing
// gates. The validate.Validator satisfies this.
type specValidator interface {
	Validate(ctx context.Context, spec map[string]any) (api.ValidateResponse, error)
}

// Handlers serves the /api/assist/* endpoints. It holds the assist backend, the
// schema provider (for the tool input_schema), and the validator (to
// re-validate prefill output). Assists do not need the git provider.
type Handlers struct {
	assist    Assist
	schema    schemaProvider
	validator specValidator
	logger    *slog.Logger
}

// NewHandlers builds the assist HTTP handlers.
func NewHandlers(a Assist, schema schemaProvider, validator specValidator, logger *slog.Logger) *Handlers {
	if logger == nil {
		logger = slog.Default()
	}
	return &Handlers{assist: a, schema: schema, validator: validator, logger: logger}
}

// Status serves GET /api/assist/status.
func (h *Handlers) Status(w http.ResponseWriter, _ *http.Request) {
	httputil.WriteJSON(w, http.StatusOK, api.AssistStatus{Available: h.assist.Available()})
}

// Prefill serves POST /api/assist/prefill. It asks the model for a partial
// spec, drops any top-level keys that fail schema validation (so the result
// stays useful), and returns the spec plus the sorted top-level keys the model
// set. Disabled backend -> 503; runtime LLM failure -> 502 (FR-011).
func (h *Handlers) Prefill(w http.ResponseWriter, r *http.Request) {
	if !h.assist.Available() {
		httputil.WriteError(w, http.StatusServiceUnavailable, "LLM assists are not configured")
		return
	}
	var req api.AssistPrefillRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		httputil.WriteError(w, http.StatusBadRequest, "invalid request body: "+err.Error())
		return
	}

	appSchema, err := h.schema.JSONSchema(r.Context())
	if err != nil {
		h.logger.Error("assist prefill: load schema", "err", err)
		httputil.WriteError(w, http.StatusInternalServerError, "failed to load schema")
		return
	}

	spec, err := h.assist.Prefill(r.Context(), req.Description, appSchema)
	if err != nil {
		h.handleAssistError(w, "prefill", err)
		return
	}
	if spec == nil {
		spec = map[string]any{}
	}

	// Best-effort: drop top-level keys whose subtree fails schema validation so
	// the frontend gets a directly-usable partial spec. The frontend re-validates
	// regardless; this only trims obviously-invalid suggestions.
	spec = h.dropInvalidTopLevelKeys(r.Context(), spec)

	keys := make([]string, 0, len(spec))
	for k := range spec {
		keys = append(keys, k)
	}
	sort.Strings(keys)

	httputil.WriteJSON(w, http.StatusOK, api.AssistPrefillResponse{Spec: spec, Keys: keys})
}

// Policies serves POST /api/assist/policies. Disabled -> 503; runtime failure
// -> 502.
func (h *Handlers) Policies(w http.ResponseWriter, r *http.Request) {
	if !h.assist.Available() {
		httputil.WriteError(w, http.StatusServiceUnavailable, "LLM assists are not configured")
		return
	}
	var req api.AssistPoliciesRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		httputil.WriteError(w, http.StatusBadRequest, "invalid request body: "+err.Error())
		return
	}

	cnpSchema, err := h.networkPoliciesSchema(r.Context())
	if err != nil {
		h.logger.Error("assist policies: load schema", "err", err)
		httputil.WriteError(w, http.StatusInternalServerError, "failed to load network policy schema")
		return
	}

	ingress, egress, err := h.assist.SuggestPolicies(r.Context(), req.Description, cnpSchema)
	if err != nil {
		h.handleAssistError(w, "policies", err)
		return
	}
	if ingress == nil {
		ingress = []any{}
	}
	if egress == nil {
		egress = []any{}
	}
	httputil.WriteJSON(w, http.StatusOK, api.AssistPoliciesResponse{Ingress: ingress, Egress: egress})
}

// networkPoliciesSchema extracts spec.properties.networkPolicies from the
// App JSON Schema.
func (h *Handlers) networkPoliciesSchema(ctx context.Context) (map[string]any, error) {
	appSchema, err := h.schema.JSONSchema(ctx)
	if err != nil {
		return nil, err
	}
	props, ok := appSchema["properties"].(map[string]any)
	if !ok {
		return nil, errors.New("schema has no properties")
	}
	np, ok := props["networkPolicies"].(map[string]any)
	if !ok {
		return nil, errors.New("schema has no networkPolicies subschema")
	}
	return np, nil
}

// dropInvalidTopLevelKeys removes top-level keys of spec whose removal makes the
// spec valid, so obviously-broken suggestions don't reach the form. It never
// errors: on any validator failure it returns spec unchanged.
func (h *Handlers) dropInvalidTopLevelKeys(ctx context.Context, spec map[string]any) map[string]any {
	if h.validator == nil || len(spec) == 0 {
		return spec
	}
	resp, err := h.validator.Validate(ctx, spec)
	if err != nil || resp.Valid {
		return spec
	}

	// Collect the top-level keys implicated by schema errors (paths like
	// "spec.<key>...") and try dropping them.
	bad := map[string]struct{}{}
	for _, fe := range resp.SchemaErrors {
		if k := topLevelKey(fe.Path); k != "" {
			bad[k] = struct{}{}
		}
	}
	if len(bad) == 0 {
		return spec
	}
	trimmed := map[string]any{}
	for k, v := range spec {
		if _, drop := bad[k]; !drop {
			trimmed[k] = v
		}
	}
	return trimmed
}

// topLevelKey extracts the first segment after "spec." from a validation path
// (e.g. "spec.image.repository" -> "image"). Returns "" for the bare "spec".
func topLevelKey(path string) string {
	const prefix = "spec."
	if len(path) <= len(prefix) || path[:len(prefix)] != prefix {
		return ""
	}
	rest := path[len(prefix):]
	for i := 0; i < len(rest); i++ {
		if rest[i] == '.' || rest[i] == '[' {
			return rest[:i]
		}
	}
	return rest
}

// handleAssistError maps a backend error to an HTTP response: not-configured ->
// 503, anything else -> 502 with a friendly message (graceful degradation,
// FR-011). The underlying error is logged, never returned to the client.
func (h *Handlers) handleAssistError(w http.ResponseWriter, op string, err error) {
	if errors.Is(err, ErrNotConfigured) {
		httputil.WriteError(w, http.StatusServiceUnavailable, "LLM assists are not configured")
		return
	}
	h.logger.Error("assist request failed", "op", op, "err", err)
	httputil.WriteError(w, http.StatusBadGateway, "the assist service is temporarily unavailable; you can fill the form manually")
}
