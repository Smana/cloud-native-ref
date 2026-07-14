package pr

import (
	"fmt"

	"sigs.k8s.io/yaml"
)

const (
	appAPIVersion = "cloud.ogenki.io/v1alpha1"
	appKind       = "App"
)

// BuildClaimYAML assembles the App claim manifest from a request's parts. The
// metadata name is the app name; namespace comes from the stack registry.
// The spec is pruned (empty strings/arrays/objects/nulls removed) so the
// committed claim stays minimal — only values the user actually set, letting the
// composition/XRD supply the rest. Mirrors the frontend's live-pane prune.
func BuildClaimYAML(name, namespace string, spec map[string]any) ([]byte, error) {
	if pruned, ok := pruneSpec(spec); ok {
		spec = pruned.(map[string]any)
	} else {
		spec = map[string]any{}
	}
	claim := map[string]any{
		"apiVersion": appAPIVersion,
		"kind":       appKind,
		"metadata": map[string]any{
			"name":      name,
			"namespace": namespace,
		},
		"spec": spec,
	}
	b, err := yaml.Marshal(claim)
	if err != nil {
		return nil, fmt.Errorf("marshal claim: %w", err)
	}
	return b, nil
}

// pruneSpec recursively removes empty values (nil, "", empty slices/maps) so the
// committed claim carries only meaningful, user-set fields. Booleans and numbers
// (including false/0) are kept — they may be intentional. Returns the pruned
// value and whether to keep it.
func pruneSpec(v any) (any, bool) {
	switch t := v.(type) {
	case map[string]any:
		out := map[string]any{}
		for k, val := range t {
			if pv, keep := pruneSpec(val); keep {
				out[k] = pv
			}
		}
		return out, len(out) > 0
	case []any:
		arr := []any{}
		for _, val := range t {
			if pv, keep := pruneSpec(val); keep {
				arr = append(arr, pv)
			}
		}
		return arr, len(arr) > 0
	case string:
		return t, t != ""
	case nil:
		return nil, false
	default:
		return t, true
	}
}

// BuildKustomizationYAML generates the app-directory kustomization referencing
// app.yaml.
func BuildKustomizationYAML() ([]byte, error) {
	k := map[string]any{
		"apiVersion": "kustomize.config.k8s.io/v1beta1",
		"kind":       "Kustomization",
		"resources":  []any{"app.yaml"},
	}
	b, err := yaml.Marshal(k)
	if err != nil {
		return nil, fmt.Errorf("marshal kustomization: %w", err)
	}
	return b, nil
}
