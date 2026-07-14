// Package appstore reads the App claim inventory from the GitOps repo via a
// gitprovider (SPEC-008 Phase 2, T201/T202). It walks apps/<stack>/*/app.yaml
// for every stack in the registry and exposes a single app for editing.
package appstore

import (
	"context"
	"fmt"
	"path"
	"sort"
	"strings"

	"github.com/Smana/cloud-native-ref/container-images/app-wizard/internal/api"
	"github.com/Smana/cloud-native-ref/container-images/app-wizard/internal/gitprovider"
	"sigs.k8s.io/yaml"
)

// StackLister lists the deployable stacks (satisfied by *schema.Pipeline via
// Stacks). It is the seam so the store never imports the pipeline directly.
type StackLister interface {
	Stacks(ctx context.Context) ([]api.Stack, error)
}

// Store reads app inventory from a repo ref.
type Store struct {
	stacks StackLister
	ref    string // base branch/ref to read from
}

// New builds a Store reading from ref (typically the repo base branch).
func New(stacks StackLister, ref string) *Store {
	return &Store{stacks: stacks, ref: ref}
}

// List walks every stack for apps/<stack>/<app>/app.yaml and returns a summary
// for each. Stacks or apps that can't be read are skipped (best-effort listing);
// a missing apps/<stack> directory is not an error.
func (s *Store) List(ctx context.Context, provider gitprovider.Provider) ([]api.AppSummary, error) {
	stacks, err := s.stacks.Stacks(ctx)
	if err != nil {
		return nil, fmt.Errorf("list stacks: %w", err)
	}

	var out []api.AppSummary
	for _, stack := range stacks {
		prefix := path.Join("apps", stack.Name)
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
	}

	sort.Slice(out, func(i, j int) bool {
		if out[i].Stack != out[j].Stack {
			return out[i].Stack < out[j].Stack
		}
		return out[i].Name < out[j].Name
	})
	return out, nil
}

// Get loads a single app for editing. Returns gitprovider.ErrNotFound when the
// app.yaml is absent.
func (s *Store) Get(ctx context.Context, provider gitprovider.Provider, stack, name string) (api.AppDetail, error) {
	appPath := path.Join("apps", stack, name, "app.yaml")
	content, _, err := provider.ReadFile(ctx, s.ref, appPath)
	if err != nil {
		return api.AppDetail{}, err
	}

	var claim map[string]any
	if err := yaml.Unmarshal(content, &claim); err != nil {
		return api.AppDetail{}, fmt.Errorf("parse %q: %w", appPath, err)
	}
	spec, _ := claim["spec"].(map[string]any)
	if spec == nil {
		spec = map[string]any{}
	}
	return api.AppDetail{
		Stack:   stack,
		Name:    name,
		Spec:    spec,
		RawYAML: string(content),
	}, nil
}

// summaryFromClaim parses an app.yaml claim into an AppSummary. It returns ok
// false when the document is not an App claim (no parseable spec/metadata).
func summaryFromClaim(stack api.Stack, appName string, content []byte) (api.AppSummary, bool) {
	var claim map[string]any
	if err := yaml.Unmarshal(content, &claim); err != nil {
		return api.AppSummary{}, false
	}

	name := appName
	namespace := stack.Namespace
	if meta, ok := claim["metadata"].(map[string]any); ok {
		if n, ok := meta["name"].(string); ok && n != "" {
			name = n
		}
		if ns, ok := meta["namespace"].(string); ok && ns != "" {
			namespace = ns
		}
	}

	spec, _ := claim["spec"].(map[string]any)

	appType := "web"
	if t, ok := spec["type"].(string); ok && t != "" {
		appType = t
	}

	return api.AppSummary{
		Stack:     stack.Name,
		Name:      name,
		Namespace: namespace,
		Image:     imageString(spec),
		Type:      appType,
	}, true
}

// imageString renders spec.image as "repository[:tag]".
func imageString(spec map[string]any) string {
	img, ok := spec["image"].(map[string]any)
	if !ok {
		return ""
	}
	repo, _ := img["repository"].(string)
	if repo == "" {
		return ""
	}
	tag, _ := img["tag"].(string)
	if tag == "" {
		return repo
	}
	return strings.Join([]string{repo, tag}, ":")
}
