#!/usr/bin/env bash
# Recycle EKS managed-node-group nodes whose ENIs predate Cilium.
#
# WHY THIS EXISTS
# ---------------
# The platform bootstraps in two stages: Stage 1 creates the EKS cluster with the
# temporary VPC CNI, Stage 2 replaces it with Cilium. The managed-node-group nodes
# therefore exist BEFORE Cilium does. When Cilium takes over it creates its own
# ENIs on them, but it fills those ENIs with individual secondary IPs rather than
# /28 prefixes — and that allocation is sticky. Cilium never converts an existing
# secondary-IP ENI to prefix delegation.
#
# The result is a permanent, invisible capacity cliff on exactly the bootstrap
# nodes. Measured on aws-0 (2026-08-02):
#
#   node             instance          provisioner   prefixes   usable IPs
#   ip-10-0-8-142    c7i-flex.xlarge   Karpenter     2          ~240
#   ip-10-0-3-147    c7i-flex.xlarge   EKS MNG       0          42
#   ip-10-0-9-161    c7i-flex.xlarge   EKS MNG       0          42
#
# Same instance type, opposite outcome — the split is *when* the node was created,
# not what it is. The 42-IP nodes then hit `no IPs currently available on the node`
# and wedge unrelated things: a DaemonSet pod that cannot get an IP keeps its
# DaemonSet at InProgress, so Helm's --wait times out and a HelmRelease in a
# completely different namespace reports InstallFailed. That cost hours to trace.
#
# Recycling the node after Cilium is healthy makes the replacement come up with
# Cilium already running, so its ENIs get prefixes.
#
# SAFETY
# ------
# Idempotent by construction: it inspects each node's CiliumNode and only recycles
# ones that actually lack prefixes. On a healthy cluster it is a no-op, so it is
# safe to run on every deploy. Nodes are recycled ONE AT A TIME, waiting for the
# replacement to be Ready before continuing.
#
# Usage: eks-recycle-bootstrap-nodes.sh --cluster-name <name> --region <region> [--profile <profile>]

set -uo pipefail

CLUSTER_NAME=""
REGION=""
PROFILE=""
# Belt and braces: never touch more than this many nodes in one run.
MAX_RECYCLE="${EKS_RECYCLE_MAX:-4}"

usage() {
	echo "Usage: $0 --cluster-name <cluster-name> --region <region> [--profile <profile>]"
	exit 1
}

while [[ $# -gt 0 ]]; do
	case "$1" in
	--cluster-name)
		CLUSTER_NAME="$2"
		shift 2
		;;
	--region)
		REGION="$2"
		shift 2
		;;
	--profile)
		PROFILE="$2"
		shift 2
		;;
	*)
		echo "Unknown option: $1"
		usage
		;;
	esac
done

[[ -z "$CLUSTER_NAME" || -z "$REGION" ]] && usage

if [[ -n "$PROFILE" ]]; then
	AWS_CMD="aws --profile ${PROFILE} --region ${REGION}"
else
	AWS_CMD="aws --region ${REGION}"
fi

echo "==> Checking for bootstrap nodes with pre-Cilium ENIs (cluster: ${CLUSTER_NAME})"

# WAIT FOR CILIUM BEFORE ASKING CILIUM ANYTHING.
#
# The prefix-delegation check below reads `cilium-config`, a ConfigMap that
# CILIUM CREATES. The helm_release that installs Cilium runs with wait=false, so
# reaching this script does not imply the ConfigMap exists yet -- and the check
# used to run FIRST, before this wait.
#
# Measured 2026-09-04 on a from-scratch bootstrap. The script read the key as
# unset, concluded prefix delegation was off, and exited without recycling
# anything:
#
#   ==> Checking for bootstrap nodes with pre-Cilium ENIs (cluster: aws-0)
#       Prefix delegation is not enabled (aws-enable-prefix-delegation=<unset>) — nothing to do.
#
# The setting was correct all along; the ConfigMap simply was not populated yet.
# `kubectl get cm cilium-config -o jsonpath=...` returned empty and the script
# treated "I could not read it" as "it is off" -- the same
# absent-versus-unknown conflation that #1963 and #1964 both turned on.
#
# The cost was the entire bootstrap. The bootstrap nodes kept their pre-Cilium
# ~18-IP pools, function-auto-ready's pod sat in ContainerCreating for over an
# hour on `all CIDR ranges are exhausted`, so the function never went healthy,
# so every Composition calling it failed, so every EPI failed, so infrastructure
# never reconciled, so no CNPG cluster was ever created and ZITADEL never
# started. Every layer reported itself healthy except the bottom one.
#
# Waiting first costs nothing when prefix delegation is off: the wait succeeds,
# the check then reads a populated ConfigMap and exits cleanly as before.

# Point kubectl at THIS cluster before asking it anything.
#
# The platform is destroyed and rebuilt routinely, and a new EKS cluster gets a
# new API endpoint and CA. So a kubeconfig left over from the previous build is
# the NORMAL state here, not an edge case -- and every kubectl call below would
# then be answered by an endpoint that no longer exists.
#
# That is not hypothetical: on 2026-09-05 this script reported "the Cilium
# DaemonSet was never created (waited 10m)" about a cluster whose DaemonSet was
# healthy and 27 minutes old. The kubeconfig still named the destroyed cluster.
#
# --cluster-name and --region are already required arguments, so this needs no
# new input.
echo "==> Pointing kubectl at ${CLUSTER_NAME} (${REGION})"
if ! aws eks update-kubeconfig --region "${REGION}" --name "${CLUSTER_NAME}" >/dev/null; then
	echo "    ERROR: could not write a kubeconfig for ${CLUSTER_NAME} in ${REGION}." >&2
	echo "    Everything below talks to the cluster, so this cannot continue." >&2
	exit 1
fi

echo "==> Waiting for the Cilium DaemonSet to be ready (up to 10m)"

# Two waits, not one, because `kubectl rollout status` does NOT wait for the
# object to appear. On a DaemonSet that does not exist yet it returns
# `Error from server (NotFound)` in about half a second, having ignored
# --timeout entirely -- measured 2026-09-05: 0.495s against a 600s timeout.
#
# That matters here specifically. `helm_release.cilium` in
# opentofu/aws/eks/configure/main.tf sets `wait = false`, so the apply can print
# "Apply complete!" and hand straight over to this script while the API server
# has not registered the DaemonSet yet. A single rollout-status call then claims
# a ten-minute timeout that never happened -- on a from-scratch build, which is
# the only kind of build this script exists for. It cost the 2026-09-05
# bootstrap, on a cluster whose Cilium went Ready 35 seconds after the
# DaemonSet was finally created.
deadline=$((SECONDS + 600))
# stderr is KEPT and inspected, for the reason this file already gives below:
# an absent object and an unreachable cluster must not print the same sentence.
# The first version of this wait discarded it and did exactly that.
ds_err="$(mktemp)"
trap 'rm -f -- "$ds_err"' EXIT
until kubectl get daemonset/cilium -n kube-system >/dev/null 2>"$ds_err"; do
	# NotFound is the condition worth waiting through. Anything else -- an
	# unreachable endpoint, an expired token, an RBAC denial -- will not fix
	# itself in ten minutes, so say so now rather than at the deadline.
	if ! grep -qi 'notfound\|not found' "$ds_err"; then
		echo "    ERROR: cannot query the cluster for the Cilium DaemonSet:" >&2
		sed 's/^/      /' "$ds_err" >&2
		echo "    This is not an absent DaemonSet -- waiting will not resolve it." >&2
		exit 1
	fi
	if [ "$SECONDS" -ge "$deadline" ]; then
		echo "    ERROR: the Cilium DaemonSet was never created (waited 10m)." >&2
		echo "    helm_release.cilium sets wait = false, so a successful apply does not" >&2
		echo "    mean the chart landed. Check the release itself:" >&2
		echo "        helm -n kube-system status cilium" >&2
		exit 1
	fi
	sleep 5
done

# stderr is deliberately NOT discarded here. Three unrelated failures reach this
# line -- the DaemonSet missing, kubeconfig pointing at another cluster, and a
# genuine readiness timeout -- and swallowing the error made all three print one
# identical sentence. After the fact the real cause was unrecoverable: the
# evidence that would have distinguished them had been thrown away.
remaining=$((deadline - SECONDS))
[ "$remaining" -gt 0 ] || remaining=30
if ! kubectl rollout status daemonset/cilium -n kube-system --timeout="${remaining}s"; then
	echo "    ERROR: Cilium DaemonSet did not become ready. Refusing to recycle nodes." >&2
	exit 1
fi
echo "    Cilium is ready."

# Only meaningful when prefix delegation is actually on. If it is off, individual
# secondary IPs are the intended behaviour everywhere and there is nothing to fix.
#
# Fail closed on an unreadable ConfigMap rather than treating it as "off". If
# Cilium is ready and this still cannot be read, something is wrong that a silent
# no-op would hide -- and the failure it hides is a capacity cliff that surfaces
# hours later, in an unrelated component.
if ! pd_raw=$(kubectl get cm -n kube-system cilium-config -o jsonpath='{.data.aws-enable-prefix-delegation}' 2>&1); then
	echo "    ERROR: could not read cilium-config even though Cilium is ready:" >&2
	echo "    ${pd_raw}" >&2
	echo "    Refusing to assume prefix delegation is off -- that assumption is what" >&2
	echo "    silently wedged the 2026-09-04 bootstrap." >&2
	exit 1
fi
pd="${pd_raw}"
if [[ "$pd" != "true" ]]; then
	echo "    Prefix delegation is not enabled (aws-enable-prefix-delegation=${pd:-<unset>}) — nothing to do."
	exit 0
fi

# Returns the number of ENI prefixes Cilium has allocated on a node (0 if none).
node_prefix_count() {
	kubectl get ciliumnode "$1" -o json 2>/dev/null |
		jq '[.status.eni.enis[]? | (.prefixes // []) | length] | add // 0'
}

mapfile -t MNG_NODES < <(kubectl get nodes -l eks.amazonaws.com/nodegroup -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null | grep -v '^[[:space:]]*$')

if [[ ${#MNG_NODES[@]} -eq 0 ]]; then
	echo "    No managed-node-group nodes found — nothing to do."
	exit 0
fi

# Decide up front which nodes need work, so the log states the plan before acting.
TARGETS=()
for node in "${MNG_NODES[@]}"; do
	prefixes=$(node_prefix_count "$node")
	itype=$(kubectl get node "$node" -o jsonpath='{.metadata.labels.node\.kubernetes\.io/instance-type}' 2>/dev/null)

	if [[ "${prefixes:-0}" -gt 0 ]]; then
		echo "    ${node} (${itype}): prefixes=${prefixes} — OK"
		continue
	fi

	# Prefix delegation requires Nitro. On anything else (e.g. i3.*, which is Xen)
	# zero prefixes is correct and recycling would loop forever.
	hypervisor=$(${AWS_CMD} ec2 describe-instance-types --instance-types "$itype" \
		--query 'InstanceTypes[0].Hypervisor' --output text 2>/dev/null)
	if [[ "$hypervisor" != "nitro" ]]; then
		echo "    ${node} (${itype}): prefixes=0 but hypervisor=${hypervisor:-unknown} — prefix delegation unsupported, skipping"
		continue
	fi

	echo "    ${node} (${itype}): prefixes=0 on a Nitro instance — NEEDS RECYCLE"
	TARGETS+=("$node")
done

if [[ ${#TARGETS[@]} -eq 0 ]]; then
	echo "==> All managed-node-group nodes already use prefix delegation. Nothing to do."
	exit 0
fi

if [[ ${#TARGETS[@]} -gt $MAX_RECYCLE ]]; then
	echo "    ERROR: ${#TARGETS[@]} nodes flagged, limit is ${MAX_RECYCLE}. Refusing — this looks wrong." >&2
	echo "    Override with EKS_RECYCLE_MAX if it is genuinely intended." >&2
	exit 1
fi

echo "==> Recycling ${#TARGETS[@]} node(s), one at a time"

failures=0
for node in "${TARGETS[@]}"; do
	echo ""
	echo "--> ${node}"

	instance_id=$(kubectl get node "$node" -o jsonpath='{.spec.providerID}' 2>/dev/null | sed 's|.*/||')
	if [[ -z "$instance_id" ]]; then
		echo "    ERROR: could not resolve instance ID — skipping." >&2
		failures=$((failures + 1))
		continue
	fi

	kubectl cordon "$node" >/dev/null 2>&1 || true

	# Best-effort drain. At bootstrap the node carries almost nothing, so a failed
	# or partial drain is not a reason to abort — the instance is about to go away.
	echo "    draining..."
	kubectl drain "$node" --ignore-daemonsets --delete-emptydir-data \
		--timeout=300s --skip-wait-for-delete-timeout=60 >/dev/null 2>&1 ||
		echo "    (drain incomplete — continuing, the instance is being replaced anyway)"

	echo "    terminating ${instance_id} (the node group restores desiredSize)"
	if ! ${AWS_CMD} ec2 terminate-instances --instance-ids "$instance_id" >/dev/null 2>&1; then
		echo "    ERROR: terminate failed for ${instance_id}" >&2
		kubectl uncordon "$node" >/dev/null 2>&1 || true
		failures=$((failures + 1))
		continue
	fi

	# Wait for the old node object to disappear, then for the group to be whole
	# again. Waiting on node COUNT rather than a name, since the replacement's
	# name is not known ahead of time.
	want=${#MNG_NODES[@]}
	echo "    waiting for the replacement to join and become Ready (up to 15m)"
	deadline=$((SECONDS + 900))
	while ((SECONDS < deadline)); do
		ready=$(kubectl get nodes -l eks.amazonaws.com/nodegroup \
			-o jsonpath='{range .items[*]}{.metadata.name}{"="}{range .status.conditions[?(@.type=="Ready")]}{.status}{end}{"\n"}{end}' 2>/dev/null |
			grep -c "=True$")
		still_there=$(kubectl get node "$node" --no-headers 2>/dev/null | grep -c . || true)
		if [[ "$ready" -ge "$want" && "$still_there" -eq 0 ]]; then
			break
		fi
		sleep 15
	done

	if ((SECONDS >= deadline)); then
		echo "    ERROR: replacement did not become Ready within 15m." >&2
		failures=$((failures + 1))
		continue
	fi
	echo "    replacement is Ready."
done

echo ""
echo "==> Verifying prefix delegation on the node group"
remaining=0
for node in $(kubectl get nodes -l eks.amazonaws.com/nodegroup -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null); do
	prefixes=$(node_prefix_count "$node")
	itype=$(kubectl get node "$node" -o jsonpath='{.metadata.labels.node\.kubernetes\.io/instance-type}' 2>/dev/null)
	if [[ "${prefixes:-0}" -gt 0 ]]; then
		echo "    ${node} (${itype}): prefixes=${prefixes} ✅"
	else
		echo "    ${node} (${itype}): prefixes=0 ⚠️"
		remaining=$((remaining + 1))
	fi
done

if [[ $failures -gt 0 ]]; then
	echo "==> Completed with ${failures} failure(s)." >&2
	exit 1
fi

# A node can legitimately still report 0 (non-Nitro), so this is a warning rather
# than an error — the per-node lines above say which and why.
[[ $remaining -gt 0 ]] && echo "==> ${remaining} node(s) still without prefixes — see the lines above."

echo "==> Done."
exit 0
