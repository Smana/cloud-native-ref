package appstore

import (
	"log/slog"
	"net/http"

	"github.com/Smana/cloud-native-ref/container-images/app-wizard/internal/api"
	"github.com/Smana/cloud-native-ref/container-images/app-wizard/internal/gitprovider"
	"github.com/Smana/cloud-native-ref/container-images/app-wizard/internal/httputil"
)

// ProviderForRequest yields the gitprovider for the authenticated user of a
// request, or an error when unauthenticated.
type ProviderForRequest func(r *http.Request) (gitprovider.Provider, error)

// ListHandler serves GET /api/apps. Unauthenticated requests get 401.
func (s *Store) ListHandler(providerFor ProviderForRequest, logger *slog.Logger) http.HandlerFunc {
	if logger == nil {
		logger = slog.Default()
	}
	return func(w http.ResponseWriter, r *http.Request) {
		provider, err := providerFor(r)
		if err != nil {
			httputil.WriteError(w, http.StatusUnauthorized, "not authenticated")
			return
		}
		apps, err := s.List(r.Context(), provider)
		if err != nil {
			logger.Error("app inventory failed", "err", err.Error())
			httputil.WriteError(w, http.StatusInternalServerError, err.Error())
			return
		}
		if apps == nil {
			apps = []api.AppSummary{}
		}
		httputil.WriteJSON(w, http.StatusOK, apps)
	}
}

// GetHandler serves GET /api/apps/{stack}/{name}. 404 when the app is absent.
func (s *Store) GetHandler(providerFor ProviderForRequest, logger *slog.Logger) http.HandlerFunc {
	if logger == nil {
		logger = slog.Default()
	}
	return func(w http.ResponseWriter, r *http.Request) {
		provider, err := providerFor(r)
		if err != nil {
			httputil.WriteError(w, http.StatusUnauthorized, "not authenticated")
			return
		}
		stack := r.PathValue("stack")
		name := r.PathValue("name")
		if stack == "" || name == "" {
			httputil.WriteError(w, http.StatusBadRequest, "stack and name are required")
			return
		}
		detail, err := s.Get(r.Context(), provider, stack, name)
		if err != nil {
			if err == gitprovider.ErrNotFound {
				httputil.WriteError(w, http.StatusNotFound, "app not found")
				return
			}
			logger.Error("load app failed", "stack", stack, "name", name, "err", err.Error())
			httputil.WriteError(w, http.StatusInternalServerError, err.Error())
			return
		}
		httputil.WriteJSON(w, http.StatusOK, detail)
	}
}
