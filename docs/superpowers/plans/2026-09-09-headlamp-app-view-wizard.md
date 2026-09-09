# Headlamp App View — Wizard Side Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix the two layout bugs found in review, then teach the App Wizard a generic `links` configuration so each app card can open an external URL template, released as v0.3.0.

**Architecture:** The wizard stays a Git view with no cluster access. A new `internal/layout` package becomes the single owner of the `{stack}/{app}` template so the PR service and the inventory agree. `links` is a file-only list in `wizard.yaml`, validated at load, surfaced through the existing `/api/branding` payload as unexpanded templates, and expanded per app in the SPA, which turns the inventory table into a card grid with an open action.

**Tech Stack:** Go 1.27 (`net/http`, `sigs.k8s.io/yaml`, strict `gopkg.in/yaml.v3` decoder), React 19 + Vite 8 + Vitest 4 + Testing Library, Tailwind 3.

**Spec:** `docs/superpowers/specs/2026-09-09-headlamp-app-view-design.md` (in `Smana/cloud-native-ref`). This plan implements its sections "The wizard" and stage 1 of "Stages".

**Repository:** `Smana/app-wizard`, local checkout `~/Sources/app-wizard`, branch from `main` (HEAD `242e580`). Two branches, two PRs: `fix/layout-inventory` for Tasks 1–2, `feat/links` for Tasks 3–7.

## Global Constraints

- The wizard holds no cluster credentials and gains none. A link is built from `stack`, `name`, `namespace` only.
- `links` is file-only (like `branding.theme`); no environment override.
- Allowed placeholders: `{namespace}`, `{name}`, `{stack}`. Any other `{...}` fails startup naming the entry.
- `links[].label` and `links[].url` non-empty; `url` an absolute `http` or `https` URL.
- Absent `links` changes nothing: cards render with Edit and Decommission only.
- With one link the open action opens it in a new tab with `noopener noreferrer`; with several, a menu of labels.
- `wizard.yaml` is decoded with `KnownFields(true)`: every new key needs a `fileConfig` field first.
- Commit messages in English, conventional prefix, no co-author trailers.
- CI (`.github/workflows/ci.yml`) fails on any skipped Go test; `gofmt` and `go vet` must be clean; `cd ui && npm test` and `npm run build` must pass.
- Release: a `v0.3.0` git tag on `main` publishes `ghcr.io/smana/app-wizard:v0.3.0` (`.github/workflows/build.yml`).

---

## File structure

| File | Responsibility |
|---|---|
| `internal/layout/layout.go` (new) | `Expand(layout, stack, app)` and `StackDir(layout, stack)`: the one place that knows the template |
| `internal/layout/layout_test.go` (new) | Round-trip and default behaviour |
| `internal/pr/pr.go` | Uses `layout.Expand`; `removalBody` names the real directory |
| `internal/pr/modes_test.go` | Removal body test under a custom layout |
| `internal/appstore/appstore.go` | `New(stacks, ref, layout)`; `List`/`Get` derive paths from the layout |
| `internal/appstore/appstore_test.go` | Custom-layout tests |
| `cmd/app-wizard/main.go` | Passes `cfg.Layout` to the store; branding handler extracted |
| `cmd/app-wizard/branding.go` + `branding_test.go` (new) | `brandingHandler(api.Branding)` |
| `internal/config/config.go` + `config_test.go` | `Link`, `Config.Links`, `fileConfig.Links`, `validateLinks` |
| `internal/api/types.go` | `Link` on the wire, `Branding.Links` |
| `ui/src/api/types.ts`, `ui/src/api/client.ts` | Mirror `Link`, default `links: []` |
| `ui/src/form/links.ts` + `links.test.ts` (new) | `expandLink(url, app)` |
| `ui/src/form/AppList.tsx` + `AppList.test.tsx` | Card grid with the open action |
| `ui/src/App.tsx` | Passes `branding.links` to `AppList` |
| `docs/configuration.md`, `examples/wizard.yaml` | Document `links` |

---

### Task 1: One owner for the layout template, and an inventory that honours it

**Files:**
- Create: `internal/layout/layout.go`, `internal/layout/layout_test.go`
- Modify: `internal/pr/pr.go:99-116`, `internal/appstore/appstore.go:24-33,38-60,84-86`, `internal/appstore/appstore_test.go:45,84,108,127`, `cmd/app-wizard/main.go:75`
- Test: `internal/appstore/appstore_test.go`, `internal/layout/layout_test.go`, `internal/pr/...` (existing suite must stay green)

**Interfaces:**
- Produces: `layout.Expand(layout, stack, app string) string`, `layout.StackDir(layout, stack string) string`, `layout.Default = "apps/{stack}/{app}"`, `appstore.New(stacks StackLister, ref, layout string) *Store`.
- Consumed by: Task 2 (`layout.Expand` in the removal body), Task 6 is independent.

- [ ] **Step 1: Create the branch**

```bash
cd ~/Sources/app-wizard && git switch main && git pull --ff-only && git switch -c fix/layout-inventory
```

- [ ] **Step 2: Write the failing layout tests**

`internal/layout/layout_test.go`:

```go
package layout

import "testing"

func TestExpandDefault(t *testing.T) {
	if got := Expand("", "team-a", "myapp"); got != "apps/team-a/myapp" {
		t.Errorf("Expand default = %q", got)
	}
	if got := Expand(Default, "team-a", "myapp"); got != "apps/team-a/myapp" {
		t.Errorf("Expand(Default) = %q", got)
	}
}

func TestExpandCustom(t *testing.T) {
	got := Expand("tenants/{stack}/apps/{app}", "team-a", "myapp")
	if got != "tenants/team-a/apps/myapp" {
		t.Errorf("Expand custom = %q", got)
	}
}

func TestStackDirIsParentOfAppDir(t *testing.T) {
	cases := map[string]string{
		"":                             "apps/team-a",
		"apps/{stack}/{app}":           "apps/team-a",
		"tenants/{stack}/apps/{app}":   "tenants/team-a/apps",
		"workloads/{app}":              "workloads",
	}
	for l, want := range cases {
		if got := StackDir(l, "team-a"); got != want {
			t.Errorf("StackDir(%q) = %q, want %q", l, got, want)
		}
	}
}
```

- [ ] **Step 3: Run them to confirm they fail**

Run: `go test ./internal/layout/ -run . -v`
Expected: FAIL — `undefined: Expand` (package does not compile yet).

- [ ] **Step 4: Write `internal/layout/layout.go`**

```go
// Package layout owns the file-layout template that decides where an app's
// manifests live in the GitOps repo. Both writers (the PR service) and readers
// (the inventory) go through it, so they cannot disagree.
package layout

import (
	"path"
	"strings"
)

// Default reproduces the historical layout.
const Default = "apps/{stack}/{app}"

// Expand substitutes {stack} and {app} in the template and returns the app
// directory. An empty template means Default. Convention (enforced by the
// config loader): the last path segment is the app directory.
func Expand(layout, stack, app string) string {
	if layout == "" {
		layout = Default
	}
	return path.Clean(strings.NewReplacer("{stack}", stack, "{app}", app).Replace(layout))
}

// StackDir is the directory that holds every app of a stack: the parent of an
// expanded app directory. Listing it and reading <entry>/app.yaml is how the
// inventory discovers apps.
func StackDir(layout, stack string) string {
	return path.Dir(Expand(layout, stack, "app"))
}
```

- [ ] **Step 5: Run the layout tests**

Run: `go test ./internal/layout/ -v`
Expected: PASS (3 tests).

- [ ] **Step 6: Make the PR service use it**

In `internal/pr/pr.go`, add `"github.com/Smana/app-wizard/internal/layout"` to the imports, then replace lines 103–116 (`appPaths` body and `expandLayout`) with:

```go
func (s *Service) appPaths(stack, app string) (appPath, kustPath, parentKustPath, appDir string) {
	appDir = layout.Expand(s.layout, stack, app)
	parentDir := path.Dir(appDir)
	return path.Join(appDir, "app.yaml"),
		path.Join(appDir, "kustomization.yaml"),
		path.Join(parentDir, "kustomization.yaml"),
		appDir
}
```

Delete the `expandLayout` function and its comment. Leave `NewService`'s `if layout == ""` default in place (it is still the documented contract of that constructor).

- [ ] **Step 7: Run the PR suite to prove nothing moved**

Run: `go build ./... && go test ./internal/pr/`
Expected: PASS. If `strings` is now unused in `pr.go`, the build says so — remove the import only if the compiler complains.

- [ ] **Step 8: Write the failing inventory tests**

Append to `internal/appstore/appstore_test.go`:

```go
// The inventory must read from wherever the PR service writes. With a custom
// layout the old code listed "apps/<stack>" and found nothing.
func TestListHonoursLayout(t *testing.T) {
	fp := gitprovider.NewFakeProvider()
	fp.Seed("main", "tenants/team-a/apps/web-app/app.yaml", []byte(`apiVersion: example.com/v1beta1
kind: App
metadata:
  name: web-app
spec:
  image:
    repository: ghcr.io/acme/web
`))
	// Same app under the default layout must NOT be picked up: only the
	// configured layout is the source of truth.
	fp.Seed("main", "apps/team-a/stale/app.yaml", []byte("kind: App\nmetadata:\n  name: stale\n"))

	store := New(fakeStacks{stacks: []api.Stack{{Name: "team-a", Namespace: "apps-team-a"}}}, "main", "tenants/{stack}/apps/{app}")
	got, err := store.List(context.Background(), fp)
	if err != nil {
		t.Fatalf("List: %v", err)
	}
	if len(got) != 1 || got[0].Name != "web-app" || got[0].Namespace != "apps-team-a" {
		t.Fatalf("got %+v, want exactly web-app in apps-team-a", got)
	}
}

func TestGetHonoursLayout(t *testing.T) {
	fp := gitprovider.NewFakeProvider()
	fp.Seed("main", "tenants/team-a/apps/myapp/app.yaml", []byte("kind: App\nspec:\n  replicas: 2\n"))

	store := New(fakeStacks{}, "main", "tenants/{stack}/apps/{app}")
	detail, err := store.Get(context.Background(), fp, "team-a", "myapp")
	if err != nil {
		t.Fatalf("Get: %v", err)
	}
	if detail.Spec["replicas"] != float64(2) {
		t.Errorf("spec not loaded from the layout path: %+v", detail.Spec)
	}
	if _, err := New(fakeStacks{}, "main", "").Get(context.Background(), fp, "team-a", "myapp"); err != gitprovider.ErrNotFound {
		t.Errorf("default layout must not find an app stored under the custom one, got %v", err)
	}
}
```

Update the four existing `New(...)` calls in this file (lines 45, 84, 108, 127) to pass a third argument `""`.

- [ ] **Step 9: Run to confirm they fail**

Run: `go test ./internal/appstore/ -run 'HonoursLayout' -v`
Expected: FAIL — `too many arguments in call to New` (compile error).

- [ ] **Step 10: Implement the layout-aware store**

In `internal/appstore/appstore.go`, add the import `"github.com/Smana/app-wizard/internal/layout"`, then:

```go
// Store reads app inventory from a repo ref.
type Store struct {
	stacks StackLister
	ref    string // base branch/ref to read from
	layout string // file-layout template shared with the PR service
}

// New builds a Store reading from ref (typically the repo base branch). layout
// is the same template the PR service writes with ("" means layout.Default).
func New(stacks StackLister, ref, layout string) *Store {
	return &Store{stacks: stacks, ref: ref, layout: layout}
}
```

In `List`, replace the `prefix := path.Join("apps", stack.Name)` line and the entry loop with:

```go
		prefix := layout.StackDir(s.layout, stack.Name)
		entries, err := provider.ReadTree(ctx, s.ref, prefix)
		if err != nil {
			if err == gitprovider.ErrNotFound {
				continue
			}
			return nil, fmt.Errorf("read tree %q: %w", prefix, err)
		}
		for _, e := range entries {
			if e.Type != "tree" {
				continue
			}
			appName := path.Base(e.Path)
			// Round-trip guard: only directories the layout would produce for
			// this name are apps. Anything else under the stack dir is noise.
			if layout.Expand(s.layout, stack.Name, appName) != e.Path {
				continue
			}
			appPath := path.Join(e.Path, "app.yaml")
			content, _, err := provider.ReadFile(ctx, s.ref, appPath)
			if err != nil {
				// No app.yaml under this dir — not an app; skip.
				continue
			}
			summary, ok := summaryFromClaim(stack, appName, content)
			if !ok {
				continue
			}
			out = append(out, summary)
		}
```

In `Get`, replace `appPath := path.Join("apps", stack, name, "app.yaml")` with:

```go
	appPath := path.Join(layout.Expand(s.layout, stack, name), "app.yaml")
```

Update the package comment's first lines to: `It walks <layout stack dir>/*/app.yaml for every stack in the registry` (replace the literal `apps/<stack>/*/app.yaml`).

- [ ] **Step 11: Wire the config through**

`cmd/app-wizard/main.go:75`:

```go
	appStore := appstore.New(pipeline, cfg.RepoBaseBranch, cfg.Layout)
```

- [ ] **Step 12: Run the whole suite**

Run: `gofmt -l . && go vet ./... && go test -race ./...`
Expected: `gofmt -l` prints nothing; all packages PASS, including the two new `HonoursLayout` tests and the four updated existing ones.

- [ ] **Step 13: Commit**

```bash
git add internal/layout internal/pr/pr.go internal/appstore cmd/app-wizard/main.go
git commit -m "fix(appstore): read the inventory from the configured layout, not apps/<stack>

The PR service wrote apps wherever LAYOUT said; the inventory hardcoded
apps/<stack>/<app>/app.yaml. With any other layout \"My apps\" listed nothing
and Edit/Decommission 404ed. One package now owns the template."
```

---

### Task 2: The removal PR body names the directory it deletes

**Files:**
- Modify: `internal/pr/pr.go:269` (call site), `internal/pr/pr.go` `removalBody` (the function following `prBody`)
- Test: `internal/pr/modes_test.go`

**Interfaces:**
- Consumes: `Service.appPaths` returning `appDir` (Task 1).
- Produces: `removalBody(req api.PRRequest, stack api.Stack, appDir string) string`.

- [ ] **Step 1: Write the failing test**

Append to `internal/pr/modes_test.go`:

```go
// The body of a removal PR is what a reviewer reads before approving a
// deletion. It must name the directory the commit actually removes.
func TestDeleteModeBodyNamesLayoutDir(t *testing.T) {
	v := fakeValidator{resp: api.ValidateResponse{Valid: true}}
	s := NewService(v, &render.FakeRenderer{}, fakeStacks{}, "main", "tenants/{stack}/apps/{app}", false)
	fp := gitprovider.NewFakeProvider()
	fp.Seed("main", "tenants/team-a/apps/myapp/app.yaml", []byte("kind: App\n"))
	fp.Seed("main", "tenants/team-a/apps/myapp/kustomization.yaml", []byte("kind: Kustomization\n"))
	fp.Seed("main", "tenants/team-a/apps/kustomization.yaml",
		[]byte("apiVersion: kustomize.config.k8s.io/v1beta1\nkind: Kustomization\nresources:\n- ./myapp\n"))

	req := newReq()
	req.Mode = "delete"
	if _, err := s.Create(context.Background(), fp, req); err != nil {
		t.Fatalf("delete: %v", err)
	}
	if len(fp.PRs) != 1 {
		t.Fatalf("expected 1 PR, got %d", len(fp.PRs))
	}
	body := fp.PRs[0].Body
	if !strings.Contains(body, "`tenants/team-a/apps/myapp/`") {
		t.Errorf("body does not name the deleted directory:\n%s", body)
	}
	if strings.Contains(body, "apps/team-a/myapp") {
		t.Errorf("body still names the default layout path:\n%s", body)
	}
}
```

Add `"github.com/Smana/app-wizard/internal/api"` and `"github.com/Smana/app-wizard/internal/render"` to the test file's imports if they are not already there (`pr_test.go` in the same package already imports both, so the compiler will tell you).

- [ ] **Step 2: Run to confirm it fails**

Run: `go test ./internal/pr/ -run TestDeleteModeBodyNamesLayoutDir -v`
Expected: FAIL — `body does not name the deleted directory` (the body says `apps/team-a/myapp/`).

- [ ] **Step 3: Fix the body**

In `internal/pr/pr.go`, change the `delete` call site (line 269) to:

```go
	return s.commitAndPR(ctx, provider, branch, files, commitMsg, title, removalBody(req, stack, appDir), nil)
```

and the function to:

```go
func removalBody(req api.PRRequest, stack api.Stack, appDir string) string {
	var sb strings.Builder
	fmt.Fprintf(&sb, "## Remove app: `%s`\n\n", req.AppName)
	fmt.Fprintf(&sb, "Decommission requested via the App Wizard.\n\n")
	fmt.Fprintf(&sb, "- **Stack**: `%s` (namespace `%s`, owner `%s`)\n", stack.Name, stack.Namespace, stack.OwnerTeam)
	fmt.Fprintf(&sb, "\nThis PR deletes `%s/` and removes its registration from the stack kustomization.\n", appDir)
	if req.Description != "" {
		fmt.Fprintf(&sb, "\n%s\n", req.Description)
	}
	return sb.String()
}
```

- [ ] **Step 4: Run the suite**

Run: `gofmt -l . && go vet ./... && go test -race ./...`
Expected: all PASS; `TestDeleteModeRemovesFilesAndParentEntry` (default layout) still passes because `appDir` is `apps/team-a/myapp` there.

- [ ] **Step 5: Commit, push, open the PR**

```bash
git add internal/pr
git commit -m "fix(pr): the removal PR body names the directory the layout resolves to"
git push -u origin fix/layout-inventory
gh pr create --base main --title "fix: the inventory and the removal PR body follow the configured layout" --body "$(cat <<'EOF'
Two bugs found reviewing v0.2.2:

- `internal/appstore` hardcoded `apps/<stack>/<app>/app.yaml`, so with any other `layout` the PR flow wrote apps to one path and "My apps" listed nothing; Edit and Decommission 404ed.
- The removal PR body hardcoded `apps/%s/%s/` and named a directory the commit did not touch.

A new `internal/layout` package owns the template; the PR service and the store both go through it. Tests cover a custom layout on both read paths and on the removal body.
EOF
)"
```

Wait for CI green, then merge (`gh pr merge --squash --delete-branch`). No release tag for this PR; v0.3.0 ships it together with Task 7.

---

### Task 3: `links` in the config loader

**Files:**
- Modify: `internal/config/config.go:118-132` (Config fields), `:142-171` (Load), `:292-296` (fileConfig)
- Test: `internal/config/config_test.go`

**Interfaces:**
- Produces: `config.Link{Label, URL string}`, `Config.Links []Link`, `validateLinks(links []Link) error`, `AllowedLinkPlaceholders = {"namespace","name","stack"}`.
- Consumed by: Task 4 (branding payload).

- [ ] **Step 1: Create the branch**

```bash
cd ~/Sources/app-wizard && git switch main && git pull --ff-only && git switch -c feat/links
```

- [ ] **Step 2: Write the failing tests**

Append to `internal/config/config_test.go`:

```go
// links: file-only list of {label,url}; url is a template over {namespace},
// {name}, {stack}. Validated at load so a typo fails at startup, not on click.
func TestLoad_Links(t *testing.T) {
	writeConfig(t, `
repo:
  owner: acme
  name: platform
schema:
  xrdPath: xrds/app.yaml
render:
  enabled: false
links:
  - label: Headlamp (aws-0)
    url: https://headlamp.example/c/main/apps/{namespace}/{name}
  - label: Runbook
    url: https://wiki.example/{stack}/{name}
`)
	cfg, err := Load()
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if len(cfg.Links) != 2 {
		t.Fatalf("Links = %+v, want 2", cfg.Links)
	}
	if cfg.Links[0].Label != "Headlamp (aws-0)" || cfg.Links[0].URL != "https://headlamp.example/c/main/apps/{namespace}/{name}" {
		t.Errorf("Links[0] = %+v", cfg.Links[0])
	}
}

func TestLoad_LinksAbsentIsEmpty(t *testing.T) {
	writeConfig(t, "repo:\n  owner: acme\n  name: platform\nschema:\n  xrdPath: xrds/app.yaml\nrender:\n  enabled: false\n")
	cfg, err := Load()
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if len(cfg.Links) != 0 {
		t.Errorf("Links = %+v, want none", cfg.Links)
	}
}

func TestLoad_LinksRejected(t *testing.T) {
	base := "repo:\n  owner: acme\n  name: platform\nschema:\n  xrdPath: xrds/app.yaml\nrender:\n  enabled: false\n"
	cases := map[string]struct{ links, want string }{
		"unknown placeholder": {"links:\n  - label: X\n    url: https://x.example/{cluster}/{name}\n", `{cluster}`},
		"relative url":        {"links:\n  - label: X\n    url: /apps/{name}\n", "absolute http"},
		"bad scheme":          {"links:\n  - label: X\n    url: ftp://x.example/{name}\n", "absolute http"},
		"empty label":         {"links:\n  - label: \"\"\n    url: https://x.example/{name}\n", "label"},
		"empty url":           {"links:\n  - label: X\n    url: \"\"\n", "url"},
	}
	for name, tc := range cases {
		t.Run(name, func(t *testing.T) {
			writeConfig(t, base+tc.links)
			_, err := Load()
			if err == nil {
				t.Fatalf("Load succeeded, want an error mentioning %q", tc.want)
			}
			if !strings.Contains(err.Error(), tc.want) {
				t.Errorf("error %q does not mention %q", err, tc.want)
			}
			if !strings.Contains(err.Error(), "links[0]") {
				t.Errorf("error %q does not name the entry", err)
			}
		})
	}
}
```

- [ ] **Step 3: Run to confirm they fail**

Run: `go test ./internal/config/ -run 'TestLoad_Links' -v`
Expected: `TestLoad_Links` FAILS at `Load` with `parse config ...: field links not found in type config.fileConfig` (strict decoding); the rejection cases fail for the same reason rather than the expected message.

- [ ] **Step 4: Implement**

In `internal/config/config.go`:

Add after the `BrandingTheme` field of `Config`:

```go
	// Links are operator-defined external links rendered on each app card
	// (file-only, `links:` in wizard.yaml). URL is a template over
	// {namespace}, {name} and {stack}; the SPA expands it per app. The wizard
	// holds no cluster credentials — a link is the only bridge to a live view.
	Links []Link
```

Add the type and validation (place them after `AssistsAvailable`):

```go
// Link is one external link shown on every app card. URL may contain the
// placeholders in AllowedLinkPlaceholders; nothing else is substituted.
type Link struct {
	Label string
	URL   string
}

// AllowedLinkPlaceholders are the only {tokens} a link URL may use. They are
// exactly what the inventory knows about an app without touching a cluster.
var AllowedLinkPlaceholders = map[string]bool{"namespace": true, "name": true, "stack": true}

var linkPlaceholder = regexp.MustCompile(`\{([^{}]*)\}`)

// validateLinks fails closed on the first bad entry, naming its index so the
// operator can find it in wizard.yaml.
func validateLinks(links []Link) error {
	for i, l := range links {
		if strings.TrimSpace(l.Label) == "" {
			return fmt.Errorf("links[%d]: label must not be empty", i)
		}
		if strings.TrimSpace(l.URL) == "" {
			return fmt.Errorf("links[%d] (%s): url must not be empty", i, l.Label)
		}
		u, err := url.Parse(l.URL)
		if err != nil || (u.Scheme != "http" && u.Scheme != "https") || u.Host == "" {
			return fmt.Errorf("links[%d] (%s): url %q must be an absolute http(s) URL", i, l.Label, l.URL)
		}
		for _, m := range linkPlaceholder.FindAllStringSubmatch(l.URL, -1) {
			if !AllowedLinkPlaceholders[m[1]] {
				return fmt.Errorf("links[%d] (%s): unknown placeholder {%s} — allowed: {namespace}, {name}, {stack}", i, l.Label, m[1])
			}
		}
	}
	return nil
}
```

Add `"net/url"` and `"regexp"` to the imports.

In `Load`, after `BrandingTheme: fc.Branding.Theme,` add:

```go
		Links:               fileLinks(fc.Links),
```

and after the `{app}` layout check add:

```go
	if err := validateLinks(cfg.Links); err != nil {
		return nil, fmt.Errorf("invalid links in config: %w", err)
	}
```

In `fileConfig`, after the `Branding` block add:

```go
	Links []struct {
		Label string `yaml:"label"`
		URL   string `yaml:"url"`
	} `yaml:"links"`
```

and add the converter next to `pick`:

```go
// fileLinks copies the file's link entries into the typed Config field.
func fileLinks(in []struct {
	Label string `yaml:"label"`
	URL   string `yaml:"url"`
}) []Link {
	out := make([]Link, 0, len(in))
	for _, l := range in {
		out = append(out, Link{Label: l.Label, URL: l.URL})
	}
	return out
}
```

Also delete the stale planning comment at lines 107–110 (`Introduced by the config-file layer (T005)...`) and replace it with `// --- Agnostic-deployment knobs (SPEC-009). ---`, since every field it mentions is wired.

- [ ] **Step 5: Run the config tests**

Run: `go test ./internal/config/ -v`
Expected: PASS, including the five `TestLoad_LinksRejected` subtests.

- [ ] **Step 6: Commit**

```bash
git add internal/config
git commit -m "feat(config): links — file-only external link templates, validated at load"
```

---

### Task 4: Links on the wire

**Files:**
- Modify: `internal/api/types.go:43-49` (Branding), `cmd/app-wizard/main.go:126-132`
- Create: `cmd/app-wizard/branding.go`, `cmd/app-wizard/branding_test.go`
- Modify: `ui/src/api/types.ts:20-25`, `ui/src/api/client.ts:91-97`

**Interfaces:**
- Consumes: `config.Link` (Task 3).
- Produces: `api.Link{Label string "label"; URL string "url"}`, `api.Branding.Links []Link "links"`, `brandingHandler(b api.Branding) http.HandlerFunc`; TS `Link {label; url}`, `Branding.links: Link[]`.

- [ ] **Step 1: Write the failing handler test**

`cmd/app-wizard/branding_test.go`:

```go
package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/Smana/app-wizard/internal/api"
)

func TestBrandingHandlerCarriesLinks(t *testing.T) {
	h := brandingHandler(api.Branding{
		Title: "Console",
		Links: []api.Link{{Label: "Headlamp", URL: "https://h.example/c/main/apps/{namespace}/{name}"}},
	})
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/api/branding", nil))
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d", rec.Code)
	}
	var got api.Branding
	if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if got.Title != "Console" || len(got.Links) != 1 || got.Links[0].URL != "https://h.example/c/main/apps/{namespace}/{name}" {
		t.Errorf("payload = %+v", got)
	}
}

func TestBrandingHandlerEmptyLinksIsArray(t *testing.T) {
	rec := httptest.NewRecorder()
	brandingHandler(api.Branding{Title: "X"}).ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/api/branding", nil))
	var raw map[string]json.RawMessage
	if err := json.Unmarshal(rec.Body.Bytes(), &raw); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if string(raw["links"]) != "[]" {
		t.Errorf("links = %s, want [] (never null — the SPA iterates it)", raw["links"])
	}
}
```

- [ ] **Step 2: Run to confirm it fails**

Run: `go test ./cmd/app-wizard/ -run TestBrandingHandler -v`
Expected: FAIL — `undefined: brandingHandler`.

- [ ] **Step 3: Implement the wire type and handler**

`internal/api/types.go`, replace the `Branding` struct:

```go
// Branding is the SPA chrome (GET /api/branding), all operator-configurable via
// wizard.yaml. Theme is a map of CSS custom properties (without the leading
// "--") applied to :root, so a deployment can restyle without a rebuild. Links
// are external URL templates the SPA expands per app ({namespace}, {name},
// {stack}); never null on the wire.
type Branding struct {
	Title   string            `json:"title"`
	LogoURL string            `json:"logoUrl"`
	Theme   map[string]string `json:"theme"`
	Links   []Link            `json:"links"`
}

// Link is one external link shown on every app card.
type Link struct {
	Label string `json:"label"`
	URL   string `json:"url"`
}
```

`cmd/app-wizard/branding.go`:

```go
package main

import (
	"net/http"

	"github.com/Smana/app-wizard/internal/api"
	"github.com/Smana/app-wizard/internal/config"
	"github.com/Smana/app-wizard/internal/httputil"
)

// brandingHandler serves GET /api/branding. Unauthenticated on purpose: the
// SPA needs the chrome before login. Links is coerced to an empty array so the
// client can iterate it without a null check.
func brandingHandler(b api.Branding) http.HandlerFunc {
	if b.Links == nil {
		b.Links = []api.Link{}
	}
	return func(w http.ResponseWriter, _ *http.Request) {
		httputil.WriteJSON(w, http.StatusOK, b)
	}
}

// brandingFromConfig maps the loaded config onto the wire type.
func brandingFromConfig(cfg *config.Config) api.Branding {
	out := api.Branding{
		Title:   cfg.BrandingTitle,
		LogoURL: cfg.BrandingLogoURL,
		Theme:   cfg.BrandingTheme,
		Links:   make([]api.Link, 0, len(cfg.Links)),
	}
	for _, l := range cfg.Links {
		out.Links = append(out.Links, api.Link{Label: l.Label, URL: l.URL})
	}
	return out
}
```

`cmd/app-wizard/main.go`, replace lines 126–132 with:

```go
	// Branding chrome for the SPA (title/logo/theme/links) — operator-configurable.
	mux.HandleFunc("GET /api/branding", brandingHandler(brandingFromConfig(cfg)))
```

Remove the now-unused `api` import from `main.go` only if the compiler reports it unused.

- [ ] **Step 4: Run Go tests**

Run: `gofmt -l . && go vet ./... && go test -race ./...`
Expected: PASS, both branding tests included.

- [ ] **Step 5: Mirror on the TypeScript side**

`ui/src/api/types.ts`, replace the `Branding` interface:

```ts
// Branding is the SPA chrome (title/logo/theme/links), configured per deployment.
export interface Branding {
  title: string;
  logoUrl: string;
  theme: Record<string, string>;
  // External URL templates expanded per app; see form/links.ts.
  links: Link[];
}

export interface Link {
  label: string;
  url: string;
}
```

`ui/src/api/client.ts`, the `getBranding` fallback becomes:

```ts
export function getBranding(): Promise<Branding> {
  return request<Branding>("/api/branding").catch(() => ({
    title: "App Wizard",
    logoUrl: "",
    theme: {},
    links: [],
  }));
}
```

`ui/src/App.tsx:24`, the initial state:

```ts
  const [branding, setBranding] = useState<Branding>({ title: "App Wizard", logoUrl: "", theme: {}, links: [] });
```

- [ ] **Step 6: Type-check and test the UI**

Run: `cd ui && npm run lint && npm test`
Expected: `tsc -b --noEmit` clean; all existing tests PASS.

- [ ] **Step 7: Commit**

```bash
git add internal/api/types.go cmd/app-wizard ui/src/api ui/src/App.tsx
git commit -m "feat(api): branding carries the configured links, never null"
```

---

### Task 5: Link expansion in the SPA

**Files:**
- Create: `ui/src/form/links.ts`, `ui/src/form/links.test.ts`

**Interfaces:**
- Produces: `expandLink(template: string, app: Pick<AppSummary, "namespace" | "name" | "stack">): string`.
- Consumed by: Task 6.

- [ ] **Step 1: Write the failing test**

`ui/src/form/links.test.ts`:

```ts
import { describe, expect, it } from "vitest";
import { expandLink } from "./links";

const app = { namespace: "demo", name: "podinfo", stack: "demo" };

describe("expandLink", () => {
  it("substitutes every allowed placeholder", () => {
    expect(expandLink("https://h.example/c/main/apps/{namespace}/{name}?s={stack}", app)).toBe(
      "https://h.example/c/main/apps/demo/podinfo?s=demo",
    );
  });

  it("substitutes a placeholder used twice", () => {
    expect(expandLink("https://x/{name}/{name}", app)).toBe("https://x/podinfo/podinfo");
  });

  it("URL-encodes values", () => {
    expect(expandLink("https://x/{name}", { ...app, name: "a b/c" })).toBe("https://x/a%20b%2Fc");
  });

  it("leaves a template with no placeholders untouched", () => {
    expect(expandLink("https://x/static", app)).toBe("https://x/static");
  });
});
```

- [ ] **Step 2: Run to confirm it fails**

Run: `cd ui && npx vitest run src/form/links.test.ts`
Expected: FAIL — cannot resolve `./links`.

- [ ] **Step 3: Implement**

`ui/src/form/links.ts`:

```ts
// Expands an operator-configured link template for one app. The backend has
// already validated that only these three placeholders occur, so anything
// else is left verbatim rather than guessed at.
import type { AppSummary } from "../api/types";

export type LinkTarget = Pick<AppSummary, "namespace" | "name" | "stack">;

export function expandLink(template: string, app: LinkTarget): string {
  const values: Record<string, string> = {
    namespace: app.namespace,
    name: app.name,
    stack: app.stack,
  };
  return template.replace(/\{(namespace|name|stack)\}/g, (_m, key: string) =>
    encodeURIComponent(values[key]),
  );
}
```

- [ ] **Step 4: Run the test**

Run: `cd ui && npx vitest run src/form/links.test.ts`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add ui/src/form/links.ts ui/src/form/links.test.ts
git commit -m "feat(ui): expandLink fills a link template for one app"
```

---

### Task 6: Cards with an open action

**Files:**
- Modify: `ui/src/form/AppList.tsx` (whole render block from line 135), `ui/src/form/AppList.test.tsx`, `ui/src/App.tsx:191`

**Interfaces:**
- Consumes: `expandLink` (Task 5), `Branding.links` (Task 4).
- Produces: `AppList` props `{ onEdit; links?: Link[] }`; test ids `app-card`, `app-open`, `app-open-menu`.

- [ ] **Step 1: Rewrite the test file**

Replace `ui/src/form/AppList.test.tsx` with:

```tsx
import { describe, expect, it, vi } from "vitest";
import { fireEvent, render, screen, waitFor } from "@testing-library/react";

vi.mock("../api/client", async (importOriginal) => {
  const actual = await importOriginal<typeof import("../api/client")>();
  return {
    ...actual,
    listApps: vi.fn().mockResolvedValue([
      { stack: "dev", name: "cinema", namespace: "dev-apps", image: "cinema:1.0", type: "web" },
      { stack: "prod", name: "reaper", namespace: "prod-apps", image: "reaper:2.1", type: "cron" },
    ]),
    openPR: vi.fn(),
  };
});

import { AppList } from "./AppList";

const headlamp = { label: "Headlamp (aws-0)", url: "https://h.example/c/main/apps/{namespace}/{name}" };
const runbook = { label: "Runbook", url: "https://wiki.example/{stack}/{name}" };

async function renderCards(links?: { label: string; url: string }[]) {
  render(<AppList onEdit={vi.fn()} links={links} />);
  await waitFor(() => {
    expect(screen.getAllByTestId("app-card")).toHaveLength(2);
  });
}

describe("AppList", () => {
  it("renders a card per app with edit and decommission", async () => {
    await renderCards();
    expect(screen.getByText("cinema")).toBeTruthy();
    expect(screen.getByText("reaper")).toBeTruthy();
    expect(screen.getAllByRole("button", { name: /Edit/i })).toHaveLength(2);
    expect(screen.getAllByRole("button", { name: /Decommission/i })).toHaveLength(2);
  });

  it("has no open action when no links are configured", async () => {
    await renderCards([]);
    expect(screen.queryByTestId("app-open")).toBeNull();
    expect(screen.queryByTestId("app-open-menu")).toBeNull();
  });

  it("with one link, the open action is a new-tab anchor expanded for the app", async () => {
    await renderCards([headlamp]);
    const opens = screen.getAllByTestId("app-open") as HTMLAnchorElement[];
    expect(opens).toHaveLength(2);
    expect(opens[0].getAttribute("href")).toBe("https://h.example/c/main/apps/dev-apps/cinema");
    expect(opens[0].getAttribute("target")).toBe("_blank");
    expect(opens[0].getAttribute("rel")).toContain("noopener");
    expect(opens[0].textContent).toContain("Headlamp (aws-0)");
  });

  it("with several links, the open action is a menu listing each label", async () => {
    await renderCards([headlamp, runbook]);
    const menus = screen.getAllByTestId("app-open-menu");
    expect(menus).toHaveLength(2);
    fireEvent.click(menus[0].querySelector("summary")!);
    const items = menus[0].querySelectorAll("a");
    expect(items).toHaveLength(2);
    expect(items[0].getAttribute("href")).toBe("https://h.example/c/main/apps/dev-apps/cinema");
    expect(items[1].getAttribute("href")).toBe("https://wiki.example/dev/cinema");
    expect(screen.queryByTestId("app-open")).toBeNull();
  });
});
```

- [ ] **Step 2: Run to confirm it fails**

Run: `cd ui && npx vitest run src/form/AppList.test.tsx`
Expected: FAIL — `app-card` never appears (the component still renders `app-row`), and TypeScript complains about the unknown `links` prop.

- [ ] **Step 3: Implement the cards**

In `ui/src/form/AppList.tsx`:

Change the imports and props:

```tsx
import type { AppSummary, Link, PRResponse } from "../api/types";
import { expandLink } from "./links";
```

```tsx
interface Props {
  // Called when a card's "Edit" action is triggered — parent fetches the detail
  // and swaps in the wizard.
  onEdit: (app: AppSummary) => void;
  // Operator-configured external links (from /api/branding). One link renders
  // as a direct open action; several render as a menu. None: cards stay inert.
  links?: Link[];
}

export function AppList({ onEdit, links = [] }: Props) {
```

Add, above the `return`, a small presentational component (keep it in this file; it has no other consumer):

```tsx
// The open action of one card. `<details>` gives a keyboard-accessible menu
// with no state to manage; the anchors open in a new tab and drop the opener.
function OpenAction({ app, links }: { app: AppSummary; links: Link[] }) {
  if (links.length === 0) return null;
  if (links.length === 1) {
    const l = links[0];
    return (
      <a
        data-testid="app-open"
        className={buttonVariants({ variant: "default", size: "sm" })}
        href={expandLink(l.url, app)}
        target="_blank"
        rel="noopener noreferrer"
      >
        Open in {l.label}
      </a>
    );
  }
  return (
    <details data-testid="app-open-menu" className="relative">
      <summary className={buttonVariants({ variant: "default", size: "sm" }) + " cursor-pointer list-none"}>
        Open ▾
      </summary>
      <ul className="absolute right-0 z-10 mt-1 min-w-48 rounded-md border border-border bg-card p-1 shadow-border">
        {links.map((l) => (
          <li key={l.label}>
            <a
              className="block rounded px-3 py-2 text-sm hover:bg-muted"
              href={expandLink(l.url, app)}
              target="_blank"
              rel="noopener noreferrer"
            >
              {l.label}
            </a>
          </li>
        ))}
      </ul>
    </details>
  );
}
```

`buttonVariants` is exported from `../components/ui/button` (the `cva` result used by `Button`); import it: `import { Button, buttonVariants } from "../components/ui/button";`. If `button.tsx` does not export it yet, add `export` in front of `const buttonVariants = cva(` in that file.

Replace the `{state === "loaded" && apps.length > 0 && ( <Card> ... </Card> )}` block with:

```tsx
      {state === "loaded" && apps.length > 0 && (
        <div className="space-y-3">
          <p className="text-sm text-muted-foreground">
            {apps.length} app{apps.length === 1 ? "" : "s"}
          </p>
          <ul className="grid grid-cols-1 gap-4 md:grid-cols-2 xl:grid-cols-3" aria-label="Apps">
            {apps.map((app) => (
              <li key={rowKey(app)}>
                <Card data-testid="app-card" className="flex h-full flex-col">
                  <CardHeader className="flex-row items-start justify-between gap-2 space-y-0">
                    <div className="min-w-0">
                      <CardTitle className="truncate">{app.name}</CardTitle>
                      <p className="mt-1 text-xs text-muted-foreground">
                        {app.stack} · {app.namespace}
                      </p>
                    </div>
                    <Badge variant="secondary">{app.type || "web"}</Badge>
                  </CardHeader>
                  <CardContent className="flex flex-1 flex-col justify-between gap-4">
                    <p className="truncate font-mono text-xs text-muted-foreground" title={app.image}>
                      {app.image}
                    </p>
                    <div className="flex flex-wrap items-center justify-between gap-2">
                      <OpenAction app={app} links={links} />
                      <div className="ml-auto flex items-center gap-2">
                        <Button type="button" variant="outline" size="sm" onClick={() => onEdit(app)}>
                          Edit
                        </Button>
                        <Button
                          type="button"
                          variant="destructive"
                          size="sm"
                          disabled={decommissioning === rowKey(app)}
                          onClick={() => onDecommission(app)}
                        >
                          {decommissioning === rowKey(app) ? "Decommissioning…" : "Decommission"}
                        </Button>
                      </div>
                    </div>
                  </CardContent>
                </Card>
              </li>
            ))}
          </ul>
        </div>
      )}
```

Update the file's header comment: `Lists apps declared across all stacks as cards and offers Edit / Decommission, plus the operator-configured open links, per card.`

`ui/src/App.tsx:191`:

```tsx
            <AppList onEdit={onEditApp} links={branding.links} />
```

- [ ] **Step 4: Run the UI tests and type-check**

Run: `cd ui && npm run lint && npm test`
Expected: PASS — 4 `AppList` tests, the `links` tests, and every pre-existing test.

- [ ] **Step 5: Look at it**

Run: `cd ~/Sources/app-wizard && make dev` then open `http://localhost:8080`, sign in (dev auth), click **My apps**. The example config has no `links`, so cards show Edit and Decommission only. Add to `examples/wizard.yaml` temporarily:

```yaml
links:
  - label: Headlamp (example)
    url: https://headlamp.example/c/main/apps/{namespace}/{name}
```

restart, and confirm each card shows **Open in Headlamp (example)** pointing at the expanded URL. Revert the temporary edit (Task 7 adds the documented, commented version).

- [ ] **Step 6: Commit**

```bash
git add ui/src/form/AppList.tsx ui/src/form/AppList.test.tsx ui/src/App.tsx ui/src/components/ui/button.tsx
git commit -m "feat(ui): My apps as cards, each with the configured open links"
```

---

### Task 7: Documentation, release v0.3.0

**Files:**
- Modify: `docs/configuration.md:44-61` (table), `examples/wizard.yaml:37-42`, `README.md` (one sentence in the features list, wherever the inventory is described)

- [ ] **Step 1: Document the key**

Append to the table in `docs/configuration.md` (after the `branding.theme` row):

```markdown
| `links` | — (file-only) | — | List of `{label, url}` shown on every card of "My apps". `url` is a template over `{namespace}`, `{name}`, `{stack}`, expanded per app and opened in a new tab. Must be absolute `http(s)`; any other placeholder fails startup. One entry renders as a direct button, several as a menu |
```

Add after the table (before `Other environment-only knobs`):

````markdown
Example — one entry per cluster when the same stacks deploy to several:

```yaml
links:
  - label: Headlamp (aws-0)
    url: https://headlamp.priv.aws.example/c/main/apps/{namespace}/{name}
  - label: Headlamp (gcp-0)
    url: https://headlamp.priv.gcp.example/c/main/apps/{namespace}/{name}
```

The wizard never contacts a cluster; the link is the whole bridge to a live view.
````

`examples/wizard.yaml`, after the `branding` block:

```yaml
# External links shown on each app card (optional, file-only). The URL is a
# template over {namespace}, {name}, {stack}; anything else fails startup.
# links:
#   - label: Headlamp
#     url: https://headlamp.example/c/main/apps/{namespace}/{name}
```

`README.md`: where the inventory ("My apps") is described, add the sentence: *Each card can carry operator-configured links (for example to a Headlamp view of the running app); see `docs/configuration.md` → `links`.*

- [ ] **Step 2: Full verification**

Run: `gofmt -l . ; go vet ./... && go test -race ./... && cd ui && npm ci && npm run lint && npm test && npm run build`
Expected: nothing from `gofmt -l`; every Go and UI test PASS; `vite build` writes `internal/web/dist`.

- [ ] **Step 3: Commit, push, PR**

```bash
git add docs/configuration.md examples/wizard.yaml README.md internal/web/dist
git commit -m "docs: the links key, with a per-cluster example"
git push -u origin feat/links
gh pr create --base main --title "feat: configurable links on app cards" --body "$(cat <<'EOF'
Adds a file-only `links` list to `wizard.yaml`: `{label, url}` entries whose URL is a template over `{namespace}`, `{name}`, `{stack}`, validated at startup (absolute http(s), known placeholders only). The branding payload carries them; "My apps" becomes a card grid where each card opens the expanded link in a new tab (one link: a button; several: a menu; none: unchanged).

The wizard still holds no cluster credentials — the link is the whole bridge to a live view. First consumer: a Headlamp App page, see cloud-native-ref `docs/superpowers/specs/2026-09-09-headlamp-app-view-design.md`.
EOF
)"
```

- [ ] **Step 4: Merge and release**

After CI is green and the PR is merged:

```bash
git switch main && git pull --ff-only
git tag -a v0.3.0 -m "v0.3.0: configurable links on app cards; inventory follows the layout"
git push origin v0.3.0
gh run watch --exit-status "$(gh run list --workflow build.yml --event push --limit 1 --json databaseId --jq '.[0].databaseId')"
docker manifest inspect ghcr.io/smana/app-wizard:v0.3.0 > /dev/null && echo "v0.3.0 published"
```

Expected: the build workflow succeeds and `docker manifest inspect` exits 0. Record the tag in the platform plan's Task 7 (the pin bump).

---

## Self-review

- **Spec coverage.** Config key, validation rules, file-only, placeholders (Task 3); branding payload (Task 4); card grid, one-link anchor, several-link menu, none inert (Task 6); docs and example (Task 7); stage 1 bug fixes (Tasks 1–2); release v0.3.0 (Task 7). Nothing in the spec's wizard section is left without a task.
- **Placeholders.** None: every step carries its code or its command.
- **Type consistency.** `config.Link` → `api.Link` → TS `Link`; `appstore.New(stacks, ref, layout)` used identically in Task 1 tests and `main.go`; `removalBody(req, stack, appDir)` matches its call site; `expandLink(template, app)` signature identical in Tasks 5 and 6; test ids `app-card`, `app-open`, `app-open-menu` identical in component and tests.
