package main

import (
	"context"
	"dagger/cloud-native-ref/internal/dagger"
	"fmt"
)

func createEKS(ctx context.Context, ctr *dagger.Container, apply bool, branch string) (map[string]interface{}, error) {
	workDir := "/cloud-native-ref/terraform/eks"

	output, err := tfRun(ctx, ctr, workDir, apply, []string{"-var-file", "variables.tfvars", "-var", fmt.Sprintf("branch=%s", branch)})
	if err != nil {
		return nil, fmt.Errorf("failed to create the EKS cluster: %w", err)
	}
	return output, nil
}
