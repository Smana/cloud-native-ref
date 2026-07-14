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

// Create runs the gates and, on success, creates the branch/files/PR/comment as
// the user behind provider. It returns a *GateError when a gate blocks the PR.
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

	// Generate the three files.
	appDir := path.Join("apps", req.Stack, req.AppName)
	appPath := path.Join(appDir, "app.yaml")
	kustPath := path.Join(appDir, "kustomization.yaml")
	parentKustPath := path.Join("apps", req.Stack, "kustomization.yaml")

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

	// Create branch, commit, open PR, comment.
	branch := branchName(req.Stack, req.AppName)
	if err := provider.CreateBranch(ctx, s.baseBranch, branch); err != nil {
		return api.PRResponse{}, fmt.Errorf("create branch: %w", err)
	}
	commitMsg := fmt.Sprintf("feat(apps): add %s to %s stack", req.AppName, req.Stack)
	if err := provider.CommitFiles(ctx, branch, files, commitMsg); err != nil {
		return api.PRResponse{}, fmt.Errorf("commit files: %w", err)
	}

	title := fmt.Sprintf("feat(apps): deploy %s to %s", req.AppName, req.Stack)
	body := prBody(req, stack)
	pull, err := provider.OpenPR(ctx, s.baseBranch, branch, title, body)
	if err != nil {
		return api.PRResponse{}, fmt.Errorf("open PR: %w", err)
	}

	if comment := renderComment(resources); comment != "" {
		if err := provider.CommentPR(ctx, pull.Number, comment); err != nil {
			// Non-fatal: the PR exists; surface via logs at the caller.
			return api.PRResponse{URL: pull.URL, Number: pull.Number, Branch: branch},
				fmt.Errorf("post render comment: %w", err)
		}
	}

	return api.PRResponse{URL: pull.URL, Number: pull.Number, Branch: branch}, nil
}

func branchName(stack, app string) string {
	return fmt.Sprintf("wizard/%s-%s-%s", stack, app, shortID())
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
