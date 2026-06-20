#!/usr/bin/env bash
# LVM Storage operator: a local RWO StorageClass (lvms-vg1) from the workers'
# dedicated disk (vdc). Day-2; run after the cluster is up.
#   scripts/lvms.sh [cluster]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLUSTER="${1:-${CLUSTER:-cluster0}}"
DIR="$ROOT/clusters/$CLUSTER"

die() { printf '\033[1;31m!!\033[0m %s\n' "$*" >&2; exit 1; }
log() { printf '\033[1;32m==>\033[0m %s\n' "$*"; }

command -v oc >/dev/null || die "oc not found"
export KUBECONFIG="$DIR/auth/kubeconfig"
[[ -f "$KUBECONFIG" ]] || die "no kubeconfig for '$CLUSTER'"
[[ -f "$DIR/lvms-operator.yaml" && -f "$DIR/lvms-cluster.yaml" ]] || die "run 'make configs' first"

log "Installing the LVM Storage operator"
oc apply -f "$DIR/lvms-operator.yaml" >/dev/null
for _ in $(seq 1 60); do oc get crd lvmclusters.lvm.topolvm.io >/dev/null 2>&1 && break; sleep 10; done
oc get crd lvmclusters.lvm.topolvm.io >/dev/null 2>&1 || die "LVMS CRDs not ready"
oc -n openshift-storage rollout status deploy/lvms-operator --timeout=300s >/dev/null 2>&1 || true

log "Creating the LVMCluster (volume group on each worker's vdc)"
for _ in $(seq 1 30); do oc apply -f "$DIR/lvms-cluster.yaml" >/dev/null 2>&1 && break; sleep 5; done

log "Waiting for the LVMCluster to become Ready"
for _ in $(seq 1 60); do
  [[ "$(oc -n openshift-storage get lvmcluster lvmcluster -o jsonpath='{.status.state}' 2>/dev/null)" == "Ready" ]] && break
  sleep 10
done
state="$(oc -n openshift-storage get lvmcluster lvmcluster -o jsonpath='{.status.state}' 2>/dev/null || true)"
[[ "$state" == "Ready" ]] || log "LVMCluster state is '$state' (check: oc -n openshift-storage describe lvmcluster lvmcluster)"

log "StorageClasses:"
oc get sc 2>/dev/null | grep -E 'NAME|lvms' || true
