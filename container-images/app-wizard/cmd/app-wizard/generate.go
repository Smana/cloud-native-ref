package main

import (
	"context"
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"

	"sigs.k8s.io/yaml"

	"github.com/Smana/cloud-native-ref/container-images/app-wizard/internal/config"
	"github.com/Smana/cloud-native-ref/container-images/app-wizard/internal/pr"
	"github.com/Smana/cloud-native-ref/container-images/app-wizard/internal/render"
	"github.com/Smana/cloud-native-ref/container-images/app-wizard/internal/schema"
	"github.com/Smana/cloud-native-ref/container-images/app-wizard/internal/validate"
)

// runGenerate implements `app-wizard generate` — the offline dry-run of the PR
// flow. It runs the exact same schema → validate → (optional) render → file
// generation the server uses, but writes the three files locally instead of
// opening a GitHub PR. No GitHub token, no cluster, no OAuth required.
//
// Usage:
//
//	app-wizard generate -stack platform -name my-api -spec spec.yaml [-out dir] [-render]
func runGenerate(args []string) error {
	fs := flag.NewFlagSet("generate", flag.ContinueOnError)
	var (
		stackName = fs.String("stack", "", "target stack (from apps/stacks.yaml) — required")
		appName   = fs.String("name", "", "application name — required")
		specPath  = fs.String("spec", "", "path to the App .spec as YAML/JSON, or '-' for stdin — required")
		outDir    = fs.String("out", "", "directory to write files into (default: print to stdout)")
		repoRoot  = fs.String("repo-root", "", "repository root (default: auto-detected / REPO_ROOT)")
		doRender  = fs.Bool("render", false, "run the crossplane render gate (needs docker + the crossplane CLI)")
		descr     = fs.String("description", "", "optional description (mirrors the PR body)")
	)
	if err := fs.Parse(args); err != nil {
		return err
	}
	if *stackName == "" || *appName == "" || *specPath == "" {
		fs.Usage()
		return fmt.Errorf("-stack, -name and -spec are required")
	}

	cfg, err := config.Load()
	if err != nil {
		return fmt.Errorf("load config: %w", err)
	}
	root := cfg.RepoRoot
	if *repoRoot != "" {
		root = *repoRoot
	}

	// Read the spec (YAML or JSON) into a generic map.
	var raw []byte
	if *specPath == "-" {
		raw, err = io.ReadAll(os.Stdin)
	} else {
		raw, err = os.ReadFile(*specPath)
	}
	if err != nil {
		return fmt.Errorf("read spec: %w", err)
	}
	var spec map[string]any
	if err := yaml.Unmarshal(raw, &spec); err != nil {
		return fmt.Errorf("parse spec: %w", err)
	}

	ctx := context.Background()

	// Same components the server wires, but with a LocalSource (offline).
	src := schema.NewLocalSource(root)
	pipeline := schema.NewPipeline(src, cfg.XRDPath, cfg.StacksPath, cfg.UIHintsPath)
	if _, err := pipeline.Build(ctx); err != nil {
		return fmt.Errorf("build schema (is -repo-root correct?): %w", err)
	}
	validator := validate.NewValidator(pipeline)

	// Resolve the stack → namespace.
	stack, ok, err := pipeline.Stack(ctx, *stackName)
	if err != nil {
		return fmt.Errorf("resolve stack: %w", err)
	}
	if !ok {
		return fmt.Errorf("unknown stack %q — see apps/stacks.yaml", *stackName)
	}

	// Gate 1: schema + CEL + secret validation (same as the server).
	vr, err := validator.Validate(ctx, spec)
	if err != nil {
		return fmt.Errorf("validate: %w", err)
	}
	if !vr.Valid {
		fmt.Fprintln(os.Stderr, "✗ validation failed:")
		for _, e := range vr.SchemaErrors {
			fmt.Fprintf(os.Stderr, "  - %s: %s\n", e.Path, e.Message)
		}
		for _, c := range vr.CELViolations {
			fmt.Fprintf(os.Stderr, "  - CEL: %s\n", c.Message)
		}
		for _, s := range vr.SecretFindings {
			fmt.Fprintf(os.Stderr, "  - secret: %s (%s)\n", s.Path, s.Reason)
		}
		return fmt.Errorf("spec is invalid")
	}

	// Build the claim.
	claimYAML, err := pr.BuildClaimYAML(*appName, stack.Namespace, spec)
	if err != nil {
		return fmt.Errorf("build claim: %w", err)
	}

	// Gate 2 (optional): crossplane render preview.
	if *doRender {
		renderer := render.NewCrossplaneRenderer(root, cfg.CompositionPath, cfg.FunctionsPath, cfg.EnvConfigPath)
		resources, err := renderer.Render(ctx, claimYAML)
		if err != nil {
			return fmt.Errorf("render gate failed: %w", err)
		}
		fmt.Fprintf(os.Stderr, "✓ render preview — %d resources:\n", len(resources))
		for _, r := range resources {
			fmt.Fprintf(os.Stderr, "  - %s/%s  %s\n", r.Kind, r.Name, r.Role)
		}
	}

	// Generate the kustomization + idempotent parent edit (read parent from disk).
	kustYAML, err := pr.BuildKustomizationYAML()
	if err != nil {
		return err
	}
	parentRel := filepath.Join("apps", *stackName, "kustomization.yaml")
	existingParent, _ := os.ReadFile(filepath.Join(root, parentRel))
	parentYAML, added, err := pr.AddResourceToKustomization(existingParent, "./"+*appName)
	if err != nil {
		return fmt.Errorf("parent kustomization: %w", err)
	}

	appDirRel := filepath.Join("apps", *stackName, *appName)
	outputs := []struct {
		path    string
		content []byte
	}{
		{filepath.Join(appDirRel, "app.yaml"), claimYAML},
		{filepath.Join(appDirRel, "kustomization.yaml"), kustYAML},
		{parentRel, parentYAML},
	}

	if *outDir == "" {
		for _, o := range outputs {
			fmt.Printf("# ---------- %s ----------\n%s\n", o.path, o.content)
		}
		fmt.Fprintf(os.Stderr, "\n✓ generated 3 files for %s/%s (stack ns=%s). Parent kustomization %s.\n",
			*stackName, *appName, stack.Namespace, addedNote(added))
		if *descr != "" {
			fmt.Fprintf(os.Stderr, "  description: %s\n", *descr)
		}
		return nil
	}

	for _, o := range outputs {
		dst := filepath.Join(*outDir, o.path)
		if err := os.MkdirAll(filepath.Dir(dst), 0o755); err != nil {
			return err
		}
		if err := os.WriteFile(dst, o.content, 0o644); err != nil {
			return err
		}
		fmt.Fprintf(os.Stderr, "wrote %s\n", dst)
	}
	fmt.Fprintf(os.Stderr, "✓ generated 3 files under %s (parent kustomization %s)\n", *outDir, addedNote(added))
	return nil
}

func addedNote(added bool) string {
	if added {
		return "updated (app registered)"
	}
	return "unchanged (already registered)"
}
