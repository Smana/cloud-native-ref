// Package schema builds the SchemaPayload the form renderer consumes: the App
// XRD converted to JSON Schema (draft 2020-12), the extracted CEL rules, the
// ui-hints presentation overlay, and the stack registry (FR-001/002/003/006,
// T102/T107).
package schema

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"os"
	"path/filepath"

	"github.com/Smana/cloud-native-ref/container-images/app-wizard/internal/gitprovider"
)

// SchemaSource reads repo files for the pipeline. Two implementations:
// LocalSource (disk, dev/test) and GitHubSource (via gitprovider, prod).
type SchemaSource interface {
	// ReadFile returns the file content and a content-addressed SHA. A missing
	// file returns os.ErrNotExist so callers can tolerate optional files.
	ReadFile(ctx context.Context, path string) (content []byte, sha string, err error)
}

// LocalSource reads files relative to a repository root on disk.
type LocalSource struct {
	Root string
}

// NewLocalSource builds a LocalSource rooted at root.
func NewLocalSource(root string) *LocalSource { return &LocalSource{Root: root} }

func (s *LocalSource) ReadFile(_ context.Context, path string) ([]byte, string, error) {
	full := filepath.Join(s.Root, filepath.FromSlash(path))
	b, err := os.ReadFile(full)
	if err != nil {
		return nil, "", err
	}
	return b, contentSHA(b), nil
}

// GitHubSource reads files from a git ref via a gitprovider.Provider.
type GitHubSource struct {
	Provider gitprovider.Provider
	Ref      string
}

// NewGitHubSource builds a source reading path at ref through p.
func NewGitHubSource(p gitprovider.Provider, ref string) *GitHubSource {
	return &GitHubSource{Provider: p, Ref: ref}
}

func (s *GitHubSource) ReadFile(ctx context.Context, path string) ([]byte, string, error) {
	b, sha, err := s.Provider.ReadFile(ctx, s.Ref, path)
	if err != nil {
		if err == gitprovider.ErrNotFound {
			return nil, "", os.ErrNotExist
		}
		return nil, "", err
	}
	if sha == "" {
		sha = contentSHA(b)
	}
	return b, sha, nil
}

func contentSHA(b []byte) string {
	sum := sha256.Sum256(b)
	return hex.EncodeToString(sum[:])[:12]
}
