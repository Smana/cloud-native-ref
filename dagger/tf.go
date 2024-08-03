package main

import (
	"context"
	"dagger/cloud-native-ref/internal/dagger"
	"encoding/json"
	"fmt"
)

// tfRun applies the terraform configuration
func tfRun(ctx context.Context, ctr *dagger.Container, workDir string, apply bool, args []string) (map[string]interface{}, error) {

	// First init the terraform configuration
	ctr = ctr.WithWorkdir(workDir).WithExec([]string{"tofu", "init"})
	_, err := ctr.Stdout(ctx)
	if err != nil {
		return nil, fmt.Errorf("failed to init the terraform configuration of the directory %s: %w", workDir, err)
	}

	cmd := []string{"tofu", "plan"}
	if apply {
		cmd = []string{"tofu", "apply", "-auto-approve"}
	}
	cmd = append(cmd, args...)
	_, err = ctr.WithWorkdir(workDir).
		WithExec(cmd).Stdout(ctx)
	if err != nil {
		return nil, fmt.Errorf("failed to run the terraform command: %w", err)
	}

	output := ""
	if apply {
		output, err = ctr.WithWorkdir(workDir).
			WithExec([]string{"tofu", "output", "-json"}).
			Stdout(ctx)
		if err != nil {
			return nil, fmt.Errorf("failed to get the output of the directory %s: %w", workDir, err)
		}
	}

	var outputJson map[string]interface{}

	// convert string to json for output
	err = json.Unmarshal([]byte(output), &outputJson)
	if err != nil {
		return nil, fmt.Errorf("failed to unmarshal the output of the directory %s: %s", workDir, err)
	}

	return outputJson, nil
}
