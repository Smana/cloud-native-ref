package main

import (
	"context"
	"dagger/cloud-native-ref/internal/dagger"
	"fmt"
	"strings"
)

// tailscaleAuthKey generate a Tailscale auth key
func tailscaleAuthKey(ctx context.Context, container *dagger.Container) (*dagger.Secret, error) {
	script := `#!/bin/bash
# Set the Tailscale API endpoint and the tailnet
tailnet=${TS_TAILNET}
apiEndpoint="https://api.tailscale.com/api/v2/tailnet/${tailnet}/keys"

# Set the Tailscale API key
tsKeyValue="${TS_API_KEY}"

# Create the request body
body=$(cat <<EOF
{
  "capabilities": {
    "devices": {
      "create": {
        "reusable": true,
        "ephemeral": true,
        "preauthorized": true
      }
    }
  },
  "expirySeconds": 3600
}
EOF
)

# Make the POST request to the Tailscale API to create an auth key
response=$(curl -s -w "%{http_code}" -o /tmp/tailscale_response.json -X POST "$apiEndpoint" \
  -H "Authorization: Bearer $tsKeyValue" \
  -H "Content-Type: application/json" \
  -d "$body")

# Extract the HTTP status code
http_status=$(tail -n1 <<< "$response")

# Check if the request was successful
if [[ "$http_status" -ne 200 ]]; then
  echo "Failed to create auth key: HTTP $http_status"
  exit 1
fi

# Parse the JSON response to extract the auth key
authKey=$(jq -r '.key' /tmp/tailscale_response.json)

if [[ "$authKey" == "null" ]]; then
  echo "Failed to parse the auth key from the response"
  exit 1
fi

# Output the auth key
echo "$authKey"

# Cleanup
rm -f /tmp/tailscale_response.json
`
	authKey, err := container.
		WithNewFile("/bin/tailscale-authkey", script, dagger.ContainerWithNewFileOpts{Permissions: 0750}).
		WithExec([]string{"/bin/tailscale-authkey"}).
		Stdout(ctx)
	if err != nil {
		return nil, fmt.Errorf("failed to create auth key: %w", err)
	}

	return dag.SetSecret("tsAuthKey", strings.TrimSpace(authKey)), nil
}

// tailscaleService creates a Tailscale dagger Service
func tailscaleService(ctx context.Context, container *dagger.Container) (*dagger.Service, error) {

	authKey, err := tailscaleAuthKey(ctx, container)
	if err != nil {
		return nil, fmt.Errorf("failed to generate Tailscale auth key: %s", err)
	}

	container = container.WithExec([]string{"apk", "add", "tailscale"})

	tsUpScript := `#!/bin/bash

# Retrieve the binaries from the sourceDir
# Start the tailscaled process in the background
tailscaled --tun=userspace-networking &
TS_PID=$!

# Wait for a few seconds to ensure the process starts
sleep 5

# Run the tailscale login and up commands
tailscale login --hostname "$TS_HOSTNAME" --authkey "$TS_AUTH_KEY"
tailscale up --accept-dns=true --accept-routes --hostname="$TS_HOSTNAME"

# Kill the background tailscaled process
kill $TS_PID

# Wait for the process to terminate
wait $TS_PID

# Relaunch the tailscaled process in the foreground
tailscaled --tun=userspace-networking --socks5-server=:1055 --outbound-http-proxy-listen=:1055
`

	svc := container.
		WithSecretVariable("TS_AUTH_KEY", authKey).
		WithNewFile("/bin/tailscale-up", tsUpScript, dagger.ContainerWithNewFileOpts{Permissions: 0750}).
		WithExposedPort(1055).AsService(dagger.ContainerAsServiceOpts{Args: []string{"/bin/tailscale-up"}})

	return svc, nil
}

func createNetwork(ctx context.Context, ctr *dagger.Container, tfarg string) (map[string]interface{}, error) {
	workDir := "/cloud-native-ref/opentofu/network"

	output, err := tfRun(ctx, ctr, workDir, tfarg, []string{"-var-file", "variables.tfvars"})
	if err != nil {
		return nil, fmt.Errorf("failed to create the network: %w", err)
	}
	return output, nil
}

func destroyNetwork(ctx context.Context, ctr *dagger.Container) error {
	workDir := "/cloud-native-ref/opentofu/network"
	_, err := tfRun(ctx, ctr, workDir, "destroy", []string{"-var-file", "variables.tfvars"})
	if err != nil {
		return fmt.Errorf("failed to destroy the network: %w", err)
	}
	return nil
}
