#!/usr/bin/env bash
# Add the day-2 workers defined by a cluster's `day2_workers` count:
# provision the worker VMs, build an agent node-image against the running cluster,
# boot the workers over redfish, and approve their CSRs until they join.
#   scripts/workers-add.sh [cluster]      (or CLUSTER=...)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
# shellcheck source=scripts/lib.sh
source "$ROOT/scripts/lib.sh"

CLUSTER="${1:-${CLUSTER:-cluster0}}"
require_cluster_name "$CLUSTER"
HTTP_PORT="${HTTP_PORT:-8099}"

resolve_ansible
require_oc
command -v jq >/dev/null || die "jq required"

# `oc adm node-image create` needs a 4.17+ client.
ocver="$("$OC" version --client -o json 2>/dev/null | jq -r '.releaseClientVersion // .clientVersion.gitVersion' 2>/dev/null || echo "")"
ocver="${ocver#v}"
[[ "$ocver" =~ ^([0-9]+)\.([0-9]+) ]] || die "cannot parse oc version: '${ocver:-unknown}'"
maj="${BASH_REMATCH[1]}"; min="${BASH_REMATCH[2]}"
(( maj > 4 || (maj == 4 && min >= 17) )) || die "need an oc >= 4.17 for 'adm node-image' (have $ocver)"

kubeconfig="$ROOT/clusters/$CLUSTER/auth/kubeconfig"
[[ -f "$kubeconfig" ]] || die "no kubeconfig for '$CLUSTER' (install the cluster first)"
export KUBECONFIG="$kubeconfig"

libvirt_become_args
ap() { ( cd "$ROOT/ansible" && "$AP" "$@" ); }

topo="$(dump_topology)"
mapfile -t WORKERS < <(jq -r --arg c "$CLUSTER" '.[] | select(.name==$c) | .day2_workers[].fullname' "$topo")
rm -f "$topo"
[[ "${#WORKERS[@]}" -gt 0 ]] || die "cluster '$CLUSTER' has no day2_workers (set day2_workers: N in group_vars)"
log "Adding ${#WORKERS[@]} worker(s): ${WORKERS[*]}"

log "Provisioning worker VMs + rendering nodes-config.yaml"
ap lifecycle/workers.yml -e cluster_name="$CLUSTER" -e worker_action=add "${BECOME[@]}"

log "Building add-nodes image against the running cluster ($("$OC" version --client 2>/dev/null | head -1))"
work="$ROOT/build/nodeimg-$CLUSTER"
rm -rf "$work"; mkdir -p "$work"
cp "$ROOT/build/nodes-config-$CLUSTER.yaml" "$work/nodes-config.yaml"
"$OC" adm node-image create --dir "$work"
iso="$(find "$work" -maxdepth 1 -name '*.iso' | head -1)"
[[ -n "$iso" ]] || die "node-image build produced no ISO (see $work/report.json)"
cp "$iso" "$ROOT/build/node_$CLUSTER.iso"

log "Serving ISO + booting workers over redfish"
trap 'kill "${http_pid:-}" 2>/dev/null || true' EXIT
start_http_server "$HTTP_PORT" "$ROOT/build" "127.0.0.1" "node_$CLUSTER.iso"
ap lifecycle/bmc.yml -e cluster="$CLUSTER" -e bmc_action=boot-iso -e node_set=day2_workers \
  -e iso_name="node_$CLUSTER.iso" -e iso_base_url="http://127.0.0.1:${HTTP_PORT}" "${BECOME[@]}"

log "Approving CSRs until workers join (Ctrl-C to stop watching)"
rc=0; ./scripts/approve-csrs.sh "$CLUSTER" "${WORKERS[@]}" || rc=$?
"$OC" get nodes   # show the node list even on timeout, then propagate the failure
exit "$rc"
