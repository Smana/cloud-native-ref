package main

import (
	"context"
	"dagger/cloud-native-ref/internal/dagger"
	"fmt"
)

func createVault(ctx context.Context, ctr *dagger.Container, apply bool) (map[string]interface{}, error) {
	workDir := "/cloud-native-ref/terraform/vault/cluster"
	_, err := tfRun(ctx, ctr, workDir, apply, []string{"-var-file", "variables.tfvars", "-auto-approve"})
	if err != nil {
		return nil, fmt.Errorf("failed to create the vault cluster: %w", err)
	}

	output, err := tfRun(ctx, ctr, workDir, apply, []string{"-var-file", "variables.tfvars"})
	if err != nil {
		return nil, fmt.Errorf("failed to create the network: %w", err)
	}
	return output, nil
}

// // init the vault server
// func initVault() (string, error) {
// 	// Create a new dagger container with the necessary tools
// 	ctr, err := bootstrapContainer([]string{
// 		"VAULT_ADDR:http://vault:8200",
// 		"VAULT_TOKEN:root",
// 	})
// 	if err != nil {
// 		return "", err
// 	}
// 	return root_token, nil
// }

// // generate approle role id and secret id for cert-manager
// func generateCertManagerCreds() (string, string, error) {
// 	// Create a new dagger container with the necessary tools
// 	ctr, err := bootstrapContainer([]string{
// 		"VAULT_ADDR:http://vault:8200",
// 		"VAULT_TOKEN:root",
// 	})
// 	if err != nil {
// 		return "", "", err
// 	}

// 	return role_id, secret_id, nil
// }
