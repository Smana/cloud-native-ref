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
func BuildClaimYAML(name, namespace string, spec map[string]any) ([]byte, error) {
	if spec == nil {
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
