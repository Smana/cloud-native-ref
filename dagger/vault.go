package main

import (
	"context"
	"dagger/cloud-native-ref/internal/dagger"
	"fmt"
	"strings"
	"time"

	"github.com/aws/aws-sdk-go/aws/session"
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

func initVault(
	vaultOutput map[string]interface{},
	sess *session.Session,
) (string, error) {
	vaultAsgMap := vaultOutput["autoscaling_group_id"].(map[string]interface{})
	vaultAsg := vaultAsgMap["value"].(string)

	instanceID, err := getInstanceIDFromASG(sess, vaultAsg)
	if err != nil {
		return "", err
	}
	fmt.Printf("Instance ID: %s\n", instanceID)

	err = checkInstanceReady(sess, instanceID, 5, time.Minute)
	if err != nil {
		return "", err
	}

	// This script returns the root token if Vault is not initialized
	vaultInitScript := `#!/bin/bash
#!/bin/bash

export VAULT_SKIP_VERIFY=true

# Check Vault status
status_output=$(vault status -format=json)

# Check if Vault is initialized
is_initialized=$(echo "$status_output" | jq -r '.initialized')

# Initialize Vault only if it is not initialized
if [ "$is_initialized" == "false" ]; then
    # Initialize Vault and store the output in a variable in JSON format
    init_output=$(vault operator init -recovery-shares=1 -recovery-threshold=1 -format=json)

    # Extract the root token from the JSON output using jq
    root_token=$(echo "$init_output" | jq -r '.root_token')

    # Print the root token
    echo "$root_token"
else
    # Print an empty string
    echo ""
fi
`
	vaultSecretName := "vault/cloud-native-ref/tokens"
	vaultRooToken := ""
	output, err := executeScriptOnInstance(sess, instanceID, vaultInitScript)
	if err != nil {
		return "", err
	}
	output = strings.TrimSpace(output)
	if output != "" {
		secretData := map[string]string{"root": output}
		storeOutputInSecretsManager(sess, vaultSecretName, secretData)
		vaultRooToken = output
	} else {
		secretData, err := getSecretManager(sess, vaultSecretName)
		if err != nil {
			return "", err
		}
		vaultRooToken = secretData["root"]
	}

	return vaultRooToken, nil
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
