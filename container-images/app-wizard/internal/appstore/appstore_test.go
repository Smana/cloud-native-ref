package appstore

import (
	"context"
	"testing"

	"github.com/Smana/cloud-native-ref/container-images/app-wizard/internal/api"
	"github.com/Smana/cloud-native-ref/container-images/app-wizard/internal/gitprovider"
)

type fakeStacks struct {
	stacks []api.Stack
}

func (f fakeStacks) Stacks(_ context.Context) ([]api.Stack, error) {
	return f.stacks, nil
}

func TestListInventory(t *testing.T) {
	fp := gitprovider.NewFakeProvider()
	// Two apps in team-a with different types.
	fp.Seed("main", "apps/team-a/web-app/app.yaml", []byte(`apiVersion: cloud.ogenki.io/v1alpha1
kind: App
metadata:
  name: web-app
  namespace: apps-team-a
spec:
  image:
    repository: ghcr.io/acme/web
    tag: "1.2.3"
`))
	fp.Seed("main", "apps/team-a/worker-app/app.yaml", []byte(`apiVersion: cloud.ogenki.io/v1alpha1
kind: App
metadata:
  name: worker-app
  namespace: apps-team-a
spec:
  type: worker
  image:
    repository: ghcr.io/acme/worker
`))
	// A directory with no app.yaml must be ignored.
	fp.Seed("main", "apps/team-a/not-an-app/README.md", []byte("noise"))

	store := New(fakeStacks{stacks: []api.Stack{{Name: "team-a", Namespace: "apps-team-a"}}}, "main")
	got, err := store.List(context.Background(), fp)
	if err != nil {
		t.Fatalf("List: %v", err)
	}
	if len(got) != 2 {
		t.Fatalf("expected 2 apps, got %d: %+v", len(got), got)
	}

	// Sorted by name: web-app after worker-app? sort is by name ascending →
	// web-app, worker-app.
	byName := map[string]api.AppSummary{}
	for _, s := range got {
		byName[s.Name] = s
	}

	web := byName["web-app"]
	if web.Image != "ghcr.io/acme/web:1.2.3" {
		t.Errorf("web image = %q", web.Image)
	}
	if web.Type != "web" {
		t.Errorf("web type = %q, want web (default)", web.Type)
	}
	if web.Namespace != "apps-team-a" || web.Stack != "team-a" {
		t.Errorf("web summary = %+v", web)
	}

	worker := byName["worker-app"]
	if worker.Type != "worker" {
		t.Errorf("worker type = %q", worker.Type)
	}
	// No tag → repository only.
	if worker.Image != "ghcr.io/acme/worker" {
		t.Errorf("worker image = %q, want repo only", worker.Image)
	}
}

func TestListSkipsStackWithoutAppsDir(t *testing.T) {
	fp := gitprovider.NewFakeProvider()
	store := New(fakeStacks{stacks: []api.Stack{{Name: "empty", Namespace: "apps-empty"}}}, "main")
	got, err := store.List(context.Background(), fp)
	if err != nil {
		t.Fatalf("List: %v", err)
	}
	if len(got) != 0 {
		t.Errorf("expected no apps, got %+v", got)
	}
}

func TestGetApp(t *testing.T) {
	fp := gitprovider.NewFakeProvider()
	raw := []byte(`apiVersion: cloud.ogenki.io/v1alpha1
kind: App
metadata:
  name: myapp
  namespace: apps-team-a
spec:
  image:
    repository: ghcr.io/acme/myapp
    tag: "1.0"
`)
	fp.Seed("main", "apps/team-a/myapp/app.yaml", raw)

	store := New(fakeStacks{}, "main")
	detail, err := store.Get(context.Background(), fp, "team-a", "myapp")
	if err != nil {
		t.Fatalf("Get: %v", err)
	}
	if detail.Stack != "team-a" || detail.Name != "myapp" {
		t.Errorf("detail = %+v", detail)
	}
	if string(detail.RawYAML) != string(raw) {
		t.Errorf("RawYAML mismatch:\n%s", detail.RawYAML)
	}
	img, _ := detail.Spec["image"].(map[string]any)
	if img == nil || img["tag"] != "1.0" {
		t.Errorf("spec image not loaded: %+v", detail.Spec)
	}
}

func TestGetAppNotFound(t *testing.T) {
	fp := gitprovider.NewFakeProvider()
	store := New(fakeStacks{}, "main")
	_, err := store.Get(context.Background(), fp, "team-a", "ghost")
	if err != gitprovider.ErrNotFound {
		t.Errorf("expected ErrNotFound, got %v", err)
	}
}
