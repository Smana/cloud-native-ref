// Package pr assembles the create-app pull request (FR-005, T106): it generates
// the three files (app.yaml, kustomization.yaml, and an idempotent parent
// kustomization edit), runs the validate + render gates (FR-007), then commits
// as the user, opens the PR, and posts a render-preview comment (FR-008).
package pr

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"path"
	"strings"

	"github.com/Smana/cloud-native-ref/container-images/app-wizard/internal/api"
	"github.com/Smana/cloud-native-ref/container-images/app-wizard/internal/gitprovider"
	"github.com/Smana/cloud-native-ref/container-images/app-wizard/internal/render"
)

// Validator runs the pre-submit gates.
type Validator interface {
	Validate(ctx context.Context, spec map[string]any) (api.ValidateResponse, error)
}

// StackResolver resolves a stack name to its registry entry.
type StackResolver interface {
	Stack(ctx context.Context, name string) (api.Stack, bool, error)
}

// GateError signals that the validate/render gates failed; the handler maps it
// to HTTP 422 and no branch/PR is created (FR-007).
type GateError struct {
	Message  string
	Validate *api.ValidateResponse
}

func (e *GateError) Error() string { return e.Message }

// Service opens create PRs.
type Service struct {
	validator  Validator
	renderer   render.Renderer
	stacks     StackResolver
	baseBranch string
}

// NewService builds the PR service.
func NewService(validator Validator, renderer render.Renderer, stacks StackResolver, baseBranch string) *Service {
	return &Service{validator: validator, renderer: renderer, stacks: stacks, baseBranch: baseBranch}
}

// Create runs the requested operation (create/update/delete) and, on success,
// creates the branch/files/PR/comment as the user behind provider. It returns a
// *GateError when a gate blocks the PR. Mode selects the operation; "" defaults
// to "create".
func (s *Service) Create(ctx context.Context, provider gitprovider.Provider, req api.PRRequest) (api.PRResponse, error) {
	if req.AppName == "" {
		return api.PRResponse{}, &GateError{Message: "appName is required"}
	}
	if req.Stack == "" {
		return api.PRResponse{}, &GateError{Message: "stack is required"}
	}

	stack, ok, err := s.stacks.Stack(ctx, req.Stack)
	if err != nil {
		return api.PRResponse{}, fmt.Errorf("resolve stack: %w", err)
	}
	if !ok {
		return api.PRResponse{}, &GateError{Message: fmt.Sprintf("unknown stack %q", req.Stack)}
	}

	switch req.Mode {
	case "", "create":
		return s.create(ctx, provider, req, stack)
	case "update":
		return s.update(ctx, provider, req, stack)
	case "delete":
		return s.delete(ctx, provider, req, stack)
	default:
		return api.PRResponse{}, &GateError{Message: fmt.Sprintf("unknown mode %q (want create|update|delete)", req.Mode)}
	}
}

// appPaths returns the app.yaml, app kustomization.yaml, and parent
// kustomization.yaml paths for a stack/app.
func appPaths(stack, app string) (appPath, kustPath, parentKustPath string) {
	appDir := path.Join("apps", stack, app)
	return path.Join(appDir, "app.yaml"),
		path.Join(appDir, "kustomization.yaml"),
		path.Join("apps", stack, "kustomization.yaml")
}

// create is the default new-app flow (three files). It refuses to clobber an
// existing app (US-1.3): if apps/<stack>/<app>/app.yaml exists at base, it
// returns a GateError directing the user to edit instead.
func (s *Service) create(ctx context.Context, provider gitprovider.Provider, req api.PRRequest, stack api.Stack) (api.PRResponse, error) {
	appPath, kustPath, parentKustPath := appPaths(req.Stack, req.AppName)

	// Guard: don't overwrite an existing app.
	if _, _, err := provider.ReadFile(ctx, s.baseBranch, appPath); err == nil {
		return api.PRResponse{}, &GateError{
			Message: fmt.Sprintf("app %q already exists in stack %q — edit it instead", req.AppName, req.Stack),
		}
	} else if err != gitprovider.ErrNotFound {
		return api.PRResponse{}, fmt.Errorf("check existing app: %w", err)
	}

	// Gate 1: schema + CEL + secret validation.
	vr, err := s.validator.Validate(ctx, req.Spec)
	if err != nil {
		return api.PRResponse{}, fmt.Errorf("validate: %w", err)
	}
	if !vr.Valid {
		return api.PRResponse{}, &GateError{Message: "validation failed", Validate: &vr}
	}

	// Build claim + gate 2: render.
	claimYAML, err := BuildClaimYAML(req.AppName, stack.Namespace, req.Spec)
	if err != nil {
		return api.PRResponse{}, err
	}
	resources, err := s.renderer.Render(ctx, claimYAML)
	if err != nil {
		return api.PRResponse{}, &GateError{Message: "render failed: " + err.Error()}
	}

	kustYAML, err := BuildKustomizationYAML()
	if err != nil {
		return api.PRResponse{}, err
	}

	// Idempotent parent kustomization edit.
	existingParent, _, err := provider.ReadFile(ctx, s.baseBranch, parentKustPath)
	if err != nil && err != gitprovider.ErrNotFound {
		return api.PRResponse{}, fmt.Errorf("read parent kustomization: %w", err)
	}
	parentYAML, _, err := AddResourceToKustomization(existingParent, "./"+req.AppName)
	if err != nil {
		return api.PRResponse{}, err
	}

	files := []gitprovider.File{
		{Path: appPath, Content: claimYAML},
		{Path: kustPath, Content: kustYAML},
		{Path: parentKustPath, Content: parentYAML},
	}

	branch := branchName("create", req.Stack, req.AppName)
	commitMsg := fmt.Sprintf("feat(apps): add %s to %s stack", req.AppName, req.Stack)
	title := fmt.Sprintf("feat(apps): deploy %s to %s", req.AppName, req.Stack)
	return s.commitAndPR(ctx, provider, branch, files, commitMsg, title, prBody(req, stack), resources)
}

// update edits an existing app via a structure-preserving patch of its
// app.yaml. It requires the app to exist, runs the same validate + render gates,
// and commits ONLY app.yaml (kustomizations already exist).
func (s *Service) update(ctx context.Context, provider gitprovider.Provider, req api.PRRequest, stack api.Stack) (api.PRResponse, error) {
	appPath, _, _ := appPaths(req.Stack, req.AppName)

	existing, _, err := provider.ReadFile(ctx, s.baseBranch, appPath)
	if err == gitprovider.ErrNotFound {
		return api.PRResponse{}, &GateError{
			Message: fmt.Sprintf("app %q not found in stack %q", req.AppName, req.Stack),
		}
	} else if err != nil {
		return api.PRResponse{}, fmt.Errorf("read existing app: %w", err)
	}

	// Gate 1: schema + CEL + secret validation.
	vr, err := s.validator.Validate(ctx, req.Spec)
	if err != nil {
		return api.PRResponse{}, fmt.Errorf("validate: %w", err)
	}
	if !vr.Valid {
		return api.PRResponse{}, &GateError{Message: "validation failed", Validate: &vr}
	}

	// Structure-preserving patch (SC-005): only changed fields diff.
	patched, err := PatchClaimYAML(existing, req.Spec)
	if err != nil {
		return api.PRResponse{}, err
	}

	// Gate 2: render the patched claim.
	resources, err := s.renderer.Render(ctx, patched)
	if err != nil {
		return api.PRResponse{}, &GateError{Message: "render failed: " + err.Error()}
	}

	files := []gitprovider.File{{Path: appPath, Content: patched}}

	branch := branchName("update", req.Stack, req.AppName)
	commitMsg := fmt.Sprintf("chore(apps): update %s in %s", req.AppName, req.Stack)
	title := fmt.Sprintf("chore(apps): update %s in %s", req.AppName, req.Stack)
	return s.commitAndPR(ctx, provider, branch, files, commitMsg, title, prBody(req, stack), resources)
}

// delete produces a removal PR: it deletes app.yaml + the app kustomization and
// removes the "./<app>" entry from the parent kustomization. No validate/render
// gates run for a removal.
func (s *Service) delete(ctx context.Context, provider gitprovider.Provider, req api.PRRequest, stack api.Stack) (api.PRResponse, error) {
	appPath, kustPath, parentKustPath := appPaths(req.Stack, req.AppName)

	if _, _, err := provider.ReadFile(ctx, s.baseBranch, appPath); err == gitprovider.ErrNotFound {
		return api.PRResponse{}, &GateError{
			Message: fmt.Sprintf("app %q not found in stack %q", req.AppName, req.Stack),
		}
	} else if err != nil {
		return api.PRResponse{}, fmt.Errorf("read existing app: %w", err)
	}

	existingParent, _, err := provider.ReadFile(ctx, s.baseBranch, parentKustPath)
	if err != nil && err != gitprovider.ErrNotFound {
		return api.PRResponse{}, fmt.Errorf("read parent kustomization: %w", err)
	}
	parentYAML, _, err := RemoveResourceFromKustomization(existingParent, "./"+req.AppName)
	if err != nil {
		return api.PRResponse{}, err
	}

	files := []gitprovider.File{
		{Path: appPath, Delete: true},
		{Path: kustPath, Delete: true},
		{Path: parentKustPath, Content: parentYAML},
	}

	branch := branchName("remove", req.Stack, req.AppName)
	commitMsg := fmt.Sprintf("chore(apps): remove %s from %s", req.AppName, req.Stack)
	title := fmt.Sprintf("chore(apps): remove %s from %s", req.AppName, req.Stack)
	return s.commitAndPR(ctx, provider, branch, files, commitMsg, title, removalBody(req, stack), nil)
}

// commitAndPR creates the branch, commits files, opens the PR, and (when
// resources are given) posts a render-preview comment.
func (s *Service) commitAndPR(ctx context.Context, provider gitprovider.Provider, branch string, files []gitprovider.File, commitMsg, title, body string, resources []api.RenderedResource) (api.PRResponse, error) {
	if err := provider.CreateBranch(ctx, s.baseBranch, branch); err != nil {
		return api.PRResponse{}, fmt.Errorf("create branch: %w", err)
	}
	if err := provider.CommitFiles(ctx, branch, files, commitMsg); err != nil {
		return api.PRResponse{}, fmt.Errorf("commit files: %w", err)
	}

	pull, err := provider.OpenPR(ctx, s.baseBranch, branch, title, body)
	if err != nil {
		return api.PRResponse{}, fmt.Errorf("open PR: %w", err)
	}

	if resources != nil {
		if comment := renderComment(resources); comment != "" {
			if err := provider.CommentPR(ctx, pull.Number, comment); err != nil {
				// Non-fatal: the PR exists; surface via logs at the caller.
				return api.PRResponse{URL: pull.URL, Number: pull.Number, Branch: branch},
					fmt.Errorf("post render comment: %w", err)
			}
		}
	}

	return api.PRResponse{URL: pull.URL, Number: pull.Number, Branch: branch}, nil
}

func branchName(op, stack, app string) string {
	return fmt.Sprintf("wizard/%s-%s-%s-%s", op, stack, app, shortID())
}

func shortID() string {
	b := make([]byte, 4)
	if _, err := rand.Read(b); err != nil {
		return "00000000"
	}
	return hex.EncodeToString(b)
}

func prBody(req api.PRRequest, stack api.Stack) string {
	var sb strings.Builder
	fmt.Fprintf(&sb, "## App: `%s`\n\n", req.AppName)
	fmt.Fprintf(&sb, "Opened via the App Wizard.\n\n")
	fmt.Fprintf(&sb, "- **Stack**: `%s` (namespace `%s`, owner `%s`)\n", stack.Name, stack.Namespace, stack.OwnerTeam)
	if req.Description != "" {
		fmt.Fprintf(&sb, "\n%s\n", req.Description)
	}
	return sb.String()
}

func removalBody(req api.PRRequest, stack api.Stack) string {
	var sb strings.Builder
	fmt.Fprintf(&sb, "## Remove app: `%s`\n\n", req.AppName)
	fmt.Fprintf(&sb, "Decommission requested via the App Wizard.\n\n")
	fmt.Fprintf(&sb, "- **Stack**: `%s` (namespace `%s`, owner `%s`)\n", stack.Name, stack.Namespace, stack.OwnerTeam)
	fmt.Fprintf(&sb, "\nThis PR deletes `apps/%s/%s/` and removes its registration from the stack kustomization.\n", req.Stack, req.AppName)
	if req.Description != "" {
		fmt.Fprintf(&sb, "\n%s\n", req.Description)
	}
	return sb.String()
}

func renderComment(resources []api.RenderedResource) string {
	if len(resources) == 0 {
		return "### Render preview\n\nNo resources rendered."
	}
	var sb strings.Builder
	sb.WriteString("### Render preview\n\nThis claim will create the following resources:\n\n")
	sb.WriteString("| Kind | Name | Role |\n|---|---|---|\n")
	for _, r := range resources {
		fmt.Fprintf(&sb, "| %s | %s | %s |\n", r.Kind, r.Name, r.Role)
	}
	return sb.String()
}
