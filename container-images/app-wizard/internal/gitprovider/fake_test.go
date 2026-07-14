package gitprovider

import (
	"context"
	"testing"
)

func TestFakeProviderRoundTrip(t *testing.T) {
	ctx := context.Background()
	f := NewFakeProvider()
	f.Seed("main", "apps/team-a/kustomization.yaml", []byte("kind: Kustomization\n"))

	if err := f.CreateBranch(ctx, "main", "wizard/x"); err != nil {
		t.Fatalf("CreateBranch: %v", err)
	}

	// A branch reads through to its base.
	got, _, err := f.ReadFile(ctx, "wizard/x", "apps/team-a/kustomization.yaml")
	if err != nil {
		t.Fatalf("ReadFile through base: %v", err)
	}
	if string(got) != "kind: Kustomization\n" {
		t.Errorf("content = %q", got)
	}

	// Missing file.
	if _, _, err := f.ReadFile(ctx, "main", "nope.yaml"); err != ErrNotFound {
		t.Errorf("expected ErrNotFound, got %v", err)
	}

	if err := f.CommitFiles(ctx, "wizard/x", []File{{Path: "a.yaml", Content: []byte("x")}}, "msg"); err != nil {
		t.Fatalf("CommitFiles: %v", err)
	}
	pr, err := f.OpenPR(ctx, "main", "wizard/x", "title", "body")
	if err != nil {
		t.Fatalf("OpenPR: %v", err)
	}
	if pr.Number != 1 {
		t.Errorf("PR number = %d", pr.Number)
	}
	if err := f.CommentPR(ctx, pr.Number, "hi"); err != nil {
		t.Fatalf("CommentPR: %v", err)
	}
	if len(f.Comments[pr.Number]) != 1 {
		t.Errorf("comment not recorded")
	}
	u, err := f.CurrentUser(ctx)
	if err != nil || u.Login == "" {
		t.Errorf("CurrentUser = %+v, %v", u, err)
	}
}
