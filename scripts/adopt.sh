#!/usr/bin/env bash
# Day-2: make in-cluster BareMetalHost management real on a baremetal cluster.
# Applies the metal3 Provisioning CR (deploys metal3/ironic) and the BMH objects,
# so the cluster power-manages its own nodes via the Redfish BMC.
# Only works on platform: baremetal (node_count >= 3). Single-node clusters are
# platform: none: the operator stays dormant, use out-of-band `make boot` there.
#   scripts/adopt.sh [cluster]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
CLUSTER="${1:-${CLUSTER:-cluster0}}"
DIR="$ROOT/clusters/$CLUSTER"

die() { printf '\033[1;31m!!\033[0m %s\n' "$*" >&2; exit 1; }

KC="$(command -v oc || command -v kubectl || true)"
[[ -n "$KC" ]] || die "need oc or kubectl on PATH"
[[ -f "$DIR/auth/kubeconfig" ]] || die "no kubeconfig for '$CLUSTER' (install it first)"
[[ -f "$DIR/provisioning.yaml" ]] || die "no provisioning.yaml for '$CLUSTER'. Adopt applies only to AGENT
       baremetal clusters (node_count >= 3). Single-node is platform: none (no metal3);
       IPI already creates the Provisioning CR + BareMetalHosts during install."

export KUBECONFIG="$DIR/auth/kubeconfig"

platform="$("$KC" get infrastructure cluster -o jsonpath='{.status.platform}' 2>/dev/null || true)"
[[ "$platform" == "BareMetal" ]] || die "cluster platform is '$platform', not BareMetal: metal3 will not deploy.
       In-cluster BMH needs a platform: baremetal cluster (node_count >= 3)."

ns=openshift-machine-api

echo "==> Applying metal3 Provisioning CR (deploys metal3/ironic)"
"$KC" apply -f "$DIR/provisioning.yaml"

echo "==> Waiting for metal3 to roll out"
"$KC" -n "$ns" rollout status deploy/metal3 --timeout=300s || true

echo "==> Waiting for the baremetal-operator admission webhook"
for _ in $(seq 1 40); do
  ep="$("$KC" -n "$ns" get endpoints baremetal-operator-webhook-service \
        -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null || true)"
  [[ -n "$ep" ]] && break
  sleep 6
done

existing="$("$KC" -n "$ns" get bmh -o name 2>/dev/null | wc -l)"
if [[ "$existing" -gt 0 ]]; then
  # Agent baremetal installs create unmanaged BMHs (with a consumerRef). Adding
  # BMC creds makes them managed -> "externally provisioned", enabling power
  # control WITHOUT reprovisioning (the host is already adopted).
  echo "==> $existing existing BMH(s): enabling BMC (power management)"
  "$KC" apply -f "$DIR/baremetalhosts.yaml"
elif [[ "${ADOPT_HOSTS:-}" == "1" ]]; then
  echo "==> ADOPT_HOSTS=1: enrolling fresh BareMetalHosts"
  "$KC" apply -f "$DIR/baremetalhosts.yaml"
else
  echo "==> No existing BMHs. NOT enrolling (applying a BMH to a running node"
  echo "    reprovisions it). Re-run with ADOPT_HOSTS=1 for fresh hardware."
fi

echo "==> metal3 pods + BareMetalHosts:"
"$KC" -n "$ns" get pods | grep -i metal3 || true
"$KC" -n "$ns" get bmh 2>/dev/null || echo "(no BareMetalHosts)"
