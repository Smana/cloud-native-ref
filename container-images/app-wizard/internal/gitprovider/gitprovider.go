// Package gitprovider abstracts the Git hosting operations the wizard needs
// (read files, create a branch, commit files, open a PR, comment). A single
// GitHub implementation ships in v1 (FR-014: the coupling is a seam, not an
// architecture). All operations take a context and never log tokens.
package gitprovider

import (
	"context"
	"errors"
)

// ErrNotFound is returned by ReadFile when a path does not exist.
var ErrNotFound = errors.New("gitprovider: file not found")

// File is a path/content pair to commit. When Delete is true the path is
// removed in the commit and Content is ignored (Phase 2 decommission flow).
type File struct {
	Path    string
	Content []byte
	Delete  bool
}

// TreeEntry is one entry from ReadTree.
type TreeEntry struct {
	Path string
	Type string // "blob" | "tree"
}

// User is the authenticated identity behind a Provider.
type User struct {
	Login     string
	AvatarURL string
	Name      string
}

// PullRequest is the result of OpenPR.
type PullRequest struct {
	Number int
	URL    string
}

// Provider is the provider-agnostic Git hosting seam (FR-014).
type Provider interface {
	// ReadFile returns a file's content on a ref (branch/tag/sha). ErrNotFound
	// when absent.
	ReadFile(ctx context.Context, ref, path string) (content []byte, sha string, err error)
	// ReadTree lists entries under a directory prefix on a ref.
	ReadTree(ctx context.Context, ref, prefix string) ([]TreeEntry, error)
	// CreateBranch creates branch from the tip of baseBranch.
	CreateBranch(ctx context.Context, baseBranch, branch string) error
	// CommitFiles commits files to branch in a single commit.
	CommitFiles(ctx context.Context, branch string, files []File, message string) error
	// OpenPR opens a pull request from head into base.
	OpenPR(ctx context.Context, base, head, title, body string) (PullRequest, error)
	// CommentPR posts a comment on a pull request.
	CommentPR(ctx context.Context, number int, body string) error
	// CurrentUser returns the authenticated user.
	CurrentUser(ctx context.Context) (User, error)
}
