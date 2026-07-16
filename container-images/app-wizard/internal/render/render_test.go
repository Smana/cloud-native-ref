package render

import (
	"strings"
	"testing"

	"sigs.k8s.io/yaml"
)

func TestParseRenderStream(t *testing.T) {
	stream := []byte(`---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: xplane-myapp
spec:
  replicas: 1
---
apiVersion: v1
kind: Service
metadata:
  name: xplane-myapp
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: xplane-myapp
`)
	got, err := ParseRenderStream(stream)
	if err != nil {
		t.Fatalf("ParseRenderStream: %v", err)
	}
	if len(got) != 3 {
		t.Fatalf("got %d resources, want 3: %+v", len(got), got)
	}
	if got[0].Kind != "Deployment" || got[0].Name != "xplane-myapp" {
		t.Errorf("first = %+v", got[0])
	}
	if got[0].Role == "" {
		t.Errorf("Deployment should have a role description")
	}
	if got[2].Kind != "HTTPRoute" {
		t.Errorf("third = %+v", got[2])
	}
}

func TestParseRenderStreamSkipsEmpty(t *testing.T) {
	got, err := ParseRenderStream([]byte("\n\n---\n\n"))
	if err != nil {
		t.Fatalf("err: %v", err)
	}
	if len(got) != 0 {
		t.Errorf("expected 0 resources, got %+v", got)
	}
}

func TestDevFunctionsYAML(t *testing.T) {
	functions := []byte(`---
apiVersion: pkg.crossplane.io/v1
kind: Function
metadata:
  name: function-kcl
spec:
  package: xpkg.upbound.io/crossplane-contrib/function-kcl:v0.12.1
---
apiVersion: pkg.crossplane.io/v1
kind: Function
metadata:
  name: function-auto-ready
spec:
  package: xpkg.crossplane.io/crossplane-contrib/function-auto-ready:v0.7.0
`)
	targets := map[string]string{
		"function-kcl":        "localhost:9443",
		"function-auto-ready": "localhost:9444",
	}
	out, err := DevFunctionsYAML(functions, targets)
	if err != nil {
		t.Fatalf("DevFunctionsYAML: %v", err)
	}
	docs := strings.Split(string(out), "---\n")
	seen := map[string]map[string]any{}
	for _, d := range docs {
		if strings.TrimSpace(d) == "" {
			continue
		}
		var fn map[string]any
		if err := yaml.Unmarshal([]byte(d), &fn); err != nil {
			t.Fatalf("unmarshal: %v", err)
		}
		meta := fn["metadata"].(map[string]any)
		seen[meta["name"].(string)] = fn
	}
	for name, target := range targets {
		fn, ok := seen[name]
		if !ok {
			t.Fatalf("function %q missing from output", name)
		}
		ann := fn["metadata"].(map[string]any)["annotations"].(map[string]any)
		if ann["render.crossplane.io/runtime"] != "Development" {
			t.Errorf("%s: runtime annotation = %v, want Development", name, ann["render.crossplane.io/runtime"])
		}
		if ann["render.crossplane.io/runtime-development-target"] != target {
			t.Errorf("%s: target = %v, want %s", name, ann["render.crossplane.io/runtime-development-target"], target)
		}
		// spec.package must be preserved (drift-free).
		if _, ok := fn["spec"].(map[string]any)["package"]; !ok {
			t.Errorf("%s: spec.package was dropped", name)
		}
	}
}

// Crossplane v2 runs the render ENGINE in Docker by default — separately from the
// functions — so annotating the functions for the Development runtime is not enough
// inside a container. Without --crossplane-binary the preview dies with:
//
//	crossplane: error: cannot create Docker network for rendering: ...
//	Cannot connect to the Docker daemon at unix:///var/run/docker.sock
//
// The engine binary is the crossplane CORE binary (crossplane-core), NOT the
// crank/CLI: `crossplane render` shells out to `<engine> internal render`, which
// only the core binary implements.
func TestRenderArgsPointTheEngineAtTheCoreBinary(t *testing.T) {
	r := &CrossplaneRenderer{
		Binary:          "crossplane",
		EngineBinary:    "/usr/local/bin/crossplane-core",
		CompositionPath: "/repo/composition.yaml",
		EnvConfigPath:   "/repo/environmentconfig.yaml",
		DevTargets:      map[string]string{"function-kcl": "localhost:9443"},
	}

	args := r.renderArgs("/tmp/claim.yaml", "/tmp/functions.yaml")

	var got string
	for _, a := range args {
		if strings.HasPrefix(a, "--crossplane-binary=") {
			got = a
		}
	}
	if got != "--crossplane-binary=/usr/local/bin/crossplane-core" {
		t.Fatalf("render must run the engine from the local core binary, not Docker; args = %v", args)
	}
}

// The engine is a DIFFERENT binary from the render driver. `crossplane render`
// (crank/CLI) shells out to `<--crossplane-binary> internal render`, a subcommand
// only the crossplane CORE binary implements — pointing the flag at the CLI itself
// fails with `crossplane: error: unexpected argument internal` (exit 80). The
// constructor must therefore resolve the engine to the core binary, and honor an
// explicit override so tests/operators can point it anywhere.
func TestNewCrossplaneRendererResolvesEngineFromOverride(t *testing.T) {
	t.Setenv("CROSSPLANE_ENGINE_BINARY", "/opt/xp/crossplane-core")

	r := NewCrossplaneRenderer("/repo", "composition.yaml", "functions.yaml", "environmentconfig.yaml", nil)

	if r.EngineBinary != "/opt/xp/crossplane-core" {
		t.Fatalf("EngineBinary = %q, want /opt/xp/crossplane-core (the CORE engine, not the CLI)", r.EngineBinary)
	}
	found := false
	for _, a := range r.renderArgs("/tmp/claim.yaml", "/tmp/functions.yaml") {
		if a == "--crossplane-binary=/opt/xp/crossplane-core" {
			found = true
		}
	}
	if !found {
		t.Fatalf("engine binary override not passed through to --crossplane-binary; args = %v", r.renderArgs("/tmp/claim.yaml", "/tmp/functions.yaml"))
	}
}

func TestRenderArgsOmitEngineFlagWhenBinaryUnresolved(t *testing.T) {
	r := &CrossplaneRenderer{Binary: "crossplane", CompositionPath: "/repo/composition.yaml"}

	for _, a := range r.renderArgs("/tmp/claim.yaml", "/tmp/functions.yaml") {
		if strings.HasPrefix(a, "--crossplane-binary=") {
			t.Fatalf("must not pass an empty --crossplane-binary; args = %v", r.renderArgs("/tmp/claim.yaml", "/tmp/functions.yaml"))
		}
	}
}
