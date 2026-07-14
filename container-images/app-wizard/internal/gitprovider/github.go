package gitprovider

import (
	"context"
	"fmt"

	"github.com/google/go-github/v66/github"
	"golang.org/x/oauth2"
)

// GitHub is a Provider backed by the GitHub REST API, acting as the user whose
// OAuth token is supplied. The token is held only for the lifetime of the
// request/session and is never logged.
type GitHub struct {
	client *github.Client
	owner  string
	repo   string
}

// NewGitHub builds a GitHub provider for owner/repo using the user's token.
func NewGitHub(ctx context.Context, token, owner, repo string) *GitHub {
	ts := oauth2.StaticTokenSource(&oauth2.Token{AccessToken: token})
	tc := oauth2.NewClient(ctx, ts)
	return &GitHub{
		client: github.NewClient(tc),
		owner:  owner,
		repo:   repo,
	}
}

func (g *GitHub) ReadFile(ctx context.Context, ref, path string) ([]byte, string, error) {
	fc, _, resp, err := g.client.Repositories.GetContents(ctx, g.owner, g.repo, path, &github.RepositoryContentGetOptions{Ref: ref})
	if err != nil {
		if resp != nil && resp.StatusCode == 404 {
			return nil, "", ErrNotFound
		}
		return nil, "", err
	}
	if fc == nil {
		return nil, "", ErrNotFound
	}
	content, err := fc.GetContent()
	if err != nil {
		return nil, "", err
	}
	return []byte(content), fc.GetSHA(), nil
}

func (g *GitHub) ReadTree(ctx context.Context, ref, prefix string) ([]TreeEntry, error) {
	_, dir, resp, err := g.client.Repositories.GetContents(ctx, g.owner, g.repo, prefix, &github.RepositoryContentGetOptions{Ref: ref})
	if err != nil {
		if resp != nil && resp.StatusCode == 404 {
			return nil, ErrNotFound
		}
		return nil, err
	}
	entries := make([]TreeEntry, 0, len(dir))
	for _, e := range dir {
		typ := "blob"
		if e.GetType() == "dir" {
			typ = "tree"
		}
		entries = append(entries, TreeEntry{Path: e.GetPath(), Type: typ})
	}
	return entries, nil
}

func (g *GitHub) CreateBranch(ctx context.Context, baseBranch, branch string) error {
	baseRef, _, err := g.client.Git.GetRef(ctx, g.owner, g.repo, "refs/heads/"+baseBranch)
	if err != nil {
		return fmt.Errorf("get base ref %q: %w", baseBranch, err)
	}
	newRef := &github.Reference{
		Ref:    github.String("refs/heads/" + branch),
		Object: &github.GitObject{SHA: baseRef.Object.SHA},
	}
	_, _, err = g.client.Git.CreateRef(ctx, g.owner, g.repo, newRef)
	return err
}

func (g *GitHub) CommitFiles(ctx context.Context, branch string, files []File, message string) error {
	ref, _, err := g.client.Git.GetRef(ctx, g.owner, g.repo, "refs/heads/"+branch)
	if err != nil {
		return fmt.Errorf("get branch ref %q: %w", branch, err)
	}
	baseCommit, _, err := g.client.Git.GetCommit(ctx, g.owner, g.repo, ref.Object.GetSHA())
	if err != nil {
		return err
	}

	entries := make([]*github.TreeEntry, 0, len(files))
	for _, f := range files {
		if f.Delete {
			// A tree entry with a nil SHA (and no content) removes the path from
			// the base tree when committed.
			entries = append(entries, &github.TreeEntry{
				Path: github.String(f.Path),
				Mode: github.String("100644"),
				Type: github.String("blob"),
				SHA:  nil,
			})
			continue
		}
		entries = append(entries, &github.TreeEntry{
			Path:    github.String(f.Path),
			Mode:    github.String("100644"),
			Type:    github.String("blob"),
			Content: github.String(string(f.Content)),
		})
	}
	tree, _, err := g.client.Git.CreateTree(ctx, g.owner, g.repo, baseCommit.Tree.GetSHA(), entries)
	if err != nil {
		return fmt.Errorf("create tree: %w", err)
	}

	commit := &github.Commit{
		Message: github.String(message),
		Tree:    tree,
		Parents: []*github.Commit{{SHA: baseCommit.SHA}},
	}
	newCommit, _, err := g.client.Git.CreateCommit(ctx, g.owner, g.repo, commit, nil)
	if err != nil {
		return fmt.Errorf("create commit: %w", err)
	}

	ref.Object.SHA = newCommit.SHA
	_, _, err = g.client.Git.UpdateRef(ctx, g.owner, g.repo, ref, false)
	if err != nil {
		return fmt.Errorf("update ref: %w", err)
	}
	return nil
}

func (g *GitHub) OpenPR(ctx context.Context, base, head, title, body string) (PullRequest, error) {
	pr, _, err := g.client.PullRequests.Create(ctx, g.owner, g.repo, &github.NewPullRequest{
		Title: github.String(title),
		Head:  github.String(head),
		Base:  github.String(base),
		Body:  github.String(body),
	})
	if err != nil {
		return PullRequest{}, err
	}
	return PullRequest{Number: pr.GetNumber(), URL: pr.GetHTMLURL()}, nil
}

func (g *GitHub) CommentPR(ctx context.Context, number int, body string) error {
	_, _, err := g.client.Issues.CreateComment(ctx, g.owner, g.repo, number, &github.IssueComment{
		Body: github.String(body),
	})
	return err
}

func (g *GitHub) CurrentUser(ctx context.Context) (User, error) {
	u, _, err := g.client.Users.Get(ctx, "")
	if err != nil {
		return User{}, err
	}
	return User{Login: u.GetLogin(), AvatarURL: u.GetAvatarURL(), Name: u.GetName()}, nil
}

// compile-time assertion.
var _ Provider = (*GitHub)(nil)
