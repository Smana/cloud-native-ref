package schema

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"sigs.k8s.io/yaml"

	"github.com/Smana/cloud-native-ref/container-images/app-wizard/internal/api"
)

// resolvePath reports whether a dotted field key (e.g. "image.repository",
// "route.internetFacing") resolves to a property in the JSON Schema derived
// from the App XRD. Walks nested `properties` one segment at a time.
func resolvePath(schema map[string]any, dotted string) bool {
	cur := schema
	for _, seg := range strings.Split(dotted, ".") {
		props, ok := cur["properties"].(map[string]any)
		if !ok {
			return false
		}
		next, ok := props[seg].(map[string]any)
		if !ok {
			return false
		}
		cur = next
	}
	return true
}

// TestUIHintsNoDriftFromXRD is the drift guard: the App XRD is the single source
// of truth for the form's fields. ui-hints.yaml only adds presentation, so every
// field key it references MUST exist in the XRD. A renamed/removed XRD field that
// leaves a stale hint key fails this test — drift cannot be merged.
func TestUIHintsNoDriftFromXRD(t *testing.T) {
	jsonSchema, _, err := ConvertXRD(loadXRD(t))
	if err != nil {
		t.Fatalf("convert XRD: %v", err)
	}
	root := repoRoot(t)
	hb, err := os.ReadFile(filepath.Join(root, filepath.FromSlash("container-images/app-wizard/ui-hints.yaml")))
	if err != nil {
		t.Fatalf("read ui-hints.yaml: %v", err)
	}
	var hints api.UIHints
	if err := yaml.Unmarshal(hb, &hints); err != nil {
		t.Fatalf("parse ui-hints.yaml: %v", err)
	}
	if len(hints.Fields) == 0 {
		t.Fatal("ui-hints.yaml has no fields — did the parse shape change?")
	}
	for key := range hints.Fields {
		if !resolvePath(jsonSchema, key) {
			t.Errorf("ui-hints.yaml references field %q that does not exist in the App XRD (schema drift)", key)
		}
	}
}

// TestLoadBearingUIKeysExist guards the field names the FRONTEND references by
// hand (not via ui-hints): the secrets editor (env, externalSecrets) and the
// public-exposure warning (route.internetFacing). If the XRD renames any of
// these, the UI feature silently breaks — this test turns that into a build
// failure. Keep this list in sync with the hardcoded keys in ui/src/form/.
func TestLoadBearingUIKeysExist(t *testing.T) {
	jsonSchema, _, err := ConvertXRD(loadXRD(t))
	if err != nil {
		t.Fatalf("convert XRD: %v", err)
	}
	keys := []string{
		"env",                  // WizardForm SECRET_KEYS + SecretsEditor envPath
		"externalSecrets",      // WizardForm SECRET_KEYS + SecretsEditor secretsPath
		"route.internetFacing", // Field.tsx public-exposure warning
		"service.port",         // basic-tier leaf
		"image.repository",     // basic-tier leaf (required)
		"image.pullPolicy",     // basic-tier filter relies on it being advanced
	}
	for _, key := range keys {
		if !resolvePath(jsonSchema, key) {
			t.Errorf("load-bearing UI field %q is missing from the App XRD — the UI references it by name", key)
		}
	}
}
