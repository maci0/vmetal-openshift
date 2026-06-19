#!/usr/bin/env bash
# Add the day-2 workers defined by a cluster's `day2_workers` count:
# provision the worker VMs, build an agent node-image against the running cluster,
# boot the workers over redfish, and approve their CSRs until they join.
#   scripts/workers-add.sh [cluster]      (or CLUSTER=...)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
CLUSTER="${1:-${CLUSTER:-cluster0}}"
HTTP_PORT="${HTTP_PORT:-8099}"

die() { printf '\033[1;31m!!\033[0m %s\n' "$*" >&2; exit 1; }
log() { printf '\033[1;32m==>\033[0m %s\n' "$*"; }

[[ -x "$ROOT/.venv/bin/ansible-playbook" ]] && AP="$ROOT/.venv/bin/ansible-playbook" || AP="ansible-playbook"
[[ -x "$ROOT/.venv/bin/python" ]] && PY="$ROOT/.venv/bin/python" || PY=python3
OI="$ROOT/build/openshift-install/openshift-install"; [[ -x "$OI" ]] || OI="$(command -v openshift-install || true)"
[[ -n "$OI" && -x "$OI" ]] || die "openshift-install not found; run scripts/bootstrap.sh"
command -v oc >/dev/null || die "oc not found"
command -v jq >/dev/null || die "jq required"

kubeconfig="$ROOT/clusters/$CLUSTER/auth/kubeconfig"
[[ -f "$kubeconfig" ]] || die "no kubeconfig for '$CLUSTER' (install the cluster first)"
export KUBECONFIG="$kubeconfig"

if [[ "$(id -u)" == 0 ]] || id -nG | grep -qw libvirt; then BECOME=(-e use_become=false); else BECOME=(); fi
ap() { ( cd "$ROOT/ansible" && "$AP" "$@" ); }

# Worker hostnames from the derived topology.
topo="$(mktemp)"; ap dump-topology.yml -e out="$topo" >/dev/null 2>&1
mapfile -t WORKERS < <(jq -r --arg c "$CLUSTER" '.[] | select(.name==$c) | .day2_workers[].fullname' "$topo")
rm -f "$topo"
[[ "${#WORKERS[@]}" -gt 0 ]] || die "cluster '$CLUSTER' has no day2_workers (set day2_workers: N in group_vars)"
log "Adding ${#WORKERS[@]} worker(s): ${WORKERS[*]}"

log "Provisioning worker VMs + rendering nodes-config.yaml"
ap workers.yml -e cluster="$CLUSTER" -e worker_action=add "${BECOME[@]}"

log "Building agent node-image against the running cluster"
work="$ROOT/build/nodeimg-$CLUSTER"
rm -rf "$work"; mkdir -p "$work"
cp "$ROOT/build/nodes-config-$CLUSTER.yaml" "$work/nodes-config.yaml"
"$OI" agent create node-image --dir "$work"
iso="$(find "$work" -maxdepth 1 -name '*.iso' | head -1)"
[[ -n "$iso" ]] || die "node-image build produced no ISO"
cp "$iso" "$ROOT/build/node_$CLUSTER.iso"

log "Serving ISO + booting workers over redfish"
"$PY" -m http.server "$HTTP_PORT" --directory "$ROOT/build" >/tmp/vmetal-iso-http.log 2>&1 &
http_pid=$!
trap 'kill "$http_pid" 2>/dev/null || true' EXIT
sleep 2
ap bmc.yml -e cluster="$CLUSTER" -e bmc_action=boot-iso -e node_set=day2_workers \
  -e iso_name="node_$CLUSTER.iso" -e iso_base_url="http://127.0.0.1:${HTTP_PORT}"

log "Approving CSRs until workers join (Ctrl-C to stop watching)"
deadline=$(( SECONDS + 2400 ))
while (( SECONDS < deadline )); do
  oc get csr -o jsonpath='{range .items[?(@.status.conditions[0].type!="Approved")]}{.metadata.name}{"\n"}{end}' 2>/dev/null \
    | grep -v '^$' | xargs -r oc adm certificate approve >/dev/null 2>&1 || true
  ready=0
  for w in "${WORKERS[@]}"; do
    [[ "$(oc get node "$w" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" == "True" ]] && ready=$((ready + 1))
  done
  log "workers Ready: $ready/${#WORKERS[@]}"
  [[ "$ready" -eq "${#WORKERS[@]}" ]] && { log "all workers joined"; break; }
  sleep 20
done
oc get nodes
