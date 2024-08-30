package main

import (
	"context"
	"dagger/cloud-native-ref/internal/dagger"
	"fmt"
	"time"

	"github.com/aws/aws-sdk-go/aws"
	"github.com/aws/aws-sdk-go/aws/awserr"
	"github.com/aws/aws-sdk-go/aws/session"
	"github.com/aws/aws-sdk-go/service/eks"
)

// execKubectl executes a kubectl command with the specified arguments
func execKubectl(ctx context.Context, ctr *dagger.Container, args []string) (string, error) {
	ctr = ctr.WithExec([]string{"apk", "add", "kubectl"})
	return ctr.
		WithExec([]string{"aws", "eks", "update-kubeconfig", "--name", eksClusterName, "--region", region}).
		WithExec(append([]string{"kubectl"}, args...)).
		Stdout(ctx)
}

// createEKS creates the EKS cluster
func createEKS(ctx context.Context, ctr *dagger.Container, tfarg string, branch string) (map[string]interface{}, error) {
	workDir := "/cloud-native-ref/terraform/eks"

	output, err := tfRun(ctx, ctr, workDir, tfarg, []string{"-var-file", "variables.tfvars", "-var", fmt.Sprintf("github_branch=%s", branch)})
	if err != nil {
		return nil, fmt.Errorf("failed to create the EKS cluster: %w", err)
	}
	return output, nil
}

// destroyEKS destroys the EKS cluster
func destroyEKS(ctx context.Context, ctr *dagger.Container, sess *session.Session, branch string) error {
	workDir := "/cloud-native-ref/terraform/eks"

	// check if the EKS cluster is still there
	EKS := eks.New(sess)

	_, err := EKS.DescribeCluster(&eks.DescribeClusterInput{
		Name: aws.String(eksClusterName),
	})
	if err != nil {
		if aerr, ok := err.(awserr.Error); ok {
			if aerr.Code() == eks.ErrCodeResourceNotFoundException {
				return nil
			}
		}
		return fmt.Errorf("failed to describe the EKS cluster: %w", err)
	}

	// suspend Flux reconciliation by scaling down all deployments of the flux-system namespace
	_, err = execKubectl(ctx, ctr, []string{"scale", "deployments", "--all", "--namespace=flux-system", "--replicas=0"})
	if err != nil {
		return fmt.Errorf("failed to scale down all deployments of the flux-system namespace: %w", err)
	}

	// Delete all nodepools and wait for a minute to allow the nodes to be terminated
	_, err = execKubectl(ctx, ctr, []string{"delete", "nodepools", "--all"})
	if err != nil {
		return fmt.Errorf("failed to delete all nodepools: %w", err)
	}

	// Delete all gateways (Gateways create LoadBalancers which need to be deleted before the EKS cluster can be destroyed)
	_, err = execKubectl(ctx, ctr, []string{"delete", "gateways", "--all"})
	if err != nil {
		return fmt.Errorf("failed to delete all gateways: %w", err)
	}

	// Delete eks pod identities
	_, err = execKubectl(ctx, ctr, []string{"delete", "epis", "--all", "--all-namespaces"})
	if err != nil {
		return fmt.Errorf("failed to delete all EKS Pod Identities: %w", err)
	}

	time.Sleep(60 * time.Second)

	_, err = tfRun(ctx, ctr, workDir, "destroy", []string{"-var-file", "variables.tfvars", "-auto-approve", "-var", fmt.Sprintf("github_branch=%s", branch)})
	if err != nil {
		return fmt.Errorf("failed to destroy the EKS cluster: %w", err)
	}
	return nil
}
