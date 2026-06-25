#!/usr/bin/env bash
# Approve pending node CSRs until all expected nodes are Ready. UPI workers (and
# the kubelet-serving certs) join via CSRs that nothing auto-approves on a
# platform:none cluster, so this runs alongside `wait-for install-complete`.
#
#   scripts/approve-csrs.sh [cluster] [expected_nodes] [timeout_secs]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLUSTER="${1:-${CLUSTER:-cluster0}}"
EXPECT="${2:-0}"
TIMEOUT="${3:-2400}"
OC="$ROOT/build/openshift-install/oc"; [[ -x "$OC" ]] || OC="$(command -v oc)"
export KUBECONFIG="$ROOT/clusters/$CLUSTER/auth/kubeconfig"

log() { printf '\033[1;32m==>\033[0m %s\n' "$*"; }

deadline=$(( $(cut -d. -f1 /proc/uptime) + TIMEOUT ))
while [[ "$(cut -d. -f1 /proc/uptime)" -lt "$deadline" ]]; do
  # Approve every Pending CSR (kubelet bootstrap + serving).
  pending="$("$OC" get csr --no-headers 2>/dev/null | awk '$NF=="Pending"{print $1}' || true)"
  if [[ -n "$pending" ]]; then
    # shellcheck disable=SC2086
    "$OC" adm certificate approve $pending >/dev/null 2>&1 && log "approved: $(echo "$pending" | tr '\n' ' ')" || true
  fi
  ready="$("$OC" get nodes --no-headers 2>/dev/null | awk '$2=="Ready"' | wc -l)"
  [[ "$EXPECT" -gt 0 && "$ready" -ge "$EXPECT" ]] && { log "all $EXPECT nodes Ready"; exit 0; }
  sleep 15
done
log "csr-approve: timed out after ${TIMEOUT}s"
