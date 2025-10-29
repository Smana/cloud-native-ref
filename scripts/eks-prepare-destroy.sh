#!/bin/bash

set -e

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

# Suspend all Flux reconciliations
if kubectl get ns flux-system &>/dev/null; then
	flux suspend kustomization --all
fi

# Use mapfile to properly handle array creation
mapfile -t NODEPOOLS < <(kubectl get nodepools -o json | jq -r '.items[].metadata.name')
if [ -n "${NODEPOOLS[*]}" ]; then
  kubectl delete nodepools --all
fi

# Use mapfile for arrays
mapfile -t GATEWAYS < <(kubectl get gateways --all-namespaces -o json | jq -r '.items[].metadata.name')
mapfile -t GAPI_SVC < <(kubectl get svc --all-namespaces -l gateway.networking.k8s.io/gateway-name -o json | jq -r '.items[].metadata.name')
if [ -n "${GATEWAYS[*]}" ] || [ -n "${GAPI_SVC[*]}" ]; then
  kubectl delete gateways --all --all-namespaces
  kubectl delete svc -l gateway.networking.k8s.io/gateway-name --all-namespaces
fi

# Wait for gateways to be deleted
sleep 30

# Clean up DNS records in Route53 to prevent stale records
echo "🧹 Cleaning up DNS records in Route53..."
DOMAIN="priv.cloud.ogenki.io"
ZONE_ID=$(${AWS_CMD} route53 list-hosted-zones --query "HostedZones[?Name=='${DOMAIN}.'].Id" --output text | cut -d'/' -f3)

if [ -n "${ZONE_ID}" ]; then
  echo "  Found hosted zone: ${ZONE_ID}"

  # Get all A records (excluding NS and SOA)
  RECORDS=$(${AWS_CMD} route53 list-resource-record-sets \
    --hosted-zone-id "${ZONE_ID}" \
    --query "ResourceRecordSets[?Type=='A' && contains(Name, '${DOMAIN}')].Name" \
    --output text)

  # Delete each A record (except the zone apex)
  for record in ${RECORDS}; do
    # Skip bao.priv.cloud.ogenki.io (OpenBao - managed separately)
    if [[ "${record}" == "bao.${DOMAIN}." ]]; then
      echo "  Skipping OpenBao record: ${record}"
      continue
    fi

    echo "  Deleting DNS record: ${record}"
    RECORD_VALUE=$(${AWS_CMD} route53 list-resource-record-sets \
      --hosted-zone-id "${ZONE_ID}" \
      --query "ResourceRecordSets[?Name=='${record}' && Type=='A'].ResourceRecords[0].Value" \
      --output text)

    if [ -n "${RECORD_VALUE}" ]; then
      ${AWS_CMD} route53 change-resource-record-sets \
        --hosted-zone-id "${ZONE_ID}" \
        --change-batch "{\"Changes\":[{\"Action\":\"DELETE\",\"ResourceRecordSet\":{\"Name\":\"${record}\",\"Type\":\"A\",\"TTL\":300,\"ResourceRecords\":[{\"Value\":\"${RECORD_VALUE}\"}]}}]}" \
        2>/dev/null || echo "  ⚠️  Failed to delete ${record} (may already be deleted)"
    fi
  done

  # Clean up associated TXT records
  echo "  Cleaning up TXT ownership records..."
  TXT_RECORDS=$(${AWS_CMD} route53 list-resource-record-sets \
    --hosted-zone-id "${ZONE_ID}" \
    --query "ResourceRecordSets[?Type=='TXT' && contains(Name, '${DOMAIN}')].Name" \
    --output text)

  for txt_record in ${TXT_RECORDS}; do
    TXT_VALUE=$(${AWS_CMD} route53 list-resource-record-sets \
      --hosted-zone-id "${ZONE_ID}" \
      --query "ResourceRecordSets[?Name=='${txt_record}' && Type=='TXT'].ResourceRecords[0].Value" \
      --output text)

    if [ -n "${TXT_VALUE}" ]; then
      ${AWS_CMD} route53 change-resource-record-sets \
        --hosted-zone-id "${ZONE_ID}" \
        --change-batch "{\"Changes\":[{\"Action\":\"DELETE\",\"ResourceRecordSet\":{\"Name\":\"${txt_record}\",\"Type\":\"TXT\",\"TTL\":300,\"ResourceRecords\":[{\"Value\":${TXT_VALUE}}]}}]}" \
        2>/dev/null || true
    fi
  done

  echo "✅ DNS cleanup complete"
else
  echo "⚠️  Hosted zone not found for ${DOMAIN}"
fi

# Use mapfile for array
mapfile -t EPIS < <(kubectl get epis -o json | jq -r '.items[].metadata.name')
if [ -n "${EPIS[*]}" ]; then
	kubectl delete epis --all --all-namespaces
fi

# Wait for epis to be deleted
sleep 30
