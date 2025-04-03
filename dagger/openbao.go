package main

import (
	"context"
	"dagger/cloud-native-ref/internal/dagger"
	"fmt"
	"strings"
	"time"

	"github.com/aws/aws-sdk-go/aws/session"
)

// initOpenBao initializes the bao cluster and returns the root token
func initOpenBao(
	baoOutput map[string]interface{},
	sess *session.Session,
) (string, error) {
	baoAsgMap := baoOutput["autoscaling_group_id"].(map[string]interface{})
	baoAsg := baoAsgMap["value"].(string)

	instanceID, err := getInstanceIDFromASG(sess, baoAsg)
	if err != nil {
		return "", err
	}

	err = checkInstanceReady(sess, instanceID, 5, time.Minute)
	if err != nil {
		return "", err
	}

	// This script returns the root token if OpenBao is not initialized
	baoInitScript := `#!/bin/bash
#!/bin/bash

export VAULT_SKIP_VERIFY=true

# Check OpenBao status
status_output=$(bao status -format=json)

# Check if OpenBao is initialized
is_initialized=$(echo "$status_output" | jq -r '.initialized')

# Initialize  only if it is not initialized
if [ "$is_initialized" == "false" ]; then
    # Initialize OpenBao and store the output in a variable in JSON format
    init_output=$(bao operator init -recovery-shares=1 -recovery-threshold=1 -format=json)

    # Extract the root token from the JSON output using jq
    root_token=$(echo "$init_output" | jq -r '.root_token')

    # Print the root token
    echo "$root_token"
else
    # Print an empty string
    echo ""
fi
`
	baoSecretName := fmt.Sprintf("openbao/%s/tokens/root", repoName)
	output, err := executeScriptOnInstance(sess, instanceID, baoInitScript)
	if err != nil {
		return "", err
	}
	token := strings.TrimSpace(output)
	if token != "" {
		secretData := map[string]string{"token": token}
		err := storeOutputInSecretsManager(sess, baoSecretName, secretData)
		if err != nil {
			return "", err
		}
	} else {
		secretData, err := getSecretManager(sess, baoSecretName)
		if err != nil {
			return "", err
		}
		token = secretData["token"]
	}

	return token, nil

}

// configureOpenBaoPKI configures the OpenBao PKI
func configureOpenBaoPKI(
	ctx context.Context,
	ctr *dagger.Container,
	sess *session.Session,
	secretName string,
) (string, error) {

	rootCerts, err := getSecretManager(sess, secretName)
	if err != nil {
		return "", err
	}

	bundlePlaintext := rootCerts["bundle"]
	if bundlePlaintext == "" {
		return "", fmt.Errorf("bundle not found in secret")
	}

	bundle := dag.SetSecret("bundle", rootCerts["bundle"])

	baoInitScript := `#!/bin/bash

wait_for_bao() {
    local max_retries=20
    local timeout_seconds=600
    local interval=$((timeout_seconds / max_retries))
    local attempt=1

    while [[ $attempt -le $max_retries ]]
    do
        echo "Attempt $attempt: Checking $VAULT_ADDR..."
        if curl -k --output /dev/null --silent --head --fail "$VAULT_ADDR/v1/sys/health"; then
            return 0
        else
            echo "URL $VAULT_ADDR/v1/sys/health is not reachable. Waiting for $interval seconds before retrying..."
            sleep $interval
        fi
        attempt=$((attempt + 1))
    done

    echo "URL $VAULT_ADDR/v1/sys/health is still not reachable after $max_retries attempts."
    return 1
}

wait_for_bao

# Enable PKI secrets engine
if ! bao secrets list --format=json | jq -e '.["pki/"]' > /dev/null; then
	bao secrets enable pki
	bao write pki/config/ca pem_bundle="${VAULT_PKI_CA_BUNDLE}"
fi

# Check the PKI configuration, returns a code 0 if the configuration is correct (There might be a better way to do this)
if [[ $(bao pki health-check --format=json pki|jq -r '.ca_validity_period[0].status') == "ok" ]]; then
	echo "PKI configuration is correct"
else
	echo "PKI configuration is incorrect"
	exit 1
fi

# Expected max-lease-ttl value
expected_ttl="315360000"

# Read the configuration of the pki secrets engine
actual_ttl=$(bao read -format=json sys/mounts/pki/tune | jq -r '.data.max_lease_ttl')

# Check if the actual value matches the expected value
if [ "$actual_ttl" == "$expected_ttl" ]; then
  echo "The max-lease-ttl value is as expected: $actual_ttl"
else
  bao secrets tune -max-lease-ttl="$expected_ttl" pki
fi
`

	return ctr.
		WithSecretVariable("VAULT_PKI_CA_BUNDLE", bundle).
		WithNewFile("/bin/configure-bao-pki", baoInitScript, dagger.ContainerWithNewFileOpts{Permissions: 0750}).
		WithExec([]string{"/bin/configure-bao-pki"}).
		Stdout(ctx)
}

// configureOpenBao configures the bao cluster
func configureOpenBao(ctx context.Context, ctr *dagger.Container, tfarg string) (map[string]interface{}, error) {
	workDir := fmt.Sprintf("/%s/opentofu/openbao/management", repoName)
	_, err := tfRun(ctx, ctr, workDir, tfarg, []string{"-var-file", "variables.tfvars"})
	if err != nil {
		return nil, fmt.Errorf("failed to configure the bao cluster: %w", err)
	}
	return nil, nil
}

// certManagerApprole creates the AppRole for the cert-manager
func certManagerApprole(ctx context.Context, container *dagger.Container, sess *session.Session) (map[string]string, error) {
	// Create the AppRole for the cert-manager
	appRoleScript := `#!/bin/bash
CERT_MANAGER_ROLE_ID=$(bao read --field=role_id auth/approle/role/cert-manager/role-id)
CERT_MANAGER_SECRET_ID=$(bao write --field=secret_id -f auth/approle/role/cert-manager/secret-id)
echo "${CERT_MANAGER_ROLE_ID},${CERT_MANAGER_SECRET_ID}"
`

	appRole, err := container.WithNewFile("/bin/create-cert-manager-approle", appRoleScript, dagger.ContainerWithNewFileOpts{Permissions: 0750}).
		WithExec([]string{"/bin/create-cert-manager-approle"}).Stdout(ctx)
	if err != nil {
		return nil, err
	}

	// split approle output with , separator, first element is role_id, second is secret_id
	appRoleOutput := strings.Split(appRole, ",")
	if len(appRoleOutput) != 2 {
		return nil, fmt.Errorf("failed to create the cert-manager AppRole")
	}
	appRoleID := appRoleOutput[0]
	appRoleSecretID := appRoleOutput[1]

	// Store the AppRole in the secret manager
	secretData := map[string]string{
		"role_id":   appRoleID,
		"secret_id": appRoleSecretID,
	}
	err = storeOutputInSecretsManager(sess, fmt.Sprintf("openbao/%s/approles/cert-manager", repoName), secretData)
	if err != nil {
		return nil, err
	}

	return secretData, nil
}

// func updateOpenBaoClusterIssuer(
// 	container *dagger.Container,
// 	AppRoleId string,
// ) *dagger.Container {

// 	replaceRoleIDScript := `#!/bin/bash
// # Define the file and new role ID
// yaml_file=${1}

// # Replace the roleId in the YAML file
// yq eval ".spec.bao.auth.appRole.roleId = \"$APPROLE_ID\"" -i "$yaml_file"

// echo "roleId updated successfully!"
// `

// 	return container.WithExec([]string{"apk", "add", "yq"}).
// 		WithEnvVariable("APPROLE_ID", AppRoleId).
// 		WithNewFile("/bin/replace-role-id", replaceRoleIDScript, dagger.ContainerWithNewFileOpts{Permissions: 0750}).
// 		WithExec([]string{"/bin/replace-role-id", fmt.Sprintf("/%s/security/base/cert-manager/bao-clusterissuer.yaml", repoName)})
// }
