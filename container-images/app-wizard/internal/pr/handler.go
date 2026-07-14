package pr

import (
	"encoding/json"
	"errors"
	"log/slog"
	"net/http"

	"github.com/Smana/cloud-native-ref/container-images/app-wizard/internal/api"
	"github.com/Smana/cloud-native-ref/container-images/app-wizard/internal/auth"
	"github.com/Smana/cloud-native-ref/container-images/app-wizard/internal/gitprovider"
)

// ProviderForRequest yields the gitprovider for the authenticated user of a
// request, or an error when unauthenticated.
type ProviderForRequest func(r *http.Request) (gitprovider.Provider, error)

// Handler serves POST /api/pr. Unauthenticated requests get 401; gate failures
// get 422 with the error; success returns api.PRResponse.
func (s *Service) Handler(providerFor ProviderForRequest, logger *slog.Logger) http.HandlerFunc {
	if logger == nil {
		logger = slog.Default()
	}
	return func(w http.ResponseWriter, r *http.Request) {
		provider, err := providerFor(r)
		if err != nil {
			// Zitadel mode: authenticated but no linked GitHub token yet — the user
			// must connect GitHub before a PR can be opened (CL-11). Signal with 428
			// Precondition Required + a link hint the UI can act on.
			if errors.Is(err, auth.ErrGitHubNotLinked) {
				// Location header carries the link URL; must be set before the body.
				w.Header().Set("Location", auth.GitHubLinkPath)
				writeJSON(w, http.StatusPreconditionRequired, api.ErrorResponse{
					Error: "Connect your GitHub account to open pull requests",
				})
				return
			}
			writeJSON(w, http.StatusUnauthorized, api.ErrorResponse{Error: "not authenticated"})
			return
		}

		var req api.PRRequest
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			writeJSON(w, http.StatusBadRequest, api.ErrorResponse{Error: "invalid request body: " + err.Error()})
			return
		}

		resp, err := s.Create(r.Context(), provider, req)
		if err != nil {
			if ge, ok := err.(*GateError); ok {
				logger.Info("pr gate blocked", "stack", req.Stack, "app", req.AppName, "reason", ge.Message)
				writeJSON(w, http.StatusUnprocessableEntity, gateErrorResponse(ge))
				return
			}
			logger.Error("pr creation failed", "stack", req.Stack, "app", req.AppName, "err", err.Error())
			writeJSON(w, http.StatusInternalServerError, api.ErrorResponse{Error: err.Error()})
			return
		}

		logger.Info("pr created", "stack", req.Stack, "app", req.AppName, "number", resp.Number)
		writeJSON(w, http.StatusCreated, resp)
	}
}

// gateErrorResponse builds the 422 body. When validation details exist it
// returns the ValidateResponse; otherwise a plain error envelope.
func gateErrorResponse(ge *GateError) any {
	if ge.Validate != nil {
		return ge.Validate
	}
	return api.ErrorResponse{Error: ge.Message}
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}
