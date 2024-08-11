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

	output, err := tfRun(ctx, ctr, workDir, apply, []string{"-var-file", "variables.tfvars"})
	if err != nil {
		return nil, fmt.Errorf("failed to create the vault cluster: %w", err)
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

func configureVaultPKI(
	ctx context.Context,
	ctr *dagger.Container,
	sess *session.Session,
	secretName string,
) error {

	rootCerts, err := getSecretManager(sess, secretName)
	if err != nil {
		return err
	}

	bundlePlaintext := rootCerts["bundle"]
	if bundlePlaintext == "" {
		return fmt.Errorf("bundle not found in secret")
	}

	bundle := dag.SetSecret("bundle", rootCerts["bundle"])

	vaultInitScript := `#!/bin/bash

wait_for_vault() {
    local max_retries=10
    local timeout_seconds=300
    local interval=$((timeout_seconds / max_retries))
    local attempt=1

    while [[ $attempt -le $max_retries ]]
    do
        echo "Attempt $attempt: Checking $VAULT_ADDR..."
        if curl -k --output /dev/null --silent --head --fail "$VAULT_ADDR"; then
            return 0
        else
            echo "URL $VAULT_ADDR is not reachable. Waiting for $interval seconds before retrying..."
            sleep $interval
        fi
        attempt=$((attempt + 1))
    done

    echo "URL $VAULT_ADDR is still not reachable after $max_retries attempts."
    return 1
}

wait_for_vault

# Enable PKI secrets engine
if ! vault secrets list --format=json | jq -e '.["pki/"]' > /dev/null; then
	vault secrets enable pki
	vault write pki/config/ca pem_bundle="${VAULT_PKI_CA_BUNDLE}"
fi

# Check the PKI configuration, returns a code 0 if the configuration is correct (There might be a better way to do this)
if [[ $(vault pki health-check --format=json pki|jq -r '.ca_validity_period[0].status') == "ok" ]]; then
	echo "PKI configuration is correct"
else
	echo "PKI configuration is incorrect"
	exit 1
fi

# Expected max-lease-ttl value
expected_ttl="315360000"

# Read the configuration of the pki secrets engine
actual_ttl=$(vault read -format=json sys/mounts/pki/tune | jq -r '.data.max_lease_ttl')

# Check if the actual value matches the expected value
if [ "$actual_ttl" == "$expected_ttl" ]; then
  echo "The max-lease-ttl value is as expected: $actual_ttl"
else
  vault secrets tune -max-lease-ttl="$expected_ttl" pki
fi
`

	ctr.
		WithSecretVariable("VAULT_PKI_CA_BUNDLE", bundle).
		WithNewFile("/bin/configure-vault-pki", vaultInitScript, dagger.ContainerWithNewFileOpts{Permissions: 0750}).
		WithExec([]string{"/bin/configure-vault-pki"}).
		Stdout(ctx)

	return err
}

func configureVault(ctx context.Context, ctr *dagger.Container, apply bool) (map[string]interface{}, error) {
	workDir := "/cloud-native-ref/terraform/vault/management"
	output, err := tfRun(ctx, ctr, workDir, apply, []string{"-var-file", "variables.tfvars"})
	if err != nil {
		return nil, fmt.Errorf("failed to configure the vault cluster: %w", err)
	}
	return output, nil
}
