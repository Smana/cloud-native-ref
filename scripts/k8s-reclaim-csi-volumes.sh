#!/usr/bin/env bash
#
# Reclaim CSI-provisioned volumes before a cluster is destroyed. CLOUD-NEUTRAL.
#
# Destroying a cluster with PVCs still bound skips the reclaim entirely: the CSI
# controller dies with the cluster, and every PVC-backed volume is orphaned in
# the cloud account with nothing left to reference it. Nothing reports this --
# `tofu destroy` says "Destroy complete", and the volumes bill quietly.
#
# The history is on both clouds now:
#   AWS  62 EBS volumes (~518Gi) accumulated across rebuilds by 2026-07, and 12
#        more (~138Gi) from a single 2026-07-21 rebuild.
#   GCP  3 orphaned PD disks (35Gi) survived the 2026-08-27 gcp-0 teardown --
#        Harbor's registry, its CNPG cluster and trivy. GKE had no equivalent of
#        this step at all; it was AWS-only because that is where it first hurt.
#
# Extracted from scripts/eks-prepare-destroy.sh rather than copied: every step
# below is plain Kubernetes, and a second copy is a second thing to forget.
#
# MUST run while the CSI controller is still schedulable -- before any node
# draining starts.
#
# Usage:
#   k8s-reclaim-csi-volumes.sh [kube-context]
#
# With no argument the current context is used. Never fails the caller: a
# cluster that is already gone, or unreachable, leaves nothing to reclaim and
# the cloud-side sweep is the backstop.

set -o errexit
set -o nounset
set -o pipefail

CONTEXT="${1:-}"
KCTL=(kubectl)
[ -n "$CONTEXT" ] && KCTL=(kubectl --context "$CONTEXT")

if ! "${KCTL[@]}" --request-timeout=20s get ns >/dev/null 2>&1; then
    echo "cluster unreachable — nothing to reclaim in-cluster; the cloud-side sweep is the backstop"
    exit 0
fi

echo "Reclaiming CSI-provisioned volumes..."

# 0. Suspend Flux first. Everything below deletes or scales down objects Flux
#    owns, and a running reconciler puts every one of them straight back --
#    the PVCs included, so the reclaim would appear to work and leave the
#    volumes bound.
#
#    eks-prepare-destroy.sh already suspends Flux earlier for its own reasons,
#    so on AWS this is a no-op. It is here because it is a PRECONDITION of the
#    steps below, not a step of the caller's: a second caller that forgot it
#    would get a silent, plausible-looking failure.
if "${KCTL[@]}" api-resources --api-group=kustomize.toolkit.fluxcd.io >/dev/null 2>&1; then
    echo "Suspending Flux kustomizations..."
    if [ -n "$CONTEXT" ]; then
        flux --context "$CONTEXT" suspend kustomization --all 2>/dev/null || true
    else
        flux suspend kustomization --all 2>/dev/null || true
    fi
fi

# 1. Belt-and-braces: make every PV reclaimable (covers Retain PVs).
for pv in $("${KCTL[@]}" get pv -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
    "${KCTL[@]}" patch pv "$pv" --type=merge \
        -p '{"spec":{"persistentVolumeReclaimPolicy":"Delete"}}' >/dev/null 2>&1 || true
done

# 2. CNPG clusters own their pods AND PVCs (recreating both if deleted from
#    under them) — delete the Cluster CRs so the operator reclaims cleanly.
if "${KCTL[@]}" api-resources --api-group=postgresql.cnpg.io 2>/dev/null | grep -q clusters; then
    "${KCTL[@]}" delete clusters.postgresql.cnpg.io --all --all-namespaces --wait=false 2>/dev/null || true
fi

# 3. Scale to 0 exactly the Deployments/StatefulSets that mount PVCs (an STS
#    would recreate PVCs from its templates if we only deleted pods).
#    Selecting by PVC-presence never touches kube-system's CSI controller.
"${KCTL[@]}" get deploy,statefulset --all-namespaces -o json 2>/dev/null \
    | jq -r '.items[] | select((([.spec.template.spec.volumes[]? | select(.persistentVolumeClaim)] | length) > 0) or (((.spec.volumeClaimTemplates // []) | length) > 0)) | "\(.kind|ascii_downcase) \(.metadata.namespace) \(.metadata.name)"' 2>/dev/null \
    | while read -r kind ns name; do
        [ -z "$name" ] && continue
        "${KCTL[@]}" scale "$kind" -n "$ns" "$name" --replicas=0 >/dev/null 2>&1 || true
    done

# 4. Catch-all for remaining PVC-mounting pods (Jobs, naked pods): PVC deletion
#    blocks on the pvc-protection finalizer while any pod still uses it.
"${KCTL[@]}" get pods --all-namespaces -o json 2>/dev/null \
    | jq -r '.items[] | select(([.spec.volumes[]? | select(.persistentVolumeClaim)] | length) > 0) | "\(.metadata.namespace) \(.metadata.name)"' 2>/dev/null \
    | while read -r ns name; do
        [ -z "$name" ] && continue
        "${KCTL[@]}" delete pod -n "$ns" "$name" --wait=false 2>/dev/null || true
    done

# 5. Delete the PVCs and wait for the CSI driver to reclaim every PV. The moment
#    the PV list is empty, the backing cloud volumes are gone too.
"${KCTL[@]}" delete pvc --all --all-namespaces --wait=false 2>/dev/null || true
echo "Waiting for PersistentVolumes to be reclaimed (up to 300s)..."
for _ in $(seq 1 60); do
    pv_count=$("${KCTL[@]}" get pv --no-headers 2>/dev/null | wc -l)
    [ "$pv_count" = "0" ] && break
    sleep 5
done

if [ "${pv_count:-0}" != "0" ]; then
    echo "WARNING: ${pv_count} PV(s) not reclaimed — their backing volumes may be orphaned:"
    "${KCTL[@]}" get pv -o jsonpath='{range .items[*]}{.metadata.name}{" -> "}{.spec.csi.volumeHandle}{"\n"}{end}' 2>/dev/null || true
    echo "The cloud-side sweep (stage2-sweep-orphaned-disks) deletes these after the"
    echo "cluster is gone. On AWS there is no equivalent step yet -- check manually."
else
    echo "All PersistentVolumes reclaimed."
fi
