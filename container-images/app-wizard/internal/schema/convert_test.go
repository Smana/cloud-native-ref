package schema

import (
	"context"
	"os"
	"path/filepath"
	"testing"
)

// repoRoot walks up from the test file until it finds the app-definition XRD,
// so schema tests run offline against the checked-in XRD.
func repoRoot(t *testing.T) string {
	t.Helper()
	if r := os.Getenv("REPO_ROOT"); r != "" {
		return r
	}
	dir, err := os.Getwd()
	if err != nil {
		t.Fatalf("getwd: %v", err)
	}
	for i := 0; i < 10; i++ {
		candidate := filepath.Join(dir, "infrastructure", "base", "crossplane", "configuration", "app-definition.yaml")
		if _, err := os.Stat(candidate); err == nil {
			return dir
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			break
		}
		dir = parent
	}
	t.Skip("repo root with app-definition.yaml not found; set REPO_ROOT to run this test")
	return ""
}

const xrdPath = "infrastructure/base/crossplane/configuration/app-definition.yaml"

func loadXRD(t *testing.T) []byte {
	t.Helper()
	root := repoRoot(t)
	b, err := os.ReadFile(filepath.Join(root, filepath.FromSlash(xrdPath)))
	if err != nil {
		t.Fatalf("read XRD: %v", err)
	}
	return b
}

func TestConvertXRD(t *testing.T) {
	doc := loadXRD(t)
	js, cel, err := ConvertXRD(doc)
	if err != nil {
		t.Fatalf("ConvertXRD: %v", err)
	}

	tests := []struct {
		name  string
		check func(t *testing.T)
	}{
		{"root is object", func(t *testing.T) {
			if js["type"] != "object" {
				t.Errorf("root type = %v, want object", js["type"])
			}
		}},
		{"draft 2020-12 declared", func(t *testing.T) {
			if js["$schema"] != "https://json-schema.org/draft/2020-12/schema" {
				t.Errorf("$schema = %v", js["$schema"])
			}
		}},
		{"required carried", func(t *testing.T) {
			req, ok := js["required"].([]any)
			if !ok {
				t.Fatalf("required missing or wrong type: %T", js["required"])
			}
			if !containsStr(req, "image") {
				t.Errorf("required = %v, want to contain image", req)
			}
		}},
		{"enum carried (image.pullPolicy)", func(t *testing.T) {
			node := propAt(t, js, "image", "pullPolicy")
			enum, ok := node["enum"].([]any)
			if !ok || len(enum) != 3 {
				t.Fatalf("pullPolicy enum = %v", node["enum"])
			}
			if !containsStr(enum, "IfNotPresent") {
				t.Errorf("enum missing IfNotPresent: %v", enum)
			}
		}},
		{"default carried (image.tag)", func(t *testing.T) {
			node := propAt(t, js, "image", "tag")
			if node["default"] != "latest" {
				t.Errorf("image.tag default = %v, want latest", node["default"])
			}
		}},
		{"minimum/maximum carried (autoscaling.targetCPU)", func(t *testing.T) {
			node := propAt(t, js, "autoscaling", "targetCPUUtilizationPercentage")
			if node["minimum"] == nil || node["maximum"] == nil {
				t.Errorf("min/max missing: %v", node)
			}
		}},
		{"pattern carried (resources.requests.cpu)", func(t *testing.T) {
			node := propAt(t, js, "resources", "requests", "cpu")
			if node["pattern"] == nil {
				t.Errorf("pattern missing on resources.requests.cpu")
			}
		}},
		{"x-kubernetes-validations stripped from output", func(t *testing.T) {
			if _, ok := js["x-kubernetes-validations"]; ok {
				t.Errorf("x-kubernetes-validations leaked into JSON Schema")
			}
		}},
		{"CEL rules extracted", func(t *testing.T) {
			// Assert known rules are present (not an exact count — the XRD gains
			// rules over time, e.g. SPEC-007 workload-type validations).
			if len(cel) < 3 {
				t.Fatalf("got %d CEL rules, want at least 3", len(cel))
			}
			found := false
			for _, r := range cel {
				if r.Message == "route.hostname is required when route is enabled" {
					found = true
				}
				if r.Rule == "" || r.Message == "" {
					t.Errorf("empty rule/message: %+v", r)
				}
			}
			if !found {
				t.Errorf("expected route.hostname CEL rule not found")
			}
		}},
	}
	for _, tc := range tests {
		t.Run(tc.name, tc.check)
	}
}

func TestConvertXRDErrors(t *testing.T) {
	if _, _, err := ConvertXRD([]byte("not: [valid")); err == nil {
		t.Errorf("expected error on invalid YAML")
	}
	if _, _, err := ConvertXRD([]byte("spec: {}")); err == nil {
		t.Errorf("expected error on XRD without versions")
	}
}

func TestPipelineBuildAndCache(t *testing.T) {
	root := repoRoot(t)
	src := NewLocalSource(root)
	p := NewPipeline(src, xrdPath, "apps/stacks.yaml", filepath.Join(root, "container-images/app-wizard/ui-hints.yaml"))

	payload, err := p.Build(context.Background())
	if err != nil {
		t.Fatalf("Build: %v", err)
	}
	if payload.SchemaVersion == "" {
		t.Errorf("SchemaVersion empty")
	}
	if len(payload.CELRules) < 3 {
		t.Errorf("CELRules = %d, want at least 3", len(payload.CELRules))
	}
	if len(payload.Hints.Fields) == 0 {
		t.Errorf("hints not loaded")
	}
	// Stacks tolerate absence (may be empty).
	if payload.Stacks == nil {
		t.Errorf("Stacks should be non-nil slice")
	}

	// Second build hits the cache and returns the identical pointer.
	payload2, err := p.Build(context.Background())
	if err != nil {
		t.Fatalf("Build 2: %v", err)
	}
	if payload != payload2 {
		t.Errorf("expected cached payload pointer")
	}
}

// helpers

func propAt(t *testing.T, root map[string]any, path ...string) map[string]any {
	t.Helper()
	cur := root
	for _, seg := range path {
		props, ok := cur["properties"].(map[string]any)
		if !ok {
			t.Fatalf("no properties at %v", path)
		}
		next, ok := props[seg].(map[string]any)
		if !ok {
			t.Fatalf("no property %q in path %v", seg, path)
		}
		cur = next
	}
	return cur
}

func containsStr(arr []any, want string) bool {
	for _, e := range arr {
		if s, ok := e.(string); ok && s == want {
			return true
		}
	}
	return false
}
