package main

import (
	"context"
	"dagger/cloud-native-ref/internal/dagger"
	"fmt"
)

// tmRun applies the Terraform/OpenTofu configuration using Terramate
func tmRun(ctx context.Context, workDir *dagger.Directory, ctr *dagger.Container, arg string, parallelism int, tmArgs []string, command []string) (string, error) {

	cmd := []string{"terramate", "run", "--parallelism", fmt.Sprintf("%d", parallelism)}
	// These are the arguments for terramate run
	cmd = append(cmd, tmArgs...)
	cmd = append(cmd, "--")
	// This is the command to run. e.g. tofu plan
	cmd = append(cmd, command...)

	return ctr.
		WithMountedDirectory("/work", workDir).
		WithWorkdir("/work").
		WithExec(cmd).Stdout(ctx)
}
