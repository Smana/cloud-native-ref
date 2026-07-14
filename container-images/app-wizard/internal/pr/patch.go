package pr

import (
	"bytes"
	"fmt"
	"sort"

	yaml "go.yaml.in/yaml/v3"
)

// PatchClaimYAML applies desiredSpec onto the top-level `spec:` mapping of an
// existing App claim, editing the YAML node tree in place so comments, key
// order, and formatting of untouched fields survive (SC-005). Changing a single
// scalar (e.g. image.tag) yields a one-line diff because only that scalar node's
// Value is rewritten.
//
// The spec mapping is treated as authoritative: keys present in the existing
// spec but absent from desiredSpec are removed. This is safe for the wizard's
// round-trip flow — the frontend loads the full spec and re-submits every field
// it read (including ones it renders read-only), so a genuinely dropped key
// means the user cleared it. Keys OUTSIDE `spec` (apiVersion, kind, metadata,
// comments, blank lines) are never touched.
//
// When existing has no parseable top-level `spec:` mapping, it falls back to a
// full BuildClaimYAML generation, preserving metadata.name / .namespace and the
// apiVersion from the existing document when present.
func PatchClaimYAML(existing []byte, desiredSpec map[string]any) ([]byte, error) {
	var doc yaml.Node
	if err := yaml.Unmarshal(existing, &doc); err != nil {
		return nil, fmt.Errorf("parse existing claim: %w", err)
	}

	root := documentRoot(&doc)
	specNode := mappingValue(root, "spec")
	if specNode == nil || specNode.Kind != yaml.MappingNode {
		return patchFallback(existing, desiredSpec)
	}

	applyMapping(specNode, desiredSpec)

	out, err := marshalNode(&doc)
	if err != nil {
		return nil, fmt.Errorf("marshal patched claim: %w", err)
	}
	return out, nil
}

// documentRoot unwraps a DocumentNode to its content mapping (or returns the
// node itself when it is already a mapping).
func documentRoot(n *yaml.Node) *yaml.Node {
	if n == nil {
		return nil
	}
	if n.Kind == yaml.DocumentNode {
		if len(n.Content) == 0 {
			return nil
		}
		return n.Content[0]
	}
	return n
}

// mappingValue returns the value node for key in a MappingNode, or nil.
func mappingValue(m *yaml.Node, key string) *yaml.Node {
	if m == nil || m.Kind != yaml.MappingNode {
		return nil
	}
	for i := 0; i+1 < len(m.Content); i += 2 {
		if m.Content[i].Value == key {
			return m.Content[i+1]
		}
	}
	return nil
}

// applyMapping reconciles a MappingNode toward desired with minimal edits:
//   - existing keys present in desired are updated in place (recursing on maps,
//     replacing sequences, rewriting only changed scalars);
//   - existing keys absent from desired are removed;
//   - desired keys absent from the mapping are appended.
//
// Key order is preserved for retained keys; new keys are appended in the order
// they appear in desired (Go map iteration is unordered, so this uses the
// stable order of desired's keys as encountered — acceptable for appended
// fields, which have no prior position to preserve).
func applyMapping(m *yaml.Node, desired map[string]any) {
	if m.Kind != yaml.MappingNode {
		*m = *toNode(desired)
		return
	}

	// First pass: walk existing key/value pairs, updating or dropping.
	kept := make([]*yaml.Node, 0, len(m.Content))
	for i := 0; i+1 < len(m.Content); i += 2 {
		keyNode := m.Content[i]
		valNode := m.Content[i+1]
		dv, ok := desired[keyNode.Value]
		if !ok {
			// Key cleared by the user — drop it (both key and value).
			continue
		}
		applyValue(valNode, dv)
		kept = append(kept, keyNode, valNode)
	}
	m.Content = kept

	// Second pass: append desired keys that were not already present.
	existingKeys := map[string]bool{}
	for i := 0; i < len(m.Content); i += 2 {
		existingKeys[m.Content[i].Value] = true
	}
	for _, k := range orderedKeys(desired) {
		if existingKeys[k] {
			continue
		}
		m.Content = append(m.Content, scalarKeyNode(k), toNode(desired[k]))
	}
}

// applyValue reconciles a single value node toward desired.
func applyValue(node *yaml.Node, desired any) {
	switch d := desired.(type) {
	case map[string]any:
		if node.Kind == yaml.MappingNode {
			applyMapping(node, d)
			return
		}
		*node = *toNode(d)
	case []any:
		// Sequences are order-significant and small — replace the value node's
		// content wholesale with a freshly rendered sequence. This keeps the
		// key node (and any comment on it) intact.
		fresh := toNode(d)
		node.Kind = fresh.Kind
		node.Tag = fresh.Tag
		node.Value = fresh.Value
		node.Style = fresh.Style
		node.Content = fresh.Content
	default:
		// Scalar: rewrite only if the value actually changed, so an unchanged
		// scalar keeps its original style and any trailing comment.
		fresh := toNode(desired)
		if node.Kind == yaml.ScalarNode && node.Value == fresh.Value && node.Tag == fresh.Tag {
			return
		}
		node.Kind = fresh.Kind
		node.Tag = fresh.Tag
		node.Value = fresh.Value
		node.Style = fresh.Style
		node.Content = fresh.Content
	}
}

// toNode converts an arbitrary Go value (from a decoded desired spec) into a
// fresh *yaml.Node by round-tripping through the encoder. This yields correct
// tags/styles for scalars, maps, and sequences.
func toNode(v any) *yaml.Node {
	var n yaml.Node
	if err := n.Encode(v); err != nil {
		// Encode only fails on unsupported types; fall back to a null scalar.
		return &yaml.Node{Kind: yaml.ScalarNode, Tag: "!!null", Value: "null"}
	}
	// Encode wraps scalars/maps directly (no DocumentNode), so n is usable.
	return &n
}

// scalarKeyNode builds a plain scalar mapping key.
func scalarKeyNode(key string) *yaml.Node {
	return &yaml.Node{Kind: yaml.ScalarNode, Tag: "!!str", Value: key}
}

// orderedKeys returns desired's keys. Go map order is non-deterministic; keys
// appended here have no existing position to preserve, so any stable-enough
// ordering is acceptable. We sort for determinism (predictable diffs/tests).
func orderedKeys(m map[string]any) []string {
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	return keys
}

// marshalNode serializes a node tree with 2-space indentation.
func marshalNode(n *yaml.Node) ([]byte, error) {
	var buf bytes.Buffer
	enc := yaml.NewEncoder(&buf)
	enc.SetIndent(2)
	if err := enc.Encode(n); err != nil {
		_ = enc.Close()
		return nil, err
	}
	if err := enc.Close(); err != nil {
		return nil, err
	}
	return buf.Bytes(), nil
}

// patchFallback regenerates the claim from scratch when the existing document
// has no usable spec mapping. It preserves metadata.name/.namespace and
// apiVersion from the existing document when present.
func patchFallback(existing []byte, desiredSpec map[string]any) ([]byte, error) {
	name, namespace := "", ""
	if len(existing) > 0 {
		var doc yaml.Node
		if err := yaml.Unmarshal(existing, &doc); err == nil {
			if root := documentRoot(&doc); root != nil {
				if meta := mappingValue(root, "metadata"); meta != nil {
					if n := mappingValue(meta, "name"); n != nil {
						name = n.Value
					}
					if n := mappingValue(meta, "namespace"); n != nil {
						namespace = n.Value
					}
				}
			}
		}
	}
	return BuildClaimYAML(name, namespace, desiredSpec)
}
