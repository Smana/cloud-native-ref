package pr

import (
	"context"
	"testing"

	"github.com/Smana/cloud-native-ref/container-images/app-wizard/internal/api"
	"github.com/Smana/cloud-native-ref/container-images/app-wizard/internal/gitprovider"
	"github.com/Smana/cloud-native-ref/container-images/app-wizard/internal/render"
	"sigs.k8s.io/yaml"
)

type fakeValidator struct {
	resp api.ValidateResponse
}

func (f fakeValidator) Validate(_ context.Context, _ map[string]any) (api.ValidateResponse, error) {
	return f.resp, nil
}

type fakeStacks struct{}

func (fakeStacks) Stack(_ context.Context, name string) (api.Stack, bool, error) {
	if name == "team-a" {
		return api.Stack{Name: "team-a", Namespace: "apps-team-a", OwnerTeam: "team-a"}, true, nil
	}
	return api.Stack{}, false, nil
}

func validService() *Service {
	v := fakeValidator{resp: api.ValidateResponse{Valid: true}}
	r := &render.FakeRenderer{Resources: []api.RenderedResource{
		{Kind: "Deployment", Name: "xplane-myapp"},
		{Kind: "Service", Name: "xplane-myapp"},
	}}
	return NewService(v, r, fakeStacks{}, "main")
}

func newReq() api.PRRequest {
	return api.PRRequest{
		Stack:       "team-a",
		AppName:     "myapp",
		Description: "a test app",
		Spec: map[string]any{
			"image": map[string]any{"repository": "ghcr.io/acme/myapp", "tag": "v1"},
		},
	}
}

func TestCreateGeneratesThreeFiles(t *testing.T) {
	s := validService()
	fp := gitprovider.NewFakeProvider()

	resp, err := s.Create(context.Background(), fp, newReq())
	if err != nil {
		t.Fatalf("Create: %v", err)
	}
	if resp.Number == 0 || resp.Branch == "" || resp.URL == "" {
		t.Errorf("incomplete PRResponse: %+v", resp)
	}

	if len(fp.Commits) != 1 {
		t.Fatalf("expected 1 commit, got %d", len(fp.Commits))
	}
	files := fp.Commits[0].Files
	if len(files) != 3 {
		t.Fatalf("expected 3 files, got %d", len(files))
	}
	want := map[string]bool{
		"apps/team-a/myapp/app.yaml":           false,
		"apps/team-a/myapp/kustomization.yaml": false,
		"apps/team-a/kustomization.yaml":       false,
	}
	for _, f := range files {
		if _, ok := want[f.Path]; ok {
			want[f.Path] = true
		} else {
			t.Errorf("unexpected file path %q", f.Path)
		}
	}
	for p, seen := range want {
		if !seen {
			t.Errorf("missing file %q", p)
		}
	}

	// app.yaml carries the claim with the stack namespace.
	var claim map[string]any
	for _, f := range files {
		if f.Path == "apps/team-a/myapp/app.yaml" {
			if err := yaml.Unmarshal(f.Content, &claim); err != nil {
				t.Fatalf("parse app.yaml: %v", err)
			}
		}
	}
	if claim["kind"] != "App" {
		t.Errorf("claim kind = %v", claim["kind"])
	}
	meta := claim["metadata"].(map[string]any)
	if meta["name"] != "myapp" || meta["namespace"] != "apps-team-a" {
		t.Errorf("claim metadata = %v", meta)
	}

	// A render-preview comment was posted.
	if len(fp.Comments[resp.Number]) != 1 {
		t.Errorf("expected 1 render comment, got %v", fp.Comments[resp.Number])
	}
}

func TestParentKustomizationEditIdempotent(t *testing.T) {
	entry := "./myapp"

	// First edit: fresh (nil existing) adds the entry.
	out1, changed1, err := AddResourceToKustomization(nil, entry)
	if err != nil {
		t.Fatalf("edit 1: %v", err)
	}
	if !changed1 {
		t.Errorf("expected change on first edit")
	}

	// Second edit over the produced content: no duplicate, no change.
	out2, changed2, err := AddResourceToKustomization(out1, entry)
	if err != nil {
		t.Fatalf("edit 2: %v", err)
	}
	if changed2 {
		t.Errorf("expected no change on idempotent second edit")
	}

	var k struct {
		Resources []string `json:"resources"`
	}
	if err := yaml.Unmarshal(out2, &k); err != nil {
		t.Fatalf("parse: %v", err)
	}
	count := 0
	for _, r := range k.Resources {
		if r == entry {
			count++
		}
	}
	if count != 1 {
		t.Errorf("entry appears %d times, want 1: %v", count, k.Resources)
	}
}

func TestCreateIdempotentWithExistingParent(t *testing.T) {
	s := validService()
	fp := gitprovider.NewFakeProvider()
	// Seed a parent kustomization already containing another app.
	existing := []byte("apiVersion: kustomize.config.k8s.io/v1beta1\nkind: Kustomization\nresources:\n- ./other\n")
	fp.Seed("main", "apps/team-a/kustomization.yaml", existing)

	if _, err := s.Create(context.Background(), fp, newReq()); err != nil {
		t.Fatalf("Create: %v", err)
	}

	var parent []byte
	for _, f := range fp.Commits[0].Files {
		if f.Path == "apps/team-a/kustomization.yaml" {
			parent = f.Content
		}
	}
	var k struct {
		Resources []string `json:"resources"`
	}
	if err := yaml.Unmarshal(parent, &k); err != nil {
		t.Fatalf("parse parent: %v", err)
	}
	if len(k.Resources) != 2 || !contains(k.Resources, "./other") || !contains(k.Resources, "./myapp") {
		t.Errorf("parent resources = %v, want [./other ./myapp]", k.Resources)
	}
}

func TestCreateBlockedByValidationGate(t *testing.T) {
	v := fakeValidator{resp: api.ValidateResponse{Valid: false, CELViolations: []api.CELRule{{Message: "bad"}}}}
	r := &render.FakeRenderer{}
	s := NewService(v, r, fakeStacks{}, "main")
	fp := gitprovider.NewFakeProvider()

	_, err := s.Create(context.Background(), fp, newReq())
	if err == nil {
		t.Fatalf("expected gate error")
	}
	if _, ok := err.(*GateError); !ok {
		t.Fatalf("expected *GateError, got %T", err)
	}
	// Nothing created.
	if len(fp.Commits) != 0 || len(fp.PRs) != 0 || len(fp.Branches) != 0 {
		t.Errorf("gate failure created git state: commits=%d prs=%d branches=%d",
			len(fp.Commits), len(fp.PRs), len(fp.Branches))
	}
	// Renderer must not have been called (validation is gate 1).
	if len(r.Calls) != 0 {
		t.Errorf("renderer called despite validation failure")
	}
}

func TestCreateUnknownStack(t *testing.T) {
	s := validService()
	fp := gitprovider.NewFakeProvider()
	req := newReq()
	req.Stack = "nope"
	_, err := s.Create(context.Background(), fp, req)
	if err == nil {
		t.Fatalf("expected error for unknown stack")
	}
	if _, ok := err.(*GateError); !ok {
		t.Errorf("expected *GateError, got %T", err)
	}
}

func contains(arr []string, want string) bool {
	for _, s := range arr {
		if s == want {
			return true
		}
	}
	return false
}
