package main

import (
	"context"
	"dagger/cloud-native-ref/internal/dagger"
	"fmt"
)

func createNetwork(ctx context.Context, ctr *dagger.Container, apply bool) (map[string]interface{}, error) {
	workDir := "/cloud-native-ref/terraform/network"

	// Firts we need to import Tailscale ACLs due to a bug in the Terraform provider
	cmd := []string{"tofu", "import", "--var-file", "variables.tfvars", "tailscale_acl.this", "acl"}
	_, err := ctr.WithWorkdir(workDir).WithExec(cmd).Stdout(ctx)
	if err != nil {
		return nil, fmt.Errorf("failed to import the Tailscale ACLs: %w", err)
	}

	output, err := tfRun(ctx, ctr, workDir, apply, []string{"-var-file", "variables.tfvars"})
	if err != nil {
		return nil, fmt.Errorf("failed to create the network: %w", err)
	}
	return output, nil
}
