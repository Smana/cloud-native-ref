package schema

import (
	"fmt"

	"github.com/Smana/cloud-native-ref/container-images/app-wizard/internal/api"
	"sigs.k8s.io/yaml"
)

// xrd is the minimal shape we parse out of the App XRD document.
type xrd struct {
	Spec struct {
		Versions []struct {
			Name   string `json:"name"`
			Schema struct {
				OpenAPIV3Schema map[string]any `json:"openAPIV3Schema"`
			} `json:"schema"`
		} `json:"versions"`
	} `json:"spec"`
}

// ConvertXRD parses the App XRD YAML and returns the JSON Schema (draft
// 2020-12) for its `spec` object plus the spec-level CEL rules. It uses the
// first served version's openAPIV3Schema (versions[0], per task scope).
//
// The conversion carries type/properties/enum/default/minimum/maximum/
// pattern/description/required/items/additionalProperties across, strips
// Kubernetes vendor extensions (x-kubernetes-*) from the JSON Schema output,
// and lifts x-kubernetes-validations into []api.CELRule.
func ConvertXRD(doc []byte) (jsonSchema map[string]any, celRules []api.CELRule, err error) {
	var x xrd
	if err := yaml.Unmarshal(doc, &x); err != nil {
		return nil, nil, fmt.Errorf("parse XRD: %w", err)
	}
	if len(x.Spec.Versions) == 0 {
		return nil, nil, fmt.Errorf("XRD has no versions")
	}
	root := x.Spec.Versions[0].Schema.OpenAPIV3Schema
	if root == nil {
		return nil, nil, fmt.Errorf("XRD version %q has no openAPIV3Schema", x.Spec.Versions[0].Name)
	}
	props, _ := root["properties"].(map[string]any)
	specNode, ok := props["spec"].(map[string]any)
	if !ok {
		return nil, nil, fmt.Errorf("XRD openAPIV3Schema has no spec property")
	}

	celRules = extractCEL(specNode)
	converted := convertNode(specNode)
	cm, _ := converted.(map[string]any)
	if cm == nil {
		cm = map[string]any{"type": "object"}
	}
	cm["$schema"] = "https://json-schema.org/draft/2020-12/schema"
	return cm, celRules, nil
}

// extractCEL reads x-kubernetes-validations from a schema node.
func extractCEL(node map[string]any) []api.CELRule {
	raw, ok := node["x-kubernetes-validations"].([]any)
	if !ok {
		return nil
	}
	rules := make([]api.CELRule, 0, len(raw))
	for _, r := range raw {
		m, ok := r.(map[string]any)
		if !ok {
			continue
		}
		rule, _ := m["rule"].(string)
		msg, _ := m["message"].(string)
		if rule != "" {
			rules = append(rules, api.CELRule{Rule: rule, Message: msg})
		}
	}
	return rules
}

// carried lists the OpenAPI keys that map 1:1 onto JSON Schema and are copied
// through verbatim (scalars/arrays; objects handled recursively below).
var carriedScalar = map[string]bool{
	"type":        true,
	"enum":        true,
	"default":     true,
	"minimum":     true,
	"maximum":     true,
	"pattern":     true,
	"description": true,
	"required":    true,
	"format":      true,
	"title":       true,
}

// convertNode recursively converts an OpenAPI v3 schema node into a JSON
// Schema node, stripping x-kubernetes-* extensions.
func convertNode(v any) any {
	switch n := v.(type) {
	case map[string]any:
		out := map[string]any{}
		for k, val := range n {
			switch {
			case k == "x-kubernetes-validations":
				// Lifted separately at the spec root; drop from output. Nested
				// validations are not surfaced in v1.
				continue
			case k == "x-kubernetes-preserve-unknown-fields":
				// Translate to permissive JSON Schema: allow any properties.
				if b, ok := val.(bool); ok && b {
					out["additionalProperties"] = true
				}
				continue
			case len(k) > 13 && k[:13] == "x-kubernetes-":
				continue
			case k == "properties":
				if pm, ok := val.(map[string]any); ok {
					np := map[string]any{}
					for pk, pv := range pm {
						np[pk] = convertNode(pv)
					}
					out["properties"] = np
				}
			case k == "items":
				out["items"] = convertNode(val)
			case k == "additionalProperties":
				switch av := val.(type) {
				case bool:
					out["additionalProperties"] = av
				case map[string]any:
					out["additionalProperties"] = convertNode(av)
				}
			case carriedScalar[k]:
				out[k] = val
			default:
				// Unknown key: carry through untouched (forward-compatible).
				out[k] = val
			}
		}
		return out
	case []any:
		arr := make([]any, len(n))
		for i, e := range n {
			arr[i] = convertNode(e)
		}
		return arr
	default:
		return v
	}
}
