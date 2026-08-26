#!/usr/bin/env bash
# Approve pending node CSRs until the named nodes are all Ready. UPI workers (and
# the kubelet-serving certs) join via CSRs that nothing auto-approves on a
# platform:none cluster, so this runs alongside `wait-for install-complete`.
#
#   scripts/approve-csrs.sh <cluster> [node...]
#
# With no node names it approves until CSR_TIMEOUT and exits 0 (fire-and-forget).
# Env: CSR_TIMEOUT (seconds, default 2400), CSR_POLL (seconds between passes).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib.sh
source "$ROOT/scripts/lib.sh"

CLUSTER="${1:-${CLUSTER:-cluster0}}"
require_cluster_name "$CLUSTER"
shift || true
NODES=("$@")
TIMEOUT="${CSR_TIMEOUT:-2400}"
POLL="${CSR_POLL:-15}"

require_oc
export KUBECONFIG="$ROOT/clusters/$CLUSTER/auth/kubeconfig"
[[ -f "$KUBECONFIG" ]] || die "no kubeconfig for '$CLUSTER'"

node_ready() {
  [[ "$("$OC" get node "$1" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" == "True" ]]
}

# /proc/uptime, not SECONDS: unaffected by the caller's shell state.
now() { cut -d. -f1 /proc/uptime; }
deadline=$(( $(now) + TIMEOUT ))

while [[ "$(now)" -lt "$deadline" ]]; do
  # Approve every Pending CSR (kubelet bootstrap + serving).
  pending="$("$OC" get csr --no-headers 2>/dev/null | awk '$NF=="Pending"{print $1}' || true)"
  if [[ -n "$pending" ]]; then
    # shellcheck disable=SC2086
    "$OC" adm certificate approve $pending >/dev/null 2>&1 && log "approved: $(echo "$pending" | tr '\n' ' ')" || true
  fi
  if [[ "${#NODES[@]}" -gt 0 ]]; then
    ready=0
    for n in "${NODES[@]}"; do node_ready "$n" && ready=$((ready + 1)); done
    log "nodes Ready: $ready/${#NODES[@]}"
    [[ "$ready" -eq "${#NODES[@]}" ]] && { log "all ${#NODES[@]} node(s) Ready"; exit 0; }
  fi
  sleep "$POLL"
done

[[ "${#NODES[@]}" -eq 0 ]] || die "csr-approve: timed out after ${TIMEOUT}s (${ready:-0}/${#NODES[@]} nodes Ready)"
log "csr-approve: stopped after ${TIMEOUT}s"
