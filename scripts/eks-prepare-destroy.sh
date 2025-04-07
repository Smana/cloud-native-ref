#!/bin/bash

set -e

# This script is used to prepare the EKS cluster for destruction.

usage() {
  echo "Usage: $0 --cluster-name <cluster-name> --region <region> --profile <profile>"
  exit 1
}

while (($#)); do
  case "$1" in
    -c | --cluster-name) CLUSTER_NAME=${2}; shift 2;;
    -r | --region) REGION=${2}; shift 2;;
    -p | --profile) PROFILE=${2}; shift 2;;
    *)
        echo "${err} : Unknown option"
        usage
        exit 3
    ;;
  esac
done

echo "This script will delete the EKS cluster $CLUSTER_NAME in region $REGION"
echo "This action is irreversible and will delete all resources in the cluster"
echo "Please ensure you have backed up any important data before proceeding"
read -p "Are you sure you want to proceed? (y/n): " confirm
if [ "$confirm" != "y" ]; then
  echo "Exiting..."
  exit 0
fi


if [ -z "$CLUSTER_NAME" ] || [ -z "$REGION" ]; then
	echo "Cluster name and region are required"
	exit 1
fi

# Common function to get AWS command
get_aws_cmd() {
    if [ -n "$PROFILE" ]; then
        echo "aws --profile $PROFILE --region $REGION"
    else
        echo "aws --region $REGION"
    fi

}

AWS_CMD=$(get_aws_cmd)

# Check if the cluster is up and running and active
if ! $AWS_CMD eks describe-cluster --name $CLUSTER_NAME --query 'cluster.status' --output text | grep -q ACTIVE; then
	echo "Cluster $CLUSTER_NAME is not active"
	exit 0
fi

# EKS get credentials
$AWS_CMD eks update-kubeconfig --name $CLUSTER_NAME --alias $CLUSTER_NAME

# Suspend all Flux reconciliations
if $(kubectl get ns flux-system &>/dev/null); then
	flux suspend kustomization --all
fi

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
