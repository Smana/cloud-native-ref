package pr

import (
	"strings"
	"testing"

	"sigs.k8s.io/yaml"
)

// TestPatchClaimYAMLMinimalDiff is the SC-005 fidelity check: changing one
// scalar (image.tag) must leave comments and unmanaged-looking fields intact and
// produce a one-line diff.
func TestPatchClaimYAMLMinimalDiff(t *testing.T) {
	existing := []byte(`apiVersion: cloud.ogenki.io/v1alpha1
kind: App
metadata:
  name: myapp
  namespace: apps-team-a
spec:
  # the container image to deploy
  image:
    repository: ghcr.io/acme/myapp
    tag: "1.0" # bump me on release
  # a field the form cannot render but must survive
  customThing: keep
`)

	// Desired spec round-trips every field the form loaded, changing only the tag.
	desired := map[string]any{
		"image": map[string]any{
			"repository": "ghcr.io/acme/myapp",
			"tag":        "2.0",
		},
		"customThing": "keep",
	}

	out, err := PatchClaimYAML(existing, desired)
	if err != nil {
		t.Fatalf("PatchClaimYAML: %v", err)
	}
	got := string(out)

	// The changed value is present, the old one gone.
	if !strings.Contains(got, `tag: "2.0"`) {
		t.Errorf("expected updated tag, got:\n%s", got)
	}
	if strings.Contains(got, `tag: "1.0"`) {
		t.Errorf("old tag still present, got:\n%s", got)
	}

	// Comments survive.
	if !strings.Contains(got, "# the container image to deploy") {
		t.Errorf("head comment lost, got:\n%s", got)
	}
	if !strings.Contains(got, "# bump me on release") {
		t.Errorf("inline comment on tag lost, got:\n%s", got)
	}
	if !strings.Contains(got, "# a field the form cannot render but must survive") {
		t.Errorf("comment on customThing lost, got:\n%s", got)
	}

	// The unmanaged field survives.
	if !strings.Contains(got, "customThing: keep") {
		t.Errorf("customThing dropped, got:\n%s", got)
	}

	// Line-level diff: exactly one line differs from the original.
	changed := diffLines(string(existing), got)
	if changed != 1 {
		t.Errorf("expected a 1-line diff, got %d changed lines:\nBEFORE:\n%s\nAFTER:\n%s", changed, existing, got)
	}
}

func TestPatchClaimYAMLRemovesClearedKey(t *testing.T) {
	existing := []byte(`spec:
  image:
    repository: ghcr.io/acme/myapp
    tag: "1.0"
  replicas: 3
`)
	// User cleared replicas (absent from desired).
	desired := map[string]any{
		"image": map[string]any{
			"repository": "ghcr.io/acme/myapp",
			"tag":        "1.0",
		},
	}
	out, err := PatchClaimYAML(existing, desired)
	if err != nil {
		t.Fatalf("PatchClaimYAML: %v", err)
	}
	if strings.Contains(string(out), "replicas") {
		t.Errorf("cleared key 'replicas' should be removed, got:\n%s", out)
	}
}

func TestPatchClaimYAMLAppendsNewKey(t *testing.T) {
	existing := []byte(`spec:
  image:
    repository: ghcr.io/acme/myapp
    tag: "1.0"
`)
	desired := map[string]any{
		"image": map[string]any{
			"repository": "ghcr.io/acme/myapp",
			"tag":        "1.0",
		},
		"replicas": 2,
	}
	out, err := PatchClaimYAML(existing, desired)
	if err != nil {
		t.Fatalf("PatchClaimYAML: %v", err)
	}
	var claim map[string]any
	if err := yaml.Unmarshal(out, &claim); err != nil {
		t.Fatalf("parse: %v", err)
	}
	spec := claim["spec"].(map[string]any)
	if spec["replicas"] == nil {
		t.Errorf("new key 'replicas' not appended, got:\n%s", out)
	}
}

func TestPatchClaimYAMLFallbackNoSpec(t *testing.T) {
	// A document with no spec mapping falls back to full generation, keeping
	// metadata name/namespace.
	existing := []byte(`apiVersion: cloud.ogenki.io/v1alpha1
kind: App
metadata:
  name: myapp
  namespace: apps-team-a
`)
	desired := map[string]any{
		"image": map[string]any{"repository": "ghcr.io/acme/myapp", "tag": "1.0"},
	}
	out, err := PatchClaimYAML(existing, desired)
	if err != nil {
		t.Fatalf("PatchClaimYAML: %v", err)
	}
	var claim map[string]any
	if err := yaml.Unmarshal(out, &claim); err != nil {
		t.Fatalf("parse: %v", err)
	}
	meta := claim["metadata"].(map[string]any)
	if meta["name"] != "myapp" || meta["namespace"] != "apps-team-a" {
		t.Errorf("fallback lost metadata: %v", meta)
	}
	spec := claim["spec"].(map[string]any)
	if spec["image"] == nil {
		t.Errorf("fallback lost spec: %v", spec)
	}
}

// diffLines counts how many lines differ (positionally) between a and b.
func diffLines(a, b string) int {
	al := strings.Split(strings.TrimRight(a, "\n"), "\n")
	bl := strings.Split(strings.TrimRight(b, "\n"), "\n")
	n := len(al)
	if len(bl) > n {
		n = len(bl)
	}
	changed := 0
	for i := 0; i < n; i++ {
		var la, lb string
		if i < len(al) {
			la = al[i]
		}
		if i < len(bl) {
			lb = bl[i]
		}
		if la != lb {
			changed++
		}
	}
	return changed
}
