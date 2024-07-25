// This Dagger configuration allows to create an EKS cluster from scratch and run tests on it then destroy it.

package main

import (
	"context"
	"dagger/cloud-native-ref/internal/dagger"
	"fmt"
	"strings"
	"unicode"
)

type CloudNativeRef struct{}

// Possible applications to enable, these applications are optional and can be enabled during the bootstrap process
type SecurityApp string
type ObservabilityApp string
type ToolingApp string

const (
	certManager     SecurityApp = "certManager"
	externalSecrets SecurityApp = "externalSecrets"
	kyverno         SecurityApp = "kyverno"

	kubePrometheusStack ObservabilityApp = "kubePrometheusStack"
	loki                ObservabilityApp = "loki"
	vectorAgent         ObservabilityApp = "vectorAgent"

	daggerEngine ToolingApp = "daggerEngine"
	ghaRunners   ToolingApp = "ghaRunners"
	harbor       ToolingApp = "harbor"
)

// bootstrapContainer creates a container with the necessary tools to bootstrap the EKS cluster
func bootstrapContainer(env []string) (*dagger.Container, error) {
	// init a wolfi container with the necessary tools
	ctr := dag.Apko().Wolfi([]string{"aws-cli-v2", "bash", "opentofu"})

	// Add the environment variables to the container
	for _, e := range env {
		parts := strings.Split(e, ":")
		if len(parts) != 2 {
			return nil, fmt.Errorf("invalid environment variable format, must be in the form <key>:<value>: %s", e)
		}
		ctr = ctr.WithEnvVariable(parts[0], parts[1])
	}

	return ctr, nil
}

// camelCaseToKebabCase converts a string from camelCase to kebab-case
func camelCaseToKebabCase(s string) string {
	var builder strings.Builder
	for i, r := range s {
		if i > 0 && unicode.IsUpper(r) {
			builder.WriteRune('-')
		}
		builder.WriteRune(unicode.ToLower(r))
	}
	return builder.String()
}

// getSecretValue returns the plaintext value of a secret
func getSecretValue(ctx context.Context, secret *dagger.Secret) (string, error) {
	plainText, err := secret.Plaintext(ctx)
	if err != nil {
		return "", fmt.Errorf("failed to get secret value from the secret passed: %w", err)
	}

	return plainText, nil
}

// Bootstrap the EKS cluster
func (m *CloudNativeRef) Bootstrap(
	ctx context.Context,

	// The directory where the AWS authentication files will be stored
	// +optional
	authDir *dagger.Directory,

	// The AWS IAM Role ARN to assume
	// +optional
	assumeRoleArn string,

	// The AWS profile to use
	// +optional
	profile string,

	// The AWS secret access key
	// +optional
	secretAccessKey *dagger.Secret,

	// The AWS access key ID
	// +optional
	accessKeyID *dagger.Secret,

	// Tooling applications to enable
	// +optional
	toolingApps ToolingApp,

	// Security applications to enable
	// +optional
	securityApps SecurityApp,

	// Observability applications to enable
	// +optional
	observabilityApps ObservabilityApp,

	// a list of environment variables, expected in (key:value) format
	// +optional
	env []string,

) (string, error) {

	ctr, err := bootstrapContainer(env)
	if err != nil {
		return "", err
	}

	// Add the AWS credentials if provided as environment variables
	if accessKeyID != nil && secretAccessKey != nil {
		accessKeyIDValue, err := getSecretValue(ctx, accessKeyID)
		if err != nil {
			return "", err
		}
		secretAccessKeyValue, err := getSecretValue(ctx, secretAccessKey)
		if err != nil {
			return "", err
		}
		ctr = ctr.WithEnvVariable("AWS_ACCESS_KEY_ID", accessKeyIDValue).
			WithEnvVariable("AWS_SECRET_ACCESS_KEY", secretAccessKeyValue)
	}

	if authDir != nil {
		ctr = ctr.WithMountedDirectory("/root/.aws/", authDir)
	}

	return ctr.
		WithExec([]string{"echo", "Bootstrap the EKS cluster"}).
		Terminal().
		Stdout(ctx)
}
