package main

import (
	"context"
	"dagger/cloud-native-ref/internal/dagger"
)

// tmRun applies the Terraform/OpenTofu configuration using Terramate
func tmRun(ctx context.Context, workDir *dagger.Directory, ctr *dagger.Container, arg string, tmArgs []string, command []string) (string, error) {

	cmd := []string{"terramate", arg}
	// These are the arguments for the command
	cmd = append(cmd, tmArgs...)
	cmd = append(cmd, "--")

	// This is the command to run. e.g. tofu plan
	cmd = append(cmd, command...)

	return ctr.
		WithMountedDirectory("/work", workDir).
		WithWorkdir("/work").
		WithExec(cmd).Stdout(ctx)
}
