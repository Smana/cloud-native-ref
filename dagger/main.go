// This Dagger configuration allows to create an EKS cluster from scratch and run tests on it then destroy it.

package main

import (
	"context"
	"dagger/cloud-native-ref/internal/dagger"
	"fmt"
	"strings"
	"sync"
)

const (
	// These are values specific to the cloud-native-ref repository
	repoName       = "cloud-native-ref"
	tailnet        = "smainklh@gmail.com"
	eksClusterName = "mycluster-0"
)

type CloudNativeRef struct {
	Container          *dagger.Container
	AWSAccessKeyID     *dagger.Secret
	AWSSecretAccessKey *dagger.Secret
	AWSProfile         string
	AWSRegion          string
	AWSAssumeRoleArn   string
}

func New(
	ctx context.Context,

	// Custom container to use as a base container.
	// +optional
	container *dagger.Container,

	// a list of environment variables, expected in (key:value) format
	// +optional
	env []string,

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

	// AWS region to use
	// +optional
	// +default="eu-west-3"
	region string,

	// tsAPIKey is the Tailscale API key to use
	// +required
	tsKey *dagger.Secret,

	// tsTailnet is the Tailscale tailnet to use
	// +optional
	tsTailnet string,

	// tsHostname is the Tailscale hostname to use
	// +optional
	// +default=""
	tsHostname string,
) (*CloudNativeRef, error) {
	if tsHostname == "" {
		tsHostname = repoName
	}
	if tsTailnet == "" {
		tsTailnet = tailnet
	}

	cRef := &CloudNativeRef{}

	if container == nil {

		// init a wolfi container with the necessary tools
		container = dag.Apko().Wolfi([]string{"aws-cli-v2", "bash", "curl", "git", "jq", "opentofu"})

		// Add the environment variables to the container
		for _, e := range env {
			parts := strings.Split(e, ":")
			if len(parts) != 2 {
				return nil, fmt.Errorf("invalid environment variable format, must be in the form <key>:<value>: %s", e)
			}
			container = container.WithEnvVariable(parts[0], parts[1])
		}

		// Add Tailscale environment variables
		container = container.
			WithEnvVariable("TS_HOSTNAME", tsHostname).
			WithEnvVariable("TS_TAILNET", tsTailnet)

		// Configure AWS authentication
		if accessKeyID != nil && secretAccessKey != nil {
			container = container.WithSecretVariable("AWS_ACCESS_KEY_ID", accessKeyID).
				WithSecretVariable("AWS_SECRET_ACCESS_KEY", secretAccessKey)
		}
		if authDir != nil {
			container = container.WithMountedDirectory("/root/.aws/", authDir)
		}
	}

	// Add tailscale environment variables
	container = container.
		WithEnvVariable("TS_HOSTNAME", tsHostname).
		WithEnvVariable("TS_TAILNET", tsTailnet).
		WithSecretVariable("TS_API_KEY", tsKey)

	// Setting AWS parameters
	cRef.AWSRegion = region
	if accessKeyID != nil && secretAccessKey != nil {
		cRef.AWSAccessKeyID = accessKeyID
		cRef.AWSSecretAccessKey = secretAccessKey
	}
	if profile != "" {
		cRef.AWSProfile = profile
	}
	if assumeRoleArn != "" {
		cRef.AWSAssumeRoleArn = assumeRoleArn
	}

	cRef.Container = container
	return cRef, nil
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
	// mount the source directory
	container := m.Container.WithMountedDirectory(fmt.Sprintf("/%s", repoName), source)

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
		container = container.WithEnvVariable("AWS_ACCESS_KEY_ID", accessKeyIDValue).
			WithEnvVariable("AWS_SECRET_ACCESS_KEY", secretAccessKeyValue)
	}

	if authDir != nil {
		container = container.WithMountedDirectory("/root/.aws/", authDir)
	}

	createNetwork(ctx, container, false)

	return container.
		WithExec([]string{"echo", "Bootstrap the EKS cluster"}).
		Stdout(ctx)
}

// Create the network resources (VPC, subnets, etc.)
func (m *CloudNativeRef) Network(
	ctx context.Context,

	// source is the directory where the Terraform configuration is stored
	// +required
	source *dagger.Directory,

	// env is a list of environment variables, expected in (key:value) format
	// +optional
	env []string,

) (*dagger.Container, error) {
	// mount the source directory
	container := m.Container.WithMountedDirectory(fmt.Sprintf("/%s", repoName), source)

	// Create the network components
	_, err := createNetwork(ctx, container, true)
	if err != nil {
		return nil, err
	}

	return container, nil
}

type VaultConfig struct {
	Addr                string
	SkipVerify          string
	RootTokenUrl        string
	CertManagerRoleID   string
	CertManagerSecretID *dagger.Secret
	Container           *dagger.Container
}

// Deploy and configure a Vault instance
func (m *CloudNativeRef) Vault(
	ctx context.Context,

	// source is the directory where the Terraform configuration is stored
	// +required
	source *dagger.Directory,

	// privateDomainName is the private domain name to use
	// +optional
	// +default="priv.cloud.ogenki.io"
	privateDomainName string,

	// vaultAddr is the Vault address to use
	// +optional
	vaultAddr string,

	// vaultSkipVerify is the Vault skip verify to use
	// +optional
	// +default="true"
	vaultSkipVerify string,

	// env is a list of environment variables, expected in (key:value) format
	// +optional
	env []string,

) (*VaultConfig, error) {
	// mount the source directory
	container := m.Container.
		WithMountedDirectory(fmt.Sprintf("/%s", repoName), source).
		WithExec([]string{"apk", "add", "vault"})

	sess, err := createAWSSession(ctx, m)
	if err != nil {
		return nil, err
	}
	tailscaleSvc, err := tailscaleService(ctx, container)
	if err != nil {
		return nil, err
	}

	// Set the Vault address
	if vaultAddr == "" && privateDomainName != "" {
		vaultAddr = fmt.Sprintf("https://vault.%s:8200", privateDomainName)
	}

	// Apply the Terraform Vault configuration
	vaultOutput, err := createVault(ctx, container, true)
	if err != nil {
		return nil, err
	}

	// Retrieve the Vault root token
	rootToken, err := initVault(vaultOutput, sess)
	if err != nil {
		return nil, err
	}

	vaultRootTokenSecret := dag.SetSecret("vaultRootToken", rootToken)
	container = container.
		WithEnvVariable("VAULT_ADDR", vaultAddr).
		WithEnvVariable("VAULT_SKIP_VERIFY", vaultSkipVerify).
		WithSecretVariable("VAULT_TOKEN", vaultRootTokenSecret).
		WithServiceBinding("tailscale", tailscaleSvc).
		WithEnvVariable("ALL_PROXY", "socks5h://tailscale:1055").
		WithEnvVariable("HTTP_PROXY", "http://tailscale:1055").
		WithEnvVariable("http_proxy", "http://tailscale:1055")

	// Configure the Vault PKI
	err = configureVaultPKI(ctx, container, sess, fmt.Sprintf("certificates/%s/root-ca", privateDomainName))
	if err != nil {
		return nil, err
	}

	// Configure the Vault (policies, auth methods, etc.)
	_, err = configureVault(ctx, container, true)
	if err != nil {
		return nil, err
	}

	// retrieve Cert Manager appRole
	certManagerAppRole, err := certManagerApprole(ctx, container, sess)
	if err != nil {
		return nil, err
	}

	return &VaultConfig{
		Addr:                vaultAddr,
		SkipVerify:          vaultSkipVerify,
		CertManagerRoleID:   string(certManagerAppRole["role_id"]),
		CertManagerSecretID: dag.SetSecret("certManagerSecretID", string(certManagerAppRole["secret_id"])),
		Container:           container,
	}, nil
}

// Create an EKS cluster
func (m *CloudNativeRef) EKS(
	ctx context.Context,

	// source is the directory where the Terraform configuration is stored
	// +required
	source *dagger.Directory,

	// branch is the branch to use for flux bootstrap
	// +required
	branch string,

	// env is a list of environment variables, expected in (key:value) format
	// +optional
	env []string,

) (*dagger.Container, error) {
	// mount the source directory
	container := m.Container.WithMountedDirectory(fmt.Sprintf("/%s", repoName), source)

	// Create the network components
	_, err := createEKS(ctx, container, true, branch)
	if err != nil {
		return nil, err
	}

	return container, nil
}

// Takes a source directory and a list of resources to update the kustomization file
func (m *CloudNativeRef) UpdateKustomization(
	ctx context.Context,

	// source is the directory where the Terraform configuration is stored
	// +required
	source *dagger.Directory,

	// kustPath is the path to the kustomize directory
	// +required
	path string,

	// resources is the list of resources to use
	// +required
	resources []string,

) (*dagger.Directory, error) {

	// mount the source directory
	ctr := m.Container.WithMountedDirectory(fmt.Sprintf("/%s", repoName), source)

	// Update kustomizations
	dir, err := updateKustomization(ctr, path, resources)
	if err != nil {
		return nil, err
	}

	return dir, nil
}

func (m *CloudNativeRef) Bootstrap(
	ctx context.Context,

	// source is the directory where the Terraform configuration is stored
	// +required
	source *dagger.Directory,

	// branch is the branch to use for flux bootstrap
	// +required
	branch string,

	// privateDomainName is the private domain name to use
	// +optional
	// +default="priv.cloud.ogenki.io"
	privateDomainName string,

	// vaultAddr is the Vault address to use
	// +optional
	vaultAddr string,

	// vaultSkipVerify is the Vault skip verify to use
	// +optional
	// +default="true"
	vaultSkipVerify string,

	// env is a list of environment variables, expected in (key:value) format
	// +optional
	env []string,

) (string, error) {
	_, err := m.Network(ctx, source, env)
	if err != nil {
		return "", fmt.Errorf("failed to create network resources: %w", err)
	}

	var wg sync.WaitGroup
	errChan := make(chan error, 2)

	var vault *VaultConfig

	wg.Add(2)

	go func() {
		defer wg.Done()
		var err error
		vault, err = m.Vault(ctx, source, privateDomainName, vaultAddr, vaultSkipVerify, env)
		if err != nil {
			errChan <- fmt.Errorf("failed to create Vault resources: %w", err)
			return
		}
	}()

	go func() {
		defer wg.Done()
		_, err := m.EKS(ctx, source, branch, env)
		if err != nil {
			errChan <- fmt.Errorf("failed to create EKS resources: %w", err)
			return
		}
	}()

	wg.Wait()
	close(errChan)

	for err := range errChan {
		if err != nil {
			return "", err
		}
	}

	return m.Container.
		WithExec([]string{
			"echo",
			fmt.Sprintf(
				"VaultAddr: %s\nCertManagerAppRoleId: %s\nEKSGetCredentials: aws eks update-kubeconfig --name %s --alias %s",
				vault.Addr,
				vault.CertManagerRoleID,
				eksClusterName,
				eksClusterName,
			),
		}).Stdout(ctx)
}
