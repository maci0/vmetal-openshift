#!/usr/bin/env bash
# Remove a cluster's day-2 workers: cordon + drain + delete them from the cluster,
# then destroy and undefine their VMs.
#   scripts/workers-remove.sh [cluster]      (or CLUSTER=...)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
# shellcheck source=scripts/lib.sh
source "$ROOT/scripts/lib.sh"

CLUSTER="${1:-${CLUSTER:-cluster0}}"
require_cluster_name "$CLUSTER"

resolve_ansible
resolve_oc
command -v jq >/dev/null || die "jq required"

kubeconfig="$ROOT/clusters/$CLUSTER/auth/kubeconfig"
[[ -f "$kubeconfig" ]] || die "no kubeconfig for '$CLUSTER'"
export KUBECONFIG="$kubeconfig"

libvirt_become_args
ap() { ( cd "$ROOT/ansible" && "$AP" "$@" ); }

topo="$(dump_topology)"
mapfile -t WORKERS < <(jq -r --arg c "$CLUSTER" '.[] | select(.name==$c) | .day2_workers[].fullname' "$topo")
rm -f "$topo"
[[ "${#WORKERS[@]}" -gt 0 ]] || die "cluster '$CLUSTER' has no day2_workers"
log "Removing ${#WORKERS[@]} worker(s): ${WORKERS[*]}"

for w in "${WORKERS[@]}"; do
  if "$OC" get node "$w" >/dev/null 2>&1; then
    log "draining $w"
    "$OC" adm cordon "$w" >/dev/null 2>&1 || true
    "$OC" adm drain "$w" --ignore-daemonsets --delete-emptydir-data --force --timeout=180s >/dev/null 2>&1 || true
    "$OC" delete node "$w" >/dev/null 2>&1 || true
  fi
done

log "Destroying worker VMs"
ap lifecycle/workers.yml -e cluster_name="$CLUSTER" -e worker_action=remove "${BECOME[@]}"
log "done"
