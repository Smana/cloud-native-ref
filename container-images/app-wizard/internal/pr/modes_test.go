package pr

import (
	"context"
	"strings"
	"testing"

	"github.com/Smana/cloud-native-ref/container-images/app-wizard/internal/gitprovider"
	"sigs.k8s.io/yaml"
)

func TestCreateGuardBlocksExistingApp(t *testing.T) {
	s := validService()
	fp := gitprovider.NewFakeProvider()
	// App already exists at base.
	fp.Seed("main", "apps/team-a/myapp/app.yaml", []byte("kind: App\n"))

	req := newReq()
	req.Mode = "create"
	_, err := s.Create(context.Background(), fp, req)
	if err == nil {
		t.Fatalf("expected gate error for existing app")
	}
	ge, ok := err.(*GateError)
	if !ok {
		t.Fatalf("expected *GateError, got %T", err)
	}
	if !strings.Contains(ge.Message, "already exists") {
		t.Errorf("unexpected message: %q", ge.Message)
	}
	// Nothing created.
	if len(fp.Commits) != 0 || len(fp.PRs) != 0 {
		t.Errorf("guard should create no git state: commits=%d prs=%d", len(fp.Commits), len(fp.PRs))
	}
}

func TestCreateModeSucceedsWhenAbsent(t *testing.T) {
	s := validService()
	fp := gitprovider.NewFakeProvider()

	req := newReq()
	req.Mode = "create"
	resp, err := s.Create(context.Background(), fp, req)
	if err != nil {
		t.Fatalf("Create: %v", err)
	}
	if len(fp.Commits) != 1 || len(fp.Commits[0].Files) != 3 {
		t.Fatalf("expected 1 commit of 3 files, got %+v", fp.Commits)
	}
	if !strings.HasPrefix(resp.Branch, "wizard/create-") {
		t.Errorf("branch = %q, want wizard/create-*", resp.Branch)
	}
}

func TestUpdateModeCommitsOnlyAppYAML(t *testing.T) {
	s := validService()
	fp := gitprovider.NewFakeProvider()
	existing := []byte(`apiVersion: cloud.ogenki.io/v1alpha1
kind: App
metadata:
  name: myapp
  namespace: apps-team-a
spec:
  image:
    repository: ghcr.io/acme/myapp
    tag: "1.0"
`)
	fp.Seed("main", "apps/team-a/myapp/app.yaml", existing)

	req := newReq()
	req.Mode = "update"
	req.Spec = map[string]any{
		"image": map[string]any{"repository": "ghcr.io/acme/myapp", "tag": "2.0"},
	}
	resp, err := s.Create(context.Background(), fp, req)
	if err != nil {
		t.Fatalf("update: %v", err)
	}
	if len(fp.Commits) != 1 {
		t.Fatalf("expected 1 commit, got %d", len(fp.Commits))
	}
	files := fp.Commits[0].Files
	if len(files) != 1 || files[0].Path != "apps/team-a/myapp/app.yaml" {
		t.Fatalf("update must commit only app.yaml, got %+v", files)
	}
	if files[0].Delete {
		t.Errorf("update file should not be a deletion")
	}
	if !strings.Contains(string(files[0].Content), `tag: "2.0"`) {
		t.Errorf("patched app.yaml missing new tag:\n%s", files[0].Content)
	}
	if !strings.HasPrefix(resp.Branch, "wizard/update-") {
		t.Errorf("branch = %q, want wizard/update-*", resp.Branch)
	}
	// A render-preview comment is posted for updates.
	if len(fp.Comments[resp.Number]) != 1 {
		t.Errorf("expected render comment, got %v", fp.Comments[resp.Number])
	}
}

func TestUpdateModeMissingApp(t *testing.T) {
	s := validService()
	fp := gitprovider.NewFakeProvider()
	req := newReq()
	req.Mode = "update"
	_, err := s.Create(context.Background(), fp, req)
	if err == nil {
		t.Fatalf("expected gate error for missing app")
	}
	ge, ok := err.(*GateError)
	if !ok {
		t.Fatalf("expected *GateError, got %T", err)
	}
	if !strings.Contains(ge.Message, "not found") {
		t.Errorf("unexpected message: %q", ge.Message)
	}
}

func TestDeleteModeRemovesFilesAndParentEntry(t *testing.T) {
	s := validService()
	fp := gitprovider.NewFakeProvider()
	fp.Seed("main", "apps/team-a/myapp/app.yaml", []byte("kind: App\n"))
	fp.Seed("main", "apps/team-a/myapp/kustomization.yaml", []byte("kind: Kustomization\n"))
	fp.Seed("main", "apps/team-a/kustomization.yaml",
		[]byte("apiVersion: kustomize.config.k8s.io/v1beta1\nkind: Kustomization\nresources:\n- ./other\n- ./myapp\n"))

	req := newReq()
	req.Mode = "delete"
	resp, err := s.Create(context.Background(), fp, req)
	if err != nil {
		t.Fatalf("delete: %v", err)
	}
	if len(fp.Commits) != 1 {
		t.Fatalf("expected 1 commit, got %d", len(fp.Commits))
	}
	byPath := map[string]gitprovider.File{}
	for _, f := range fp.Commits[0].Files {
		byPath[f.Path] = f
	}
	if f, ok := byPath["apps/team-a/myapp/app.yaml"]; !ok || !f.Delete {
		t.Errorf("app.yaml should be a deletion, got %+v", f)
	}
	if f, ok := byPath["apps/team-a/myapp/kustomization.yaml"]; !ok || !f.Delete {
		t.Errorf("app kustomization.yaml should be a deletion, got %+v", f)
	}
	parent, ok := byPath["apps/team-a/kustomization.yaml"]
	if !ok || parent.Delete {
		t.Fatalf("parent kustomization should be edited, not deleted: %+v", parent)
	}
	var k struct {
		Resources []string `json:"resources"`
	}
	if err := yaml.Unmarshal(parent.Content, &k); err != nil {
		t.Fatalf("parse parent: %v", err)
	}
	if contains(k.Resources, "./myapp") {
		t.Errorf("parent still references ./myapp: %v", k.Resources)
	}
	if !contains(k.Resources, "./other") {
		t.Errorf("parent lost unrelated ./other: %v", k.Resources)
	}
	if !strings.HasPrefix(resp.Branch, "wizard/remove-") {
		t.Errorf("branch = %q, want wizard/remove-*", resp.Branch)
	}
	// No render comment for a removal.
	if len(fp.Comments[resp.Number]) != 0 {
		t.Errorf("delete should post no render comment, got %v", fp.Comments[resp.Number])
	}
}

func TestDeleteModeMissingApp(t *testing.T) {
	s := validService()
	fp := gitprovider.NewFakeProvider()
	req := newReq()
	req.Mode = "delete"
	_, err := s.Create(context.Background(), fp, req)
	if err == nil {
		t.Fatalf("expected gate error for missing app")
	}
	if _, ok := err.(*GateError); !ok {
		t.Errorf("expected *GateError, got %T", err)
	}
}

func TestUnknownMode(t *testing.T) {
	s := validService()
	fp := gitprovider.NewFakeProvider()
	req := newReq()
	req.Mode = "frobnicate"
	_, err := s.Create(context.Background(), fp, req)
	if err == nil {
		t.Fatalf("expected error for unknown mode")
	}
	if _, ok := err.(*GateError); !ok {
		t.Errorf("expected *GateError, got %T", err)
	}
}

// RemoveResourceFromKustomization idempotency.
func TestRemoveResourceIdempotent(t *testing.T) {
	existing := []byte("apiVersion: kustomize.config.k8s.io/v1beta1\nkind: Kustomization\nresources:\n- ./a\n- ./b\n")
	out1, changed1, err := RemoveResourceFromKustomization(existing, "./a")
	if err != nil || !changed1 {
		t.Fatalf("first remove: changed=%v err=%v", changed1, err)
	}
	out2, changed2, err := RemoveResourceFromKustomization(out1, "./a")
	if err != nil {
		t.Fatalf("second remove: %v", err)
	}
	if changed2 {
		t.Errorf("second remove of absent entry should be no-op")
	}
	var k struct {
		Resources []string `json:"resources"`
	}
	if err := yaml.Unmarshal(out2, &k); err != nil {
		t.Fatalf("parse: %v", err)
	}
	if contains(k.Resources, "./a") || !contains(k.Resources, "./b") {
		t.Errorf("resources = %v, want [./b]", k.Resources)
	}
}
