package pr

import (
	"fmt"

	"sigs.k8s.io/yaml"
)

// AddResourceToKustomization performs an idempotent edit of a parent
// kustomization: it adds `entry` (e.g. "./myapp") to the resources list if
// absent, returning the updated YAML and whether a change was made. It
// preserves other fields by round-tripping through a generic map.
//
// When existing is nil/empty a fresh kustomization is created.
func AddResourceToKustomization(existing []byte, entry string) ([]byte, bool, error) {
	doc := map[string]any{}
	if len(existing) > 0 {
		if err := yaml.Unmarshal(existing, &doc); err != nil {
			return nil, false, fmt.Errorf("parse parent kustomization: %w", err)
		}
	}
	if doc["apiVersion"] == nil {
		doc["apiVersion"] = "kustomize.config.k8s.io/v1beta1"
	}
	if doc["kind"] == nil {
		doc["kind"] = "Kustomization"
	}

	var resources []any
	if r, ok := doc["resources"].([]any); ok {
		resources = r
	}
	for _, r := range resources {
		if s, ok := r.(string); ok && s == entry {
			// Already present — no change (idempotent).
			return existing, false, nil
		}
	}
	resources = append(resources, entry)
	doc["resources"] = resources

	out, err := yaml.Marshal(doc)
	if err != nil {
		return nil, false, fmt.Errorf("marshal parent kustomization: %w", err)
	}
	return out, true, nil
}
