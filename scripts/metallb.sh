#!/usr/bin/env bash
# Install MetalLB on a cluster so Service type=LoadBalancer gets an external IP
# (baremetal has no cloud LB). Installs the operator, waits for it, then applies
# the MetalLB instance + an L2 address pool from the machine net.
#   scripts/metallb.sh [cluster]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLUSTER="${1:-${CLUSTER:-cluster0}}"
DIR="$ROOT/clusters/$CLUSTER"

die() { printf '\033[1;31m!!\033[0m %s\n' "$*" >&2; exit 1; }
log() { printf '\033[1;32m==>\033[0m %s\n' "$*"; }

command -v oc >/dev/null || die "oc not found"
[[ -f "$DIR/metallb-operator.yaml" ]] || die "no manifests for '$CLUSTER'; run 'make configs' first"
export KUBECONFIG="$DIR/auth/kubeconfig"
[[ -f "$KUBECONFIG" ]] || die "no kubeconfig for '$CLUSTER'"

log "Installing the MetalLB operator"
oc apply -f "$DIR/metallb-operator.yaml"

log "Waiting for the MetalLB CRDs"
for _ in $(seq 1 60); do
  oc get crd metallbs.metallb.io >/dev/null 2>&1 && break
  sleep 10
done
oc get crd metallbs.metallb.io >/dev/null 2>&1 || die "MetalLB operator did not install (check the subscription / marketplace)"
oc -n metallb-system rollout status deploy/metallb-operator-controller-manager --timeout=180s || true

log "Applying MetalLB instance + L2 address pool"
for _ in $(seq 1 30); do
  oc apply -f "$DIR/metallb-config.yaml" && break   # retry: admission webhook may lag the CRDs
  sleep 10
done

log "Done. Pool:"
oc -n metallb-system get ipaddresspool 2>/dev/null
