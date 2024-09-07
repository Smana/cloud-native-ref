package main

import (
	"context"
	"dagger/cloud-native-ref/internal/dagger"
	"fmt"
)

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
func destroyEKS(ctx context.Context, container *dagger.Container, branch string) error {
	workDir := "/cloud-native-ref/terraform/eks"

	container = container.WithExec([]string{"apk", "add", "flux", "kubectl"})

	eksDestroyScript := `#!/bin/bash

set -e

while (($#)); do
  case "$1" in
    -c | --cluster-name) CLUSTER_NAME=${2}; shift 2;;
    -r | --region) REGION=${2}; shift 2;;
    *)
        echo "${err} : Unknown option"
        usage
        exit 3
    ;;
  esac
done

if [ -z "$CLUSTER_NAME" ] || [ -z "$REGION" ]; then
	echo "Cluster name and region are required"
	exit 1
fi

# Check if the cluster is up and running and active
if ! aws eks describe-cluster --name $CLUSTER_NAME --region $REGION --query 'cluster.status' --output text | grep -q ACTIVE; then
	echo "Cluster $CLUSTER_NAME is not active"
	exit 0
fi

# EKS get credentials
aws eks update-kubeconfig --name $CLUSTER_NAME --region $REGION

# Suspend all Flux reconciliations
flux suspend kustomization --all

NODEPOOLS=$(kubectl get nodepools -o json | jq -r '.items[].metadata.name')
if ! [ -z "$NODEPOOLS" ]; then
  kubectl delete nodepools --all
fi

GATEWAYS=($(kubectl get gateways --all-namespaces -o json | jq -r '.items[].metadata.name'))
GAPI_SVC=($(kubectl get svc --all-namespaces -l gateway.networking.k8s.io/gateway-name -o json | jq -r '.items[].metadata.name'))
if ! [ -z "$GATEWAYS" ] || ! [ -z "$GAPI_SVC" ]; then
  kubectl delete gateways --all --all-namespaces
  kubectl delete svc -l gateway.networking.k8s.io/gateway-name --all-namespaces
fi

# Wait for gateways to be deleted
sleep 30

EPIS=$(kubectl get epis -o json | jq -r '.items[].metadata.name')
if ! [ -z "$EPIS" ]; then
	kubectl delete epis --all --all-namespaces
fi

# Wait for epis to be deleted
sleep 30

# Delete flux resources from Opentofu state
tofu init
if tofu state list | grep -q "flux_bootstrap_git.this"; then
    tofu state rm flux_bootstrap_git.this
fi
if tofu state list | grep -q "kubernetes_namespace.flux_system"; then
	tofu state rm kubernetes_namespace.flux_system
fi
`

	_, err := container.
		WithWorkdir(workDir).
		WithNewFile("/bin/eks-destroy", eksDestroyScript, dagger.ContainerWithNewFileOpts{Permissions: 0750}).
		WithExec([]string{"/bin/eks-destroy", "-c", eksClusterName, "-r", region}).
		Stdout(ctx)
	if err != nil {
		return fmt.Errorf("failed to delete Kubernenes resources before destroying the EKS cluster: %w", err)
	}

	_, err = tfRun(ctx, container, workDir, "destroy", []string{"-var-file", "variables.tfvars", "-var", fmt.Sprintf("github_branch=%s", branch)})
	if err != nil {
		return fmt.Errorf("failed to destroy the EKS cluster: %w", err)
	}
	return nil
}
