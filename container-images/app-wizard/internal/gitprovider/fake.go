package gitprovider

import (
	"context"
	"sort"
	"strings"
	"sync"
)

// FakeProvider is an in-memory Provider for tests. It records branches,
// commits, PRs and comments and lets tests seed initial file content.
type FakeProvider struct {
	mu sync.Mutex

	User User

	// Files is the seeded/committed content keyed by "<ref>:<path>". The
	// base branch content is also readable from any branch created off it.
	Files map[string][]byte

	Branches map[string]string // branch -> base branch it was created from
	Commits  []FakeCommit
	PRs      []FakePR
	Comments map[int][]string

	nextPR int
}

// FakeCommit records a CommitFiles call.
type FakeCommit struct {
	Branch  string
	Message string
	Files   []File
}

// FakePR records an OpenPR call.
type FakePR struct {
	Number      int
	Base, Head  string
	Title, Body string
	URL         string
}

// NewFakeProvider builds an empty fake with a default user.
func NewFakeProvider() *FakeProvider {
	return &FakeProvider{
		User:     User{Login: "octocat", Name: "The Octocat", AvatarURL: "https://example.test/avatar.png"},
		Files:    map[string][]byte{},
		Branches: map[string]string{},
		Comments: map[int][]string{},
		nextPR:   1,
	}
}

// Seed stores content readable at ref/path (used to prime base-branch state).
func (f *FakeProvider) Seed(ref, path string, content []byte) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.Files[ref+":"+path] = content
}

func (f *FakeProvider) ReadFile(_ context.Context, ref, path string) ([]byte, string, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if c, ok := f.Files[ref+":"+path]; ok {
		return c, fakeSHA(c), nil
	}
	// Fall back to the base branch a branch was created from.
	if base, ok := f.Branches[ref]; ok {
		if c, ok := f.Files[base+":"+path]; ok {
			return c, fakeSHA(c), nil
		}
	}
	return nil, "", ErrNotFound
}

func (f *FakeProvider) ReadTree(_ context.Context, ref, prefix string) ([]TreeEntry, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	prefix = strings.TrimSuffix(prefix, "/") + "/"
	seen := map[string]TreeEntry{}
	for k := range f.Files {
		parts := strings.SplitN(k, ":", 2)
		if len(parts) != 2 || parts[0] != ref {
			continue
		}
		p := parts[1]
		if !strings.HasPrefix(p, prefix) {
			continue
		}
		rest := strings.TrimPrefix(p, prefix)
		if i := strings.Index(rest, "/"); i >= 0 {
			d := prefix + rest[:i]
			seen[d] = TreeEntry{Path: d, Type: "tree"}
		} else {
			seen[p] = TreeEntry{Path: p, Type: "blob"}
		}
	}
	out := make([]TreeEntry, 0, len(seen))
	for _, e := range seen {
		out = append(out, e)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Path < out[j].Path })
	return out, nil
}

func (f *FakeProvider) CreateBranch(_ context.Context, baseBranch, branch string) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.Branches[branch] = baseBranch
	return nil
}

func (f *FakeProvider) CommitFiles(_ context.Context, branch string, files []File, message string) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	for _, file := range files {
		if file.Delete {
			delete(f.Files, branch+":"+file.Path)
			continue
		}
		f.Files[branch+":"+file.Path] = file.Content
	}
	f.Commits = append(f.Commits, FakeCommit{Branch: branch, Message: message, Files: files})
	return nil
}

func (f *FakeProvider) OpenPR(_ context.Context, base, head, title, body string) (PullRequest, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	n := f.nextPR
	f.nextPR++
	pr := FakePR{Number: n, Base: base, Head: head, Title: title, Body: body, URL: "https://example.test/pr/" + itoa(n)}
	f.PRs = append(f.PRs, pr)
	return PullRequest{Number: n, URL: pr.URL}, nil
}

func (f *FakeProvider) CommentPR(_ context.Context, number int, body string) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.Comments[number] = append(f.Comments[number], body)
	return nil
}

func (f *FakeProvider) CurrentUser(_ context.Context) (User, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.User, nil
}

func fakeSHA(b []byte) string { return "sha-" + itoa(len(b)) }

func itoa(n int) string {
	if n == 0 {
		return "0"
	}
	neg := n < 0
	if neg {
		n = -n
	}
	var buf [20]byte
	i := len(buf)
	for n > 0 {
		i--
		buf[i] = byte('0' + n%10)
		n /= 10
	}
	if neg {
		i--
		buf[i] = '-'
	}
	return string(buf[i:])
}

var _ Provider = (*FakeProvider)(nil)
