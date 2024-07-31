package main

import (
	"context"
	"dagger/cloud-native-ref/internal/dagger"
	"fmt"
)

func createVaultCluster(ctx context.Context, ctr *dagger.Container, apply bool) (string, error) {
	_, err := tfRun(ctx, ctr, "/cloud-native-ref/terraform/vault/cluster", apply, []string{"-var-file", "variables.tfvars", "-auto-approve"})
	if err != nil {
		return "", fmt.Errorf("failed to create the vault cluster: %w", err)
	}

	outputsJson, err := ctr.WithExec([]string{"tofu", "output", "-json"}).WithWorkdir("/cloud-native-ref/terraform/vault/cluster").Stdout(ctx)
	if err != nil {
		return "", fmt.Errorf("failed to get the output of the vault cluster: %w", err)
	}

	fmt.Printf("Vault cluster outputs: %s\n", outputsJson)

	return "", nil
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
