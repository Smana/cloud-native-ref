// Package httputil provides small shared HTTP response helpers used across the
// app-wizard backend handlers, replacing the previously duplicated per-package
// writeJSON/writeError copies.
package httputil

import (
	"encoding/json"
	"net/http"

	"github.com/Smana/cloud-native-ref/container-images/app-wizard/internal/api"
)

// WriteJSON writes v as a JSON body with the given status code.
func WriteJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

// WriteError writes an api.ErrorResponse{Error: msg} with the given status code.
func WriteError(w http.ResponseWriter, status int, msg string) {
	WriteJSON(w, status, api.ErrorResponse{Error: msg})
}
