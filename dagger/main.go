// This Dagger configuration allows to create an EKS cluster from scratch and run tests on it then destroy it.

package main

import (
	"context"
	"dagger/cloud-native-ref/internal/dagger"
	"fmt"
	"strings"
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
	ctr := dag.Apko().Wolfi([]string{"aws-cli-v2", "bash", "bind-tools", "git", "opentofu", "tailscale"})

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

// Clean all Terraform cache files
func (m *CloudNativeRef) Clean(
	ctx context.Context,

	// source is the directory where the Terraform configuration is stored
	// +required
	source *dagger.Directory,
) (string, error) {

	ctr, err := bootstrapContainer([]string{})
	if err != nil {
		return "", err
	}

	cmd := []string{"find", ".", "(", "-type", "d", "-name", "*.terraform", "-or", "-name", "*.terraform.lock.hcl", ")", "-exec", "rm", "-vrf", "{}", "+"}
	return ctr.
		WithMountedDirectory("/cloud-native-ref", source).
		WithWorkdir("/cloud-native-ref").
		WithExec(cmd).Stdout(ctx)
}

// Plan display the terraform plan for all the modules
func (m *CloudNativeRef) Plan(
	ctx context.Context,

	// source is the directory where the Terraform configuration is stored
	// +required
	source *dagger.Directory,

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

	// a list of environment variables, expected in (key:value) format
	// +optional
	env []string,

) (string, error) {

	ctr, err := bootstrapContainer(env)
	if err != nil {
		return "", err
	}

	// mount the source directory
	ctr = ctr.WithMountedDirectory("/cloud-native-ref", source)

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

	createNetwork(ctx, ctr, false)

	return ctr.
		WithExec([]string{"echo", "Bootstrap the EKS cluster"}).
		Stdout(ctx)
}

// Bootstrap the EKS cluster
func (m *CloudNativeRef) Bootstrap(
	ctx context.Context,

	// source is the directory where the Terraform configuration is stored
	// +required
	source *dagger.Directory,

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

	// apply if set to true, the terraform apply will be executed
	// +optional
	apply bool,

	// tsKey is the Tailscale key to use
	// +optional
	tsKey *dagger.Secret,

	// tsTailnet is the Tailscale tailnet to use
	// +optional
	// +default="smainklh@gmail.com"
	tsTailnet string,

	// tsHostname is the Tailscale hostname to use
	// +optional
	// +default="cloud-native-ref"
	tsHostname string,

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

	// mount the source directory
	ctr = ctr.WithMountedDirectory("/cloud-native-ref", source)

	if accessKeyID != nil && secretAccessKey != nil {
		ctr = ctr.WithSecretVariable("AWS_ACCESS_KEY_ID", accessKeyID).
			WithSecretVariable("AWS_SECRET_ACCESS_KEY", secretAccessKey)
	}

	if authDir != nil {
		ctr = ctr.WithMountedDirectory("/root/.aws/", authDir)
	}

	// networkOutput, err := createNetwork(ctx, ctr, true)
	// if err != nil {
	// 	return "", err
	// }

	// fmt.Printf("Network output: %s\n", networkOutput)

	svc, err := tailscaleService(ctx, tsKey, tsTailnet, tsHostname)
	if err != nil {
		return "", err
	}

	return ctr.
		WithServiceBinding("tailscale", svc).
		WithEnvVariable("ALL_PROXY", "socks5://tailscale:1055").
		WithEnvVariable("HTTP_PROXY", "http://tailscale:1055").
		WithEnvVariable("http_proxy", "http://tailscale:1055").
		WithExec([]string{"ping", "-c", "3", "100.103.180.69"}).
		Stdout(ctx)
}
