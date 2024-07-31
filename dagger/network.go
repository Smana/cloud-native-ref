package main

import (
	"context"
	"dagger/cloud-native-ref/internal/dagger"
	"fmt"
)

func createNetwork(ctx context.Context, ctr *dagger.Container, apply bool) (string, error) {
	_, err := tfRun(ctx, ctr, "/cloud-native-ref/terraform/network", apply, []string{"-var-file", "variables.tfvars"})
	if err != nil {
		return "", fmt.Errorf("failed to create the network: %w", err)
	}

	outputsJson, err := ctr.WithExec([]string{"tofu", "output", "-json"}).WithWorkdir("/cloud-native-ref/terraform/network").Stdout(ctx)
	if err != nil {
		return "", fmt.Errorf("failed to get the output of the network: %w", err)
	}

	fmt.Printf("Network outputs: %s\n", outputsJson)

	return "", nil
}
