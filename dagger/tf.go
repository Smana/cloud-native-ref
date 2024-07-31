package main

import (
	"context"
	"dagger/cloud-native-ref/internal/dagger"
	"fmt"
)

// tfRun applies the terraform configuration
func tfRun(ctx context.Context, ctr *dagger.Container, workDir string, apply bool, args []string) (string, error) {

	// First init the terraform configuration
	ctr = ctr.WithWorkdir(workDir).WithExec([]string{"tofu", "init"})
	_, err := ctr.Stdout(ctx)
	if err != nil {
		return "", fmt.Errorf("failed to init the terraform configuration: %w", err)
	}

	cmd := []string{"tofu", "plan"}
	if apply {
		cmd = []string{"tofu", "apply"}
	}
	cmd = append(cmd, args...)
	return ctr.WithWorkdir(workDir).
		WithExec(cmd).Stdout(ctx)
}
