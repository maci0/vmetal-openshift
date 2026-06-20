#!/usr/bin/env bash
# OpenShift Virtualization (CNV): install the kubevirt-hyperconverged operator and
# the HyperConverged CR. Day-2; needs nested virt (this lab provides it).
#   scripts/virt.sh [cluster]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLUSTER="${1:-${CLUSTER:-cluster0}}"
DIR="$ROOT/clusters/$CLUSTER"

die() { printf '\033[1;31m!!\033[0m %s\n' "$*" >&2; exit 1; }
log() { printf '\033[1;32m==>\033[0m %s\n' "$*"; }

command -v oc >/dev/null || die "oc not found"
export KUBECONFIG="$DIR/auth/kubeconfig"
[[ -f "$KUBECONFIG" ]] || die "no kubeconfig for '$CLUSTER'"
[[ -f "$DIR/cnv-operator.yaml" && -f "$DIR/cnv-hyperconverged.yaml" ]] || die "run 'make configs' first"

log "Installing the OpenShift Virtualization operator"
oc apply -f "$DIR/cnv-operator.yaml" >/dev/null
for _ in $(seq 1 60); do oc get crd hyperconvergeds.hco.kubevirt.io >/dev/null 2>&1 && break; sleep 10; done
oc get crd hyperconvergeds.hco.kubevirt.io >/dev/null 2>&1 || die "CNV operator/CRDs not ready"

# Dedicated live-migration network (macvlan over the migration VLAN). Apply before
# the HyperConverged so its liveMigrationConfig.network can reference it.
if [[ -f "$DIR/cnv-migration-network.yaml" ]]; then
  log "Applying the dedicated live-migration network (migration VLAN)"
  for _ in $(seq 1 30); do oc apply -f "$DIR/cnv-migration-network.yaml" >/dev/null 2>&1 && break; sleep 5; done
fi

log "Creating the HyperConverged CR (deploys KubeVirt + CDI)"
for _ in $(seq 1 30); do oc apply -f "$DIR/cnv-hyperconverged.yaml" >/dev/null 2>&1 && break; sleep 5; done

log "Waiting for HyperConverged to become Available (this takes several minutes)"
for _ in $(seq 1 90); do
  [[ "$(oc -n openshift-cnv get hyperconverged kubevirt-hyperconverged -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null)" == "True" ]] && break
  sleep 20
done
avail="$(oc -n openshift-cnv get hyperconverged kubevirt-hyperconverged -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || true)"
if [[ "$avail" == "True" ]]; then
  log "OpenShift Virtualization is Available"
else
  log "HyperConverged Available=$avail (check: oc -n openshift-cnv get hyperconverged -o yaml)"
fi
oc get csv -n openshift-cnv 2>/dev/null | grep -E 'kubevirt|NAME' || true
