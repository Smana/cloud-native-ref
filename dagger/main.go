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
	region         = "eu-west-3"
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

	// tmVersion is the version of the Terramate CLI to use
	// +optional
	// +default="0.13.0"
	tmVersion string,

) (*CloudNativeRef, error) {
	if tsHostname == "" {
		tsHostname = repoName
	}
	if tsTailnet == "" {
		tsTailnet = tailnet
	}

	cRef := &CloudNativeRef{}

	if container == nil {

		// init a alpine container with the necessary tools
		container = dag.Container().From("alpine:latest").WithExec([]string{"apk", "add", "aws-cli-v2", "bash", "curl", "git", "go", "jq", "opentofu"})

		// Download the kubeconform archive and extract the binary into a dagger *File
		terramateBin := dag.Arc().
			Unarchive(dag.HTTP(fmt.Sprintf("https://github.com/terramate-io/terramate/releases/download/v%s/terramate_%s_linux_x86_64.tar.gz", tmVersion, tmVersion)).
				WithName(fmt.Sprintf("terramate_%s_linux_x86_64.tar.gz", tmVersion))).File("terramate_0/terramate")

		// Add the terramate binary to the container
		container = container.WithFile("/bin/terramate", terramateBin, dagger.ContainerWithFileOpts{Permissions: 0750})

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

// Plan display the tofu plan for all the modules
func (m *CloudNativeRef) Plan(
	ctx context.Context,

	// source is the directory where the Opentofu configuration is stored
	// +defaultPath="."
	// +ignore=["!**/opentofu"]
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

	_, err := createNetwork(ctx, container, "plan")
	if err != nil {
		return "", err
	}

	return container.
		WithExec([]string{"echo", "Bootstrap the EKS cluster"}).
		Stdout(ctx)
}

// Create the network resources (VPC, subnets, etc.)
func (m *CloudNativeRef) Network(
	ctx context.Context,

	// source is the directory where the Opentofu configuration is stored
	// +defaultPath="."
	// +ignore=["!**/opentofu"]
	source *dagger.Directory,

	// env is a list of environment variables, expected in (key:value) format
	// +optional
	env []string,

) (*dagger.Container, error) {
	// mount the source directory
	container := m.Container.WithMountedDirectory(fmt.Sprintf("/%s", repoName), source)

	// Create the network components
	_, err := createNetwork(ctx, container, "apply")
	if err != nil {
		return nil, err
	}

	return container, nil
}

type OpenBaoConfig struct {
	Addr                string
	SkipVerify          string
	RootTokenUrl        string
	CertManagerRoleID   string
	CertManagerSecretID *dagger.Secret
	Container           *dagger.Container
}

// Deploy and configure a OpenBao instance
func (m *CloudNativeRef) Openbao(
	ctx context.Context,

	// source is the directory where the Opentofu configuration is stored
	// +defaultPath="."
	// +ignore=["!**/opentofu"]
	source *dagger.Directory,

	// privateDomainName is the private domain name to use
	// +optional
	// +default="priv.cloud.ogenki.io"
	privateDomainName string,

	// openbaoAddr is the OpenBao address to use
	// +optional
	openbaoAddr string,

	// openbaoSkipVerify is the OpenBao skip verify to use
	// +optional
	// +default="true"
	openbaoSkipVerify string,

	// env is a list of environment variables, expected in (key:value) format
	// +optional
	env []string,

) (*OpenBaoConfig, error) {
	// mount the source directory
	container := m.Container.
		WithMountedDirectory(fmt.Sprintf("/%s", repoName), source).
		WithExec([]string{"apk", "add", "openbao"})

	sess, err := createAWSSession(ctx, m)
	if err != nil {
		return nil, err
	}
	tailscaleSvc, err := tailscaleService(ctx, container)
	if err != nil {
		return nil, err
	}

	// Set the OpenBao address
	if openbaoAddr == "" && privateDomainName != "" {
		openbaoAddr = fmt.Sprintf("https://bao.%s:8200", privateDomainName)
	}

	// Apply the OpentofuOpenBao configuration
	openbaoOutput, err := createOpenBao(ctx, container, "apply")
	if err != nil {
		return nil, err
	}

	// Retrieve the OpenBao root token
	rootToken, err := initOpenBao(openbaoOutput, sess)
	if err != nil {
		return nil, err
	}

	openbaoRootTokenSecret := dag.SetSecret("openbaoRootToken", rootToken)
	container = container.
		WithEnvVariable("VAULT_ADDR", openbaoAddr).
		WithEnvVariable("VAULT_SKIP_VERIFY", openbaoSkipVerify).
		WithSecretVariable("VAULT_TOKEN", openbaoRootTokenSecret).
		WithServiceBinding("tailscale", tailscaleSvc).
		WithEnvVariable("ALL_PROXY", "socks5h://tailscale:1055").
		WithEnvVariable("HTTP_PROXY", "http://tailscale:1055").
		WithEnvVariable("http_proxy", "http://tailscale:1055")

	// Configure the OpenBao PKI
	_, err = configureOpenBaoPKI(ctx, container, sess, fmt.Sprintf("certificates/%s/root-ca", privateDomainName))
	if err != nil {
		return nil, err
	}

	// Configure the OpenBao (policies, auth methods, etc.)
	_, err = configureOpenBao(ctx, container, "apply")
	if err != nil {
		return nil, err
	}

	// retrieve Cert Manager appRole
	certManagerAppRole, err := certManagerApprole(ctx, container, sess)
	if err != nil {
		return nil, err
	}

	return &OpenBaoConfig{
		Addr:                openbaoAddr,
		SkipVerify:          openbaoSkipVerify,
		CertManagerRoleID:   string(certManagerAppRole["role_id"]),
		CertManagerSecretID: dag.SetSecret("certManagerSecretID", string(certManagerAppRole["secret_id"])),
		Container:           container,
	}, nil
}

// Create an EKS cluster
func (m *CloudNativeRef) EKS(
	ctx context.Context,

	// source is the directory where the Opentofu configuration is stored
	// +defaultPath="."
	// +ignore=["!**/opentofu"]
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
	_, err := createEKS(ctx, container, "apply", branch)
	if err != nil {
		return nil, err
	}

	return container, nil
}

// Takes a source directory and a list of resources to update the kustomization file
func (m *CloudNativeRef) UpdateKustomization(
	ctx context.Context,

	// source is the directory where the Opentofu configuration is stored
	// +defaultPath="."
	// +ignore=["!**/opentofu"]
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

	// source is the directory where the Opentofu configuration is stored
	// +defaultPath="."
	// +ignore=["!**/opentofu"]
	source *dagger.Directory,

	// branch is the branch to use for flux bootstrap
	// +required
	branch string,

	// privateDomainName is the private domain name to use
	// +optional
	// +default="priv.cloud.ogenki.io"
	privateDomainName string,

	// openbaoAddr is the OpenBao address to use
	// +optional
	openbaoAddr string,

	// openbaoSkipVerify is the OpenBao skip verify to use
	// +optional
	// +default="true"
	openbaoSkipVerify string,

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

	var openbao *OpenBaoConfig

	wg.Add(2)

	go func() {
		defer wg.Done()
		var err error
		openbao, err = m.Openbao(ctx, source, privateDomainName, openbaoAddr, openbaoSkipVerify, env)
		if err != nil {
			errChan <- fmt.Errorf("failed to create OpenBao resources: %w", err)
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
				"OpenBaoAddr: %s\nCertManagerAppRoleId: %s\nEKSGetCredentials: aws eks update-kubeconfig --name %s --alias %s",
				openbao.Addr,
				openbao.CertManagerRoleID,
				eksClusterName,
				eksClusterName,
			),
		}).Stdout(ctx)
}

func (m *CloudNativeRef) Destroy(
	ctx context.Context,

	// source is the directory where the Opentofu configuration is stored
	// +defaultPath="."
	// +ignore=["!**/opentofu"]
	source *dagger.Directory,

	// branch is the branch to use for flux bootstrap
	// +required
	branch string,

	// privateDomainName is the private domain name to use
	// +optional
	// +default="priv.cloud.ogenki.io"
	privateDomainName string,

	// openbaoAddr is the OpenBao address to use
	// +optional
	openbaoAddr string,

	// openbaoSkipVerify is the OpenBao skip verify to use
	// +optional
	// +default="true"
	openbaoSkipVerify string,

	// env is a list of environment variables, expected in (key:value) format
	// +optional
	env []string,

) error {
	// mount the source directory
	container := m.Container.WithMountedDirectory(fmt.Sprintf("/%s", repoName), source)

	var wg sync.WaitGroup
	errChan := make(chan error, 2)

	wg.Add(2)

	sess, err := createAWSSession(ctx, m)
	if err != nil {
		return err
	}
	tailscaleSvc, err := tailscaleService(ctx, container)
	if err != nil {
		return err
	}

	// Set the OpenBao address
	if openbaoAddr == "" && privateDomainName != "" {
		openbaoAddr = fmt.Sprintf("https://bao.%s:8200", privateDomainName)
	}

	openbaoSecretName := fmt.Sprintf("openbao/%s/tokens/root", repoName)

	secretData, err := getSecretManager(sess, openbaoSecretName)
	if err != nil {
		return err
	}
	rootToken := secretData["token"]

	openbaoRootTokenSecret := dag.SetSecret("openbaoRootToken", rootToken)
	container = container.
		WithEnvVariable("VAULT_ADDR", openbaoAddr).
		WithEnvVariable("VAULT_SKIP_VERIFY", openbaoSkipVerify).
		WithSecretVariable("VAULT_TOKEN", openbaoRootTokenSecret).
		WithServiceBinding("tailscale", tailscaleSvc).
		WithEnvVariable("ALL_PROXY", "socks5h://tailscale:1055").
		WithEnvVariable("HTTP_PROXY", "http://tailscale:1055").
		WithEnvVariable("http_proxy", "http://tailscale:1055")

	go func() {
		defer wg.Done()
		err := destroyEKS(ctx, container, branch)
		if err != nil {
			errChan <- fmt.Errorf("failed to destroy EKS resources: %w", err)
			return
		}
	}()

	go func() {
		defer wg.Done()
		err := destroyOpenBao(ctx, container)
		if err != nil {
			errChan <- fmt.Errorf("failed to destroy OpenBao resources: %w", err)
			return
		}
	}()

	wg.Wait()

	close(errChan)
	for err := range errChan {
		if err != nil {
			return err
		}
	}

	// Destroy the network components
	err = destroyNetwork(ctx, container)
	if err != nil {
		return err
	}

	return nil
}
