package schema

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"os"
	"sync"

	"github.com/Smana/cloud-native-ref/container-images/app-wizard/internal/api"
	"sigs.k8s.io/yaml"
)

// Pipeline builds and caches the SchemaPayload. The XRD/stacks come from a
// SchemaSource (offline-testable via LocalSource); ui-hints.yaml is read from
// disk because it is bundled with the wizard, not the GitOps repo.
type Pipeline struct {
	src         SchemaSource
	xrdPath     string
	stacksPath  string
	uiHintsPath string

	mu    sync.Mutex
	cache map[string]*api.SchemaPayload // keyed by XRD SHA
}

// NewPipeline builds a pipeline. uiHintsPath is an on-disk path; xrdPath and
// stacksPath are resolved through src.
func NewPipeline(src SchemaSource, xrdPath, stacksPath, uiHintsPath string) *Pipeline {
	return &Pipeline{
		src:         src,
		xrdPath:     xrdPath,
		stacksPath:  stacksPath,
		uiHintsPath: uiHintsPath,
		cache:       map[string]*api.SchemaPayload{},
	}
}

// Build assembles the payload. The SchemaVersion is the XRD source SHA; the
// result is cached by that SHA.
func (p *Pipeline) Build(ctx context.Context) (*api.SchemaPayload, error) {
	xrdDoc, sha, err := p.src.ReadFile(ctx, p.xrdPath)
	if err != nil {
		return nil, fmt.Errorf("read XRD %q: %w", p.xrdPath, err)
	}

	p.mu.Lock()
	if cached, ok := p.cache[sha]; ok {
		p.mu.Unlock()
		return cached, nil
	}
	p.mu.Unlock()

	jsonSchema, celRules, err := ConvertXRD(xrdDoc)
	if err != nil {
		return nil, err
	}

	hints, err := p.loadHints()
	if err != nil {
		return nil, err
	}

	stacks, err := p.loadStacks(ctx)
	if err != nil {
		return nil, err
	}

	payload := &api.SchemaPayload{
		JSONSchema:    jsonSchema,
		CELRules:      celRules,
		Hints:         hints,
		Stacks:        stacks,
		SchemaVersion: sha,
	}

	p.mu.Lock()
	p.cache[sha] = payload
	p.mu.Unlock()

	return payload, nil
}

// CELRules is a convenience returning just the CEL rules (used by the
// validator wiring).
func (p *Pipeline) CELRules(ctx context.Context) ([]api.CELRule, error) {
	pl, err := p.Build(ctx)
	if err != nil {
		return nil, err
	}
	return pl.CELRules, nil
}

// JSONSchema is a convenience returning just the JSON Schema.
func (p *Pipeline) JSONSchema(ctx context.Context) (map[string]any, error) {
	pl, err := p.Build(ctx)
	if err != nil {
		return nil, err
	}
	return pl.JSONSchema, nil
}

func (p *Pipeline) loadHints() (api.UIHints, error) {
	empty := api.UIHints{Fields: map[string]api.FieldHint{}, Groups: []api.GroupHint{}}
	if p.uiHintsPath == "" {
		return empty, nil
	}
	b, err := os.ReadFile(p.uiHintsPath)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return empty, nil
		}
		return empty, fmt.Errorf("read ui-hints %q: %w", p.uiHintsPath, err)
	}
	var h api.UIHints
	if err := yaml.Unmarshal(b, &h); err != nil {
		return empty, fmt.Errorf("parse ui-hints: %w", err)
	}
	if h.Fields == nil {
		h.Fields = map[string]api.FieldHint{}
	}
	if h.Groups == nil {
		h.Groups = []api.GroupHint{}
	}
	return h, nil
}

func (p *Pipeline) loadStacks(ctx context.Context) ([]api.Stack, error) {
	b, _, err := p.src.ReadFile(ctx, p.stacksPath)
	if err != nil {
		// Tolerate absence: empty list (T107).
		if errors.Is(err, os.ErrNotExist) {
			return []api.Stack{}, nil
		}
		return nil, fmt.Errorf("read stacks %q: %w", p.stacksPath, err)
	}
	var doc struct {
		Stacks []api.Stack `json:"stacks"`
	}
	if err := yaml.Unmarshal(b, &doc); err != nil {
		return nil, fmt.Errorf("parse stacks: %w", err)
	}
	if doc.Stacks == nil {
		return []api.Stack{}, nil
	}
	return doc.Stacks, nil
}

// Stack resolves a stack name to its registry entry (StackResolver).
func (p *Pipeline) Stack(ctx context.Context, name string) (api.Stack, bool, error) {
	pl, err := p.Build(ctx)
	if err != nil {
		return api.Stack{}, false, err
	}
	for _, s := range pl.Stacks {
		if s.Name == name {
			return s, true, nil
		}
	}
	return api.Stack{}, false, nil
}

// Handler serves GET /api/schema.
func (p *Pipeline) Handler() http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		payload, err := p.Build(r.Context())
		if err != nil {
			writeJSONError(w, http.StatusInternalServerError, err.Error())
			return
		}
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		_ = json.NewEncoder(w).Encode(payload)
	}
}

func writeJSONError(w http.ResponseWriter, status int, msg string) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(api.ErrorResponse{Error: msg})
}
