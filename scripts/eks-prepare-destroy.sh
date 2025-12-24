#!/bin/bash

# Don't use set -e globally - we want to handle errors gracefully during cleanup
# set -e

# Define error message variable
err="ERROR"

# This script is used to prepare the EKS cluster for destruction.

usage() {
  echo "Usage: $0 --cluster-name <cluster-name> --region <region> --profile <profile>"
  exit 1
}

# Initialize variables
CLUSTER_NAME=""
REGION=""
PROFILE=""

while (($#)); do
  case "$1" in
    -c | --cluster-name) CLUSTER_NAME="${2}"; shift 2;;
    -r | --region) REGION="${2}"; shift 2;;
    -p | --profile) PROFILE="${2}"; shift 2;;
    -h | --help) usage;;
    *)
        echo "${err} : Unknown option"
        usage
    ;;
  esac
done

# Validate required parameters
if [ -z "${CLUSTER_NAME}" ] || [ -z "${REGION}" ]; then
	echo "Cluster name and region are required"
	usage
fi

echo "This script will delete the EKS cluster ${CLUSTER_NAME} in region ${REGION}"
echo "This action is irreversible and will delete all resources in the cluster"
echo "Please ensure you have backed up any important data before proceeding"
read -r -p "Are you sure you want to proceed? (y/n): " confirm
if [ "${confirm}" != "y" ]; then
  echo "Exiting..."
  exit 0
fi

# Common function to get AWS command
get_aws_cmd() {
    if [ -n "${PROFILE}" ]; then
        echo "aws --profile ${PROFILE} --region ${REGION}"
    else
        echo "aws --region ${REGION}"
    fi
}

AWS_CMD=$(get_aws_cmd)

# Check if the cluster is up and running and active
if ! ${AWS_CMD} eks describe-cluster --name "${CLUSTER_NAME}" --query 'cluster.status' --output text | grep -q ACTIVE; then
	echo "Cluster ${CLUSTER_NAME} is not active"
	exit 0
fi

# EKS get credentials
${AWS_CMD} eks update-kubeconfig --name "${CLUSTER_NAME}" --alias "${CLUSTER_NAME}"

# Suspend all Flux reconciliations (only if Flux CRDs are available)
echo "Checking for Flux resources..."
if kubectl api-resources --api-group=kustomize.toolkit.fluxcd.io &>/dev/null; then
	echo "Suspending Flux kustomizations..."
	flux suspend kustomization --all 2>/dev/null || echo "No Flux kustomizations to suspend"
else
	echo "Flux CRDs not available, skipping Flux suspension"
fi

# Delete Karpenter NodePools (only if CRD exists)
echo "Checking for Karpenter NodePools..."
if kubectl api-resources --api-group=karpenter.sh 2>/dev/null | grep -q nodepools; then
	mapfile -t NODEPOOLS < <(kubectl get nodepools -o json 2>/dev/null | jq -r '.items[].metadata.name' 2>/dev/null || echo "")
	if [ -n "${NODEPOOLS[*]}" ]; then
		echo "Deleting NodePools: ${NODEPOOLS[*]}"
		kubectl delete nodepools --all 2>/dev/null || echo "Failed to delete some NodePools"
	else
		echo "No NodePools found"
	fi
else
	echo "Karpenter CRDs not available, skipping NodePool deletion"
fi

# Delete Gateway API resources (only if CRD exists)
echo "Checking for Gateway API resources..."
if kubectl api-resources --api-group=gateway.networking.k8s.io 2>/dev/null | grep -q gateways; then
	mapfile -t GATEWAYS < <(kubectl get gateways --all-namespaces -o json 2>/dev/null | jq -r '.items[].metadata.name' 2>/dev/null || echo "")
	if [ -n "${GATEWAYS[*]}" ]; then
		echo "Deleting Gateways: ${GATEWAYS[*]}"
		kubectl delete gateways --all --all-namespaces 2>/dev/null || echo "Failed to delete some Gateways"
		kubectl delete svc -l gateway.networking.k8s.io/gateway-name --all-namespaces 2>/dev/null || true
		# Wait for gateways to be deleted
		echo "Waiting for Gateways to be deleted..."
		sleep 30
	else
		echo "No Gateways found"
	fi
else
	echo "Gateway API CRDs not available, skipping Gateway deletion"
fi

# Delete EKS Pod Identity associations (only if CRD exists)
echo "Checking for EKS Pod Identity resources..."
if kubectl api-resources 2>/dev/null | grep -q "ekspodidentities\|epis"; then
	mapfile -t EPIS < <(kubectl get epis --all-namespaces -o json 2>/dev/null | jq -r '.items[].metadata.name' 2>/dev/null || echo "")
	if [ -n "${EPIS[*]}" ]; then
		echo "Deleting EKS Pod Identities: ${EPIS[*]}"
		kubectl delete epis --all --all-namespaces 2>/dev/null || echo "Failed to delete some EPIs"
		# Wait for epis to be deleted
		echo "Waiting for EPIs to be deleted..."
		sleep 30
	else
		echo "No EKS Pod Identities found"
	fi
else
	echo "EKS Pod Identity CRDs not available, skipping EPI deletion"
fi

echo "Cluster cleanup completed successfully"
