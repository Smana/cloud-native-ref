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
# Same env-var bypass as scripts/terramate-destroy-confirm.sh — lets a
# `terramate script run --reverse destroy` orchestrate this prep step
# without a second human prompt after the user already consented once.
if [ "${TM_DESTROY_CONFIRMED:-false}" = "true" ]; then
  echo "[eks-prepare-destroy] TM_DESTROY_CONFIRMED=true — skipping interactive prompt."
else
  read -r -p "Are you sure you want to proceed? (y/n): " confirm
  if [ "${confirm}" != "y" ]; then
    echo "Exiting..."
    exit 0
  fi
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

# Disable Kyverno's `failurePolicy: Fail` admission webhooks BEFORE
# nodes go away. Once the kyverno-svc Service has no endpoints (its pods
# evicted with the nodes), every kubectl delete in this script and
# every delete tofu issues against the apiserver fails with:
#   Internal error occurred: failed calling webhook "validate.kyverno.svc-fail":
#   no endpoints available for service "kyverno-svc"
# Same pattern for cilium-operator's mutating webhook on Cilium endpoints.
echo "Disabling validating/mutating webhooks that would block deletes..."
for hook_kind in validatingwebhookconfigurations mutatingwebhookconfigurations; do
	# Targeted: anything labeled kyverno or cilium-system component.
	kubectl delete "$hook_kind" -l app.kubernetes.io/part-of=kyverno --wait=false 2>/dev/null || true
	# Defensive: anything whose name contains kyverno (covers chart variants
	# that don't ship the part-of label).
	kubectl get "$hook_kind" -o name 2>/dev/null | grep -iE "kyverno|cilium-operator" \
		| xargs -r kubectl delete --wait=false 2>/dev/null || true
done
# ValidatingAdmissionPolicyBinding (Gateway API ships
# `safe-upgrades.gateway.networking.k8s.io` which blocks CRD downgrades —
# also fires during destroy when the gateway-api CRDs go away).
kubectl delete validatingadmissionpolicybinding --all --wait=false 2>/dev/null || true

# Reclaim CSI-provisioned volumes BEFORE any node teardown. Destroying the
# cluster with PVCs still bound skips the reclaim (the EBS CSI controller
# dies with the cluster) and every PVC-backed EBS volume is orphaned in the
# account — 62 volumes (~518Gi) had accumulated across rebuilds by 2026-07.
# Must run while the CSI controller is schedulable, i.e. before the
# Karpenter NodePool deletion below starts draining nodes.
echo "Reclaiming CSI-provisioned volumes..."

# 1. Belt-and-braces: make every PV reclaimable (covers future Retain PVs).
for pv in $(kubectl get pv -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
	kubectl patch pv "$pv" --type=merge -p '{"spec":{"persistentVolumeReclaimPolicy":"Delete"}}' >/dev/null 2>&1 || true
done

# 2. CNPG clusters own their pods AND PVCs (recreating both if deleted from
#    under them) — delete the Cluster CRs so the operator reclaims cleanly.
if kubectl api-resources --api-group=postgresql.cnpg.io 2>/dev/null | grep -q clusters; then
	kubectl delete clusters.postgresql.cnpg.io --all --all-namespaces --wait=false 2>/dev/null || true
fi

# 3. Scale to 0 exactly the Deployments/StatefulSets that mount PVCs (STS
#    would recreate PVCs from their templates if we only deleted pods).
#    Selecting by PVC-presence never touches kube-system's CSI controller.
kubectl get deploy,statefulset --all-namespaces -o json 2>/dev/null \
	| jq -r '.items[] | select((([.spec.template.spec.volumes[]? | select(.persistentVolumeClaim)] | length) > 0) or (((.spec.volumeClaimTemplates // []) | length) > 0)) | "\(.kind|ascii_downcase) \(.metadata.namespace) \(.metadata.name)"' 2>/dev/null \
	| while read -r kind ns name; do
		[ -z "$name" ] && continue
		kubectl scale "$kind" -n "$ns" "$name" --replicas=0 >/dev/null 2>&1 || true
	done

# 4. Catch-all for remaining PVC-mounting pods (Jobs, naked pods): PVC
#    deletion blocks on the pvc-protection finalizer while any pod uses it.
kubectl get pods --all-namespaces -o json 2>/dev/null \
	| jq -r '.items[] | select(([.spec.volumes[]? | select(.persistentVolumeClaim)] | length) > 0) | "\(.metadata.namespace) \(.metadata.name)"' 2>/dev/null \
	| while read -r ns name; do
		[ -z "$name" ] && continue
		kubectl delete pod -n "$ns" "$name" --wait=false 2>/dev/null || true
	done

# 5. Delete the PVCs and wait for the CSI driver to reclaim every PV (the
#    moment the PV list is empty, the EBS volumes are gone from AWS too).
kubectl delete pvc --all --all-namespaces --wait=false 2>/dev/null || true
echo "Waiting for PersistentVolumes to be reclaimed (up to 300s)..."
for _ in $(seq 1 60); do
	pv_count=$(kubectl get pv --no-headers 2>/dev/null | wc -l)
	[ "$pv_count" = "0" ] && break
	sleep 5
done
if [ "${pv_count:-0}" != "0" ]; then
	echo "WARNING: ${pv_count} PV(s) not reclaimed — their backing volumes will be orphaned:"
	kubectl get pv -o jsonpath='{range .items[*]}{.metadata.name}{" -> "}{.spec.csi.volumeHandle}{"\n"}{end}' 2>/dev/null || true
	echo "Clean them up after destroy: aws ec2 describe-volumes --filters Name=status,Values=available Name=tag-key,Values=kubernetes.io/created-for/pvc/name"
else
	echo "All PersistentVolumes reclaimed."
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

# Delete Gateway API resources (only if CRD exists).
# Order matters: HTTPRoute → Gateway → GatewayClass. Each level holds a
# finalizer cleared by the gateway controller; if controllers are already
# gone (Flux suspend above stops them), strip finalizers so tofu's
# subsequent CRD destroy doesn't block for hours on a leftover CR.
strip_finalizers_for_kind() {
	local kind="$1"
	local ns_flag="$2"       # "--all-namespaces" or "" for cluster-scoped
	local selector="${3:-}"  # optional label selector
	# shellcheck disable=SC2086
	for ref in $(kubectl get "$kind" $ns_flag ${selector:+-l "$selector"} -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name} {end}' 2>/dev/null); do
		local ns="${ref%/*}" name="${ref#*/}"
		[ -z "$name" ] && continue
		if [ -n "$ns" ] && [ "$ns" != "/" ]; then
			kubectl patch "$kind" -n "$ns" "$name" --type=merge -p '{"metadata":{"finalizers":null}}' >/dev/null 2>&1 || true
		else
			kubectl patch "$kind" "$name" --type=merge -p '{"metadata":{"finalizers":null}}' >/dev/null 2>&1 || true
		fi
	done
}

echo "Checking for Gateway API resources..."
if kubectl api-resources --api-group=gateway.networking.k8s.io 2>/dev/null | grep -q gateways; then
	# 1. HTTPRoutes / GRPCRoutes / TCPRoutes / TLSRoutes
	for route_kind in httproute grpcroute tcproute tlsroute udproute; do
		if kubectl api-resources --api-group=gateway.networking.k8s.io 2>/dev/null | grep -qw "${route_kind}s"; then
			kubectl delete "${route_kind}" --all --all-namespaces --wait=false 2>/dev/null || true
			strip_finalizers_for_kind "$route_kind" --all-namespaces
		fi
	done
	# 2. Gateways
	mapfile -t GATEWAYS < <(kubectl get gateways --all-namespaces -o json 2>/dev/null | jq -r '.items[].metadata.name' 2>/dev/null || echo "")
	if [ -n "${GATEWAYS[*]}" ]; then
		echo "Deleting Gateways: ${GATEWAYS[*]}"
		kubectl delete gateways --all --all-namespaces --wait=false 2>/dev/null || true
		# Cilium-gateway-spawned Services (cilium-gateway-<gw-name>) can carry
		# external-controller finalizers — `tailscale.com/finalizer` for
		# loadBalancerClass=tailscale, `service.k8s.aws/resources` for AWS LBC.
		# By this point Cilium / cluster DNS may already be degraded (NodePool
		# delete above started draining nodes), so the controller can't reach
		# its external API to clear the finalizer and tofu destroy hangs on
		# the orphan Service forever. Strip it as a safety net.
		# Side-effect (Tailscale): the matching device stays registered on the
		# tailnet — clean it up from https://login.tailscale.com/admin/machines.
		kubectl delete svc -l gateway.networking.k8s.io/gateway-name --all-namespaces --wait=false 2>/dev/null || true
		strip_finalizers_for_kind svc --all-namespaces gateway.networking.k8s.io/gateway-name
		strip_finalizers_for_kind gateway --all-namespaces
	fi
	# 3. GatewayClasses (cluster-scoped) — these hold the finalizer that
	#    blocks the gatewayclasses CRD destroy if the controller is gone.
	#    Includes Cilium classes (`cilium`, `cilium-tailscale`) and
	#    Envoy AI Gateway (`envoy-ai-gateway`).
	if kubectl get gatewayclass >/dev/null 2>&1; then
		kubectl delete gatewayclass --all --wait=false 2>/dev/null || true
		strip_finalizers_for_kind gatewayclass ""
	fi
	echo "Waiting for Gateway API CR cleanup to settle..."
	sleep 15
else
	echo "Gateway API CRDs not available, skipping Gateway deletion"
fi

# Envoy Gateway / AI Gateway extension CRs (Backend, EnvoyProxy,
# ClientTrafficPolicy, EnvoyExtensionPolicy, AIGatewayRoute, etc.).
# Same pattern: their controllers add finalizers; clear them now so
# the corresponding CRDs can drop cleanly.
echo "Checking for Envoy Gateway / AI Gateway extension resources..."
for kind_group in \
	"backend gateway.envoyproxy.io" \
	"envoyproxy gateway.envoyproxy.io" \
	"clienttrafficpolicy gateway.envoyproxy.io" \
	"backendtrafficpolicy gateway.envoyproxy.io" \
	"envoyextensionpolicy gateway.envoyproxy.io" \
	"securitypolicy gateway.envoyproxy.io" \
	"aigatewayroute aigateway.envoyproxy.io" \
	"aiservicebackend aigateway.envoyproxy.io"; do
	read -r kind group <<<"$kind_group"
	if kubectl api-resources --api-group="$group" 2>/dev/null | grep -qw "${kind}s\|${kind}"; then
		kubectl delete "$kind" --all --all-namespaces --wait=false 2>/dev/null || true
		strip_finalizers_for_kind "$kind" --all-namespaces
	fi
done

# InferencePool CRs (gateway-api-inference-extension) — EPP controller
# finalizer blocks the inferencepools CRD destroy.
if kubectl api-resources --api-group=inference.networking.k8s.io 2>/dev/null | grep -q inferencepool; then
	kubectl delete inferencepool --all --all-namespaces --wait=false 2>/dev/null || true
	strip_finalizers_for_kind inferencepool --all-namespaces
fi

# Delete EKS Pod Identity associations (only if CRD exists)
echo "Checking for EKS Pod Identity resources..."
if kubectl api-resources 2>/dev/null | grep -q "ekspodidentities\|epis"; then
	mapfile -t EPIS < <(kubectl get epis --all-namespaces -o json 2>/dev/null | jq -r '.items[].metadata.name' 2>/dev/null || echo "")
	if [ -n "${EPIS[*]}" ]; then
		echo "Deleting EKS Pod Identities: ${EPIS[*]}"
		# --wait=false: kubectl default waits for full deletion, which hangs
		# forever if Crossplane is unhealthy (controller pods unschedulable
		# because Cilium/CNI is already gone — typical mid-destroy state).
		kubectl delete epis --all --all-namespaces --wait=false 2>/dev/null || echo "Failed to issue some EPI deletes"
	else
		echo "No EKS Pod Identities found"
	fi
else
	echo "EKS Pod Identity CRDs not available, skipping EPI deletion"
fi

# The Crossplane composite finalizer only clears when its controller drains
# the composed MRs via the AWS API; if Crossplane is dead (no Cilium ⇒ no
# CNI ⇒ pods unschedulable), it never clears and tofu destroy hangs on the
# namespace deletion.
# Side-effect: composed AWS resources (xplane-* IAM Roles, Policies,
# RolePolicyAttachments, S3 buckets) are orphaned. EKS PodIdentity
# associations vanish with the cluster. Clean up xplane-* IAM resources
# manually after tofu destroy finishes:
#   aws iam list-roles --query 'Roles[?starts_with(RoleName, `xplane-`)].RoleName' --output text
echo "Stripping Crossplane composite finalizers from any stuck XRs..."
if kubectl api-resources --api-group=apiextensions.crossplane.io 2>/dev/null | grep -q .; then
	# Wait briefly for natural cleanup before forcing
	for _ in 1 2 3 4 5 6; do
		any=$(kubectl get xr -A -o json 2>/dev/null | jq '[.items[] | select(.metadata.deletionTimestamp != null)] | length' 2>/dev/null || echo 0)
		[ "$any" = "0" ] && break
		sleep 5
	done
	# `kubectl get xr` covers every composite XR kind cluster-wide. Use jq
	# to filter (kubectl jsonpath's filter expression is unreliable across
	# versions) and emit kind/ns/name triples for terminating XRs only.
	for ref in $(kubectl get xr -A -o json 2>/dev/null | jq -r '.items[] | select(.metadata.deletionTimestamp) | "\(.kind)/\(.metadata.namespace // "")/\(.metadata.name)"' 2>/dev/null); do
		kind="${ref%%/*}"
		rest="${ref#*/}"
		ns="${rest%/*}"
		name="${rest#*/}"
		[ -z "$name" ] && continue
		if [ -n "$ns" ]; then
			kubectl patch "$kind" -n "$ns" "$name" --type=merge -p '{"metadata":{"finalizers":null}}' >/dev/null 2>&1 || true
		else
			kubectl patch "$kind" "$name" --type=merge -p '{"metadata":{"finalizers":null}}' >/dev/null 2>&1 || true
		fi
	done
fi

echo "Cluster cleanup completed successfully"
