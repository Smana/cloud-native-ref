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

# Reclaim CSI-provisioned volumes BEFORE any node teardown. Must run while the
# CSI controller is still schedulable, i.e. before the Karpenter NodePool
# deletion below starts draining nodes.
#
# Every step of it is plain Kubernetes and applies to any CSI driver, so it
# lives in a shared script rather than here: GKE orphaned three PD disks on the
# 2026-08-27 gcp-0 teardown for want of exactly this, and a second copy would
# have been a second thing to forget. The EBS sweep below is the AWS-specific
# half, and stays here.
"$(dirname "$0")/k8s-reclaim-csi-volumes.sh" || true

# Sweep EBS volumes this cluster orphaned in EARLIER runs. The reclaim above
# only covers PVs that still exist; anything left behind by a previous destroy
# (cluster torn down before the CSI controller could reclaim, or a PV that
# missed the 300s window) sits in the account forever. 62 volumes (~518Gi) had
# accumulated by 2026-07, and 12 more (~138Gi) from a single 2026-07-21 rebuild.
#
# Safety, in order of importance:
#   1. `status=available` ONLY — an attached volume is never a candidate. This
#      runs after the PVC deletion above, so anything detached here is genuinely
#      orphaned rather than mid-reschedule.
#   2. Scoped to THIS cluster via `kubernetes.io/cluster/<name>=owned`, the tag
#      the EBS CSI driver stamps on every volume it provisions.
#   3. Requires the `kubernetes.io/created-for/pvc/name` tag, so only
#      PVC-provisioned volumes qualify — never a hand-made or root volume.
# Set EKS_DESTROY_KEEP_VOLUMES=true to skip (e.g. to salvage data first).
echo "Sweeping EBS volumes orphaned by earlier runs of cluster ${CLUSTER_NAME}..."
if [ "${EKS_DESTROY_KEEP_VOLUMES:-false}" = "true" ]; then
	echo "EKS_DESTROY_KEEP_VOLUMES=true — skipping EBS sweep."
else
	mapfile -t ORPHAN_VOLS < <(${AWS_CMD} ec2 describe-volumes \
		--filters "Name=status,Values=available" \
		"Name=tag:kubernetes.io/cluster/${CLUSTER_NAME},Values=owned" \
		"Name=tag-key,Values=kubernetes.io/created-for/pvc/name" \
		--query 'Volumes[].VolumeId' --output text 2>/dev/null | tr '\t' '\n' | grep -v '^[[:space:]]*$' || true)
	if [ ${#ORPHAN_VOLS[@]} -eq 0 ]; then
		echo "No orphaned EBS volumes found."
	else
		echo "Deleting ${#ORPHAN_VOLS[@]} orphaned volume(s):"
		${AWS_CMD} ec2 describe-volumes --volume-ids "${ORPHAN_VOLS[@]}" \
			--query 'Volumes[].[VolumeId,Size,Tags[?Key==`kubernetes.io/created-for/pvc/name`]|[0].Value]' \
			--output text 2>/dev/null | while read -r vid vsize vpvc; do
				echo "  ${vid}  ${vsize}Gi  ${vpvc}"
			done
		for vol in "${ORPHAN_VOLS[@]}"; do
			${AWS_CMD} ec2 delete-volume --volume-id "${vol}" >/dev/null 2>&1 \
				|| echo "  WARNING: failed to delete ${vol} (may still be detaching — the next run retries)"
		done
		echo "EBS sweep done."
	fi
fi

# Reclaim the IAM access keys this cluster created. Harbor's S3 registry
# storage cannot use EKS Pod Identity (goharbor/harbor#18686 closed unmerged),
# so it authenticates as a static IAM user — and the constitution deliberately
# withholds IAM delete rights from Crossplane, so the user and its key OUTLIVE
# the cluster. AWS caps AccessKeysPerUser at 2, so after two rebuilds the quota
# is full and the THIRD rebuild's Harbor never starts: the AccessKey MR fails
# with `LimitExceeded`, its connection Secret stays empty, and harbor-registry
# dies with `CreateContainerConfigError: couldn't find key username`.
#
# Delete only the keys THIS cluster owns, read from the AccessKey managed
# resources themselves. Blanket-deleting every key on an `xplane-*` user would
# be wrong: those user names are global, so a second live cluster running
# Harbor holds the other key slot — and that is precisely how the quota fills.
#
# Order is load-bearing: the Kubernetes MR must go FIRST. Deleting the AWS key
# while its MR still exists just makes Crossplane reconcile a replacement,
# re-consuming the slot we are trying to free.
echo "Reclaiming IAM access keys owned by this cluster..."
if kubectl api-resources --api-group=iam.aws.m.upbound.io 2>/dev/null | grep -q accesskeys; then
	mapfile -t ACCESS_KEYS < <(kubectl get accesskey.iam.aws.m.upbound.io -A -o json 2>/dev/null \
		| jq -r '.items[] | select(.metadata.annotations["crossplane.io/external-name"]) | "\(.metadata.namespace)|\(.metadata.name)|\(.spec.forProvider.user // .status.atProvider.user // "")|\(.metadata.annotations["crossplane.io/external-name"])"' 2>/dev/null || true)
	if [ ${#ACCESS_KEYS[@]} -eq 0 ]; then
		echo "No AccessKey resources found."
	else
		for entry in "${ACCESS_KEYS[@]}"; do
			[ -z "${entry}" ] && continue
			ak_ns="${entry%%|*}"; rest="${entry#*|}"
			ak_name="${rest%%|*}"; rest="${rest#*|}"
			ak_user="${rest%%|*}"; ak_id="${rest##*|}"
			if [ -z "${ak_user}" ] || [ -z "${ak_id}" ]; then
				continue
			fi
			echo "  ${ak_user} / ${ak_id} (from ${ak_ns}/${ak_name})"
			# 1. Stop Crossplane managing it, so it cannot recreate the key.
			kubectl delete accesskey.iam.aws.m.upbound.io -n "${ak_ns}" "${ak_name}" --wait=false >/dev/null 2>&1 || true
			kubectl patch accesskey.iam.aws.m.upbound.io -n "${ak_ns}" "${ak_name}" --type=merge -p '{"metadata":{"finalizers":null}}' >/dev/null 2>&1 || true
			# 2. Now free the quota slot in AWS.
			${AWS_CMD} iam delete-access-key --user-name "${ak_user}" --access-key-id "${ak_id}" >/dev/null 2>&1 \
				|| echo "    WARNING: failed to delete ${ak_id} — free it manually or the next rebuild's Harbor will not start"
		done
		echo "IAM access key reclaim done."
	fi
else
	echo "AccessKey CRDs not available, skipping IAM key reclaim."
fi

# Delete Karpenter NodePools (only if CRD exists)
#
# AND THEN WAIT FOR THE NODECLAIMS TO GO. Deleting a NodePool does not terminate
# anything by itself -- it asks Karpenter to, and Karpenter runs INSIDE this
# cluster. If the control plane is destroyed while a NodeClaim is still
# draining, the EC2 instance survives with nothing left that will ever reap it.
#
# Measured 2026-09-02: a teardown left two instances running, both tagged
# kubernetes.io/cluster/<cluster>=owned. One had been launched A MINUTE AFTER
# the teardown began, because this script drains workloads and Karpenter
# provisioned for the pods that went pending. Their ENIs held two security
# groups, `tofu destroy` failed with DependencyViolation, and since that stack
# failed the whole --reverse sweep stopped there -- leaving an entire SECOND
# CLOUD untouched and running. One orphaned node, two clusters still billing.
echo "Checking for Karpenter NodePools..."
if kubectl api-resources --api-group=karpenter.sh 2>/dev/null | grep -q nodepools; then
	mapfile -t NODEPOOLS < <(kubectl get nodepools -o json 2>/dev/null | jq -r '.items[].metadata.name' 2>/dev/null || echo "")
	if [ -n "${NODEPOOLS[*]}" ]; then
		echo "Deleting NodePools: ${NODEPOOLS[*]}"
		kubectl delete nodepools --all 2>/dev/null || echo "Failed to delete some NodePools"
	else
		echo "No NodePools found"
	fi

	# Bounded: this is best-effort cleanup, not a gate. If Karpenter cannot
	# finish (it may already be evicted), say so loudly and name the sweep --
	# a warning the operator can act on beats a hang, and beats silence.
	if kubectl api-resources --api-group=karpenter.sh 2>/dev/null | grep -q nodeclaims; then
		echo "Waiting for Karpenter NodeClaims to terminate (up to 300s)..."
		for _ in $(seq 1 60); do
			remaining="$(kubectl get nodeclaims -o json 2>/dev/null | jq -r '.items | length' 2>/dev/null || echo 0)"
			[ "${remaining:-0}" = "0" ] && break
			sleep 5
		done
		remaining="$(kubectl get nodeclaims -o json 2>/dev/null | jq -r '.items | length' 2>/dev/null || echo 0)"
		if [ "${remaining:-0}" = "0" ]; then
			echo "All NodeClaims terminated."
		else
			echo "[warn] ${remaining} NodeClaim(s) still present. Their EC2 instances will"
			echo "[warn] outlive the cluster and their ENIs will block security-group"
			echo "[warn] deletion with DependencyViolation. After the destroy, sweep them:"
			echo "[warn]   aws ec2 describe-instances --region <region> \\"
			echo "[warn]     --filters Name=tag:kubernetes.io/cluster/<cluster>,Values=owned \\"
			echo "[warn]               Name=instance-state-name,Values=running"
		fi
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
# NOTE: IAM access KEYS and CSI EBS volumes are no longer in that manual list —
# both are reclaimed automatically earlier in this script. Roles, policies and
# S3 buckets still are: they are re-adopted by name on the next apply, so they
# cost nothing to leave behind, whereas keys hit a hard quota of 2 per user.
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

# Sweep the load-balancer security groups this cluster's controllers created.
#
# The AWS Load Balancer Controller creates security groups for the NLBs behind
# Gateway API / Service type=LoadBalancer, and they OUTLIVE the load balancers
# they belong to. Nothing in the OpenTofu graph owns them, so `tofu destroy` on
# opentofu/aws/network then fails at the very last resource with
#
#   Error: deleting EC2 VPC (vpc-...): DependencyViolation:
#   The vpc '...' has dependencies and cannot be deleted.
#
# after every other resource in the stack is already gone. Measured on the
# 2026-08-23 rebuild: three left behind -- k8s-traffic-<cluster>-*,
# k8s-security-ciliumga-*, k8s-infrastr-ciliumga-*.
#
# This runs LAST, and waits for the load balancers to actually disappear first:
# deleting a Gateway starts LB teardown asynchronously, and a security group
# still attached to a live LB cannot be deleted.
#
# Scoped by the controller's own `elbv2.k8s.aws/cluster` tag, not by an
# `k8s-*` name match. Those names are not unique to a cluster, and a second
# cluster sharing this VPC would have its groups swept too -- the same reasoning
# that keeps the IAM key reclaim above tied to this cluster's own resources.
echo "Sweeping load-balancer security groups owned by cluster ${CLUSTER_NAME}..."
if [ "${EKS_DESTROY_KEEP_SECURITY_GROUPS:-false}" = "true" ]; then
	echo "EKS_DESTROY_KEEP_SECURITY_GROUPS=true — skipping security group sweep."
else
	CLUSTER_VPC=$(${AWS_CMD} eks describe-cluster --name "${CLUSTER_NAME}" \
		--query 'cluster.resourcesVpcConfig.vpcId' --output text 2>/dev/null || echo "")

	if [ -z "${CLUSTER_VPC}" ] || [ "${CLUSTER_VPC}" = "None" ]; then
		echo "Could not determine the cluster VPC — skipping (cluster may already be gone)."
	else
		# Wait for the LBs to go. Their security groups cannot be deleted while
		# they are attached, and Gateway deletion above only STARTS that teardown.
		for _ in $(seq 1 30); do
			LB_COUNT=$(${AWS_CMD} elbv2 describe-load-balancers \
				--query "length(LoadBalancers[?VpcId=='${CLUSTER_VPC}'])" \
				--output text 2>/dev/null || echo "0")
			[ "${LB_COUNT}" = "0" ] && break
			echo "  waiting for ${LB_COUNT} load balancer(s) to finish deleting..."
			sleep 10
		done

		# Several passes: these groups reference each other, so a group can be
		# undeletable on one pass and deletable on the next once its referrer is
		# gone. Four passes has been ample; the VPC destroy surfaces anything left.
		for _ in 1 2 3 4; do
			mapfile -t ORPHAN_SGS < <(${AWS_CMD} ec2 describe-security-groups \
				--filters "Name=vpc-id,Values=${CLUSTER_VPC}" \
				"Name=tag:elbv2.k8s.aws/cluster,Values=${CLUSTER_NAME}" \
				--query 'SecurityGroups[?GroupName!=`default`].GroupId' \
				--output text 2>/dev/null | tr '\t' '\n' | grep -v '^[[:space:]]*$' || true)
			[ ${#ORPHAN_SGS[@]} -eq 0 ] && break
			for sg in "${ORPHAN_SGS[@]}"; do
				if ${AWS_CMD} ec2 delete-security-group --group-id "${sg}" >/dev/null 2>&1; then
					echo "  deleted ${sg}"
				fi
			done
		done

		# Report anything still in the VPC. These are NOT deleted -- they may
		# belong to something else entirely -- but naming them here turns a
		# DependencyViolation at the end of `tofu destroy` into a warning that
		# says which groups to look at.
		mapfile -t REMAINING_SGS < <(${AWS_CMD} ec2 describe-security-groups \
			--filters "Name=vpc-id,Values=${CLUSTER_VPC}" \
			--query 'SecurityGroups[?GroupName!=`default`].[GroupId,GroupName]' \
			--output text 2>/dev/null | grep -v '^[[:space:]]*$' || true)
		if [ ${#REMAINING_SGS[@]} -eq 0 ]; then
			echo "No security groups left in ${CLUSTER_VPC} beyond the default."
		else
			echo "WARNING: ${#REMAINING_SGS[@]} non-default security group(s) remain in ${CLUSTER_VPC}."
			echo "         If the VPC destroy fails with DependencyViolation, start here:"
			printf '           %s\n' "${REMAINING_SGS[@]}"
		fi
	fi
fi

echo "Cluster cleanup completed successfully"
