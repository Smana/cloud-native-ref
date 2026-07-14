package render

import (
	"context"
	"encoding/json"
	"net/http"

	"github.com/Smana/cloud-native-ref/container-images/app-wizard/internal/api"
	"github.com/Smana/cloud-native-ref/container-images/app-wizard/internal/httputil"
	"sigs.k8s.io/yaml"
)

// StackResolver resolves a stack name to its registry entry (for namespace).
type StackResolver interface {
	Stack(ctx context.Context, name string) (api.Stack, bool, error)
}

// Handler serves POST /api/render-preview. It builds a claim from the request
// and returns the rendered resources; render failures return ok=false with the
// error rather than an HTTP error (FR-008).
func Handler(r Renderer, stacks StackResolver) http.HandlerFunc {
	return func(w http.ResponseWriter, req *http.Request) {
		var body api.RenderPreviewRequest
		if err := json.NewDecoder(req.Body).Decode(&body); err != nil {
			httputil.WriteError(w, http.StatusBadRequest, "invalid request body: "+err.Error())
			return
		}

		namespace := ""
		if body.Stack != "" {
			s, ok, err := stacks.Stack(req.Context(), body.Stack)
			if err != nil {
				httputil.WriteError(w, http.StatusInternalServerError, err.Error())
				return
			}
			if !ok {
				httputil.WriteJSON(w, http.StatusOK, api.RenderPreviewResponse{OK: false, Error: "unknown stack " + body.Stack})
				return
			}
			namespace = s.Namespace
		}

		claimYAML, err := buildClaim(body.Name, namespace, body.Spec)
		if err != nil {
			httputil.WriteError(w, http.StatusInternalServerError, err.Error())
			return
		}

		resources, err := r.Render(req.Context(), claimYAML)
		if err != nil {
			httputil.WriteJSON(w, http.StatusOK, api.RenderPreviewResponse{OK: false, Error: err.Error()})
			return
		}
		httputil.WriteJSON(w, http.StatusOK, api.RenderPreviewResponse{OK: true, Resources: resources})
	}
}

func buildClaim(name, namespace string, spec map[string]any) ([]byte, error) {
	if spec == nil {
		spec = map[string]any{}
	}
	meta := map[string]any{"name": name}
	if namespace != "" {
		meta["namespace"] = namespace
	}
	claim := map[string]any{
		"apiVersion": "cloud.ogenki.io/v1alpha1",
		"kind":       "App",
		"metadata":   meta,
		"spec":       spec,
	}
	return yaml.Marshal(claim)
}
