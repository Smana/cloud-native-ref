package gitprovider

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// LocalDryRun is a DEV-ONLY provider (AUTH_MODE=dev). It reads files from the
// on-disk repo and, instead of opening a GitHub PR, writes the committed files
// into the working tree so they can be inspected/committed by hand. It never
// talks to GitHub. Do not wire this in a deployed environment.
type LocalDryRun struct {
	Root string // repository root on disk
}

// NewLocalDryRun builds the dev provider rooted at the on-disk repo.
func NewLocalDryRun(root string) *LocalDryRun { return &LocalDryRun{Root: root} }

func (l *LocalDryRun) ReadFile(_ context.Context, _, path string) ([]byte, string, error) {
	b, err := os.ReadFile(filepath.Join(l.Root, path))
	if err != nil {
		if os.IsNotExist(err) {
			return nil, "", ErrNotFound
		}
		return nil, "", err
	}
	return b, "", nil
}

func (l *LocalDryRun) ReadTree(_ context.Context, _, prefix string) ([]TreeEntry, error) {
	dir := filepath.Join(l.Root, prefix)
	entries, err := os.ReadDir(dir)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil
		}
		return nil, err
	}
	var out []TreeEntry
	for _, e := range entries {
		t := "blob"
		if e.IsDir() {
			t = "tree"
		}
		out = append(out, TreeEntry{Path: filepath.Join(prefix, e.Name()), Type: t})
	}
	return out, nil
}

// CreateBranch is a no-op for the dry-run provider.
func (l *LocalDryRun) CreateBranch(_ context.Context, _, _ string) error { return nil }

// CommitFiles writes the files into the working tree (dry-run "commit").
func (l *LocalDryRun) CommitFiles(_ context.Context, _ string, files []File, _ string) error {
	for _, f := range files {
		dst := filepath.Join(l.Root, f.Path)
		if f.Delete {
			if err := os.Remove(dst); err != nil && !os.IsNotExist(err) {
				return err
			}
			continue
		}
		if err := os.MkdirAll(filepath.Dir(dst), 0o755); err != nil {
			return err
		}
		if err := os.WriteFile(dst, f.Content, 0o644); err != nil {
			return err
		}
	}
	return nil
}

// OpenPR returns a synthetic result describing the dry-run (no real PR).
func (l *LocalDryRun) OpenPR(_ context.Context, _, head, _, _ string) (PullRequest, error) {
	return PullRequest{
		Number: 0,
		URL:    fmt.Sprintf("dev-dry-run: files written to the working tree (branch %q, no PR opened)", head),
	}, nil
}

// CommentPR is a no-op for the dry-run provider.
func (l *LocalDryRun) CommentPR(_ context.Context, _ int, _ string) error { return nil }

// CurrentUser returns a fixed dev identity.
func (l *LocalDryRun) CurrentUser(_ context.Context) (User, error) {
	login := strings.TrimSpace(os.Getenv("DEV_USER"))
	if login == "" {
		login = "dev-user"
	}
	return User{Login: login, Name: "Local Dev", AvatarURL: ""}, nil
}
