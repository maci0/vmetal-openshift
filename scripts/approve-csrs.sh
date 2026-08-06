#!/usr/bin/env bash
# Approve pending node CSRs until all expected nodes are Ready. UPI workers (and
# the kubelet-serving certs) join via CSRs that nothing auto-approves on a
# platform:none cluster, so this runs alongside `wait-for install-complete`.
#
#   scripts/approve-csrs.sh [cluster] [expected_nodes] [timeout_secs]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib.sh
source "$ROOT/scripts/lib.sh"

CLUSTER="${1:-${CLUSTER:-cluster0}}"
require_cluster_name "$CLUSTER"
EXPECT="${2:-0}"
TIMEOUT="${3:-2400}"
resolve_oc
export KUBECONFIG="$ROOT/clusters/$CLUSTER/auth/kubeconfig"
[[ -f "$KUBECONFIG" ]] || die "no kubeconfig for '$CLUSTER'"

deadline=$(( $(cut -d. -f1 /proc/uptime) + TIMEOUT ))
while [[ "$(cut -d. -f1 /proc/uptime)" -lt "$deadline" ]]; do
  # Approve every Pending CSR (kubelet bootstrap + serving).
  pending="$("$OC" get csr --no-headers 2>/dev/null | awk '$NF=="Pending"{print $1}' || true)"
  if [[ -n "$pending" ]]; then
    # shellcheck disable=SC2086
    "$OC" adm certificate approve $pending >/dev/null 2>&1 && log "approved: $(echo "$pending" | tr '\n' ' ')" || true
  fi
  ready="$("$OC" get nodes --no-headers 2>/dev/null | awk '$2 ~ /^Ready/' | wc -l || true)"
  ready="${ready// /}"
  [[ "$EXPECT" -gt 0 && "${ready:-0}" -ge "$EXPECT" ]] && { log "all $EXPECT nodes Ready"; exit 0; }
  sleep 15
done
if [[ "$EXPECT" -gt 0 ]]; then
  die "csr-approve: timed out after ${TIMEOUT}s (expected $EXPECT Ready nodes)"
fi
log "csr-approve: timed out after ${TIMEOUT}s"
exit 0
