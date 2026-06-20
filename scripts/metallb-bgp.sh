#!/usr/bin/env bash
# MetalLB BGP mode: run an FRR router on the host that peers with the speakers,
# and advertise an off-link pool over BGP (so reachability proves the BGP route).
# FRR runs as a host-network container; zebra installs the learned /32s into the
# host kernel (ECMP across speakers).
#   scripts/metallb-bgp.sh [cluster] [up|down]   (default: up)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLUSTER="${1:-${CLUSTER:-cluster0}}"
ACTION="${2:-up}"
DIR="$ROOT/clusters/$CLUSTER"
FRR_NAME="vmetal-frr-$CLUSTER"
FRR_IMG="${FRR_IMG:-quay.io/frrouting/frr:latest}"

die() { printf '\033[1;31m!!\033[0m %s\n' "$*" >&2; exit 1; }
log() { printf '\033[1;32m==>\033[0m %s\n' "$*"; }

command -v oc >/dev/null || die "oc not found"
export KUBECONFIG="$DIR/auth/kubeconfig"

# Container runtime for the FRR peer (needs host netns + privileged so zebra can
# write host kernel routes).
if command -v podman >/dev/null; then RT="sudo podman"
elif command -v docker >/dev/null; then RT="docker"; docker info >/dev/null 2>&1 || RT="sudo docker"
else die "need podman or docker for the FRR BGP peer"; fi

if [[ "$ACTION" == down ]]; then
  log "Removing FRR + BGP config"
  $RT rm -f "$FRR_NAME" >/dev/null 2>&1 || true
  [[ -f "$DIR/metallb-bgp.yaml" ]] && oc delete -f "$DIR/metallb-bgp.yaml" --ignore-not-found >/dev/null 2>&1 || true
  log "done (L2 MetalLB, if installed, is left in place)"
  exit 0
fi

[[ -f "$DIR/frr.conf" && -f "$DIR/metallb-bgp.yaml" ]] || die "no BGP manifests for '$CLUSTER'; run 'make configs' first"
[[ -f "$KUBECONFIG" ]] || die "no kubeconfig for '$CLUSTER'"

log "Installing the MetalLB operator (if needed)"
oc apply -f "$DIR/metallb-operator.yaml" >/dev/null
for _ in $(seq 1 60); do oc get crd metallbs.metallb.io >/dev/null 2>&1 && break; sleep 10; done
oc get crd bgppeers.metallb.io >/dev/null 2>&1 || die "MetalLB operator/CRDs not ready"

log "Applying MetalLB instance"
for _ in $(seq 1 30); do oc apply -f "$DIR/metallb-config.yaml" >/dev/null 2>&1 && break; sleep 10; done
oc -n metallb-system rollout status ds/speaker --timeout=180s >/dev/null 2>&1 || true

log "Starting FRR BGP router on the host ($FRR_IMG)"
$RT rm -f "$FRR_NAME" >/dev/null 2>&1 || true
$RT run -d --name "$FRR_NAME" --network host --privileged --restart unless-stopped \
  -v "$DIR/frr.conf:/etc/frr/frr.conf:ro" \
  -v "$DIR/frr-daemons:/etc/frr/daemons:ro" \
  "$FRR_IMG" >/dev/null
sleep 5

log "Applying MetalLB BGP peer + advertisement"
for _ in $(seq 1 30); do oc apply -f "$DIR/metallb-bgp.yaml" >/dev/null 2>&1 && break; sleep 5; done

log "Done. Check the peering + routes:"
echo "  $RT exec $FRR_NAME vtysh -c 'show bgp summary'"
echo "  $RT exec $FRR_NAME vtysh -c 'show bgp ipv4 unicast'"
echo "  expose a Service type=LoadBalancer with annotation"
echo "    metallb.io/address-pool: ${CLUSTER}-bgp-pool"
echo "  then: ip route show | grep 198.51 ; curl http://<assigned-ip>"
