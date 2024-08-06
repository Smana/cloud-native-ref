package main

import (
	"context"
	"dagger/cloud-native-ref/internal/dagger"
	"encoding/json"
	"fmt"

	"github.com/go-resty/resty/v2"
)

type tailscaleAuthKeyResponse struct {
	ID           string `json:"id"`
	Key          string `json:"key"`
	Created      string `json:"created"`
	Expires      string `json:"expires"`
	Capabilities struct {
		Devices struct {
			Create struct {
				Reusable      bool `json:"reusable"`
				Ephemeral     bool `json:"ephemeral"`
				Preauthorized bool `json:"preauthorized"`
			} `json:"create"`
		} `json:"devices"`
	} `json:"capabilities"`
}

// tailscaleAuthKey creates a Tailscale auth key
func tailscaleAuthKey(tsKeyValue, tailnet string) (*dagger.Secret, error) {
	// Tailscale API endpoint for creating auth keys
	apiEndpoint := fmt.Sprintf("https://api.tailscale.com/api/v2/tailnet/%s/keys", tailnet)

	// Create a new Resty client
	client := resty.New()

	// Define the request body
	body := map[string]interface{}{
		"capabilities": map[string]interface{}{
			"devices": map[string]interface{}{
				"create": map[string]bool{
					"reusable":      true,
					"ephemeral":     true,
					"preauthorized": true,
				},
			},
		},
		"expirySeconds": 3600,
	}

	// Make a POST request to the Tailscale API to create an auth key
	resp, err := client.R().
		SetHeader("Authorization", "Bearer "+tsKeyValue).
		SetHeader("Content-Type", "application/json").
		SetBody(body).
		Post(apiEndpoint)

	if err != nil {
		return nil, fmt.Errorf("failed to create auth key: %s", err)
	}

	// Check if the request was successful
	if resp.IsError() {
		return nil, fmt.Errorf("failed to create auth key: %s", resp.Status())
	}

	var authKeyResponse tailscaleAuthKeyResponse
	err = json.Unmarshal(resp.Body(), &authKeyResponse)
	if err != nil {
		return nil, fmt.Errorf("failed to unmarshal response: %s", err)
	}

	authKey := dag.SetSecret("TAILSCALE_AUTHKEY", authKeyResponse.Key)

	return authKey, nil
}

// tailscaleService creates a Tailscale dagger Service
func tailscaleService(ctx context.Context, tsKey *dagger.Secret, tsTailnet string, tsHostname string) (*dagger.Service, error) {
	tsAPIKey, err := getSecretValue(ctx, tsKey)
	if err != nil {
		return nil, err
	}

	authKey, err := tailscaleAuthKey(tsAPIKey, tsTailnet)
	if err != nil {
		return nil, fmt.Errorf("failed to generate Tailscale auth key: %s", err)
	}

	ctr := dag.Apko().Wolfi([]string{"bash", "bind-tools", "curl", "netcat-openbsd", "nmap"})

	// Installing unstable tailscale binaries
	binDir := dag.Arc().
		Unarchive(dag.HTTP("https://pkgs.tailscale.com/unstable/tailscale_1.71.72_amd64.tgz").WithName("tailscale_1.71.72_amd64.tgz"))
	tailscaledBin := binDir.File("tailscale_1.71.72_amd64/tailscaled")
	tailscaleBin := binDir.File("tailscale_1.71.72_amd64/tailscale")

	tsScript := `#!/bin/bash

# Retrieve the binaries from the sourceDir
# Start the tailscaled process in the background
tailscaled --tun=userspace-networking &
TAILSCALED_PID=$!

# Wait for a few seconds to ensure the process starts
sleep 5

# Run the tailscale login and up commands
tailscale login --hostname "$TAILSCALE_HOSTNAME" --authkey "$TAILSCALE_AUTHKEY"
tailscale up --accept-dns=true --accept-routes --hostname="$TAILSCALE_HOSTNAME"

# Kill the background tailscaled process
kill $TAILSCALED_PID

# Wait for the process to terminate
wait $TAILSCALED_PID

# Relaunch the tailscaled process in the foreground
tailscaled --tun=userspace-networking --socks5-server=:1055
`

	svc := ctr.
		WithEnvVariable("TAILSCALE_HOSTNAME", tsHostname).
		WithSecretVariable("TAILSCALE_AUTHKEY", authKey).
		WithNewFile("/bin/tailscale-up", tsScript, dagger.ContainerWithNewFileOpts{Permissions: 0750}).
		WithFile("/bin/tailscaled", tailscaledBin, dagger.ContainerWithFileOpts{Permissions: 0750}).
		WithFile("/bin/tailscale", tailscaleBin, dagger.ContainerWithFileOpts{Permissions: 0750}).
		WithExec([]string{"/bin/tailscale-up"}).WithExposedPort(1055).AsService()

	return svc, nil
}

func createNetwork(ctx context.Context, ctr *dagger.Container, apply bool) (map[string]interface{}, error) {
	workDir := "/cloud-native-ref/terraform/network"

	// Firts we need to import Tailscale ACLs due to a bug in the Terraform provider
	importScript := `
if tofu state list | grep -q "tailscale_acl.this"; then
    echo "Resource tailscale_acl.this already exists in the state."
else
    echo "Resource tailscale_acl.this does not exist in the state. Importing..."
    tofu import --var-file variables.tfvars tailscale_acl.this acl
fi
`
	cmd := []string{"bash", "-c", importScript}
	_, err := ctr.WithWorkdir(workDir).WithExec(cmd).Stdout(ctx)
	if err != nil {
		return nil, fmt.Errorf("failed to import the Tailscale ACLs: %w", err)
	}

	output, err := tfRun(ctx, ctr, workDir, apply, []string{"-var-file", "variables.tfvars"})
	if err != nil {
		return nil, fmt.Errorf("failed to create the network: %w", err)
	}
	return output, nil
}
