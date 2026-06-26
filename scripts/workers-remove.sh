#!/usr/bin/env bash
# Remove a cluster's day-2 workers: cordon + drain + delete them from the cluster,
# then destroy and undefine their VMs.
#   scripts/workers-remove.sh [cluster]      (or CLUSTER=...)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
CLUSTER="${1:-${CLUSTER:-cluster0}}"

die() { printf '\033[1;31m!!\033[0m %s\n' "$*" >&2; exit 1; }
log() { printf '\033[1;32m==>\033[0m %s\n' "$*"; }

[[ -x "$ROOT/.venv/bin/ansible-playbook" ]] && AP="$ROOT/.venv/bin/ansible-playbook" || AP="ansible-playbook"
command -v oc >/dev/null || die "oc not found"
command -v jq >/dev/null || die "jq required"

kubeconfig="$ROOT/clusters/$CLUSTER/auth/kubeconfig"
[[ -f "$kubeconfig" ]] || die "no kubeconfig for '$CLUSTER'"
export KUBECONFIG="$kubeconfig"

if [[ "$(id -u)" == 0 ]] || id -nG | grep -qw libvirt; then BECOME=(-e use_become=false); else BECOME=(); fi
ap() { ( cd "$ROOT/ansible" && "$AP" "$@" ); }

topo="$(mktemp)"; ap lifecycle/dump-topology.yml -e out="$topo" >/dev/null 2>&1
mapfile -t WORKERS < <(jq -r --arg c "$CLUSTER" '.[] | select(.name==$c) | .day2_workers[].fullname' "$topo")
rm -f "$topo"
[[ "${#WORKERS[@]}" -gt 0 ]] || die "cluster '$CLUSTER' has no day2_workers"
log "Removing ${#WORKERS[@]} worker(s): ${WORKERS[*]}"

for w in "${WORKERS[@]}"; do
  if oc get node "$w" >/dev/null 2>&1; then
    log "draining $w"
    oc adm cordon "$w" >/dev/null 2>&1 || true
    oc adm drain "$w" --ignore-daemonsets --delete-emptydir-data --force --timeout=180s >/dev/null 2>&1 || true
    oc delete node "$w" >/dev/null 2>&1 || true
  fi
done

log "Destroying worker VMs"
ap lifecycle/workers.yml -e cluster_name="$CLUSTER" -e worker_action=remove "${BECOME[@]}"
log "done"
